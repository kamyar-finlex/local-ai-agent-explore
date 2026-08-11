#!/usr/bin/env python3
"""
p3-plan-lint.py - mechanical validation of a plan against ORCHESTRATOR.md.

The planner is a small model; whether it actually produced dispatchable tickets
is not something to establish by reading them. This script parses every issue
the way the dispatcher will and reports PASS/FAIL per check, exiting non-zero on
any failure -- so it works as a gate before a human is asked to approve
anything.

It has NO network dependency in fixture mode and never writes. The parser here
is deliberately a SEPARATE implementation from the renderer in p3-plan.py: if
both were the same code, a round-trip test would only prove the code agrees with
itself.

Three input modes, one check engine:

  --ledger plan/tickets.jsonl        before creation: the fields, the graph
  --fixtures DIR                     rendered issues as JSON (offline, no token)
  --repo owner/name --parent N       live: the issues that actually exist

Checks that cannot be evaluated in a mode report SKIP rather than a silent PASS.
A check that can never fail is worse than no check -- this repo has already
shipped one of those once.
"""

import argparse
import json
import os
import re
import shlex
import sys
import urllib.error
import urllib.request

API = "https://api.github.com"

REQUIRED_SECTIONS = ["Goal", "Files touched", "Details", "Acceptance criteria"]
OPTIONAL_SECTIONS = ["Blocked-by"]
STATUS_LABELS = {"status:backlog", "status:todo", "status:in-progress",
                 "status:blocked", "status:done"}
PRIORITY_RE = re.compile(r"^priority:([1-4])$")
PATH_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]*$")
SHELL_OPS = {"&&", "||", ";", "|", "&", ">", ">>", "<", "2>", "2>&1"}
PROSE = re.compile(r"\b(should|must|verify that|check that|ensure|works|passes when)\b", re.I)

PASS, FAIL, SKIP = "PASS", "FAIL", "SKIP"


# --------------------------------------------------------------------------- #
# parsing - independent of p3-plan.py's renderer, on purpose
# --------------------------------------------------------------------------- #

def parse_body(body):
    order, sections, cur = [], {}, None
    for line in (body or "").splitlines():
        m = re.match(r"^##\s+(.+?)\s*$", line)
        if m:
            cur = m.group(1)
            order.append(cur)
            sections.setdefault(cur, [])
        elif cur is not None:
            sections[cur].append(line)
    return order, {k: "\n".join(v).strip() for k, v in sections.items()}


def parse_files(text):
    out = []
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("- "):
            out.append(line[2:].strip())
        elif line:
            out.append("!" + line)     # a non-bullet line the dispatcher cannot parse
    return out


def parse_blockers(text):
    refs, junk = [], []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        m = re.fullmatch(r"#(\d+)", line)
        if m:
            refs.append(int(m.group(1)))
        else:
            junk.append(line)
    return refs, junk


def strip_fence(text):
    lines = [l for l in text.splitlines() if not l.strip().startswith("```")]
    return "\n".join(lines).strip()


class Ticket:
    def __init__(self, key, label, title, labels, parent, body=None, fields=None):
        self.key, self.label, self.title = key, label, title
        self.labels, self.parent = list(labels or []), parent
        self.section_order, self.sections = [], {}
        self.junk_blockers, self.bad_file_lines = [], []
        if body is not None:
            self.section_order, self.sections = parse_body(body)
            raw_files = parse_files(self.sections.get("Files touched", ""))
            self.bad_file_lines = [f[1:] for f in raw_files if f.startswith("!")]
            self.files = [f for f in raw_files if not f.startswith("!")]
            self.goal = self.sections.get("Goal", "")
            self.details = self.sections.get("Details", "")
            self.acceptance = strip_fence(self.sections.get("Acceptance criteria", ""))
            self.blockers, self.junk_blockers = parse_blockers(
                self.sections.get("Blocked-by", ""))
            self.has_blocked_section = "Blocked-by" in self.sections
        else:
            f = fields
            self.files = f["files"]
            self.goal, self.details = f["goal"], f["details"]
            self.acceptance = f["acceptance"]
            self.blockers = f["blocked_by"]
            self.has_blocked_section = bool(f["blocked_by"])

    @property
    def priorities(self):
        return [l for l in self.labels if PRIORITY_RE.match(l)]

    @property
    def statuses(self):
        return [l for l in self.labels if l in STATUS_LABELS]


# --------------------------------------------------------------------------- #
# graph
# --------------------------------------------------------------------------- #

def ancestors(tickets, key, memo=None):
    """Everything that must close before `key` may start."""
    memo = {} if memo is None else memo
    if key in memo:
        return memo[key]
    memo[key] = set()
    out, t = set(), tickets.get(key)
    if t:
        for b in t.blockers:
            if b in tickets:
                out.add(b)
                out |= ancestors(tickets, b, memo)
    memo[key] = out
    return out


def find_cycle(tickets):
    colour, path = {}, []

    def walk(k):
        colour[k] = 1
        path.append(k)
        for b in tickets[k].blockers:
            if b not in tickets:
                continue
            if colour.get(b) == 1:
                return path[path.index(b):] + [b]
            if colour.get(b, 0) == 0:
                found = walk(b)
                if found:
                    return found
        colour[k] = 2
        path.pop()
        return None

    for k in tickets:
        if colour.get(k, 0) == 0:
            found = walk(k)
            if found:
                return found
    return None


def waves(tickets):
    """Dependency levels: everything in one level can be in flight together."""
    depth, out = {}, []

    def d(k, seen=()):
        if k in depth:
            return depth[k]
        if k in seen:
            return 0
        v = 0
        for b in tickets[k].blockers:
            if b in tickets:
                v = max(v, d(b, seen + (k,)) + 1)
        depth[k] = v
        return v

    for k in tickets:
        d(k)
    for lvl in range(max(depth.values(), default=0) + 1):
        out.append([tickets[k].label for k in tickets if depth[k] == lvl])
    return out


# --------------------------------------------------------------------------- #
# checks
# --------------------------------------------------------------------------- #

CHECKS = []


def check(cid, why):
    def deco(fn):
        fn.cid, fn.why = cid, why
        CHECKS.append(fn)
        return fn
    return deco


def verdict(bad, ok_msg):
    if bad:
        return FAIL, "; ".join(bad[:4]) + (f" (+{len(bad) - 4} more)" if len(bad) > 4 else "")
    return PASS, ok_msg


@check("FMT-SECTIONS", "the body carries exactly the contract's sections, in order")
def c_sections(ts, ctx):
    if ctx["mode"] == "ledger":
        return SKIP, "ledger mode: no body rendered yet"
    bad = []
    for t in ts:
        seen = t.section_order
        missing = [s for s in REQUIRED_SECTIONS if s not in seen]
        unknown = [s for s in seen if s not in REQUIRED_SECTIONS + OPTIONAL_SECTIONS]
        dupes = [s for s in set(seen) if seen.count(s) > 1]
        req_seen = [s for s in seen if s in REQUIRED_SECTIONS]
        if missing:
            bad.append(f"{t.label}: missing {missing}")
        elif unknown:
            bad.append(f"{t.label}: unknown section {unknown}")
        elif dupes:
            bad.append(f"{t.label}: duplicated section {dupes}")
        elif req_seen != REQUIRED_SECTIONS:
            bad.append(f"{t.label}: sections out of order {req_seen}")
    return verdict(bad, f"{len(ts)} tickets carry all {len(REQUIRED_SECTIONS)} sections in order")


@check("FMT-TITLE", "a title a human can scan in a list")
def c_title(ts, ctx):
    bad = [f"{t.label}: title {'empty' if not t.title.strip() else 'is ' + str(len(t.title)) + ' chars'}"
           for t in ts if not t.title.strip() or len(t.title) > 72]
    return verdict(bad, "titles are 1-72 characters")


@check("FMT-GOAL", "Goal is one sentence, not a paragraph")
def c_goal(ts, ctx):
    bad = []
    for t in ts:
        g = t.goal.strip()
        if not g:
            bad.append(f"{t.label}: Goal is empty")
        elif len(g.splitlines()) > 1:
            bad.append(f"{t.label}: Goal spans {len(g.splitlines())} lines")
    return verdict(bad, "every Goal is a single sentence")


@check("FMT-FILES", "Files touched parses as a list of repo-relative paths")
def c_files(ts, ctx):
    bad = []
    for t in ts:
        if t.bad_file_lines:
            bad.append(f"{t.label}: unparseable file line {t.bad_file_lines[0]!r}")
            continue
        if not t.files:
            bad.append(f"{t.label}: no files listed")
            continue
        for p in t.files:
            if p.startswith("/") or ".." in p.split("/"):
                bad.append(f"{t.label}: {p} is not repo-relative")
            elif not PATH_RE.match(p) or p.endswith("/"):
                bad.append(f"{t.label}: {p} is not a plain file path")
        if len(set(t.files)) != len(t.files):
            bad.append(f"{t.label}: duplicate path in Files touched")
    return verdict(bad, f"{sum(len(t.files) for t in ts)} paths, all repo-relative")


@check("FMT-DETAILS", "Details gives a worker enough to start")
def c_details(ts, ctx):
    bad = [f"{t.label}: Details is {len(t.details.strip())} chars"
           for t in ts if len(t.details.strip()) < 20]
    return verdict(bad, "every ticket has substantive Details")


@check("FMT-ACCEPT", "Acceptance criteria is ONE runnable command, not prose")
def c_accept(ts, ctx):
    bad = []
    for t in ts:
        cmd = t.acceptance.strip()
        if not cmd:
            bad.append(f"{t.label}: empty")
            continue
        if len(cmd.splitlines()) > 1:
            bad.append(f"{t.label}: {len(cmd.splitlines())} lines, expected 1")
            continue
        try:
            toks = shlex.split(cmd)
        except ValueError as e:
            bad.append(f"{t.label}: unparseable ({e})")
            continue
        if not toks:
            bad.append(f"{t.label}: empty")
        elif [x for x in toks if x in SHELL_OPS]:
            op = [x for x in toks if x in SHELL_OPS][0]
            bad.append(f"{t.label}: chains commands with {op!r}")
        elif PROSE.search(cmd):
            bad.append(f"{t.label}: prose, not a command ({cmd[:40]!r})")
        elif not re.match(r"^[A-Za-z0-9_./-]+$", toks[0]):
            bad.append(f"{t.label}: {toks[0]!r} is not a command name")
    return verdict(bad, "every acceptance criterion is a single command")


@check("FMT-BLOCKED", "Blocked-by holds bare #N references, or is absent")
def c_blocked(ts, ctx):
    if ctx["mode"] == "ledger":
        return SKIP, "ledger mode: references are local ids until emit"
    bad = []
    for t in ts:
        if t.junk_blockers:
            bad.append(f"{t.label}: {t.junk_blockers[0]!r} is not a #N reference")
        if t.has_blocked_section and not t.blockers and not t.junk_blockers:
            bad.append(f"{t.label}: empty Blocked-by section (omit it instead)")
        if t.key in t.blockers:
            bad.append(f"{t.label}: blocked by itself")
    return verdict(bad, "dependency references are well-formed")


@check("LBL-PRIORITY", "exactly one priority label")
def c_priority(ts, ctx):
    bad = [f"{t.label}: {t.priorities or 'no priority label'}"
           for t in ts if len(t.priorities) != 1]
    return verdict(bad, "every ticket carries exactly one priority:N")


@check("LBL-BACKLOG", "created in backlog, so a human still gates the work")
def c_backlog(ts, ctx):
    bad = [f"{t.label}: labels {t.statuses or '[]'}"
           for t in ts if "status:backlog" not in t.labels]
    return verdict(bad, "every ticket is status:backlog")


@check("LBL-STATUS", "no self-approval, and status:blocked only where it is true")
def c_status(ts, ctx):
    bad = []
    for t in ts:
        extra = [s for s in t.statuses if s not in ("status:backlog", "status:blocked")]
        if extra:
            bad.append(f"{t.label}: planner applied {extra} -- approval is a human act")
        if "status:blocked" in t.labels and not t.blockers:
            bad.append(f"{t.label}: status:blocked with no Blocked-by")
    return verdict(bad, "no ticket approves itself")


@check("LBL-NOSPEC", "children are not themselves specs")
def c_nospec(ts, ctx):
    bad = [f"{t.label}: carries the `spec` label" for t in ts if "spec" in t.labels]
    return verdict(bad, "no child carries the spec label")


@check("DEP-RESOLVE", "every Blocked-by points at a ticket in this plan")
def c_resolve(ts, ctx):
    known = {t.key for t in ts} | set(ctx.get("external", []))
    bad = [f"{t.label}: blocked by unknown {b}" for t in ts for b in t.blockers
           if b not in known]
    return verdict(bad, "all dependency references resolve")


@check("DEP-CYCLE", "the dependency graph is acyclic, so something can start")
def c_cycle(ts, ctx):
    index = {t.key: t for t in ts}
    cyc = find_cycle(index)
    if cyc:
        return FAIL, "cycle: " + " -> ".join(index[k].label if k in index else str(k) for k in cyc)
    return PASS, "no dependency cycles"


@check("DEP-ROOT", "at least one ticket is ready on day one")
def c_root(ts, ctx):
    roots = [t.label for t in ts if not t.blockers]
    if not roots:
        return FAIL, "every ticket has a blocker -- nothing is dispatchable"
    return PASS, f"{len(roots)} ticket(s) start unblocked: {', '.join(roots[:4])}"


@check("CONC-FILES", "tickets that may run together do not share a file")
def c_conc(ts, ctx):
    index = {t.key: t for t in ts}
    memo, bad = {}, []
    for i, a in enumerate(ts):
        for b in ts[i + 1:]:
            if b.key in ancestors(index, a.key, memo) or a.key in ancestors(index, b.key, memo):
                continue                                  # forced apart in time
            shared = sorted(set(a.files) & set(b.files))
            if shared:
                bad.append(f"{a.label} and {b.label} both touch {shared[0]}")
    return verdict(bad, "concurrently dispatchable tickets touch disjoint files")


@check("SAFE-README", "no ticket touches the target README (contract prohibition)")
def c_readme(ts, ctx):
    bad = [f"{t.label}: {p}" for t in ts for p in t.files
           if os.path.basename(p).lower() == "readme.md" or p.split("/")[0] == ".git"]
    return verdict(bad, "no ticket edits the README or .git")


@check("SIZE-FILES", "one concern per ticket, measured in files")
def c_size(ts, ctx):
    lim = ctx["max_files"]
    bad = [f"{t.label}: {len(t.files)} files (limit {lim})" for t in ts if len(t.files) > lim]
    return verdict(bad, f"no ticket exceeds {lim} files")


@check("LINK-PARENT", "every ticket is a native sub-issue of the spec")
def c_parent(ts, ctx):
    if ctx["mode"] == "ledger":
        return SKIP, "ledger mode: nothing linked until emit"
    spec = ctx.get("spec")
    if spec is None:
        return SKIP, "no --parent given, so linkage cannot be judged"
    bad = [f"{t.label}: parent={t.parent}" for t in ts if t.parent != spec]
    return verdict(bad, f"all {len(ts)} tickets are sub-issues of #{spec}")


# --------------------------------------------------------------------------- #
# input adapters
# --------------------------------------------------------------------------- #

def from_ledger(path):
    tickets, order, spec = {}, [], None
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if rec.get("kind") == "init":
                spec = rec["spec"]
            if rec.get("kind") == "ticket":
                if rec["id"] not in tickets:
                    order.append(rec["id"])
                tickets[rec["id"]] = rec
    out = [Ticket(r["id"], r["id"], r["title"],
                  ["status:backlog", f"priority:{r['priority']}"], None, fields=r)
           for r in (tickets[i] for i in order)]
    return out, spec


def from_fixtures(d):
    out = []
    for name in sorted(os.listdir(d)):
        if not name.endswith(".json"):
            continue
        with open(os.path.join(d, name), encoding="utf-8") as fh:
            i = json.load(fh)
        out.append(Ticket(i["number"], f"{i.get('local_id', '')}#{i['number']}".lstrip(),
                          i.get("title", ""), i.get("labels", []),
                          i.get("parent"), body=i.get("body", "")))
    return out


def from_repo(repo, parent):
    tok = os.environ.get("GITHUB_TOKEN") or os.environ.get("TARGET_REPO_TOKEN")
    if not tok:
        sys.exit("error: GITHUB_TOKEN is not set")

    def get(path):
        req = urllib.request.Request(API + path)
        req.add_header("Authorization", f"Bearer {tok}")
        req.add_header("Accept", "application/vnd.github+json")
        req.add_header("X-GitHub-Api-Version", "2022-11-28")
        req.add_header("User-Agent", "p3-plan-lint")
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return json.loads(r.read())
        except urllib.error.HTTPError as e:
            sys.exit(f"error: GET {path} -> HTTP {e.code}")
        except urllib.error.URLError as e:
            sys.exit(f"error: GET {path} unreachable: {e.reason}")

    out = []
    for i in get(f"/repos/{repo}/issues/{parent}/sub_issues?per_page=100"):
        out.append(Ticket(i["number"], f"#{i['number']}", i.get("title", ""),
                          [l["name"] for l in i.get("labels", [])],
                          parent, body=i.get("body", "")))
    return out


# --------------------------------------------------------------------------- #

def main():
    p = argparse.ArgumentParser(description="validate a plan against ORCHESTRATOR.md")
    p.add_argument("--ledger")
    p.add_argument("--fixtures")
    p.add_argument("--repo")
    p.add_argument("--parent", type=int)
    p.add_argument("--max-files", type=int, default=4)
    p.add_argument("--external", default="", help="comma-separated issue numbers that may "
                                                  "legitimately appear in Blocked-by")
    p.add_argument("--json", action="store_true")
    p.add_argument("--quiet", action="store_true")
    p.add_argument("--list-checks", action="store_true")
    a = p.parse_args()

    if a.list_checks:
        for fn in CHECKS:
            print(f"{fn.cid}\t{fn.why}")
        return 0

    spec = a.parent
    if a.ledger:
        tickets, spec = from_ledger(a.ledger)
        mode, src = "ledger", a.ledger
    elif a.fixtures:
        tickets = from_fixtures(a.fixtures)
        mode, src = "fixtures", a.fixtures
        if spec is None:
            parents = {t.parent for t in tickets if t.parent is not None}
            spec = parents.pop() if len(parents) == 1 else None
    elif a.repo and a.parent:
        tickets = from_repo(a.repo, a.parent)
        mode, src = "live", f"{a.repo} sub-issues of #{a.parent}"
    else:
        p.error("pass --ledger FILE, --fixtures DIR, or --repo owner/name --parent N")

    ctx = {"mode": mode, "spec": spec, "max_files": a.max_files,
           "external": [int(x) for x in a.external.split(",") if x.strip()]}

    if not tickets:
        print("error: the plan is empty -- nothing to validate", file=sys.stderr)
        return 1

    results = []
    for fn in CHECKS:
        try:
            status, msg = fn(tickets, ctx)
        except Exception as e:                      # a broken check is a failure
            status, msg = FAIL, f"check raised {type(e).__name__}: {e}"
        results.append((fn.cid, status, msg))

    npass = sum(1 for _, s, _ in results if s == PASS)
    nfail = sum(1 for _, s, _ in results if s == FAIL)
    nskip = sum(1 for _, s, _ in results if s == SKIP)

    if a.json:
        print(json.dumps({
            "mode": mode, "tickets": len(tickets),
            "passed": [c for c, s, _ in results if s == PASS],
            "failed": [c for c, s, _ in results if s == FAIL],
            "skipped": [c for c, s, _ in results if s == SKIP],
            "messages": {c: m for c, _, m in results},
        }, indent=2))
    elif not a.quiet:
        colour = {PASS: "\033[32m", FAIL: "\033[31m", SKIP: "\033[33m"}
        print(f"\nPLAN VALIDATION  ({mode}: {src}, {len(tickets)} tickets)\n")
        for cid, status, msg in results:
            print(f"  {colour[status]}{status}\033[0m  {cid:<13} {msg}")
        if nfail == 0:
            index = {t.key: t for t in tickets}
            for n, w in enumerate(waves(index), 1):
                print(f"        wave {n}: {', '.join(sorted(w))}")
        print(f"\nRESULT: {npass} passed, {nfail} failed, {nskip} skipped\n")

    return 1 if nfail else 0


if __name__ == "__main__":
    sys.exit(main())

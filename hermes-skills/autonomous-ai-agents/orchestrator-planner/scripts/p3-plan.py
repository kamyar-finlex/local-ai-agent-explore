#!/usr/bin/env python3
"""
p3-plan.py - the planner's ledger and issue emitter.

The planning model does NOT write issue bodies, JSON payloads or API calls. It
supplies fields, one ticket per invocation; this script renders the ORCHESTRATOR
ticket format, keeps an append-only ledger, and creates the issues. Two reasons,
both about surviving a small model:

  1. FORMAT IS NOT THE MODEL'S JOB. A 20B model asked to emit twenty
     fully-formed markdown bodies gets the last few wrong -- a missing "##
     Blocked-by", a priority label written twice. Rendering here removes that
     entire failure class: the sections and labels are a f-string, not a
     generation.
  2. FAILURE IS PER-TICKET. Every `add` appends one line and every `emit`
     appends one line; nothing is ever rewritten. A crash, a context overflow or
     a 502 from GitHub loses exactly one ticket, and re-running resumes from the
     ledger instead of re-planning.

`add` validates the row at the moment it is written, so the model is corrected
while it still remembers what it meant -- the earliest possible feedback point.

Stdlib only: the agent container has python3, curl and git, but NOT `gh`
(measured), so GitHub is reached over the REST API with urllib, which honours
HTTPS_PROXY and therefore works through the egress allowlist.

Usage:
  p3-plan.py init      --repo owner/name --spec 7
  p3-plan.py spec-show
  p3-plan.py layout    --path src/app.py --path tests/test_app.py ...
  p3-plan.py add       --id T1 --title "..." --priority 1 \
                       --files src/x.py,tests/test_x.py \
                       --acceptance "pytest -q tests/test_x.py" \
                       --goal "..." --details "..." [--blocked-by T0]
  p3-plan.py list | status | next
  p3-plan.py render    T1
  p3-plan.py emit      --id T1 | --all [--dry-run]

Environment:
  GITHUB_TOKEN   required for spec-show and a real emit; never logged.
  HTTPS_PROXY    honoured automatically by urllib when set.
"""

import argparse
import json
import os
import re
import shlex
import sys
import time
import urllib.error
import urllib.request

API = "https://api.github.com"

PRIORITIES = (1, 2, 3, 4)
ID_RE = re.compile(r"^T[0-9]{1,3}$")
PATH_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]*$")
# Shell operators that would make an acceptance criterion more than one command.
# Detected as whole shlex TOKENS, so a ';' inside a quoted python -c stays legal.
SHELL_OPS = {"&&", "||", ";", "|", "&", ">", ">>", "<", "2>", "2>&1"}
PROSE = re.compile(r"\b(should|must|verify that|check that|ensure|works|passes when)\b", re.I)


# --------------------------------------------------------------------------- #
# ledger
# --------------------------------------------------------------------------- #

class Plan:
    """Append-only JSONL ledger, rebuilt by replay. Never rewritten in place."""

    def __init__(self, plan_dir):
        self.dir = plan_dir
        self.path = os.path.join(plan_dir, "tickets.jsonl")
        self.repo = None
        self.spec = None
        self.layout = []
        self.tickets = {}      # id -> dict
        self.order = []        # ids in insertion order
        self.emitted = {}      # id -> {"number": int, "id": int}
        self._load()

    def _load(self):
        if not os.path.exists(self.path):
            return
        with open(self.path, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
        for n, line in enumerate(lines, 1):
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                # A torn final line is what a crash mid-append looks like.
                # Ignoring it is correct; ignoring one in the MIDDLE is not.
                if n == len(lines):
                    warn(f"ignoring torn final ledger line {n} (crash during append)")
                    continue
                die(f"ledger line {n} is corrupt: {line[:80]}")
            kind = rec.get("kind")
            if kind == "init":
                self.repo, self.spec = rec["repo"], rec["spec"]
            elif kind == "layout":
                self.layout = rec["paths"]
            elif kind == "ticket":
                if rec["id"] not in self.tickets:
                    self.order.append(rec["id"])
                self.tickets[rec["id"]] = rec
            elif kind == "emitted":
                self.emitted[rec["id"]] = {"number": rec["number"], "node": rec.get("node")}

    def append(self, rec):
        os.makedirs(self.dir, exist_ok=True)
        rec.setdefault("ts", int(time.time()))
        with open(self.path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(rec, sort_keys=True) + "\n")
            fh.flush()
            os.fsync(fh.fileno())

    def ticket_list(self):
        return [self.tickets[i] for i in self.order]

    def topo(self):
        """Insertion order, stabilised so blockers precede dependants."""
        done, out = set(), []
        pending = list(self.order)
        while pending:
            progressed = False
            for tid in list(pending):
                if all(b in done for b in self.tickets[tid]["blocked_by"]):
                    out.append(tid)
                    done.add(tid)
                    pending.remove(tid)
                    progressed = True
            if not progressed:                       # cycle: lint catches it
                out.extend(pending)
                break
        return out


def warn(msg):
    print(f"  warn: {msg}", file=sys.stderr)


def die(msg, code=1):
    print(f"error: {msg}", file=sys.stderr)
    raise SystemExit(code)


# --------------------------------------------------------------------------- #
# render - the ORCHESTRATOR ticket format, written once, in one place
# --------------------------------------------------------------------------- #

def render(ticket, resolve):
    """resolve: local id -> '#N'. Deliberately a small independent function --
    p3-plan-lint.py re-parses this text with its own parser, so a round-trip
    test through both actually proves something."""
    body = [
        "## Goal",
        ticket["goal"].strip(),
        "",
        "## Files touched",
    ]
    body += [f"- {p}" for p in ticket["files"]]
    body += [
        "",
        "## Details",
        ticket["details"].strip(),
        "",
        "## Acceptance criteria",
        ticket["acceptance"].strip(),
    ]
    if ticket["blocked_by"]:
        body += ["", "## Blocked-by"]
        body += [resolve(b) for b in ticket["blocked_by"]]
    return "\n".join(body) + "\n"


def labels_for(ticket):
    # status:backlog only. `status:blocked` is left to the dispatcher: while a
    # ticket is in backlog it is not dispatchable for a reason that has nothing
    # to do with its blockers, and two status labels at once is ambiguous state.
    return ["status:backlog", f"priority:{ticket['priority']}"]


# --------------------------------------------------------------------------- #
# field validation - runs at `add` time, one ticket at a time
# --------------------------------------------------------------------------- #

def check_acceptance(cmd):
    if "\n" in cmd.strip():
        return "must be a single line"
    if not cmd.strip():
        return "is empty"
    if cmd.strip().startswith(("-", "*", "#")):
        return "looks like a bullet or heading, not a command"
    try:
        toks = shlex.split(cmd)
    except ValueError as e:
        return f"does not parse as a shell command ({e})"
    if not toks:
        return "is empty"
    bad = [t for t in toks if t in SHELL_OPS]
    if bad:
        return (f"chains commands with {bad[0]!r}; the dispatcher runs ONE command "
                "and reads ONE exit code -- commit a make target or a script instead")
    if PROSE.search(cmd):
        return "reads as prose, not a command"
    if not re.match(r"^[A-Za-z0-9_./-]+$", toks[0]):
        return f"first token {toks[0]!r} is not a command name"
    return None


def check_files(paths):
    if not paths:
        return "no files listed; a ticket without a file list cannot be scheduled"
    seen = set()
    for p in paths:
        if p in seen:
            return f"{p} listed twice"
        seen.add(p)
        if p.startswith("/") or ".." in p.split("/"):
            return f"{p} is not a repo-relative path"
        if not PATH_RE.match(p) or p.endswith("/"):
            return f"{p} is not a plain file path"
        if os.path.basename(p).lower() == "readme.md":
            return "tickets may not touch the target README (ORCHESTRATOR prohibition)"
        if p.split("/")[0] == ".git":
            return f"{p} is inside .git"
    return None


# --------------------------------------------------------------------------- #
# GitHub - REST over urllib, stdlib only, proxy-aware
# --------------------------------------------------------------------------- #

def token():
    t = os.environ.get("GITHUB_TOKEN") or os.environ.get("TARGET_REPO_TOKEN") or ""
    if not t:
        die("GITHUB_TOKEN is not set (inject it at runtime; never commit it)")
    return t


def gh(method, path, body=None, raw=False):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token()}")
    req.add_header("Accept", "application/vnd.github.raw" if raw
                   else "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    req.add_header("User-Agent", "p3-planner")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            payload = r.read()
            return r.status, (payload.decode("utf-8", "replace") if raw
                              else (json.loads(payload) if payload.strip() else {}))
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:400]
        # Never echo headers: the token lives there.
        die(f"GitHub {method} {path} -> HTTP {e.code}: {detail}")
    except urllib.error.URLError as e:
        die(f"GitHub {method} {path} unreachable: {e.reason} "
            "(is HTTPS_PROXY set to the egress proxy?)")


# --------------------------------------------------------------------------- #
# commands
# --------------------------------------------------------------------------- #

def cmd_init(a, plan):
    if plan.repo:
        die(f"already initialised for {plan.repo} spec #{plan.spec}")
    if "/" not in a.repo:
        die("--repo must be owner/name")
    plan.append({"kind": "init", "repo": a.repo, "spec": a.spec})
    print(f"initialised plan for {a.repo}, spec issue #{a.spec}, ledger {plan.path}")


def cmd_spec_show(a, plan):
    require_init(plan)
    _, issue = gh("GET", f"/repos/{plan.repo}/issues/{plan.spec}")
    names = [l["name"] for l in issue.get("labels", [])]
    if "spec" not in names:
        die(f"issue #{plan.spec} is not labelled `spec` (labels: {names or 'none'})")
    os.makedirs(plan.dir, exist_ok=True)
    with open(os.path.join(plan.dir, "spec.md"), "w", encoding="utf-8") as fh:
        fh.write(f"# {issue['title']}\n\n{issue.get('body') or ''}\n")
    readme_bytes = 0
    try:
        _, readme = gh("GET", f"/repos/{plan.repo}/readme", raw=True)
        with open(os.path.join(plan.dir, "readme.md"), "w", encoding="utf-8") as fh:
            fh.write(readme)
        readme_bytes = len(readme)
    except SystemExit:
        warn("no README in the target repo -- the spec issue is the whole specification")
    print(f"spec #{plan.spec}: {issue['title']}")
    print(f"saved {plan.dir}/spec.md and {plan.dir}/readme.md ({readme_bytes} bytes)")
    print("--- spec issue body ---")
    print(issue.get("body") or "(empty)")


def cmd_layout(a, plan):
    require_init(plan)
    paths = flatten(a.path)
    if not paths:
        die("--path is required (repeat it, or comma-separate)")
    err = check_files(paths)
    if err:
        die(f"layout: {err}")
    plan.append({"kind": "layout", "paths": paths})
    print(f"layout recorded: {len(paths)} paths")
    for p in paths:
        print(f"  {p}")


def cmd_add(a, plan):
    require_init(plan)
    if not ID_RE.match(a.id):
        die("--id must look like T1, T2, ... (a local id; GitHub numbers are assigned later)")
    if a.id in plan.tickets:
        die(f"{a.id} already exists -- pick the next free id (`p3-plan.py list`)")
    if a.priority not in PRIORITIES:
        die("--priority must be 1, 2, 3 or 4")
    title = a.title.strip()
    if not title or len(title) > 72:
        die("--title must be 1-72 characters")

    files = flatten(a.files)
    err = check_files(files)
    if err:
        die(f"--files: {err}")
    if a.max_files and len(files) > a.max_files:
        die(f"--files lists {len(files)} paths (limit {a.max_files}); "
            "that is more than one concern -- split the ticket")

    blockers = flatten(a.blocked_by)
    for b in blockers:
        if b == a.id:
            die(f"{a.id} cannot block itself")
        if b not in plan.tickets:
            die(f"--blocked-by {b} does not exist yet; add blockers before dependants")

    err = check_acceptance(a.acceptance)
    if err:
        die(f"--acceptance {err}")

    goal, details = a.goal.strip(), read_or(a.details, a.details_file).strip()
    if not goal:
        die("--goal is required (one sentence)")
    if "\n" in goal:
        die("--goal must be one sentence on one line")
    if len(details) < 20:
        die("--details is too thin for a worker that has read only the README and this issue")

    # Overlap is a PLANNING failure, so catch it here rather than at dispatch.
    # A new ticket is forced apart in time only from its own transitive
    # blockers; every other existing ticket could be in flight beside it.
    earlier = ancestors(plan, blockers)
    for other in plan.ticket_list():
        if other["id"] in earlier:
            continue
        shared = set(files) & set(other["files"])
        if shared:
            die(f"{sorted(shared)} is already claimed by {other['id']}; two tickets that "
                f"can run at the same time must not share a file -- either add "
                f"--blocked-by {other['id']} to chain them, or give this ticket its own file")

    rec = {"kind": "ticket", "id": a.id, "title": title, "priority": a.priority,
           "files": files, "blocked_by": blockers, "acceptance": a.acceptance.strip(),
           "goal": goal, "details": details}
    plan.append(rec)
    print(f"added {a.id}  priority:{a.priority}  {len(files)} file(s)"
          + (f"  blocked-by {','.join(blockers)}" if blockers else "")
          + f"  [{len(plan.tickets) + 1} tickets in plan]")


def cmd_list(a, plan):
    require_init(plan)
    for t in plan.ticket_list():
        n = plan.emitted.get(t["id"], {}).get("number")
        print(f"  {t['id']:<4} p{t['priority']}  "
              f"{'#' + str(n) if n else 'pending':<8} "
              f"{t['title'][:44]:<46} "
              f"blocked-by:{','.join(t['blocked_by']) or '-':<12} "
              f"{','.join(t['files'])}")


def cmd_status(a, plan):
    require_init(plan)
    total, done = len(plan.tickets), len(plan.emitted)
    print(f"repo={plan.repo} spec=#{plan.spec} layout={len(plan.layout)} paths")
    print(f"tickets={total} emitted={done} pending={total - done}")
    if total > done:
        print("next: " + (next_id(plan) or "-"))


def cmd_next(a, plan):
    require_init(plan)
    print(next_id(plan) or "")


def cmd_render(a, plan):
    require_init(plan)
    t = plan.tickets.get(a.id) or die(f"{a.id} not in the plan")
    print(render(t, lambda b: resolve_ref(plan, b, allow_pending=True)))


def cmd_emit(a, plan):
    require_init(plan)
    if not a.id and not a.all:
        die("pass --id T1 (one ticket, the resumable way) or --all")
    if a.id and a.id not in plan.tickets:
        die(f"{a.id} not in the plan")
    # --all walks every ticket, including the done ones: resuming should SAY what
    # it is skipping, so a fresh context can see where the last run stopped.
    ids = [a.id] if a.id else plan.topo()
    if not ids:
        print("nothing to emit; the plan has no tickets")
        return

    if not a.dry_run:
        have = {l["name"] for l in gh("GET", f"/repos/{plan.repo}/labels?per_page=100")[1]}
        need = {"status:backlog"} | {f"priority:{p}" for p in PRIORITIES}
        missing = need - have
        if missing:
            die(f"labels missing in {plan.repo}: {sorted(missing)} -- run bootstrap-labels.sh")

    for tid in ids:
        if tid in plan.emitted:
            print(f"  skip {tid}: already issue #{plan.emitted[tid]['number']}")
            continue
        t = plan.tickets[tid]
        for b in t["blocked_by"]:
            if b not in plan.emitted:
                die(f"{tid} is blocked by {b}, which has no issue number yet -- emit {b} first")
        body = render(t, lambda b: resolve_ref(plan, b))
        if a.dry_run:
            number = 9000 + plan.order.index(tid) + 1
            fixture = {"number": number, "title": t["title"], "body": body,
                       "labels": labels_for(t), "parent": plan.spec, "local_id": tid}
            out = a.fixtures or os.path.join(plan.dir, "fixtures")
            os.makedirs(out, exist_ok=True)
            with open(os.path.join(out, f"{tid}.json"), "w", encoding="utf-8") as fh:
                json.dump(fixture, fh, indent=2, sort_keys=True)
            plan.emitted[tid] = {"number": number, "node": None}
            print(f"  dry-run {tid} -> #{number} ({out}/{tid}.json)")
            continue

        _, issue = gh("POST", f"/repos/{plan.repo}/issues",
                      {"title": t["title"], "body": body, "labels": labels_for(t)})
        # Sub-issue linkage wants the issue's DATABASE id, not its number --
        # passing the number silently links the wrong issue or 404s.
        gh("POST", f"/repos/{plan.repo}/issues/{plan.spec}/sub_issues",
           {"sub_issue_id": issue["id"]})
        plan.append({"kind": "emitted", "id": tid,
                     "number": issue["number"], "node": issue["id"]})
        plan.emitted[tid] = {"number": issue["number"], "node": issue["id"]}
        print(f"  created {tid} -> #{issue['number']}  {t['title'][:50]}")


# --------------------------------------------------------------------------- #
# helpers
# --------------------------------------------------------------------------- #

def require_init(plan):
    if not plan.repo:
        die("no plan here; run `p3-plan.py init --repo owner/name --spec N` first")


def flatten(values):
    out = []
    for v in values or []:
        out += [p.strip() for p in v.split(",") if p.strip()]
    return out


def read_or(inline, path):
    if path:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    return inline or ""


def next_id(plan):
    for tid in plan.topo():
        if tid not in plan.emitted:
            return tid
    return None


def resolve_ref(plan, local_id, allow_pending=False):
    e = plan.emitted.get(local_id)
    if e:
        return f"#{e['number']}"
    if allow_pending:
        return f"#?{local_id}"
    die(f"{local_id} has no issue number yet")


def ancestors(plan, blockers):
    """Every ticket that must be closed before one blocked by `blockers`."""
    seen, stack = set(), list(blockers)
    while stack:
        cur = stack.pop()
        if cur in seen or cur not in plan.tickets:
            continue
        seen.add(cur)
        stack += plan.tickets[cur]["blocked_by"]
    return seen


def main():
    p = argparse.ArgumentParser(description="planner ledger + issue emitter")
    p.add_argument("--plan-dir", default=os.environ.get("P3_PLAN_DIR", "plan"))
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("init");        s.add_argument("--repo", required=True); s.add_argument("--spec", type=int, required=True)
    s = sub.add_parser("spec-show")
    s = sub.add_parser("layout");      s.add_argument("--path", action="append", required=True)
    s = sub.add_parser("add")
    s.add_argument("--id", required=True)
    s.add_argument("--title", required=True)
    s.add_argument("--priority", type=int, required=True)
    s.add_argument("--files", action="append", required=True)
    s.add_argument("--acceptance", required=True)
    s.add_argument("--goal", required=True)
    s.add_argument("--details", default="")
    s.add_argument("--details-file", default="")
    s.add_argument("--blocked-by", action="append", default=[])
    s.add_argument("--max-files", type=int, default=4)
    sub.add_parser("list"); sub.add_parser("status"); sub.add_parser("next")
    s = sub.add_parser("render");      s.add_argument("id")
    s = sub.add_parser("emit")
    s.add_argument("--id"); s.add_argument("--all", action="store_true")
    s.add_argument("--dry-run", action="store_true"); s.add_argument("--fixtures")

    a = p.parse_args()
    plan = Plan(a.plan_dir)
    {"init": cmd_init, "spec-show": cmd_spec_show, "layout": cmd_layout, "add": cmd_add,
     "list": cmd_list, "status": cmd_status, "next": cmd_next, "render": cmd_render,
     "emit": cmd_emit}[a.cmd](a, plan)


if __name__ == "__main__":
    main()

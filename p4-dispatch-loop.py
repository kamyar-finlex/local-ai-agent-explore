#!/usr/bin/env python3
"""
p4-dispatch-loop - the DISPATCHER of the orchestrator contract (ORCHESTRATOR.md).

It polls the target repository for approved issues, decides *deterministically*
which of them are ready, claims them, starts one worker container per ticket
through the existing body-validating spawn dispatcher (p1-dispatcher.py), and
later validates what a worker produced.

There is no model anywhere in this file. "Is this ticket ready" is arithmetic on
labels, issue states and declared file paths, so the same repository state always
produces the same schedule and every decision can be replayed from the JSON plan
this program prints.

Subcommands
  plan      compute the schedule and print it. Read-only: mutates nothing.
  dispatch  compute, claim and spawn. --interval turns it into a poll loop.
  reap      release claims whose worker went silent past the timeout.
  validate  check one finished ticket: acceptance command, diff scope, full test
            suite, PR exists and references the issue. Records failures as an
            issue comment and repairs nothing.

Sources (--source)
  github            the live GitHub REST API; token from TARGET_REPO_TOKEN.
  fixture:<path>    a JSON fixture (see p4-fixtures/). Used by verify-dispatch.sh
                    so the scheduling logic is provable without live GitHub.

Spawners (--spawn)
  http              POST /spawn to p1-dispatcher (P4_SPAWN_URL, P4_SPAWN_TOKEN).
  record:<path>     append the spawn requests to a JSONL file; create nothing.
  none              dry run.
  fail              always fail, to exercise the claim-release path.

Configuration is environment only (see local.env.example). No token is ever
printed: everything on stdout/stderr passes through redact().

Stdlib only.
"""

from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import json
import os
import posixpath
import random
import re
import shlex
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

# --------------------------------------------------------------------------- #
# configuration
# --------------------------------------------------------------------------- #

REPO             = os.environ.get("TARGET_REPO", "")
TOKEN            = os.environ.get("TARGET_REPO_TOKEN", "")
API_ROOT         = os.environ.get("P4_GITHUB_API", "https://api.github.com")
MAX_CONCURRENCY  = int(os.environ.get("P4_MAX_CONCURRENCY", "3"))
WORKER_TIMEOUT_M = int(os.environ.get("P4_WORKER_TIMEOUT_MINUTES", "45"))
# Default to the name the composed stack actually uses. The old default,
# p1-dispatcher, was the standalone rig's container and does not exist under
# compose - and because it is absent from NO_PROXY, urllib handed the request
# to the egress proxy, which failed to resolve it. The symptom was a DNS error
# that read like a network fault rather than a wrong hostname.
SPAWN_URL        = os.environ.get("P4_SPAWN_URL", "http://hermes-dispatcher:2375")
SPAWN_TOKEN      = os.environ.get("P4_SPAWN_TOKEN", "")
WORKER_PREFIX    = os.environ.get("P4_WORKER_NAME_PREFIX", "p1-p4w-")
WORKER_CMD_TMPL  = os.environ.get(
    "P4_WORKER_CMD",
    '["sh","-c","P4_ISSUE={issue} P4_REPO={repo} exec /usr/local/bin/p4-worker.sh"]',
)
TEST_COMMAND     = os.environ.get("P4_TEST_COMMAND", "")
LOCK_PATH        = os.environ.get("P4_LOCK", os.path.join(
    os.environ.get("TMPDIR", "/tmp"), "p4-dispatch.lock"))
POLL_INTERVAL    = int(os.environ.get("P4_POLL_INTERVAL", "60"))
DISPATCHER_ID    = os.environ.get("P4_DISPATCHER_ID", "")

LBL_TODO        = "status:todo"
LBL_IN_PROGRESS = "status:in-progress"
LBL_BLOCKED     = "status:blocked"
LBL_BACKLOG     = "status:backlog"
LBL_DONE        = "status:done"

CLAIM_MARK     = "p4-claim"
RELEASE_MARK   = "p4-release"
HEARTBEAT_MARK = "p4-heartbeat"
DEFECT_MARK    = "p4-defect"
REPORT_MARK    = "p4-validation"

EXIT_OK, EXIT_FAIL, EXIT_USAGE, EXIT_LOCKED = 0, 1, 2, 3


def redact(text: str) -> str:
    """Last line of defence: no secret ever reaches a log, a comment or the
    harness transcript. Applied to everything this program prints."""
    out = str(text)
    for secret in (TOKEN, SPAWN_TOKEN):
        if secret and len(secret) >= 4:
            out = out.replace(secret, "<redacted>")
    return out


def log(msg: str) -> None:
    print(redact(msg), file=sys.stderr, flush=True)


def utcnow() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def parse_ts(value: str) -> dt.datetime:
    """GitHub timestamps are RFC3339 'Z'. Server time only - never the local
    clock, so a skewed dispatcher host cannot reap a live worker."""
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    return dt.datetime.fromisoformat(value)


# --------------------------------------------------------------------------- #
# ticket parsing - ORCHESTRATOR.md "Ticket format"
# --------------------------------------------------------------------------- #

# A heading needs whitespace after the hashes. Without that rule the line '#12'
# under Blocked-by parses as a heading, every blocker list comes out empty, and
# the dispatcher cheerfully runs dependent tickets in parallel - the exact
# silent failure ORCHESTRATOR.md opens by warning about.
HEADING_RE = re.compile(r"^\s{0,3}#{1,6}[ \t]+(.+?)\s*$")
BULLET_RE  = re.compile(r"^\s*[-*]\s+(.*\S)\s*$")
ISSUE_REF_RE = re.compile(r"#(\d+)\b")
PRIORITY_RE  = re.compile(r"^priority:(\d+)$")
FENCE_RE     = re.compile(r"^\s*(```|~~~)")

# A word that only ever appears in prose. Two or more of them (outside quotes)
# in an "Acceptance criteria" line means the planner wrote a sentence, not a
# command. Rejecting is safe because a rejection is REPORTED, never silent.
PROSE_WORDS = {
    "the", "a", "an", "and", "or", "of", "in", "to", "that", "all", "is", "are",
    "be", "should", "must", "when", "then", "with", "from", "it", "this",
    "there", "which", "passes", "passing", "returns", "without", "any",
}
QUOTED_RE = re.compile(r"""('[^']*'|"[^"]*")""")

BLOCKING, ADVISORY = "blocking", "advisory"


class Defect:
    __slots__ = ("kind", "detail", "severity")

    def __init__(self, kind: str, detail: str, severity: str = BLOCKING):
        self.kind, self.detail, self.severity = kind, detail, severity

    def as_dict(self) -> dict:
        return {"kind": self.kind, "detail": self.detail, "severity": self.severity}


def split_sections(body: str) -> dict:
    """Markdown headings -> {lowercased heading: [lines]}. Fenced blocks are
    skipped so a '# comment' inside a code fence is not read as a heading."""
    sections, current, fenced = {}, None, False
    for line in (body or "").splitlines():
        if FENCE_RE.match(line):
            fenced = not fenced
            if current is not None:
                sections[current].append(line)
            continue
        m = None if fenced else HEADING_RE.match(line)
        if m:
            current = m.group(1).strip().lower().rstrip(":").strip()
            sections.setdefault(current, [])
        elif current is not None:
            sections[current].append(line)
    return sections


def normalise_path(raw: str) -> str:
    """One canonical spelling per file, so 'src/app.py', './src/app.py' and
    '`src/app.py`' are one path and not three."""
    p = raw.strip().strip("`").strip().strip('"').strip("'")
    p = p.replace("\\", "/")
    while p.startswith("./"):
        p = p[2:]
    p = posixpath.normpath(p) if p else p
    return p.rstrip("/") if p not in ("", "/", ".") else p


def parse_files(lines: list, defects: list) -> list:
    files = []
    for line in lines:
        if not line.strip():
            continue
        m = BULLET_RE.match(line)
        if not m:
            # Prose inside the file list. Not fatal on its own, but the planner
            # is meant to emit bullets only.
            defects.append(Defect("files_prose", f"non-bullet line in Files touched: {line.strip()!r}", ADVISORY))
            continue
        entry = m.group(1).strip()
        token = entry.split()[0]
        if token != entry:
            defects.append(Defect("files_annotated",
                                  f"path entry carries extra text: {entry!r}; using {token!r}", ADVISORY))
        path = normalise_path(token)
        if not path:
            continue
        if path.startswith("/") or path.startswith("..") or path == ".":
            defects.append(Defect("files_bad_path", f"path escapes the repository: {entry!r}"))
            continue
        if path not in files:
            files.append(path)
    return files


def parse_acceptance(lines: list, defects: list):
    """ORCHESTRATOR.md: 'one shell command, nothing else'. Anything else is a
    planning defect that must be reported, not quietly skipped."""
    cleaned = []
    for line in lines:
        s = line.strip()
        if not s or FENCE_RE.match(line):
            continue
        if s.startswith("$ "):
            s = s[2:].strip()
        if s.startswith("`") and s.endswith("`") and len(s) > 1:
            s = s[1:-1].strip()
        cleaned.append(s)
    if not cleaned:
        defects.append(Defect("acceptance_missing", "no Acceptance criteria command found"))
        return None
    if len(cleaned) > 1:
        defects.append(Defect("acceptance_multiline",
                              "Acceptance criteria must be exactly one command, found "
                              f"{len(cleaned)} lines: {cleaned!r}"))
        return None
    cmd = cleaned[0]

    # Rule 1: a command does not end in a sentence-final full stop. 'pytest .'
    # ends in a dot too, but preceded by a space - that is an argument.
    if re.search(r"[A-Za-z0-9)\]]\.$", cmd) or cmd.endswith(":"):
        defects.append(Defect("acceptance_prose", f"reads as a sentence, not a command: {cmd!r}"))
        return None
    # Rule 2: two or more prose-only words outside quotes means a sentence.
    bare = QUOTED_RE.sub(" ", cmd)
    hits = [w for w in re.split(r"[\s;|&()]+", bare.lower()) if w in PROSE_WORDS]
    if len(hits) >= 2:
        defects.append(Defect("acceptance_prose",
                              f"reads as a sentence, not a command ({sorted(set(hits))}): {cmd!r}"))
        return None
    # Rule 3: the first token has to look like something executable.
    first = cmd.split()[0] if cmd.split() else ""
    if not re.match(r"^[A-Za-z0-9_@./+~$-]+$", first) or first.lower() in PROSE_WORDS:
        defects.append(Defect("acceptance_prose", f"first token is not a command: {cmd!r}"))
        return None
    try:
        shlex.split(cmd)
    except ValueError as e:
        defects.append(Defect("acceptance_unparseable", f"{e}: {cmd!r}"))
        return None
    return cmd


def parse_blockers(lines: list, number: int, defects: list) -> list:
    blockers, saw_text = [], False
    for line in lines:
        s = line.strip().lstrip("-*").strip()
        if not s:
            continue
        saw_text = True
        found = ISSUE_REF_RE.findall(s)
        if not found:
            # 'none', 'n/a', prose. The contract says omit the section instead.
            # Fail closed and report: guessing is how dependency handling
            # silently stops firing.
            defects.append(Defect("blockedby_unparseable",
                                  f"Blocked-by line has no #N reference: {s!r}; "
                                  "omit the section entirely when there are no blockers"))
            continue
        for n in found:
            n = int(n)
            if n == number:
                defects.append(Defect("blockedby_self", f"issue #{number} lists itself as a blocker"))
                continue
            if n not in blockers:
                blockers.append(n)
    if saw_text and not blockers and not any(d.kind.startswith("blockedby") for d in defects):
        defects.append(Defect("blockedby_unparseable", "Blocked-by section present but empty"))
    return blockers


class Ticket:
    def __init__(self, issue: dict):
        self.number   = int(issue["number"])
        self.title    = issue.get("title", "")
        self.state    = issue.get("state", "open")
        self.labels   = sorted({l for l in issue.get("labels", [])})
        self.body     = issue.get("body") or ""
        self.defects  = []

        sections = split_sections(self.body)
        files_sec = _section(sections, ("files touched", "files"))
        if files_sec is None:
            self.defects.append(Defect("files_missing", "no 'Files touched' section"))
            self.files = []
        else:
            self.files = parse_files(files_sec, self.defects)
            if not self.files:
                self.defects.append(Defect("files_empty", "'Files touched' section lists no paths"))

        acc_sec = _section(sections, ("acceptance criteria", "acceptance"))
        if acc_sec is None:
            self.defects.append(Defect("acceptance_missing", "no 'Acceptance criteria' section"))
            self.acceptance = None
        else:
            self.acceptance = parse_acceptance(acc_sec, self.defects)

        blk_sec = _section(sections, ("blocked-by", "blocked by"))
        self.blockers = parse_blockers(blk_sec, self.number, self.defects) if blk_sec is not None else []

        prio = [PRIORITY_RE.match(l) for l in self.labels]
        found = [int(m.group(1)) for m in prio if m]
        if found:
            self.priority = min(found)
        else:
            self.priority = 99
            self.defects.append(Defect("priority_missing", "no priority:N label", ADVISORY))

    @property
    def blocking_defects(self):
        return [d for d in self.defects if d.severity == BLOCKING]

    def has(self, label: str) -> bool:
        return label in self.labels

    def as_dict(self) -> dict:
        return {"issue": self.number, "priority": self.priority, "files": self.files,
                "acceptance": self.acceptance, "blocked_by": self.blockers,
                "labels": self.labels, "state": self.state}


def _section(sections: dict, names) -> list | None:
    for n in names:
        if n in sections:
            return sections[n]
    return None


# --------------------------------------------------------------------------- #
# file overlap - the property that makes parallelism safe
# --------------------------------------------------------------------------- #

def path_conflict(a: str, b: str) -> bool:
    """Two declared paths collide if they are the same file, or if one contains
    the other. Case-folded: 'src/App.py' and 'src/app.py' are the same file on
    a case-insensitive filesystem (macOS, Windows), and two workers editing
    them in parallel corrupt each other on checkout.

    Siblings do NOT collide: 'src/a.py' and 'src/b.py' run in parallel, which
    is the entire point of declaring files per ticket."""
    a, b = a.casefold(), b.casefold()
    if a == b:
        return True
    return a.startswith(b + "/") or b.startswith(a + "/")


def fileset_conflicts(files_a, files_b) -> list:
    return sorted({(a, b) for a in files_a for b in files_b if path_conflict(a, b)})


# --------------------------------------------------------------------------- #
# claims - the lock is a comment, not a label
# --------------------------------------------------------------------------- #

MARKER_RE = re.compile(r"<!--\s*(p4-[a-z]+)\s+(\{.*?\})\s*-->", re.S)


def markers(body: str):
    for m in MARKER_RE.finditer(body or ""):
        try:
            yield m.group(1), json.loads(m.group(2))
        except ValueError:
            continue


def make_marker(kind: str, payload: dict) -> str:
    return f"<!-- {kind} {json.dumps(payload, sort_keys=True, separators=(',', ':'))} -->"


class Claim:
    def __init__(self, comment_id: int, created_at: str, payload: dict):
        self.comment_id, self.created_at, self.payload = comment_id, created_at, payload
        self.nonce = payload.get("nonce", "")
        self.worker = payload.get("worker", "")

    def as_dict(self):
        return {"comment_id": self.comment_id, "created_at": self.created_at, **self.payload}


def active_claim(comments: list):
    """The claim on an issue is the earliest un-released claim comment.

    'Earliest' is decided by the comment id, which the server assigns and
    increases monotonically - the dispatcher never invents the ordering, so two
    dispatchers racing on the same issue agree on who won without a lock
    service."""
    claims, released = [], set()
    for c in sorted(comments, key=lambda c: int(c["id"])):
        for kind, payload in markers(c.get("body", "")):
            if kind == CLAIM_MARK:
                claims.append(Claim(int(c["id"]), c.get("created_at", ""), payload))
            elif kind == RELEASE_MARK:
                released.add(payload.get("nonce", ""))
    live = [c for c in claims if c.nonce not in released]
    return live[0] if live else None


def last_heartbeat(comments: list, nonce: str):
    stamp = None
    for c in sorted(comments, key=lambda c: int(c["id"])):
        for kind, payload in markers(c.get("body", "")):
            if kind == HEARTBEAT_MARK and payload.get("nonce", nonce) == nonce:
                stamp = c.get("created_at", stamp)
    return stamp


# --------------------------------------------------------------------------- #
# scheduling - pure function of repository state
# --------------------------------------------------------------------------- #

class Plan:
    def __init__(self):
        self.ready, self.skipped, self.defects, self.cycles = [], [], [], []
        self.concurrency = {}
        self.fatal = None

    def as_dict(self):
        return {
            "concurrency": self.concurrency,
            "dispatch": [{"issue": t.number, "priority": t.priority, "files": t.files,
                          "acceptance": t.acceptance} for t in self.ready],
            "skipped": self.skipped,
            "defects": self.defects,
            "cycles": self.cycles,
            "fatal": self.fatal,
        }


def find_cycles(tickets: dict) -> list:
    """Iterative DFS over the Blocked-by graph. Bounded by the number of edges,
    so a cycle is reported and the pass continues - it can never spin.

    Readiness itself never walks this graph (it only asks 'is that issue
    closed'), so a cycle cannot hang the loop even if this function did not
    exist. It exists so the deadlock is *reported* instead of looking like an
    ordinary, permanently blocked ticket."""
    colour, cycles, stack_pos = {}, [], {}
    for root in sorted(tickets):
        if colour.get(root):
            continue
        stack = [(root, iter(tickets[root].blockers))]
        colour[root], stack_pos[root] = 1, 0
        path = [root]
        while stack:
            node, it = stack[-1]
            advanced = False
            for nxt in it:
                if nxt not in tickets or tickets[nxt].state != "open":
                    continue
                if colour.get(nxt) == 1:  # back edge -> cycle
                    cyc = path[path.index(nxt):]
                    norm = tuple(sorted(cyc))
                    if norm not in [tuple(sorted(c)) for c in cycles]:
                        cycles.append(sorted(cyc))
                    continue
                if colour.get(nxt) in (None, 0):
                    colour[nxt] = 1
                    path.append(nxt)
                    stack.append((nxt, iter(tickets[nxt].blockers)))
                    advanced = True
                    break
            if not advanced:
                colour[node] = 2
                stack.pop()
                if path and path[-1] == node:
                    path.pop()
    return cycles


def build_plan(issues: list, comments_by_issue: dict, limit: int) -> Plan:
    """The whole scheduling decision. Deterministic, side-effect free."""
    plan = Plan()
    tickets = {}
    for raw in issues:
        t = Ticket(raw)
        tickets[t.number] = t

    for t in tickets.values():
        for d in t.defects:
            plan.defects.append({"issue": t.number, **d.as_dict()})

    for cyc in find_cycles(tickets):
        plan.cycles.append(cyc)
        for n in cyc:
            plan.defects.append({"issue": n, "kind": "dependency_cycle",
                                 "detail": "Blocked-by cycle: " + " -> ".join(f"#{x}" for x in cyc),
                                 "severity": BLOCKING})
    cycle_members = {n for cyc in plan.cycles for n in cyc}

    # --- what is already held -------------------------------------------------
    # A ticket is "held" if a worker is on it: the in-progress label, or an
    # un-released claim comment. The claim comment is the authoritative lock;
    # the label is its human-visible mirror (see P4-DISPATCH.md).
    held, held_files, unknown_files = {}, [], []
    for t in tickets.values():
        claim = active_claim(comments_by_issue.get(t.number, []))
        in_prog = t.has(LBL_IN_PROGRESS) and t.state == "open"
        if not (in_prog or (claim and t.state == "open")):
            continue
        held[t.number] = {"issue": t.number, "label": in_prog,
                          "claim": claim.as_dict() if claim else None}
        if t.files:
            held_files.append((t.number, t.files))
        else:
            unknown_files.append(t.number)

    if unknown_files:
        # We cannot know which files a running worker is editing, so no schedule
        # this pass is provably safe. Fail closed and say why.
        plan.fatal = ("in-progress issues declare no files: "
                      + ", ".join(f"#{n}" for n in sorted(unknown_files)))
        for n in unknown_files:
            plan.defects.append({"issue": n, "kind": "in_progress_unknown_files",
                                 "detail": "claimed ticket has no parseable Files touched; "
                                           "cannot prove disjointness, refusing to dispatch",
                                 "severity": BLOCKING})

    slots = max(0, limit - len(held))
    plan.concurrency = {"limit": limit, "held": len(held), "slots": slots,
                        "held_issues": sorted(held)}

    # --- candidate ordering: priority, then issue number ----------------------
    candidates = sorted((t for t in tickets.values() if t.state == "open"),
                        key=lambda t: (t.priority, t.number))

    reserved = list(held_files)  # files taken by this pass as it proceeds
    for t in candidates:
        if t.number in held:
            plan.skipped.append({"issue": t.number, "reason": "already_claimed",
                                 "detail": "a worker holds this ticket"})
            continue
        # Rule 1 - approval
        if not t.has(LBL_TODO):
            plan.skipped.append({"issue": t.number, "reason": "not_approved",
                                 "detail": f"labels={t.labels}"})
            continue
        if t.has(LBL_DONE):
            plan.skipped.append({"issue": t.number, "reason": "label_conflict",
                                 "detail": "carries status:todo and status:done"})
            continue
        # Rule 4 - a usable ticket (also covers the file list, which rule 3 needs)
        if t.blocking_defects:
            plan.skipped.append({"issue": t.number, "reason": "blocking_defect",
                                 "detail": "; ".join(f"{d.kind}: {d.detail}" for d in t.blocking_defects)})
            continue
        if t.number in cycle_members:
            plan.skipped.append({"issue": t.number, "reason": "dependency_cycle",
                                 "detail": "member of a Blocked-by cycle"})
            continue
        # Rule 2 - blockers closed
        open_blockers, unknown_blockers = [], []
        for b in t.blockers:
            bt = tickets.get(b)
            if bt is None:
                unknown_blockers.append(b)
            elif bt.state != "closed":
                open_blockers.append(b)
        if unknown_blockers:
            plan.defects.append({"issue": t.number, "kind": "blocker_unknown",
                                 "detail": "Blocked-by references issues not found in the repo: "
                                           + ", ".join(f"#{b}" for b in unknown_blockers),
                                 "severity": BLOCKING})
            plan.skipped.append({"issue": t.number, "reason": "blocker_unknown",
                                 "detail": ", ".join(f"#{b}" for b in unknown_blockers)})
            continue
        if open_blockers:
            plan.skipped.append({"issue": t.number, "reason": "blocked_by_open",
                                 "detail": ", ".join(f"#{b}" for b in sorted(open_blockers))})
            continue
        # Rule 3 - file disjointness, against held tickets AND against the
        # tickets already promoted in this same pass.
        clash = None
        for other, files in reserved:
            pairs = fileset_conflicts(t.files, files)
            if pairs:
                clash = (other, pairs)
                break
        if clash:
            other, pairs = clash
            plan.skipped.append({"issue": t.number, "reason": "file_conflict",
                                 "detail": f"#{other} on " + ", ".join(
                                     a if a == b else f"{a}~{b}" for a, b in pairs)})
            continue
        if plan.fatal:
            plan.skipped.append({"issue": t.number, "reason": "fatal",
                                 "detail": plan.fatal})
            continue
        if len(plan.ready) >= slots:
            plan.skipped.append({"issue": t.number, "reason": "no_slots",
                                 "detail": f"concurrency limit {limit} reached"})
            continue
        plan.ready.append(t)
        reserved.append((t.number, t.files))

    return plan


# --------------------------------------------------------------------------- #
# repository clients
# --------------------------------------------------------------------------- #

class RepoError(Exception):
    pass


class GitHubClient:
    """Live GitHub REST. Never tested against live GitHub in this repo - no
    credentials exist here - so every call it makes is listed in P4-DISPATCH.md
    under 'what is untested'."""

    def __init__(self, repo: str, token: str, api_root: str = API_ROOT):
        if not repo:
            raise RepoError("TARGET_REPO is not set")
        if not token:
            raise RepoError("TARGET_REPO_TOKEN is not set (put it in local.env)")
        self.repo, self.token, self.api = repo, token, api_root.rstrip("/")

    def _request(self, method: str, path: str, body=None, _attempt: int = 0):
        url = path if path.startswith("http") else f"{self.api}{path}"
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Authorization", f"Bearer {self.token}")
        req.add_header("Accept", "application/vnd.github+json")
        req.add_header("X-GitHub-Api-Version", "2022-11-28")
        req.add_header("User-Agent", "p4-dispatch-loop")
        if data is not None:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                payload = resp.read()
                parsed = json.loads(payload) if payload.strip() else None
                return parsed, dict(resp.headers)
        except urllib.error.HTTPError as e:
            retry_after = e.headers.get("Retry-After") if e.headers else None
            rate_left = (e.headers or {}).get("X-RateLimit-Remaining")
            transient = e.code >= 500 or e.code == 429 or (e.code == 403 and rate_left == "0")
            if transient and _attempt < 5:
                wait = float(retry_after) if retry_after else min(60, 2 ** _attempt) + random.random()
                log(f"github {e.code} on {method} {path}; backing off {wait:.1f}s")
                time.sleep(wait)
                return self._request(method, path, body, _attempt + 1)
            detail = e.read().decode("utf-8", "replace")[:300]
            raise RepoError(redact(f"{method} {path} -> {e.code}: {detail}"))
        except urllib.error.URLError as e:
            if _attempt < 3:
                time.sleep(2 ** _attempt)
                return self._request(method, path, body, _attempt + 1)
            raise RepoError(redact(f"{method} {path} -> {e}"))

    def _paged(self, path: str):
        out, page = [], 1
        while True:
            sep = "&" if "?" in path else "?"
            chunk, _ = self._request("GET", f"{path}{sep}per_page=100&page={page}")
            if not chunk:
                break
            out.extend(chunk)
            if len(chunk) < 100:
                break
            page += 1
            if page > 20:
                break
        return out

    def list_issues(self):
        raw = self._paged(f"/repos/{self.repo}/issues?state=all")
        issues = []
        for i in raw:
            if "pull_request" in i:      # the issues endpoint returns PRs too
                continue
            issues.append({"number": i["number"], "title": i.get("title", ""),
                           "state": i.get("state", "open"), "body": i.get("body") or "",
                           "labels": [l["name"] for l in i.get("labels", [])]})
        return issues

    def list_comments(self, number: int):
        raw = self._paged(f"/repos/{self.repo}/issues/{number}/comments")
        return [{"id": c["id"], "created_at": c["created_at"],
                 "body": c.get("body") or "", "user": (c.get("user") or {}).get("login", "")}
                for c in raw]

    def create_comment(self, number: int, body: str):
        c, _ = self._request("POST", f"/repos/{self.repo}/issues/{number}/comments",
                             {"body": body})
        return {"id": c["id"], "created_at": c["created_at"], "body": c.get("body", "")}

    def delete_comment(self, comment_id: int):
        self._request("DELETE", f"/repos/{self.repo}/issues/comments/{comment_id}")

    def add_labels(self, number: int, labels: list):
        self._request("POST", f"/repos/{self.repo}/issues/{number}/labels", {"labels": labels})

    def remove_label(self, number: int, label: str):
        enc = urllib.parse.quote(label, safe="")
        try:
            self._request("DELETE", f"/repos/{self.repo}/issues/{number}/labels/{enc}")
        except RepoError as e:
            if "404" not in str(e):
                raise

    def list_pulls(self):
        raw = self._paged(f"/repos/{self.repo}/pulls?state=all")
        return [{"number": p["number"], "state": p.get("state", "open"),
                 "head": (p.get("head") or {}).get("ref", ""),
                 "base": (p.get("base") or {}).get("ref", ""),
                 "body": p.get("body") or "", "title": p.get("title", ""),
                 "merged": bool(p.get("merged_at"))} for p in raw]

    def save(self):
        pass


class FixtureClient:
    """The same interface backed by a JSON file, so every scheduling decision is
    provable offline and repeatably. Mutations are applied in memory and, with
    --fixture-out, written back so a harness can assert on what changed."""

    def __init__(self, path: str, out: str | None = None, now: str | None = None):
        with open(path) as fh:
            self.data = json.load(fh)
        self.path, self.out = path, out
        self.repo = self.data.get("repo", "example/target")
        self.now = now
        self._next_comment_id = max(
            [int(c["id"]) for lst in self.data.get("comments", {}).values() for c in lst] + [1000]) + 1
        self._seq = 0
        for i in self.data.get("issues", []):
            if "body_lines" in i and "body" not in i:
                i["body"] = "\n".join(i["body_lines"])

    def _stamp(self):
        base = parse_ts(self.now) if self.now else utcnow()
        self._seq += 1
        return (base + dt.timedelta(seconds=self._seq)).strftime("%Y-%m-%dT%H:%M:%SZ")

    def list_issues(self):
        return [{"number": i["number"], "title": i.get("title", ""),
                 "state": i.get("state", "open"), "body": i.get("body", ""),
                 "labels": list(i.get("labels", []))} for i in self.data.get("issues", [])]

    def _issue(self, number: int):
        for i in self.data.get("issues", []):
            if int(i["number"]) == int(number):
                return i
        raise RepoError(f"fixture has no issue #{number}")

    def list_comments(self, number: int):
        return [dict(c) for c in self.data.setdefault("comments", {}).get(str(number), [])]

    def _inject_race(self, number: int):
        """Simulate a second dispatcher that claimed the same ticket in the
        window between our read and our write. Its comment gets the LOWER id,
        which is exactly the case a read-then-write check cannot detect."""
        spec = (self.data.get("race_claims") or {}).get(str(number))
        if not spec or spec.get("_fired"):
            return
        spec["_fired"] = True
        payload = {"nonce": spec.get("nonce", "0000"), "dispatcher": spec.get("dispatcher", "other"),
                   "issue": number, "worker": spec.get("worker", f"{WORKER_PREFIX}{number}")}
        c = {"id": self._next_comment_id, "created_at": self._stamp(),
             "body": make_marker(CLAIM_MARK, payload) + "\nClaimed by another dispatcher.",
             "user": "p4-other"}
        self._next_comment_id += 1
        self.data.setdefault("comments", {}).setdefault(str(number), []).append(c)

    def create_comment(self, number: int, body: str):
        self._inject_race(number)
        c = {"id": self._next_comment_id, "created_at": self._stamp(), "body": body,
             "user": "p4-dispatcher"}
        self._next_comment_id += 1
        self.data.setdefault("comments", {}).setdefault(str(number), []).append(c)
        return dict(c)

    def delete_comment(self, comment_id: int):
        for k, lst in self.data.setdefault("comments", {}).items():
            self.data["comments"][k] = [c for c in lst if int(c["id"]) != int(comment_id)]

    def add_labels(self, number: int, labels: list):
        i = self._issue(number)
        i["labels"] = sorted(set(i.get("labels", [])) | set(labels))

    def remove_label(self, number: int, label: str):
        i = self._issue(number)
        i["labels"] = [l for l in i.get("labels", []) if l != label]

    def list_pulls(self):
        return [dict(p) for p in self.data.get("pulls", [])]

    def save(self):
        if self.out:
            with open(self.out, "w") as fh:
                json.dump(self.data, fh, indent=2, sort_keys=True)


# --------------------------------------------------------------------------- #
# spawners - all of them go through the existing p1-dispatcher
# --------------------------------------------------------------------------- #

class SpawnError(Exception):
    pass


class HttpSpawner:
    """The ONLY way this program creates a container: POST /spawn to
    p1-dispatcher (SPAWNING-DECISION.md option (d)). It sends a name and a
    command; the create body is built on the other side from a hardened
    template, so nothing here can widen a worker's privileges."""

    def __init__(self, url: str = SPAWN_URL, token: str = SPAWN_TOKEN):
        self.url, self.token = url.rstrip("/"), token

    def _post(self, verb: str, payload: dict):
        req = urllib.request.Request(f"{self.url}{verb}", method="POST",
                                     data=json.dumps(payload).encode())
        req.add_header("Content-Type", "application/json")
        if self.token:
            req.add_header("Authorization", f"Bearer {self.token}")
        # The spawn dispatcher lives on the sandbox network, never through a proxy.
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        try:
            with opener.open(req, timeout=30) as resp:
                payload = resp.read()
                return resp.status, (json.loads(payload) if payload.strip() else {})
        except urllib.error.HTTPError as e:
            raise SpawnError(redact(f"{verb} -> {e.code}: {e.read().decode('utf-8', 'replace')[:200]}"))
        except urllib.error.URLError as e:
            raise SpawnError(redact(f"{verb} -> {e}"))

    def spawn(self, name: str, cmd: list):
        status, body = self._post("/spawn", {"name": name, "cmd": cmd})
        if status != 201:
            raise SpawnError(f"spawn returned {status}: {body}")
        return body

    def stop(self, name: str):
        try:
            self._post("/stop", {"name": name})
        except SpawnError as e:
            log(f"stop {name}: {e}")

    def remove(self, name: str):
        try:
            self._post("/remove", {"name": name})
        except SpawnError as e:
            log(f"remove {name}: {e}")


class RecordingSpawner:
    def __init__(self, path: str):
        self.path = path

    def _write(self, rec: dict):
        with open(self.path, "a") as fh:
            fh.write(json.dumps(rec, sort_keys=True) + "\n")

    def spawn(self, name, cmd):
        self._write({"verb": "spawn", "name": name, "cmd": cmd})
        return {"id": "recorded", "name": name}

    def stop(self, name):
        self._write({"verb": "stop", "name": name})

    def remove(self, name):
        self._write({"verb": "remove", "name": name})


class NullSpawner:
    def spawn(self, name, cmd):
        return {"id": "dry-run", "name": name}

    def stop(self, name):
        pass

    def remove(self, name):
        pass


class FailingSpawner:
    def spawn(self, name, cmd):
        raise SpawnError("spawn refused (simulated)")

    def stop(self, name):
        pass

    def remove(self, name):
        pass


# --------------------------------------------------------------------------- #
# claim / dispatch
# --------------------------------------------------------------------------- #

def worker_name(number: int) -> str:
    # Must satisfy p1-dispatcher's WORKER_NAME_PREFIX, which is 'p1-' by default;
    # 'p4w' keeps this experiment's containers identifiable inside that namespace.
    return f"{WORKER_PREFIX}{number}"


def worker_cmd(number: int, repo: str) -> list:
    cmd = json.loads(WORKER_CMD_TMPL)
    return [str(part).replace("{issue}", str(number)).replace("{repo}", repo) for part in cmd]


def dispatcher_id() -> str:
    return DISPATCHER_ID or f"p4-{os.getpid()}-{int(time.time())}"


def claim_and_spawn(client, spawner, ticket: Ticket, disp_id: str, repo: str) -> dict:
    """Claim a ticket, start its worker, then mark it in-progress.

    Ordering matters and is deliberate:

      1. re-read the issue and its comments (closes most of the read/act window),
      2. post a claim comment carrying a nonce,
      3. re-list the comments and keep the claim only if OURS is the earliest
         un-released one - the server's comment ids decide, not us,
      4. spawn the worker,
      5. only then relabel to status:in-progress.

    If the spawn fails we post a release marker and leave the labels untouched:
    the ticket is still status:todo, which no agent is permitted to set, so the
    dispatcher must never have to restore it.
    """
    number = ticket.number
    fresh = [i for i in client.list_issues() if int(i["number"]) == number]
    if not fresh:
        return {"issue": number, "claimed": False, "reason": "issue disappeared"}
    fresh_t = Ticket(fresh[0])
    if not fresh_t.has(LBL_TODO) or fresh_t.has(LBL_IN_PROGRESS) or fresh_t.state != "open":
        return {"issue": number, "claimed": False, "reason": "label changed under us"}
    existing = active_claim(client.list_comments(number))
    if existing:
        return {"issue": number, "claimed": False,
                "reason": f"already claimed by {existing.payload.get('dispatcher', '?')}"}

    nonce = "%016x" % random.getrandbits(64)
    name = worker_name(number)
    payload = {"nonce": nonce, "dispatcher": disp_id, "issue": number, "worker": name}
    body = (make_marker(CLAIM_MARK, payload) + "\n"
            f"Claimed by the dispatcher for worker `{name}`.\n\n"
            f"- files: {', '.join('`%s`' % f for f in ticket.files)}\n"
            f"- acceptance: `{ticket.acceptance}`\n\n"
            "If this worker goes silent it is released automatically after "
            f"{WORKER_TIMEOUT_M} minutes and the issue returns to `status:backlog` "
            "for a human to re-approve.")
    mine = client.create_comment(number, body)

    winner = active_claim(client.list_comments(number))
    if not winner or winner.nonce != nonce:
        # Someone else got there first. Withdraw and leave their claim alone.
        try:
            client.delete_comment(mine["id"])
        except Exception as e:                                  # noqa: BLE001
            log(f"#{number}: could not withdraw losing claim: {e}")
        return {"issue": number, "claimed": False,
                "reason": f"lost claim race to {winner.payload.get('dispatcher', '?') if winner else '?'}"}

    try:
        result = spawner.spawn(name, worker_cmd(number, repo))
    except SpawnError as e:
        client.create_comment(number, make_marker(RELEASE_MARK, {"nonce": nonce, "reason": "spawn_failed"})
                              + f"\nWorker could not be started: {redact(str(e))}. "
                                "The ticket keeps `status:todo` and will be retried on the next pass.")
        return {"issue": number, "claimed": False, "reason": f"spawn failed: {e}"}

    client.add_labels(number, [LBL_IN_PROGRESS])
    client.remove_label(number, LBL_TODO)
    client.remove_label(number, LBL_BLOCKED)
    return {"issue": number, "claimed": True, "worker": name, "nonce": nonce,
            "spawn": result}


def report_defects(client, plan: Plan) -> int:
    """Post each blocking defect once. A planner defect that is skipped in
    silence is indistinguishable from an ordinary blocked ticket, which is the
    failure this reporting exists to prevent."""
    posted = 0
    by_issue = {}
    for d in plan.defects:
        if d.get("severity") != BLOCKING:
            continue
        by_issue.setdefault(d["issue"], []).append(d)
    for number, defects in sorted(by_issue.items()):
        already = set()
        for c in client.list_comments(number):
            for kind, payload in markers(c.get("body", "")):
                if kind == DEFECT_MARK:
                    already.add(payload.get("kind", ""))
        fresh = [d for d in defects if d["kind"] not in already]
        if not fresh:
            continue
        lines = ["The dispatcher cannot schedule this ticket as written:", ""]
        lines += [f"- **{d['kind']}** — {d['detail']}" for d in fresh]
        lines += ["", "It has not been dispatched. Fix the issue body (see `ORCHESTRATOR.md` "
                      "→ Ticket format); the dispatcher picks it up on the next poll.",
                  "", "".join(make_marker(DEFECT_MARK, {"kind": d["kind"]}) for d in fresh)]
        client.create_comment(number, "\n".join(lines))
        posted += len(fresh)
    return posted


# --------------------------------------------------------------------------- #
# reaping - a worker that dies must not hold its ticket forever
# --------------------------------------------------------------------------- #

def reap(client, spawner, now: dt.datetime, timeout_minutes: int, pulls: list) -> list:
    """Release claims whose worker has gone silent.

    Liveness cannot be asked of the spawn dispatcher: its interface is three
    verbs and deliberately exposes no inventory, no /logs and no /wait. So the
    signal is time - the claim comment's server timestamp, refreshed by the
    worker's own heartbeat comments - and the action is: stop the container,
    say so on the issue, and drop the ticket to status:backlog. NOT to
    status:todo: re-approval is a human act, and a dispatcher that could
    re-approve work has removed the review gate.
    """
    actions = []
    issues = client.list_issues()
    for raw in issues:
        t = Ticket(raw)
        if t.state != "open":
            continue
        comments = client.list_comments(t.number)
        claim = active_claim(comments)
        if not claim and not t.has(LBL_IN_PROGRESS):
            continue
        if not claim:
            actions.append({"issue": t.number, "action": "none",
                            "reason": "in-progress without a claim comment (hand-labelled?)"})
            continue
        stamp = last_heartbeat(comments, claim.nonce) or claim.created_at
        age_min = (now - parse_ts(stamp)).total_seconds() / 60.0
        if age_min <= timeout_minutes:
            actions.append({"issue": t.number, "action": "none", "age_minutes": round(age_min, 1),
                            "reason": "claim is fresh"})
            continue
        open_pr = [p for p in pulls if pr_references(p, t.number) and p.get("state") == "open"]
        if open_pr:
            actions.append({"issue": t.number, "action": "none", "age_minutes": round(age_min, 1),
                            "reason": f"PR #{open_pr[0]['number']} is open and awaiting a human"})
            continue
        spawner.stop(claim.worker)
        spawner.remove(claim.worker)
        client.create_comment(
            t.number,
            make_marker(RELEASE_MARK, {"nonce": claim.nonce, "reason": "timeout"}) + "\n"
            f"Worker `{claim.worker}` produced nothing for {age_min:.0f} minutes "
            f"(timeout {timeout_minutes}m). Its container was stopped and removed and the "
            "claim released.\n\nThe ticket is now `status:backlog`. A human re-approving it "
            "(`status:todo`) is what restarts the work — the dispatcher will not re-approve "
            "its own ticket. Check the branch for partial work before restarting.")
        client.add_labels(t.number, [LBL_BACKLOG])
        client.remove_label(t.number, LBL_IN_PROGRESS)
        actions.append({"issue": t.number, "action": "released", "worker": claim.worker,
                        "age_minutes": round(age_min, 1)})
    return actions


def pr_references(pr: dict, number: int) -> bool:
    text = f"{pr.get('body', '')}\n{pr.get('title', '')}"
    if re.search(rf"#{number}\b", text):
        return True
    return bool(re.match(rf"^issue-{number}(-|$)", pr.get("head", "")))


# --------------------------------------------------------------------------- #
# validation of a finished worker
# --------------------------------------------------------------------------- #

def run_shell(cmd: str, cwd: str, timeout: int = 900):
    try:
        proc = subprocess.run(["/bin/sh", "-c", cmd], cwd=cwd, timeout=timeout,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        return proc.returncode, proc.stdout.decode("utf-8", "replace")[-4000:]
    except subprocess.TimeoutExpired:
        return 124, f"timed out after {timeout}s"
    except OSError as e:
        return 127, str(e)


def validate(client, number: int, checkout: str, base: str, test_command: str,
             run_code: bool = True) -> dict:
    """ORCHESTRATOR.md 'Validation': acceptance passes, diff touches only the
    declared files, full suite passes, PR exists and references the issue.

    It records what failed and repairs nothing - an agent quietly fixing another
    agent's output hides the failure this system exists to surface."""
    issues = [i for i in client.list_issues() if int(i["number"]) == number]
    if not issues:
        return {"issue": number, "ok": False, "checks": [
            {"name": "issue exists", "ok": False, "detail": "not found"}]}
    t = Ticket(issues[0])
    checks = []

    prs = [p for p in client.list_pulls() if pr_references(p, number)]
    pr = prs[0] if prs else None
    checks.append({"name": "pull request exists and references the issue",
                   "ok": bool(pr),
                   "detail": f"PR #{pr['number']} ({pr['head']})" if pr else
                             "no pull request references this issue"})
    branch = pr["head"] if pr else f"issue-{number}"
    if pr:
        expected = f"issue-{number}-"
        checks.append({"name": "branch follows issue-<number>-<slug>",
                       "ok": pr["head"].startswith(expected) or pr["head"] == f"issue-{number}",
                       "detail": pr["head"]})

    if t.acceptance is None:
        checks.append({"name": "acceptance command is parseable", "ok": False,
                       "detail": "; ".join(d.detail for d in t.defects if d.kind.startswith("acceptance"))})

    if checkout and os.path.isdir(os.path.join(checkout, ".git")):
        code, out = run_shell(f"git rev-parse --verify {shlex.quote(branch)}", checkout, 60)
        if code != 0:
            checks.append({"name": "branch exists in the checkout", "ok": False, "detail": out.strip()[:200]})
        else:
            code, mb = run_shell(f"git merge-base {shlex.quote(base)} {shlex.quote(branch)}", checkout, 60)
            merge_base = mb.strip().splitlines()[-1] if code == 0 else base
            code, out = run_shell(
                f"git diff --name-only {shlex.quote(merge_base)}..{shlex.quote(branch)}", checkout, 120)
            changed = [normalise_path(p) for p in out.splitlines() if p.strip()]
            stray = [p for p in changed
                     if not any(path_conflict(p, d) for d in t.files)]
            checks.append({"name": "diff touches only the declared files",
                           "ok": not stray and code == 0,
                           "detail": ("undeclared: " + ", ".join(stray)) if stray
                                     else f"{len(changed)} file(s), all declared"})
            if run_code:
                code, out = run_shell(f"git checkout --quiet {shlex.quote(branch)}", checkout, 120)
                if t.acceptance:
                    rc, out = run_shell(t.acceptance, checkout)
                    checks.append({"name": f"acceptance command passes ({t.acceptance})",
                                   "ok": rc == 0, "detail": f"exit {rc}\n{out.strip()[-800:]}"})
                if test_command:
                    rc, out = run_shell(test_command, checkout)
                    checks.append({"name": f"full test suite passes ({test_command})",
                                   "ok": rc == 0, "detail": f"exit {rc}\n{out.strip()[-800:]}"})
                else:
                    checks.append({"name": "full test suite passes", "ok": False,
                                   "detail": "P4_TEST_COMMAND is not configured; the contract "
                                             "requires the whole suite to run, so this counts as "
                                             "a failure rather than a skip"})
    else:
        checks.append({"name": "checkout available for verification", "ok": False,
                       "detail": f"{checkout or '<unset>'} is not a git checkout"})

    ok = all(c["ok"] for c in checks)
    return {"issue": number, "ok": ok, "branch": branch, "checks": checks,
            "declared_files": t.files}


def record_validation(client, result: dict) -> None:
    number = result["issue"]
    lines = [make_marker(REPORT_MARK, {"ok": result["ok"], "issue": number}),
             ("**Validation passed.**" if result["ok"] else "**Validation FAILED.**"), ""]
    for c in result["checks"]:
        lines.append(f"- {'PASS' if c['ok'] else 'FAIL'} — {c['name']}")
        if c.get("detail") and not c["ok"]:
            detail = redact(c["detail"]).strip()
            lines.append("  ```\n  " + "\n  ".join(detail.splitlines()[:20]) + "\n  ```")
    if result["ok"]:
        lines += ["", "The ticket stays `status:in-progress` until the pull request is merged: "
                      "its files remain reserved so no other worker edits them under an unmerged "
                      "branch. A human merges and sets `status:done`."]
    else:
        lines += ["", "The dispatcher does not repair worker output. The ticket has been moved to "
                      "`status:backlog`; a human decides whether to re-approve it (`status:todo`) "
                      "for another attempt."]
    client.create_comment(number, "\n".join(lines))
    if not result["ok"]:
        comments = client.list_comments(number)
        claim = active_claim(comments)
        if claim:
            client.create_comment(number, make_marker(
                RELEASE_MARK, {"nonce": claim.nonce, "reason": "validation_failed"})
                + "\nClaim released after failed validation.")
        client.add_labels(number, [LBL_BACKLOG])
        client.remove_label(number, LBL_IN_PROGRESS)


# --------------------------------------------------------------------------- #
# wiring
# --------------------------------------------------------------------------- #

def make_client(args):
    src = args.source
    if src == "github":
        return GitHubClient(REPO, TOKEN)
    if src.startswith("fixture:"):
        return FixtureClient(src.split(":", 1)[1], getattr(args, "fixture_out", None),
                             getattr(args, "now", None))
    raise RepoError(f"unknown --source {src!r}")


def make_spawner(spec: str):
    if spec == "http":
        return HttpSpawner()
    if spec == "none":
        return NullSpawner()
    if spec == "fail":
        return FailingSpawner()
    if spec.startswith("record:"):
        return RecordingSpawner(spec.split(":", 1)[1])
    raise SpawnError(f"unknown --spawn {spec!r}")


def acquire_lock(path: str):
    """One dispatch pass per host at a time. Two passes overlapping is the
    cheapest way to double-dispatch a ticket, and it is prevented here rather
    than detected later."""
    fh = open(path, "w")
    try:
        fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        fh.close()
        return None
    fh.write(str(os.getpid()))
    fh.flush()
    return fh


def gather(client):
    issues = client.list_issues()
    comments = {}
    for i in issues:
        n = int(i["number"])
        # Comments are only read where a claim could exist: open issues. Closed
        # ones cannot hold a lock, and one API call per issue per poll is the
        # dominant cost of a pass.
        comments[n] = client.list_comments(n) if i.get("state", "open") == "open" else []
    return issues, comments


def cmd_plan(args) -> int:
    client = make_client(args)
    issues, comments = gather(client)
    plan = build_plan(issues, comments, args.limit)
    print(json.dumps(plan.as_dict(), indent=2, sort_keys=True))
    return EXIT_OK


def one_pass(args, client, spawner, disp_id: str) -> dict:
    issues, comments = gather(client)
    plan = build_plan(issues, comments, args.limit)
    repo = getattr(client, "repo", REPO)
    outcome = {"plan": plan.as_dict(), "claims": [], "reap": [], "defects_reported": 0}

    if not args.no_report:
        outcome["defects_reported"] = report_defects(client, plan)

    for ticket in plan.ready:
        res = claim_and_spawn(client, spawner, ticket, disp_id, repo)
        outcome["claims"].append(res)
        log(f"#{ticket.number} {'dispatched to ' + res['worker'] if res['claimed'] else 'NOT claimed: ' + res['reason']}")

    if args.reap:
        now = parse_ts(args.now) if args.now else utcnow()
        outcome["reap"] = reap(client, spawner, now, args.timeout, client.list_pulls())
    client.save()
    return outcome


def cmd_dispatch(args) -> int:
    lock = acquire_lock(args.lock)
    if lock is None:
        log(f"another dispatch pass holds {args.lock}; exiting without acting")
        return EXIT_LOCKED
    client = make_client(args)
    spawner = make_spawner(args.spawn)
    disp_id = dispatcher_id()
    try:
        while True:
            outcome = one_pass(args, client, spawner, disp_id)
            print(json.dumps(outcome, indent=2, sort_keys=True))
            if not args.interval:
                return EXIT_OK
            time.sleep(args.interval)
    finally:
        lock.close()


def cmd_reap(args) -> int:
    lock = acquire_lock(args.lock)
    if lock is None:
        log(f"another dispatch pass holds {args.lock}; exiting without acting")
        return EXIT_LOCKED
    try:
        client = make_client(args)
        spawner = make_spawner(args.spawn)
        now = parse_ts(args.now) if args.now else utcnow()
        actions = reap(client, spawner, now, args.timeout, client.list_pulls())
        client.save()
        print(json.dumps({"reap": actions}, indent=2, sort_keys=True))
        return EXIT_OK
    finally:
        lock.close()


def cmd_validate(args) -> int:
    client = make_client(args)
    result = validate(client, args.issue, args.checkout, args.base,
                      args.test_command, run_code=not args.no_run)
    if not args.dry_run:
        record_validation(client, result)
    client.save()
    print(redact(json.dumps(result, indent=2, sort_keys=True)))
    return EXIT_OK if result["ok"] else EXIT_FAIL


def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="p4-dispatch-loop", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    def common(sp):
        sp.add_argument("--source", default="github",
                        help="github | fixture:<path.json>")
        sp.add_argument("--fixture-out", help="write the mutated fixture here (fixture source only)")
        sp.add_argument("--now", help="ISO timestamp to use as 'now' (fixtures/tests)")

    sp = sub.add_parser("plan", help="compute the schedule; mutates nothing")
    common(sp)
    sp.add_argument("--limit", type=int, default=MAX_CONCURRENCY)
    sp.set_defaults(func=cmd_plan)

    sp = sub.add_parser("dispatch", help="claim ready tickets and spawn their workers")
    common(sp)
    sp.add_argument("--limit", type=int, default=MAX_CONCURRENCY)
    sp.add_argument("--spawn", default="http", help="http | record:<file> | none | fail")
    sp.add_argument("--interval", type=int, default=0, help="poll every N seconds (0 = one pass)")
    sp.add_argument("--lock", default=LOCK_PATH)
    sp.add_argument("--reap", action="store_true", help="also release timed-out claims")
    sp.add_argument("--timeout", type=int, default=WORKER_TIMEOUT_M)
    sp.add_argument("--no-report", action="store_true", help="do not comment defects")
    sp.set_defaults(func=cmd_dispatch)

    sp = sub.add_parser("reap", help="release claims whose worker went silent")
    common(sp)
    sp.add_argument("--spawn", default="http")
    sp.add_argument("--timeout", type=int, default=WORKER_TIMEOUT_M)
    sp.add_argument("--lock", default=LOCK_PATH)
    sp.set_defaults(func=cmd_reap)

    sp = sub.add_parser("validate", help="validate one finished ticket")
    common(sp)
    sp.add_argument("--issue", type=int, required=True)
    sp.add_argument("--checkout", default=os.environ.get("P4_CHECKOUT", ""))
    sp.add_argument("--base", default=os.environ.get("P4_BASE_BRANCH", "main"))
    sp.add_argument("--test-command", default=TEST_COMMAND)
    sp.add_argument("--no-run", action="store_true", help="metadata checks only, run no code")
    sp.add_argument("--dry-run", action="store_true", help="do not comment the result")
    sp.set_defaults(func=cmd_validate)

    args = p.parse_args(argv)
    try:
        return args.func(args)
    except (RepoError, SpawnError) as e:
        log(f"error: {e}")
        return EXIT_USAGE


if __name__ == "__main__":
    sys.exit(main())

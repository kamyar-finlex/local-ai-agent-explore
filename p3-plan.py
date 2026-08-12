#!/usr/bin/env python3
"""
p3-plan.py - the planner. A SCRIPT owns the control flow; the model supplies
judgement, one decision at a time, as JSON.

WHY IT IS SHAPED THIS WAY
-------------------------
An earlier design handed the model a seven-phase procedure and asked it to
follow it. Across four live runs with a 20B local model it failed differently
every time: it improvised (git status, greps, a clone, browser automation)
instead of starting; it diagnosed "network blocked" from `curl | jq` exiting 127
because jq is absent; it wrote the application under test into its own data
directory -- and when the write_file tool was removed it used
`bash -c "cat > file"` instead; it burned turns trying to install pytest; it
stopped after one ticket and handed the human a numbered list; and finally it
printed a confident five-ticket plan when the ledger held two, fabricating three
tickets in prose.

The pattern is consistent: where the SCRIPT owns control the output has never
once been malformed; where the MODEL owns control it drifts. So control is
inverted. `p3-plan.py plan` runs the entire loop itself:

  1. init the ledger, fetch the spec issue and the target README
  2. ask the model ONCE for the file layout
  3. loop: ask for the NEXT ticket -> validate -> record -> repeat, until every
     layout path is claimed or a budget is hit
  4. lint the whole plan
  5. emit to GitHub, link sub-issues, record the numbers
  6. verify what actually exists

Every model call is small, single-purpose, stateless, and constrained to a JSON
object whose schema is printed in the prompt. The reply is validated on receipt;
a malformed or schema-violating reply is retried with the parse error fed back,
and when the retries are exhausted the script STOPS and prints the raw string.
It never invents a ticket to fill a gap -- that is precisely the failure being
designed out.

The model never sees a shell, never writes a file, and never decides when to
stop.

The ledger, the renderer and the emitter below are unchanged from the version
that has never produced a malformed ticket, and the model still supplies fields
rather than markdown: the contract's sections and labels are an f-string.

Stdlib only: the agent container has python3, curl and git, but NOT `gh` and NOT
`jq` (both measured), so GitHub is reached over the REST API with urllib, which
honours HTTPS_PROXY and therefore works through the egress allowlist. The
inference call deliberately does NOT go through that proxy -- see model_opener().

Usage:
  p3-plan.py plan      --repo owner/name --spec 7          # the whole loop
  p3-plan.py plan      --repo owner/name --spec 7 --dry-run \
                       --spec-file S.md --readme-file R.md # offline, no GitHub
  p3-plan.py measure   --calls 20 [--kind ticket|layout]   # JSON validity rate

  p3-plan.py init      --repo owner/name --spec 7          # the manual steps,
  p3-plan.py spec-show                                     # still available for
  p3-plan.py layout    --path src/app.py --path ...        # repair and resume
  p3-plan.py add       --id T1 --title "..." --priority 1 \
                       --files src/x.py,tests/test_x.py \
                       --acceptance "pytest -q tests/test_x.py" \
                       --goal "..." --details "..." [--blocked-by T0]
  p3-plan.py list | status | next
  p3-plan.py render    T1
  p3-plan.py emit      --id T1 | --all [--dry-run]

Exit codes:
  0  success
  1  usage / validation / GitHub error
  3  the model could not produce a valid decision (loud stop, raw reply printed)
  4  the loop hit a budget with layout paths still unclaimed

Environment:
  GITHUB_TOKEN     required for spec-show and a real emit; never logged.
  HTTPS_PROXY      honoured automatically by urllib for the GitHub calls.
  P3_MODEL_URL     OpenAI-compatible chat endpoint.
                   default http://ollama-gate:11434/v1/chat/completions
                   (from the host it is http://127.0.0.1:11434/v1/chat/completions)
  P3_MODEL         model tag, default gpt-oss:20b-64k
  P3_MODEL_KEY     bearer token for the endpoint, default "ollama" (Ollama
                   ignores it but OpenAI clients demand a non-empty value)
  P3_MODEL_TIMEOUT seconds per call, default 600
  P3_MODEL_RETRIES retries after a rejected reply, default 3
  P3_MODEL_MAX_TOKENS  default 2048
  P3_MODEL_JSON_MODE   1 (default) sends response_format=json_object; 0 omits it
  P3_MODEL_USE_PROXY   1 routes inference through HTTPS_PROXY; default 0
  P3_PLAN_DIR      ledger directory, default $HERMES_HOME/plan (writable by the agent)
"""

import argparse
import hashlib
import json
import os
import re
import shlex
import subprocess
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

# The seven fields the model is asked for. Everything else on a ticket -- the id,
# the labels, the markdown -- is the script's, because it is bookkeeping rather
# than judgement.
MODEL_TICKET_FIELDS = ("title", "priority", "files", "blocked_by",
                       "acceptance", "goal", "details")

EXIT_MODEL = 3
EXIT_BUDGET = 4


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
        self.emitted = {}      # id -> {"number": int, "node": int}
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
            # "modelcall" records are an audit trail only; nothing replays them.

    def append(self, rec):
        os.makedirs(self.dir, exist_ok=True)
        rec.setdefault("ts", int(time.time()))
        with open(self.path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(rec, sort_keys=True) + "\n")
            fh.flush()
            os.fsync(fh.fileno())

    def add_ticket(self, rec):
        """Append a ticket AND update the replayed state, so a long-running
        `plan` sees the same picture a fresh process would."""
        self.append(rec)
        if rec["id"] not in self.tickets:
            self.order.append(rec["id"])
        self.tickets[rec["id"]] = rec

    def ticket_list(self):
        return [self.tickets[i] for i in self.order]

    def claimed(self):
        """path -> the id of the ticket that first claimed it."""
        out = {}
        for t in self.ticket_list():
            for p in t["files"]:
                out.setdefault(p, t["id"])
        return out

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


def sha(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


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
# field validation - one ticket at a time, at the moment it is proposed
#
# Shared by `add` (a human or a shell caller) and by the plan loop (the model),
# so the model is held to exactly the rules the manual path is held to. Every
# function returns an error STRING or None; the caller decides whether that is a
# `die` or a retry prompt.
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


def build_ticket(plan, tid, obj, max_files=4, enforce_layout=True):
    """Turn a proposal into a ledger record, or explain why it is not one.

    `obj` is a plain dict of the seven MODEL_TICKET_FIELDS -- from argparse in
    `add`, from parsed model JSON in the plan loop. Returns (record, None) or
    (None, "why not"). The record contains NOTHING that did not come from `obj`
    except the id, which is the script's bookkeeping.
    """
    for k in MODEL_TICKET_FIELDS:
        if k not in obj:
            return None, f"missing key {k!r}; the reply must carry all of {list(MODEL_TICKET_FIELDS)}"

    if not ID_RE.match(tid):
        return None, "id must look like T1, T2, ... (GitHub numbers are assigned later)"
    if tid in plan.tickets:
        return None, f"{tid} already exists -- pick the next free id"

    prio = obj["priority"]
    if isinstance(prio, str) and prio.strip().isdigit():
        prio = int(prio.strip())
    if not isinstance(prio, int) or isinstance(prio, bool) or prio not in PRIORITIES:
        return None, "priority must be 1, 2, 3 or 4 (a number, not a label or a list)"

    if not isinstance(obj["title"], str):
        return None, "title must be a string"
    title = obj["title"].strip()
    if not title or len(title) > 72:
        return None, f"title must be 1-72 characters (got {len(title)})"

    files = obj["files"]
    if isinstance(files, str):
        files = [p.strip() for p in files.split(",") if p.strip()]
    if not isinstance(files, list) or not all(isinstance(p, str) for p in files):
        return None, "files must be a list of path strings"
    files = [p.strip() for p in files if p.strip()]
    err = check_files(files)
    if err:
        return None, f"files: {err}"
    if max_files and len(files) > max_files:
        return None, (f"files lists {len(files)} paths (limit {max_files}); that is more "
                      "than one concern -- split the ticket")
    if enforce_layout and plan.layout:
        stray = [p for p in files if p not in plan.layout]
        if stray:
            return None, (f"{stray[0]} is not in the recorded file layout; a ticket may only "
                          "touch paths the layout already lists")

    blockers = obj["blocked_by"]
    if blockers is None:
        blockers = []
    if isinstance(blockers, str):
        blockers = [b.strip() for b in blockers.split(",") if b.strip()]
    if not isinstance(blockers, list) or not all(isinstance(b, str) for b in blockers):
        return None, "blocked_by must be a list of ticket ids such as [\"T1\"], or []"
    blockers = [b.strip() for b in blockers if b.strip()]
    if len(set(blockers)) != len(blockers):
        return None, "blocked_by lists the same ticket twice"
    for b in blockers:
        if b == tid:
            return None, f"{tid} cannot block itself"
        if b not in plan.tickets:
            return None, (f"blocked_by {b} does not exist yet; only tickets already in the "
                          "plan may be listed")

    if not isinstance(obj["acceptance"], str):
        return None, "acceptance must be a single shell command, as a string"
    err = check_acceptance(obj["acceptance"])
    if err:
        return None, f"acceptance {err}"

    # An acceptance command that runs a file this ticket does not create cannot
    # pass when the ticket is done. Observed live: a foundation ticket creating
    # pyproject.toml whose acceptance ran another ticket's test file. Every other
    # check passed it, because "one command" was all any of them asked.
    # Deliberately conservative: only tokens that are literally layout paths are
    # judged, so a make target or `python -c` is never second-guessed.
    if plan.layout:
        owned = set(files)
        for anc in ancestors(plan, blockers):
            owned |= set(plan.tickets[anc]["files"])
        try:
            toks = shlex.split(obj["acceptance"])
        except ValueError:
            toks = []
        foreign = [t for t in toks if t in plan.layout and t not in owned]
        if foreign:
            return None, (f"acceptance runs {foreign[0]}, which this ticket does not create "
                          "and no ticket it is blocked by creates either -- it cannot pass "
                          "when this ticket is done. Name a file this ticket creates, or add "
                          "the owner to blocked_by")

    if not isinstance(obj["goal"], str) or not isinstance(obj["details"], str):
        return None, "goal and details must be strings"
    goal = obj["goal"].strip()
    details = obj["details"].strip()
    if not goal:
        return None, "goal is required (one sentence)"
    if "\n" in goal:
        return None, "goal must be one sentence on one line"
    if len(details) < 20:
        return None, ("details is too thin for a worker that has read only the README and "
                      "this one issue; write 40-80 words")

    # Overlap is a PLANNING failure, so catch it here rather than at dispatch.
    # A new ticket is forced apart in time only from its own transitive
    # blockers; every other existing ticket could be in flight beside it.
    earlier = ancestors(plan, blockers)
    for other in plan.ticket_list():
        if other["id"] in earlier:
            continue
        shared = sorted(set(files) & set(other["files"]))
        if shared:
            return None, (f"{shared[0]} is already claimed by {other['id']}; two tickets that "
                          f"can run at the same time must not share a file -- either add "
                          f"{other['id']} to blocked_by to chain them, or give this ticket "
                          "its own file")

    return {"kind": "ticket", "id": tid, "title": title, "priority": prio,
            "files": files, "blocked_by": blockers,
            "acceptance": obj["acceptance"].strip(),
            "goal": goal, "details": details}, None


def validate_layout(obj, min_paths=3, max_paths=40):
    """Checks the ONE layout reply. Mutates obj["paths"] to the cleaned list."""
    if not isinstance(obj, dict) or "paths" not in obj:
        return "missing key 'paths'; the reply must be {\"paths\": [\"...\"]}"
    paths = obj["paths"]
    if isinstance(paths, str):
        paths = [p.strip() for p in paths.split(",") if p.strip()]
    if not isinstance(paths, list) or not all(isinstance(p, str) for p in paths):
        return "'paths' must be a list of path strings"
    paths = [p.strip() for p in paths if p.strip()]
    if len(paths) < min_paths:
        return (f"only {len(paths)} path(s); a complete layout names every file the finished "
                f"project has, which is at least {min_paths}")
    if len(paths) > max_paths:
        return f"{len(paths)} paths is more than {max_paths}; name files, not every future idea"
    err = check_files(paths)
    if err:
        return f"paths: {err}"
    obj["paths"] = paths
    return None


# --------------------------------------------------------------------------- #
# model client - OpenAI-compatible chat, stdlib urllib, one decision per call
# --------------------------------------------------------------------------- #

MODEL_URL_DEFAULT = "http://ollama-gate:11434/v1/chat/completions"
MODEL_DEFAULT = "gpt-oss:20b-64k"

FENCE_RE = re.compile(r"```(?:json)?\s*(.*?)```", re.S)


class ModelError(Exception):
    """A transport-level failure: no reply to judge, so there is nothing to feed
    back. Distinct from a reply that arrived and was wrong."""


class EmptyReply(ModelError):
    """The call succeeded and the assistant message was empty. On a reasoning
    model this means the generation budget was spent thinking, which is neither a
    transport fault nor a bad answer -- it is its own failure mode, and it was
    frequent enough in measurement to deserve its own name."""


def model_cfg(a):
    def env_int(name, default):
        try:
            return int(os.environ.get(name, default))
        except ValueError:
            die(f"{name} must be an integer")
    return {
        "url": a.endpoint or os.environ.get("P3_MODEL_URL") or MODEL_URL_DEFAULT,
        "model": a.model or os.environ.get("P3_MODEL") or MODEL_DEFAULT,
        "temperature": a.temperature,
        "max_tokens": env_int("P3_MODEL_MAX_TOKENS", 2048),
        "timeout": env_int("P3_MODEL_TIMEOUT", 600),
        "retries": a.retries if a.retries is not None else env_int("P3_MODEL_RETRIES", 3),
        "json_mode": os.environ.get("P3_MODEL_JSON_MODE", "1") != "0",
    }


def model_opener():
    """The gate is a plain-http host on the isolated network; HTTPS_PROXY is set
    so the GitHub calls can leave through the egress allowlist. Sending
    inference through squid would be denied by that allowlist and looks exactly
    like "the model is down", so this opener has proxies explicitly disabled."""
    if os.environ.get("P3_MODEL_USE_PROXY") == "1":
        return urllib.request.build_opener()
    return urllib.request.build_opener(urllib.request.ProxyHandler({}))


def chat(messages, cfg):
    """One completion. Returns the assistant's content string, or raises."""
    body = {"model": cfg["model"], "messages": messages, "stream": False,
            "temperature": cfg["temperature"], "max_tokens": cfg["max_tokens"]}
    if cfg["json_mode"]:
        body["response_format"] = {"type": "json_object"}
    req = urllib.request.Request(cfg["url"], data=json.dumps(body).encode(), method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("Authorization", "Bearer " + os.environ.get("P3_MODEL_KEY", "ollama"))
    req.add_header("User-Agent", "p3-planner")
    try:
        with model_opener().open(req, timeout=cfg["timeout"]) as r:
            payload = json.loads(r.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:300]
        raise ModelError(f"HTTP {e.code} from the model endpoint: {detail}")
    except urllib.error.URLError as e:
        raise ModelError(f"model endpoint {cfg['url']} unreachable: {e.reason}")
    except ValueError as e:
        raise ModelError(f"the model endpoint did not return JSON: {e}")
    except OSError as e:
        raise ModelError(f"model endpoint {cfg['url']} failed: {e}")
    try:
        msg = payload["choices"][0]["message"]
    except (KeyError, IndexError, TypeError):
        raise ModelError("reply has no choices[0].message: " + json.dumps(payload)[:300])
    content = (msg.get("content") or "").strip()
    if not content:
        # gpt-oss is a reasoning model: an empty content with a full reasoning
        # field means the token budget was spent thinking. Say so, because the
        # remedy (raise P3_MODEL_MAX_TOKENS) is not obvious from "empty reply".
        reasoned = len((msg.get("reasoning") or msg.get("reasoning_content") or ""))
        raise EmptyReply(f"the model spent its whole generation budget reasoning and "
                         f"returned no answer ({reasoned} chars of reasoning, "
                         f"max_tokens={cfg['max_tokens']})")
    return content


def extract_json(raw):
    """(obj, None) or (None, reason).

    Tolerant of a ```json fence and of a leading preamble, because neither is a
    fabrication -- the JSON is still the model's. NOT tolerant of truncated or
    absent JSON, which is the case that must reach the retry loop.
    """
    candidates = [raw.strip()]
    m = FENCE_RE.search(raw)
    if m:
        candidates.append(m.group(1).strip())
    s, e = raw.find("{"), raw.rfind("}")
    if s != -1 and e > s:
        candidates.append(raw[s:e + 1])
    reason = "no JSON object in the reply"
    for c in candidates:
        if not c:
            continue
        try:
            obj = json.loads(c)
        except ValueError as ex:
            reason = f"the reply is not valid JSON ({ex})"
            continue
        if isinstance(obj, dict):
            return obj, None
        reason = f"top-level JSON is a {type(obj).__name__}, expected an object"
    return None, reason


def ask(cfg, kind, messages, validate, plan=None, stats=None):
    """Ask for ONE decision. Retry with the rejection fed back; then stop LOUDLY.

    `validate(obj)` returns None or an error string; it is the only thing that
    decides whether a reply is usable. There is no path here that returns a
    value the model did not send.
    """
    attempts = cfg["retries"] + 1
    convo = list(messages)
    last_raw = ""
    for n in range(1, attempts + 1):
        try:
            raw = chat(convo, cfg)
        except ModelError as e:
            why = "empty" if isinstance(e, EmptyReply) else "transport"
            last_raw = f"<no reply: {e}>"
            record_call(plan, kind, n, None, f"{why}: {e}")
            if stats is not None:
                stats.append((why, str(e)))
            if n == attempts:
                break
            time.sleep(min(2 ** (n - 1), 8))
            continue
        obj, err = extract_json(raw)
        why = "json" if err else None
        if err is None:
            err = validate(obj)
            if err:
                why = "schema"
        last_raw = raw
        record_call(plan, kind, n, raw, err)
        if stats is not None:
            stats.append(("ok", "") if err is None else (why, err))
        if err is None:
            return obj, raw
        print(f"    reply {n}/{attempts} rejected: {err}", file=sys.stderr)
        convo = convo + [
            {"role": "assistant", "content": raw[:4000]},
            {"role": "user", "content":
                f"REJECTED: {err}\n"
                "Reply again with ONLY the JSON object described above. "
                "No prose, no explanation, no markdown fence."},
        ]
    die(f"the model did not produce a usable {kind} in {attempts} attempt(s).\n"
        f"Nothing was invented to fill the gap and no ticket was skipped; the plan "
        f"stops here so a human can see what the model actually said.\n"
        f"--- last raw reply ---\n{last_raw}\n--- end of raw reply ---",
        code=EXIT_MODEL)


def record_call(plan, kind, attempt, raw, err):
    """Audit trail. The raw text is NOT stored -- its sha256 is, which is what
    the harness needs to prove a ledger ticket came from a real reply."""
    if plan is None:
        return
    plan.append({"kind": "modelcall", "call": kind, "attempt": attempt,
                 "sha256": sha(raw) if raw is not None else None,
                 "chars": len(raw) if raw is not None else 0,
                 "head": (raw[:160] if raw is not None else ""),
                 "error": err})


# --------------------------------------------------------------------------- #
# prompts - one decision each, everything the model needs in the one message
# --------------------------------------------------------------------------- #

SYSTEM = ("You are a planning function inside a script. You do not run commands, "
          "read files, or write code. You answer with exactly one JSON object and "
          "nothing else: no prose, no explanation, no markdown fence.")

LAYOUT_SCHEMA = '{"paths": ["<repo-relative file path>", "..."]}'

TICKET_SCHEMA = ('{"title": "<= 72 chars", "priority": 1, '
                 '"files": ["<path from the layout>"], "blocked_by": ["T1"], '
                 '"acceptance": "<one shell command>", '
                 '"goal": "<one sentence on one line>", '
                 '"details": "<40-80 words for the worker>"}')


def clip(text, n, label):
    text = (text or "").strip()
    if len(text) <= n:
        return text
    return text[:n] + f"\n[...{label} truncated at {n} characters...]"


def layout_prompt(spec_text, readme_text, min_paths, max_paths):
    user = f"""TASK: choose the complete file layout for a project that does not exist yet.

SPECIFICATION (the issue being planned):
{clip(spec_text, 6000, 'spec')}

TARGET README (the project's own specification):
{clip(readme_text, 8000, 'README')}

RULES
- Name every file the FINISHED project contains: the dependency/config manifest,
  every source file, and one test file per source file.
- Repo-relative paths only. No leading "/", no "..", no directory names -- every
  entry must be a file.
- Follow the conventions of the stack the README names and nothing more ambitious.
- One concern per file. A file is the unit of concurrency, so two concerns in one
  file means two tickets that cannot run at the same time.
- No file called utils: a file with no single owner attracts edits from every
  ticket and serialises the whole plan.
- Never list README.md, and nothing under .git.
- Between {min_paths} and {max_paths} paths.

REPLY WITH EXACTLY THIS JSON SHAPE AND NOTHING ELSE:
{LAYOUT_SCHEMA}"""
    return [{"role": "system", "content": SYSTEM},
            {"role": "user", "content": user}]


def ticket_prompt(spec_text, plan, tid, uncovered, max_files):
    if plan.ticket_list():
        claimed = plan.claimed()
        lines = []
        for t in plan.ticket_list():
            lines.append(
                f"{t['id']}  priority:{t['priority']}  "
                f"files: {', '.join(t['files'])}  "
                f"blocked_by: {', '.join(t['blocked_by']) or '-'}\n"
                f"    {t['title']}")
        planned = "\n".join(lines)
        owners = "\n".join(f"- {p}  (owned by {claimed[p]})" for p in plan.layout if p in claimed)
    else:
        planned = "(none yet -- this is the first ticket, so it is the foundation)"
        owners = "(none yet)"

    # Both live runs against gpt-oss:20b put the dependency manifest in the LAST
    # ticket, unblocked, so a worker would have been dispatched to run pytest in
    # a project that did not install yet. Every mechanical check passed it, because
    # a missing dependency is invisible to a consistency check. The prompt is now
    # the only channel for that rule, so it says it here, in both directions.
    if not plan.ticket_list():
        foundation = (
            "- This is the FIRST ticket, so it is the foundation. It creates the\n"
            "  dependency/config manifest and whatever the test runner needs to run at\n"
            "  all, and nothing else. Its acceptance command is the test runner itself.\n"
            "  Do not start with a feature: every later ticket's acceptance command\n"
            "  depends on this one existing.")
    else:
        first = plan.ticket_list()[0]["id"]
        foundation = (
            f"- {first} is the foundation ticket. This ticket must be blocked_by {first},\n"
            f"  directly or through another ticket that already is, because its acceptance\n"
            f"  command cannot run before the project installs.")

    user = f"""TASK: choose the NEXT single implementation ticket. One ticket, not a plan.

SPECIFICATION (the issue being planned):
{clip(spec_text, 2500, 'spec')}

FILE LAYOUT (fixed -- every path a ticket touches must appear here):
{chr(10).join('- ' + p for p in plan.layout)}

PATHS ALREADY CLAIMED:
{owners}

PATHS NOT YET CLAIMED BY ANY TICKET:
{chr(10).join('- ' + p for p in uncovered)}

TICKETS ALREADY PLANNED:
{planned}

RULES
- This is ticket {tid}. Describe only it. Do not describe the tickets after it.
- Prefer a ticket that claims one or more of the unclaimed paths above.
{foundation}
- files: 1 to {max_files} paths, all taken from the layout. Normally one source
  file plus its test file.
- A path that is already claimed may be listed ONLY if this ticket lists the
  claiming ticket in blocked_by -- otherwise two workers edit one file at once,
  which is a planning failure.
- blocked_by: ids of tickets already planned above, or []. If this ticket needs
  what an earlier one creates, say so; priority does not sequence work.
- acceptance: exactly ONE shell command run from the repository root, naming the
  test file this ticket creates. No "&&", no "||", no ";", no pipes, no prose.
- priority: 1 foundation, 2 the behaviour the spec is about, 3 wiring, 4 the rest.
- goal: one sentence on one line. If it needs an "and", the ticket is too big.
- details: 40-80 words telling a worker what to implement, referring to sections
  of the README rather than restating them.
- title: at most 72 characters.

REPLY WITH EXACTLY THIS JSON SHAPE AND NOTHING ELSE:
{TICKET_SCHEMA}"""
    return [{"role": "system", "content": SYSTEM},
            {"role": "user", "content": user}]


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
    if getattr(a, "quiet_spec", False):
        return
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
    obj = {"title": a.title, "priority": a.priority, "files": flatten(a.files),
           "blocked_by": flatten(a.blocked_by), "acceptance": a.acceptance,
           "goal": a.goal, "details": read_or(a.details, a.details_file)}
    rec, err = build_ticket(plan, a.id, obj, max_files=a.max_files)
    if err:
        die(err)
    plan.add_ticket(rec)
    print(f"added {rec['id']}  priority:{rec['priority']}  {len(rec['files'])} file(s)"
          + (f"  blocked-by {','.join(rec['blocked_by'])}" if rec["blocked_by"] else "")
          + f"  [{len(plan.tickets)} tickets in plan]")


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
    if plan.layout:
        unc = uncovered(plan)
        print(f"layout coverage: {len(plan.layout) - len(unc)}/{len(plan.layout)} paths claimed"
              + (f"; unclaimed: {', '.join(unc)}" if unc else ""))
    if total > done:
        print("next: " + (next_id(plan) or "-"))


def cmd_next(a, plan):
    require_init(plan)
    print(next_id(plan) or "")


def cmd_render(a, plan):
    require_init(plan)
    t = plan.tickets.get(a.id) or die(f"{a.id} not in the plan")
    print(render(t, lambda b: resolve_ref(plan, b, allow_pending=True)))


def do_emit(plan, ids, dry_run, fixtures):
    """Create one issue per ticket, link it under the spec, record the number.
    Append-only and resumable: a ticket the ledger says exists is skipped."""
    if not ids:
        print("nothing to emit; the plan has no tickets")
        return
    if not dry_run:
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
        if dry_run:
            number = 9000 + plan.order.index(tid) + 1
            fixture = {"number": number, "title": t["title"], "body": body,
                       "labels": labels_for(t), "parent": plan.spec, "local_id": tid}
            out = fixtures or os.path.join(plan.dir, "fixtures")
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


def cmd_emit(a, plan):
    require_init(plan)
    if not a.id and not a.all:
        die("pass --id T1 (one ticket, the resumable way) or --all")
    if a.id and a.id not in plan.tickets:
        die(f"{a.id} not in the plan")
    # --all walks every ticket, including the done ones: resuming should SAY what
    # it is skipping, so a fresh context can see where the last run stopped.
    do_emit(plan, [a.id] if a.id else plan.topo(), a.dry_run, a.fixtures)


# --------------------------------------------------------------------------- #
# plan - the whole loop, owned by this script
# --------------------------------------------------------------------------- #

def lint_path():
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), "p3-plan-lint.py")


def run_lint(args):
    """A SEPARATE process running a SEPARATE implementation of the parser. Kept
    as a subprocess rather than an import so that is visibly true."""
    p = subprocess.run([sys.executable, lint_path()] + args,
                       capture_output=True, text=True)
    sys.stdout.write(p.stdout)
    sys.stderr.write(p.stderr)
    return p.returncode


def load_spec(a, plan):
    sp = os.path.join(plan.dir, "spec.md")
    rp = os.path.join(plan.dir, "readme.md")
    if a.spec_file or a.readme_file:
        os.makedirs(plan.dir, exist_ok=True)
        if a.spec_file:
            with open(a.spec_file, encoding="utf-8") as fh:
                text = fh.read()
            with open(sp, "w", encoding="utf-8") as fh:
                fh.write(text)
        if a.readme_file:
            with open(a.readme_file, encoding="utf-8") as fh:
                text = fh.read()
            with open(rp, "w", encoding="utf-8") as fh:
                fh.write(text)
    elif not os.path.exists(sp):
        a.quiet_spec = True
        cmd_spec_show(a, plan)
    spec_text = open(sp, encoding="utf-8").read() if os.path.exists(sp) else ""
    readme_text = open(rp, encoding="utf-8").read() if os.path.exists(rp) else ""
    if not spec_text.strip() and not readme_text.strip():
        die("neither the spec issue nor the README has any content to plan from")
    return spec_text, readme_text


def uncovered(plan):
    claimed = plan.claimed()
    return [p for p in plan.layout if p not in claimed]


def next_free_id(plan):
    n = 1
    while f"T{n}" in plan.tickets:
        n += 1
    return f"T{n}"


def cmd_plan(a, plan):
    cfg = model_cfg(a)

    # ---- 1. the ledger ---------------------------------------------------- #
    if plan.repo:
        if plan.repo != a.repo or plan.spec != a.spec:
            die(f"this plan directory already holds {plan.repo} spec #{plan.spec}; "
                f"use a different --plan-dir for {a.repo} spec #{a.spec}")
        print(f"[1/6] resuming {plan.repo} spec #{plan.spec}: "
              f"{len(plan.tickets)} ticket(s), {len(plan.emitted)} emitted")
    else:
        if "/" not in a.repo:
            die("--repo must be owner/name")
        plan.append({"kind": "init", "repo": a.repo, "spec": a.spec})
        plan.repo, plan.spec = a.repo, a.spec
        print(f"[1/6] initialised {a.repo} spec #{a.spec}, ledger {plan.path}")

    spec_text, readme_text = load_spec(a, plan)
    print(f"      spec {len(spec_text)} chars, README {len(readme_text)} chars")
    print(f"      model {cfg['model']} at {cfg['url']}  "
          f"(retries {cfg['retries']}, budget {a.max_tickets} tickets)")

    # Every ATTEMPT lands here, retries included, so --max-model-calls bounds the
    # work actually done rather than the tickets that came out of it.
    attempts = []

    # ---- 2. the layout: ONE model call ------------------------------------ #
    if plan.layout:
        print(f"[2/6] layout already recorded: {len(plan.layout)} paths (not re-asking)")
    else:
        print("[2/6] asking the model for the file layout")
        obj, raw = ask(cfg, "layout",
                       layout_prompt(spec_text, readme_text, a.min_paths, a.max_paths),
                       lambda o: validate_layout(o, a.min_paths, a.max_paths),
                       plan, stats=attempts)
        plan.append({"kind": "layout", "paths": obj["paths"], "raw_sha256": sha(raw)})
        plan.layout = obj["paths"]
        print(f"      layout: {len(plan.layout)} paths")
        for p in plan.layout:
            print(f"        {p}")

    # ---- 3. the tickets: ONE model call each ------------------------------ #
    print("[3/6] asking the model for one ticket at a time")
    stalls = 0
    while True:
        unc = uncovered(plan)
        if not unc:
            print(f"      every layout path is claimed by a ticket "
                  f"({len(plan.tickets)} tickets)")
            break
        if len(plan.tickets) >= a.max_tickets:
            die(f"hit the ticket budget ({a.max_tickets}) with {len(unc)} layout path(s) "
                f"still unclaimed: {', '.join(unc)}\n"
                "The plan is incomplete and no ticket was invented to close the gap. "
                "Raise --max-tickets, or fix the layout and start a fresh plan directory.",
                code=EXIT_BUDGET)
        if len(attempts) >= a.max_model_calls:
            die(f"hit the model-call budget ({a.max_model_calls} attempts, retries included) "
                f"with {len(unc)} layout path(s) still unclaimed: {', '.join(unc)}",
                code=EXIT_BUDGET)

        tid = next_free_id(plan)
        holder = {}

        def check(o, _tid=tid, _holder=holder):
            rec, err = build_ticket(plan, _tid, o, max_files=a.max_files)
            if err is None:
                _holder["rec"] = rec
            return err

        obj, raw = ask(cfg, f"ticket {tid}",
                       ticket_prompt(spec_text, plan, tid, unc, a.max_files),
                       check, plan, stats=attempts)
        rec = holder["rec"]
        # Provenance: the sha256 of the exact reply this ticket was built from.
        # It is what proves, mechanically, that the ledger holds no ticket the
        # model did not return.
        rec["raw_sha256"] = sha(raw)
        rec["origin"] = "model"
        plan.add_ticket(rec)

        after = uncovered(plan)
        gained = len(unc) - len(after)
        print(f"      {rec['id']}  p{rec['priority']}  {rec['title'][:52]}"
              f"   (+{gained} path(s) claimed, {len(after)} left)")
        if gained <= 0:
            stalls += 1
            if stalls >= a.max_stalls:
                die(f"{stalls} consecutive tickets claimed no new layout path; the loop is "
                    f"not converging. Still unclaimed: {', '.join(after)}", code=EXIT_BUDGET)
        else:
            stalls = 0

    # ---- 4. lint the whole plan ------------------------------------------- #
    print("[4/6] validating the plan before anything is created")
    rc = run_lint(["--ledger", plan.path, "--max-files", str(a.max_files)])
    if rc != 0:
        die("the plan does not validate; nothing was created. "
            "Fix it with `add` or start again with a fresh --plan-dir.")

    if a.no_emit:
        print("[5/6] --no-emit: stopping before anything is created")
        return

    # ---- 5. emit ----------------------------------------------------------- #
    print(f"[5/6] {'dry-run emit' if a.dry_run else 'creating issues'}")
    do_emit(plan, plan.topo(), a.dry_run, a.fixtures)

    # ---- 6. verify what actually exists ------------------------------------ #
    print("[6/6] verifying what exists")
    if a.dry_run:
        rc = run_lint(["--fixtures", a.fixtures or os.path.join(plan.dir, "fixtures"),
                       "--parent", str(plan.spec), "--max-files", str(a.max_files)])
    else:
        rc = run_lint(["--repo", plan.repo, "--parent", str(plan.spec),
                       "--max-files", str(a.max_files)])
    if rc != 0:
        die("what was created does not validate -- report this to the human, do not "
            "attempt to repair it by editing issues")
    print(f"\ndone: {len(plan.tickets)} tickets, all status:backlog, awaiting human "
          f"approval. Nothing is dispatchable until a human sets status:todo.")


# --------------------------------------------------------------------------- #
# measure - the first-try JSON validity rate, on the actual workload
# --------------------------------------------------------------------------- #

def cmd_measure(a, plan):
    """N independent single-shot planning calls. No retries, no ledger, no
    GitHub: the question is how often ONE call comes back schema-valid."""
    cfg = model_cfg(a)
    cfg["retries"] = 0

    seed = json.load(open(a.seed, encoding="utf-8")) if a.seed else None
    spec_text = open(a.spec_file, encoding="utf-8").read() if a.spec_file else ""
    readme_text = open(a.readme_file, encoding="utf-8").read() if a.readme_file else ""
    if a.kind in ("ticket", "both") and not seed:
        die("--kind ticket needs --seed FILE holding {\"layout\": [...], \"tickets\": [...]}")

    kinds = ["layout", "ticket"] if a.kind == "both" else [a.kind]
    report = {"model": cfg["model"], "endpoint": cfg["url"],
              "temperature": cfg["temperature"], "json_mode": cfg["json_mode"],
              "calls_per_kind": a.calls, "results": {}}

    for kind in kinds:
        if kind == "ticket":
            scratch = Plan(os.path.join(a.plan_dir, "_measure"))
            scratch.repo, scratch.spec = "example-org/example-service", 1
            scratch.layout = seed["layout"]
            for t in seed["tickets"]:
                rec = dict(t)
                rec["kind"] = "ticket"
                scratch.tickets[rec["id"]] = rec
                scratch.order.append(rec["id"])
            tid = next_free_id(scratch)
            messages = ticket_prompt(spec_text, scratch, tid, uncovered(scratch), a.max_files)
            validate = lambda o: build_ticket(scratch, tid, o, max_files=a.max_files)[1]
        else:
            messages = layout_prompt(spec_text, readme_text, a.min_paths, a.max_paths)
            validate = lambda o: validate_layout(dict(o), a.min_paths, a.max_paths)

        outcomes = []
        print(f"\nmeasuring {a.calls} single-shot `{kind}` calls "
              f"against {cfg['model']}", file=sys.stderr)
        for i in range(1, a.calls + 1):
            t0 = time.time()
            stats = []
            try:
                ask(cfg, kind, messages, validate, plan=None, stats=stats)
            except SystemExit:
                pass
            why, detail = stats[-1] if stats else ("transport", "no attempt recorded")
            dt = time.time() - t0
            outcomes.append({"n": i, "outcome": why, "detail": detail, "seconds": round(dt, 1)})
            print(f"  {i:>3}/{a.calls}  {why:<9} {dt:6.1f}s  {detail[:88]}", file=sys.stderr)

        ok = sum(1 for o in outcomes if o["outcome"] == "ok")
        report["results"][kind] = {
            "calls": len(outcomes), "valid_first_try": ok,
            "rate": round(ok / len(outcomes), 4) if outcomes else 0.0,
            "median_seconds": sorted(o["seconds"] for o in outcomes)[len(outcomes) // 2]
            if outcomes else 0,
            "outcomes": outcomes,
        }

    print()
    for kind, r in report["results"].items():
        print(f"{kind}: schema-valid on the first try {r['valid_first_try']}/{r['calls']} "
              f"({r['rate'] * 100:.1f}%), median {r['median_seconds']}s")
        modes = {}
        for o in r["outcomes"]:
            if o["outcome"] == "ok":
                continue
            key = (o["outcome"], o["detail"][:70])
            modes[key] = modes.get(key, 0) + 1
        for (why, detail), n in sorted(modes.items(), key=lambda kv: -kv[1]):
            print(f"    {n:>3}  {why}: {detail}")
    if a.out:
        with open(a.out, "w", encoding="utf-8") as fh:
            json.dump(report, fh, indent=2, sort_keys=True)
        print(f"\nwrote {a.out}")


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


def add_model_args(s):
    s.add_argument("--endpoint", default=None, help="OpenAI-compatible chat URL")
    s.add_argument("--model", default=None)
    s.add_argument("--temperature", type=float, default=0.2)
    s.add_argument("--retries", type=int, default=None,
                   help="retries after a rejected reply (default 3)")
    s.add_argument("--max-files", type=int, default=4)
    s.add_argument("--min-paths", type=int, default=3)
    s.add_argument("--max-paths", type=int, default=40)


def main():
    p = argparse.ArgumentParser(description="planner: script-owned loop, model-supplied judgement")
    # Default to a directory that is writable by the agent, not to a relative
    # "plan" beside whatever the cwd happens to be. The agent runs as uid 10000
    # while its working directory is root-owned 0755, so a relative default fails
    # with EACCES - and it fails invisibly to anyone testing with `docker exec`,
    # which defaults to root and can write there fine.
    p.add_argument("--plan-dir", default=os.environ.get(
        "P3_PLAN_DIR",
        os.path.join(os.environ["HERMES_HOME"], "plan") if os.environ.get("HERMES_HOME") else "plan"))
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("plan", help="run the whole planning loop")
    s.add_argument("--repo", required=True)
    s.add_argument("--spec", type=int, required=True)
    s.add_argument("--spec-file", default="", help="offline: use this file as the spec")
    s.add_argument("--readme-file", default="", help="offline: use this file as the README")
    s.add_argument("--max-tickets", type=int, default=30)
    s.add_argument("--max-model-calls", type=int, default=80)
    s.add_argument("--max-stalls", type=int, default=3,
                   help="consecutive tickets claiming no new layout path before giving up")
    s.add_argument("--dry-run", action="store_true", help="render fixtures instead of creating issues")
    s.add_argument("--fixtures", default=None)
    s.add_argument("--no-emit", action="store_true", help="stop after the plan validates")
    add_model_args(s)

    s = sub.add_parser("measure", help="first-try schema-valid rate over N calls")
    s.add_argument("--calls", type=int, default=20)
    s.add_argument("--kind", choices=["layout", "ticket", "both"], default="ticket")
    s.add_argument("--spec-file", default="")
    s.add_argument("--readme-file", default="")
    s.add_argument("--seed", default="", help="JSON: {\"layout\": [...], \"tickets\": [...]}")
    s.add_argument("--out", default="")
    add_model_args(s)

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
    {"plan": cmd_plan, "measure": cmd_measure,
     "init": cmd_init, "spec-show": cmd_spec_show, "layout": cmd_layout, "add": cmd_add,
     "list": cmd_list, "status": cmd_status, "next": cmd_next, "render": cmd_render,
     "emit": cmd_emit}[a.cmd](a, plan)


if __name__ == "__main__":
    main()

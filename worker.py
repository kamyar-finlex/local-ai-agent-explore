#!/usr/bin/env python3
"""
worker.py - the worker. It turns ONE ticket into ONE pull request.

A SCRIPT owns the control flow; the model only produces file contents.

WHY IT IS SHAPED THIS WAY
-------------------------
This is the same inversion `p3-plan.py` documents, applied to the other end of
the pipeline. Four live runs of a skill-driven planner - where the MODEL owned
the procedure - failed four different ways: it improvised instead of starting,
read "network blocked" out of a missing binary, wrote files it had no business
writing, routed around a tool that was taken away from it, stopped after one
ticket, and finally printed a confident five-ticket plan when only two existed.
Moving control flow into the script fixed all of it, and measurement agreed:
97.5% first-try schema-valid output when the model answers ONE narrow question,
against four-for-four failure when it drives a procedure.

So the model here is never asked "implement this ticket". It is asked, once per
declared file:

    here is the goal, the details, the repo's README, the other declared paths
    and this file's current contents - return the full new contents of THIS file

and nothing else. It never runs a command, never chooses what to do next, never
decides when the work is done, and never gets to write a path it names itself:
the script writes exactly the path it asked about, and refuses a reply that
answers about a different one.

THE ORDER, AND WHY EACH STEP IS WHERE IT IS
-------------------------------------------
  1. config          - fail on a missing token/repo/issue before anything else
  2. fetch the issue - and REFUSE a non-conforming ticket here, before the clone
                       and before the first model call. A malformed ticket is a
                       planning defect to report, not something to guess around.
  3. clone + branch  - shallow, into the one writable mount
  4. one model call per declared file, contents held in memory
  5. write - only after EVERY declared file has a validated reply, so the
                       "this needs another file" outcome writes nothing at all
  6. acceptance command, with a bounded per-file retry that feeds the failure
                       back; then the project's full test suite
  7. scope gate      - `git status` must show no file outside the declared list,
                       and the staged diff must be a subset of it
  8. commit, push, open the pull request with `Closes #N`

Anything that is not outcome (8) exits with its own code (see EXIT_CODES) so the
dispatcher can tell "PR opened" from "needs a file" from "model unusable"
without parsing prose.

WHAT THIS PROGRAM CANNOT DO, BY CONSTRUCTION
--------------------------------------------
There is no code path here that writes a label, merges a pull request, or
force-pushes. Not "it is instructed not to" - the functions do not exist. That
matters because ORCHESTRATOR.md's first two prohibitions are the review gate
itself, and a prohibition that lives only in a prompt is a guardrail against
accident rather than a control. The remaining rules that CAN be expressed as
code are: the declared-file scope gate, the README refusal, the
no-weakened-tests check and the dependency-manifest check.

Stdlib only. The worker image has python3, pip, pytest, git and curl - and NOT
`gh`, NOT `jq` (both measured), so GitHub is reached over the REST API with
urllib, which honours HTTPS_PROXY and therefore leaves through the egress
allowlist. The inference call deliberately does NOT go through that proxy; see
model_opener().

Usage (the dispatcher's default command supplies the first two by environment):
  worker.py                       # P4_ISSUE / P4_REPO / GITHUB_TOKEN from env
  worker.py --issue 31 --repo owner/name
  worker.py --exit-codes          # print the exit-code table and stop

Offline, for the harness - no GitHub, no live model:
  worker.py --issue 31 --repo example/target \\
            --github fixture:/tmp/state.json --origin file:///tmp/origin.git \\
            --workspace /tmp/ws --endpoint http://127.0.0.1:PORT/v1/chat/completions

Environment:
  GITHUB_TOKEN      required. Also accepted as TARGET_REPO_TOKEN. Never logged,
                    never placed in a command line, never written to a file, and
                    never put into a git remote URL (see git_env()).
  TARGET_REPO       owner/name. The dispatcher's command also passes P4_REPO.
  P4_ISSUE          the issue number this worker was handed.
  P4_GITHUB_API     API root, default https://api.github.com
  P5_MODEL_URL      OpenAI-compatible chat endpoint.
                    default http://ollama-gate:11434/v1/chat/completions
  P5_MODEL          model tag, default gpt-oss:20b-64k
  P5_MODEL_KEY      bearer for that endpoint, default "ollama"
  P5_MODEL_TIMEOUT  seconds per call, default 600
  P5_MODEL_RETRIES  retries after a REJECTED reply, default 3
  P5_MODEL_MAX_TOKENS  default 4096 (a file is bigger than a ticket)
  P5_MODEL_JSON_MODE   1 (default) sends response_format=json_object
  P5_MODEL_USE_PROXY   1 routes inference through HTTPS_PROXY; default 0
  P5_WORKSPACE      writable directory to clone into, default /work
  P5_TEST_COMMAND   the project's FULL suite, default "pytest -q"
  P5_ATTEMPTS       acceptance attempts, default 3 (1 write + 2 retries)
  P5_ACCEPTANCE_TIMEOUT  seconds for the acceptance command, default 300
  P5_SUITE_TIMEOUT  seconds for the full suite, default 900
  P5_MAX_FILE_BYTES cap on one file's contents, default 65536
  P5_CONTEXT_BYTES  per-file clip when other files are shown as context, 8000
  P5_HEARTBEAT_SECONDS  minimum gap between heartbeat comments, default 600
"""

import argparse
import json
import os
import re
import shlex
import subprocess
import sys
import time
import urllib.error
import urllib.request

# --------------------------------------------------------------------------- #
# exit codes - one per OUTCOME, because the dispatcher reads a number, not prose
# --------------------------------------------------------------------------- #

EXIT_OK          = 0    # pull request opened; acceptance and suite both passed
EXIT_ERROR       = 1    # unexpected internal failure
EXIT_USAGE       = 2    # configuration missing or wrong; nothing was attempted
EXIT_MODEL       = 3    # the model never produced a usable reply -> unusable
EXIT_TICKET      = 4    # the ticket does not conform: a PLANNING defect
EXIT_NEEDS_FILE  = 5    # the work needs a file outside Files touched
EXIT_ACCEPTANCE  = 6    # acceptance command still failing after the retries
EXIT_SUITE       = 7    # the project's full test suite failed
EXIT_GIT         = 8    # clone / push / pull-request creation failed
EXIT_SCOPE       = 9    # a file outside the declared list changed
EXIT_DEPENDENCY  = 10   # a dependency the target README does not sanction
EXIT_TEST_WEAK   = 11   # the reply would weaken, skip or delete a test

EXIT_CODES = [
    (EXIT_OK,         "pr-opened",        "acceptance and full suite passed, PR opened"),
    (EXIT_ERROR,      "internal-error",   "unexpected failure, or nothing left to commit"),
    (EXIT_USAGE,      "config-missing",   "token, repo or issue number absent; nothing attempted"),
    (EXIT_MODEL,      "model-unusable",   "no schema-valid reply after the retries; nothing committed"),
    (EXIT_TICKET,     "ticket-malformed", "planning defect: the ticket does not match ORCHESTRATOR.md"),
    (EXIT_NEEDS_FILE, "needs-file",       "needs a file outside Files touched; commented, wrote nothing"),
    (EXIT_ACCEPTANCE, "acceptance-failed","acceptance command failed after the retries; nothing committed"),
    (EXIT_SUITE,      "suite-failed",     "a test the worker did not write failed; nothing committed"),
    (EXIT_GIT,        "git-failed",       "clone, push or pull-request creation failed"),
    (EXIT_SCOPE,      "scope-violation",  "a file outside the declared list changed; nothing committed"),
    (EXIT_DEPENDENCY, "unsanctioned-dep", "a dependency the target README does not sanction"),
    (EXIT_TEST_WEAK,  "test-weakened",    "the reply removed, skipped or xfailed a test"),
]

# --------------------------------------------------------------------------- #
# ticket-format constants - these ARE ORCHESTRATOR.md's ticket format. If they
# drift from it, the worker refuses tickets the planner legitimately produced,
# so verify-worker.sh re-reads that file and compares.
# --------------------------------------------------------------------------- #

SEC_GOAL       = "Goal"
SEC_FILES      = "Files touched"
SEC_DETAILS    = "Details"
SEC_ACCEPTANCE = "Acceptance criteria"
SEC_BLOCKED    = "Blocked-by"

REQUIRED_SECTIONS = [SEC_GOAL, SEC_FILES, SEC_DETAILS, SEC_ACCEPTANCE]
OPTIONAL_SECTIONS = [SEC_BLOCKED]

PATH_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]*$")
# Shell operators that would make an acceptance criterion more than one command.
# Detected as whole shlex TOKENS, so a ';' inside a quoted python -c stays legal.
SHELL_OPS = {"&&", "||", ";", "|", "&", ">", ">>", "<", "2>", "2>&1"}
PROSE = re.compile(r"\b(should|must|verify that|check that|ensure|works|passes when)\b", re.I)

CLAIM_MARK     = "p4-claim"
HEARTBEAT_MARK = "p4-heartbeat"
DEFECT_MARK    = "p4-defect"

# Files a test run leaves behind. They are not source edits, and a target repo
# without a .gitignore would otherwise trip the scope gate on its own artefacts.
# Narrow on purpose: everything else outside the declared list is a violation.
ARTIFACT_RE = re.compile(r"(^|/)(__pycache__|\.pytest_cache|\.mypy_cache|"
                         r"\.ruff_cache|\.hypothesis|node_modules|\.coverage|"
                         r"htmlcov|\.tox)(/|$)"
                         r"|\.pyc$|\.pyo$|(^|/)\.coverage\.[^/]+$")

# Dependency manifests. A ticket may legitimately declare one; what it may not do
# is add a package the target README never mentions.
MANIFESTS = {"requirements.txt", "requirements-dev.txt", "pyproject.toml",
             "setup.py", "setup.cfg", "package.json", "Gemfile", "go.mod",
             "Cargo.toml"}

# Markers that turn a passing test into a non-test.
SKIP_RE = re.compile(r"@pytest\.mark\.(skip|skipif|xfail)|pytest\.skip\(|"
                     r"pytest\.xfail\(|unittest\.skip|\.skip\(|\.todo\(|xit\(|xdescribe\(")
TEST_DEF_RE = re.compile(r"^\s*(?:async\s+)?def\s+(test_\w+)", re.M)

MODEL_URL_DEFAULT = "http://ollama-gate:11434/v1/chat/completions"
MODEL_DEFAULT = "gpt-oss:20b-64k"
FENCE_RE = re.compile(r"```(?:[A-Za-z0-9_+-]*)\s*(.*?)```", re.S)

# Set once, in config(). Everything printed goes through redact().
SECRETS = []


# --------------------------------------------------------------------------- #
# output - one funnel, so a secret cannot reach a log by a route nobody checked
# --------------------------------------------------------------------------- #

def redact(text):
    out = str(text)
    for s in SECRETS:
        if s and len(s) >= 4:
            out = out.replace(s, "<redacted>")
    return out


def say(msg):
    print(redact(msg), flush=True)


def warn(msg):
    print(redact(f"  warn: {msg}"), file=sys.stderr, flush=True)


def die(msg, code=EXIT_ERROR):
    print(redact(f"error: {msg}"), file=sys.stderr, flush=True)
    raise SystemExit(code)


def clip(text, n, label=""):
    text = text or ""
    if len(text) <= n:
        return text
    return text[:n] + f"\n... [clipped, {len(text) - n} more chars{' of ' + label if label else ''}]"


def tail(text, n):
    text = text or ""
    return text if len(text) <= n else "... [earlier output clipped]\n" + text[-n:]


# --------------------------------------------------------------------------- #
# configuration - loudly, and before anything else happens
# --------------------------------------------------------------------------- #

def env_int(name, default):
    raw = os.environ.get(name, "")
    if raw == "":
        return default
    try:
        return int(raw)
    except ValueError:
        die(f"{name} must be an integer, got {raw!r}", EXIT_USAGE)


def config(argv=None):
    p = argparse.ArgumentParser(add_help=True, description=__doc__.split("\n")[1],
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--issue", type=int, help="issue number (default $P4_ISSUE)")
    p.add_argument("--repo", help="owner/name (default $TARGET_REPO / $P4_REPO)")
    p.add_argument("--github", default=os.environ.get("P5_GITHUB", ""),
                   help="'fixture:PATH' replaces the GitHub API with a JSON file (harness only)")
    p.add_argument("--origin", default=os.environ.get("P5_ORIGIN", ""),
                   help="git URL to clone (default https://github.com/<repo>.git)")
    p.add_argument("--workspace", default=os.environ.get("P5_WORKSPACE", "/work"))
    p.add_argument("--endpoint", default="", help="model endpoint (default $P5_MODEL_URL)")
    p.add_argument("--model", default="", help="model tag (default $P5_MODEL)")
    p.add_argument("--temperature", type=float, default=0.2)
    p.add_argument("--retries", type=int, default=None)
    p.add_argument("--attempts", type=int, default=None,
                   help="acceptance attempts, including the first (default $P5_ATTEMPTS or 3)")
    p.add_argument("--exit-codes", action="store_true",
                   help="print the exit-code table and stop")
    a = p.parse_args(argv)

    if a.exit_codes:
        for code, name, why in EXIT_CODES:
            print(f"{code}\t{name}\t{why}")
        raise SystemExit(EXIT_OK)

    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("TARGET_REPO_TOKEN") or ""
    fixture = a.github.startswith("fixture:")
    if token:
        SECRETS.append(token)
    elif not fixture:
        die("GITHUB_TOKEN is not set. The dispatcher injects it from its own "
            "environment (WORKER_ENV_ALLOWLIST); an empty one means the operator "
            "has not configured TARGET_REPO_TOKEN. Refusing to start: a worker "
            "without a token fails deep inside a push instead of here.", EXIT_USAGE)

    repo = a.repo or os.environ.get("TARGET_REPO") or os.environ.get("P4_REPO") or ""
    if not repo:
        die("TARGET_REPO is not set (owner/name). Refusing to guess a repository.",
            EXIT_USAGE)
    if repo.count("/") != 1 or not all(repo.split("/")):
        die(f"TARGET_REPO must be owner/name, got {repo!r}", EXIT_USAGE)

    issue = a.issue if a.issue is not None else env_int("P4_ISSUE", 0)
    if not issue or issue <= 0:
        die("P4_ISSUE is not set. A worker is handed exactly ONE issue number and "
            "must not pick one for itself.", EXIT_USAGE)

    url = a.endpoint or os.environ.get("P5_MODEL_URL") or MODEL_URL_DEFAULT
    model = a.model or os.environ.get("P5_MODEL") or MODEL_DEFAULT
    if not url.strip() or not model.strip():
        die("the model endpoint and model tag must both be non-empty "
            "(P5_MODEL_URL / P5_MODEL)", EXIT_USAGE)

    cfg = {
        "issue": int(issue),
        "repo": repo,
        "token": token,
        "api": (os.environ.get("P4_GITHUB_API") or "https://api.github.com").rstrip("/"),
        "github": a.github,
        "origin": a.origin or f"https://github.com/{repo}.git",
        "workspace": a.workspace,
        "url": url,
        "model": model,
        "temperature": a.temperature,
        "max_tokens": env_int("P5_MODEL_MAX_TOKENS", 4096),
        "timeout": env_int("P5_MODEL_TIMEOUT", 600),
        "retries": a.retries if a.retries is not None else env_int("P5_MODEL_RETRIES", 3),
        "json_mode": os.environ.get("P5_MODEL_JSON_MODE", "1") != "0",
        "attempts": a.attempts if a.attempts is not None else env_int("P5_ATTEMPTS", 3),
        "test_command": os.environ.get("P5_TEST_COMMAND") or "pytest -q",
        "acceptance_timeout": env_int("P5_ACCEPTANCE_TIMEOUT", 300),
        "suite_timeout": env_int("P5_SUITE_TIMEOUT", 900),
        "max_file_bytes": env_int("P5_MAX_FILE_BYTES", 65536),
        "context_bytes": env_int("P5_CONTEXT_BYTES", 8000),
        "heartbeat_seconds": env_int("P5_HEARTBEAT_SECONDS", 600),
    }
    if cfg["attempts"] < 1:
        die("P5_ATTEMPTS must be at least 1", EXIT_USAGE)
    return cfg


# --------------------------------------------------------------------------- #
# GitHub - REST over urllib, proxy-aware. There is no method here that writes a
# label, merges a pull request, or edits an issue body: see the module docstring.
# --------------------------------------------------------------------------- #

class GitHubError(Exception):
    pass


class GitHub:
    def __init__(self, cfg):
        self.api = cfg["api"]
        self.repo = cfg["repo"]
        self.token = cfg["token"]

    def _call(self, method, path, body=None):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.api + path, data=data, method=method)
        req.add_header("Authorization", f"Bearer {self.token}")
        req.add_header("Accept", "application/vnd.github+json")
        req.add_header("X-GitHub-Api-Version", "2022-11-28")
        req.add_header("User-Agent", "hermes-worker")
        if data is not None:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                payload = r.read()
                return json.loads(payload) if payload.strip() else {}
        except urllib.error.HTTPError as e:
            detail = e.read().decode("utf-8", "replace")[:400]
            # Never echo request headers: the token lives there.
            raise GitHubError(f"{method} {path} -> HTTP {e.code}: {detail}")
        except urllib.error.URLError as e:
            raise GitHubError(f"{method} {path} unreachable: {e.reason} "
                              "(is HTTPS_PROXY pointing at the egress proxy?)")

    def get_issue(self, n):
        return self._call("GET", f"/repos/{self.repo}/issues/{n}")

    def list_comments(self, n):
        return self._call("GET", f"/repos/{self.repo}/issues/{n}/comments?per_page=100")

    def create_comment(self, n, body):
        return self._call("POST", f"/repos/{self.repo}/issues/{n}/comments",
                          {"body": body})

    def create_pull(self, title, head, base, body):
        return self._call("POST", f"/repos/{self.repo}/pulls",
                          {"title": title, "head": head, "base": base, "body": body})


class FixtureGitHub:
    """The same four calls against a JSON file, so the harness can drive a whole
    run with no credential and no network. Writes are persisted immediately, so a
    run that dies mid-way still shows what it had said."""

    def __init__(self, path):
        self.path = path
        with open(path, encoding="utf-8") as fh:
            self.state = json.load(fh)
        self.state.setdefault("comments", {})
        self.state.setdefault("pulls", [])

    def _flush(self):
        with open(self.path, "w", encoding="utf-8") as fh:
            json.dump(self.state, fh, indent=2, sort_keys=True)

    def _issue(self, n):
        for i in self.state.get("issues", []):
            if int(i["number"]) == int(n):
                return i
        raise GitHubError(f"GET /issues/{n} -> HTTP 404: no such issue in the fixture")

    def get_issue(self, n):
        i = dict(self._issue(n))
        if "body" not in i and "body_lines" in i:
            i["body"] = "\n".join(i["body_lines"])
        return i

    def list_comments(self, n):
        return list(self.state["comments"].get(str(n), []))

    def create_comment(self, n, body):
        rec = {"id": 1000 + sum(len(v) for v in self.state["comments"].values()),
               "body": body, "user": {"login": "hermes-worker"}}
        self.state["comments"].setdefault(str(n), []).append(rec)
        self._flush()
        return rec

    def create_pull(self, title, head, base, body):
        rec = {"number": 500 + len(self.state["pulls"]), "title": title,
               "head": {"ref": head}, "base": {"ref": base}, "body": body,
               "html_url": f"https://example.invalid/pull/{500 + len(self.state['pulls'])}"}
        self.state["pulls"].append(rec)
        self._flush()
        return rec


def open_github(cfg):
    if cfg["github"].startswith("fixture:"):
        return FixtureGitHub(cfg["github"].split(":", 1)[1])
    if cfg["github"]:
        die(f"--github {cfg['github']!r} is not understood; use 'fixture:PATH'",
            EXIT_USAGE)
    return GitHub(cfg)


# --------------------------------------------------------------------------- #
# the ticket - parsed strictly, refused loudly
# --------------------------------------------------------------------------- #

def split_sections(body):
    """'## Name' headings -> {name: text}. Order is preserved in `order`."""
    out, order, current = {}, [], None
    for line in (body or "").splitlines():
        m = re.match(r"^\s{0,3}##\s+(.+?)\s*$", line)
        if m:
            current = m.group(1).strip()
            if current not in out:
                order.append(current)
                out[current] = []
            continue
        if current is not None:
            out[current].append(line)
    return {k: "\n".join(v).strip() for k, v in out.items()}, order


def check_files(paths):
    """The declared-file list, held to exactly the planner's rules (p3-plan.py
    check_files). A worker that accepted a path the planner would not emit would
    be quietly widening the contract."""
    if not paths:
        return ("no files listed. A ticket without a file list cannot be worked "
                "safely: the whole reason it could run beside another ticket is "
                "that list")
    seen = set()
    for p in paths:
        if p in seen:
            return f"{p} is listed twice"
        seen.add(p)
        if p.startswith("/") or ".." in p.split("/"):
            return f"{p} is not a repo-relative path"
        if not PATH_RE.match(p) or p.endswith("/"):
            return f"{p} is not a plain file path"
        if os.path.basename(p).lower() == "readme.md":
            return ("the ticket declares the target README. No agent may modify "
                    "it (ORCHESTRATOR.md, Hard prohibitions)")
        if p.split("/")[0] == ".git":
            return f"{p} is inside .git"
    return None


def install_declared_dependencies(cfg, repo_dir, rep):
    """Install what the PROJECT declares, after writing files and before acceptance.

    Without this, any ticket whose acceptance command imports a third-party
    package fails with an import error no amount of retrying can fix - observed
    on a real ticket that specified FastAPI while nothing in the pipeline ever
    installed it. The worker then spent its whole retry budget re-asking the
    model to fix code that was already correct.

    The distinction that keeps this inside the contract: the worker installs
    what the repository's own manifest declares. It never invents a dependency,
    and a package the project has not declared is still refused.

    A failure here is reported, not worked around. Best-effort in the sense that
    a project with no manifest is normal and silent; a manifest that will not
    install is a real problem the human should see in the log.
    """
    # --no-build-isolation on the pyproject path is load-bearing. `pip install .`
    # otherwise spawns a subprocess to fetch the build backend (setuptools) from
    # the index BEFORE building, and that subprocess does not inherit the proxy
    # reliably - observed failing with "Name does not resolve" while the parent
    # pip could reach PyPI perfectly well. The image already ships setuptools, so
    # there is nothing to fetch.
    #
    # Not -q either. A quiet install that fails prints "See above for output"
    # with nothing above it, which turns a precise error into a guess.
    manifests = [
        (["pip", "install", "--disable-pip-version-check",
          "-r", "requirements.txt"], "requirements.txt"),
        (["pip", "install", "--disable-pip-version-check",
          "--no-build-isolation", "."], "pyproject.toml"),
    ]
    for cmd, fname in manifests:
        path = os.path.join(repo_dir, fname)
        if not os.path.isfile(path):
            continue
        rep.heartbeat(f"installing dependencies from {fname}")
        rc, out = run(cmd, cwd=repo_dir, timeout=cfg.get("install_timeout", 600))
        if rc == 0:
            say(f"  installed dependencies from {fname}")
        else:
            # Not fatal on its own: the acceptance command is the real verdict,
            # and a manifest can fail to install for reasons that do not matter
            # to this ticket. But say so, or a later import error looks unrelated.
            say(f"  WARNING: `{' '.join(cmd)}` -> exit {rc} (acceptance will show the consequence)")
            # Print enough to diagnose. Three lines caught the epilogue and lost
            # the cause; pip puts the real error well above its own summary.
            lines = [ln for ln in (out or "").splitlines() if ln.strip()]
            for line in lines[-25:]:
                say(f"    {line}")
        return
    say("  no dependency manifest present; nothing to install")


def check_acceptance(cmd):
    """One runnable command, nothing else - same rules the planner is held to."""
    if not cmd.strip():
        return "is empty"
    if "\n" in cmd.strip():
        return "must be a single line; prose here makes the ticket unverifiable"
    if cmd.strip().startswith(("-", "*", "#")):
        return "looks like a bullet or a heading, not a command"
    try:
        toks = shlex.split(cmd)
    except ValueError as e:
        return f"does not parse as a shell command ({e})"
    if not toks:
        return "is empty"
    bad = [t for t in toks if t in SHELL_OPS]
    if bad:
        return (f"chains commands with {bad[0]!r}; the worker runs ONE command and "
                "reads ONE exit code")
    if PROSE.search(cmd):
        return "reads as prose, not a command"
    if not re.match(r"^[A-Za-z0-9_./-]+$", toks[0]):
        return f"first token {toks[0]!r} is not a command name"
    return None


def parse_ticket(issue):
    """(ticket, None) or (None, 'why this is a planning defect').

    Nothing is inferred. A ticket missing a section is refused rather than
    guessed at, because guessing produces a plausible pull request against the
    wrong intent - the most expensive output this system can emit.
    """
    body = issue.get("body") or ""
    if not body.strip():
        return None, "the issue body is empty"
    sections, _order = split_sections(body)

    missing = [s for s in REQUIRED_SECTIONS if s not in sections]
    if missing:
        return None, ("missing required section(s) " +
                      ", ".join(f"'## {m}'" for m in missing) +
                      f"; ORCHESTRATOR.md requires {REQUIRED_SECTIONS}")

    goal = sections[SEC_GOAL].strip()
    if not goal:
        return None, "'## Goal' is empty"

    files, junk = [], []
    for line in sections[SEC_FILES].splitlines():
        line = line.strip()
        if not line:
            continue
        if line.startswith("- "):
            files.append(line[2:].strip())
        else:
            junk.append(line)
    if junk:
        return None, ("'## Files touched' must be one '- path' per line; found "
                      f"{junk[0]!r}")
    err = check_files(files)
    if err:
        return None, f"'## Files touched': {err}"

    acceptance = sections[SEC_ACCEPTANCE].strip()
    err = check_acceptance(acceptance)
    if err:
        return None, f"'## Acceptance criteria' {err}"

    details = sections[SEC_DETAILS].strip()
    if not details:
        return None, "'## Details' is empty; the worker has nothing to implement from"

    blocked = []
    for line in sections.get(SEC_BLOCKED, "").splitlines():
        line = line.strip()
        if not line:
            continue
        m = re.match(r"^#?(\d+)$", line.lstrip("- ").strip())
        if not m:
            return None, f"'## Blocked-by' must be '#N' per line; found {line!r}"
        blocked.append(int(m.group(1)))

    return {"number": int(issue["number"]),
            "title": (issue.get("title") or "").strip(),
            "goal": goal, "files": files, "details": details,
            "acceptance": acceptance, "blocked_by": blocked}, None


def slug(text, n=32):
    s = re.sub(r"[^a-z0-9]+", "-", (text or "").lower()).strip("-")
    if len(s) > n:
        s = s[:n].rstrip("-")
    return s or "work"


def branch_name(ticket):
    return f"issue-{ticket['number']}-{slug(ticket['title'])}"


# --------------------------------------------------------------------------- #
# model client - one file per call, stdlib urllib
# --------------------------------------------------------------------------- #

class ModelError(Exception):
    """Transport-level: no reply to judge, so there is nothing to feed back."""


class EmptyReply(ModelError):
    """The call succeeded and the assistant message was empty. On a reasoning
    model that means the generation budget was spent thinking - its own failure
    mode, with its own remedy (raise P5_MODEL_MAX_TOKENS)."""


def model_opener():
    """The gate is a plain-http host on the isolated network, and HTTPS_PROXY is
    set so the GitHub calls can leave through the egress allowlist. Sending
    inference through squid would be DENIED by that allowlist and would look
    exactly like "the model is down", so proxies are explicitly disabled here."""
    if os.environ.get("P5_MODEL_USE_PROXY") == "1":
        return urllib.request.build_opener()
    return urllib.request.build_opener(urllib.request.ProxyHandler({}))


def chat(messages, cfg):
    body = {"model": cfg["model"], "messages": messages, "stream": False,
            "temperature": cfg["temperature"], "max_tokens": cfg["max_tokens"]}
    if cfg["json_mode"]:
        body["response_format"] = {"type": "json_object"}
    req = urllib.request.Request(cfg["url"], data=json.dumps(body).encode(),
                                 method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("Authorization", "Bearer " + os.environ.get("P5_MODEL_KEY", "ollama"))
    req.add_header("User-Agent", "hermes-worker")
    try:
        with model_opener().open(req, timeout=cfg["timeout"]) as r:
            payload = json.loads(r.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as e:
        raise ModelError(f"HTTP {e.code} from the model endpoint: "
                         f"{e.read().decode('utf-8', 'replace')[:300]}")
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
        reasoned = len(msg.get("reasoning") or msg.get("reasoning_content") or "")
        raise EmptyReply("the model spent its whole generation budget reasoning and "
                         f"returned no answer ({reasoned} chars of reasoning, "
                         f"max_tokens={cfg['max_tokens']})")
    return content


def extract_json(raw):
    """(obj, None) or (None, reason). Tolerant of a ```json fence and a leading
    preamble - the JSON is still the model's. NOT tolerant of truncated or absent
    JSON, which is the case that must reach the retry loop."""
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


class NeedsFile(Exception):
    """The model says the work needs a path the ticket did not declare. This is a
    correct, useful outcome - it tells a human the plan was wrong - so it is a
    control-flow signal rather than an error."""

    def __init__(self, path, reason):
        super().__init__(f"needs {path}: {reason}")
        self.path = path
        self.reason = reason


def ask_file(cfg, messages, requested, declared, existing, rep=None):
    """ONE model call for ONE file. Returns the contents string.

    Retries with the rejection fed back, then STOPS LOUDLY. There is no path here
    that returns contents the model did not send, and none that returns contents
    for a path other than `requested`.
    """
    attempts = cfg["retries"] + 1
    convo = list(messages)
    last_raw = ""
    # Whether the FINAL rejection was "you weakened a test". It gets its own exit
    # code because "the model cannot write JSON" and "the model tried to delete a
    # test to go green" are different problems for whoever reads the code.
    weakened = None
    for n in range(1, attempts + 1):
        try:
            raw = chat(convo, cfg)
        except ModelError as e:
            last_raw = f"<no reply: {e}>"
            weakened = None
            warn(f"{requested}: attempt {n}/{attempts}: {e}")
            if n == attempts:
                break
            time.sleep(min(2 ** (n - 1), 8))
            continue
        obj, err = extract_json(raw)
        contents = None
        weakened = None
        if err is None:
            # The sanctioned way to say "this ticket is under-specified".
            if "needs_file" in obj and obj.get("needs_file"):
                need = str(obj["needs_file"]).strip()
                if need in declared:
                    err = (f"needs_file {need!r} IS in Files touched; answer about "
                           f"{requested!r} instead")
                else:
                    raise NeedsFile(need, str(obj.get("reason") or "not stated").strip())
            if err is None:
                contents, err = validate_file_reply(obj, requested, cfg)
            if err is None:
                err = weakening_error(requested, existing.get(requested), contents)
                weakened = err
        last_raw = raw
        if err is None:
            return contents
        print(redact(f"    {requested}: reply {n}/{attempts} rejected: {err}"),
              file=sys.stderr, flush=True)
        convo = convo + [
            {"role": "assistant", "content": raw[:4000]},
            {"role": "user", "content":
                f"REJECTED: {err}\n"
                f"Reply again with ONLY the JSON object described above, for the file "
                f"{requested!r} and no other. No prose, no explanation, no markdown fence."},
        ]
    if weakened:
        if rep:
            rep.comment(f"Stopping: the model's replies for `{requested}` kept weakening "
                        f"an existing test.\n\n{weakened}\n\nNothing was written and "
                        "nothing was committed. `ORCHESTRATOR.md` forbids weakening, "
                        "skipping or deleting a test to make a run pass; if the test is "
                        "genuinely wrong, that is a human's call, not a worker's.")
        die(f"the model's last reply for {requested} would weaken a test: {weakened}. "
            "Every attempt was refused, nothing was written and nothing was "
            "committed. A failing test is the most useful output this system "
            "produces, so it is never switched off to get a green run.",
            EXIT_TEST_WEAK)
    if rep:
        rep.comment(f"Stopping: the model could not produce usable contents for "
                    f"`{requested}` in {attempts} attempt(s), so **nothing was written "
                    "and nothing was committed**. The last reply was refused for this "
                    "reason:\n\n```\n" + clip(last_raw, 1200) + "\n```\n\n"
                    "Nothing was invented to fill the gap. This is a model-capability "
                    "finding, not a code review.")
    die(f"the model did not produce usable contents for {requested} in "
        f"{attempts} attempt(s). Nothing was written and nothing was committed; "
        f"the run stops here so a human can see what the model actually said.\n"
        f"--- last raw reply ---\n{clip(last_raw, 4000)}\n--- end of raw reply ---",
        EXIT_MODEL)


def validate_file_reply(obj, requested, cfg):
    """(contents, None) or (None, 'why not').

    The path check is the load-bearing one: a reply that answers about a
    DIFFERENT file is the model trying to write outside the ticket, and it is
    refused here rather than filtered later.
    """
    if "path" not in obj:
        return None, ('missing key "path"; the reply must be '
                      '{"path": "<the requested file>", "contents": "<full text>"}')
    if str(obj["path"]).strip() != requested:
        return None, (f'"path" is {str(obj["path"]).strip()!r} but this call is about '
                      f"{requested!r}. One file per reply, and only the file asked "
                      "about; other files are other calls or other tickets")
    if "files" in obj or "extra_files" in obj or "additional_files" in obj:
        return None, ("the reply carries extra files; exactly one file per reply, "
                      f"the one named {requested!r}")
    if "contents" not in obj:
        return None, 'missing key "contents"'
    contents = obj["contents"]
    if isinstance(contents, list):
        if not all(isinstance(x, str) for x in contents):
            return None, '"contents" as a list must be a list of line strings'
        contents = "\n".join(contents)
        if contents and not contents.endswith("\n"):
            contents += "\n"
    if not isinstance(contents, str):
        return None, f'"contents" must be a string, got {type(contents).__name__}'
    if not contents.strip():
        return None, '"contents" is empty; a file with no content is not an implementation'
    if len(contents.encode("utf-8", "replace")) > cfg["max_file_bytes"]:
        return None, (f'"contents" is larger than {cfg["max_file_bytes"]} bytes; '
                      "split the work or shorten the file")
    if "\x00" in contents:
        return None, '"contents" contains a NUL byte'
    if not contents.endswith("\n"):
        contents += "\n"
    return contents, None


def looks_like_test(path):
    base = os.path.basename(path)
    return (base.startswith("test_") or base.endswith(("_test.py", ".test.js", ".test.ts",
                                                       "_spec.rb", "_test.go"))
            or path.startswith("tests/") or "/tests/" in "/" + path)


def weakening_error(path, old, new):
    """ORCHESTRATOR.md: never weaken, skip or delete a test to make a run pass.
    Checked mechanically for an EXISTING test file, because "a failing test is
    the most useful output this system produces" is worth more than one green
    run. Only applies where there is an old version to compare against; a brand
    new test file has nothing to weaken."""
    if old is None or not looks_like_test(path):
        return None
    was = set(TEST_DEF_RE.findall(old))
    now = set(TEST_DEF_RE.findall(new))
    gone = sorted(was - now)
    if gone:
        return (f"the reply removes existing test(s) {', '.join(gone)} from {path}. "
                "A test may be added or extended, never deleted to make a run pass")
    if SKIP_RE.search(new) and not SKIP_RE.search(old):
        return (f"the reply adds a skip/xfail marker to {path}. A failing test is "
                "a finding to report, not something to switch off")
    return None


def dependency_error(path, old, new, readme):
    """Narrow, deliberate check: a ticket may declare a manifest, but a package
    the target README never mentions is a dependency the README does not
    sanction. Line-based and manifest-only - it will not catch an import added
    to source code, which is stated as a known gap rather than papered over.

    A project with no README sanctions nothing. That is the conservative reading
    and also the loud one: the run has already warned that it is writing code
    against a specification that is not there."""
    if os.path.basename(path) not in MANIFESTS:
        return None
    readme_l = (readme or "").lower()
    added = [ln.strip() for ln in new.splitlines()
             if ln.strip() and ln.strip() not in (old or "").splitlines()]
    unsanctioned = []
    for line in added:
        if line.startswith("#") or line.startswith("//"):
            continue
        m = re.match(r'^\s*"?([A-Za-z][A-Za-z0-9._-]{1,40})"?\s*[:=<>~!\s"]', line + " ")
        if not m:
            continue
        name = m.group(1)
        if name.lower() in ("name", "version", "description", "requires", "dependencies",
                            "python", "authors", "readme", "license", "scripts",
                            "requires-python", "build-backend", "module", "go", "main"):
            continue
        if name.lower() not in readme_l:
            unsanctioned.append(name)
    if unsanctioned:
        return (f"{path} would add {', '.join(sorted(set(unsanctioned)))}, which the "
                "target README does not mention. ORCHESTRATOR.md: never add a "
                "dependency the target README does not sanction")
    return None


# --------------------------------------------------------------------------- #
# prompt - everything the model needs for ONE file, in one message
# --------------------------------------------------------------------------- #

SYSTEM = ("You are a code-writing function inside a script. You do not run "
          "commands, browse, or choose what happens next. You are given one file "
          "path and you answer with exactly one JSON object and nothing else: no "
          "prose, no explanation, no markdown fence.")

FILE_SCHEMA = '{"path": "<the requested path, verbatim>", "contents": "<the complete file>"}'
NEEDS_SCHEMA = '{"needs_file": "<the path you would need>", "reason": "<one line>"}'


def file_prompt(cfg, ticket, target, readme, contents, failure=None):
    """One user message. `contents` maps declared path -> current text (either
    what is in the checkout or what this run has produced so far)."""
    others = [p for p in ticket["files"] if p != target]
    ctx = []
    for p in others:
        if p in contents:
            ctx.append(f"--- {p} (current contents) ---\n"
                       f"{clip(contents[p], cfg['context_bytes'], p)}")
        else:
            ctx.append(f"--- {p} (does not exist yet; another call in this same run "
                       f"will write it) ---")
    current = contents.get(target)
    body = [
        f"TASK: return the complete new contents of ONE file: {target}",
        "",
        f"TARGET FILE: {target}",
        "",
        "TICKET",
        f"  goal: {ticket['goal']}",
        f"  acceptance command (it will be run for real): {ticket['acceptance']}",
        "  details:",
        "    " + ticket["details"].replace("\n", "\n    "),
        "",
        "FILES THIS TICKET MAY TOUCH (no others exist for you):",
    ]
    body += [f"  - {p}" + ("   <-- this call" if p == target else "") for p in ticket["files"]]
    body += [
        "",
        "TARGET PROJECT README (the specification; do not modify it)",
        clip(readme or "(this repository has no README)", 6000, "README"),
        "",
    ]
    if current is None:
        body += [f"{target} does not exist yet. Return its complete initial contents.", ""]
    else:
        body += [f"--- {target} (current contents; return the COMPLETE new version) ---",
                 clip(current, cfg["context_bytes"], target), ""]
    if ctx:
        body += ["OTHER FILES IN THIS TICKET"] + ctx + [""]
    if failure:
        body += [
            "THE ACCEPTANCE COMMAND FAILED with the file contents you produced.",
            f"  command: {ticket['acceptance']}",
            "  output (tail):",
            "    " + tail(failure, 3000).replace("\n", "\n    "),
            "",
            f"Fix {target} so that command passes. Do not change the command, do not "
            "weaken or delete a test, and do not ask for another file unless the work "
            "genuinely cannot be done without one.",
            "",
        ]
    body += [
        "RULES",
        f"  - Answer about {target} and no other file. Other paths are other calls.",
        "  - Do not create, mention as created, or write any file outside the list above.",
        "  - Never modify the README. Never delete or skip a test.",
        "  - Add no third-party dependency the README does not already sanction.",
        "  - Return the WHOLE file, not a diff, not a fragment, not an ellipsis.",
        "",
        "REPLY with exactly one JSON object:",
        f"  {FILE_SCHEMA}",
        "If, and only if, this file genuinely cannot be written without a file that is "
        "NOT in the list above, reply instead with:",
        f"  {NEEDS_SCHEMA}",
    ]
    return [{"role": "system", "content": SYSTEM},
            {"role": "user", "content": "\n".join(body)}]


# --------------------------------------------------------------------------- #
# git and subprocess - the token never appears in argv, a file, or a remote URL
# --------------------------------------------------------------------------- #

def run(cmd, cwd=None, timeout=300, env=None):
    """(rc, combined output). Never through a shell: the acceptance command is ONE
    command by contract, and a shell would let a malformed ticket become
    arbitrary chained execution."""
    try:
        p = subprocess.run(cmd, cwd=cwd, timeout=timeout, env=env,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    except FileNotFoundError:
        return 127, f"{cmd[0]}: command not found"
    except subprocess.TimeoutExpired as e:
        out = (e.output or b"").decode("utf-8", "replace")
        return 124, out + f"\n[timed out after {timeout}s]"
    return p.returncode, p.stdout.decode("utf-8", "replace")


def git_env(cfg, workspace):
    """A GIT_ASKPASS helper, so the credential is read from the environment at
    the moment git asks for it. The alternative - a token in the clone URL - puts
    it in argv, in .git/config, and in every push's error message.

    The helper script contains the NAME of the variable, never its value."""
    env = dict(os.environ)
    env["GIT_TERMINAL_PROMPT"] = "0"
    env["GIT_CONFIG_NOSYSTEM"] = "0"
    env["GIT_ADVICE_DETACHED_HEAD"] = "false"
    if cfg["token"]:
        helper = os.path.join(workspace, ".git-askpass")
        with open(helper, "w", encoding="utf-8") as fh:
            fh.write('#!/bin/sh\ncase "$1" in\n'
                     'Username*) printf %s "x-access-token" ;;\n'
                     '*) printf %s "$GITHUB_TOKEN" ;;\nesac\n')
        os.chmod(helper, 0o700)
        env["GIT_ASKPASS"] = helper
        env["GITHUB_TOKEN"] = cfg["token"]
    return env


def git(cfg, args, cwd, timeout=300):
    ident = ["-c", "user.name=hermes-worker",
             "-c", "user.email=hermes-worker@users.noreply.github.com",
             "-c", "advice.detachedHead=false", "-c", "protocol.file.allow=always"]
    return run(["git"] + ident + list(args), cwd=cwd, timeout=timeout,
               env=git_env(cfg, cfg["workspace"]))


def clone(cfg, ticket):
    """Shallow, into the one writable mount. Returns (repo_dir, default_branch)."""
    ws = cfg["workspace"]
    if not os.path.isdir(ws):
        die(f"workspace {ws} does not exist. Inside a worker it is the tmpfs the "
            "spawn dispatcher mounts (WORKER_WORK_PATH); outside one, pass "
            "--workspace.", EXIT_USAGE)
    repo_dir = os.path.join(ws, "repo")
    if os.path.exists(repo_dir):
        die(f"{repo_dir} already exists; refusing to work in a dirty workspace",
            EXIT_USAGE)
    rc, out = git(cfg, ["clone", "--depth", "1", cfg["origin"], repo_dir], cwd=ws, timeout=600)
    if rc != 0:
        die("clone failed: " + tail(out, 1500), EXIT_GIT)
    rc, head = git(cfg, ["rev-parse", "--abbrev-ref", "HEAD"], cwd=repo_dir)
    if rc != 0:
        die("cannot read the default branch after cloning: " + tail(head, 500), EXIT_GIT)
    default_branch = head.strip()
    branch = branch_name(ticket)
    rc, out = git(cfg, ["ls-remote", "--heads", "origin", branch], cwd=repo_dir)
    if rc == 0 and out.strip():
        die(f"branch {branch} already exists on the remote. A worker never "
            "force-pushes, so this ticket needs a human: either the previous "
            "attempt's branch is still open, or two workers were handed the same "
            "issue.", EXIT_GIT)
    rc, out = git(cfg, ["checkout", "-b", branch], cwd=repo_dir)
    if rc != 0:
        die(f"cannot create branch {branch}: " + tail(out, 500), EXIT_GIT)
    return repo_dir, default_branch, branch


def scope_violations(cfg, repo_dir, declared):
    """Every path git sees as changed that the ticket did not declare.

    This is the enforcement of "change only the files under Files touched". It is
    a GIT-level check on purpose: the writer only ever writes declared paths, but
    the acceptance command runs project code, and project code can create files.
    A generated file is exactly as much a scope violation as an edited one.
    """
    rc, out = git(cfg, ["status", "--porcelain", "-uall"], cwd=repo_dir)
    if rc != 0:
        die("git status failed: " + tail(out, 500), EXIT_GIT)
    bad = []
    for line in out.splitlines():
        if not line.strip():
            continue
        path = line[3:].strip()
        if " -> " in path:                      # a rename: both sides count
            for part in path.split(" -> "):
                p = part.strip().strip('"')
                if p not in declared and not ARTIFACT_RE.search(p):
                    bad.append(p)
            continue
        path = path.strip('"')
        if path in declared or ARTIFACT_RE.search(path):
            continue
        bad.append(path)
    return sorted(set(bad))


def staged_paths(cfg, repo_dir):
    rc, out = git(cfg, ["diff", "--cached", "--name-only"], cwd=repo_dir)
    if rc != 0:
        die("git diff --cached failed: " + tail(out, 500), EXIT_GIT)
    return [p for p in out.splitlines() if p.strip()]


def write_files(repo_dir, contents, declared):
    """Write the declared files, and only them. `declared` is passed in and
    re-checked here rather than trusted from the caller, so a future refactor
    cannot make this function write an arbitrary path."""
    for path, text in contents.items():
        if path not in declared:
            die(f"internal: refusing to write {path}, which the ticket did not "
                "declare", EXIT_SCOPE)
        full = os.path.join(repo_dir, path)
        if os.path.relpath(full, repo_dir).startswith(".."):
            die(f"internal: {path} escapes the checkout", EXIT_SCOPE)
        os.makedirs(os.path.dirname(full) or repo_dir, exist_ok=True)
        with open(full, "w", encoding="utf-8") as fh:
            fh.write(text)


def read_existing(repo_dir, paths):
    out = {}
    for p in paths:
        full = os.path.join(repo_dir, p)
        if os.path.isfile(full):
            try:
                with open(full, encoding="utf-8") as fh:
                    out[p] = fh.read()
            except (OSError, UnicodeDecodeError) as e:
                warn(f"cannot read existing {p}: {e}")
    return out


def read_readme(repo_dir):
    for name in ("README.md", "readme.md", "README.rst", "README"):
        full = os.path.join(repo_dir, name)
        if os.path.isfile(full):
            with open(full, encoding="utf-8", errors="replace") as fh:
                return fh.read()
    return ""


# --------------------------------------------------------------------------- #
# reporting on the issue
# --------------------------------------------------------------------------- #

class Reporter:
    """Comments, and the heartbeat the dispatcher's reaper watches for.

    Heartbeats are posted by the SCRIPT at points it knows it is about to be slow
    (a model call, a test run), not by a timer and not by the model. A worker
    that stops heartbeating is assumed dead after P4_WORKER_TIMEOUT_MINUTES.
    """

    def __init__(self, gh, issue, cfg):
        self.gh = gh
        self.issue = issue
        self.cfg = cfg
        self.nonce = ""
        self.last = 0.0

    def find_nonce(self):
        try:
            comments = self.gh.list_comments(self.issue)
        except GitHubError as e:
            warn(f"cannot list comments: {e}")
            return
        for c in reversed(comments):
            body = c.get("body") or ""
            if CLAIM_MARK in body:
                m = re.search(r'"nonce"\s*:\s*"([0-9a-fA-F]+)"', body)
                if m:
                    self.nonce = m.group(1)
                    return

    def comment(self, body):
        try:
            self.gh.create_comment(self.issue, redact(body))
        except GitHubError as e:
            # A comment that cannot be posted must not mask the real outcome.
            warn(f"could not comment on #{self.issue}: {e}")

    def heartbeat(self, what, force=False):
        now = time.time()
        if not force and (now - self.last) < self.cfg["heartbeat_seconds"]:
            return
        self.last = now
        self.comment(f'<!-- {HEARTBEAT_MARK} {{"nonce":"{self.nonce}"}} -->\n'
                     f"Worker on issue #{self.issue}: {what}")

    def defect(self, why):
        self.comment(f'<!-- {DEFECT_MARK} {{"issue":{self.issue},"kind":"malformed-ticket"}} -->\n'
                     f"**This ticket cannot be worked as written.** No branch was created "
                     f"and no code was generated.\n\n{why}\n\n"
                     "This is a planning defect: `ORCHESTRATOR.md` fixes the ticket format, "
                     "and a worker that guessed around a missing section would produce a "
                     "plausible pull request against the wrong intent. Fix the ticket (a "
                     "human act) and re-approve it.")


# --------------------------------------------------------------------------- #
# the loop
# --------------------------------------------------------------------------- #

def choose_retry_target(ticket, failure, contents):
    """Which file to re-ask after a failing acceptance command.

    Deterministic, and the SCRIPT's decision - not the model's. The order below is
    not arbitrary: the acceptance command is nearly always a test invocation, so
    the test file's path appears in the failure output of *every* failure,
    including the ones caused entirely by the implementation. "Named in the
    output" therefore discriminates nothing on its own, and a naive version of
    this function re-asks the test file forever while the broken implementation
    sits untouched (measured: it turned a recoverable failure into an exhausted
    retry budget).

    So: an implementation file named in the failure, else the first
    implementation file, else a test file named in the failure, else the first
    declared file. The choice is printed so a human can see why.
    """
    named = [p for p in ticket["files"] if p in (failure or "")]
    impl_named = [p for p in named if not looks_like_test(p)]
    if impl_named:
        return impl_named[0], "it is named in the failure output"
    impl = [p for p in ticket["files"] if not looks_like_test(p)]
    if impl:
        return impl[0], ("it is the first declared implementation file; a failing test "
                         "command names the test file whether or not the test is at fault")
    if named:
        return named[0], "it is the only declared file named in the failure output"
    return ticket["files"][0], "it is the first declared file"


def main(argv=None):
    cfg = config(argv)
    say(f"worker: issue #{cfg['issue']} in {cfg['repo']}")
    say(f"  model {cfg['model']} at {cfg['url']}  "
        f"(retries {cfg['retries']}, acceptance attempts {cfg['attempts']})")
    say(f"  workspace {cfg['workspace']}, origin "
        f"{'(fixture) ' if cfg['github'] else ''}{cfg['origin']}")

    gh = open_github(cfg)
    rep = Reporter(gh, cfg["issue"], cfg)

    # ---- 1. the ticket, BEFORE the clone and before the first model call ---- #
    try:
        issue = gh.get_issue(cfg["issue"])
    except GitHubError as e:
        die(f"cannot read issue #{cfg['issue']}: {e}", EXIT_GIT)
    if issue.get("state") == "closed":
        die(f"issue #{cfg['issue']} is closed; nothing to do", EXIT_TICKET)
    labels = [l["name"] if isinstance(l, dict) else str(l) for l in (issue.get("labels") or [])]
    if "spec" in labels:
        die(f"issue #{cfg['issue']} carries the `spec` label: it is a specification "
            "to plan from, not an implementation ticket", EXIT_TICKET)

    ticket, err = parse_ticket(issue)
    if err:
        rep.find_nonce()
        rep.defect(err)
        die(f"issue #{cfg['issue']} does not conform to ORCHESTRATOR.md: {err}\n"
            "Reported on the issue. Nothing was cloned, no model call was made and "
            "no file was written.", EXIT_TICKET)

    say(f"  ticket: {ticket['title']!r}")
    say(f"  files:  {', '.join(ticket['files'])}")
    say(f"  accept: {ticket['acceptance']}")
    declared = set(ticket["files"])

    rep.find_nonce()
    rep.heartbeat(f"started; implementing {len(ticket['files'])} file(s)", force=True)

    # ---- 2. clone and branch ----------------------------------------------- #
    repo_dir, default_branch, branch = clone(cfg, ticket)
    say(f"  cloned (depth 1), default branch {default_branch}, working on {branch}")

    readme = read_readme(repo_dir)
    if not readme:
        warn("the target repository has no README; the model is being asked to write "
             "code against a specification that is not there")
    existing = read_existing(repo_dir, ticket["files"])
    contents = dict(existing)

    # ---- 3. one model call per declared file, NOTHING written yet ----------- #
    # Held in memory until every file has a validated reply, so the
    # "needs another file" outcome genuinely writes nothing.
    produced = {}
    try:
        for path in ticket["files"]:
            rep.heartbeat(f"asking the model for {path}")
            say(f"  model call: {path}"
                f"{' (rewriting an existing file)' if path in existing else ''}")
            text = ask_file(cfg, file_prompt(cfg, ticket, path, readme, contents),
                            path, declared, existing, rep)
            dep = dependency_error(path, existing.get(path), text, readme)
            if dep:
                rep.comment(f"Stopping: {dep}\n\nNothing was committed.")
                die(dep, EXIT_DEPENDENCY)
            produced[path] = text
            contents[path] = text
            say(f"    {path}: {len(text.splitlines())} lines, {len(text)} chars")
    except NeedsFile as need:
        rep.comment(f"Blocked: this needs `{need.path}`, which is not in Files touched. "
                    f"Reason: {need.reason}.\n\n"
                    "No file was written and nothing was committed. Per "
                    "`ORCHESTRATOR.md` a worker changes only its declared files; "
                    "editing this one silently would collide with whoever owns it. "
                    "Amend the ticket (or split it) and re-approve.")
        die(f"needs `{need.path}`, which the ticket did not declare: {need.reason}. "
            "Reported on the issue; nothing written.", EXIT_NEEDS_FILE)

    # ---- 4. write, then run the acceptance command -------------------------- #
    write_files(repo_dir, produced, declared)
    say(f"  wrote {len(produced)} file(s)")

    install_declared_dependencies(cfg, repo_dir, rep)

    accept_cmd = shlex.split(ticket["acceptance"])
    failure = None
    passed = False
    accept_output = ""
    for attempt in range(1, cfg["attempts"] + 1):
        rep.heartbeat(f"running the acceptance command (attempt {attempt}/{cfg['attempts']})")
        rc, out = run(accept_cmd, cwd=repo_dir, timeout=cfg["acceptance_timeout"])
        say(f"  acceptance attempt {attempt}/{cfg['attempts']}: "
            f"`{ticket['acceptance']}` -> exit {rc}")
        if rc == 0:
            passed = True
            failure = None
            accept_output = out
            break
        failure = out
        if rc == 127:
            warn("the acceptance command does not exist in this image. That is the "
                 "'no new dependencies' rule enforced structurally, not a bug to "
                 "work around.")
        if attempt == cfg["attempts"]:
            break
        target, why = choose_retry_target(ticket, failure, contents)
        say(f"    retrying {target}: {why}")
        rep.heartbeat(f"acceptance failed; re-asking the model for {target}")
        try:
            text = ask_file(cfg, file_prompt(cfg, ticket, target, readme, contents,
                                             failure=failure),
                            target, declared, existing, rep)
        except NeedsFile as need:
            rep.comment(f"Blocked: this needs `{need.path}`, which is not in Files "
                        f"touched. Reason: {need.reason}.\n\nNothing was committed. "
                        "The branch exists only inside the worker's own workspace.")
            die(f"needs `{need.path}` during the retry: {need.reason}",
                EXIT_NEEDS_FILE)
        dep = dependency_error(target, existing.get(target), text, readme)
        if dep:
            rep.comment(f"Stopping: {dep}\n\nNothing was committed.")
            die(dep, EXIT_DEPENDENCY)
        contents[target] = text
        produced[target] = text
        write_files(repo_dir, {target: text}, declared)

    if not passed:
        rep.comment(f"The acceptance command did not pass after {cfg['attempts']} "
                    f"attempt(s), so **nothing was committed and no pull request was "
                    f"opened**.\n\n"
                    f"```\n$ {ticket['acceptance']}\n{tail(failure or '', 2500)}\n```\n\n"
                    "The command was run exactly as the ticket states it and was not "
                    "weakened. Either the ticket is under-specified or the model cannot "
                    "write this file; both need a human.")
        die(f"acceptance command still failing after {cfg['attempts']} attempt(s); "
            "nothing was committed.", EXIT_ACCEPTANCE)

    # ---- 5. the project's full test suite ---------------------------------- #
    suite_cmd = shlex.split(cfg["test_command"])
    rep.heartbeat("running the project's full test suite")
    rc, suite_out = run(suite_cmd, cwd=repo_dir, timeout=cfg["suite_timeout"])
    say(f"  full suite: `{cfg['test_command']}` -> exit {rc}")
    if rc != 0:
        rep.comment(f"The acceptance command passed but the project's full test suite "
                    f"failed, so **nothing was committed**.\n\n"
                    f"```\n$ {cfg['test_command']}\n{tail(suite_out, 2500)}\n```\n\n"
                    "A test this ticket did not write is now failing. That is a real "
                    "finding and it is reported rather than repaired: no test was "
                    "deleted, skipped or loosened to get a green run.")
        die("the full test suite failed; nothing was committed. A failing test is the "
            "most useful output this system produces, so it is reported as-is.",
            EXIT_SUITE)

    # ---- 6. the scope gate, before anything is committed -------------------- #
    stray = scope_violations(cfg, repo_dir, declared)
    if stray:
        rep.comment("Stopping: the working tree contains file(s) this ticket did not "
                    "declare, so **nothing was committed**.\n\n"
                    + "\n".join(f"- `{p}`" for p in stray) +
                    "\n\nA worker changes only the files under `Files touched` - that "
                    "list is why this ticket could run beside others. A file created "
                    "by the code or by the acceptance run counts too. Either the "
                    "ticket should declare it, or the implementation should not "
                    "produce it.")
        die("file(s) outside the declared list changed: " + ", ".join(stray) +
            ". Nothing was committed.", EXIT_SCOPE)

    # ---- 7. commit, push, pull request -------------------------------------- #
    rc, out = git(cfg, ["add", "--"] + ticket["files"], cwd=repo_dir)
    if rc != 0:
        die("git add failed: " + tail(out, 500), EXIT_GIT)
    staged = staged_paths(cfg, repo_dir)
    outside = sorted(set(staged) - declared)
    if outside:
        die("internal: the staged diff reaches outside the declared list "
            f"({', '.join(outside)}); refusing to commit", EXIT_SCOPE)
    if not staged:
        rep.comment("Stopping: the acceptance command passes but the declared files "
                    "are byte-identical to the default branch, so there is nothing "
                    "to commit. Either the work was already done, or the ticket is "
                    "not describing a change.")
        die("nothing staged: the declared files are unchanged", EXIT_ERROR)
    missing = [p for p in produced if p not in staged]
    if missing:
        die("git refused to stage " + ", ".join(missing) +
            " (are they ignored by .gitignore in the target repo?)", EXIT_GIT)

    message = (f"{ticket['title'] or 'Implement issue'}\n\n"
               f"{ticket['goal']}\n\nCloses #{ticket['number']}\n")
    rc, out = git(cfg, ["commit", "-m", message], cwd=repo_dir)
    if rc != 0:
        die("git commit failed: " + tail(out, 800), EXIT_GIT)
    rc, sha = git(cfg, ["rev-parse", "HEAD"], cwd=repo_dir)
    say(f"  committed {sha.strip()[:12]} touching {len(staged)} file(s): {', '.join(staged)}")

    rep.heartbeat("pushing the branch", force=True)
    # Never a forced push, in any of its spellings. The refspec is explicit so
    # that a stray HEAD cannot push somewhere else, and the default branch is
    # never a target here.
    rc, out = git(cfg, ["push", "--set-upstream", "origin",
                        f"HEAD:refs/heads/{branch}"], cwd=repo_dir, timeout=600)
    if rc != 0:
        die("git push failed: " + tail(out, 1200), EXIT_GIT)
    say(f"  pushed {branch}")

    pr_body = (f"Closes #{ticket['number']}\n\n"
               f"{ticket['goal']}\n\n"
               f"### Files changed\n" + "\n".join(f"- `{p}`" for p in staged) + "\n\n"
               f"### Acceptance command\n```\n$ {ticket['acceptance']}\n"
               f"{tail(accept_output, 1200)}\n```\n\n"
               f"### Full test suite\n```\n$ {cfg['test_command']}\n"
               f"{tail(suite_out, 1200)}\n```\n\n"
               "Opened by a worker agent. It cannot merge this and did not try: "
               "humans merge.")
    try:
        pr = gh.create_pull(ticket["title"] or f"Issue #{ticket['number']}",
                            branch, default_branch, pr_body)
    except GitHubError as e:
        rep.comment(f"The work is pushed to `{branch}` and both commands pass, but the "
                    f"pull request could not be created: {e}")
        die(f"pull request creation failed: {e}", EXIT_GIT)
    number = pr.get("number")
    say(f"  opened pull request #{number}")

    rep.comment(f"Done. Pull request #{number} from `{branch}` -> `{default_branch}`, "
                f"body references `Closes #{ticket['number']}`.\n\n"
                f"- acceptance `{ticket['acceptance']}` -> exit 0\n"
                f"- full suite `{cfg['test_command']}` -> exit 0\n"
                f"- files committed: " + ", ".join(f"`{p}`" for p in staged) + "\n\n"
                "Not merged, and not mergeable by this worker. The dispatcher "
                "validates the branch independently; this comment is for the human.")
    return EXIT_OK


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(EXIT_ERROR)

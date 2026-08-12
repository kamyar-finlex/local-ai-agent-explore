#!/usr/bin/env bash
# Verification of the WORKER (worker.py), in the same discipline as
# verify-planner.sh and verify-dispatch.sh: PASS/FAIL lines, a POSITIVE CONTROL
# in every suite, and a non-zero exit if anything fails.
#
#   ./verify-worker.sh                 # everything, including the mutation control
#   ./verify-worker.sh image           # + one run inside hermes-worker:latest,
#                                      #   read-only rootfs, uid 10001, /work tmpfs,
#                                      #   started the way the dispatcher starts it
#   P5_SKIP_MUTATION=1 ./verify-worker.sh    # the suites only (used by the mutants)
#
# NO LIVE MODEL AND NO GITHUB. Every run below drives the real worker.py against
#   - a mock OpenAI-compatible endpoint on loopback serving p5-fixtures/model/replies.json,
#   - a fixture GitHub (`--github fixture:...`) that is a JSON file, and
#   - a real local git repository (`file://.../origin.git`) built from p5-fixtures/repo.
# HTTPS_PROXY is deliberately pointed at a dead port for the whole run, so a
# worker that reached api.github.com by some path nobody checked would fail
# rather than quietly succeed.
#
# What is being verified is not "is the generated code good" - that is the
# model's problem - but "does the SCRIPT stay in control of the model". Eight
# independent questions:
#
#   1. Does the worker refuse a non-conforming ticket BEFORE cloning and before
#      the first model call?  A malformed ticket is a planning defect to report,
#      and a worker that guesses around it produces a plausible pull request
#      against the wrong intent.
#   2. Does a well-formed ticket plus good replies really produce a branch and a
#      commit touching ONLY the declared files?  This is the positive control:
#      almost every other assertion here is of the form "X must NOT happen", and
#      a worker that does nothing at all satisfies all of them.
#   3. Is a reply that proposes an extra file refused, and the extra file absent
#      afterwards - from the commit, from the branch and from the workspace?
#   4. Does a failing acceptance command trigger a retry with the failure fed
#      back, and does EXHAUSTING the retries fail loudly instead of committing
#      anyway?
#   5. Are the hard prohibitions structural?  The worker must have no code path
#      that writes a label, merges, or force-pushes, must never edit the README,
#      and must refuse to delete or skip a test even when that would go green.
#   6. Does the needs-another-file outcome comment, write nothing, and exit with
#      its own code?
#   7. Are the outcomes actually distinguishable - one exit code each?
#   8. Does the harness itself have teeth?  The mutation control breaks the
#      file-scope check two different ways and requires the suite to go RED.
#
# The mock is checked to have been exercised: if the endpoint served no calls,
# the model-driven suites would all pass vacuously, and that is reported as a
# failure rather than a clean sweep.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER="${P5_WORKER_SCRIPT:-$HERE/worker.py}"
FIX="$HERE/p5-fixtures"
REPLIES="$FIX/model/replies.json"
ISSUES="$FIX/issues.json"
CONTRACT="$HERE/ORCHESTRATOR.md"
REPO="example/target"
MODE="${1:-fixtures}"
# The container suite needs the mock reachable from inside a container, so in
# that mode only, the endpoint binds every interface instead of loopback.
MOCK_BIND="127.0.0.1"
[ "$MODE" = image ] && MOCK_BIND="0.0.0.0"

# A deliberately recognisable fake. No real credential is used or needed here,
# and the hygiene suite greps every byte of captured output for this string.
export GITHUB_TOKEN="p5-fake-worker-token-4Kd8-never-log-me"
# Offline by construction: if anything tries to leave through a proxy it fails.
export HTTPS_PROXY="http://127.0.0.1:9"
export https_proxy="$HTTPS_PROXY"
export HTTP_PROXY="$HTTPS_PROXY"
export http_proxy="$HTTPS_PROXY"
unset NO_PROXY no_proxy 2>/dev/null

WORK="$(mktemp -d "${TMPDIR:-/tmp}/p5-worker.XXXXXX")"
MOCK_STATE="$WORK/mock"
mkdir -p "$MOCK_STATE"

cleanup() {
  if [ -n "${MOCK_PID:-}" ]; then
    kill "$MOCK_PID" 2>/dev/null
    wait "$MOCK_PID" 2>/dev/null
  fi
  rm -rf "$WORK" "$HERE/__pycache__"
}
trap cleanup EXIT

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
note() { printf '        %s\n' "$1"; }

for f in "$WORKER" "$REPLIES" "$ISSUES" "$CONTRACT" "$FIX/repo/README.md"; do
  [ -f "$f" ] || { echo "missing: $f" >&2; exit 2; }
done
command -v git >/dev/null || { echo "git is required" >&2; exit 2; }
# pytest is a hard prerequisite, not an optional extra: the fixture project's
# acceptance commands ARE pytest invocations, so skipping them would leave the
# suite passing without exercising the thing it exists to test.
#
# Getting it is awkward through no fault of the user. A Homebrew python3 is PEP
# 668 "externally managed", so `pip install pytest` is refused, and telling
# someone to --break-system-packages their interpreter for a test harness is not
# a reasonable ask. So provision a throwaway venv beside the harness and put it
# first on PATH. Override with PYTEST_VENV=/path if you would rather point at
# your own.
if ! python3 -c 'import pytest' 2>/dev/null; then
  VENV="${PYTEST_VENV:-$HERE/.venv-verify}"
  # Gate on pytest, not on the interpreter. A venv left half-provisioned by an
  # interrupted run has a python3 and no pytest, and checking for the
  # interpreter would reuse it forever without ever installing anything.
  if ! "$VENV/bin/python3" -c 'import pytest' 2>/dev/null; then
    echo "provisioning a local venv for pytest at ${VENV##*/} (one-off)..." >&2
    [ -x "$VENV/bin/python3" ] || python3 -m venv "$VENV" 2>&1 | tail -2 >&2
    "$VENV/bin/python3" -m pip install -q --disable-pip-version-check pytest 2>&1 | tail -2 >&2
  fi
  [ -x "$VENV/bin/python3" ] && PATH="$VENV/bin:$PATH" && export PATH
fi
python3 -c 'import pytest' 2>/dev/null || {
  echo "pytest must be importable: the fixture project's acceptance commands are" >&2
  echo "pytest invocations, and skipping them would make this suite vacuous." >&2
  exit 2; }

################################################################################
echo
echo "STATIC: the prohibitions that must be absent from the code, not just the prompt"
################################################################################
# ORCHESTRATOR.md's first prohibitions are the review gate itself. A worker that
# merely promises not to relabel its own issue is one prompt away from doing it,
# so the claim checked here is stronger: there is NO code path that can.

grep -Eq '"(PATCH|PUT|DELETE)"' "$WORKER" \
  && bad "worker.py issues a PATCH/PUT/DELETE - it can modify existing objects" \
  || ok "worker.py never issues PATCH/PUT/DELETE (it can only GET and POST comments/pulls)"

grep -q '/labels' "$WORKER" \
  && bad "worker.py references the labels endpoint" \
  || ok "worker.py has no labels endpoint at all - it cannot relabel an issue"

grep -q 'status:todo' "$WORKER" \
  && bad "worker.py mentions status:todo - approval is a human act" \
  || ok "worker.py never so much as names status:todo"

grep -Eq '/(merge|merges)"' "$WORKER" \
  && bad "worker.py references a merge endpoint" \
  || ok "worker.py has no merge call - humans merge"

grep -Eq -- '--force|--force-with-lease|push .*-f\b' "$WORKER" \
  && bad "worker.py can force-push" \
  || ok "worker.py never force-pushes (no --force anywhere)"

grep -q 'shell=True' "$WORKER" \
  && bad "worker.py runs a shell - a malformed ticket becomes chained execution" \
  || ok "worker.py never uses shell=True (the acceptance command is ONE command)"

grep -Eq 'x-access-token:|:\$\{?GITHUB_TOKEN|token@github' "$WORKER" \
  && bad "worker.py puts the token in a URL - it would land in .git/config and every error" \
  || ok "worker.py never embeds the token in a git URL (GIT_ASKPASS reads it from the env)"

# The exit codes are the dispatcher's only way to tell the outcomes apart.
CODES="$(python3 "$WORKER" --exit-codes 2>/dev/null)"
NCODES=$(printf '%s\n' "$CODES" | grep -c .)
NUNIQ=$(printf '%s\n' "$CODES" | cut -f1 | sort -u | grep -c .)
if [ "$NCODES" -ge 8 ] && [ "$NCODES" -eq "$NUNIQ" ]; then
  ok "$NCODES documented outcomes, each with its own exit code"
else
  bad "exit codes are not distinct: $NCODES documented, $NUNIQ unique"
fi
for want in pr-opened needs-file model-unusable ticket-malformed acceptance-failed scope-violation; do
  printf '%s\n' "$CODES" | grep -q "	$want	" \
    || bad "no distinct exit code for the '$want' outcome"
done
printf '%s\n' "$CODES" | grep -q "	needs-file	" \
  && ok "'needs a file' has an exit code of its own, distinct from a plain failure"

################################################################################
echo
echo "CONTRACT AGREEMENT  (ORCHESTRATOR.md is the source of truth)"
################################################################################
# Same class of bug the contract file's own preamble warns about: if the planner
# writes `Blocked-by` and the worker looks for `Blocks`, every ticket looks
# malformed. So the contract itself is parsed and compared.

python3 - "$CONTRACT" "$WORKER" > "$WORK/contract.tsv" <<'PY'
import importlib.util
import re
import sys

contract, worker_path = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("worker", worker_path)
w = importlib.util.module_from_spec(spec)
spec.loader.exec_module(w)
text = open(contract, encoding="utf-8").read()


def emit(cond, msg):
    print(("PASS" if cond else "FAIL") + "\t" + msg)


block = re.search(r"## Ticket format.*?```(.*?)```", text, re.S)
sections = re.findall(r"^## (.+)$", block.group(1), re.M) if block else []
expected = w.REQUIRED_SECTIONS + w.OPTIONAL_SECTIONS
emit(sections == expected,
     f"the worker's section names are the contract's: {sections} vs {expected}")

emit("- **Files touched** is a list of paths" in text and bool(w.check_files(["ok.py"]) is None),
     "the contract's Files touched list is what the worker parses")

# The worker must be at least as strict as the planner about the acceptance line.
emit(w.check_acceptance("pytest -q tests/test_x.py") is None
     and w.check_acceptance("a && b") is not None
     and w.check_acceptance("all tests should pass") is not None,
     "one runnable command accepted; a chain and a sentence refused")

emit(w.check_files(["README.md"]) is not None and w.check_files(["docs/readme.md"]) is not None,
     "a ticket declaring a README is refused (contract: never modify the target README)")

emit(w.check_files(["/etc/hosts"]) is not None and w.check_files(["../x.py"]) is not None
     and w.check_files([]) is not None,
     "absolute paths, escapes and an empty file list are all refused")

emit(w.branch_name({"number": 42, "title": "Add CSV export"}) == "issue-42-add-csv-export",
     "branch name is issue-<number>-<short-slug>, as the contract states")

# The dependency policy: the contract names one README section, the worker reads
# one README section, and if those two strings differ the worker sanctions
# nothing and every manifest ticket is refused. Same failure class as
# Blocked-by/Blocks, with a quieter symptom.
emit(f"## {w.SEC_CONSTRAINTS}" in text,
     f"the contract names the section the worker parses: '## {w.SEC_CONSTRAINTS}'")

# Stronger than a string compare: the contract's own worked example is fed to
# the worker's parser, so a documented format the code cannot read is a failure.
example = re.search(r"```markdown\n(## " + re.escape(w.SEC_CONSTRAINTS) + r".*?)```",
                    text, re.S)
parsed = w.sanctioned_packages(example.group(1)) if example else None
emit(parsed == {"fastapi", "uvicorn", "pydantic", "pytest", "httpx"},
     f"the contract's example constraints section parses to its own list: {parsed}")

# Absent section and empty section both sanction nothing; only the first is a
# defect. `None` vs `set()` is the distinction the warning is built on.
emit(w.sanctioned_packages("# p\n\nprose naming pytest and fastapi in passing") is None,
     "a README with no constraints section sanctions nothing, whatever its prose says")
emit(w.sanctioned_packages(f"# p\n\n## {w.SEC_CONSTRAINTS}\n\nStandard library only.\n")
     == set(),
     "an empty constraints section is a deliberate 'nothing', distinct from an absent one")

# Permission is exact. The old check was `name.lower() in readme.lower()`, which
# is not an allowlist: it sanctioned any package whose name fell inside a word.
allow = f"# p\n\nThis API handles requests and re-exports things.\n\n## {w.SEC_CONSTRAINTS}\n\n- fastapi\n"
emit(w.dependency_error("requirements.txt", None, "fastapi\n", allow) is None
     and w.dependency_error("requirements.txt", None, "api\n", allow) is not None
     and w.dependency_error("requirements.txt", None, "requests\n", allow) is not None
     and w.dependency_error("requirements.txt", None, "re\n", allow) is not None,
     "the sanctioned name passes; three packages that are only substrings of prose do not")

# A whole dependency set can live on ONE line, and that is the line a model
# writing a fresh pyproject.toml produces. A per-line scan sees only the key.
# `dependencies = ["requests"]` walked through the check until TECH-101.
one = f"# p\n\n## {w.SEC_CONSTRAINTS}\n\n- fastapi\n- pytest\n"
emit(w.dependency_error("pyproject.toml", None, 'dependencies = ["requests"]\n', one) is not None
     and w.dependency_error("pyproject.toml", None, '"devDependencies": {"lodash": "^4"}\n', one) is not None
     and w.dependency_error("pyproject.toml", None, 'dependencies = ["fastapi>=0.1", "pytest"]\n', one) is None,
     "a dependency list written on one line is read, in TOML and in JSON")

# ...and the metadata beside it is not mistaken for packages, or every manifest
# is refused and the check is useless in the other direction.
emit(w.dependency_error("pyproject.toml", None,
                        'name = "trip-planner"\nauthors = [{name = "A Person"}]\n'
                        'classifiers = ["Programming Language :: Python"]\n'
                        'description = "Plan a short trip."\n', one) is None,
     "project metadata -- name, authors, classifiers, description -- is not a package list")

# One package, however it is spelled. PEP 503 folding on both sides, or a model
# writes ruamel_yaml where the README says ruamel.yaml and walks through.
fold = f"# p\n\n## {w.SEC_CONSTRAINTS}\n\n- ruamel.yaml\n"
emit(w.dependency_error("requirements.txt", None, "ruamel_yaml==0.18\n", fold) is None
     and w.dependency_error("requirements.txt", None, "ruamel.yaml.clib\n", fold) is not None,
     "name folding makes ruamel_yaml the sanctioned package, and ruamel.yaml.clib another")

# Installing the project's manifest BUILDS it, and setuptools builds in tree. A
# real run passed acceptance and the full suite and was then refused at the scope
# gate for seven files it could not have declared. Exempt those; do not exempt a
# `build/` directory that might hold source.
for art in ("ai_trip_planner.egg-info/PKG-INFO", "build/lib/app/main.py",
            "build/bdist.linux-aarch64/x", ".eggs/pkg"):
    emit(bool(w.ARTIFACT_RE.search(art)), f"build by-product is exempt from the scope gate: {art}")
for src in ("build/main.py", "build/settings.py", "app/main.py"):
    emit(not w.ARTIFACT_RE.search(src), f"a plausible source path is NOT exempt: {src}")

# The worker prompt must carry the list, not a pointer to it. A model that has to
# find the section 6000 characters away is a model that guesses.
prompt = w.file_prompt({"context_bytes": 4000},
                       {"files": ["requirements.txt"], "goal": "g", "details": "d",
                        "acceptance": "pytest -q", "number": 1, "title": "t"},
                       "requirements.txt", allow, {})
emit("fastapi" in prompt[1]["content"].split("RULES", 1)[1],
     "the model is told which packages are sanctioned, in the rules, by name")

# Round-trip: the planner's renderer -> the worker's parser. Two independent
# implementations of one format; if they disagree, nothing works end to end.
rendered = "\n".join([
    "## Goal", "A helper.", "",
    "## Files touched", "- src/x.py", "- tests/test_x.py", "",
    "## Details", "Write it.", "",
    "## Acceptance criteria", "pytest -q tests/test_x.py", "",
    "## Blocked-by", "#12",
])
t, err = w.parse_ticket({"number": 1, "title": "A helper", "body": rendered})
emit(err is None and t["files"] == ["src/x.py", "tests/test_x.py"]
     and t["acceptance"] == "pytest -q tests/test_x.py" and t["blocked_by"] == [12],
     f"a ticket in the contract's exact format parses ({err})")
PY
while IFS=$'\t' read -r verdict msg; do
  [ "$verdict" = PASS ] && ok "$msg" || bad "$msg"
done < "$WORK/contract.tsv"

################################################################################
echo
echo "CONFIGURATION: fail loudly and early, before anything is attempted"
################################################################################

cfg_run() { # NAME  env-assignments...
  local name=$1; shift
  ( env "$@" python3 "$WORKER" ) > "$WORK/cfg-$name.out" 2> "$WORK/cfg-$name.err"
  echo $? > "$WORK/cfg-$name.rc"
}
cfg_rc() { cat "$WORK/cfg-$1.rc"; }

cfg_run notoken GITHUB_TOKEN= TARGET_REPO="$REPO" P4_ISSUE=31
[ "$(cfg_rc notoken)" = 2 ] && grep -qi "GITHUB_TOKEN" "$WORK/cfg-notoken.err" \
  && ok "no token: exit 2 and the message names GITHUB_TOKEN" \
  || bad "no token: exit $(cfg_rc notoken), message: $(head -1 "$WORK/cfg-notoken.err")"

cfg_run norepo GITHUB_TOKEN="$GITHUB_TOKEN" TARGET_REPO= P4_ISSUE=31
[ "$(cfg_rc norepo)" = 2 ] && grep -qi "TARGET_REPO" "$WORK/cfg-norepo.err" \
  && ok "no repo: exit 2 and the message names TARGET_REPO" \
  || bad "no repo: exit $(cfg_rc norepo)"

cfg_run noissue GITHUB_TOKEN="$GITHUB_TOKEN" TARGET_REPO="$REPO" P4_ISSUE=
[ "$(cfg_rc noissue)" = 2 ] && grep -qi "P4_ISSUE" "$WORK/cfg-noissue.err" \
  && ok "no issue number: exit 2 and the message names P4_ISSUE" \
  || bad "no issue number: exit $(cfg_rc noissue)"

cfg_run badrepo GITHUB_TOKEN="$GITHUB_TOKEN" TARGET_REPO="not-a-slug" P4_ISSUE=31
[ "$(cfg_rc badrepo)" = 2 ] \
  && ok "a repo that is not owner/name is refused rather than guessed at" \
  || bad "a malformed TARGET_REPO was accepted (exit $(cfg_rc badrepo))"

cfg_run empty_endpoint GITHUB_TOKEN="$GITHUB_TOKEN" TARGET_REPO="$REPO" P4_ISSUE=31 \
        P5_MODEL_URL=" " P5_MODEL=x
[ "$(cfg_rc empty_endpoint)" = 2 ] \
  && ok "an empty model endpoint is a configuration error, not a mystery timeout" \
  || bad "an empty model endpoint was accepted (exit $(cfg_rc empty_endpoint))"

################################################################################
echo
echo "MOCK MODEL + LOCAL ORIGIN  (no live model, no GitHub, no credentials)"
################################################################################

cat > "$WORK/mock-model.py" <<'PY'
#!/usr/bin/env python3
"""A canned OpenAI-compatible chat endpoint for the worker.

Which reply is served is decided by reading the prompt the worker sent, the same
way a human would: every file prompt carries one 'TARGET FILE: <path>' line, so
the key is the path being asked about. '<path>#<n>' answers the n-th call for
that path within one run - rejection feedback and acceptance retries both count
- and '*' is the fallback.

A string value is served as the assistant's raw content; an object value is
served as its JSON encoding. Every request is logged per run, including whether
the prompt carried a rejection or an acceptance failure, which is how the
harness proves the retry actually fed the failure back.
"""
import json
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPLIES, STATE = sys.argv[1], sys.argv[2]
BIND = sys.argv[3] if len(sys.argv) > 3 else "127.0.0.1"
DOC = json.load(open(REPLIES, encoding="utf-8"))["scenarios"]
SERVED = {}

TARGET_RE = re.compile(r"^TARGET FILE: (.+)$", re.M)


def state(name, default=""):
    try:
        with open(os.path.join(STATE, name), encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return default


def log(name, rec):
    with open(os.path.join(STATE, name), "a", encoding="utf-8") as fh:
        fh.write(json.dumps(rec, sort_keys=True) + "\n")


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        if self.path != "/v1/chat/completions":
            self.send_error(404, "only /v1/chat/completions is mocked")
            return
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        prompt = "\n".join(m.get("content") or "" for m in body["messages"])
        scen, run = state("scenario"), state("run", "run")
        m = TARGET_RE.search(prompt)
        key = m.group(1).strip() if m else "unknown"
        n = SERVED.get((run, scen, key), 0) + 1
        SERVED[(run, scen, key)] = n
        table = DOC.get(scen)
        if table is None:
            self.send_error(500, f"unknown scenario {scen!r}")
            return
        value = table.get(f"{key}#{n}", table.get(key, table.get("*")))
        log(f"requests.{run}.jsonl", {
            "scenario": scen, "key": key, "attempt": n, "served": value is not None,
            "rejected_feedback": "REJECTED:" in prompt,
            "acceptance_failure": "THE ACCEPTANCE COMMAND FAILED" in prompt,
            "turns": sum(1 for x in body["messages"] if x["role"] == "assistant"),
        })
        if value is None:
            self.send_error(500, f"scenario {scen!r} has no reply for {key!r}")
            return
        if value == "__http500__":
            self.send_error(500, "the mock endpoint is deliberately down")
            return
        content = value if isinstance(value, str) else json.dumps(value)
        payload = json.dumps({
            "id": "mock", "object": "chat.completion", "model": body.get("model"),
            "choices": [{"index": 0, "finish_reason": "stop",
                         "message": {"role": "assistant", "content": content}}],
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


srv = ThreadingHTTPServer((BIND, 0), H)
with open(os.path.join(STATE, "port"), "w", encoding="utf-8") as fh:
    fh.write(str(srv.server_address[1]))
srv.serve_forever()
PY

printf 'good\n' > "$MOCK_STATE/scenario"
printf 'boot\n' > "$MOCK_STATE/run"
python3 "$WORK/mock-model.py" "$REPLIES" "$MOCK_STATE" "$MOCK_BIND" &
MOCK_PID=$!
for _ in $(seq 1 50); do [ -s "$MOCK_STATE/port" ] && break; sleep 0.1; done
MOCK_PORT="$(cat "$MOCK_STATE/port" 2>/dev/null || true)"
if [ -n "$MOCK_PORT" ] && kill -0 "$MOCK_PID" 2>/dev/null; then
  ok "mock model endpoint listening on loopback (no live model, no GPU)"
else
  bad "the mock model endpoint did not start - every suite below is meaningless"
  printf '\nRESULT: %d passed, %d failed\n\n' "$pass" "$fail"; exit 1
fi
MOCK_URL="http://127.0.0.1:$MOCK_PORT/v1/chat/completions"

# --- a fresh origin per run: the worker PUSHES, so no two runs may share one ---
mk_origin() { # tag -> path of a bare repo seeded from p5-fixtures/repo
  # One assignment per line on purpose: in a single `local a=$1 b=$a` bash
  # declares both names before evaluating either value, so $a would be unset.
  local tag=$1
  local seed="$WORK/$tag.seed"
  local bare="$WORK/$tag.git"
  rm -rf "$seed" "$bare"
  mkdir -p "$seed"
  cp -R "$FIX/repo/." "$seed/"
  ( cd "$seed" && git init -q -b main . \
      && git add -A \
      && git -c user.name=fixture -c user.email=fixture@example.invalid \
             commit -q -m "the fixture target project" ) >/dev/null 2>&1
  git clone -q --bare "$seed" "$bare" >/dev/null 2>&1
  printf '%s' "$bare"
}
[ -d "$(mk_origin control)" ] && ok "local git origin built from the committed fixture project" \
  || bad "could not build the fixture origin - the run suites cannot work"

run_worker() { # tag scenario issue [extra worker args...]
  local tag=$1 scen=$2 issue=$3; shift 3
  printf '%s\n' "$scen" > "$MOCK_STATE/scenario"
  printf '%s\n' "$tag"  > "$MOCK_STATE/run"
  local origin; origin="$(mk_origin "$tag")"
  # PREBRANCH lets a suite hand the worker an origin that already carries its
  # branch - the situation in which a lesser worker would force-push.
  if [ -n "${PREBRANCH:-}" ]; then
    git --git-dir="$origin" branch "$PREBRANCH" main >/dev/null 2>&1
  fi
  mkdir -p "$WORK/$tag.ws"
  cp "$ISSUES" "$WORK/$tag.issues.json"
  echo "$issue" > "$WORK/$tag.issue"
  env P5_MODEL_URL="$MOCK_URL" P5_MODEL="mock-model" P5_MODEL_TIMEOUT=30 \
      P5_TEST_COMMAND="python3 -m pytest -q" P5_HEARTBEAT_SECONDS=0 \
      python3 "$WORKER" --issue "$issue" --repo "$REPO" \
        --github "fixture:$WORK/$tag.issues.json" \
        --origin "file://$origin" --workspace "$WORK/$tag.ws" "$@" \
        > "$WORK/$tag.out" 2> "$WORK/$tag.err"
  echo $? > "$WORK/$tag.rc"
}
rc_of()        { cat "$WORK/$1.rc" 2>/dev/null || echo "NO-RUN"; }
branches_of()  { git --git-dir="$WORK/$1.git" for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null; }
changed_in()   { git --git-dir="$WORK/$1.git" diff --name-only "main..$2" 2>/dev/null; }
commits_in()   { git --git-dir="$WORK/$1.git" rev-list --count "main..$2" 2>/dev/null || echo 0; }
blob_in()      { git --git-dir="$WORK/$1.git" show "$2:$3" 2>/dev/null; }
tree_dirty()   { git -C "$WORK/$1.ws/repo" status --porcelain 2>/dev/null; }
calls_in()     { grep -c . "$MOCK_STATE/requests.$1.jsonl" 2>/dev/null || echo 0; }

# Fixture-GitHub queries. One helper, so a typo cannot silently return nothing.
cat > "$WORK/q.py" <<'PY'
import json
import sys

state, issue, what = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(state, encoding="utf-8"))
if what == "comments":
    print("\n---\n".join(c["body"] for c in d.get("comments", {}).get(issue, [])))
elif what == "ncomments":
    print(len(d.get("comments", {}).get(issue, [])))
elif what == "npulls":
    print(len(d.get("pulls", [])))
elif what == "pullbody":
    print("\n---\n".join(p["body"] for p in d.get("pulls", [])))
elif what == "pullhead":
    print(" ".join(p["head"]["ref"] for p in d.get("pulls", [])))
elif what == "labels":
    print(" ".join(sorted(
        "%s=%s" % (i["number"], ",".join(sorted(i.get("labels", []))))
        for i in d["issues"])))
else:
    raise SystemExit("unknown query " + what)
PY
# gh_q <run-tag> <query>  - the issue number is the one that run was handed.
gh_q() {
  local tag=$1
  local what=$2
  local issue
  issue="$(cat "$WORK/$tag.issue" 2>/dev/null || echo 0)"
  python3 "$WORK/q.py" "$WORK/$tag.issues.json" "$issue" "$what"
}

################################################################################
echo
echo "TICKET CONFORMANCE: refused BEFORE any clone and BEFORE any model call"
################################################################################
# Each fixture issue is malformed in exactly one way, so each check fires on its
# own defect rather than on a pile of them.

refusal() { # tag issue "what is wrong"
  local tag=$1 issue=$2 what=$3
  run_worker "$tag" good "$issue"
  local rc; rc="$(rc_of "$tag")"
  local calls; calls="$(calls_in "$tag")"
  local cloned="no"; [ -e "$WORK/$tag.ws/repo" ] && cloned="yes"
  if [ "$rc" = 4 ] && [ "$calls" -eq 0 ] && [ "$cloned" = no ]; then
    ok "#$issue ($what): exit 4, no clone, no model call"
  else
    bad "#$issue ($what): exit $rc, $calls model call(s), cloned=$cloned"
    note "$(head -3 "$WORK/$tag.err")"
  fi
}
refusal m-nofiles 32 "no Files touched"
refusal m-prose   33 "prose acceptance criterion"
refusal m-chain   34 "acceptance chains two commands"
refusal m-readme  35 "declares the target README"
refusal m-nogoal  36 "no Goal section"
refusal m-abs     37 "absolute path in the file list"
refusal m-nodet   38 "empty Details section"
refusal m-spec    42 "a spec issue, not an implementation ticket"
refusal m-closed  43 "already closed"

grep -q "p4-defect" <(gh_q m-nofiles comments) \
  && ok "the refusal is reported on the issue as a defect marker the dispatcher can find" \
  || bad "a malformed ticket was refused silently - indistinguishable from a blocked one"
gh_q m-readme comments | grep -qi "README" \
  && ok "the README refusal says so on the issue, in words a human can act on" \
  || bad "the README refusal does not explain itself"
[ "$(gh_q m-nofiles npulls)" = 0 ] \
  && ok "no pull request is opened for a ticket that was never worked" \
  || bad "a pull request appeared for a refused ticket"

################################################################################
echo
echo "POSITIVE CONTROL: a good ticket and good replies produce a real commit"
################################################################################
# Everything above is "must not happen"; a worker that does nothing satisfies all
# of it. This suite fails if work does not genuinely flow.

run_worker good good 31
GOOD_BRANCH="issue-31-add-a-slugify-helper"
if [ "$(rc_of good)" = 0 ]; then
  ok "the happy path exits 0"
else
  bad "the happy path exited $(rc_of good)"
  note "$(tail -5 "$WORK/good.err")"
  note "$(tail -5 "$WORK/good.out")"
fi
[ "$(calls_in good)" -ge 2 ] \
  && ok "the mock was exercised: $(calls_in good) model call(s), one per declared file" \
  || bad "the mock served $(calls_in good) calls - the suite would pass vacuously"
branches_of good | grep -qx "$GOOD_BRANCH" \
  && ok "the branch $GOOD_BRANCH exists on the origin (pushed for real)" \
  || bad "no branch $GOOD_BRANCH on the origin; got: $(branches_of good | tr '\n' ' ')"
[ "$(commits_in good "$GOOD_BRANCH")" = 1 ] \
  && ok "exactly one commit on top of main" \
  || bad "$(commits_in good "$GOOD_BRANCH") commit(s) on top of main, expected 1"
CH="$(changed_in good "$GOOD_BRANCH" | sort | tr '\n' ' ')"
[ "$CH" = "src/slug.py tests/test_slug.py " ] \
  && ok "the commit touches ONLY the two declared files" \
  || bad "the commit touches: $CH"
printf '%s' "$CH" | grep -q "README" \
  && bad "the commit touches the README" \
  || ok "the commit does not touch the README"
diff -q <(blob_in good "$GOOD_BRANCH" README.md) "$FIX/repo/README.md" >/dev/null 2>&1 \
  && ok "the README on the branch is byte-identical to the one on main" \
  || bad "the README changed on the branch"
diff -q <(blob_in good "$GOOD_BRANCH" tests/test_util.py) "$FIX/repo/tests/test_util.py" >/dev/null 2>&1 \
  && ok "the pre-existing test file is byte-identical on the branch" \
  || bad "a test file the ticket did not declare changed"
blob_in good "$GOOD_BRANCH" src/slug.py | grep -q "def slugify" \
  && ok "the committed file is the contents the model returned, written verbatim" \
  || bad "the committed file is not what the mock served"
[ "$(gh_q good npulls)" = 1 ] \
  && ok "exactly one pull request was opened" \
  || bad "$(gh_q good npulls) pull request(s) opened"
gh_q good pullbody | grep -q "Closes #31" \
  && ok "the pull request body references the issue as 'Closes #31'" \
  || bad "the pull request body does not reference the issue"
[ "$(gh_q good pullhead)" = "$GOOD_BRANCH" ] \
  && ok "the pull request head is the worker's own branch" \
  || bad "the pull request head is $(gh_q good pullhead)"
gh_q good comments | grep -q "p4-heartbeat" \
  && ok "the worker heartbeats on the issue, so the reaper can tell it is alive" \
  || bad "no heartbeat comment - a live worker would be reaped as dead"
gh_q good comments | grep -q "a1b2c3d4e5f60718" \
  && ok "the heartbeat carries the dispatcher's claim nonce, copied verbatim" \
  || bad "the heartbeat does not carry the claim nonce"
[ -z "$(tree_dirty good)" ] \
  && ok "the workspace is clean after the commit: nothing was left unstaged" \
  || bad "the workspace still has changes: $(tree_dirty good | tr '\n' ' ')"

# The list-of-lines reply shape (tests/test_slug.py in the fixture) must have
# produced a real file, or that tolerance is untested.
blob_in good "$GOOD_BRANCH" tests/test_slug.py | grep -q "def test_slugify_spaces" \
  && ok "a reply whose contents came as a list of lines was written as a real file" \
  || bad "the list-of-lines reply shape did not produce the file"

################################################################################
echo
echo "OUT OF SCOPE: a reply that proposes another file does not write it"
################################################################################

run_worker wrongpath wrong-path 31 --retries 1
[ "$(rc_of wrongpath)" = 3 ] \
  && ok "a reply about an undeclared path is refused every time: exit 3 (model unusable)" \
  || bad "a reply about an undeclared path gave exit $(rc_of wrongpath)"
[ -e "$WORK/wrongpath.ws/repo/src/other.py" ] \
  && bad "src/other.py was written - the worker wrote a path it was not asked about" \
  || ok "src/other.py does not exist anywhere in the workspace"
[ -z "$(tree_dirty wrongpath)" ] \
  && ok "the checkout is untouched: not one byte was written" \
  || bad "the checkout was modified: $(tree_dirty wrongpath | tr '\n' ' ')"
[ -z "$(branches_of wrongpath | grep -x issue-31-add-a-slugify-helper)" ] \
  && ok "nothing was pushed" \
  || bad "a branch was pushed despite no usable reply"
grep -qi "one file per reply\|this call is about" "$WORK/wrongpath.err" \
  && ok "the rejection tells the model which file the call was about" \
  || bad "the rejection message does not name the requested file"

run_worker extrafiles extra-files-key 31
[ "$(rc_of extrafiles)" = 0 ] \
  && ok "a smuggled second file is rejected, and the clean retry still finishes (exit 0)" \
  || bad "the extra-files scenario exited $(rc_of extrafiles)"
[ -e "$WORK/extrafiles.ws/repo/src/sneaky.py" ] \
  && bad "src/sneaky.py was written from the reply's extra_files key" \
  || ok "src/sneaky.py was never written, in the workspace or anywhere else"
changed_in extrafiles "$GOOD_BRANCH" | grep -q "sneaky" \
  && bad "src/sneaky.py reached the commit" \
  || ok "the commit contains only the declared files"
grep -q "extra files" "$WORK/extrafiles.err" \
  && ok "the reply carrying extra files was refused with a reason" \
  || bad "the extra-files reply was not refused explicitly"

run_worker readmetarget readme-target 31 --retries 1
[ "$(rc_of readmetarget)" = 3 ] \
  && ok "a reply that answers about README.md is refused (exit 3), not applied" \
  || bad "the README-target scenario exited $(rc_of readmetarget)"
diff -q "$WORK/readmetarget.ws/repo/README.md" "$FIX/repo/README.md" >/dev/null 2>&1 \
  && ok "the README in the checkout is byte-identical after the attempt" \
  || bad "the README was modified"

# A file the RUNTIME creates is as much a scope violation as one the model
# names, and only a git-level check can see it.
run_worker leaky runtime-scope 41
[ "$(rc_of leaky)" = 9 ] \
  && ok "a file created by the code under test is caught: exit 9 (scope violation)" \
  || bad "the runtime scope violation gave exit $(rc_of leaky)"
gh_q leaky comments | grep -q "cache.db" \
  && ok "the issue comment names the undeclared file" \
  || bad "the scope violation was not reported on the issue"
[ "$(commits_in leaky issue-41-add-a-cache-module)" = 0 ] \
  && ok "nothing was committed despite the acceptance command passing" \
  || bad "it committed anyway"
[ "$(gh_q leaky npulls)" = 0 ] \
  && ok "no pull request was opened" \
  || bad "a pull request was opened from an out-of-scope tree"

################################################################################
echo
echo "ACCEPTANCE COMMAND: retry with the failure fed back, then fail loudly"
################################################################################

run_worker retry retry-then-pass 31
[ "$(rc_of retry)" = 0 ] \
  && ok "a first implementation that fails the acceptance command is retried to success" \
  || bad "the retry scenario exited $(rc_of retry)"
python3 - "$MOCK_STATE/requests.retry.jsonl" <<'PY' && ok "the retry prompt carried the acceptance command's own failure output" || bad "the retry did not feed the failure back"
import json
import sys
recs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
sys.exit(0 if any(r["acceptance_failure"] for r in recs) else 1)
PY
[ "$(commits_in retry "$GOOD_BRANCH")" = 1 ] \
  && ok "the successful retry produced exactly one commit" \
  || bad "$(commits_in retry "$GOOD_BRANCH") commit(s) after the retry"
grep -q "retrying src/slug.py" "$WORK/retry.out" \
  && ok "the SCRIPT chose which file to re-ask, and said which and why" \
  || bad "no record of the script choosing a retry target"

run_worker exhausted retry-exhausted 31 --attempts 2
[ "$(rc_of exhausted)" = 6 ] \
  && ok "exhausting the retries exits 6 (acceptance failed), loudly" \
  || bad "exhausted retries gave exit $(rc_of exhausted)"
[ "$(commits_in exhausted "$GOOD_BRANCH")" = 0 ] \
  && ok "NOTHING was committed when the acceptance command never passed" \
  || bad "it committed after the acceptance command failed - the worst outcome here"
[ -z "$(branches_of exhausted | grep -x "$GOOD_BRANCH")" ] \
  && ok "the branch was never pushed" \
  || bad "the branch was pushed despite a failing acceptance command"
[ "$(gh_q exhausted npulls)" = 0 ] \
  && ok "no pull request was opened" \
  || bad "a pull request was opened for work that does not pass"
gh_q exhausted comments | grep -q "did not pass" \
  && ok "the failure is reported on the issue with the command's output" \
  || bad "the acceptance failure was not reported on the issue"
[ "$(calls_in exhausted)" -ge 3 ] \
  && ok "the model was re-asked ($(calls_in exhausted) calls), so the retry really ran" \
  || bad "only $(calls_in exhausted) model call(s): no retry happened"

################################################################################
echo
echo "TESTS ARE NEVER WEAKENED, AND A FAILING SUITE IS A FINDING"
################################################################################

run_worker suite suite-breaks 39
[ "$(rc_of suite)" = 7 ] \
  && ok "acceptance passes but the full suite fails: exit 7, its own outcome" \
  || bad "the broken-suite scenario exited $(rc_of suite)"
[ "$(commits_in suite issue-39-add-a-tripling-helper-to-uti)" = 0 ] \
  && ok "nothing was committed when a test the worker did not write started failing" \
  || bad "it committed with the suite red"
gh_q suite comments | grep -q "full test suite" \
  && ok "the failing suite is reported on the issue rather than repaired" \
  || bad "the suite failure was not reported"
gh_q suite comments | grep -qi "deleted, skipped or loosened" \
  && ok "the report says explicitly that no test was loosened to get a green run" \
  || bad "the report does not address test weakening"

run_worker weaken weakens-test 40 --retries 1
[ "$(rc_of weaken)" = 11 ] \
  && ok "a reply that deletes an existing test is refused: exit 11, its own code" \
  || bad "the weakening scenario exited $(rc_of weaken)"
diff -q "$WORK/weaken.ws/repo/tests/test_util.py" "$FIX/repo/tests/test_util.py" >/dev/null 2>&1 \
  && ok "the existing test file is byte-identical: nothing was deleted or skipped" \
  || bad "the existing test file was modified"
grep -qi "removes existing test" "$WORK/weaken.err" \
  && ok "the first rejection names the test that would have disappeared" \
  || bad "the rejection does not name the deleted test"
grep -qi "skip/xfail" "$WORK/weaken.err" \
  && ok "the second rejection catches the skip marker route to the same outcome" \
  || bad "an added skip marker was not caught"
[ "$(commits_in weaken issue-40-extend-the-util-tests)" = 0 ] \
  && ok "nothing was committed" \
  || bad "it committed a weakened test file"

# Positive control for that check: a rejection the model can recover from must
# not be a dead end, or the check would simply block legitimate work.
run_worker weakenfix weakens-then-fixes 40 --retries 1
[ "$(rc_of weakenfix)" = 0 ] \
  && ok "the same rejection, then a reply that keeps every test: the run finishes" \
  || bad "a recoverable weakening rejection became a dead end (exit $(rc_of weakenfix))"
blob_in weakenfix issue-40-extend-the-util-tests tests/test_util.py \
  | grep -q "def test_double_zero" \
  && ok "the committed test file still contains the test the first reply deleted" \
  || bad "the committed test file lost a test"

################################################################################
echo
echo "DEPENDENCIES: only what the README's Implementation constraints sanction"
################################################################################
# The worker's container CAN reach PyPI, so this check is the control between a
# model and arbitrary third-party code running with a credential in its
# environment. #44 declares a manifest, which is the one file where a new
# dependency can arrive legitimately.

run_worker depbad dependency-bad 44
[ "$(rc_of depbad)" = 10 ] \
  && ok "a package outside the sanctioned list is refused: exit 10, its own code" \
  || bad "the unsanctioned-dependency scenario exited $(rc_of depbad)"
gh_q depbad comments | grep -q "requests" \
  && ok "the issue comment names the package that was refused" \
  || bad "the refused dependency is not named on the issue"
gh_q depbad comments | grep -q "Implementation constraints" \
  && ok "and names the section a human would have to edit to permit it" \
  || bad "the refusal does not say where the permission would come from"
[ "$(commits_in depbad issue-44-pin-the-test-dependency)" = 0 ] \
  && ok "nothing was committed" \
  || bad "it committed a manifest with an unsanctioned dependency"

run_worker depok dependency-ok 44
[ "$(rc_of depok)" = 0 ] \
  && ok "a manifest holding only what the README sanctions is accepted (exit 0)" \
  || bad "the sanctioned-dependency scenario exited $(rc_of depok)"
[ "$(changed_in depok issue-44-pin-the-test-dependency | tr -d '\n')" = "requirements.txt" ] \
  && ok "the commit contains the manifest and nothing else" \
  || bad "the commit touches $(changed_in depok issue-44-pin-the-test-dependency | tr '\n' ' ')"

# The regression that made an allowlist out of what was a substring search.
# `api`, `requests` and `re` are all real distributions on PyPI and all three
# appear inside words in the fixture README's prose. Under the old check every
# one of them was sanctioned by a sentence nobody wrote as a permission.
run_worker depsub dependency-substring 44
[ "$(rc_of depsub)" = 10 ] \
  && ok "packages that merely appear as substrings of README prose are refused" \
  || bad "the substring scenario exited $(rc_of depsub); prose is granting permission"
for pkg in api requests re; do
  gh_q depsub comments | grep -qw "$pkg" \
    && ok "the refusal names '$pkg', which the old substring check would have allowed" \
    || bad "'$pkg' was not among the refused packages"
done
[ "$(commits_in depsub issue-44-pin-the-test-dependency)" = 0 ] \
  && ok "nothing was committed" \
  || bad "it committed a manifest sanctioned only by a coincidence of spelling"

################################################################################
echo
echo "NOTHING TO DO, AND A BRANCH THAT ALREADY EXISTS"
################################################################################

run_worker nochange no-change 40
[ "$(rc_of nochange)" = 1 ] \
  && ok "a reply identical to what is already on main commits nothing (exit 1)" \
  || bad "the no-change scenario exited $(rc_of nochange)"
[ "$(gh_q nochange npulls)" = 0 ] \
  && ok "no empty pull request was opened" \
  || bad "an empty pull request was opened"
gh_q nochange comments | grep -qi "nothing to commit" \
  && ok "the issue says why there was nothing to do" \
  || bad "the empty outcome was not explained on the issue"

# A worker never force-pushes, so a branch that already exists is a human's
# problem and must be reported rather than overwritten.
PREBRANCH="$GOOD_BRANCH" run_worker taken good 31
[ "$(rc_of taken)" = 8 ] \
  && ok "an existing remote branch stops the run (exit 8) instead of being overwritten" \
  || bad "the pre-existing-branch scenario exited $(rc_of taken)"
[ "$(git --git-dir="$WORK/taken.git" rev-parse "$GOOD_BRANCH")" \
  = "$(git --git-dir="$WORK/taken.git" rev-parse main)" ] \
  && ok "the existing branch still points where it did: nothing was force-pushed" \
  || bad "the existing branch moved"

################################################################################
echo
echo "NEEDS ANOTHER FILE: comment, write nothing, exit with its own code"
################################################################################

run_worker needs needs-file 31
[ "$(rc_of needs)" = 5 ] \
  && ok "needing an undeclared file exits 5, distinct from every failure code" \
  || bad "the needs-file scenario exited $(rc_of needs)"
gh_q needs comments | grep -q "Blocked: this needs \`src/__init__.py\`" \
  && ok "the issue comment names the file, in the words p4-worker-instructions.md uses" \
  || bad "the needs-file comment does not match the documented wording"
gh_q needs comments | grep -qi "reason" \
  && ok "the comment carries the model's stated reason" \
  || bad "the comment gives no reason"
[ -z "$(tree_dirty needs)" ] \
  && ok "not one file was written - not even the declared ones" \
  || bad "files were written before stopping: $(tree_dirty needs | tr '\n' ' ')"
[ -e "$WORK/needs.ws/repo/src/__init__.py" ] \
  && bad "it created the file it said it needed" \
  || ok "the file it asked for was not created"
[ "$(gh_q needs npulls)" = 0 ] \
  && ok "no pull request" \
  || bad "a pull request was opened"

################################################################################
echo
echo "MODEL UNUSABLE: prose, and a dead endpoint"
################################################################################

run_worker prose prose 31 --retries 1
[ "$(rc_of prose)" = 3 ] \
  && ok "a reply that is prose rather than JSON exhausts the retries and stops: exit 3" \
  || bad "the prose scenario exited $(rc_of prose)"
grep -q "last raw reply" "$WORK/prose.err" \
  && ok "the raw reply is printed, so a human can see what the model actually said" \
  || bad "the raw reply was swallowed"
[ -z "$(tree_dirty prose)" ] && ok "nothing written" || bad "files were written"
gh_q prose comments | grep -qi "could not produce usable contents" \
  && ok "the model-capability finding is recorded on the issue" \
  || bad "nothing was reported on the issue"

run_worker down http-500 31 --retries 1
[ "$(rc_of down)" = 3 ] \
  && ok "a dead model endpoint is a model failure (exit 3), not a mystery" \
  || bad "the dead-endpoint scenario exited $(rc_of down)"
[ "$(commits_in down "$GOOD_BRANCH")" = 0 ] \
  && ok "nothing was committed" \
  || bad "it committed something"

################################################################################
echo
echo "LABELS, MERGES AND SECRETS: what must never happen in ANY of the runs above"
################################################################################

BASE_LABELS="$(python3 "$WORK/q.py" "$ISSUES" 0 labels)"
drift=0
runs=0
for tag in m-nofiles m-prose m-chain m-readme m-nogoal m-abs m-nodet m-spec m-closed \
           good wrongpath extrafiles readmetarget leaky retry exhausted suite \
           weaken weakenfix depbad depok nochange taken needs prose down; do
  [ -f "$WORK/$tag.issues.json" ] || continue
  runs=$((runs+1))
  if [ "$(gh_q "$tag" labels)" != "$BASE_LABELS" ]; then
    bad "run '$tag' changed an issue's labels"
    drift=$((drift+1))
  fi
done
[ "$drift" = 0 ] && [ "$runs" -ge 20 ] \
  && ok "not one of the $runs runs changed a single label on any issue" \
  || bad "label drift in $drift of $runs run(s)"

pulls=0
for tag in good extrafiles retry weakenfix depok; do
  pulls=$((pulls + $(gh_q "$tag" npulls)))
done
[ "$pulls" = 5 ] \
  && ok "the five runs that should open a pull request opened exactly one each" \
  || bad "expected 5 pull requests across the successful runs, got $pulls"

# Secret hygiene: the token is in the environment of every run above.
if grep -rl "$GITHUB_TOKEN" "$WORK"/*.out "$WORK"/*.err "$WORK"/*.issues.json \
      "$MOCK_STATE" 2>/dev/null | grep -q .; then
  bad "the token appears in captured output or in what was sent to the model"
  note "$(grep -rl "$GITHUB_TOKEN" "$WORK"/*.out "$WORK"/*.err "$MOCK_STATE" 2>/dev/null | head -3)"
else
  ok "the token appears in no stdout, no stderr, no issue comment and no model prompt"
fi
grep -rq "$GITHUB_TOKEN" "$WORK"/*.git 2>/dev/null \
  && bad "the token reached a git repository (a remote URL or a config)" \
  || ok "the token is in no git config and no remote URL"

TOTAL_CALLS=$(cat "$MOCK_STATE"/requests.*.jsonl 2>/dev/null | grep -c . || echo 0)
[ "$TOTAL_CALLS" -ge 20 ] \
  && ok "the mock endpoint served $TOTAL_CALLS calls across the suites (not vacuous)" \
  || bad "the mock served only $TOTAL_CALLS calls"

################################################################################
if [ "$MODE" = image ]; then
echo
echo "IN THE REAL IMAGE: hermes-worker:latest, read-only rootfs, uid 10001"
################################################################################
# Everything above runs on the host's python. This suite runs ONE ticket inside
# the image the spawn dispatcher actually creates workers from, started with the
# dispatcher's own default command template, so the things a host run cannot
# check are checked: python 3.12 rather than the host's, alpine rather than
# macOS, a read-only rootfs with a single writable /work tmpfs, and a non-root
# uid that has to be able to write into it.
#
# Still no live model and still no GitHub: the endpoint is the same mock (bound
# to every interface for this mode) and the origin is the same local bare repo,
# mounted in. The container is named p8-* and removed on exit.

if ! command -v docker >/dev/null; then
  bad "docker is not on PATH: the image suite cannot run (use the default mode)"
elif ! docker image inspect hermes-worker:latest >/dev/null 2>&1; then
  bad "hermes-worker:latest is not built. docker compose --profile images build worker-image"
else
  IMG="$WORK/img"
  mkdir -p "$IMG"
  cp -R "$(mk_origin container)" "$IMG/origin.git"
  cp "$ISSUES" "$IMG/issues.json"
  # The image runs as uid 10001; the mount has to be writable by it, since the
  # worker pushes into that bare repo.
  chmod -R 0777 "$IMG"
  printf 'good\n' > "$MOCK_STATE/scenario"
  printf 'container\n' > "$MOCK_STATE/run"
  : > "$MOCK_STATE/requests.container.jsonl"

  docker rm -f p8-worker-image >/dev/null 2>&1
  # The command is the dispatcher's default P4_WORKER_CMD, verbatim in shape:
  # `sh -c "P4_ISSUE=.. P4_REPO=.. exec /usr/local/bin/p4-worker.sh"`. If that
  # shim or its exec is wrong, the exit code below is the shell's, not the
  # worker's, and the outcome codes stop meaning anything.
  docker run --rm --name p8-worker-image \
    --read-only --tmpfs /work:size=64m,mode=1777,exec \
    --network bridge \
    -v "$HERE/worker.py":/usr/local/bin/worker.py:ro \
    -v "$HERE/p4-worker.sh":/usr/local/bin/p4-worker.sh:ro \
    -v "$IMG":/fixtures \
    -e GITHUB_TOKEN="$GITHUB_TOKEN" \
    -e P5_GITHUB="fixture:/fixtures/issues.json" \
    -e P5_ORIGIN="file:///fixtures/origin.git" \
    -e P5_MODEL_URL="http://host.docker.internal:$MOCK_PORT/v1/chat/completions" \
    -e P5_MODEL="mock-model" -e P5_MODEL_TIMEOUT=60 \
    -e P5_TEST_COMMAND="python3 -m pytest -q" -e P5_HEARTBEAT_SECONDS=0 \
    -e HTTPS_PROXY= -e https_proxy= -e HTTP_PROXY= -e http_proxy= \
    hermes-worker:latest \
    sh -c "P4_ISSUE=31 P4_REPO=$REPO exec /usr/local/bin/p4-worker.sh" \
    > "$WORK/container.out" 2> "$WORK/container.err"
  crc=$?

  [ "$crc" = 0 ] \
    && ok "one ticket, end to end, inside hermes-worker:latest (exit 0)" \
    || { bad "the in-image run exited $crc"; note "$(tail -6 "$WORK/container.err")"; }
  [ "$(grep -c . "$MOCK_STATE/requests.container.jsonl" 2>/dev/null || echo 0)" -ge 2 ] \
    && ok "the container reached the model endpoint (2 calls, one per declared file)" \
    || bad "the container made no model call"
  git --git-dir="$IMG/origin.git" for-each-ref --format='%(refname:short)' refs/heads \
    | grep -qx "$GOOD_BRANCH" \
    && ok "the branch was pushed into the mounted origin from inside the container" \
    || bad "no branch in the origin after the in-image run"
  CCH="$(git --git-dir="$IMG/origin.git" diff --name-only "main..$GOOD_BRANCH" 2>/dev/null | sort | tr '\n' ' ')"
  [ "$CCH" = "src/slug.py tests/test_slug.py " ] \
    && ok "the in-image commit touches only the declared files" \
    || bad "the in-image commit touches: $CCH"
  [ "$(python3 "$WORK/q.py" "$IMG/issues.json" 31 npulls)" = 1 ] \
    && ok "a pull request was recorded through the fixture GitHub" \
    || bad "no pull request from the in-image run"
  grep -q "$GITHUB_TOKEN" "$WORK/container.out" "$WORK/container.err" \
    && bad "the token appears in the container's own log" \
    || ok "the token appears nowhere in the container's log"
  grep -qi "read-only\|permission denied" "$WORK/container.err" \
    && bad "something tried to write outside /work: $(grep -i -m1 'read-only\|permission denied' "$WORK/container.err")" \
    || ok "nothing needed to write outside the /work tmpfs"
  docker ps -a --filter name=p8- --format '{{.Names}}' | grep -q . \
    && bad "a p8-* scratch container was left behind" \
    || ok "no scratch container left behind"
fi
fi

################################################################################
if [ "${P5_SKIP_MUTATION:-0}" != 1 ] && [ "$MODE" != image ]; then
echo
echo "MUTATION CONTROL: break the file-scope check and require this suite to go RED"
################################################################################
# A check that has never failed has never been tested. Two mutants, both of which
# make out-of-scope writes acceptable, in two different places:
#
#   M1 - scope_violations() returns nothing, so git is never consulted.
#   M2 - the artefact exemption swallows every path, which is the plausible
#        version of the same bug: a regex written slightly too wide.
#
# Each mutant re-runs this entire suite (with P5_SKIP_MUTATION=1) and must make
# it fail. If it does not, the checks below are decoration.

mutate() { # name  python-patch-file -> mutant path or empty
  local name=$1
  local patch=$2
  local out="$WORK/mutant-$name.py"
  python3 "$patch" "$HERE/worker.py" "$out" || return 1
  printf '%s' "$out"
}

cat > "$WORK/m1.py" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
needle = '    rc, out = git(cfg, ["status", "--porcelain", "-uall"], cwd=repo_dir)'
if needle not in src:
    raise SystemExit("M1: could not find the scope check to break")
open(sys.argv[2], "w", encoding="utf-8").write(
    src.replace(needle, "    return []  # MUTANT M1: the scope check is disabled\n" + needle, 1))
PY
cat > "$WORK/m2.py" <<'PY'
import re
import sys
src = open(sys.argv[1], encoding="utf-8").read()
new, n = re.subn(r'ARTIFACT_RE = re\.compile\(.*?\)\n(?=\n)',
                 'ARTIFACT_RE = re.compile(r".")  # MUTANT M2: exempts everything\n',
                 src, count=1, flags=re.S)
if n != 1:
    raise SystemExit("M2: could not find ARTIFACT_RE to widen")
open(sys.argv[2], "w", encoding="utf-8").write(new)
PY

for m in m1 m2; do
  MUT="$(mutate "$m" "$WORK/$m.py")"
  if [ -z "$MUT" ] || [ ! -f "$MUT" ]; then
    bad "mutation $m could not be applied - the mutation control proves nothing"
    continue
  fi
  P5_SKIP_MUTATION=1 P5_WORKER_SCRIPT="$MUT" "$HERE/verify-worker.sh" \
    > "$WORK/$m.suite.out" 2>&1
  mrc=$?
  # Count the FAIL *lines* the suite printed, not every occurrence of the word:
  # one of the section headings contains "A FAILING SUITE", and counting that
  # would make the mutation control look stronger than it is.
  python3 - "$WORK/$m.suite.out" > "$WORK/$m.fails" <<'PY'
import re
import sys
strip = re.compile(r"\033\[[0-9;]*m")
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    clean = strip.sub("", line).rstrip("\n")
    if clean.startswith("  FAIL  "):
        print(clean[8:])
PY
  MFAILS="$(grep -c . "$WORK/$m.fails" || true)"
  if [ "$mrc" -ne 0 ] && [ "$MFAILS" -gt 0 ]; then
    ok "mutant $m (scope check broken) makes this suite FAIL: $MFAILS failing check(s)"
    head -6 "$WORK/$m.fails" | while read -r line; do note "caught by: $line"; done
  else
    bad "mutant $m passed the suite - the file-scope checks do not actually check anything"
  fi
done
fi

################################################################################
echo
printf 'RESULT: %d passed, %d failed\n\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0

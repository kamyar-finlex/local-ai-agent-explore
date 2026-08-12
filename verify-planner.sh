#!/usr/bin/env bash
# Verification of the PLANNER, in the same discipline as verify-sandbox.sh: the
# claim is measured mechanically rather than asserted, every suite carries a
# POSITIVE CONTROL, and the script exits non-zero if the planner's output would
# not actually be dispatchable.
#
#   ./verify-planner.sh
#
# What is being verified is not "does the model sound sensible" but "does the
# artefact parse", and "does the SCRIPT stay in control when the model does not
# cooperate". Seven independent questions:
#
#   1. Does the validator agree with ORCHESTRATOR.md?  A validator that checks
#      for the wrong section name would pass a plan the dispatcher cannot read --
#      exactly the failure that file's preamble warns about. So the contract is
#      re-read here and compared against the validator's constants.
#   2. Can each check actually FAIL?  Every check is fired at a deliberately
#      malformed plan. A check that has never failed has never been tested; this
#      repo has already shipped one probe that could not fail.
#   3. Is every check exercised?  The union of checks fired across the malformed
#      plans must cover the full check list -- no dead checks.
#   4. Does the emitter's own output satisfy the validator?  Renderer and parser
#      are separate implementations, so the round-trip proves they agree.
#   5. Does `p3-plan.py plan` -- the script-owned loop -- do the right thing when
#      the model misbehaves?  A mock endpoint returns canned replies: prose
#      instead of JSON, truncated JSON, a five-ticket array, schema violations,
#      a mid-run 500. The loop must retry with the error fed back, then STOP
#      LOUDLY. It must never skip a ticket and never invent one.
#   6. Can the ledger hold a ticket the model did not return?  Every ticket
#      record carries the sha256 of the reply it was built from; the harness
#      re-derives the fields from what the mock actually sent and compares.
#      A deliberately fabricated ledger row must be caught by that same check.
#   7. Does the loop terminate?  On coverage, on a stall, and on a budget.
#
# No credentials and no live model: everything runs against fixtures and a mock
# endpoint on loopback. The only network use is that loopback socket.

set -uo pipefail

HERE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$HERE_DIR/hermes-skills/autonomous-ai-agents/orchestrator-planner"
LINT="$SKILL/scripts/p3-plan-lint.py"
PLAN="$SKILL/scripts/p3-plan.py"
GOOD="$HERE_DIR/p3-fixtures/good"
SPECDIR="$HERE_DIR/p3-fixtures/spec"
REPLIES="$HERE_DIR/p3-fixtures/model/replies.json"
CONTRACT="$HERE_DIR/ORCHESTRATOR.md"
SPEC_ISSUE=7

WORK="$(mktemp -d "${TMPDIR:-/tmp}/p3-planner-XXXXXX")"
cleanup() {
  if [ -n "${MOCK_PID:-}" ]; then
    kill "$MOCK_PID" 2>/dev/null
    wait "$MOCK_PID" 2>/dev/null    # reap it, so bash does not print "Terminated"
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
note() { printf '        %s\n' "$1"; }

lint() { python3 "$LINT" "$@"; }
# Check ids that a lint run reported as failed, one per line.
failed_ids() { lint "$@" --json 2>/dev/null | python3 -c \
  'import json,sys; print("\n".join(json.load(sys.stdin)["failed"]))'; }

for f in "$LINT" "$PLAN" "$CONTRACT" "$REPLIES" "$SPECDIR/spec.md" "$SPECDIR/readme.md"; do
  [ -f "$f" ] || { echo "missing: $f" >&2; exit 2; }
done
[ -d "$GOOD" ] || { echo "missing fixtures: $GOOD" >&2; exit 2; }

################################################################################
echo
echo "LINTER SELF-TEST"
################################################################################

ALL_CHECKS="$(lint --list-checks | cut -f1)"
NCHECKS=$(printf '%s\n' "$ALL_CHECKS" | grep -c .)
[ "$NCHECKS" -ge 15 ] \
  && ok "validator exposes $NCHECKS checks" \
  || bad "validator exposes only $NCHECKS checks"

out="$(lint --fixtures "$GOOD" --parent "$SPEC_ISSUE" 2>&1)"; rc=$?
[ $rc -eq 0 ] \
  && ok "a conforming plan passes (exit 0)" \
  || { bad "a conforming plan was rejected (exit $rc)"; printf '%s\n' "$out" | sed 's/^/        /'; }
printf '%s' "$out" | grep -q "0 failed, 0 skipped" \
  && ok "conforming plan: every check ran, none skipped" \
  || bad "conforming plan: some checks skipped - $(printf '%s' "$out" | grep RESULT)"

# The validator is the thing a human leans on before approving tickets; it must
# not need the token that lets an agent write to the repo.
( unset GITHUB_TOKEN TARGET_REPO_TOKEN; lint --fixtures "$GOOD" --parent "$SPEC_ISSUE" >/dev/null 2>&1 )
[ $? -eq 0 ] && ok "validation needs no credentials (fixture mode is offline)" \
             || bad "validation failed without a token - it is reaching the network"

################################################################################
echo
echo "CONTRACT AGREEMENT  (ORCHESTRATOR.md is the source of truth)"
################################################################################
# If the planner writes `Blocked-by` and the dispatcher looks for `Blocks`,
# dependency handling silently never fires. Same class of bug: a validator whose
# idea of the format drifts from the contract. So parse the contract itself.

cat > "$WORK/contract-agreement.py" <<'PY'
import importlib.util, json, os, re, sys

contract, lint_path, good = sys.argv[1], sys.argv[2], sys.argv[3]
spec = importlib.util.spec_from_file_location("lint", lint_path)
lint = importlib.util.module_from_spec(spec); spec.loader.exec_module(lint)

text = open(contract, encoding="utf-8").read()

def emit(cond, msg):
    print(("PASS" if cond else "FAIL") + "\t" + msg)

# The ticket template is the first fenced block after "## Ticket format".
block = re.search(r"## Ticket format.*?```(.*?)```", text, re.S)
sections = re.findall(r"^## (.+)$", block.group(1), re.M) if block else []
expected = lint.REQUIRED_SECTIONS + lint.OPTIONAL_SECTIONS
emit(sections == expected,
     f"validator's sections match the contract template: {sections} vs {expected}")

# Labels named in the contract's state table.
c_status = set(re.findall(r"`(status:[a-z-]+)`", text))
emit(c_status == lint.STATUS_LABELS,
     f"validator knows every status label in the contract: {sorted(c_status)}")

c_prio = set(re.findall(r"`(priority:[1-4])`", text))
emit(c_prio == {"priority:1", "priority:4"}
     and all(lint.PRIORITY_RE.match("priority:" + n) for n in "1234")
     and not lint.PRIORITY_RE.match("priority:5"),
     "contract's priority range is priority:1..priority:4, and so is the validator's")

# The contract says Blocked-by is omitted, not written as "none".
emit('do not write "none"' in text,
     'contract forbids writing "none" under Blocked-by, and FMT-BLOCKED enforces it')

# What the emitter actually stamps on a created issue, read from its output.
labels = set()
for name in os.listdir(good):
    if name.endswith(".json"):
        labels |= set(json.load(open(os.path.join(good, name)))["labels"])
status_used = {l for l in labels if l.startswith("status:")}
emit(status_used == {"status:backlog"},
     f"emitter stamps only status:backlog on creation (found {sorted(status_used)})")
emit({l for l in labels if l.startswith("priority:")} <= {f"priority:{n}" for n in "1234"},
     "emitter stamps only priorities the contract defines")

# The prohibition the SAFE-README check is derived from must still be in force.
emit("modify the target project's README" in text,
     "contract still prohibits touching the target README (SAFE-README's basis)")
PY

python3 "$WORK/contract-agreement.py" "$CONTRACT" "$LINT" "$GOOD" > "$WORK/agreement.txt" 2>&1 \
  || bad "the contract-agreement probe itself failed: $(tail -1 "$WORK/agreement.txt")"
while IFS=$'\t' read -r verdict msg; do
  [ -n "${verdict:-}" ] || continue
  [ "$verdict" = "PASS" ] && ok "$msg" || bad "$msg"
done < "$WORK/agreement.txt"

################################################################################
echo
echo "POSITIVE CONTROLS  (every check must be able to FAIL)"
################################################################################
# Each case is the conforming plan with ONE deliberate defect. The validator has
# to reject it AND name the right check; "exit non-zero" alone would be satisfied
# by a validator that rejects everything.

mutate() { # case-name dest-dir
  python3 - "$GOOD" "$2" "$1" <<'PY'
import json, os, shutil, sys
src, dst, case = sys.argv[1], sys.argv[2], sys.argv[3]
shutil.rmtree(dst, ignore_errors=True); shutil.copytree(src, dst)

def load(t): return json.load(open(os.path.join(dst, t + ".json")))
def save(t, i): json.dump(i, open(os.path.join(dst, t + ".json"), "w"), indent=2, sort_keys=True)

def edit(t, fn):
    i = load(t); fn(i); save(t, i)

M = {
  # id                     what is broken
  "no-details-section":   lambda: edit("T3", lambda i: i.update(body=i["body"].replace("## Details\n", ""))),
  "long-title":           lambda: edit("T2", lambda i: i.update(title="x" * 90)),
  "multiline-goal":       lambda: edit("T2", lambda i: i.update(body=i["body"].replace(
                              "## Goal\n", "## Goal\nfirst line of a paragraph\n"))),
  "absolute-path":        lambda: edit("T3", lambda i: i.update(body=i["body"].replace(
                              "- src/example/store.py", "- /etc/passwd"))),
  "thin-details":         lambda: edit("T4", lambda i: i.update(body=i["body"].replace(
                              i["body"].split("## Details\n")[1].split("\n\n")[0], "todo"))),
  "chained-acceptance":   lambda: edit("T3", lambda i: i.update(body=i["body"].replace(
                              "pytest -q tests/test_store.py\n\n## Blocked-by",
                              "cd src && pytest -q\n\n## Blocked-by"))),
  "prose-acceptance":     lambda: edit("T4", lambda i: i.update(body=i["body"].replace(
                              "pytest -q tests/test_api.py", "the router should return 404"))),
  "blocked-by-none":      lambda: edit("T5", lambda i: i.update(body=i["body"].replace("#9003", "none"))),
  "two-priorities":       lambda: edit("T2", lambda i: i["labels"].append("priority:4")),
  "no-backlog-label":     lambda: edit("T2", lambda i: i.update(
                              labels=[l for l in i["labels"] if l != "status:backlog"])),
  "self-approved":        lambda: edit("T4", lambda i: i["labels"].append("status:todo")),
  "child-is-spec":        lambda: edit("T4", lambda i: i["labels"].append("spec")),
  "dangling-blocker":     lambda: edit("T5", lambda i: i.update(body=i["body"].replace("#9003", "#4242"))),
  "dependency-cycle":     lambda: edit("T1", lambda i: i.update(body=i["body"].rstrip()
                              + "\n\n## Blocked-by\n#9005\n")),
  "file-overlap":         lambda: edit("T3", lambda i: i.update(body=i["body"].replace(
                              "- tests/test_store.py", "- src/example/api.py"))),
  "touches-readme":       lambda: edit("T3", lambda i: i.update(body=i["body"].replace(
                              "- src/example/store.py", "- README.md"))),
  "oversized-ticket":     lambda: edit("T4", lambda i: i.update(body=i["body"].replace(
                              "- src/example/api.py",
                              "- src/example/api.py\n- a.py\n- b.py\n- c.py\n- d.py"))),
  "orphan-ticket":        lambda: edit("T3", lambda i: i.update(parent=99)),
}
M[case]()
PY
}

FIRED="$WORK/fired.txt"; : > "$FIRED"

# case-name : check ids that MUST appear among the failures
CASES="
no-details-section:FMT-SECTIONS
long-title:FMT-TITLE
multiline-goal:FMT-GOAL
absolute-path:FMT-FILES
thin-details:FMT-DETAILS
chained-acceptance:FMT-ACCEPT
prose-acceptance:FMT-ACCEPT
blocked-by-none:FMT-BLOCKED
two-priorities:LBL-PRIORITY
no-backlog-label:LBL-BACKLOG
self-approved:LBL-STATUS
child-is-spec:LBL-NOSPEC
dangling-blocker:DEP-RESOLVE
dependency-cycle:DEP-CYCLE,DEP-ROOT
file-overlap:CONC-FILES
touches-readme:SAFE-README
oversized-ticket:SIZE-FILES
orphan-ticket:LINK-PARENT
"

for entry in $CASES; do
  case_name=${entry%%:*}; want=${entry#*:}
  dir="$WORK/$case_name"
  mutate "$case_name" "$dir" || { bad "$case_name: could not build the malformed fixture"; continue; }

  got="$(failed_ids --fixtures "$dir" --parent "$SPEC_ISSUE")"
  printf '%s\n' "$got" >> "$FIRED"
  lint --fixtures "$dir" --parent "$SPEC_ISSUE" >/dev/null 2>&1; rc=$?

  missing=""
  for w in $(printf '%s' "$want" | tr ',' ' '); do
    printf '%s\n' "$got" | grep -qx "$w" || missing="$missing $w"
  done
  if [ $rc -eq 0 ]; then
    bad "$case_name: validator accepted a plan that is not dispatchable (exit 0)"
  elif [ -n "$missing" ]; then
    bad "$case_name: rejected, but$missing did not fire (fired:$(printf '%s' "$got" | tr '\n' ' '))"
  else
    ok "$case_name -> $want"
  fi
done

################################################################################
echo
echo "COVERAGE OF THE CHECKS THEMSELVES"
################################################################################
# A check nothing has ever fired is indistinguishable from a check that cannot
# fire. Refuse to report a clean sweep unless every check has been made to fail.

uncovered=""
for c in $ALL_CHECKS; do
  grep -qx "$c" "$FIRED" || uncovered="$uncovered $c"
done
[ -z "$uncovered" ] \
  && ok "all $NCHECKS checks were made to fail by at least one control" \
  || bad "never exercised, so unproven:$uncovered"

################################################################################
echo
echo "PLANNER ROUND-TRIP  (what the emitter writes, the validator must accept)"
################################################################################
# The renderer in p3-plan.py and the parser in p3-plan-lint.py are separate
# implementations on purpose; this is where they are held against each other.

RT="$WORK/roundtrip"
python3 "$PLAN" --plan-dir "$RT" init --repo example-org/example-service --spec "$SPEC_ISSUE" >/dev/null
python3 "$PLAN" --plan-dir "$RT" add --id T1 --priority 1 \
  --title "Create the package skeleton" --files pyproject.toml,tests/test_smoke.py \
  --acceptance "pytest -q tests/test_smoke.py" \
  --goal "The repository installs and runs an empty test suite." \
  --details "Create pyproject.toml with a src layout and pytest as the only dev dependency, plus one trivial smoke test." >/dev/null
python3 "$PLAN" --plan-dir "$RT" add --id T2 --priority 2 --blocked-by T1 \
  --title "Add the record store" --files src/example/store.py,tests/test_store.py \
  --acceptance "pytest -q tests/test_store.py" \
  --goal "Records can be added and fetched by id." \
  --details "Implement the Store class from the README data model, with add/get/list and a KeyError on a missing id." >/dev/null
python3 "$PLAN" --plan-dir "$RT" add --id T3 --priority 2 --blocked-by T1 \
  --title "Add the HTTP router" --files src/example/api.py,tests/test_api.py \
  --acceptance "pytest -q tests/test_api.py" \
  --goal "The service maps HTTP paths to handler callables." \
  --details "Implement register and dispatch from the README HTTP surface section, returning 404 for unknown routes." >/dev/null

lint --ledger "$RT/tickets.jsonl" >/dev/null 2>&1 \
  && ok "the ledger validates before a single issue is created" \
  || bad "the ledger the planner just wrote does not validate"

( unset GITHUB_TOKEN TARGET_REPO_TOKEN
  python3 "$PLAN" --plan-dir "$RT" emit --all --dry-run --fixtures "$RT/fixtures" >/dev/null 2>&1 )
[ $? -eq 0 ] && ok "dry-run emit needs no token (nothing reaches GitHub)" \
             || bad "dry-run emit failed or wanted credentials"

lint --fixtures "$RT/fixtures" --parent "$SPEC_ISSUE" >/dev/null 2>&1 \
  && ok "rendered issue bodies parse back cleanly (renderer and parser agree)" \
  || bad "the emitter produced bodies its own validator rejects"

n=$(ls "$RT/fixtures" | grep -c '\.json$')
[ "$n" -eq 3 ] && ok "one file per ticket: a crash loses one ticket, not the plan" \
               || bad "expected 3 rendered tickets, found $n"

# Resumability. Simulate a run that created T1 and then died - the ledger records
# the created issue, so the next invocation must skip it rather than duplicate it.
# This is the property that makes a lost turn cost one ticket instead of a plan.
printf '%s\n' '{"kind":"emitted","id":"T1","number":41}' >> "$RT/tickets.jsonl"
again=$(python3 "$PLAN" --plan-dir "$RT" emit --all --dry-run --fixtures "$RT/fixtures" 2>&1)
printf '%s' "$again" | grep -q "skip T1: already issue #41" \
  && ok "emit resumes from the ledger instead of recreating (T1 skipped)" \
  || bad "emit did not skip the ticket the ledger says was already created: $again"
printf '%s' "$again" | grep -q "dry-run T2" \
  && ok "the tickets that were never created are still emitted" \
  || bad "resuming skipped work that had not been done"
[ "$(python3 "$PLAN" --plan-dir "$RT" next)" = "T2" ] \
  && ok "\`next\` names the ticket to retry, so a fresh context can resume" \
  || bad "\`next\` did not name the first unemitted ticket"

################################################################################
echo
echo "EARLY REJECTION  (a malformed row never reaches the ledger)"
################################################################################
# The point of validating at `add` time is that a small model is corrected while
# it still remembers what it meant. Each of these must be refused at entry.

RJ="$WORK/reject"
python3 "$PLAN" --plan-dir "$RJ" init --repo example-org/example-service --spec "$SPEC_ISSUE" >/dev/null
python3 "$PLAN" --plan-dir "$RJ" add --id T1 --priority 1 --title "Scaffold" \
  --files pyproject.toml --acceptance "pytest -q" \
  --goal "The suite runs." --details "Create pyproject.toml with pytest as the only dev dependency." >/dev/null

reject() { # label expected-substring args...
  local label=$1 want=$2; shift 2
  local out; out=$(python3 "$PLAN" --plan-dir "$RJ" add "$@" 2>&1); local rc=$?
  if [ $rc -eq 0 ]; then
    bad "accepted a ticket it should have refused: $label"
  elif printf '%s' "$out" | grep -q "$want"; then
    ok "refused at entry: $label"
  else
    bad "$label refused for the wrong reason: $out"
  fi
}

BASE_OK=(--priority 2 --goal "Records can be fetched." \
         --details "Implement the Store class from the README data model section.")

reject "prose acceptance criterion" "prose" --id T2 --title "Store" \
  --files src/store.py --acceptance "the tests should pass" "${BASE_OK[@]}"
reject "two commands in the acceptance criterion" "chains commands" --id T2 --title "Store" \
  --files src/store.py --acceptance "pytest -q && ruff check ." "${BASE_OK[@]}"
reject "a ticket that edits the README" "README" --id T2 --title "Docs" \
  --files README.md --acceptance "pytest -q" "${BASE_OK[@]}"
reject "an unknown blocker" "does not exist" --id T2 --title "Store" \
  --files src/store.py --acceptance "pytest -q" --blocked-by T9 "${BASE_OK[@]}"
reject "priority outside 1-4" "priority must be" --id T2 --title "Store" \
  --files src/store.py --acceptance "pytest -q" --goal "Records can be fetched." \
  --details "Implement the Store class from the README data model section." --priority 7
reject "a file already claimed by a concurrent ticket" "already claimed" --id T2 --title "More scaffold" \
  --files pyproject.toml --acceptance "pytest -q" "${BASE_OK[@]}"
reject "a ticket with no files" "no files listed" --id T2 --title "Think about it" \
  --files "," --acceptance "pytest -q" "${BASE_OK[@]}"

n=$(grep -c '"kind": "ticket"' "$RJ/tickets.jsonl")
[ "$n" -eq 1 ] && ok "the ledger still holds only the one valid ticket" \
               || bad "$n tickets in the ledger; a refused row was written anyway"

################################################################################
echo
echo "MOCK MODEL  (the script-owned loop, driven by canned replies)"
################################################################################
# `p3-plan.py plan` runs the whole loop itself and calls the model only for
# decisions. Everything below drives that loop against an OpenAI-compatible
# endpoint on loopback that returns whatever p3-fixtures/model/replies.json says
# for the scenario currently selected. No live model, no GitHub, no credentials.

MOCK_STATE="$WORK/mock"
mkdir -p "$MOCK_STATE" "$WORK/cwd"

cat > "$WORK/mock-model.py" <<'PY'
#!/usr/bin/env python3
"""A canned OpenAI-compatible chat endpoint.

It reads the scenario name from a file on every request, so a suite can change
the model's behaviour mid-run -- which is how the "interrupted run resumes"
case is built without restarting anything.

Which reply is served is decided by reading the prompt the planner sent, the
same way a human would: the layout call announces itself, and a ticket call
names the ticket it is asking for. Every reply actually returned is appended to
replies.jsonl, which is what the anti-fabrication suite checks the ledger
against.
"""
import hashlib
import json
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPLIES, STATE = sys.argv[1], sys.argv[2]
DOC = json.load(open(REPLIES, encoding="utf-8"))["scenarios"]
SERVED = {}          # (scenario, key) -> attempts served so far

TICKET_RE = re.compile(r"This is ticket (T\d+)\.")


def log(name, rec):
    with open(os.path.join(STATE, name), "a", encoding="utf-8") as fh:
        fh.write(json.dumps(rec, sort_keys=True) + "\n")


def scenario():
    with open(os.path.join(STATE, "scenario"), encoding="utf-8") as fh:
        return fh.read().strip()


def decide(prompt):
    if "TASK: choose the complete file layout" in prompt:
        return "layout"
    m = TICKET_RE.search(prompt)
    return m.group(1) if m else "unknown"


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        if self.path != "/v1/chat/completions":
            self.send_error(404, "only /v1/chat/completions is mocked")
            return
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        prompt = "\n".join(m.get("content") or "" for m in body["messages"])
        scen = scenario()
        key = decide(prompt)
        n = SERVED.get((scen, key), 0) + 1
        SERVED[(scen, key)] = n
        table = DOC.get(scen)
        if table is None:
            self.send_error(500, f"unknown scenario {scen!r}")
            return
        content = table.get(f"{key}#{n}", table.get(key, table.get("*")))
        log("requests.jsonl", {"scenario": scen, "key": key, "attempt": n,
                               "served": content is not None,
                               "retry_turns": sum(1 for m in body["messages"]
                                                  if m["role"] == "assistant")})
        if content is None:
            self.send_error(500, f"scenario {scen!r} has no reply for {key!r}")
            return
        if content == "__http500__":
            self.send_error(500, "the mock endpoint is deliberately down")
            return
        log("replies.jsonl", {"scenario": scen, "key": key, "attempt": n,
                              "sha256": hashlib.sha256(content.encode()).hexdigest(),
                              "content": content})
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


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
with open(os.path.join(STATE, "port"), "w", encoding="utf-8") as fh:
    fh.write(str(srv.server_address[1]))
srv.serve_forever()
PY

printf 'good\n' > "$MOCK_STATE/scenario"
python3 "$WORK/mock-model.py" "$REPLIES" "$MOCK_STATE" &
MOCK_PID=$!
for _ in $(seq 1 50); do [ -s "$MOCK_STATE/port" ] && break; sleep 0.1; done
MOCK_PORT="$(cat "$MOCK_STATE/port" 2>/dev/null || true)"
if [ -n "$MOCK_PORT" ] && kill -0 "$MOCK_PID" 2>/dev/null; then
  ok "mock model endpoint listening on loopback (no live model, no GPU)"
else
  bad "the mock model endpoint did not start - every suite below is meaningless"
  echo; printf 'RESULT: %d passed, %d failed\n\n' "$pass" "$fail"; exit 1
fi
MOCK_URL="http://127.0.0.1:$MOCK_PORT/v1/chat/completions"

# One planning run. Credentials are explicitly emptied: a --dry-run plan that
# reads its spec from a file must never reach GitHub.
plan_run() { # scenario run-name [extra args to `plan`]
  local scen=$1 name=$2; shift 2
  printf '%s\n' "$scen" > "$MOCK_STATE/scenario"
  ( cd "$WORK/cwd" && env -u GITHUB_TOKEN -u TARGET_REPO_TOKEN \
      P3_MODEL_URL="$MOCK_URL" P3_MODEL="mock-model" P3_MODEL_TIMEOUT=30 \
      python3 "$PLAN" --plan-dir "$WORK/$name" plan \
        --repo example-org/example-service --spec "$SPEC_ISSUE" \
        --spec-file "$SPECDIR/spec.md" --readme-file "$SPECDIR/readme.md" \
        --dry-run "$@" ) > "$WORK/$name.out" 2> "$WORK/$name.err"
}
tickets_in() { # run-name -> how many tickets its ledger holds
  local f="$WORK/$1/tickets.jsonl"
  [ -f "$f" ] || { echo 0; return; }
  grep -c '"kind": "ticket"' "$f" || true    # grep prints 0 and exits 1 on no match
}

# --- a well-formed reply produces a conforming ticket ----------------------- #
plan_run good run-good; rc=$?
[ $rc -eq 0 ] && ok "a well-formed model reply drives the loop to completion (exit 0)" \
              || { bad "the good scenario failed (exit $rc)"; sed 's/^/        /' "$WORK/run-good.err" | tail -20; }

NGOOD=$(tickets_in run-good)
[ "$NGOOD" -ge 3 ] \
  && ok "the loop produced $NGOOD tickets from the mock's replies" \
  || bad "only $NGOOD ticket(s) produced - the mock suites would pass vacuously"

lint --fixtures "$WORK/run-good/fixtures" --parent "$SPEC_ISSUE" >/dev/null 2>&1 \
  && ok "every ticket the loop produced satisfies the contract validator" \
  || bad "the loop produced tickets its own validator rejects"

grep -q "0 failed" "$WORK/run-good.out" \
  && ok "the loop ran the validator itself and reported a clean plan" \
  || bad "the loop did not report a validated plan"

[ -z "$(ls -A "$WORK/cwd")" ] \
  && ok "the run wrote nothing outside its plan directory (the model has no shell)" \
  || bad "files appeared in the working directory: $(ls -A "$WORK/cwd" | tr '\n' ' ')"

# A fence and a prose preamble are the model's own JSON, just dressed up.
plan_run fenced run-fenced; rc=$?
[ $rc -eq 0 ] && ok "a fenced reply with a preamble is accepted (the JSON is still the model's)" \
              || bad "a fenced JSON reply defeated the parser (exit $rc)"

################################################################################
echo
echo "MALFORMED REPLIES  (retry with the error fed back, then stop loudly)"
################################################################################
# The failure this whole design exists to prevent is a planner that fills a gap
# it could not get an answer for. So: exhausting the retries must FAIL, not
# skip, and not invent.

for case in bad-json truncated-json json-array; do
  plan_run "$case" "run-$case" --retries 2; rc=$?
  err="$WORK/run-$case.err"
  if [ $rc -eq 3 ]; then
    ok "$case: the loop stopped loudly (exit 3) instead of continuing"
  else
    bad "$case: expected exit 3, got $rc"
  fi
  grep -q -- "--- last raw reply ---" "$err" \
    && ok "$case: the raw reply is printed, so a human can see what was actually said" \
    || bad "$case: the raw model reply was swallowed"
  n=$(tickets_in "run-$case")
  [ "$n" -eq 0 ] \
    && ok "$case: no ticket was invented to fill the gap (ledger holds 0)" \
    || bad "$case: $n ticket(s) in the ledger after an unusable reply"
  [ ! -d "$WORK/run-$case/fixtures" ] \
    && ok "$case: nothing was emitted" \
    || bad "$case: issues were rendered from a plan that never validated"
done

# Retries must actually be spent, and the rejection must be sent BACK.
att=$(python3 - "$MOCK_STATE/requests.jsonl" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8")]
rows = [r for r in rows if r["scenario"] == "bad-json" and r["key"] == "T1"]
print(f'{len(rows)} {max((r["retry_turns"] for r in rows), default=0)}')
PY
)
set -- $att
[ "$1" -eq 3 ] \
  && ok "the rejected decision was retried to the configured limit (3 attempts)" \
  || bad "expected 3 attempts at the same decision, saw $1"
[ "$2" -ge 1 ] \
  && ok "the retry prompt carries the previous reply and the rejection reason" \
  || bad "retries were sent as a fresh prompt - the parse error was not fed back"

# ...and a first-attempt failure that the model then fixes must recover.
plan_run retry-then-good run-retry --retries 2; rc=$?
[ $rc -eq 0 ] \
  && ok "a rejected first attempt followed by a correct one recovers (exit 0)" \
  || bad "the retry path cannot succeed (exit $rc) - retries would be theatre"

################################################################################
echo
echo "SCHEMA VIOLATIONS  (parseable JSON that is still not a ticket)"
################################################################################
# Each scenario returns ONE well-formed JSON object with exactly one defect, and
# --retries 0 so the loop fails on the first reply. The run must be rejected AND
# the message must name the actual defect: "exit non-zero" alone would be
# satisfied by a planner that rejects everything.

schema_case() { # scenario expected-substring-in-the-rejection
  local scen=$1 want=$2
  plan_run "$scen" "run-$scen" --retries 0; local rc=$?
  local err="$WORK/run-$scen.err"
  if [ $rc -eq 0 ]; then
    bad "$scen: accepted a reply that violates the schema"
  elif grep -qi -- "$want" "$err"; then
    ok "$scen -> rejected: $(grep -o "rejected: .*" "$err" | head -1 | cut -c1-72)"
  else
    bad "$scen: rejected for the wrong reason: $(grep 'rejected:' "$err" | head -1)"
  fi
  local n; n=$(tickets_in "run-$scen")
  [ "$n" -eq 0 ] || bad "$scen: a rejected ticket reached the ledger anyway"
}

schema_case schema-missing-files    "missing key 'files'"
schema_case schema-empty-files      "no files listed"
schema_case schema-prose-acceptance "prose"
schema_case schema-two-priorities   "priority must be"
schema_case schema-chained-acceptance "chains commands"
schema_case schema-off-layout       "not in the recorded file layout"
schema_case schema-touches-readme   "README"
schema_case schema-long-title       "title must be"
schema_case schema-thin-details     "details is too thin"
schema_case schema-unknown-blocker  "does not exist yet"
schema_case schema-foreign-acceptance "it cannot pass"

################################################################################
echo
echo "TERMINATION  (the loop ends, three ways, and cannot spin)"
################################################################################

cov=$(python3 - "$WORK/run-good/tickets.jsonl" <<'PY'
import json, sys
layout, claimed, n = [], set(), 0
for line in open(sys.argv[1], encoding="utf-8"):
    r = json.loads(line)
    if r.get("kind") == "layout":
        layout = r["paths"]
    elif r.get("kind") == "ticket":
        n += 1
        claimed |= set(r["files"])
missing = [p for p in layout if p not in claimed]
print(f'{len(layout)} {n} {",".join(missing) or "-"}')
PY
)
set -- $cov
[ "$3" = "-" ] \
  && ok "the loop stopped because all $1 layout paths were claimed by $2 tickets" \
  || bad "the loop stopped with paths unclaimed: $3"

# A budget the plan cannot meet must fail, not quietly emit a partial plan.
plan_run good run-budget --max-tickets 2; rc=$?
[ $rc -eq 4 ] \
  && ok "hitting the ticket budget with paths unclaimed fails (exit 4)" \
  || bad "expected exit 4 on an unmet ticket budget, got $rc"
grep -q "still unclaimed" "$WORK/run-budget.err" \
  && ok "the budget failure names the paths no ticket claimed" \
  || bad "the budget failure does not say what is missing"
[ ! -d "$WORK/run-budget/fixtures" ] \
  && ok "a plan that hit the budget emitted nothing" \
  || bad "a partial plan was emitted"

# A model that keeps proposing valid tickets which claim nothing new would spin
# until the budget. The stall detector stops it much earlier.
plan_run stall run-stall --max-stalls 2 --max-tickets 25; rc=$?
[ $rc -eq 4 ] \
  && ok "a non-converging model is stopped by the stall detector (exit 4)" \
  || bad "expected exit 4 from the stall detector, got $rc"
n=$(tickets_in run-stall)
[ "$n" -le 4 ] \
  && ok "the stall was caught after $n tickets, not after the 25-ticket budget" \
  || bad "the stall detector let $n tickets through"

################################################################################
echo
echo "ANTI-FABRICATION  (the ledger holds only what the model returned)"
################################################################################
# This is the property the whole redesign is for: an earlier planner printed a
# confident five-ticket plan when the ledger held two. Every ticket record
# carries the sha256 of the reply it was built from, so the claim is checkable
# rather than assertable -- and the check is fired at a fabricated row to prove
# it can fail.

cat > "$WORK/antifab.py" <<'PY'
import hashlib, json, sys

ledger, replies = sys.argv[1], sys.argv[2]
FIELDS = ("title", "priority", "files", "blocked_by", "acceptance", "goal", "details")

by_sha = {}
for line in open(replies, encoding="utf-8"):
    r = json.loads(line)
    by_sha[r["sha256"]] = r["content"]

problems, n = [], 0
for line in open(ledger, encoding="utf-8"):
    rec = json.loads(line)
    if rec.get("kind") != "ticket":
        continue
    n += 1
    sha = rec.get("raw_sha256")
    if sha is None:
        problems.append(f'{rec["id"]}: no provenance -- it records no model reply')
        continue
    if sha not in by_sha:
        problems.append(f'{rec["id"]}: sha {sha[:12]} matches no reply the model sent')
        continue
    # Not just "a reply existed" -- the FIELDS must be the ones in that reply.
    raw = by_sha[sha]
    s, e = raw.find("{"), raw.rfind("}")
    sent = json.loads(raw[s:e + 1])
    for f in FIELDS:
        want = sent.get(f)
        if isinstance(want, str):
            want = want.strip()
        if want != rec.get(f):
            problems.append(f'{rec["id"]}.{f} is not what the model sent')
print(json.dumps({"tickets": n, "problems": problems}))
PY

af=$(python3 "$WORK/antifab.py" "$WORK/run-good/tickets.jsonl" "$MOCK_STATE/replies.jsonl")
nprob=$(printf '%s' "$af" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d["problems"]))')
nt=$(printf '%s' "$af" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tickets"])')
[ "$nprob" -eq 0 ] \
  && ok "all $nt ledger tickets re-derive, field for field, from replies the model actually sent" \
  || bad "ledger tickets do not match what the model sent: $af"

# Positive control for the check itself: fabricate a ticket the way the old
# planner did -- a plausible row that no reply ever contained.
cp "$WORK/run-good/tickets.jsonl" "$WORK/fabricated.jsonl"
python3 - "$WORK/fabricated.jsonl" <<'PY'
import json, sys
row = {"kind": "ticket", "id": "T9", "title": "Add the CSV export endpoint",
       "priority": 2, "files": ["src/example/export.py"], "blocked_by": [],
       "acceptance": "pytest -q tests/test_export.py",
       "goal": "Records can be exported as CSV.",
       "details": "A perfectly plausible ticket that no model reply ever contained.",
       "raw_sha256": "0" * 64, "origin": "model"}
open(sys.argv[1], "a", encoding="utf-8").write(json.dumps(row, sort_keys=True) + "\n")
PY
fab=$(python3 "$WORK/antifab.py" "$WORK/fabricated.jsonl" "$MOCK_STATE/replies.jsonl")
printf '%s' "$fab" | grep -q "matches no reply the model sent" \
  && ok "a fabricated ticket IS caught by that check (so the check can fail)" \
  || bad "the anti-fabrication check accepted an invented ticket: $fab"

# And the audit trail must agree with the ledger: one accepted reply per ticket.
acc=$(python3 - "$WORK/run-good/tickets.jsonl" <<'PY'
import json, sys
t = a = 0
for line in open(sys.argv[1], encoding="utf-8"):
    r = json.loads(line)
    if r.get("kind") == "ticket":
        t += 1
    elif r.get("kind") == "modelcall" and r["call"].startswith("ticket") and not r["error"]:
        a += 1
print(f"{t} {a}")
PY
)
set -- $acc
[ "$1" -eq "$2" ] \
  && ok "one accepted model reply per ticket in the ledger ($1 = $2)" \
  || bad "$1 tickets but $2 accepted ticket replies - the two do not agree"

################################################################################
echo
echo "RESUME  (an interrupted run continues, it does not re-plan)"
################################################################################
# The endpoint dies after two tickets. The ledger keeps them; a second run must
# pick up at ticket three, re-ask nothing it already has, and duplicate nothing.

plan_run interrupt run-resume --retries 1; rc=$?
[ $rc -ne 0 ] && ok "the run died when the endpoint went away (exit $rc)" \
              || bad "the run reported success despite a dead endpoint"
first=$(tickets_in run-resume)
[ "$first" -eq 2 ] \
  && ok "the two tickets decided before the failure survived in the ledger" \
  || bad "expected 2 tickets in the interrupted ledger, found $first"
cp "$WORK/run-resume/tickets.jsonl" "$WORK/resume-before.jsonl"

plan_run good run-resume; rc=$?
[ $rc -eq 0 ] && ok "the resumed run completed (exit 0)" \
              || { bad "the resumed run failed (exit $rc)"; tail -5 "$WORK/run-resume.err" | sed 's/^/        /'; }
grep -q "resuming example-org/example-service" "$WORK/run-resume.out" \
  && ok "the resumed run said it was resuming rather than starting over" \
  || bad "the resumed run did not announce a resume"
grep -q "layout already recorded" "$WORK/run-resume.out" \
  && ok "the layout was not re-asked - one layout call per plan, ever" \
  || bad "the resumed run asked the model for the layout a second time"

dup=$(python3 - "$WORK/run-resume/tickets.jsonl" "$WORK/resume-before.jsonl" <<'PY'
import json, sys
def tickets(p):
    return [json.loads(l) for l in open(p, encoding="utf-8")
            if json.loads(l).get("kind") == "ticket"]
after, before = tickets(sys.argv[1]), tickets(sys.argv[2])
ids = [t["id"] for t in after]
dupes = sorted({i for i in ids if ids.count(i) > 1})
same = all(a["title"] == b["title"] and a["files"] == b["files"]
           for a, b in zip(after, before))
print(f'{len(after)} {",".join(dupes) or "-"} {"same" if same else "REWRITTEN"}')
PY
)
set -- $dup
[ "$2" = "-" ] && ok "no ticket id appears twice after resuming ($1 tickets)" \
               || bad "resuming duplicated tickets: $2"
[ "$3" = "same" ] && ok "the tickets decided before the interruption were not re-decided" \
                  || bad "resuming rewrote work that was already in the ledger"
[ "$1" -eq "$NGOOD" ] \
  && ok "the resumed plan reaches the same size as an uninterrupted one ($1)" \
  || bad "resumed plan has $1 tickets, an uninterrupted one has $NGOOD"

################################################################################
echo
echo "POSITIVE CONTROL FOR THESE SUITES"
################################################################################
# If the mock never returns anything usable, the loop must fail. A suite that
# still reports success against `never-valid` is measuring nothing at all --
# this repo has shipped a probe that could not fail once already.

plan_run never-valid run-control --retries 1; rc=$?
[ $rc -ne 0 ] \
  && ok "a model that never answers usefully produces a FAILED run (exit $rc)" \
  || bad "the loop reported success from a model that answered nothing - these suites are vacuous"
[ "$(tickets_in run-control)" -eq 0 ] \
  && ok "...and an empty ledger, not a plausible-looking plan" \
  || bad "tickets appeared from a model that returned no usable reply"

nscen=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["scenarios"]))' "$REPLIES")
served=$(python3 -c '
import json,sys
print(len({json.loads(l)["scenario"] for l in open(sys.argv[1], encoding="utf-8")}))' "$MOCK_STATE/requests.jsonl")
[ "$served" -ge "$nscen" ] \
  && ok "every one of the $nscen canned scenarios was actually exercised" \
  || bad "only $served of $nscen scenarios were used - some canned replies are dead fixtures"

echo
printf 'RESULT: %d passed, %d failed\n\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1

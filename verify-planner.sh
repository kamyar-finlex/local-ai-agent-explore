#!/usr/bin/env bash
# Verification of the PLANNER, in the same discipline as verify-sandbox.sh: the
# claim is measured mechanically rather than asserted, every suite carries a
# POSITIVE CONTROL, and the script exits non-zero if the planner's output would
# not actually be dispatchable.
#
#   ./verify-planner.sh
#
# What is being verified is not "does the model sound sensible" but "does the
# artefact parse". Four independent questions:
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
#
# No credentials and no network: everything runs against fixtures.

set -uo pipefail

HERE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$HERE_DIR/hermes-skills/autonomous-ai-agents/orchestrator-planner"
LINT="$SKILL/scripts/p3-plan-lint.py"
PLAN="$SKILL/scripts/p3-plan.py"
GOOD="$HERE_DIR/p3-fixtures/good"
CONTRACT="$HERE_DIR/ORCHESTRATOR.md"
SPEC_ISSUE=7

WORK="$(mktemp -d "${TMPDIR:-/tmp}/p3-planner-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
note() { printf '        %s\n' "$1"; }

lint() { python3 "$LINT" "$@"; }
# Check ids that a lint run reported as failed, one per line.
failed_ids() { lint "$@" --json 2>/dev/null | python3 -c \
  'import json,sys; print("\n".join(json.load(sys.stdin)["failed"]))'; }

for f in "$LINT" "$PLAN" "$CONTRACT"; do
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

echo
printf 'RESULT: %d passed, %d failed\n\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1

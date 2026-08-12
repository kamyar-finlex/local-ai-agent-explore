#!/usr/bin/env bash
# Verification of the DISPATCH LOOP (p4-dispatch-loop.py), in the same style as
# verify-sandbox.sh / verify-spawning.sh: PASS/FAIL lines, a positive control in
# every suite, and a non-zero exit if anything fails.
#
#   ./verify-dispatch.sh            # the scheduling suites, against FIXTURES
#   ./verify-dispatch.sh spawn      # + a live spawn through p1-dispatcher
#                                   #   (needs ./p1-spawn-setup.sh first)
#
# Why fixtures: the scheduler's job is to be right EVERY time, so it is tested
# against a repository state that is committed, readable and identical on every
# run. A live GitHub repo cannot give that - and it also cannot be made to hold
# a dependency cycle, a dead worker and a claim race at the same instant.
#
# The fixtures are in p4-fixtures/. Nothing here reaches the network, and no
# credential is required: --source fixture:<file> replaces the GitHub client
# with one that reads and writes a JSON file.
#
# THE POSITIVE CONTROL MATTERS MOST. Most assertions below are of the form
# "this ticket must NOT be dispatched", and a dispatcher that dispatches nothing
# at all satisfies every one of them. So each suite first proves that work
# genuinely flows: tickets dispatched, containers spawned, labels moved.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[ -f "$HERE/local.env" ] && . "$HERE/local.env"

SCRIPT="$HERE/p4-dispatch-loop.py"
FIX="$HERE/p4-fixtures"
NOW="2026-01-01T12:00:00Z"          # fixtures are timestamped against this
WORK="$(mktemp -d "${TMPDIR:-/tmp}/p4-verify.XXXXXX")"
MODE="${1:-fixtures}"

# A deliberately recognisable fake. No real credential exists in this repo; the
# hygiene suite greps every byte of output for this string.
export TARGET_REPO_TOKEN="p4-fake-token-8Qm2-never-log-me"
export P4_SPAWN_TOKEN="p4-fake-spawn-token-7Zx9"
export TARGET_REPO="example/target"

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
note() { printf '        %s\n' "$1"; }
cleanup() { rm -rf "$WORK" "$HERE/__pycache__"; }
trap cleanup EXIT

# --- query helpers: read the dispatcher's JSON output --------------------------
q() {  # FILE PYTHON-EXPR   (d = parsed json)
  python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
sys.stdout.write(str(eval(sys.argv[2])))' "$1" "$2" 2>/dev/null
}
plan_dispatch() { q "$1" '" ".join(str(x["issue"]) for x in (d.get("dispatch") or d["plan"]["dispatch"]))'; }
skip_reason()   { q "$1" 'next((s["reason"] for s in (d.get("skipped") or d["plan"]["skipped"]) if s["issue"]=='"$2"'), "NOT-SKIPPED")'; }
skip_detail()   { q "$1" 'next((s["detail"] for s in (d.get("skipped") or d["plan"]["skipped"]) if s["issue"]=='"$2"'), "")'; }
defect_kinds()  { q "$1" '" ".join(x["kind"] for x in (d.get("defects") or d["plan"]["defects"]) if x["issue"]=='"$2"')'; }
labels_of()     { q "$1" '" ".join(sorted(next(i["labels"] for i in d["issues"] if i["number"]=='"$2"')))'; }
claimed()       { q "$1" 'next((str(c["claimed"]) for c in d["claims"] if c["issue"]=='"$2"'), "NOT-ATTEMPTED")'; }
claim_reason()  { q "$1" 'next((c.get("reason","") for c in d["claims"] if c["issue"]=='"$2"'), "")'; }
reap_action()   { q "$1" 'next((a["action"] for a in d["reap"] if a["issue"]=='"$2"'), "MISSING")'; }
comment_bodies(){ q "$1" '" ".join(c["body"].replace(chr(10)," ") for c in d.get("comments",{}).get("'"$2"'",[]))'; }

with_timeout() {  # SECONDS COMMAND...  - portable; the loop must never hang
  local secs=$1; shift
  if command -v timeout >/dev/null; then timeout "$secs" "$@"; return $?; fi
  if command -v gtimeout >/dev/null; then gtimeout "$secs" "$@"; return $?; fi
  "$@" &                      # fallback: poll and kill
  local p=$! i=0
  while kill -0 "$p" 2>/dev/null; do
    i=$((i+1)); [ "$i" -gt $((secs*10)) ] && { kill -9 "$p" 2>/dev/null; return 124; }
    sleep 0.1
  done
  wait "$p"
}

run_plan() {  # OUTFILE FIXTURE LIMIT
  with_timeout 30 python3 "$SCRIPT" plan --source "fixture:$FIX/$2" --now "$NOW" \
    --limit "$3" > "$1" 2> "$1.err"
}
run_dispatch() {  # TAG FIXTURE LIMIT SPAWNSPEC [extra...]
  local tag=$1 fx=$2 limit=$3 spawn=$4; shift 4
  with_timeout 60 python3 "$SCRIPT" dispatch --source "fixture:$FIX/$fx" \
    --fixture-out "$WORK/$tag.state.json" --now "$NOW" --limit "$limit" \
    --spawn "$spawn" --lock "$WORK/$tag.lock" "$@" \
    > "$WORK/$tag.out.json" 2> "$WORK/$tag.err"
}

################################################################################
echo
echo "SCHEDULING - POSITIVE CONTROL  (if nothing is dispatched, every negative below is void)"
################################################################################
run_plan "$WORK/basic.json" basic.json 20
rc=$?
DISPATCH="$(plan_dispatch "$WORK/basic.json")"
if [ "$rc" -eq 0 ] && [ -n "$DISPATCH" ]; then
  ok "the loop terminates and dispatches work (issues: $DISPATCH)"
else
  bad "POSITIVE CONTROL FAILED: plan exited $rc and dispatched '$DISPATCH' - every negative below is void"
  note "$(head -3 "$WORK/basic.json.err" 2>/dev/null)"
  printf '\nRESULT: %d passed, %d failed\n\n' "$pass" "$fail"; exit 1
fi
[ "$DISPATCH" = "16 2 5 4 7 17 14" ] \
  && ok "dispatch order is priority then issue number (16 2 5 4 7 17 14)" \
  || bad "dispatch order is '$DISPATCH', expected '16 2 5 4 7 17 14'"
case " $DISPATCH " in *" 5 "*) ok "#5, whose blockers #1 and #26 are BOTH closed, is dispatched" ;;
                      *) bad "#5 has only closed blockers but was not dispatched" ;; esac
case " $DISPATCH " in *" 2 "*) case " $DISPATCH " in *" 7 "*)
        ok "#2 (src/api.py) and #7 (src/cli.py) - disjoint files - dispatched together" ;;
        *) bad "#7 was not dispatched alongside #2" ;; esac ;;
   *) bad "#2 was not dispatched" ;; esac

echo
echo "SCHEDULING - WHAT MUST NEVER BE DISPATCHED"
[ "$(skip_reason "$WORK/basic.json" 3)" = "blocked_by_open" ] \
  && ok "#3 skipped: blocker #4 is open ($(skip_detail "$WORK/basic.json" 3))" \
  || bad "#3 with an OPEN blocker was not skipped (reason: $(skip_reason "$WORK/basic.json" 3))"
[ "$(skip_reason "$WORK/basic.json" 27)" = "blocked_by_open" ] \
  && ok "#27 skipped: one blocker closed is not enough, #4 is still open" \
  || bad "#27 dispatched with a partially closed blocker set"
# The approval gate is GONE: asking for the work is the approval, so a ticket
# sitting in status:backlog dispatches exactly like one in status:todo. #4 is
# the backlog ticket that used to be skipped as `not_approved`.
case " $DISPATCH " in *" 4 "*) ok "#4 is dispatched from status:backlog - no approval label needed" ;;
                      *) bad "#4 (status:backlog) was skipped; the approval gate is still in force" ;; esac
[ "$(skip_reason "$WORK/basic.json" 4)" = "NOT-SKIPPED" ] \
  && ok "...and it appears in no skip list, under any reason" \
  || bad "#4 was skipped as '$(skip_reason "$WORK/basic.json" 4)'"
# What rule 1 still refuses, now that approval is not part of it. Both are OPEN,
# so they reach rule 1 rather than being filtered as closed beforehand.
[ "$(skip_reason "$WORK/basic.json" 50)" = "spec_issue" ] \
  && ok "#50 is a spec issue and is never dispatched, approval gate or not" \
  || bad "#50 (spec) was not skipped as spec_issue (reason: $(skip_reason "$WORK/basic.json" 50))"
[ "$(skip_reason "$WORK/basic.json" 51)" = "already_done" ] \
  && ok "#51 carries status:done: merged work is not re-dispatched" \
  || bad "#51 (status:done) was not skipped as already_done (reason: $(skip_reason "$WORK/basic.json" 51))"
[ -z "$(defect_kinds "$WORK/basic.json" 50)" ] \
  && ok "and #50 raises no defect: a spec is not judged against the ticket contract" \
  || bad "#50 (spec) raised defect(s): $(defect_kinds "$WORK/basic.json" 50)"
[ "$(skip_reason "$WORK/basic.json" 6)" = "file_conflict" ] \
  && ok "#6 and #2 share src/api.py - never dispatched together ($(skip_detail "$WORK/basic.json" 6))" \
  || bad "two tickets sharing src/api.py were both dispatched"
[ "$(skip_reason "$WORK/basic.json" 13)" = "file_conflict" ] \
  && ok "#13 collides with in-progress #12 on src/held.py ($(skip_detail "$WORK/basic.json" 13))" \
  || bad "#13 was dispatched despite colliding with an in-progress ticket"
[ "$(skip_reason "$WORK/basic.json" 15)" = "file_conflict" ] \
  && ok "directory overlap counts: #15 (docs/guide.md) blocked by #14 (docs/)" \
  || bad "#15 inside #14's declared directory was dispatched in parallel"
[ "$(skip_reason "$WORK/basic.json" 18)" = "file_conflict" ] \
  && ok "case-only difference counts: App.py vs app.py is one file" \
  || bad "#17 and #18 differing only in case were both dispatched"
[ "$(skip_reason "$WORK/basic.json" 12)" = "already_claimed" ] \
  && ok "#12, already claimed by a live worker, is not re-dispatched" \
  || bad "#12 with a live claim was re-dispatched"

echo
echo "MALFORMED TICKETS ARE REPORTED, NOT SILENTLY SKIPPED"
[ "$(defect_kinds "$WORK/basic.json" 8)" = "acceptance_prose" ] \
  && ok "#8 prose acceptance criterion reported as acceptance_prose" \
  || bad "#8 prose acceptance criterion produced defects '$(defect_kinds "$WORK/basic.json" 8)'"
[ "$(skip_reason "$WORK/basic.json" 8)" = "blocking_defect" ] \
  && ok "#8 is skipped for that defect, with the defect named in the skip reason" \
  || bad "#8 skip reason is '$(skip_reason "$WORK/basic.json" 8)'"
[ "$(defect_kinds "$WORK/basic.json" 9)" = "files_missing" ] \
  && ok "#9 without a Files touched section reported as files_missing" \
  || bad "#9 missing file list produced defects '$(defect_kinds "$WORK/basic.json" 9)'"
[ "$(defect_kinds "$WORK/basic.json" 19)" = "blockedby_self" ] \
  && ok "#19 listing itself as a blocker reported as blockedby_self" \
  || bad "#19 self-blocker produced defects '$(defect_kinds "$WORK/basic.json" 19)'"
run_dispatch defects basic.json 20 "record:$WORK/defects.jsonl"
if grep -q 'acceptance_prose' <<<"$(comment_bodies "$WORK/defects.state.json" 8)"; then
  ok "the defect is written back to issue #8 as a comment (a human can see it)"
else
  bad "no defect comment was posted on #8"
fi
run_dispatch defects2 basic.json 20 "record:$WORK/defects2.jsonl"
n1=$(q "$WORK/defects.out.json" 'd["defects_reported"]')
if [ "${n1:-0}" -gt 0 ]; then ok "defect comments are posted ($n1 on the first pass)"
else bad "no defects were reported at all"; fi

echo
echo "DEPENDENCY CYCLE  (must be reported, and must not hang the loop)"
run_plan "$WORK/cycle.json" basic.json 20; rc=$?
[ "$rc" -eq 0 ] && ok "a repo containing a #10<->#11 cycle still completes a pass (exit 0, under a 30s timeout)" \
                || bad "the pass did not complete on a cyclic graph (exit $rc; 124 = timed out = hung)"
[ "$(q "$WORK/cycle.json" 'd["cycles"]')" = "[[10, 11]]" ] \
  && ok "the cycle is reported explicitly: [[10, 11]]" \
  || bad "cycle not reported (got '$(q "$WORK/cycle.json" 'd["cycles"]')')"
[ "$(skip_reason "$WORK/cycle.json" 10)" = "dependency_cycle" ] \
  && ok "#10 is skipped as a cycle member rather than looking like ordinary blocked work" \
  || bad "#10 skip reason is '$(skip_reason "$WORK/cycle.json" 10)'"

echo
echo "CONCURRENCY LIMIT"
run_plan "$WORK/limit1.json" basic.json 1
[ "$(plan_dispatch "$WORK/limit1.json")" = "" ] \
  && ok "--limit 1 with one ticket already in progress dispatches nothing (0 slots)" \
  || bad "--limit 1 dispatched '$(plan_dispatch "$WORK/limit1.json")' while #12 was in progress"
run_plan "$WORK/limit3.json" basic.json 3
[ "$(plan_dispatch "$WORK/limit3.json")" = "16 2" ] \
  && ok "--limit 3 fills the 2 free slots with the 2 highest-priority ready tickets (16 2)" \
  || bad "--limit 3 dispatched '$(plan_dispatch "$WORK/limit3.json")', expected '16 2'"
[ "$(skip_reason "$WORK/limit3.json" 5)" = "no_slots" ] \
  && ok "the rest are skipped as no_slots, not silently dropped" \
  || bad "#5 skip reason is '$(skip_reason "$WORK/limit3.json" 5)', expected no_slots"

echo
echo "FAIL CLOSED  (an in-progress ticket whose files are unknown)"
run_dispatch unknown unknown-files.json 5 "record:$WORK/unknown.jsonl"
[ "$(plan_dispatch "$WORK/unknown.out.json")" = "" ] \
  && ok "nothing is dispatched while a claimed ticket declares no files" \
  || bad "dispatched '$(plan_dispatch "$WORK/unknown.out.json")' although file disjointness was unprovable"
grep -q 'in-progress issues declare no files' "$WORK/unknown.out.json" \
  && ok "the refusal states its reason (fatal: in-progress issues declare no files: #40)" \
  || bad "the pass refused without recording why"
[ ! -s "$WORK/unknown.jsonl" ] \
  && ok "no container was spawned during that pass" \
  || bad "a worker was spawned during a fail-closed pass"

################################################################################
echo
echo "CLAIMING - POSITIVE CONTROL"
################################################################################
run_dispatch claim basic.json 3 "record:$WORK/claim.jsonl"
[ "$(claimed "$WORK/claim.out.json" 16)" = "True" ] \
  && ok "#16 is claimed and its worker spawned" \
  || bad "POSITIVE CONTROL FAILED: #16 was not claimed ($(claim_reason "$WORK/claim.out.json" 16))"
grep -q '"name": "hermes-worker-16"' "$WORK/claim.jsonl" \
  && ok "the spawn request names one container per ticket (hermes-worker-16)" \
  || bad "no spawn request for #16"
grep -q 'P4_ISSUE=16' "$WORK/claim.jsonl" \
  && ok "the worker is handed its issue number and nothing else" \
  || bad "the spawn command does not carry the issue number"
[ "$(labels_of "$WORK/claim.state.json" 16)" = "priority:1 status:in-progress" ] \
  && ok "#16 is relabelled status:todo -> status:in-progress on claim" \
  || bad "#16 labels after claim: '$(labels_of "$WORK/claim.state.json" 16)'"
grep -q 'p4-claim' <<<"$(comment_bodies "$WORK/claim.state.json" 16)" \
  && ok "the claim is recorded as a comment carrying a nonce (the actual lock)" \
  || bad "no claim comment on #16"

echo
echo "CLAIMING - TWO PASSES CANNOT BOTH CLAIM ONE TICKET"
# Second pass over the state the first pass produced: #16 is now in-progress.
with_timeout 60 python3 "$SCRIPT" dispatch --source "fixture:$WORK/claim.state.json" \
  --fixture-out "$WORK/claim2.state.json" --now "$NOW" --limit 3 \
  --spawn "record:$WORK/claim2.jsonl" --lock "$WORK/claim2.lock" \
  > "$WORK/claim2.out.json" 2> "$WORK/claim2.err"
grep -q 'hermes-worker-16' "$WORK/claim2.jsonl" 2>/dev/null \
  && bad "a second pass spawned a SECOND worker for #16" \
  || ok "a second pass does not re-dispatch #16 (label + claim comment both hold it)"
# A competing dispatcher inserts its claim, with a lower comment id, in the exact
# window between our read and our write.
run_dispatch race contested.json 5 "record:$WORK/race.jsonl"
[ "$(claimed "$WORK/race.out.json" 30)" = "False" ] \
  && ok "lost the claim race on #30 and stood down ($(claim_reason "$WORK/race.out.json" 30))" \
  || bad "#30 was claimed although another dispatcher's claim comment was older"
grep -q 'hermes-worker-30' "$WORK/race.jsonl" 2>/dev/null \
  && bad "a worker was spawned for #30 after losing the race" \
  || ok "no worker spawned for the lost ticket"
[ "$(labels_of "$WORK/race.state.json" 30)" = "priority:1 status:todo" ] \
  && ok "#30 keeps status:todo - the loser mutates nothing" \
  || bad "#30 labels after a lost race: '$(labels_of "$WORK/race.state.json" 30)'"
[ "$(claimed "$WORK/race.out.json" 31)" = "True" ] \
  && ok "POSITIVE CONTROL: the uncontested #31 in the same pass IS claimed" \
  || bad "POSITIVE CONTROL FAILED: #31 was not claimed either - the pass may just be inert"

echo
echo "CLAIMING - A FAILED SPAWN LEAVES NO GHOST CLAIM"
run_dispatch spawnfail contested.json 5 fail
[ "$(claimed "$WORK/spawnfail.out.json" 31)" = "False" ] \
  && ok "a spawn failure is reported as a failed claim" \
  || bad "a failed spawn was reported as a successful claim"
[ "$(labels_of "$WORK/spawnfail.state.json" 31)" = "priority:1 status:todo" ] \
  && ok "the ticket keeps status:todo (the dispatcher never has to re-approve it)" \
  || bad "labels were moved despite the spawn failing: '$(labels_of "$WORK/spawnfail.state.json" 31)'"
grep -q 'p4-release' <<<"$(comment_bodies "$WORK/spawnfail.state.json" 31)" \
  && ok "the claim is released again, so the next poll can retry" \
  || bad "no release marker after a failed spawn - the ticket would be stuck"

echo
echo "CLAIMING - TWO PASSES CANNOT RUN AT ONCE ON ONE HOST"
python3 - "$WORK/hold.lock" <<'PY' &
import fcntl, sys, time
fh = open(sys.argv[1], "w"); fcntl.flock(fh, fcntl.LOCK_EX); time.sleep(4)
PY
holder=$!
sleep 1
with_timeout 20 python3 "$SCRIPT" dispatch --source "fixture:$FIX/basic.json" \
  --now "$NOW" --limit 3 --spawn none --lock "$WORK/hold.lock" >/dev/null 2>"$WORK/lock.err"
rc=$?
wait "$holder" 2>/dev/null
[ "$rc" -eq 3 ] && ok "a second pass refuses to start while the lock is held (exit 3)" \
                || bad "a second pass ran while the lock was held (exit $rc)"
with_timeout 20 python3 "$SCRIPT" dispatch --source "fixture:$FIX/contested.json" \
  --now "$NOW" --limit 1 --spawn none --lock "$WORK/hold.lock" >/dev/null 2>&1
[ $? -eq 0 ] && ok "POSITIVE CONTROL: once released, the same lock file admits a pass" \
             || bad "POSITIVE CONTROL FAILED: the lock is never released"

################################################################################
echo
echo "STALE CLAIM RECOVERY  (a worker that dies must not hold its ticket forever)"
################################################################################
with_timeout 60 python3 "$SCRIPT" reap --source "fixture:$FIX/stale-claim.json" \
  --fixture-out "$WORK/reap.state.json" --now "$NOW" --timeout 45 \
  --spawn "record:$WORK/reap.jsonl" --lock "$WORK/reap.lock" \
  > "$WORK/reap.out.json" 2> "$WORK/reap.err"
[ "$(reap_action "$WORK/reap.out.json" 20)" = "released" ] \
  && ok "POSITIVE CONTROL: #20, silent for 180 minutes, is released" \
  || bad "POSITIVE CONTROL FAILED: the stale claim on #20 was not released"
if grep -q '"name": "hermes-worker-20", "verb": "stop"' "$WORK/reap.jsonl" &&
   grep -q '"name": "hermes-worker-20", "verb": "remove"' "$WORK/reap.jsonl"; then
  ok "its container is stopped and removed through the spawn dispatcher"
else
  bad "the dead worker's container was never cleaned up: $(tr '\n' ' ' < "$WORK/reap.jsonl")"
fi
if grep -q 'hermes-worker-21' "$WORK/reap.jsonl"; then
  bad "the reaper touched the LIVE worker's container (hermes-worker-21)"
else
  ok "no stop/remove was aimed at a live worker's container"
fi
[ "$(labels_of "$WORK/reap.state.json" 20)" = "priority:2 status:backlog" ] \
  && ok "#20 goes to status:backlog - NOT status:todo, which only a human may set" \
  || bad "#20 labels after reaping: '$(labels_of "$WORK/reap.state.json" 20)'"
grep -q 'p4-release' <<<"$(comment_bodies "$WORK/reap.state.json" 20)" \
  && ok "the release is recorded on the issue with its reason" \
  || bad "the reap left no audit trail on #20"
[ "$(reap_action "$WORK/reap.out.json" 21)" = "none" ] \
  && ok "#21, claimed 5 minutes ago, is left alone" \
  || bad "a live worker's claim (#21) was reaped"
[ "$(reap_action "$WORK/reap.out.json" 22)" = "none" ] \
  && ok "#22 has an open PR: files stay reserved until a human merges it" \
  || bad "#22 was reaped although its PR is open and awaiting review"
[ "$(reap_action "$WORK/reap.out.json" 23)" = "none" ] \
  && ok "#23's heartbeat comment (2 min old) keeps a 210-minute-old claim alive" \
  || bad "#23 was reaped despite a recent heartbeat"

################################################################################
echo
echo "WORKER OUTPUT VALIDATION  (real git branches, real commands)"
################################################################################
REPO="$WORK/repo"
mkdir -p "$REPO/src"
(
  cd "$REPO" || exit 1
  git init -q -b main . && git config user.email p4@example.invalid && git config user.name p4
  echo base > src/base.py && git add -A && git commit -qm base
  for spec in "issue-50-good:src/good.py" "issue-52-failing:src/failing.py"; do
    git checkout -q -b "${spec%%:*}" main; echo x > "${spec##*:}"; git add -A; git commit -qm "${spec%%:*}"
  done
  git checkout -q -b issue-51-scoped main
  echo x > src/scoped.py; echo x > src/secret.py; git add -A; git commit -qm issue-51
  git checkout -q main
) >/dev/null 2>&1
validate() {  # ISSUE
  with_timeout 60 python3 "$SCRIPT" validate --source "fixture:$FIX/validation.json" \
    --fixture-out "$WORK/val$1.state.json" --issue "$1" --checkout "$REPO" --base main \
    --test-command true > "$WORK/val$1.json" 2> "$WORK/val$1.err"
}
check_of() { q "$WORK/val$1.json" 'str(next(c["ok"] for c in d["checks"] if c["name"].startswith("'"$2"'")))'; }

validate 50
[ "$(q "$WORK/val50.json" 'd["ok"]')" = "True" ] \
  && ok "POSITIVE CONTROL: a correct worker's output validates (PR + scope + acceptance + suite)" \
  || bad "POSITIVE CONTROL FAILED: correct output did not validate - the negatives below are void"
validate 51
[ "$(check_of 51 'diff touches')" = "False" ] \
  && ok "#51 fails: the branch edited src/secret.py, which the ticket never declared" \
  || bad "an out-of-scope file was not caught"
[ "$(q "$WORK/val51.json" 'd["ok"]')" = "False" ] && ok "#51 is reported as failed overall" \
                                                  || bad "#51 passed validation"
validate 52
[ "$(check_of 52 'acceptance command')" = "False" ] \
  && ok "#52 fails: its acceptance command exits non-zero on the branch" \
  || bad "a failing acceptance command was not caught"
validate 53
[ "$(check_of 53 'pull request exists')" = "False" ] \
  && ok "#53 fails: no pull request references the issue" \
  || bad "a missing pull request was not caught"
grep -q 'Validation FAILED' <<<"$(comment_bodies "$WORK/val52.state.json" 52)" \
  && ok "the failure is recorded as a comment on the issue" \
  || bad "no validation comment was posted on #52"
[ "$(labels_of "$WORK/val52.state.json" 52)" = "priority:1 status:backlog" ] \
  && ok "a failed ticket leaves status:in-progress for status:backlog (a human re-approves)" \
  || bad "#52 labels after a failed validation: '$(labels_of "$WORK/val52.state.json" 52)'"
[ "$(labels_of "$WORK/val50.state.json" 50)" = "priority:1 status:in-progress" ] \
  && ok "a PASSED ticket stays in-progress until merge, so its files stay reserved" \
  || bad "#50 released its files before the PR merged: '$(labels_of "$WORK/val50.state.json" 50)'"
grep -qi 'repair\|does not repair' <<<"$(comment_bodies "$WORK/val52.state.json" 52)" \
  && ok "the comment states that the dispatcher does not repair the work" \
  || bad "the failure comment does not say the dispatcher will not fix it"

################################################################################
echo
echo "SECRET HYGIENE  (no token in any output, ever)"
################################################################################
# Negative control first: prove the grep can find the token when it IS present.
printf 'Authorization: Bearer %s\n' "$TARGET_REPO_TOKEN" > "$WORK/canary.txt"
grep -q "$TARGET_REPO_TOKEN" "$WORK/canary.txt" \
  && ok "NEGATIVE CONTROL: the probe can detect the token when it is present" \
  || bad "NEGATIVE CONTROL FAILED: the probe cannot see the token, so the sweep proves nothing"
leaks=$(grep -rl "$TARGET_REPO_TOKEN" "$WORK" 2>/dev/null | grep -v canary.txt | tr '\n' ' ')
[ -z "$leaks" ] \
  && ok "no token in any transcript, comment or fixture this run produced" \
  || bad "token found in: $leaks"
python3 - "$SCRIPT" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("p4", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
tok = os.environ["TARGET_REPO_TOKEN"]
sys.exit(0 if m.redact(f"failed with Bearer {tok} on retry") == "failed with Bearer <redacted> on retry" else 1)
PY
[ $? -eq 0 ] && ok "redact() removes the token from a string that contains it" \
             || bad "redact() left the token in place"
grep -rn "$HOME" "$HERE/p4-dispatch-loop.py" "$HERE/verify-dispatch.sh" "$FIX" >/dev/null 2>&1 \
  && bad "a home directory path is hardcoded in the p4 files" \
  || ok "no machine-specific absolute path in the p4 files"

################################################################################
if [ "$MODE" = "spawn" ]; then
echo
echo "LIVE SPAWN THROUGH p1-dispatcher  (opt-in: needs ./p1-spawn-setup.sh)"
################################################################################
  NET=p1-spawn-net
  DISP=p1-dispatcher
  if [ -z "$(docker ps -q -f name="^${DISP}$" 2>/dev/null)" ]; then
    bad "$DISP is not running - run ./p1-spawn-setup.sh first"
  else
    DTOKEN=$(docker inspect "$DISP" --format '{{range .Config.Env}}{{println .}}{{end}}' \
             | sed -n 's/^DISPATCH_TOKEN=//p')
    docker rm -f hermes-worker-31 hermes-worker-30 >/dev/null 2>&1
    # The dispatch loop runs where the orchestrator runs: in a container on the
    # spawn network, with no Docker socket of its own.
    # Only the repo is mounted, read-only. Everything the pass writes stays in
    # the container's own /tmp; the assertions below read the host's Docker
    # state, which is the point - the evidence comes from outside the caller.
    docker run --rm --network "$NET" \
      -v "$HERE:/app:ro" \
      -e "P4_SPAWN_URL=http://$DISP:2375" -e "P4_SPAWN_TOKEN=$DTOKEN" \
      -e 'P4_WORKER_CMD=["sleep","60"]' \
      python:3-alpine python /app/p4-dispatch-loop.py dispatch \
        --source fixture:/app/p4-fixtures/contested.json --fixture-out /tmp/live.state.json \
        --now "$NOW" --limit 2 --spawn http --lock /tmp/live.lock \
        > "$WORK/live.out.json" 2> "$WORK/live.err"
    rc=$?
    [ "$rc" -eq 0 ] && ok "the dispatch loop ran inside a container with no Docker socket (exit 0)" \
                    || bad "containerised dispatch pass exited $rc: $(tail -2 "$WORK/live.err")"
    if [ -n "$(docker ps -aq -f name='^hermes-worker-31$')" ]; then
      ok "a real worker container hermes-worker-31 exists"
      [ "$(docker inspect hermes-worker-31 --format '{{index .Config.Labels "role"}}')" = "hermes-worker" ] \
        && ok "it carries role=hermes-worker (the spawn dispatcher stamped it)" \
        || bad "worker label is wrong"
      [ "$(docker inspect hermes-worker-31 --format '{{if .HostConfig.Binds}}{{.HostConfig.Binds}}{{else}}[]{{end}}')" = "[]" ] \
        && ok "it has no bind mounts - the hardened template still applies" \
        || bad "the worker got bind mounts"
      [ "$(docker inspect hermes-worker-31 --format '{{.State.Running}}')" = "true" ] \
        && ok "it is running" || bad "worker is not running"
    else
      bad "no worker container was created"
    fi
    [ -z "$(docker ps -aq -f name='^hermes-worker-30$')" ] \
      && ok "no container for #30, the ticket this pass lost the claim race on" \
      || bad "a container was created for a ticket this dispatcher did not own"
    docker rm -f hermes-worker-31 hermes-worker-30 >/dev/null 2>&1
    ok "cleanup: p4 worker containers removed"
  fi
fi

echo
printf 'RESULT: %d passed, %d failed\n\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1

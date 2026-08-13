#!/usr/bin/env bash
# Verification of the PARALLEL RUN (TECH-105), in the same style as the other
# verify-*.sh: PASS/FAIL lines, a positive control in every suite, and a
# non-zero exit if anything fails.
#
#   ./verify-parallel.sh            # replay the captured run + the live fixtures
#   ./verify-parallel.sh live       # + re-query the three pull requests on GitHub
#   ./verify-parallel.sh mutate     # + break path_conflict and require this to go RED
#
# Two halves, and the difference between them is the point.
#
# The REPLAY half re-derives the concurrency claim from raw captured artefacts in
# p6-evidence/ - container start/finish timestamps, a once-a-second `docker ps`
# sample, the pull requests' own file lists. It reads no sentence anyone wrote.
# It exists because "three workers ran concurrently" was claimed twice during
# Phase 1 and was false both times: three containers had run, ~18 and ~57 minutes
# apart, and the report said otherwise. A harness that computes the intersection
# of the intervals cannot make that mistake, and it goes red if the evidence is
# ever replaced by evidence that does not support the claim.
#
# The LIVE half re-proves the mechanism from nothing: it runs the real dispatch
# loop against two fixtures that differ by a single declared path, and requires
# the colliding one to be refused and the disjoint one to be dispatched. No
# credentials, no network.
#
# Neither half is sufficient alone. Replay cannot show the check still works;
# fixtures cannot show it ever arbitrated a real race. Suite D closes that gap
# with the refusal the LIVE REPOSITORY produced mid-run, while a worker genuinely
# held the contested file.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SCRIPT="${P6_SCRIPT:-$HERE/p4-dispatch-loop.py}"
FIX="$HERE/p6-fixtures"
EV="$HERE/p6-evidence"
NOW="2026-01-01T12:00:00Z"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/p6-verify.XXXXXX")"
MODE="${1:-replay}"

TS="$EV/05-container-timestamps.txt"
ISO="$EV/08-container-isolation.json"
POLL="$EV/02-docker-ps-poll.tsv"
PR="$EV/06-pull-requests.json"
MERGE="$EV/07-three-way-merge.txt"
LIVEPLAN="$EV/04-plan-during-run.json"

# No real credential is needed for anything except `live`, and none belongs in
# this file. The placeholder is recognisable so a leak would be obvious.
export TARGET_REPO_TOKEN="${TARGET_REPO_TOKEN:-p6-fake-token-4Kd8-never-log-me}"
export TARGET_REPO="${TARGET_REPO:-example/target}"

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
note() { printf '        %s\n' "$1"; }
cleanup() { rm -rf "$WORK" "$HERE/__pycache__"; }
trap cleanup EXIT

# --- helpers -----------------------------------------------------------------
# Every helper prints "OK" or a reason. A crashed helper prints its traceback
# rather than nothing, so a broken check reads as a FAIL and never as a PASS.
verdict() {  # LABEL  <output-of-a-helper>
  if [ "$2" = "OK" ]; then ok "$1"; else bad "$1"; note "${2:-(the check produced no output)}"; fi
}
verdict_msg() {  # LABEL-PREFIX  <output-of-a-helper, "OK <detail>" or a reason>
  case "$2" in
    OK*) ok "$1${2#OK}" ;;
    *)   bad "$1"; note "${2:-(the check produced no output)}" ;;
  esac
}

cat > "$WORK/evidence.py" <<'PYEOF'
"""Assertions over the captured run. One check per argv[1]; prints OK or why not."""
import datetime
import itertools
import json
import sys

check, paths = sys.argv[1], sys.argv[2:]


def load(p):
    with open(p) as fh:
        return json.load(fh)


def parse_ts(t):
    """Docker's RFC3339 carries nanoseconds; datetime stops at microseconds."""
    t = t.replace("Z", "+00:00")
    head, _, rest = t.partition(".")
    if rest:
        frac, sign, tz = rest.partition("+")
        t = head + "." + frac[:6] + sign + tz
    return datetime.datetime.fromisoformat(t)


def containers():
    return load(paths[0])


if check == "count":
    names = {c["name"] for c in containers()}
    print("OK" if len(names) == 3 else "found %d distinct containers: %s" % (len(names), sorted(names)))

elif check == "overlap":
    cs = containers()
    lo = max(parse_ts(c["started_at"]) for c in cs)
    hi = min(parse_ts(c["finished_at"]) for c in cs)
    secs = round((hi - lo).total_seconds(), 1)
    if secs > 0:
        print("OK: %ss with all %d alive, %s -> %s" % (secs, len(cs), lo.time(), hi.time()))
    else:
        span = ["%s %s..%s" % (c["name"], parse_ts(c["started_at"]).time(), parse_ts(c["finished_at"]).time())
                for c in cs]
        print("intervals do NOT intersect (%ss); this is a SEQUENTIAL run: %s" % (secs, "; ".join(span)))

elif check == "exits":
    codes = {c["name"]: c["exit_code"] for c in containers()}
    oom = [c["name"] for c in containers() if c["oom_killed"]]
    if set(codes.values()) == {0} and not oom:
        print("OK")
    else:
        print("exit codes %s, OOM-killed %s" % (codes, oom or "none"))

elif check == "poll":
    best = cur = 0
    with open(paths[0]) as fh:
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            cur = cur + 1 if len(parts) > 1 and parts[1] == "3" else 0
            best = max(best, cur)
    print("OK: %d consecutive samples" % best if best else
          "the sample never shows three workers at once")

elif check == "isolation":
    # (label, predicate) - every worker must satisfy every one of these.
    rules = [
        ("its own /work tmpfs, sized under its memory cap",
         lambda c: c["tmpfs"].get("/work", "").startswith("size=384m")),
        ("no bind mounts - there is no shared path to race on",
         lambda c: not c["binds"] and not c["mounts"]),
        ("read-only rootfs, ALL caps dropped, no-new-privileges, unprivileged",
         lambda c: c["readonly_rootfs"] and c["cap_drop"] == ["ALL"]
         and "no-new-privileges" in c["security_opt"] and not c["privileged"]),
        ("private IPC and PID namespaces - no worker sees another's processes",
         lambda c: c["ipc_mode"] in ("private", "shareable") and c["pid_mode"] == ""),
        ("a NON-ZERO memory and pid cap (an unset compose key inspects as 0, meaning no limit)",
         lambda c: c["memory"] > 0 and c["pids_limit"] > 0),
        ("role=hermes-worker, which is what scopes the dispatcher's stop/remove",
         lambda c: c["labels"].get("role") == "hermes-worker"
         and c["labels"].get("managed-by") == "p1-dispatcher"),
        ("on the isolated network only - egress is the proxy or nothing",
         lambda c: c["networks"] == ["hermes-isolated"]),
    ]
    want = paths[1]
    for label, pred in rules:
        if label != want:
            continue
        offenders = [c["name"] for c in containers() if not pred(c)]
        print("OK" if not offenders else "offenders: " + ", ".join(offenders))
        break
    else:
        print("no such rule: %r" % want)

elif check == "rules":
    print("\n".join(label for label, _ in [
        ("its own /work tmpfs, sized under its memory cap", None),
        ("no bind mounts - there is no shared path to race on", None),
        ("read-only rootfs, ALL caps dropped, no-new-privileges, unprivileged", None),
        ("private IPC and PID namespaces - no worker sees another's processes", None),
        ("a NON-ZERO memory and pid cap (an unset compose key inspects as 0, meaning no limit)", None),
        ("role=hermes-worker, which is what scopes the dispatcher's stop/remove", None),
        ("on the isolated network only - egress is the proxy or nothing", None),
    ]))

elif check == "pr_count":
    pulls = load(paths[0])["pulls"]
    print("OK" if len(pulls) == 3 else "found %d pull requests" % len(pulls))

elif check == "pr_branches":
    pulls = load(paths[0])["pulls"]
    heads = {p["head"] for p in pulls}
    print("OK: " + ", ".join(sorted(heads)) if len(heads) == len(pulls)
          else "branches are shared: %s" % sorted(heads))

elif check == "pr_base":
    pulls = load(paths[0])["pulls"]
    bases, shas = {p["base"] for p in pulls}, {p["merge_base_sha"] for p in pulls}
    print("OK: all from %s@%s" % (bases.pop(), shas.pop()[:7]) if len(bases) == 1 and len(shas) == 1
          else "bases %s, base commits %s - not one parallel wave" % (bases, {s[:7] for s in shas}))

elif check == "pr_scope":
    out = []
    for p in load(paths[0])["pulls"]:
        extra = sorted(set(p["changed_files"]) - set(p["declared_files"]))
        if extra:
            out.append("#%s changed undeclared %s" % (p["issue"], extra))
    print("OK" if not out else "; ".join(out))

elif check == "pr_disjoint":
    out = []
    for a, b in itertools.combinations(load(paths[0])["pulls"], 2):
        both = sorted(set(a["changed_files"]) & set(b["changed_files"]))
        if both:
            out.append("#%s and #%s both changed %s" % (a["issue"], b["issue"], both))
    print("OK" if not out else "; ".join(out))

elif check == "plan_dispatch":
    print(" ".join(str(x["issue"]) for x in load(paths[0])["dispatch"]))

elif check == "plan_skip":
    want = int(paths[1])
    s = next((s for s in load(paths[0])["skipped"] if s["issue"] == want), None)
    print("NOT-SKIPPED" if s is None else "%s|%s" % (s["reason"], s["detail"]))

elif check == "plan_held":
    print(json.dumps(load(paths[0])["concurrency"]["held_issues"]))

else:
    sys.exit("unknown check %r" % check)
PYEOF

ev() { python3 "$WORK/evidence.py" "$@" 2>&1; }

################################################################################
echo
echo "A. THE RUN - three workers alive at the same instant"
echo "   Derived from container timestamps, never from an agent's account of itself."
################################################################################

if [ -s "$TS" ] && [ -s "$ISO" ] && [ -s "$POLL" ]; then
  ok "the captured run exists (positive control: without it every assertion below is void)"
else
  bad "POSITIVE CONTROL FAILED: an artefact under p6-evidence/ is missing or empty"
  note "expected $TS, $ISO, $POLL"
fi

verdict     "three distinct worker containers were recorded" "$(ev count "$ISO")"
verdict_msg "their [start, finish] intervals intersect" "$(ev overlap "$ISO")"
verdict     "all three exited 0 and none was OOM-killed - three workers WORKING, not three crashing together" "$(ev exits "$ISO")"
verdict_msg "an independent once-a-second docker ps sample saw all three at once" "$(ev poll "$POLL")"

################################################################################
echo
echo "B. NO CROSS-AGENT COLLISION - three branches, three diffs, nothing shared"
################################################################################

if [ "$MODE" = "live" ]; then
  if [ "$TARGET_REPO_TOKEN" = "p6-fake-token-4Kd8-never-log-me" ]; then
    bad "live mode needs a real TARGET_REPO_TOKEN; source local.env first"
  else
    cat > "$WORK/requery.py" <<'PYEOF'
import json, os, subprocess, sys
repo = os.environ["TARGET_REPO"]
base = json.load(open(sys.argv[1]))
def gh(path):
    return json.loads(subprocess.check_output(["gh", "api", path]))
for entry in base["pulls"]:
    n = entry["pull"]
    pull = gh("repos/%s/pulls/%s" % (repo, n))
    entry["head"] = pull["head"]["ref"]
    entry["base"] = pull["base"]["ref"]
    entry["head_sha"] = pull["head"]["sha"]
    entry["merge_base_sha"] = pull["base"]["sha"]
    entry["changed_files"] = sorted(f["filename"] for f in gh("repos/%s/pulls/%s/files" % (repo, n)))
print(json.dumps(base, indent=2))
PYEOF
    if GH_TOKEN="$TARGET_REPO_TOKEN" python3 "$WORK/requery.py" "$PR" > "$WORK/live-pr.json" 2>"$WORK/requery.err"; then
      PR="$WORK/live-pr.json"
      ok "re-queried all three pull requests from GitHub instead of replaying the capture"
    else
      bad "could not re-query the pull requests: $(head -1 "$WORK/requery.err")"
    fi
  fi
fi

verdict     "three pull requests were opened, one per ticket" "$(ev pr_count "$PR")"
verdict_msg "on three distinct branches - no worker pushed onto another's" "$(ev pr_branches "$PR")"
verdict_msg "all three branch from one commit - they really did start together" "$(ev pr_base "$PR")"
verdict     "every changed file is one its ticket declared - no diff escaped its file list" "$(ev pr_scope "$PR")"
verdict     "no file appears in two pull requests - the collision the design exists to prevent did not happen" "$(ev pr_disjoint "$PR")"

# Path-level disjointness is necessary and not sufficient: two branches can touch
# different files and still be incompatible. The merge is the check that sees
# that, which is why this suite does not stop at set arithmetic.
if grep -q "no conflict" "$MERGE" 2>/dev/null && ! grep -qiE "conflict in|merge failed" "$MERGE" 2>/dev/null; then
  ok "the three branches merge into one tree with no conflict"
else
  bad "the recorded three-way merge did not come out clean ($MERGE)"
fi
if grep -qE "^16 passed" "$MERGE" 2>/dev/null && grep -qE "^34 passed" "$MERGE" 2>/dev/null; then
  ok "and the suite on the merged tree passes, 16 -> 34 tests"
else
  bad "the suite on the merged tree is not recorded as passing ($MERGE)"
fi

################################################################################
echo
echo "C. STRUCTURAL ISOLATION - why a worker cannot reach another's workspace"
################################################################################

while IFS= read -r rule; do
  [ -n "$rule" ] || continue
  verdict "each worker: $rule" "$(ev isolation "$ISO" "$rule")"
done <<< "$(ev rules "$ISO")"

################################################################################
echo
echo "D. THE COLLISION CHECK ARBITRATES - fixtures, then the live repository"
################################################################################

run_plan() {  # OUTFILE FIXTURE LIMIT
  python3 "$SCRIPT" plan --source "fixture:$FIX/$2" --now "$NOW" --limit "$3" \
    > "$1" 2> "$1.err"
}

# Positive control FIRST. disjoint.json differs from collision.json by exactly
# one declared path; if all three do not dispatch here, the refusal below proves
# nothing about file overlap.
run_plan "$WORK/disjoint.json" disjoint.json 3
D_ALL="$(ev plan_dispatch "$WORK/disjoint.json")"
if [ "$D_ALL" = "60 61 62" ]; then
  ok "POSITIVE CONTROL: with disjoint paths all three dispatch (60 61 62)"
else
  bad "POSITIVE CONTROL FAILED: the disjoint fixture dispatched '$D_ALL', expected '60 61 62'"
  note "$(head -3 "$WORK/disjoint.json.err" 2>/dev/null)"
fi

run_plan "$WORK/collision.json" collision.json 3
C_ALL="$(ev plan_dispatch "$WORK/collision.json")"
if [ "$C_ALL" = "60 61" ]; then
  ok "change one path to collide and only 60 and 61 dispatch - the second claimant is held back"
else
  bad "the collision fixture dispatched '$C_ALL', expected '60 61'"
  note "$(head -3 "$WORK/collision.json.err" 2>/dev/null)"
fi

S62="$(ev plan_skip "$WORK/collision.json" 62)"
case "$S62" in
  file_conflict\|*"#61"*src/shared.py*)
    ok "#62 is skipped for file_conflict, naming the ticket and the exact path: ${S62#*|}" ;;
  file_conflict\|*)
    bad "#62 is refused for file_conflict but the reason names no path: ${S62#*|}" ;;
  *)
    bad "#62 was skipped as '${S62%%|*}', expected 'file_conflict'" ;;
esac

# A slot cap would also have stopped #62 if the limit were 2, and that is a
# different property. Prove the refusal survives an unlimited slot budget.
run_plan "$WORK/collision-99.json" collision.json 99
S99="$(ev plan_skip "$WORK/collision-99.json" 62)"
if [ "${S99%%|*}" = "file_conflict" ]; then
  ok "the refusal is the file rule, not the concurrency limit - it holds at --limit 99"
else
  bad "with slots to spare #62 was no longer refused ('${S99%%|*}'); the rule under test may be the slot cap"
fi

# The fixtures prove the check works. This proves it arbitrated a real race:
# captured mid-run against the live repository, with three workers alive.
L29="$(ev plan_skip "$LIVEPLAN" 29)"
L_HELD="$(ev plan_held "$LIVEPLAN")"
if [ "${L29%%|*}" = "file_conflict" ] && [ "$L_HELD" = "[26, 27, 28]" ]; then
  ok "on the LIVE repository, mid-run with $L_HELD held, #29 was refused: ${L29#*|}"
else
  bad "the captured live pass does not show the refusal (reason '${L29%%|*}', held '$L_HELD')"
fi

################################################################################
if [ "$MODE" = "mutate" ]; then
echo
echo "E. MUTATION CONTROL - break the check and require this harness to notice"
################################################################################
  MUT="$WORK/mutant.py"
  sed 's|^    a, b = a.casefold(), b.casefold()$|    return False  # MUTATION: path_conflict disabled|' \
    "$HERE/p4-dispatch-loop.py" > "$MUT"
  if ! diff -q "$MUT" "$HERE/p4-dispatch-loop.py" >/dev/null 2>&1; then
    ok "path_conflict disabled in a throwaway copy (the committed file is untouched)"
  else
    bad "the mutation did not apply - path_conflict's body has changed shape; update the sed"
  fi
  P6_SCRIPT="$MUT" "$0" replay > "$WORK/mutant.out" 2>&1
  if grep -q "FAIL" "$WORK/mutant.out"; then
    ok "the mutant run goes RED - suite D is capable of catching a collision"
    note "$(grep -c FAIL "$WORK/mutant.out") failing checks; first: $(grep -m1 FAIL "$WORK/mutant.out" | sed 's/^ *[^ ]*FAIL[^ ]* *//')"
  else
    bad "the mutant run still passed - suite D would NOT catch a real collision"
  fi
fi

################################################################################
echo
printf 'RESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1

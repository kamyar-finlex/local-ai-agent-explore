#!/usr/bin/env bash
# Install this repo's Hermes skills into the agent's data directory.
#
#   ./install-skills.sh
#
# The agent reads skills from its own data directory, which is a host bind mount
# and is deliberately NOT part of this repository -- it holds the agent's memory
# and sessions. So the skills live here, under version control, and are copied
# into place. Re-run after editing one.
#
# Copying rather than symlinking on purpose: the container sees the data
# directory through a bind mount, and a symlink pointing outside it would dangle
# inside the container.

set -euo pipefail
HERE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[ -f "$HERE_DIR/local.env" ] && . "$HERE_DIR/local.env"

SRC="$HERE_DIR/hermes-skills"
DEST="${HERMES_DATA:-$HOME/.hermes}/skills"

[ -d "$SRC" ]  || { echo "no hermes-skills/ directory here" >&2; exit 1; }
[ -d "$DEST" ] || { echo "agent skills directory not found: $DEST" >&2; exit 1; }

# ---- One source of truth per script -----------------------------------------
# A skill carries its scripts inside its own directory, and the same programs
# also live at the repo root, where the harnesses point at them. That is two
# copies of a 62 KB file kept in step by hand, and it does not stay in step:
# p4-dispatch-loop.py was edited at the root, verified there, installed from
# here - and the agent went on running the previous version. The symptom was a
# reap that reported a reason string the new code cannot produce.
#
# So the ROOT file is canonical and this script copies it over the skill's copy
# before installing, out loud. `verify-dispatch.sh` asserts the same equality,
# so drift fails a harness run even when nobody installs anything.
CANONICAL="
p4-dispatch-loop.py:orchestrator-dispatch
p3-plan.py:orchestrator-planner
"
while IFS=: read -r script skill; do
  [ -n "$script" ] || continue
  root="$HERE_DIR/$script"
  copy="$SRC/autonomous-ai-agents/$skill/scripts/$script"
  [ -f "$root" ] && [ -f "$copy" ] || continue
  if cmp -s "$root" "$copy"; then
    echo "  in sync    $script"
  else
    cp "$root" "$copy"
    echo "  SYNCED     $script  (the skill copy was stale; the root file wins)"
  fi
done <<EOF
$CANONICAL
EOF
echo

installed=0
# Skills are grouped one level deep (category/skill-name/SKILL.md), matching the
# layout the agent's bundled skills already use.
while IFS= read -r skill; do
  rel="${skill#"$SRC"/}"
  target="$DEST/$rel"
  mkdir -p "$(dirname "$target")"
  rm -rf "$target"
  cp -R "$skill" "$target"
  echo "  installed  $rel"
  installed=$((installed+1))
done < <(find "$SRC" -mindepth 2 -maxdepth 2 -type d)

echo
echo "$installed skill(s) into $DEST"

# ---- Toolset restriction ----------------------------------------------------
# The agent ships 18 toolsets enabled. The planner needs terminal, file and
# skills; todo and memory are harmless and useful. Every other toolset costs
# twice over:
#
#   1. Context. Tool definitions consumed ~23% of a 65,536-token window before
#      any work began, on a model that has little to spare.
#   2. Wrong turns. Given a browser and a web search, a small model reaches for
#      them instead of the command the skill prescribes. `file` is dropped for a
#      sharper reason: its write_file is how the planner started writing the
#      application itself -- __init__.py, an app module, a test -- into the
#      agent's own data directory, where the code is useless and the tickets it
#      then wrote described work already done. The planner reads exactly one
#      file, plan/readme.md, and `cat` through terminal does that. Observed: it tried to
#      read a GitHub issue through browser automation, then through `curl | jq`
#      (no jq installed, exit 127), and concluded from that the network was
#      blocked -- while a one-line script call would have fetched it.
#
# Removing the option is more reliable than instructing against it. This is the
# same lesson as the write_file allowlist: a prohibition a tool can still reach
# around is a guardrail, not a control.
KEEP="terminal skills todo memory"
DROP="web browser file code_execution vision image_gen bfl tts computer_use delegation cronjob session_search clarify"

if docker ps --format '{{.Names}}' | grep -qx hermes; then
  docker exec hermes hermes tools disable $DROP >/dev/null 2>&1 \
    && echo "restricted toolsets to: $KEEP" \
    || echo "could not restrict toolsets (is the agent running?)" >&2
else
  echo "agent not running - restrict toolsets later with:"
  echo "  docker exec hermes hermes tools disable $DROP"
fi

echo
echo "Restart the agent so it rescans:  docker compose restart hermes"

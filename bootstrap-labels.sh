#!/usr/bin/env bash
# Create the labels the orchestrator contract depends on, in the target repository.
#
#   TARGET_REPO=owner/name ./bootstrap-labels.sh
#
# Idempotent: existing labels are updated rather than duplicated.
#
# These must exist before the first planning run. The planner applies
# status:backlog and a priority to every issue it creates, and a label it cannot
# apply produces a planning failure that looks like a permissions error.

set -euo pipefail
HERE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[ -f "$HERE_DIR/local.env" ] && . "$HERE_DIR/local.env"

REPO="${TARGET_REPO:-}"
[ -n "$REPO" ] || { echo "TARGET_REPO is not set (put it in local.env)" >&2; exit 1; }
command -v gh >/dev/null || { echo "gh CLI not found" >&2; exit 1; }

# name|colour|description
LABELS="
spec|5319e7|A specification for the planner to decompose. Human-applied.
status:backlog|ededed|Awaiting human approval. Never dispatched.
status:todo|0e8a16|Approved by a human. Eligible for dispatch.
status:in-progress|fbca04|Claimed by a worker.
status:blocked|b60205|Has at least one open Blocked-by dependency.
status:done|6f42c1|Pull request merged.
priority:1|b60205|Highest.
priority:2|d93f0b|High.
priority:3|fbca04|Medium.
priority:4|c2e0c6|Low.
poc-test|bfd4f2|Created during an experiment run. Safe to bulk-close.
"

created=0; updated=0; failed=0
while IFS='|' read -r name colour desc; do
  [ -n "${name:-}" ] || continue
  if gh label create "$name" --repo "$REPO" --color "$colour" --description "$desc" >/dev/null 2>&1; then
    echo "  created  $name"; created=$((created+1))
  elif gh label edit "$name" --repo "$REPO" --color "$colour" --description "$desc" >/dev/null 2>&1; then
    echo "  updated  $name"; updated=$((updated+1))
  else
    echo "  FAILED   $name" >&2; failed=$((failed+1))
  fi
done <<EOF
$(printf '%s\n' "$LABELS" | grep -v '^[[:space:]]*$')
EOF

echo
echo "$created created, $updated updated, $failed failed in $REPO"
echo "Verify:  gh label list --repo $REPO"
[ "$failed" -eq 0 ] || exit 1

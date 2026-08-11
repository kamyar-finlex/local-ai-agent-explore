#!/usr/bin/env bash
# Remove everything the spawning PoC created. Namespaced by the `p1-` prefix, so
# this cannot touch hermes, ollama-gate, or the hermes-isolated network.
#
#   ./p1-spawn-teardown.sh

set -uo pipefail
NET=p1-spawn-net

echo "removing p1-* containers..."
# Every container this rig creates is p1-*: the proxy, the dispatcher, the
# bystander, and any worker (p1-worker-*, p1-attack-*) left behind by a run.
ids=$(docker ps -aq --filter 'name=^/p1-' 2>/dev/null)
[ -n "$ids" ] && docker rm -f $ids >/dev/null 2>&1 || true

# Belt and braces: anything still carrying our worker label.
wids=$(docker ps -aq --filter 'label=role=hermes-worker' 2>/dev/null)
[ -n "$wids" ] && docker rm -f $wids >/dev/null 2>&1 || true

echo "removing network $NET..."
docker network rm "$NET" >/dev/null 2>&1 || true

echo "done. Remaining p1-* (should be none):"
docker ps -a --filter 'name=^/p1-' --format '  {{.Names}} ({{.Status}})' || true

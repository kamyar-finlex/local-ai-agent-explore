#!/usr/bin/env bash
# Launch Hermes Agent sandboxed: no internet, no LAN, no host services except the
# local model API via the gate.
#
#   ./run-hermes.sh [args passed through to the agent]
#
# Deliberately absent: -v /var/run/docker.sock. Mounting the Docker socket hands
# the agent root on the host and voids every boundary below.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NETWORK=hermes-isolated
GATE=ollama-gate
NAME=hermes

# The agent's persistent data directory on the host. Override with HERMES_DATA.
DATA="${HERMES_DATA:-$HOME/.hermes}"

fail() { echo "REFUSING TO LAUNCH: $1" >&2; exit 1; }

# ---- Preflight: refuse to launch if the cage is not actually closed ----------
# A sandbox that silently degrades is worse than no sandbox, because it is
# trusted. Assert the boundary every time rather than assuming setup persisted.

[ -d "$DATA" ] || fail "data directory $DATA does not exist."

[ "$(docker network inspect "$NETWORK" --format '{{.Internal}}' 2>/dev/null)" = "true" ] \
  || fail "$NETWORK is missing or not --internal; the agent would have egress. Run ./setup-sandbox.sh"

[ -n "$(docker ps -q -f name="^${GATE}$")" ] \
  || fail "$GATE is not running. Run ./setup-sandbox.sh"

probe() { # method path -> http status, from inside the isolated network
  docker run --rm --network "$NETWORK" curlimages/curl:latest \
    -s -m 10 -o /dev/null -w '%{http_code}' -X "$1" "http://${GATE}:11434$2" -d '{}' 2>/dev/null | tail -1
}
[ "$(probe POST /api/pull)" = "403" ] \
  || fail "gate allows /api/pull - an indirect internet egress. Check ollama-gate.conf."
[ "$(probe GET /api/tags)" = "200" ] \
  || fail "gate cannot reach the model; the agent would start with nothing to talk to."

# A previous run not started with --rm leaves a stopped container holding the
# name. Clear that, but never touch a RUNNING one - that would kill a live session.
if [ -n "$(docker ps -aq -f name="^${NAME}$")" ]; then
  if [ -n "$(docker ps -q -f name="^${NAME}$")" ]; then
    fail "a container named '$NAME' is already RUNNING. Attach with 'docker attach $NAME', or stop it first."
  fi
  docker rm "$NAME" >/dev/null 2>&1 || true
  echo "cleared a stopped leftover container named '$NAME'."
fi

# A --memory value larger than the Docker VM's own RAM is not a limit at all: the
# container can consume the whole VM before the cgroup ever binds. On Docker
# Desktop the VM is often far smaller than the host (measured here: 36 GB host,
# 7.65 GiB VM), so size the cap against the VM and say so out loud.
VM_MEM_MB=$(docker info --format '{{.MemTotal}}' 2>/dev/null | awk '{printf "%d", $1/1048576}')
MEM_LIMIT="${MEM_LIMIT:-}"
if [ -z "$MEM_LIMIT" ]; then
  if [ -n "$VM_MEM_MB" ] && [ "$VM_MEM_MB" -gt 0 ] 2>/dev/null; then
    # Leave ~25% of the VM for the gate, any workers, and the daemon itself.
    MEM_LIMIT="$(( VM_MEM_MB * 75 / 100 ))m"
  else
    MEM_LIMIT="4g"
  fi
fi
echo "memory cap: $MEM_LIMIT (Docker VM total: ${VM_MEM_MB:-unknown} MiB) - override with MEM_LIMIT=..."

echo "preflight OK: network internal, gate up, egress paths blocked, model reachable."

exec docker run -it --rm \
  --name "$NAME" \
  --network "$NETWORK" \
  --cap-drop ALL \
  --cap-add CHOWN --cap-add SETUID --cap-add SETGID \
  --cap-add DAC_OVERRIDE --cap-add FOWNER \
  --security-opt no-new-privileges \
  --memory "$MEM_LIMIT" \
  --cpus 4 \
  --pids-limit 512 \
  --tmpfs /tmp:size=1g \
  -v "$DATA:/opt/data" \
  -v "$DATA/hooks:/opt/data/hooks:ro" \
  nousresearch/hermes-agent "$@"

# Capability note: bare --cap-drop ALL BREAKS this image. s6-overlay drops
# privileges during init and dies with
#   s6-applyuidgid: fatal: unable to set supplementary group list
# The five caps above are the minimum s6 needs. Critically none is NET_ADMIN, so
# the container still cannot install a route out of the --internal network.
#
# Never add: --cap-add NET_ADMIN, --privileged, -v /var/run/docker.sock,
# --network bridge, --yolo, or --accept-hooks. Each voids a boundary above.

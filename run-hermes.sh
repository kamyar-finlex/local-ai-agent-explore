#!/usr/bin/env bash
# Bring the composed stack up and attach to the orchestrator.
#
#   ./run-hermes.sh            # up + attach
#   ./run-hermes.sh --no-attach
#
# The topology now lives in docker-compose.yml. This wrapper exists for the two
# things a compose file cannot do by itself:
#
#   1. Source local.env, which is gitignored and holds machine-specific values
#      (DISPATCH_TOKEN, EXTRA_PORTS, HERMES_DATA). Keeping them out of the repo
#      is what makes captured output safe to publish without scrubbing.
#   2. Size the orchestrator's memory cap against the LIVE Docker VM. A cap
#      larger than the VM is not a cap at all - the container exhausts the VM
#      before the cgroup ever binds - and compose has no way to read
#      `docker info`. The compose default is a static floor; this raises it to
#      fit the machine it is actually running on.
#
# The preflight assertions that used to live here are now the `preflight`
# service, which the orchestrator `depends_on: service_completed_successfully`.
# That is strictly better: it cannot be skipped by starting the stack some other
# way, and it tests reachability from inside the cage rather than inspecting
# configuration from outside it.
#
# Deliberately absent, here and in docker-compose.yml: any Docker socket mount
# on the orchestrator. Mounting it hands the agent root on the host and voids
# every boundary. Spawning goes through the dispatcher instead.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

ATTACH=1
[ "${1:-}" = "--no-attach" ] && ATTACH=0

command -v docker >/dev/null || { echo "docker not found" >&2; exit 1; }

# shellcheck source=/dev/null
if [ -f "$HERE/local.env" ]; then
  set -a; . "$HERE/local.env"; set +a
else
  echo "no local.env found - copy local.env.example to local.env first" >&2
  exit 1
fi

[ -n "${DISPATCH_TOKEN:-}" ] || {
  echo "DISPATCH_TOKEN is not set in local.env; the spawn dispatcher refuses to start without one." >&2
  exit 1
}

export HERMES_DATA="${HERMES_DATA:-$HOME/.hermes}"
[ -d "$HERMES_DATA" ] || { echo "data directory $HERMES_DATA does not exist." >&2; exit 1; }

# Size the cap against the VM, not the host. On Docker Desktop the VM is often
# far smaller than the machine (measured here: 7.65 GiB VM). Leave room for the
# two gateways, the dispatcher and three 512 MiB workers - about 2 GiB - plus
# whatever else this VM is already hosting.
if [ -z "${HERMES_MEM_LIMIT:-}" ]; then
  VM_MEM_MB=$(docker info --format '{{.MemTotal}}' 2>/dev/null | awk '{printf "%d", $1/1048576}')
  if [ -n "$VM_MEM_MB" ] && [ "$VM_MEM_MB" -gt 3072 ] 2>/dev/null; then
    # VM, minus the rest of the stack's committed caps, minus 25% for the daemon
    # and anything else running in the VM.
    export HERMES_MEM_LIMIT="$(( (VM_MEM_MB - 2016) * 75 / 100 ))m"
  else
    export HERMES_MEM_LIMIT="2g"
  fi
  echo "orchestrator memory cap: $HERMES_MEM_LIMIT (Docker VM total: ${VM_MEM_MB:-unknown} MiB) - override with HERMES_MEM_LIMIT=..."
fi

# The worker image must exist before the dispatcher can spawn anything, and
# nothing else builds it.
docker image inspect "${WORKER_IMAGE:-hermes-worker:latest}" >/dev/null 2>&1 \
  || docker compose --profile images build worker-image

echo "bringing the stack up (preflight will refuse if the cage is not closed)..."
docker compose up -d

docker compose ps

if [ "$ATTACH" = "1" ]; then
  echo
  echo "starting an agent session - leave it with /exit, stop the stack with 'docker compose down'"
  # `docker attach` is wrong for this image under compose. Started detached, the
  # entrypoint runs its gateway and parks the main service on `sleep infinity`,
  # so attaching connects to a sleeping process and shows a dead terminal. Worse,
  # typing /exit in a previous session leaves the container Up and healthy with
  # no agent inside it - the stack looks fine and cannot be talked to.
  #
  # Exec-ing a fresh agent gives a real TTY every time, and leaving a session
  # ends only that session rather than emptying the container.
  exec docker compose exec hermes hermes --skills orchestrator-planner
fi

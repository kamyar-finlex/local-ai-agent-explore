#!/usr/bin/env bash
# TECH-98 prototype rig: bring up BOTH candidate spawning mechanisms side by side
# so verify-spawning.sh can measure them against the same adversarial battery.
#
#   ./p1-spawn-setup.sh
#
# Everything created here is namespaced with a `p1-` prefix and removed by
# ./p1-spawn-teardown.sh. This rig does NOT touch hermes, ollama-gate, or the
# hermes-isolated network.
#
#   (a) p1-socket-proxy  - tecnativa/docker-socket-proxy, granted the MINIMUM
#                          surface to spawn workers: CONTAINERS=1, POST=1.
#                          This is the off-the-shelf "safe" option under test.
#   (d) p1-dispatcher    - the thin body-validating dispatcher (p1-dispatcher.py).
#
# Both own the Docker socket. The orchestrator (simulated by throwaway curl
# containers in verify-spawning.sh) only ever gets NETWORK access to them - never
# the socket.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NET=p1-spawn-net
PROXY=p1-socket-proxy
DISP=p1-dispatcher

command -v docker >/dev/null || { echo "docker not found" >&2; exit 1; }

# A dedicated bridge network for the rig. Not --internal: the subject here is the
# spawn CONTROL interface, not network egress (that boundary is the other PoC).
if ! docker network inspect "$NET" >/dev/null 2>&1; then
  docker network create "$NET" >/dev/null
  echo "created network $NET"
else
  echo "network $NET already exists"
fi

docker rm -f "$PROXY" "$DISP" >/dev/null 2>&1 || true

# --- (a) the path-filtering socket proxy -------------------------------------
# CONTAINERS=1 + POST=1 is the smallest grant that lets a caller create/start/
# stop/remove workers. Everything else stays at its secure-by-default 0.
docker run -d --name "$PROXY" \
  --network "$NET" \
  --restart unless-stopped \
  --memory 64m --cpus 0.5 --pids-limit 64 \
  --security-opt no-new-privileges \
  -e CONTAINERS=1 -e POST=1 \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  tecnativa/docker-socket-proxy:latest >/dev/null
echo "up: $PROXY (tecnativa/docker-socket-proxy, CONTAINERS=1 POST=1)"

# --- (d) the body-validating dispatcher --------------------------------------
# Token is a PoC placeholder, same spirit as the repo's api_key=ollama. In a
# real deployment this would be injected from a secret, not hard-set here.
TOKEN="${DISPATCH_TOKEN:-p1-demo-token-$(date +%s)}"
docker run -d --name "$DISP" \
  --network "$NET" \
  --restart unless-stopped \
  --memory 96m --cpus 0.5 --pids-limit 64 \
  --security-opt no-new-privileges \
  -e DISPATCH_TOKEN="$TOKEN" \
  -e WORKER_IMAGE=alpine:latest \
  -e WORKER_LABEL_KEY=role -e WORKER_LABEL_VALUE=hermes-worker \
  -e WORKER_NETWORK="$NET" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$HERE/p1-dispatcher.py:/app/dispatcher.py:ro" \
  python:3-alpine python /app/dispatcher.py >/dev/null
echo "up: $DISP (body-validating dispatcher, token in its env)"

# A deliberately UNRELATED, unlabelled bystander. verify-spawning.sh uses it as
# the "container without the worker label" target. It stands in for hermes so the
# destructive tests never point at the real hermes container.
docker rm -f p1-bystander >/dev/null 2>&1 || true
docker run -d --name p1-bystander --network "$NET" \
  --label role=innocent-bystander \
  alpine:latest sleep 3600 >/dev/null
echo "up: p1-bystander (unlabelled non-worker; stop/remove target for the negative tests)"

# Wait for the dispatcher's HTTP listener.
for _ in $(seq 1 20); do
  if docker run --rm --network "$NET" curlimages/curl:latest \
       -s -m 3 -o /dev/null "http://$DISP:2375/healthz" 2>/dev/null; then
    break
  fi
  sleep 0.5
done

echo
echo "rig up. Now:"
echo "  ./verify-spawning.sh proxy       # option (a) - expected to FAIL"
echo "  ./verify-spawning.sh dispatcher  # option (d) - expected to PASS"
echo "  ./p1-spawn-teardown.sh           # remove everything p1-*"

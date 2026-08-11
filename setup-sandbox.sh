#!/usr/bin/env bash
# Create the sandbox: an --internal network with no egress, plus a dual-homed
# nginx gate that exposes ONLY the local model API into it.
#
#   ./setup-sandbox.sh
#
# Idempotent - safe to re-run. Re-run after editing ollama-gate.conf.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NETWORK=hermes-isolated
GATE=ollama-gate

command -v docker >/dev/null || { echo "docker not found" >&2; exit 1; }

# --internal means: no gateway, no route out, no outbound DNS. This is the
# boundary; everything else is defence in depth.
if [ "$(docker network inspect "$NETWORK" --format '{{.Internal}}' 2>/dev/null)" = "true" ]; then
  echo "network $NETWORK already exists (internal)"
else
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
  docker network create --internal "$NETWORK" >/dev/null
  echo "created network $NETWORK (internal, no egress)"
fi

docker rm -f "$GATE" >/dev/null 2>&1 || true

# Start on bridge FIRST so nginx can resolve host.docker.internal at boot; a
# proxy_pass to an unresolvable name makes nginx refuse to start.
docker run -d --name "$GATE" \
  --network bridge \
  --restart unless-stopped \
  --memory 128m --cpus 0.5 --pids-limit 64 \
  --security-opt no-new-privileges \
  --sysctl net.ipv4.ip_forward=0 \
  --read-only \
  --tmpfs /var/cache/nginx:size=16m \
  --tmpfs /var/run:size=1m \
  --tmpfs /tmp:size=8m \
  --cap-drop ALL \
  --cap-add CHOWN --cap-add SETUID --cap-add SETGID --cap-add DAC_OVERRIDE \
  -v "$HERE/ollama-gate.conf:/etc/nginx/conf.d/default.conf:ro" \
  nginx:alpine >/dev/null

docker network connect "$NETWORK" "$GATE"

echo "gate $GATE up on both networks:"
docker inspect "$GATE" --format '{{range $k,$v := .NetworkSettings.Networks}}  - {{$k}}
{{end}}'

if err=$(docker logs "$GATE" 2>&1 | grep -iE 'emerg|\[error\]' | head -3) && [ -n "$err" ]; then
  echo "nginx reported errors:" >&2
  echo "$err" >&2
  exit 1
fi

echo
echo "Now run ./verify-sandbox.sh to confirm the boundary holds."

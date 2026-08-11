#!/usr/bin/env bash
# Create the domain-allowlisted egress sandbox: an --internal network with no
# route out, a squid CONNECT proxy as the ONLY hole, and -- separately -- the
# unchanged local-model gate.
#
#   ./setup-egress.sh            # build it
#   ./setup-egress.sh teardown   # remove every p2-* resource it created
#
# Idempotent. Re-run after editing egress-proxy.conf or egress-allowed-domains.txt.
#
# Everything is namespaced p2-* so it can live beside the model-only sandbox
# (hermes-isolated / ollama-gate) without touching it.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NETWORK=p2-egress-isolated
PROXY=p2-egress-proxy
GATE=p2-model-gate
AGENT=p2-agent
IMAGE=p2-probe:latest
PROXY_IMAGE=p2-squid:latest
GENDIR=/tmp/p2-egress-generated

if [ "${1:-}" = "teardown" ]; then
  docker rm -f "$AGENT" "$PROXY" "$GATE" >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
  docker rmi "$IMAGE" "$PROXY_IMAGE" >/dev/null 2>&1 || true
  rm -rf "$GENDIR"
  echo "torn down: $AGENT $PROXY $GATE, network $NETWORK, images $IMAGE $PROXY_IMAGE"
  exit 0
fi

command -v docker >/dev/null || { echo "docker not found" >&2; exit 1; }

# 1. The boundary. --internal means no gateway: nothing on this network can
#    route anywhere, with or without proxy environment variables.
if [ "$(docker network inspect "$NETWORK" --format '{{.Internal}}' 2>/dev/null)" = "true" ]; then
  echo "network $NETWORK already exists (internal)"
else
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
  docker network create --internal "$NETWORK" >/dev/null
  echo "created network $NETWORK (internal, no egress)"
fi
SUBNET=$(docker network inspect "$NETWORK" --format '{{(index .IPAM.Config 0).Subnet}}')

# 2. squid listens on 0.0.0.0, so pin the client ACL to this network's subnet --
#    otherwise every container on the default bridge gets a free proxy.
mkdir -p "$GENDIR"
printf 'acl agent_net src %s\n' "$SUBNET" > "$GENDIR/agent-net.conf"
echo "restricted proxy clients to $SUBNET"

# 3. Images: the proxy, and a worker stand-in with git + curl + python3.
docker build -q -t "$PROXY_IMAGE" -f "$HERE/egress-proxy.Dockerfile" "$HERE" >/dev/null
docker build -q -t "$IMAGE"       -f "$HERE/egress-probe.Dockerfile" "$HERE" >/dev/null
echo "built $PROXY_IMAGE and $IMAGE"

docker rm -f "$PROXY" "$GATE" "$AGENT" >/dev/null 2>&1 || true

# 4. The egress proxy. Dual-homed by necessity, so it is the hardened component:
#    read-only rootfs, no capabilities beyond privilege-dropping, ip_forward=0 so
#    it cannot route for anyone who somehow acquires NET_ADMIN.
#    Bridge first: squid resolves nothing at boot, but it needs working DNS.
docker run -d --name "$PROXY" \
  --network bridge \
  --restart unless-stopped \
  --memory 192m --cpus 0.5 --pids-limit 128 \
  --security-opt no-new-privileges \
  --sysctl net.ipv4.ip_forward=0 \
  --read-only \
  --tmpfs /var/cache/squid:size=16m,mode=1777 \
  --tmpfs /var/log/squid:size=8m,mode=1777 \
  --tmpfs /var/run:size=1m,mode=1777 \
  --cap-drop ALL \
  --cap-add CHOWN --cap-add SETUID --cap-add SETGID --cap-add DAC_OVERRIDE \
  -v "$HERE/egress-proxy.conf:/etc/squid/squid.conf:ro" \
  -v "$HERE/egress-allowed-domains.txt:/etc/squid/allowed-domains.txt:ro" \
  -v "$GENDIR/agent-net.conf:/etc/squid/agent-net.conf:ro" \
  "$PROXY_IMAGE" >/dev/null
docker network connect "$NETWORK" "$PROXY"

# 5. The model gate, byte-identical config to the model-only sandbox. Separate
#    container, separate port, separate concern: path allowlist for plaintext
#    HTTP to the local model, domain allowlist for HTTPS to the internet.
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

# 6. The confined worker. Internal network only, no capabilities, and the proxy
#    variables the well-behaved case uses. NO_PROXY keeps model traffic off the
#    egress proxy -- it would be denied there, since it is not a CONNECT tunnel.
docker run -d --name "$AGENT" \
  --network "$NETWORK" \
  --memory 512m --cpus 1 --pids-limit 256 \
  --security-opt no-new-privileges \
  --cap-drop ALL \
  -e HTTPS_PROXY="http://$PROXY:3128" \
  -e https_proxy="http://$PROXY:3128" \
  -e HTTP_PROXY="http://$PROXY:3128" \
  -e http_proxy="http://$PROXY:3128" \
  -e NO_PROXY="$GATE,localhost,127.0.0.1" \
  -e no_proxy="$GATE,localhost,127.0.0.1" \
  "$IMAGE" sleep infinity >/dev/null

# squid takes a moment to install and bind.
for _ in $(seq 1 40); do
  docker exec "$AGENT" python3 -c "
import socket,sys
s=socket.socket(); s.settimeout(2)
sys.exit(0 if s.connect_ex(('$PROXY',3128))==0 else 1)" >/dev/null 2>&1 && break
  sleep 1
done

echo
echo "topology:"
for c in "$AGENT" "$PROXY" "$GATE"; do
  printf '  %-16s %s\n' "$c" \
    "$(docker inspect "$c" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}')"
done

if err=$(docker logs "$PROXY" 2>&1 | grep -iE 'FATAL|ERROR' | head -3) && [ -n "$err" ]; then
  echo "squid reported errors:" >&2; echo "$err" >&2; exit 1
fi

echo
echo "Now run ./verify-egress.sh to confirm the allowlist holds and cannot be bypassed."

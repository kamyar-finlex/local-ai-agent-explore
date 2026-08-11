#!/usr/bin/env bash
# Host-side verification of the agent sandbox. Proves the boundary from outside,
# independently of anything the agent claims about itself -- a model asked whether
# it can reach the internet may simply say the wrong thing.
#
#   ./verify-sandbox.sh
#
# Exits non-zero if any security-relevant check fails, so it is safe to gate a
# demo or a CI job on it.
#
# Add your own host services to check with EXTRA_PORTS, e.g.
#   EXTRA_PORTS="8080 9000" ./verify-sandbox.sh

set -uo pipefail
NETWORK=hermes-isolated
GATE=ollama-gate
NAME=hermes

# Common local dev infrastructure that an escaped agent would find interesting.
DEFAULT_PORTS="27017:MongoDB 3306:MySQL 5432:PostgreSQL 6379:Redis 4566:LocalStack"

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
note() { printf '        %s\n' "$1"; }

probe() { # method path -> http status, from inside the cage
  docker run --rm --network "$NETWORK" curlimages/curl:latest \
    -s -m 10 -o /dev/null -w '%{http_code}' -X "$1" "http://${GATE}:11434$2" -d '{}' 2>/dev/null | tail -1
}
tcp() { # host port -> open|shut, from inside the cage
  docker run --rm --network "$NETWORK" alpine:latest \
    sh -c "timeout 3 nc -z $1 $2 >/dev/null 2>&1 && echo open || echo shut" 2>/dev/null | tail -1
}

echo
echo "NETWORK ISOLATION"
[ "$(docker network inspect "$NETWORK" --format '{{.Internal}}' 2>/dev/null)" = "true" ] \
  && ok "$NETWORK is --internal (no gateway, no egress)" \
  || bad "$NETWORK is NOT internal - the agent has egress"
[ "$(tcp 1.1.1.1 443)" = "shut" ] && ok "internet (HTTPS) unreachable" || bad "internet REACHABLE"
[ "$(tcp 8.8.8.8 53)"  = "shut" ] && ok "outbound DNS unreachable"     || bad "outbound DNS REACHABLE"

echo
echo "HOST SERVICES UNREACHABLE"
for entry in $DEFAULT_PORTS; do
  port=${entry%%:*}; label=${entry#*:}
  [ "$(tcp host.docker.internal "$port")" = "shut" ] \
    && ok "$label :$port unreachable" || bad "$label :$port REACHABLE from the agent"
done
for port in ${EXTRA_PORTS:-}; do
  [ "$(tcp host.docker.internal "$port")" = "shut" ] \
    && ok "host service :$port unreachable" || bad "host service :$port REACHABLE from the agent"
done

echo
echo "GATE ALLOWLIST"
for entry in "/api/pull:model download (indirect internet egress)" \
             "/api/push:model upload (exfiltration)" \
             "/api/delete:model deletion" \
             "/api/create:model creation" \
             "/nonexistent:default-deny"; do
  path=${entry%%:*}; label=${entry#*:}
  code=$(probe POST "$path")
  [ "$code" = "403" ] && ok "$label blocked (403)" || bad "$label returned $code, expected 403"
done
for entry in "/api/tags:model list" "/api/version:version"; do
  path=${entry%%:*}; label=${entry#*:}
  code=$(probe GET "$path")
  [ "$code" = "200" ] && ok "$label allowed (200)" || bad "$label returned $code, expected 200"
done

echo
echo "GATE HARDENING"
[ "$(docker exec "$GATE" cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" = "0" ] \
  && ok "gate ip_forward=0 (cannot route even if the agent gained NET_ADMIN)" \
  || bad "gate ip_forward=1 - only capability-dropping prevents tunnelling"
[ "$(docker inspect "$GATE" --format '{{.HostConfig.ReadonlyRootfs}}' 2>/dev/null)" = "true" ] \
  && ok "gate rootfs read-only" || bad "gate rootfs writable"

echo
echo "MODEL SERVER EXPOSURE"
if command -v lsof >/dev/null && lsof -nP -iTCP:11434 -sTCP:LISTEN 2>/dev/null | grep -q "127.0.0.1:11434"; then
  ok "model server bound to 127.0.0.1 only (not exposed to the LAN)"
else
  note "could not confirm a loopback-only bind on :11434 - check manually"
fi

echo
echo "MODEL FITNESS"
ctx=$(curl -s http://127.0.0.1:11434/api/ps 2>/dev/null \
      | python3 -c "import json,sys; m=json.load(sys.stdin).get('models',[]); print(m[0].get('context_length') if m else 0)" 2>/dev/null)
if [ "${ctx:-0}" -ge 64000 ] 2>/dev/null; then
  ok "served context ${ctx} meets the 64000 minimum"
elif [ "${ctx:-0}" = "0" ]; then
  note "no model loaded - send one prompt, then re-run this check"
else
  bad "served context ${ctx} is BELOW the 64000 minimum - the agent will refuse to start"
fi

echo
echo "CONTAINER PRIVILEGES"
if [ -n "$(docker ps -q -f name="^${NAME}$")" ]; then
  docker inspect "$NAME" --format '{{.HostConfig.CapAdd}}' | grep -q NET_ADMIN \
    && bad "$NAME has NET_ADMIN - it can install a route out" || ok "$NAME has no NET_ADMIN"
  [ "$(docker inspect "$NAME" --format '{{.HostConfig.Privileged}}')" = "false" ] \
    && ok "$NAME not privileged" || bad "$NAME is PRIVILEGED"
  docker inspect "$NAME" --format '{{range .Mounts}}{{.Source}} {{end}}' | grep -q "docker.sock" \
    && bad "docker.sock is MOUNTED - the agent has host root" || ok "no docker.sock mounted"
  docker inspect "$NAME" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' | grep -qw bridge \
    && bad "$NAME is on bridge - full host and internet access" || ok "$NAME only on $NETWORK"
else
  note "$NAME is not running - privilege checks skipped"
fi

echo
echo "DIRECT PROBES INSIDE THE REAL AGENT CONTAINER"
# The checks above run in throwaway containers on the same network. That is a
# valid inference (same network => same reachability, given the privilege check
# confirms which network the agent is on) but it is not a direct measurement.
# These probes execute inside the actual agent container instead.
if [ -n "$(docker ps -q -f name="^${NAME}$")" ]; then
  # Direct IP as well as a hostname: proves there is no ROUTE, not merely that
  # DNS is unavailable. A DNS-only failure would be a much weaker result.
  code=$(docker exec "$NAME" curl -s -m 8 -o /dev/null -w '%{http_code}' https://1.1.1.1 2>/dev/null)
  [ "${code:-000}" = "000" ] && ok "agent cannot reach 1.1.1.1 by direct IP (no route)" \
                             || bad "agent reached 1.1.1.1 -> HTTP $code"
  docker exec "$NAME" getent hosts example.com >/dev/null 2>&1 \
    && bad "agent CAN resolve public DNS" || ok "agent cannot resolve public DNS"

  # Port reachability, via python3 sockets rather than the shell's /dev/tcp.
  # /dev/tcp is a BASH feature; this image's sh is dash, so a /dev/tcp probe
  # fails with "Directory nonexistent" whether the port is open or not - a
  # false pass that reports containment it never measured.
  #
  # Tested against the host's real LAN IP as well as host.docker.internal, so a
  # failure is route-level (ENETUNREACH) rather than merely unresolvable DNS.
  # The gate is included as a POSITIVE CONTROL: if it does not come back
  # reachable, the probe itself is broken and the negatives mean nothing.
  HOST_IP="${HOST_IP:-$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')}"
  probe_out=$(docker exec "$NAME" python3 -c '
import socket, sys
host_ip = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] else None
targets = [("host.docker.internal", 27017, "MongoDB via host.docker.internal")]
if host_ip:
    targets += [(host_ip, 27017, "MongoDB via host LAN IP"),
                (host_ip, 3306,  "MySQL via host LAN IP"),
                (host_ip, 4566,  "LocalStack via host LAN IP")]
targets += [("ollama-gate", 11434, "CONTROL gate")]
for h, p, label in targets:
    try:
        s = socket.socket(); s.settimeout(4)
        rc = s.connect_ex((h, p)); s.close()
        print("%s|%s" % (label, "OPEN" if rc == 0 else "SHUT"))
    except Exception as e:
        print("%s|SHUT" % label)
' "$HOST_IP" 2>/dev/null)

  [ -n "$HOST_IP" ] || note "could not detect host LAN IP; set HOST_IP=... for a route-level probe"
  while IFS='|' read -r label state; do
    [ -n "$label" ] || continue
    case "$label" in
      CONTROL*)
        [ "$state" = "OPEN" ] && ok "positive control: agent CAN reach the gate (probe is working)" \
                             || bad "positive control FAILED - the probe cannot detect open ports, so the results below are void" ;;
      *)
        [ "$state" = "SHUT" ] && ok "agent cannot reach $label" \
                              || bad "agent REACHED $label" ;;
    esac
  done <<EOF
$probe_out
EOF

  code=$(docker exec "$NAME" curl -s -m 8 -o /dev/null -w '%{http_code}' \
         -X POST "http://${GATE}:11434/api/pull" -d '{"model":"llama3"}' 2>/dev/null)
  [ "$code" = "403" ] && ok "agent blocked from /api/pull (403)" \
                      || bad "agent got $code from /api/pull, expected 403"

  docker exec "$NAME" sh -c 'ls /Users' >/dev/null 2>&1 \
    && bad "host home directory /Users is VISIBLE inside the agent" \
    || ok "host home directory not present inside the agent"

  # The permitted hole must still work, or the sandbox is merely broken.
  code=$(docker exec "$NAME" curl -s -m 240 -o /dev/null -w '%{http_code}' \
         -X POST "http://${GATE}:11434/v1/chat/completions" \
         -H 'Content-Type: application/json' \
         -d '{"model":"'"${MODEL:-gpt-oss:20b-64k}"'","messages":[{"role":"user","content":"hi"}],"max_tokens":512}' 2>/dev/null)
  [ "$code" = "200" ] && ok "agent CAN reach the model through the gate (200)" \
                      || bad "agent cannot reach the model: HTTP $code"
else
  note "$NAME is not running - direct in-container probes skipped"
  note "start it with ./run-hermes.sh and re-run for the strongest result"
fi

echo
printf 'RESULT: %d passed, %d failed\n\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1

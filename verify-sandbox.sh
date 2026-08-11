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
#
# Runs against the COMPOSED stack (docker-compose.yml). The names below are the
# compose container_names; the checks themselves are unchanged from the script-
# based topology, plus a COMPOSE TRANSLATION section that asserts every property
# that used to be a `docker run` flag is still set on the running container.
# Translating a sandbox is exactly the moment a flag goes missing silently.

set -uo pipefail

# Machine-specific values live in local.env, which is gitignored. Sourcing it here
# keeps private ports and addresses out of the repo and out of captured output, so
# there is nothing to scrub before publishing.
HERE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[ -f "$HERE_DIR/local.env" ] && . "$HERE_DIR/local.env"
NETWORK="${ISOLATED_NETWORK:-hermes-isolated}"
GATE="${GATE_NAME:-ollama-gate}"
NAME="${AGENT_NAME:-hermes}"
DISPATCHER="${DISPATCHER_NAME:-hermes-dispatcher}"
PROXY="${PROXY_NAME:-hermes-egress-proxy}"

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
  # Was "not on bridge". Under compose the agent is on no bridge network at all,
  # so assert the stronger property directly: exactly one network, the internal
  # one. That also catches a second network being added later.
  agent_nets=$(docker inspect "$NAME" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}')
  if [ "$(echo "$agent_nets" | wc -w)" -eq 1 ] && echo "$agent_nets" | grep -qw "$NETWORK"; then
    ok "$NAME is on $NETWORK and nothing else"
  else
    bad "$NAME is on: $agent_nets - expected only $NETWORK"
  fi
else
  note "$NAME is not running - privilege checks skipped"
fi

echo
echo "COMPOSE TRANSLATION  (every property that used to be a docker run flag)"
# The consolidation risk is not that a boundary was argued away, it is that a
# flag silently did not survive being rewritten as YAML. Each check below names
# the flag it replaces.
if [ -n "$(docker ps -q -f name="^${NAME}$")" ]; then
  # --cap-drop ALL --cap-add CHOWN,SETUID,SETGID,DAC_OVERRIDE,FOWNER
  # Exact set, sorted: a superset is a silent privilege grant, a subset breaks
  # s6 init ("unable to set supplementary group list") and the agent never boots.
  want="CAP_CHOWN CAP_DAC_OVERRIDE CAP_FOWNER CAP_SETGID CAP_SETUID"
  got=$(docker inspect "$NAME" --format '{{range .HostConfig.CapAdd}}{{.}} {{end}}' \
        | tr ' ' '\n' | sed '/^$/d' | sort | tr '\n' ' ' | sed 's/ $//')
  [ "$(docker inspect "$NAME" --format '{{.HostConfig.CapDrop}}')" = "[ALL]" ] \
    && ok "$NAME cap_drop is exactly ALL" || bad "$NAME cap_drop is not ALL"
  [ "$got" = "$want" ] && ok "$NAME cap_add is exactly the 5 caps s6 needs ($got)" \
                       || bad "$NAME cap_add is '$got', expected '$want'"
  # --security-opt no-new-privileges
  docker inspect "$NAME" --format '{{.HostConfig.SecurityOpt}}' | grep -q 'no-new-privileges' \
    && ok "$NAME has no-new-privileges" || bad "$NAME is MISSING no-new-privileges"
  # --memory / --cpus / --pids-limit. Zero means "no limit", which is what an
  # unset compose key looks like - indistinguishable from a limit at inspect
  # time unless it is checked for being non-zero.
  m=$(docker inspect "$NAME" --format '{{.HostConfig.Memory}}')
  c=$(docker inspect "$NAME" --format '{{.HostConfig.NanoCpus}}')
  p=$(docker inspect "$NAME" --format '{{.HostConfig.PidsLimit}}')
  [ "${m:-0}" -gt 0 ] 2>/dev/null && ok "$NAME memory capped ($((m/1048576)) MiB)" || bad "$NAME has NO memory limit"
  [ "${c:-0}" -gt 0 ] 2>/dev/null && ok "$NAME cpus capped ($((c/1000000000)) cpus)" || bad "$NAME has NO cpu limit"
  [ "${p:-0}" -gt 0 ] 2>/dev/null && ok "$NAME pids capped ($p)" || bad "$NAME has NO pids limit"
  # A memory cap larger than the Docker VM itself is not a cap: the container
  # exhausts the VM before the cgroup ever binds.
  vm=$(docker info --format '{{.MemTotal}}' 2>/dev/null)
  if [ "${m:-0}" -gt 0 ] && [ "${vm:-0}" -gt 0 ] 2>/dev/null; then
    [ "$m" -lt "$vm" ] && ok "$NAME memory cap is below the Docker VM total ($((vm/1048576)) MiB)" \
                       || bad "$NAME memory cap ($((m/1048576)) MiB) >= VM total ($((vm/1048576)) MiB) - not a cap"
  fi
  # Per-container caps that each fit the VM can still not fit TOGETHER. That is
  # the failure the consolidation makes possible: five services plus three
  # workers now share one VM, where each prototype had it to itself. Worker caps
  # come from the dispatcher's own configuration, so this tracks the real
  # worst case rather than an assumption about it.
  wmem=$(docker inspect "$DISPATCHER" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
         | sed -n 's/^WORKER_MEMORY=//p' | head -1)
  wmem="${wmem:-536870912}"
  total=$m
  for svc in "$GATE" "$PROXY" "$DISPATCHER"; do
    sm=$(docker inspect "$svc" --format '{{.HostConfig.Memory}}' 2>/dev/null || echo 0)
    total=$(( total + ${sm:-0} ))
  done
  total=$(( total + 3 * wmem ))
  if [ "${vm:-0}" -gt 0 ] 2>/dev/null; then
    [ "$total" -lt "$vm" ] \
      && ok "whole stack + 3 workers commits $((total/1048576)) MiB of the VM's $((vm/1048576)) MiB" \
      || bad "committed caps total $((total/1048576)) MiB > VM $((vm/1048576)) MiB - the stack cannot all be resident"
  fi
  # --tmpfs /tmp
  docker inspect "$NAME" --format '{{.HostConfig.Tmpfs}}' | grep -q '/tmp' \
    && ok "$NAME /tmp is a tmpfs (not written into the data mount)" || bad "$NAME has no /tmp tmpfs"
  # -v "$DATA/hooks:/opt/data/hooks:ro"
  docker inspect "$NAME" --format '{{range .Mounts}}{{.Destination}}:{{.RW}} {{end}}' \
    | grep -q '/opt/data/hooks:false' \
    && ok "$NAME hooks directory mounted read-only" || bad "$NAME hooks directory is WRITABLE"
else
  note "$NAME is not running - compose translation checks skipped"
fi

# The gate and the proxy are the dual-homed components; the same flags must have
# survived for them. Their read-only/ip_forward checks are above and in
# verify-egress.sh; these are the limits.
for svc in "$GATE" "$PROXY"; do
  [ -n "$(docker ps -q -f name="^${svc}$")" ] || { note "$svc not running - skipped"; continue; }
  m=$(docker inspect "$svc" --format '{{.HostConfig.Memory}}')
  p=$(docker inspect "$svc" --format '{{.HostConfig.PidsLimit}}')
  [ "${m:-0}" -gt 0 ] 2>/dev/null && [ "${p:-0}" -gt 0 ] 2>/dev/null \
    && ok "$svc memory and pids capped ($((m/1048576)) MiB, $p pids)" \
    || bad "$svc is missing a memory or pids limit"
  docker inspect "$svc" --format '{{.HostConfig.SecurityOpt}}' | grep -q 'no-new-privileges' \
    && ok "$svc has no-new-privileges" || bad "$svc is MISSING no-new-privileges"
  docker inspect "$svc" --format '{{range .Mounts}}{{.Source}} {{end}}' | grep -q 'docker.sock' \
    && bad "$svc has the Docker socket mounted - it must not" || ok "$svc has no Docker socket"
done

echo
echo "SPAWN DISPATCHER  (owns the socket so the orchestrator never has to)"
if [ -n "$(docker ps -q -f name="^${DISPATCHER}$")" ]; then
  docker inspect "$DISPATCHER" --format '{{range .Mounts}}{{.Source}} {{end}}' | grep -q 'docker.sock' \
    && ok "$DISPATCHER holds the Docker socket (by design - it is the only one that may)" \
    || bad "$DISPATCHER has no Docker socket - it cannot spawn anything"
  d_nets=$(docker inspect "$DISPATCHER" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}')
  if [ "$(echo "$d_nets" | wc -w)" -eq 1 ] && echo "$d_nets" | grep -qw "$NETWORK"; then
    ok "$DISPATCHER is on $NETWORK only (its socket is not exposed to any routed network)"
  else
    bad "$DISPATCHER is on: $d_nets - a socket holder must not be dual-homed"
  fi
  [ "$(docker inspect "$DISPATCHER" --format '{{.HostConfig.ReadonlyRootfs}}')" = "true" ] \
    && ok "$DISPATCHER rootfs read-only" || bad "$DISPATCHER rootfs writable"
  docker inspect "$DISPATCHER" --format '{{.HostConfig.SecurityOpt}}' | grep -q 'no-new-privileges' \
    && ok "$DISPATCHER has no-new-privileges" || bad "$DISPATCHER is MISSING no-new-privileges"
  # It must not publish its port to the host: the whole point is that only the
  # isolated network can reach the verb interface.
  [ "$(docker inspect "$DISPATCHER" --format '{{len .HostConfig.PortBindings}}')" = "0" ] \
    && ok "$DISPATCHER publishes no port to the host" \
    || bad "$DISPATCHER publishes a port to the host - the socket interface is exposed"
else
  note "$DISPATCHER is not running - spawn checks skipped (see ./verify-spawning.sh)"
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
  #
  # --noproxy '*' is load-bearing now that the composed orchestrator carries
  # HTTPS_PROXY. Without it curl would go to the egress proxy, be refused there,
  # and still report 000 - the check would pass while measuring the allowlist
  # instead of the absent route. The two must stay separately verifiable.
  code=$(docker exec "$NAME" curl -s -m 8 --noproxy '*' -o /dev/null -w '%{http_code}' https://1.1.1.1 2>/dev/null)
  [ "${code:-000}" = "000" ] && ok "agent cannot reach 1.1.1.1 by direct IP (no route, proxy bypassed)" \
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
gate = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else "ollama-gate"
targets = [("host.docker.internal", 27017, "MongoDB via host.docker.internal")]
if host_ip:
    targets += [(host_ip, 27017, "MongoDB via host LAN IP"),
                (host_ip, 3306,  "MySQL via host LAN IP"),
                (host_ip, 4566,  "LocalStack via host LAN IP")]
targets += [(gate, 11434, "CONTROL gate")]
for h, p, label in targets:
    try:
        s = socket.socket(); s.settimeout(4)
        rc = s.connect_ex((h, p)); s.close()
        print("%s|%s" % (label, "OPEN" if rc == 0 else "SHUT"))
    except Exception as e:
        print("%s|SHUT" % label)
' "$HOST_IP" "$GATE" 2>/dev/null)

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

  code=$(docker exec "$NAME" curl -s -m 8 --noproxy '*' -o /dev/null -w '%{http_code}' \
         -X POST "http://${GATE}:11434/api/pull" -d '{"model":"llama3"}' 2>/dev/null)
  [ "$code" = "403" ] && ok "agent blocked from /api/pull (403)" \
                      || bad "agent got $code from /api/pull, expected 403"

  docker exec "$NAME" sh -c 'ls /Users' >/dev/null 2>&1 \
    && bad "host home directory /Users is VISIBLE inside the agent" \
    || ok "host home directory not present inside the agent"

  # The permitted hole must still work, or the sandbox is merely broken.
  code=$(docker exec "$NAME" curl -s -m 240 --noproxy '*' -o /dev/null -w '%{http_code}' \
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

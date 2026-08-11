#!/usr/bin/env bash
# Host-side verification of the domain-allowlisted egress path. Proves the
# boundary from outside the agent, and -- more importantly -- proves it cannot be
# bypassed by an agent that simply ignores the proxy environment variables.
#
#   ./verify-egress.sh
#
# Exits non-zero if any security-relevant check fails.
#
# Every negative result is paired with a positive control. A probe that reports
# "blocked" when it is merely broken is worse than no probe at all: see
# RESULTS.md section 7 for the /dev/tcp false pass this discipline caught.

set -uo pipefail

# Machine-specific values live in local.env, which is gitignored. Sourcing it here
# keeps private ports and addresses out of the repo and out of captured output, so
# there is nothing to scrub before publishing.
HERE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[ -f "$HERE_DIR/local.env" ] && . "$HERE_DIR/local.env"
NETWORK=p2-egress-isolated
PROXY=p2-egress-proxy
GATE=p2-model-gate
AGENT=p2-agent
ALLOWFILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/egress-allowed-domains.txt"

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
note() { printf '        %s\n' "$1"; }

if [ -z "$(docker ps -q -f name="^${AGENT}$")" ]; then
  echo "$AGENT is not running - run ./setup-egress.sh first" >&2; exit 1
fi

# Ask the proxy for a tunnel and report the status line it answers with. Speaking
# the proxy protocol directly, rather than through curl, keeps "the proxy refused
# with 403" distinguishable from "the connection failed" -- curl collapses both.
proxy_req() { # request-line-target [method] -> 200 | 403 | ERR
  docker exec "$AGENT" python3 -c '
import socket, sys
target, method = sys.argv[1], sys.argv[2]
try:
    s = socket.create_connection(("'"$PROXY"'", 3128), 8); s.settimeout(8)
    host = target.split("//")[-1].split("/")[0]
    s.sendall(("%s %s HTTP/1.1\r\nHost: %s\r\nProxy-Connection: close\r\n\r\n"
               % (method, target, host)).encode())
    line = s.recv(256).decode("latin1").split("\r\n")[0]
    s.close()
    print(line.split(" ")[1] if len(line.split(" ")) > 1 else "ERR")
except Exception:
    print("ERR")
' "$1" "${2:-CONNECT}" 2>/dev/null | tail -1
}

# Raw TCP reachability with the proxy ignored entirely. python3 sockets, not
# /dev/tcp: /dev/tcp is a bash feature and this image's sh is ash, so such a
# probe fails identically whether the port is open or blocked.
#
# Prints the errno with the failure -- 101 (ENETUNREACH) is the kernel saying
# there is no route, which is a stronger claim than a timeout or a DNS failure.
direct_tcp() { # host port -> OPEN | SHUT:<errno|reason>
  docker exec "$AGENT" python3 -c '
import socket, sys
try:
    s = socket.socket(); s.settimeout(5)
    rc = s.connect_ex((sys.argv[1], int(sys.argv[2]))); s.close()
    print("OPEN" if rc == 0 else "SHUT:%d" % rc)
except socket.gaierror:
    print("SHUT:dns")
except Exception as e:
    print("SHUT:%s" % type(e).__name__)
' "$1" "$2" 2>/dev/null | tail -1
}
shut() { case "$1" in SHUT*) return 0;; *) return 1;; esac; }

# One real GitHub address, resolved on the HOST so the probe below aims at a port
# that genuinely listens. A closed port is indistinguishable from a blocked one.
#
# Deliberately NOT falling back to a hardcoded literal: these addresses rotate, and
# a stale one would aim the probe at a port nobody is listening on, turning a
# meaningless timeout into a "blocked" PASS. If resolution fails, the check is
# skipped and says so - an absent check is honest, a false pass is not.
GH_IP=$(python3 -c "import socket;print(socket.gethostbyname('github.com'))" 2>/dev/null || echo "")

echo
echo "TOPOLOGY"
[ "$(docker network inspect "$NETWORK" --format '{{.Internal}}' 2>/dev/null)" = "true" ] \
  && ok "$NETWORK is --internal (no gateway, no route out, no outbound DNS)" \
  || bad "$NETWORK is NOT internal - the agent has egress regardless of the proxy"
nets=$(docker inspect "$AGENT" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}')
[ "$(echo "$nets" | wc -w)" -eq 1 ] && echo "$nets" | grep -qw "$NETWORK" \
  && ok "$AGENT is on $NETWORK only" || bad "$AGENT is on: $nets"
docker inspect "$AGENT" --format '{{.HostConfig.CapAdd}}' | grep -q NET_ADMIN \
  && bad "$AGENT has NET_ADMIN - it can install its own route out" \
  || ok "$AGENT has no NET_ADMIN (cannot install a route)"
docker inspect "$PROXY" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' \
  | grep -qw bridge && ok "$PROXY is dual-homed (the single hole, by design)" \
  || bad "$PROXY has no egress side - nothing can get out at all"

echo
echo "POSITIVE CONTROLS  (if these fail, every negative below is void)"
[ "$(direct_tcp "$PROXY" 3128)" = "OPEN" ] 2>/dev/null \
  && ok "the TCP probe can detect an open port ($PROXY:3128 reachable)" \
  || bad "TCP probe cannot reach the proxy - the probe is broken, results void"
code=$(docker exec "$AGENT" curl -s -m 25 -o /dev/null -w '%{http_code}' \
       -I https://github.com 2>/dev/null)
[ "${code:-000}" != "000" ] \
  && ok "allowed domain reachable through the proxy: https://github.com -> $code" \
  || bad "github.com NOT reachable through the proxy - the egress path is broken"
code=$(docker exec "$AGENT" curl -s -m 25 -o /dev/null -w '%{http_code}' \
       https://api.linear.app/graphql 2>/dev/null)
[ "${code:-000}" != "000" ] \
  && ok "allowed domain reachable through the proxy: api.linear.app -> $code (TLS up)" \
  || bad "api.linear.app NOT reachable through the proxy"
for dom in api.github.com codeload.github.com; do
  grep -qE "^${dom}$" "$ALLOWFILE" || continue
  [ "$(proxy_req "${dom}:443")" = "200" ] \
    && ok "allowed domain tunnels: CONNECT ${dom}:443 -> 200" \
    || bad "CONNECT ${dom}:443 was refused, but it is on the allowlist"
done

echo
echo "BYPASS: NO DIRECT ROUTE WITH THE PROXY IGNORED"
# The threat is not a cooperative client. It is an agent that never reads
# HTTPS_PROXY at all -- so every probe here bypasses it deliberately.
if [ -z "$GH_IP" ]; then
  note "could not resolve github.com on the host - raw-IP checks skipped (not passed)"
fi
if [ -n "$GH_IP" ]; then
r=$(direct_tcp "$GH_IP" 443)
shut "$r" && ok "no route to github.com by raw IP ($GH_IP:443, $r) - a port that genuinely listens, so this is route-level" \
          || bad "REACHED github.com directly by IP - the proxy is not the only path out"
r=$(direct_tcp 1.1.1.1 443)
shut "$r" && ok "no route to 1.1.1.1:443 by raw IP ($r)" || bad "REACHED 1.1.1.1:443 directly"
r=$(direct_tcp 8.8.8.8 53)
shut "$r" && ok "no route to outbound DNS (8.8.8.8:53, $r)" || bad "outbound DNS REACHABLE"
r=$(direct_tcp host.docker.internal 27017)
shut "$r" && ok "no route to host services (host.docker.internal:27017, $r)" \
          || bad "REACHED a host service directly"
# host.docker.internal merely fails to resolve, which is the weaker result. The
# host's real LAN IP is where a service actually listens, so a failure there is
# the kernel refusing to route rather than a name lookup coming up empty.
HOST_IP="${HOST_IP:-$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')}"
if [ -n "$HOST_IP" ]; then
  r=$(direct_tcp "$HOST_IP" 27017)
  shut "$r" && ok "no route to host services by host LAN IP ($HOST_IP:27017, $r)" \
            || bad "REACHED a host service by LAN IP - the internal network is not isolating"
else
  note "could not detect the host LAN IP; set HOST_IP=... for a route-level host probe"
fi
docker exec "$AGENT" getent hosts github.com >/dev/null 2>&1 \
  && bad "agent can resolve github.com itself - DNS is leaving the isolated network" \
  || ok "agent cannot resolve github.com (the proxy does DNS, the agent never does)"
code=$(docker exec "$AGENT" curl -s -m 8 --noproxy '*' -o /dev/null -w '%{http_code}' \
       "https://$GH_IP" 2>/dev/null)
[ "${code:-000}" = "000" ] && ok "curl --noproxy to github.com's IP fails (no route)" \
                           || bad "curl --noproxy reached github.com -> $code"
fi   # end GH_IP-dependent checks
code=$(docker exec "$AGENT" env -u HTTPS_PROXY -u https_proxy -u HTTP_PROXY -u http_proxy \
       curl -s -m 8 -o /dev/null -w '%{http_code}' https://example.com 2>/dev/null)
[ "${code:-000}" = "000" ] && ok "with proxy vars unset, https://example.com fails" \
                           || bad "reached example.com with the proxy vars unset -> $code"

echo
echo "DOMAIN ALLOWLIST  (refusals must come FROM THE PROXY, i.e. 403)"
[ "$(proxy_req "example.com:443")" = "403" ] \
  && ok "non-allowed domain refused by the proxy: CONNECT example.com:443 -> 403" \
  || bad "CONNECT example.com:443 -> $(proxy_req example.com:443), expected 403"
[ "$(proxy_req "1.1.1.1:443")" = "403" ] \
  && ok "raw-IP CONNECT refused: CONNECT 1.1.1.1:443 -> 403 (DNS cannot be skipped)" \
  || bad "raw-IP CONNECT was NOT refused - the allowlist is sidesteppable"
if [ -n "$GH_IP" ]; then
  [ "$(proxy_req "$GH_IP:443")" = "403" ] \
    && ok "raw-IP CONNECT to an ALLOWED host's IP refused ($GH_IP:443 -> 403)" \
    || bad "CONNECT $GH_IP:443 allowed - the allowlist is a name check only"
else
  note "github.com did not resolve - the allowed-host raw-IP check was skipped"
fi
[ "$(proxy_req "[2606:4700:4700::1111]:443")" = "403" ] \
  && ok "IPv6-literal CONNECT refused" || bad "IPv6-literal CONNECT was NOT refused"
[ "$(proxy_req "github.com.p2-not-github.example:443")" = "403" ] \
  && ok "lookalike domain refused (github.com.p2-not-github.example)" \
  || bad "a domain merely CONTAINING github.com was allowed - matching is not exact"
[ "$(proxy_req "github.com:22")" = "403" ] \
  && ok "non-443 port refused on an allowed domain (CONNECT github.com:22 -> 403)" \
  || bad "CONNECT github.com:22 allowed - ssh tunnels out through the proxy"
[ "$(proxy_req "host.docker.internal:27017")" = "403" ] \
  && ok "proxy will not tunnel to host services (host.docker.internal:27017 -> 403)" \
  || bad "the proxy tunnelled to a HOST service - it is dual-homed, so this is reachable"
[ "$(proxy_req "http://api.linear.app/" GET)" = "403" ] \
  && ok "plain-HTTP fetch refused even for an allowed domain (CONNECT-only proxy)" \
  || bad "the proxy fetched a URL itself - it should only tunnel"
[ "$(proxy_req "http://169.254.169.254/latest/meta-data/" GET)" = "403" ] \
  && ok "link-local metadata endpoint refused" || bad "metadata endpoint NOT refused"

echo
echo "PROXY IS NOT AN OPEN PROXY FOR THE REST OF THE HOST"
PROXY_BRIDGE_IP=$(docker inspect "$PROXY" \
  --format '{{with index .NetworkSettings.Networks "bridge"}}{{.IPAddress}}{{end}}' 2>/dev/null)
if [ -n "$PROXY_BRIDGE_IP" ]; then
  # Deliberately NOT curl: curl reports 000 for a refused CONNECT, which is the
  # same thing it reports when it could not reach the proxy at all. Speaking the
  # protocol directly separates "the proxy said no" from "nothing was measured".
  out=$(docker run --rm --network bridge p2-probe:latest python3 -c '
import socket, sys
try:
    s = socket.create_connection((sys.argv[1], 3128), 8); s.settimeout(8)
    s.sendall(b"CONNECT github.com:443 HTTP/1.1\r\nHost: github.com\r\n\r\n")
    print(s.recv(128).decode("latin1").split("\r\n")[0].split(" ")[1]); s.close()
except Exception as e:
    print("UNREACHED")
' "$PROXY_BRIDGE_IP" 2>/dev/null | tail -1)
  if [ "$out" = "403" ]; then
    ok "a bridge container reaches the proxy but is refused (403) - not an open proxy"
  elif [ "$out" = "UNREACHED" ]; then
    ok "a bridge container cannot even reach the proxy port"
  else
    bad "any container on bridge can tunnel through the proxy -> $out"
  fi
else
  note "could not determine the proxy's bridge IP - open-proxy check skipped"
fi

echo
echo "PROXY HARDENING"
[ "$(docker exec "$PROXY" cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" = "0" ] \
  && ok "proxy ip_forward=0 (cannot route even if the agent gained NET_ADMIN)" \
  || bad "proxy ip_forward=1 - it would route for anyone who can set a route"
[ "$(docker inspect "$PROXY" --format '{{.HostConfig.ReadonlyRootfs}}')" = "true" ] \
  && ok "proxy rootfs read-only (cannot install or rewrite its own config)" \
  || bad "proxy rootfs writable"
docker inspect "$PROXY" --format '{{range .Mounts}}{{.Destination}}:{{.RW}} {{end}}' \
  | grep -q "/etc/squid/allowed-domains.txt:false" \
  && ok "allowlist mounted read-only" || bad "the allowlist is writable from the proxy"
grep -q '^\s*http_access deny all' "$(dirname "$ALLOWFILE")/egress-proxy.conf" \
  && ok "proxy config ends in default-deny" || bad "no explicit default-deny in the proxy config"
grep -qE '^\s*\.' "$ALLOWFILE" \
  && bad "the allowlist contains a leading-dot wildcard - that allows any subdomain" \
  || ok "allowlist has no wildcard entries (exact hosts only)"

echo
echo "GIT OVER HTTPS THROUGH THE PROXY"
docker exec "$AGENT" sh -c 'rm -rf /tmp/p2-clone' >/dev/null 2>&1
# Counting output lines would false-pass on an error message, so match a ref that
# must be present in a successful listing.
out=$(docker exec "$AGENT" sh -c \
  'git ls-remote https://github.com/octocat/Hello-World.git 2>&1 | grep -c "refs/heads/master$"' \
  2>/dev/null | tail -1)
[ "${out:-0}" = "1" ] && ok "git ls-remote works through the proxy (refs/heads/master listed)" \
                      || bad "git ls-remote failed through the proxy"
docker exec "$AGENT" sh -c \
  'git clone --depth 1 -q https://github.com/octocat/Hello-World.git /tmp/p2-clone' >/dev/null 2>&1 \
  && ok "git clone --depth 1 works through the proxy" || bad "git clone failed through the proxy"
# What `git push` requests first. 401 = GitHub's auth challenge, i.e. the endpoint
# was reached over the tunnel. No credentials are sent, and nothing is written.
code=$(docker exec "$AGENT" curl -s -m 25 -o /dev/null -w '%{http_code}' \
       'https://github.com/octocat/Hello-World.git/info/refs?service=git-receive-pack' 2>/dev/null)
[ "$code" = "401" ] || [ "$code" = "200" ] \
  && ok "git-receive-pack endpoint reached through the proxy (HTTP $code, github.com only)" \
  || bad "git-receive-pack unreachable: HTTP $code - a real push would fail"
docker exec "$AGENT" sh -c 'rm -rf /tmp/p2-clone' >/dev/null 2>&1

echo
echo "LOCAL MODEL PATH UNCHANGED  (path allowlist, separate from the egress proxy)"
mcode() { docker exec "$AGENT" curl -s -m 20 --noproxy '*' -o /dev/null -w '%{http_code}' \
          -X "$1" "http://${GATE}:11434$2" -d '{}' 2>/dev/null | tail -1; }
[ "$(mcode GET /api/tags)" = "200" ] \
  && ok "model gate reachable: GET /api/tags -> 200" \
  || bad "model gate broken: GET /api/tags -> $(mcode GET /api/tags)"
[ "$(mcode POST /api/pull)" = "403" ] \
  && ok "model gate still denies /api/pull (indirect internet egress)" \
  || bad "/api/pull is no longer 403"
[ "$(mcode POST /nonexistent)" = "403" ] \
  && ok "model gate still default-denies unknown paths" || bad "model gate default-deny broken"
if [ "${MODEL_CHAT:-0}" = "1" ]; then
  code=$(docker exec "$AGENT" curl -s -m 240 --noproxy '*' -o /dev/null -w '%{http_code}' \
         -X POST "http://${GATE}:11434/v1/chat/completions" -H 'Content-Type: application/json' \
         -d '{"model":"'"${MODEL:-gpt-oss:20b-64k}"'","messages":[{"role":"user","content":"hi"}],"max_tokens":16}' 2>/dev/null)
  [ "$code" = "200" ] && ok "inference works through the model gate (200)" \
                      || bad "inference through the model gate returned $code"
else
  note "set MODEL_CHAT=1 to also run a real inference call (loads the model into RAM)"
fi
# The two gates must stay separate: the egress proxy is not a way to the model,
# and NO_PROXY is what keeps a proxy-aware client off it.
[ "$(proxy_req "${GATE}:11434")" = "403" ] \
  && ok "egress proxy refuses to tunnel to the model gate (concerns stay separate)" \
  || bad "the egress proxy tunnels to the model gate"

echo
echo "AUDIT TRAIL"
denied=$(docker exec "$PROXY" grep -c TCP_DENIED /var/log/squid/access.log 2>/dev/null | tail -1)
[ "${denied:-0}" -gt 0 ] 2>/dev/null \
  && ok "proxy logged $denied denied attempts (independent record of what was tried)" \
  || bad "no denials in the proxy log - either nothing was refused, or logging is broken"

echo
printf 'RESULT: %d passed, %d failed\n\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1

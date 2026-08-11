#!/bin/sh
# Preflight for the composed stack. Runs as a compose service that the
# orchestrator `depends_on: service_completed_successfully`, so a failure here
# stops the orchestrator from ever starting. A sandbox that silently degrades is
# worse than no sandbox, because it is trusted.
#
# This runs INSIDE the isolated network with no Docker socket. It therefore
# tests REACHABILITY rather than inspecting configuration: "there is no route to
# 1.1.1.1" is a stronger claim than "the network object says Internal=true", and
# it is the claim that actually matters.
#
# Needs only curl and a POSIX shell (curlimages/curl).

GATE="${GATE_HOST:-ollama-gate}"
PROXY="${PROXY_HOST:-hermes-egress-proxy}"
DISPATCHER="${DISPATCHER_HOST:-hermes-dispatcher}"

fail() { echo "  REFUSING TO LAUNCH: $1" >&2; exit 1; }
okay() { echo "  ok: $1"; }

# %{http_code} is 000 when nothing answered at all, which is what "no route"
# looks like from curl. --noproxy '*' so the proxy variables cannot rescue a
# probe that is meant to go direct.
code() { curl -s -m 10 --noproxy '*' -o /dev/null -w '%{http_code}' "$@" 2>/dev/null; }

echo "preflight:"

# --- Positive control first -------------------------------------------------
# If the gate cannot be reached, every "blocked" result below is unfalsifiable.
c=$(code "http://${GATE}:11434/api/tags")
[ "$c" = "200" ] || fail "gate ${GATE} did not serve /api/tags (got ${c}); the agent would start with nothing to talk to."
okay "model gate reachable (/api/tags -> 200)"

# --- The gate's path allowlist still holds ----------------------------------
c=$(code -X POST "http://${GATE}:11434/api/pull" -d '{}')
[ "$c" = "403" ] || fail "gate allows /api/pull (got ${c}) - an indirect internet egress via the host. Check ollama-gate.conf."
okay "gate denies /api/pull (403)"

c=$(code -X POST "http://${GATE}:11434/nonexistent" -d '{}')
[ "$c" = "403" ] || fail "gate does not default-deny unknown paths (got ${c})."
okay "gate default-denies unknown paths (403)"

# --- There is no route out at all -------------------------------------------
# By raw IP, so this is the kernel refusing to route rather than DNS coming up
# empty. If the network stopped being --internal, this is what would notice.
c=$(code https://1.1.1.1)
[ "$c" = "000" ] || fail "reached 1.1.1.1 directly (HTTP ${c}) - the isolated network has a route out."
okay "no direct route to the internet (1.1.1.1 unreachable)"

c=$(code https://example.com)
[ "$c" = "000" ] || fail "resolved and reached example.com directly (HTTP ${c}) - there is outbound DNS and a route."
okay "no outbound DNS and no direct route (example.com unreachable)"

# --- The two permitted holes are actually up --------------------------------
# Liveness only: no request leaves the machine, so the stack still starts with
# the laptop offline. Whether the ALLOWLIST holds is verify-egress.sh's job.
c=$(curl -s -m 10 --noproxy '*' -o /dev/null -w '%{http_code}' "http://${PROXY}:3128/" 2>/dev/null)
[ "$c" != "000" ] || fail "egress proxy ${PROXY}:3128 is not answering; workers would have no way to reach GitHub."
okay "egress proxy listening (answered ${c} to a non-proxy request)"

c=$(code "http://${DISPATCHER}:2375/healthz")
[ "$c" = "200" ] || fail "spawn dispatcher ${DISPATCHER}:2375 is not healthy (got ${c}); the orchestrator could not start workers."
okay "spawn dispatcher healthy (/healthz -> 200)"

echo "  preflight OK: no route out, gate allowlist intact, both holes up."

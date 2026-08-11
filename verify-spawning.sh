#!/usr/bin/env bash
# TECH-98 - adversarial verification of a container-SPAWNING mechanism for an
# untrusted orchestrator. Same discipline as verify-sandbox.sh: every claim is
# measured from OUTSIDE the caller, the attacker's requests are issued from a
# throwaway container that has ONLY network access to the mechanism (never the
# Docker socket), every suite carries a POSITIVE CONTROL that must succeed or the
# negatives are void, and the script exits non-zero if the mechanism is unsafe.
#
#   ./verify-spawning.sh proxy        # option (a) tecnativa/docker-socket-proxy
#   ./verify-spawning.sh dispatcher   # option (d) body-validating dispatcher (default)
#
# Bring the rig up first with ./p1-spawn-setup.sh.
#
# The security question is blunt: "can a caller that is only supposed to spawn
# labelled workers instead mount the host filesystem, gain privilege, take the
# host network/PID namespace, or touch containers it does not own?" PASS = the
# mechanism refused. FAIL = it allowed it.

set -uo pipefail
NET=p1-spawn-net
PROXY=p1-socket-proxy
DISP=p1-dispatcher
BYSTANDER=p1-bystander
WORKER_LABEL='role=hermes-worker'
ALPINE=alpine:latest

TARGET="${1:-dispatcher}"

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
note() { printf '        %s\n' "$1"; }

# --- issue an attacker request from a throwaway container on the rig network ---
# It has no socket mount; its entire capability is "reach the mechanism's port".
CODE=""; BODY=""
_run() {  # runs curl in a throwaway container; splits body from trailing status
  local raw; raw=$(docker run --rm --network "$NET" curlimages/curl:latest "$@" 2>/dev/null)
  CODE=$(printf '%s\n' "$raw" | sed -n 's/^P1CODE://p' | tail -1)
  BODY=$(printf '%s\n' "$raw" | grep -v '^P1CODE:')
}
proxy_call() {  # METHOD PATH [BODY]
  local m=$1 p=$2 b=${3:-}
  if [ -n "$b" ]; then
    _run -s -m 30 -w $'\nP1CODE:%{http_code}' -X "$m" \
         -H 'Content-Type: application/json' -d "$b" "http://$PROXY:2375$p"
  else
    _run -s -m 30 -w $'\nP1CODE:%{http_code}' -X "$m" "http://$PROXY:2375$p"
  fi
}
disp_call() {  # METHOD PATH [BODY] [TOKEN|__NONE__]
  local m=$1 p=$2 b=${3:-} tok=${4-$TOKEN} args=()
  args=(-s -m 30 -w $'\nP1CODE:%{http_code}' -X "$m")
  [ "$tok" != "__NONE__" ] && args+=(-H "Authorization: Bearer $tok")
  [ -n "$b" ] && args+=(-H 'Content-Type: application/json' -d "$b")
  _run "${args[@]}" "http://$DISP:2375$p"
}

hins() { docker inspect "$1" --format "$2" 2>/dev/null; }
ensure_bystander() {  # a fresh unrelated, unlabelled-as-worker container
  docker rm -f "$BYSTANDER" >/dev/null 2>&1 || true
  docker run -d --name "$BYSTANDER" --network "$NET" --label role=innocent-bystander \
    "$ALPINE" sleep 3600 >/dev/null 2>&1
}
cleanup_workers() { docker rm -f $(docker ps -aq --filter 'name=^/p1-worker-' \
                    --filter 'name=^/p1-attack-' 2>/dev/null) >/dev/null 2>&1 || true; }

################################################################################
# OPTION (a) - path-filtering socket proxy
########################################################################################
suite_proxy() {
  echo "TARGET: option (a) tecnativa/docker-socket-proxy  ($PROXY, CONTAINERS=1 POST=1)"
  [ -n "$(docker ps -q -f name="^${PROXY}$")" ] || { note "$PROXY not running - run ./p1-spawn-setup.sh"; return; }
  cleanup_workers; ensure_bystander

  echo
  echo "POSITIVE CONTROL  (the mechanism MUST be able to spawn a labelled worker)"
  proxy_call POST "/containers/create?name=p1-worker-ctl" \
    '{"Image":"'"$ALPINE"'","Cmd":["sleep","300"],"Labels":{"role":"hermes-worker"}}'
  if [ "$CODE" = "201" ]; then
    ok "create labelled worker (201)"
    proxy_call POST "/containers/p1-worker-ctl/start"; [ "$CODE" = "204" ] && ok "start worker (204)" || bad "start worker returned $CODE"
    proxy_call POST "/containers/p1-worker-ctl/stop";  [ "$CODE" = "204" ] && ok "stop worker (204)"  || bad "stop worker returned $CODE"
    proxy_call DELETE "/containers/p1-worker-ctl";     [ "$CODE" = "204" ] && ok "remove worker (204)" || bad "remove worker returned $CODE"
  else
    bad "POSITIVE CONTROL FAILED: create worker returned $CODE - probe broken, negatives void"; return
  fi

  echo
  echo "BODY-VALIDATION  (the crux: does it inspect the create BODY, or only the path?)"
  # Flagship: create+start a 'worker' that bind-mounts the host root read-only and
  # reads host files. If the proxy performs no body validation, this succeeds and
  # the proxy is a Docker socket mount with extra steps.
  docker rm -f p1-attack-bind >/dev/null 2>&1 || true
  proxy_call POST "/containers/create?name=p1-attack-bind" \
    '{"Image":"'"$ALPINE"'","Labels":{"role":"hermes-worker"},"Cmd":["sh","-c","echo VM_HOSTNAME=$(cat /host/etc/hostname); echo HOST_HOME_DIRS=$(ls /host/Users 2>/dev/null | tr \"\\n\" \" \")"],"HostConfig":{"Binds":["/:/host:ro"]}}'
  if [ "$CODE" = "201" ]; then
    proxy_call POST "/containers/p1-attack-bind/start" >/dev/null
    sleep 2
    evidence=$(docker logs p1-attack-bind 2>/dev/null | tr -d '\000' | tr '\n' ' ' | head -c 200)
    bad "host-root bind mount ACCEPTED (201) and the worker read the host FS"
    note "evidence from inside the spawned container: ${evidence:-<no logs>}"
  else
    ok "host-root bind mount refused ($CODE)"
  fi

  docker rm -f p1-attack-priv >/dev/null 2>&1 || true
  proxy_call POST "/containers/create?name=p1-attack-priv" \
    '{"Image":"'"$ALPINE"'","Cmd":["sleep","5"],"Labels":{"role":"hermes-worker"},"HostConfig":{"Privileged":true}}'
  [ "$CODE" = "201" ] && bad "Privileged:true ACCEPTED (201)" || ok "Privileged:true refused ($CODE)"

  docker rm -f p1-attack-nethost >/dev/null 2>&1 || true
  proxy_call POST "/containers/create?name=p1-attack-nethost" \
    '{"Image":"'"$ALPINE"'","Cmd":["sleep","5"],"Labels":{"role":"hermes-worker"},"HostConfig":{"NetworkMode":"host"}}'
  [ "$CODE" = "201" ] && bad "NetworkMode:host ACCEPTED (201)" || ok "NetworkMode:host refused ($CODE)"

  docker rm -f p1-attack-pidhost >/dev/null 2>&1 || true
  proxy_call POST "/containers/create?name=p1-attack-pidhost" \
    '{"Image":"'"$ALPINE"'","Cmd":["sleep","5"],"Labels":{"role":"hermes-worker"},"HostConfig":{"PidMode":"host"}}'
  [ "$CODE" = "201" ] && bad "PidMode:host ACCEPTED (201)" || ok "PidMode:host refused ($CODE)"

  docker rm -f p1-attack-sock >/dev/null 2>&1 || true
  proxy_call POST "/containers/create?name=p1-attack-sock" \
    '{"Image":"'"$ALPINE"'","Cmd":["sleep","5"],"Labels":{"role":"hermes-worker"},"HostConfig":{"Binds":["/var/run/docker.sock:/var/run/docker.sock"]}}'
  [ "$CODE" = "201" ] && bad "docker.sock bind ACCEPTED (201) - a worker could re-mount the socket" \
                      || ok "docker.sock bind refused ($CODE)"

  echo
  echo "LABEL SCOPING  (can it touch containers it was never meant to?)"
  proxy_call POST "/containers/$BYSTANDER/stop"
  if [ "$CODE" = "204" ]; then bad "stopped UNRELATED non-worker container ($BYSTANDER) - no label scoping"; ensure_bystander
  else ok "refused to stop unrelated container ($CODE)"; fi
  proxy_call DELETE "/containers/$BYSTANDER?force=1"
  if [ "$CODE" = "204" ]; then bad "removed UNRELATED non-worker container ($BYSTANDER) - no label scoping"; ensure_bystander
  else ok "refused to remove unrelated container ($CODE)"; fi
  proxy_call GET "/containers/hermes/json"
  [ "$CODE" = "200" ] && bad "can INSPECT unrelated container 'hermes' (200) - full read of others' config" \
                      || ok "refused to inspect unrelated container hermes ($CODE)"
  proxy_call GET "/containers/json?all=1"
  if [ "$CODE" = "200" ] && printf '%s' "$BODY" | grep -q 'hermes'; then
    bad "full container INVENTORY disclosed (200) - lists hermes/ollama-gate/etc"
  else ok "container inventory not disclosed ($CODE)"; fi

  echo
  echo "CATEGORY LIMITS  (what the path filter DOES still block - to be fair)"
  proxy_call POST "/exec/deadbeef/start" '{"Detach":true}'
  [ "$CODE" = "403" ] && ok "exec START blocked (403, EXEC=0)" || bad "exec START returned $CODE, expected 403"
  note "caveat: 'POST /containers/{id}/exec' (exec CREATE) matches the CONTAINERS acl and IS allowed;"
  note "only the /exec/{id}/start step is blocked, so exec is inert but the surface is not clean."
  proxy_call GET "/images/json"
  [ "$CODE" = "403" ] && ok "image list blocked (403, IMAGES=0)" || bad "image list returned $CODE, expected 403"
  proxy_call POST "/build" '{}'
  [ "$CODE" = "403" ] && ok "image build blocked (403, BUILD=0)" || bad "build returned $CODE, expected 403"
  proxy_call GET "/info"
  [ "$CODE" = "403" ] && ok "daemon /info blocked (403, INFO=0)" || bad "/info returned $CODE, expected 403"

  cleanup_workers
}

########################################################################################
# OPTION (d) - body-validating dispatcher
########################################################################################
suite_dispatcher() {
  echo "TARGET: option (d) body-validating dispatcher  ($DISP)"
  [ -n "$(docker ps -q -f name="^${DISP}$")" ] || { note "$DISP not running - run ./p1-spawn-setup.sh"; return; }
  TOKEN=$(hins "$DISP" '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^DISPATCH_TOKEN=//p')
  [ -n "$TOKEN" ] || { bad "could not read DISPATCH_TOKEN from $DISP - cannot authenticate"; return; }
  cleanup_workers; ensure_bystander

  echo
  echo "POSITIVE CONTROL  (the mechanism MUST be able to spawn/stop/remove a worker)"
  disp_call POST "/spawn" '{"name":"p1-worker-ctl","cmd":["sleep","300"]}'
  if [ "$CODE" = "201" ]; then
    ok "spawn worker (201)"
    running=$(hins p1-worker-ctl '{{.State.Running}}'); label=$(hins p1-worker-ctl '{{index .Config.Labels "role"}}')
    [ "$running" = "true" ] && ok "worker is actually running" || bad "worker not running (State.Running=$running)"
    [ "$label" = "hermes-worker" ] && ok "worker carries $WORKER_LABEL" || bad "worker label is '$label', expected hermes-worker"
    disp_call POST "/stop" '{"name":"p1-worker-ctl"}';   [ "$CODE" = "200" ] && ok "stop worker (200)"   || bad "stop returned $CODE"
    disp_call POST "/remove" '{"name":"p1-worker-ctl"}'; [ "$CODE" = "200" ] && ok "remove worker (200)" || bad "remove returned $CODE"
  else
    bad "POSITIVE CONTROL FAILED: spawn returned $CODE ($BODY) - probe broken, negatives void"; return
  fi

  echo
  echo "BODY-VALIDATION  (smuggled HostConfig must never reach Docker)"
  docker rm -f p1-attack-smuggle >/dev/null 2>&1 || true
  disp_call POST "/spawn" '{"name":"p1-attack-smuggle","cmd":["sleep","60"],"image":"mongo:7","Privileged":true,"HostConfig":{"Binds":["/:/host:rw","/var/run/docker.sock:/var/run/docker.sock"],"Privileged":true,"NetworkMode":"host","PidMode":"host","CapAdd":["ALL"]}}'
  if [ "$CODE" != "201" ]; then
    ok "smuggle attempt rejected outright ($CODE)"
  else
    # It accepted the request - now PROVE none of the smuggled fields took effect.
    binds=$(hins p1-attack-smuggle '{{if .HostConfig.Binds}}{{.HostConfig.Binds}}{{else}}[]{{end}}')
    priv=$(hins p1-attack-smuggle '{{.HostConfig.Privileged}}')
    netm=$(hins p1-attack-smuggle '{{.HostConfig.NetworkMode}}')
    pidm=$(hins p1-attack-smuggle '{{.HostConfig.PidMode}}')
    img=$(hins  p1-attack-smuggle '{{.Config.Image}}')
    [ "$binds" = "[]" ]        && ok "no host bind mounts (Binds=$binds)"        || bad "SMUGGLED BIND TOOK EFFECT: $binds"
    [ "$priv" = "false" ]      && ok "not privileged (Privileged=$priv)"          || bad "SMUGGLED Privileged TOOK EFFECT: $priv"
    [ "$netm" != "host" ]      && ok "network not host (NetworkMode=$netm)"        || bad "SMUGGLED NetworkMode:host TOOK EFFECT"
    [ "$pidm" != "host" ]      && ok "pid ns not host (PidMode='${pidm:-<empty>}')" || bad "SMUGGLED PidMode:host TOOK EFFECT"
    [ "$img" = "$ALPINE" ]     && ok "image forced to $ALPINE (not caller's mongo:7)" || bad "SMUGGLED image TOOK EFFECT: $img"
    docker rm -f p1-attack-smuggle >/dev/null 2>&1 || true
  fi

  echo
  echo "AUTHENTICATION"
  disp_call POST "/spawn" '{"name":"p1-worker-noauth"}' "__NONE__"
  [ "$CODE" = "401" ] && ok "no token rejected (401)" || bad "no token returned $CODE, expected 401"
  disp_call POST "/spawn" '{"name":"p1-worker-badauth"}' "wrong-token"
  [ "$CODE" = "401" ] && ok "bad token rejected (401)" || bad "bad token returned $CODE, expected 401"

  echo
  echo "LABEL SCOPING  (must refuse containers it does not own)"
  disp_call POST "/stop" "{\"name\":\"$BYSTANDER\"}"
  [ "$CODE" = "403" ] && ok "refused to stop unrelated container $BYSTANDER (403)" || bad "stop $BYSTANDER returned $CODE, expected 403"
  [ "$(hins "$BYSTANDER" '{{.State.Running}}')" = "true" ] && ok "$BYSTANDER left running (untouched)" || bad "$BYSTANDER was disturbed"
  disp_call POST "/remove" "{\"name\":\"$BYSTANDER\"}"
  [ "$CODE" = "403" ] && ok "refused to remove unrelated container $BYSTANDER (403)" || bad "remove $BYSTANDER returned $CODE, expected 403"
  # The strongest statement: point a destructive verb at the REAL hermes. The
  # guard inspects the label first (read-only) and refuses before acting.
  disp_call POST "/stop" '{"name":"hermes"}'
  [ "$CODE" = "403" ] && ok "refused to stop the real 'hermes' container (403)" || bad "stop hermes returned $CODE, expected 403"
  [ "$(hins hermes '{{.State.Running}}')" = "true" ] && ok "hermes still running (guard did not disturb it)" || bad "hermes was disturbed - INVESTIGATE"

  echo
  echo "SURFACE  (no raw Docker API, no exec/build/inventory)"
  disp_call POST "/containers/create" '{"Image":"alpine"}'
  [ "$CODE" = "404" ] && ok "no raw /containers/create passthrough (404)" || bad "/containers/create returned $CODE, expected 404"
  disp_call POST "/exec" '{}'
  [ "$CODE" = "404" ] && ok "no exec surface (404)" || bad "/exec returned $CODE, expected 404"
  disp_call POST "/build" '{}'
  [ "$CODE" = "404" ] && ok "no build surface (404)" || bad "/build returned $CODE, expected 404"
  disp_call GET "/containers/json" ""
  [ "$CODE" = "404" ] && ok "no inventory disclosure (404)" || bad "/containers/json returned $CODE, expected 404"

  cleanup_workers
}

echo
case "$TARGET" in
  proxy)      suite_proxy ;;
  dispatcher) suite_dispatcher ;;
  *) echo "usage: $0 [proxy|dispatcher]"; exit 2 ;;
esac

echo
printf 'RESULT (%s): %d passed, %d failed\n\n' "$TARGET" "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1

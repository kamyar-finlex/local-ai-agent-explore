#!/usr/bin/env bash
# TECH-98 - adversarial verification of a container-SPAWNING mechanism for an
# untrusted orchestrator. Same discipline as verify-sandbox.sh: every claim is
# measured from OUTSIDE the caller, the attacker's requests are issued from a
# throwaway container that has ONLY network access to the mechanism (never the
# Docker socket), every suite carries a POSITIVE CONTROL that must succeed or the
# negatives are void, and the script exits non-zero if the mechanism is unsafe.
#
#   ./verify-spawning.sh dispatcher   # option (d) body-validating dispatcher (default)
#   ./verify-spawning.sh proxy        # option (a) tecnativa/docker-socket-proxy
#
# The security question is blunt: "can a caller that is only supposed to spawn
# labelled workers instead mount the host filesystem, gain privilege, take the
# host network/PID namespace, or touch containers it does not own?" PASS = the
# mechanism refused. FAIL = it allowed it.
#
# TOPOLOGY, after the consolidation:
#
#   dispatcher  - option (d) WON, so it is a service in docker-compose.yml and
#                 this suite runs against the composed stack. Its worker image,
#                 label, name prefix and network are read from the RUNNING
#                 container's environment rather than hardcoded, so the attack
#                 payloads below stay aimed at the real configuration. Hardcoded
#                 names would have made the smuggle test fail on name validation
#                 instead of body validation - a pass that measures nothing.
#
#   proxy       - option (a) LOST and is deliberately NOT in the composed stack;
#                 composing a mechanism this harness proves unsafe would be the
#                 wrong artifact to ship. Its suite is kept because the exploit
#                 is the evidence for the decision, and it still needs the
#                 standalone rig: ./p1-spawn-setup.sh, then
#                 ./verify-spawning.sh proxy, then ./p1-spawn-teardown.sh.

set -uo pipefail
HERE_DIR="$(cd "$(dirname "$0")" && pwd)"
# Machine-specific values (TARGET_REPO, TARGET_REPO_TOKEN) live in the gitignored
# local.env. The ENV-INJECTION suite needs a real credential for ONE check - the
# positive control that a worker can actually clone the target repository - and a
# real repo name to clone. Without local.env that single check is skipped loudly
# and everything else still runs.
# shellcheck source=/dev/null
[ -f "$HERE_DIR/local.env" ] && . "$HERE_DIR/local.env"

DISP="${DISPATCHER_NAME:-hermes-dispatcher}"
AGENT_NAME="${AGENT_NAME:-hermes}"
# The rejected option (a) rig is still p1-*, and still on its own network.
PROXY=p1-socket-proxy
PROXY_NET=p1-spawn-net
ALPINE=alpine:latest
# The ENV-INJECTION suite stands up its OWN dispatcher, because the properties it
# has to prove need a configuration the composed dispatcher cannot have at once:
# an allowlisted variable that IS set, one that is deliberately NOT set, and a
# reserved name the allowlist must refuse. Namespaced p7-* and torn down.
P7DISP=p7-env-dispatcher
P7PREFIX=p7-w-
P7LABEL=p7-scratch-worker
P7WORK_SIZE=256m
P7UNSET=P7_UNSET_ON_PURPOSE

TARGET="${1:-dispatcher}"

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
note() { printf '        %s\n' "$1"; }

# Anything this script prints goes through here. The suite handles a real
# credential; a captured PASS/FAIL transcript is exactly the sort of thing that
# ends up pasted into a ticket.
SECRET="${TARGET_REPO_TOKEN:-}"
scrub() { if [ -n "$SECRET" ]; then sed "s|${SECRET}|<redacted>|g"; else cat; fi; }

# --- issue an attacker request from a throwaway container on the rig network ---
# It has no socket mount; its entire capability is "reach the mechanism's port".
CODE=""; BODY=""
NET=""            # set per suite: the network the mechanism under test is on
PREFIX="p1-"      # set per suite: the name prefix the mechanism enforces
LABEL_KEY="role"
LABEL_VALUE="hermes-worker"
BYSTANDER="p1-bystander"
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
denv() { hins "$1" '{{range .Config.Env}}{{println .}}{{end}}' | sed -n "s/^$2=//p" | head -1; }
# Is the variable PRESENT at all? Distinct from denv returning empty, which is the
# whole point of the "unset means omitted, not empty" requirement.
dhas() { hins "$1" '{{range .Config.Env}}{{println .}}{{end}}' | grep -q "^$2=" && echo yes || echo no; }
# Does ANY entry equal NAME=VALUE? Deliberately not "the first entry", because the
# naive way to leak a caller's env is to APPEND it - .Config.Env then holds the
# dispatcher's value first and the attacker's second, and a check that reads only
# the first occurrence would report a pass while the process sees the attacker's.
eany() { hins "$1" '{{range .Config.Env}}{{println .}}{{end}}' | grep -qxF -- "$2=$3" && echo yes || echo no; }
enames()  { hins "$1" '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^\([^=]*\)=.*/\1/p' | sort -u; }
inames()  { docker image inspect "$1" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
            | sed -n 's/^\([^=]*\)=.*/\1/p' | sort -u; }
# The Tmpfs map as "path=opts" lines, so a rename or a resize is visible.
dtmpfs() { hins "$1" '{{range $p,$o := .HostConfig.Tmpfs}}{{$p}}={{$o}}{{"\n"}}{{end}}' | sed '/^$/d' | sort; }
ensure_bystander() {  # a fresh unrelated, unlabelled-as-worker container
  docker rm -f "$BYSTANDER" >/dev/null 2>&1 || true
  docker run -d --name "$BYSTANDER" --network "$NET" --label role=innocent-bystander \
    "$ALPINE" sleep 3600 >/dev/null 2>&1
}
cleanup_workers() { docker rm -f $(docker ps -aq --filter "name=^/${PREFIX}" \
                    --filter "label=${LABEL_KEY}=${LABEL_VALUE}" 2>/dev/null) >/dev/null 2>&1 || true; }

################################################################################
# OPTION (a) - path-filtering socket proxy
########################################################################################
suite_proxy() {
  echo "TARGET: option (a) tecnativa/docker-socket-proxy  ($PROXY, CONTAINERS=1 POST=1)"
  echo "        NOTE: this option was rejected and is NOT part of the composed stack."
  echo "        It runs on the standalone p1-* rig (./p1-spawn-setup.sh)."
  # The rejected rig keeps its own network, prefix and bystander; nothing here
  # touches the composed stack.
  NET="$PROXY_NET"; PREFIX="p1-"; BYSTANDER="p1-bystander"
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
  # Now that the mechanism's job includes handing workers a credential, the read
  # surface is not merely an information leak - it is a credential oracle. The
  # proxy's `/containers` ACL covers reads, so a caller can inspect the very
  # container that holds the bearer token and lift it out of .Config.Env.
  proxy_call GET "/containers/p1-dispatcher/json"
  if [ "$CODE" = "200" ] && printf '%s' "$BODY" | grep -q 'DISPATCH_TOKEN='; then
    bad "CREDENTIAL DISCLOSED: read DISPATCH_TOKEN out of another container's .Config.Env (200)"
  else ok "cannot read another container's environment ($CODE)"; fi

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
  [ -n "$(docker ps -q -f name="^${DISP}$")" ] \
    || { note "$DISP not running - bring the stack up with 'docker compose up -d'"; return; }

  # Read the mechanism's real configuration off the running container instead of
  # hardcoding it. If the attack payloads used the wrong name prefix, the
  # dispatcher would reject them at NAME validation and every "refused" below
  # would be true but meaningless - the suite must exercise body validation.
  TOKEN=$(denv "$DISP" DISPATCH_TOKEN)
  [ -n "$TOKEN" ] || { bad "could not read DISPATCH_TOKEN from $DISP - cannot authenticate"; return; }
  PREFIX=$(denv "$DISP" WORKER_NAME_PREFIX);  PREFIX="${PREFIX:-p1-}"
  LABEL_KEY=$(denv "$DISP" WORKER_LABEL_KEY); LABEL_KEY="${LABEL_KEY:-role}"
  LABEL_VALUE=$(denv "$DISP" WORKER_LABEL_VALUE); LABEL_VALUE="${LABEL_VALUE:-hermes-worker}"
  WORKER_IMAGE=$(denv "$DISP" WORKER_IMAGE); WORKER_IMAGE="${WORKER_IMAGE:-$ALPINE}"
  NET=$(denv "$DISP" WORKER_NETWORK)
  NET="${NET:-$(hins "$DISP" '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}')}"
  # The env/workspace configuration, likewise read off the running container. An
  # attack payload that guessed the wrong workspace path would "fail to rename
  # it" for the wrong reason.
  ALLOW_RAW=$(denv "$DISP" WORKER_ENV_ALLOWLIST); ALLOW_RAW="${ALLOW_RAW:-GITHUB_TOKEN,TARGET_REPO}"
  ALLOW_NAMES=$(printf '%s' "$ALLOW_RAW" | tr ',' ' ')
  WPATH=$(denv "$DISP" WORKER_WORK_PATH);  WPATH="${WPATH:-/work}"
  WSIZE=$(denv "$DISP" WORKER_WORK_SIZE);  WSIZE="${WSIZE:-384m}"
  TMPSIZE=8m
  BYSTANDER="${PREFIX}NOT-a-worker-bystander"
  # A bystander whose name carries the worker prefix is the harder case: it
  # proves the guard is the LABEL, not the name.
  CTL="${PREFIX}ctl"; SMUGGLE="${PREFIX}attack-smuggle"
  note "config read from $DISP: prefix=$PREFIX label=$LABEL_KEY=$LABEL_VALUE net=$NET image=$WORKER_IMAGE"
  note "env allowlist=$ALLOW_RAW  workspace=$WPATH size=$WSIZE"
  cleanup_workers; docker rm -f "$BYSTANDER" >/dev/null 2>&1; ensure_bystander

  echo
  echo "POSITIVE CONTROL  (the mechanism MUST be able to spawn/stop/remove a worker)"
  disp_call POST "/spawn" "{\"name\":\"$CTL\",\"cmd\":[\"sleep\",\"300\"]}"
  if [ "$CODE" = "201" ]; then
    ok "spawn worker (201)"
    running=$(hins "$CTL" '{{.State.Running}}')
    label=$(hins "$CTL" "{{index .Config.Labels \"$LABEL_KEY\"}}")
    [ "$running" = "true" ] && ok "worker is actually running" || bad "worker not running (State.Running=$running)"
    [ "$label" = "$LABEL_VALUE" ] && ok "worker carries $LABEL_KEY=$LABEL_VALUE" \
                                  || bad "worker label is '$label', expected $LABEL_VALUE"
    # The workers the dispatcher creates must be as confined as everything else.
    # This was implicit in the p1 rig; under compose, workers share the agent's
    # isolated network, so their own hardening is what stops one worker being a
    # softer way in than the orchestrator.
    [ "$(hins "$CTL" '{{.HostConfig.CapDrop}}')" = "[ALL]" ] \
      && ok "worker created with cap_drop ALL" || bad "worker has capabilities"
    [ "$(hins "$CTL" '{{.HostConfig.ReadonlyRootfs}}')" = "true" ] \
      && ok "worker rootfs read-only" || bad "worker rootfs writable"
    [ "$(hins "$CTL" '{{.HostConfig.Memory}}')" -gt 0 ] 2>/dev/null \
      && ok "worker memory capped ($(( $(hins "$CTL" '{{.HostConfig.Memory}}') / 1048576 )) MiB)" \
      || bad "worker has no memory limit"
    [ "$(hins "$CTL" '{{.HostConfig.NetworkMode}}')" = "$NET" ] \
      && ok "worker joined $NET (no route out except the two gates)" \
      || bad "worker network is $(hins "$CTL" '{{.HostConfig.NetworkMode}}'), expected $NET"

    # ---- /status: the one fact the reaper needs, and nothing more (TECH-102) --
    # Read through the lifecycle of THIS container, because the three answers
    # only mean anything in contrast: a verb that always said "not running"
    # would satisfy the exited and gone cases and be useless.
    echo
    echo "  STATUS - running"
    disp_call POST "/status" "{\"name\":\"$CTL\"}"
    STAT_RUNNING="$BODY"
    [ "$CODE" = "200" ] && ok "status answers for a labelled worker (200)" \
                        || bad "status returned $CODE for our own worker, expected 200"
    jfield() { printf '%s' "$1" | python3 -c 'import json,sys
try: print(json.loads(sys.stdin.read()).get(sys.argv[1]))
except Exception: print("PARSE-ERROR")' "$2"; }
    [ "$(jfield "$STAT_RUNNING" running)" = "True" ] \
      && ok "it reports the running worker as running" \
      || bad "status says running=$(jfield "$STAT_RUNNING" running) for a container Docker calls running"
    [ "$(jfield "$STAT_RUNNING" exists)" = "True" ] \
      && ok "and exists=true" || bad "status says exists=$(jfield "$STAT_RUNNING" exists)"
    [ "$(jfield "$STAT_RUNNING" exit_code)" = "None" ] \
      && ok "exit_code is null while it runs - a bare 0 would read as a clean exit" \
      || bad "a running container reported exit_code=$(jfield "$STAT_RUNNING" exit_code)"

    # THE check this verb had to earn. An off-the-shelf socket proxy's
    # GET /containers/{id}/json returns the injected credential in the body;
    # that is one of the nine checks it failed. The response must be four
    # fields, by name, and must contain no others.
    KEYS=$(printf '%s' "$STAT_RUNNING" | python3 -c 'import json,sys
try: print(",".join(sorted(json.loads(sys.stdin.read()))))
except Exception: print("PARSE-ERROR")')
    [ "$KEYS" = "exists,exit_code,name,running" ] \
      && ok "the response is exactly {exists, exit_code, name, running} - no other field" \
      || bad "status response carries unexpected fields: $KEYS"
    if printf '%s' "$STAT_RUNNING" | grep -qiE '"(env|mounts|config|hostconfig|image|networksettings|args|path)"'; then
      bad "STATUS LEAKS CONTAINER DETAIL - env/mounts/config/image are visible"
    else
      ok "no env, mounts, config, image or network detail in the body"
    fi
    # And the concrete version of the same statement: the actual injected
    # credential, byte for byte. Never printed, only searched for.
    INJ_TOK=$(denv "$CTL" GITHUB_TOKEN)
    if [ -n "$INJ_TOK" ]; then
      printf '%s' "$STAT_RUNNING" | grep -qF -- "$INJ_TOK" \
        && bad "THE INJECTED CREDENTIAL IS READABLE THROUGH /status - it is a token oracle" \
        || ok "the worker's injected GITHUB_TOKEN does not appear in the status body"
    else
      note "no GITHUB_TOKEN injected into this worker, so the token-oracle check is vacuous here"
    fi

    echo
    echo "  STATUS - cannot enumerate, cannot be aimed elsewhere"
    disp_call POST "/status" '{}'
    [ "$CODE" = "400" ] && ok "no name at all is refused (400) - there is no 'list everything' form" \
                        || bad "status with no name returned $CODE, expected 400"
    disp_call POST "/status" '{"name":"*"}'
    [ "$CODE" = "400" ] && ok "a wildcard is refused (400)" || bad "status '*' returned $CODE, expected 400"
    disp_call POST "/status" '{"name":""}'
    [ "$CODE" = "400" ] && ok "an empty name is refused (400)" || bad "status '' returned $CODE, expected 400"
    disp_call POST "/status" "{\"name\":[\"$CTL\"]}"
    [ "$CODE" = "400" ] && ok "a LIST of names is refused (400) - one question, one container" \
                        || bad "status with a list returned $CODE, expected 400"
    disp_call POST "/status" '{"name":"../../containers/json"}'
    [ "$CODE" = "400" ] && ok "a path-traversal name is refused (400)" \
                        || bad "status '../../containers/json' returned $CODE, expected 400"
    disp_call POST "/status" "{\"name\":\"$BYSTANDER\"}"
    [ "$CODE" = "403" ] && ok "refused to describe the unlabelled $BYSTANDER (403), same guard as stop/remove" \
                        || bad "status on $BYSTANDER returned $CODE, expected 403"
    disp_call POST "/status" "{\"name\":\"$AGENT_NAME\"}"
    if [ "$CODE" = "403" ]; then
      ok "refused to describe the real '$AGENT_NAME' container (403)"
      printf '%s' "$BODY" | grep -qiE '"(env|mounts|state|config)"' \
        && bad "the 403 for $AGENT_NAME still leaked container detail" \
        || ok "and the refusal itself discloses nothing about it"
    else
      bad "status on $AGENT_NAME returned $CODE, expected 403"
    fi
    disp_call POST "/status" "{\"name\":\"$CTL\"}" "__NONE__"
    [ "$CODE" = "401" ] && ok "unauthenticated status is rejected (401)" \
                        || bad "status without a token returned $CODE, expected 401"
    disp_call GET "/status" ""
    [ "$CODE" = "404" ] && ok "there is no GET /status - one authentication chokepoint, not two" \
                        || bad "GET /status returned $CODE, expected 404"

    echo
    echo "  STATUS - exited, then gone"
    disp_call POST "/stop" "{\"name\":\"$CTL\"}";   [ "$CODE" = "200" ] && ok "stop worker (200)"   || bad "stop returned $CODE"
    disp_call POST "/status" "{\"name\":\"$CTL\"}"
    STAT_EXITED="$BODY"
    [ "$(jfield "$STAT_EXITED" running)" = "False" ] && [ "$(jfield "$STAT_EXITED" exists)" = "True" ] \
      && ok "a stopped worker reads exists=true running=false - the case that used to cost 45 minutes" \
      || bad "a stopped worker reads exists=$(jfield "$STAT_EXITED" exists) running=$(jfield "$STAT_EXITED" running)"
    [ "$(jfield "$STAT_EXITED" exit_code)" != "None" ] \
      && ok "and its exit code is available ($(jfield "$STAT_EXITED" exit_code))" \
      || bad "no exit code for a stopped container"
    disp_call POST "/remove" "{\"name\":\"$CTL\"}"; [ "$CODE" = "200" ] && ok "remove worker (200)" || bad "remove returned $CODE"
    disp_call POST "/status" "{\"name\":\"$CTL\"}"
    STAT_GONE="$BODY"
    if [ "$CODE" = "200" ] && [ "$(jfield "$STAT_GONE" exists)" = "False" ]; then
      ok "a removed worker is a 200 with exists=false - 'gone' is an ANSWER, not an error"
    else
      bad "status after remove returned $CODE / exists=$(jfield "$STAT_GONE" exists), expected 200/false"
    fi
  else
    bad "POSITIVE CONTROL FAILED: spawn returned $CODE ($BODY) - probe broken, negatives void"; return
  fi

  echo
  echo "BODY-VALIDATION  (smuggled HostConfig, Env and Tmpfs must never reach Docker)"
  # One request that tries everything at once. Since the dispatcher CONSTRUCTS the
  # create body, every one of these fields is simply never read - so the request
  # is accepted (201) and the proof is what the created container looks like from
  # the host. A 4xx here would be a weaker result and would also mean the suite
  # stopped short of body validation, which is why that case is a FAIL below.
  #
  # The env half of the payload is the new attack surface: the dispatcher now
  # injects credentials, so a caller that could name, add or override a variable
  # would have turned the injection point into a credential channel.
  docker rm -f "$SMUGGLE" >/dev/null 2>&1 || true
  disp_call POST "/spawn" "{\"name\":\"$SMUGGLE\",\"cmd\":[\"sleep\",\"60\"],\"image\":\"mongo:7\",\"Privileged\":true,\"Env\":[\"EVIL_INJECTED=1\",\"GITHUB_TOKEN=attacker-controlled\",\"TARGET_REPO=attacker/repo\",\"LD_PRELOAD=/tmp/evil.so\"],\"env\":{\"EVIL_LOWERCASE\":\"1\"},\"environment\":[\"EVIL_COMPOSE_STYLE=1\"],\"WorkingDir\":\"/attacker\",\"workspace\":\"/hostile\",\"work_path\":\"/hostile\",\"WORKER_WORK_PATH\":\"/hostile\",\"WORKER_WORK_SIZE\":\"4g\",\"work_size\":\"4g\",\"workspace_size\":\"4g\",\"WORKER_ENV_ALLOWLIST\":\"DISPATCH_TOKEN\",\"Tmpfs\":{\"/hostile\":\"size=4g\"},\"HostConfig\":{\"Binds\":[\"/:/host:rw\",\"/var/run/docker.sock:/var/run/docker.sock\"],\"Privileged\":true,\"NetworkMode\":\"host\",\"PidMode\":\"host\",\"CapAdd\":[\"ALL\"],\"Tmpfs\":{\"/hostile\":\"size=4g\",\"$WPATH\":\"size=4g\",\"/tmp\":\"size=4g\"},\"ReadonlyRootfs\":false}}"
  if [ "$CODE" != "201" ]; then
    bad "smuggle attempt returned $CODE, not 201 - the suite did not reach body validation ($BODY)"
  else
    # It accepted the request - now PROVE none of the smuggled fields took effect.
    binds=$(hins "$SMUGGLE" '{{if .HostConfig.Binds}}{{.HostConfig.Binds}}{{else}}[]{{end}}')
    priv=$(hins "$SMUGGLE" '{{.HostConfig.Privileged}}')
    netm=$(hins "$SMUGGLE" '{{.HostConfig.NetworkMode}}')
    pidm=$(hins "$SMUGGLE" '{{.HostConfig.PidMode}}')
    img=$(hins  "$SMUGGLE" '{{.Config.Image}}')
    [ "$binds" = "[]" ]           && ok "no host bind mounts (Binds=$binds)"         || bad "SMUGGLED BIND TOOK EFFECT: $binds"
    [ "$priv" = "false" ]         && ok "not privileged (Privileged=$priv)"          || bad "SMUGGLED Privileged TOOK EFFECT: $priv"
    [ "$netm" != "host" ]         && ok "network not host (NetworkMode=$netm)"       || bad "SMUGGLED NetworkMode:host TOOK EFFECT"
    [ "$pidm" != "host" ]         && ok "pid ns not host (PidMode='${pidm:-<empty>}')" || bad "SMUGGLED PidMode:host TOOK EFFECT"
    [ "$img" = "$WORKER_IMAGE" ]  && ok "image forced to $WORKER_IMAGE (not caller's mongo:7)" || bad "SMUGGLED image TOOK EFFECT: $img"
    [ "$(hins "$SMUGGLE" '{{.HostConfig.ReadonlyRootfs}}')" = "true" ] \
      && ok "rootfs still read-only (caller's ReadonlyRootfs:false ignored)" \
      || bad "SMUGGLED ReadonlyRootfs:false TOOK EFFECT"

    # --- the env half -----------------------------------------------------
    # Names the caller tried to add outright.
    for evil in EVIL_INJECTED EVIL_LOWERCASE EVIL_COMPOSE_STYLE LD_PRELOAD; do
      [ "$(dhas "$SMUGGLE" "$evil")" = "no" ] \
        && ok "caller-supplied Env had no effect ($evil absent from the worker)" \
        || bad "CALLER-SUPPLIED ENV TOOK EFFECT: $evil is set in the worker"
    done
    # PATH gets its OWN spawn. It always exists (the image sets it), so the
    # question is whether the caller could REPLACE it - and a successful override
    # breaks the container's own entrypoint, which would abort the rest of this
    # battery if it shared the worker above. Failing to start is itself a catch.
    PATHPROBE="${PREFIX}attack-path"
    docker rm -f "$PATHPROBE" >/dev/null 2>&1 || true
    disp_call POST "/spawn" "{\"name\":\"$PATHPROBE\",\"cmd\":[\"sleep\",\"30\"],\"Env\":[\"PATH=/attacker/bin\"]}"
    if [ "$CODE" != "201" ]; then
      bad "PATH override changed the outcome of /spawn ($CODE) - the caller's Env reached Docker"
    else
      [ "$(eany "$PATHPROBE" PATH /attacker/bin)" = "no" ] \
        && ok "caller could not override PATH (still the image's)" \
        || bad "CALLER OVERRODE PATH - process hijack"
    fi
    docker rm -f "$PATHPROBE" >/dev/null 2>&1 || true
    # An allowlisted name is the sharpest case: the caller names a variable the
    # dispatcher does inject and supplies its own value. Whatever the dispatcher
    # is configured with, the worker must never hold the caller's string ANYWHERE
    # in its env.
    for al in $ALLOW_NAMES; do
      want=$(denv "$DISP" "$al")
      if [ "$(eany "$SMUGGLE" "$al" attacker-controlled)" = "yes" ] || \
         [ "$(eany "$SMUGGLE" "$al" attacker/repo)" = "yes" ]; then
        bad "CALLER OVERRODE $al - the worker holds the caller's value"
      elif [ "$(dhas "$SMUGGLE" "$al")" = "no" ] && [ -z "$want" ]; then
        ok "caller could not add $al (unset in the dispatcher, so absent - not caller's value)"
      elif [ "$(denv "$SMUGGLE" "$al")" = "$want" ] && [ -n "$want" ]; then
        ok "caller could not override $al (worker holds the dispatcher's value)"
      else
        bad "$al is neither the dispatcher's value nor absent - unexplained"
      fi
    done
    # A variable that appears twice is the signature of "the caller's env was
    # merged in", whichever copy the kernel ends up handing the process.
    etot=$(hins "$SMUGGLE" '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^\([^=]*\)=.*/\1/p' | wc -l | tr -d ' ')
    euniq=$(enames "$SMUGGLE" | wc -l | tr -d ' ')
    [ "$etot" = "$euniq" ] && ok "no duplicated variable names ($euniq of $etot) - nothing was merged in" \
                           || bad "DUPLICATED env names ($euniq unique of $etot) - a second value was merged in"
    # No variable at all beyond what the IMAGE bakes in and what the dispatcher's
    # own allowlist permits. This is the check that catches a future "just pass
    # the request's env through" regression even for a name nobody thought of.
    extra=$( { enames "$SMUGGLE"; inames "$WORKER_IMAGE"; inames "$WORKER_IMAGE"; } \
             | sort | uniq -u | grep -vx -F -e PATH $(printf -- '-e %s ' $ALLOW_NAMES) | tr '\n' ' ')
    [ -z "$extra" ] && ok "worker env is image-baked + allowlist only (no extra names)" \
                    || bad "UNEXPECTED env names in the worker: $extra"

    # --- the workspace half ----------------------------------------------
    tm=$(dtmpfs "$SMUGGLE" | tr '\n' ' ')
    printf '%s' "$tm" | grep -q "/hostile" \
      && bad "CALLER ADDED A TMPFS AT ITS OWN PATH: $tm" \
      || ok "caller could not rename/add a workspace path (Tmpfs: ${tm% })"
    printf '%s' "$tm" | grep -q "4g" \
      && bad "CALLER RESIZED A TMPFS: $tm" \
      || ok "caller could not change a tmpfs size (still size=$WSIZE / $TMPSIZE)"
    [ "$(hins "$SMUGGLE" '{{.Config.WorkingDir}}')" = "$WPATH" ] \
      && ok "WorkingDir is the dispatcher's $WPATH (not caller's /attacker)" \
      || bad "SMUGGLED WorkingDir TOOK EFFECT: $(hins "$SMUGGLE" '{{.Config.WorkingDir}}')"
    docker rm -f "$SMUGGLE" >/dev/null 2>&1 || true
  fi

  echo
  echo "AUTHENTICATION"
  disp_call POST "/spawn" "{\"name\":\"${PREFIX}noauth\"}" "__NONE__"
  [ "$CODE" = "401" ] && ok "no token rejected (401)" || bad "no token returned $CODE, expected 401"
  disp_call POST "/spawn" "{\"name\":\"${PREFIX}badauth\"}" "wrong-token"
  [ "$CODE" = "401" ] && ok "bad token rejected (401)" || bad "bad token returned $CODE, expected 401"

  echo
  echo "LABEL SCOPING  (must refuse containers it does not own)"
  # The bystander deliberately CARRIES the worker name prefix. If the guard were
  # a name check rather than a label check, this would be stopped and removed.
  disp_call POST "/stop" "{\"name\":\"$BYSTANDER\"}"
  [ "$CODE" = "403" ] && ok "refused to stop unrelated container $BYSTANDER (403)" || bad "stop $BYSTANDER returned $CODE, expected 403"
  [ "$(hins "$BYSTANDER" '{{.State.Running}}')" = "true" ] && ok "$BYSTANDER left running (untouched)" || bad "$BYSTANDER was disturbed"
  disp_call POST "/remove" "{\"name\":\"$BYSTANDER\"}"
  [ "$CODE" = "403" ] && ok "refused to remove unrelated container $BYSTANDER (403)" || bad "remove $BYSTANDER returned $CODE, expected 403"
  # The strongest statement: point a destructive verb at the REAL orchestrator.
  # The guard inspects the label first (read-only) and refuses before acting.
  disp_call POST "/stop" "{\"name\":\"$AGENT_NAME\"}"
  [ "$CODE" = "403" ] && ok "refused to stop the real '$AGENT_NAME' container (403)" || bad "stop $AGENT_NAME returned $CODE, expected 403"
  [ "$(hins "$AGENT_NAME" '{{.State.Running}}')" = "true" ] && ok "$AGENT_NAME still running (guard did not disturb it)" || bad "$AGENT_NAME was disturbed - INVESTIGATE"
  # Consolidation-specific: the dispatcher now lives beside the components it
  # could most usefully disable. Neither is labelled as a worker, so both must
  # be refused - a stop of the gate would blind the model path, a stop of the
  # proxy would blind the audit trail.
  for infra in "${GATE_NAME:-ollama-gate}" "${PROXY_NAME:-hermes-egress-proxy}"; do
    [ -n "$(docker ps -q -f name="^${infra}$")" ] || continue
    disp_call POST "/stop" "{\"name\":\"$infra\"}"
    [ "$CODE" = "403" ] && ok "refused to stop stack component $infra (403)" \
                        || bad "stop $infra returned $CODE, expected 403"
    [ "$(hins "$infra" '{{.State.Running}}')" = "true" ] && ok "$infra still running (untouched)" \
                                                         || bad "$infra was disturbed - INVESTIGATE"
  done

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

  echo
  echo "WORKSPACE  (one tmpfs, ours, writable - and nothing else got writable)"
  # Positive control for the workspace: without this the "caller could not resize
  # it" results above would be true of a workspace that does not work at all.
  WSPROBE="${PREFIX}workspace-probe"
  docker rm -f "$WSPROBE" >/dev/null 2>&1 || true
  PROBE="echo ok > $WPATH/probe.txt 2>/dev/null && echo WORKSPACE_WRITABLE=yes || echo WORKSPACE_WRITABLE=no; echo x > /etc/p7-probe 2>/dev/null && echo ROOTFS_WRITABLE=yes || echo ROOTFS_WRITABLE=no; echo PWD=\$(pwd); grep -E ' $WPATH | /tmp ' /proc/mounts"
  disp_call POST "/spawn" "{\"name\":\"$WSPROBE\",\"cmd\":[\"sh\",\"-c\",\"$PROBE\"]}"
  if [ "$CODE" != "201" ]; then
    bad "workspace probe spawn returned $CODE ($BODY) - workspace claims below are void"
  else
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      [ "$(hins "$WSPROBE" '{{.State.Running}}')" = "false" ] && break; sleep 1
    done
    plog=$(docker logs "$WSPROBE" 2>&1 | tr -d '\000')
    printf '%s' "$plog" | grep -q 'WORKSPACE_WRITABLE=yes' \
      && ok "workspace $WPATH is writable by the worker user" \
      || bad "workspace $WPATH is NOT writable - the feature does not work"
    printf '%s' "$plog" | grep -q 'ROOTFS_WRITABLE=no' \
      && ok "rootfs outside the workspace is still read-only (/etc refused)" \
      || bad "ROOTFS IS WRITABLE - ReadonlyRootfs was lost"
    printf '%s' "$plog" | grep -q "PWD=$WPATH" \
      && ok "worker starts in the workspace (WorkingDir=$WPATH)" \
      || bad "worker cwd is not $WPATH"
    note "mounts seen from inside: $(printf '%s' "$plog" | grep -E "^tmpfs $WPATH|^tmpfs /tmp" | tr '\n' ' ')"
    tmn=$(dtmpfs "$WSPROBE" | wc -l | tr -d ' ')
    [ "$tmn" = "2" ] && ok "exactly two tmpfs mounts, both the dispatcher's (/tmp + $WPATH)" \
                     || bad "expected 2 tmpfs mounts, found $tmn: $(dtmpfs "$WSPROBE" | tr '\n' ' ')"
    dtmpfs "$WSPROBE" | grep -q "^$WPATH=size=$WSIZE," \
      && ok "workspace tmpfs sized from dispatcher config (size=$WSIZE)" \
      || bad "workspace tmpfs is $(dtmpfs "$WSPROBE" | grep "^$WPATH=")"
    dtmpfs "$WSPROBE" | grep -q "^/tmp=size=$TMPSIZE\$" \
      && ok "/tmp is still small (size=$TMPSIZE)" \
      || bad "/tmp is $(dtmpfs "$WSPROBE" | grep '^/tmp=') - expected size=$TMPSIZE"
    # A tmpfs is RAM, not a path on the host. The distinction is the whole point,
    # so assert there is still no bind or volume mount of any kind.
    mnt=$(hins "$WSPROBE" '{{range .Mounts}}{{.Type}}:{{.Source}} {{end}}')
    [ -z "$(printf '%s' "$mnt" | tr -d ' ')" ] \
      && ok "no bind or volume mounts at all (.Mounts empty)" \
      || bad "worker has host mounts: $mnt"
    docker rm -f "$WSPROBE" >/dev/null 2>&1 || true
  fi

  cleanup_workers
  docker rm -f "$BYSTANDER" >/dev/null 2>&1 || true

  suite_env_injection
}

########################################################################################
# ENV INJECTION - needs a configuration the composed dispatcher cannot hold at once
########################################################################################
# The requirements are:
#   * an allowlisted variable that IS set in the dispatcher must reach the worker,
#   * an allowlisted variable that is NOT set must be ABSENT rather than empty,
#   * a name on the dispatcher's reserved list must be refused even when the
#     operator asks for it,
# and one dispatcher cannot be in all three states for the same variable. So this
# section stands up its OWN dispatcher from the same p1-dispatcher.py, with a
# configuration chosen to make each case decidable, and tears it down. It is
# namespaced p7-* and labels its workers p7-scratch-worker so neither cleanup path
# can reach into the composed stack.
p7_down() {
  docker rm -f $(docker ps -aq --filter "name=^/${P7PREFIX}" 2>/dev/null) >/dev/null 2>&1
  docker rm -f "$P7DISP" >/dev/null 2>&1
}

p7_call() {  # METHOD PATH [BODY] [TOKEN|__NONE__]
  local m=$1 p=$2 b=${3:-} tok=${4-$P7TOKEN} args=()
  args=(-s -m 60 -w $'\nP1CODE:%{http_code}' -X "$m")
  [ "$tok" != "__NONE__" ] && args+=(-H "Authorization: Bearer $tok")
  [ -n "$b" ] && args+=(-H 'Content-Type: application/json' -d "$b")
  _run "${args[@]}" "http://$P7DISP:2375$p"
}

suite_env_injection() {
  echo
  echo "ENV INJECTION  (values from the dispatcher's own environment, never the request)"
  trap p7_down EXIT INT TERM
  p7_down
  P7TOKEN="p7-$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  P7SENTINEL="p7-sentinel-$$"
  # `-e NAME` with no value inherits from this shell: the credential is passed by
  # reference, so it never appears in argv where `ps` would show it.
  export GITHUB_TOKEN="${TARGET_REPO_TOKEN:-}"
  export TARGET_REPO="${TARGET_REPO:-}"
  docker run -d --name "$P7DISP" --network "$NET" \
    -v "$HERE_DIR/p1-dispatcher.py":/app/dispatcher.py:ro \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -e DISPATCH_TOKEN="$P7TOKEN" \
    -e WORKER_IMAGE="$WORKER_IMAGE" \
    -e WORKER_LABEL_KEY=role -e WORKER_LABEL_VALUE="$P7LABEL" \
    -e WORKER_NETWORK="$NET" -e WORKER_NAME_PREFIX="$P7PREFIX" \
    -e WORKER_MEMORY=536870912 \
    -e WORKER_WORK_PATH=/work -e WORKER_WORK_SIZE="$P7WORK_SIZE" \
    -e WORKER_ENV_ALLOWLIST="GITHUB_TOKEN,TARGET_REPO,P7_SET_ON_PURPOSE,$P7UNSET,DISPATCH_TOKEN,WORKER_IMAGE" \
    -e P7_SET_ON_PURPOSE="$P7SENTINEL" \
    -e GITHUB_TOKEN -e TARGET_REPO \
    -e PYTHONUNBUFFERED=1 -e PYTHONDONTWRITEBYTECODE=1 \
    --read-only --tmpfs /tmp:size=8m \
    --security-opt no-new-privileges --cap-drop ALL \
    -m 96m --pids-limit 64 --restart no \
    python:3-alpine python /app/dispatcher.py >/dev/null 2>&1

  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    p7_call GET "/healthz"; [ "$CODE" = "200" ] && break; sleep 1
  done
  if [ "$CODE" != "200" ]; then
    bad "scratch dispatcher $P7DISP did not come up ($CODE) - env-injection claims void"
    note "$(docker logs "$P7DISP" 2>&1 | tail -5 | scrub | tr '\n' ' ')"
    p7_down; return
  fi
  note "scratch dispatcher up: allowlist=GITHUB_TOKEN,TARGET_REPO,P7_SET_ON_PURPOSE,$P7UNSET,DISPATCH_TOKEN,WORKER_IMAGE"
  note "P7_SET_ON_PURPOSE is set in it; $P7UNSET deliberately is not; the last two are reserved names"

  # One worker, spawned with a body that also tries to override and add.
  W="${P7PREFIX}env"
  p7_call POST "/spawn" "{\"name\":\"$W\",\"cmd\":[\"sleep\",\"120\"],\"Env\":[\"P7_SET_ON_PURPOSE=attacker-controlled\",\"$P7UNSET=attacker-controlled\",\"DISPATCH_TOKEN=attacker-controlled\",\"EVIL_ADDED=1\"]}"
  SPAWN_BODY="$BODY"
  if [ "$CODE" != "201" ]; then
    bad "POSITIVE CONTROL FAILED: scratch spawn returned $CODE ($(printf '%s' "$BODY" | scrub)) - env claims void"
    p7_down; return
  fi
  ok "scratch dispatcher spawned a worker (201)"

  # POSITIVE CONTROL for the whole feature: a variable the dispatcher HAS reaches
  # the worker, with the dispatcher's value.
  [ "$(denv "$W" P7_SET_ON_PURPOSE)" = "$P7SENTINEL" ] \
    && ok "allowlisted variable that IS set reaches the worker with the dispatcher's value" \
    || bad "injection does not work: P7_SET_ON_PURPOSE is '$(denv "$W" P7_SET_ON_PURPOSE)', expected the dispatcher's value"
  # ... and the caller could not overwrite it, which is only a real test because
  # the variable is genuinely present.
  [ "$(eany "$W" P7_SET_ON_PURPOSE attacker-controlled)" = "no" ] \
    && ok "caller could not override a variable that IS injected" \
    || bad "CALLER OVERRODE AN INJECTED VARIABLE"
  # THE unset-vs-empty requirement.
  if [ "$(dhas "$W" "$P7UNSET")" = "no" ]; then
    ok "allowlisted-but-unset $P7UNSET is ABSENT from the worker (not present-and-empty)"
  else
    bad "$P7UNSET is present in the worker as '$(denv "$W" "$P7UNSET")' - should have been omitted"
  fi
  [ "$(dhas "$W" EVIL_ADDED)" = "no" ] \
    && ok "caller could not add a variable outside the allowlist (EVIL_ADDED absent)" \
    || bad "CALLER ADDED EVIL_ADDED"
  # Reserved names: refused by the dispatcher even though the operator listed them.
  # DISPATCH_TOKEN is the sharp one - a worker holding it could spawn more workers.
  [ "$(dhas "$W" DISPATCH_TOKEN)" = "no" ] \
    && ok "reserved DISPATCH_TOKEN refused by the allowlist (worker cannot spawn workers)" \
    || bad "WORKER HOLDS DISPATCH_TOKEN - privilege amplification"
  [ "$(dhas "$W" WORKER_IMAGE)" = "no" ] \
    && ok "reserved WORKER_* name refused by the allowlist (WORKER_IMAGE absent)" \
    || bad "worker holds WORKER_IMAGE - dispatcher control surface leaked"
  dlog=$(docker logs "$P7DISP" 2>&1)
  printf '%s' "$dlog" | grep -q "refusing to allowlist 'DISPATCH_TOKEN'" \
    && ok "dispatcher LOGGED the refused allowlist entry" \
    || bad "dispatcher silently dropped a refused allowlist entry"
  printf '%s' "$dlog" | grep -q "$P7UNSET is allowlisted but unset" \
    && ok "dispatcher LOGGED the omitted-because-unset variable" \
    || bad "dispatcher silently omitted an unset variable"
  printf '%s' "$dlog" | grep -q "env_injected=" \
    && ok "spawn log records injected variable NAMES (audit trail)" \
    || bad "no per-spawn env audit line in the dispatcher log"

  # --- credential handling: only meaningful with a real token configured ------
  if [ -z "${TARGET_REPO_TOKEN:-}" ] || [ -z "${TARGET_REPO:-}" ]; then
    note "TARGET_REPO/TARGET_REPO_TOKEN not in local.env - skipping the credential"
    note "and live-clone controls. Set them to exercise the full path."
  else
    [ "$(denv "$W" GITHUB_TOKEN)" = "$(denv "$P7DISP" GITHUB_TOKEN)" ] && [ "$(dhas "$W" GITHUB_TOKEN)" = "yes" ] \
      && ok "GITHUB_TOKEN injected from the dispatcher's own env (values compared, never printed)" \
      || bad "GITHUB_TOKEN did not reach the worker"
    [ "$(denv "$W" TARGET_REPO)" = "${TARGET_REPO}" ] \
      && ok "TARGET_REPO injected from the dispatcher's own env" \
      || bad "TARGET_REPO did not reach the worker"
    # The caller never sees the credential: not in the spawn response, not in any
    # other response, and not in the dispatcher's log.
    printf '%s' "$SPAWN_BODY" | grep -qF "$TARGET_REPO_TOKEN" \
      && bad "TOKEN ECHOED IN THE SPAWN RESPONSE" \
      || ok "token not echoed in the spawn response"
    p7_call POST "/spawn" '{"name":"bad name"}'; b1="$BODY"
    p7_call POST "/spawn" "{\"name\":\"${P7PREFIX}x\",\"cmd\":[\"badcmd\"]}"; b2="$BODY"
    p7_call GET "/healthz"; b3="$BODY"
    printf '%s%s%s' "$b1" "$b2" "$b3" | grep -qF "$TARGET_REPO_TOKEN" \
      && bad "TOKEN ECHOED IN AN ERROR/HEALTH RESPONSE" \
      || ok "token not echoed in error or health responses"
    printf '%s' "$dlog" | grep -qF "$TARGET_REPO_TOKEN" \
      && bad "TOKEN PRESENT IN THE DISPATCHER'S OWN LOG" \
      || ok "token absent from the dispatcher's log (names only)"
    # The spawn request itself never carried the credential: the worker's argv
    # holds the literal '$GITHUB_TOKEN', expanded only inside the container.
    CL="${P7PREFIX}clone"
    CLONE="set -e; cd /work; git clone --depth 1 https://x-access-token:\$GITHUB_TOKEN@github.com/\$TARGET_REPO repo >/dev/null 2>&1; echo CLONE_OK files=\$(find repo -type f | wc -l) kb=\$(du -sk repo | cut -f1); cd repo; git checkout -q -b p7-verify; git commit -q --allow-empty -m p7-verify && echo COMMIT_OK; echo WORKSPACE_FREE_KB=\$(df -k /work | tail -1 | awk '{print \$4}')"
    p7_call POST "/spawn" "{\"name\":\"$CL\",\"cmd\":[\"sh\",\"-c\",\"$CLONE\"]}"
    if [ "$CODE" != "201" ]; then
      bad "live-clone worker spawn returned $CODE ($(printf '%s' "$BODY" | scrub))"
    else
      hins "$CL" '{{json .Config.Cmd}}' | grep -qF "$TARGET_REPO_TOKEN" \
        && bad "THE CREDENTIAL IS IN THE WORKER'S ARGV - it came from the caller" \
        || ok "spawn request never carried the credential (argv holds \$GITHUB_TOKEN, not its value)"
      for _ in $(seq 1 60); do
        [ "$(hins "$CL" '{{.State.Running}}')" = "false" ] && break; sleep 2
      done
      clog=$(docker logs "$CL" 2>&1 | tr -d '\000')
      xc=$(hins "$CL" '{{.State.ExitCode}}')
      if printf '%s' "$clog" | grep -q 'CLONE_OK'; then
        ok "shallow git clone of the private target repo through the egress proxy SUCCEEDED"
        note "$(printf '%s' "$clog" | grep -E 'CLONE_OK|WORKSPACE_FREE_KB' | tr '\n' ' ' | scrub)"
      else
        bad "live clone failed (exit $xc): $(printf '%s' "$clog" | tail -2 | tr '\n' ' ' | scrub)"
      fi
      printf '%s' "$clog" | grep -q 'COMMIT_OK' \
        && ok "git can branch and commit inside the workspace (a worker can produce a PR branch)" \
        || bad "git could not commit in the workspace"
      printf '%s' "$clog" | grep -qF "$TARGET_REPO_TOKEN" \
        && bad "TOKEN LEAKED INTO THE WORKER'S LOG" \
        || ok "token absent from the worker's own log output"
    fi
  fi

  p7_down
  trap - EXIT INT TERM

  suite_status_mutation
}

########################################################################################
# MUTATION CONTROL for /status - widen the response and require the checks to notice
########################################################################################
# The /status assertions above are all of the form "this field is NOT in the
# body", and a verb that returned an empty object would satisfy every one of
# them. So: run a dispatcher whose /status hands back the whole inspect body -
# the exact thing an off-the-shelf socket proxy does, and the exact thing this
# interface exists to avoid - and require the checks to go red against it.
#
# It runs on its OWN scratch dispatcher, from a MUTATED COPY of p1-dispatcher.py
# in a temp directory. The committed file is never edited, so an interrupted run
# cannot leave a widened status verb behind on disk.
P8DISP=p8-mutant-dispatcher
P8PREFIX=p8-w-
P8LABEL=p8-scratch-worker

p8_down() {
  docker rm -f $(docker ps -aq --filter "name=^/${P8PREFIX}" 2>/dev/null) >/dev/null 2>&1
  docker rm -f "$P8DISP" >/dev/null 2>&1
  [ -n "${P8DIR:-}" ] && rm -rf "$P8DIR"
}

p8_call() {  # METHOD PATH [BODY]
  local m=$1 p=$2 b=${3:-} args=()
  args=(-s -m 30 -w $'\nP1CODE:%{http_code}' -X "$m" -H "Authorization: Bearer $P8TOKEN")
  [ -n "$b" ] && args+=(-H 'Content-Type: application/json' -d "$b")
  _run "${args[@]}" "http://$P8DISP:2375$p"
}

suite_status_mutation() {
  echo
  echo "MUTATION CONTROL  (/status widened to return the inspect body must be CAUGHT)"
  trap p8_down EXIT INT TERM
  p8_down
  P8DIR="$(mktemp -d "${TMPDIR:-/tmp}/p8-mutant.XXXXXX")"
  P8TOKEN="p8-$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"

  # The mutation: answer with everything Docker knows, and neuter the guard that
  # is supposed to stop exactly that.
  python3 - "$HERE_DIR/p1-dispatcher.py" "$P8DIR/dispatcher.py" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
needle = """    body = {
        "name": name,
        "exists": True,
        "running": running,
        "exit_code": None if running else state.get("ExitCode"),
    }"""
if needle not in text:
    sys.exit("MUTATION-TARGET-MISSING: the status response body has changed shape")
text = text.replace(needle, """    body = dict(info)
    body.update({"name": name, "exists": True, "running": running,
                 "exit_code": None if running else state.get("ExitCode")})""")
# ...and disable the drift guard, so the mutation is not caught by the code
# itself. What is under test is the HARNESS.
text = text.replace('    if set(body) != set(STATUS_FIELDS):',
                    '    if False:')
open(dst, "w").write(text)
PY
  if [ $? -ne 0 ] || [ ! -s "$P8DIR/dispatcher.py" ]; then
    bad "could not build the mutant - p1-dispatcher.py's status body has changed shape; update the mutation"
    p8_down; trap - EXIT INT TERM; return
  fi
  ok "mutant built in a temp dir (the committed p1-dispatcher.py is untouched)"

  export GITHUB_TOKEN="${TARGET_REPO_TOKEN:-}"
  docker run -d --name "$P8DISP" --network "$NET" \
    -v "$P8DIR/dispatcher.py":/app/dispatcher.py:ro \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -e DISPATCH_TOKEN="$P8TOKEN" \
    -e WORKER_IMAGE="$WORKER_IMAGE" \
    -e WORKER_LABEL_KEY=role -e WORKER_LABEL_VALUE="$P8LABEL" \
    -e WORKER_NETWORK="$NET" -e WORKER_NAME_PREFIX="$P8PREFIX" \
    -e WORKER_MEMORY=268435456 \
    -e WORKER_WORK_PATH=/work -e WORKER_WORK_SIZE=64m \
    -e WORKER_ENV_ALLOWLIST="GITHUB_TOKEN" -e GITHUB_TOKEN \
    -e PYTHONUNBUFFERED=1 -e PYTHONDONTWRITEBYTECODE=1 \
    --read-only --tmpfs /tmp:size=8m \
    --security-opt no-new-privileges --cap-drop ALL \
    -m 96m --pids-limit 64 --restart no \
    python:3-alpine python /app/dispatcher.py >/dev/null 2>&1
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    p8_call GET "/healthz"; [ "$CODE" = "200" ] && break; sleep 1
  done
  if [ "$CODE" != "200" ]; then
    bad "the mutant dispatcher did not come up ($CODE) - the mutation control proves nothing"
    note "$(docker logs "$P8DISP" 2>&1 | tail -5 | scrub | tr '\n' ' ')"
    p8_down; trap - EXIT INT TERM; return
  fi

  P8W="${P8PREFIX}probe"
  p8_call POST "/spawn" "{\"name\":\"$P8W\",\"cmd\":[\"sleep\",\"60\"]}"
  if [ "$CODE" != "201" ]; then
    bad "the mutant could not spawn a probe worker ($CODE) - the mutation control proves nothing"
    p8_down; trap - EXIT INT TERM; return
  fi
  p8_call POST "/status" "{\"name\":\"$P8W\"}"
  MUT_BODY="$BODY"

  # Now run the SAME three assertions the real suite makes, and require each to
  # come out the other way. A mutation nobody's check can see is a check nobody
  # needs.
  MUT_KEYS=$(printf '%s' "$MUT_BODY" | python3 -c 'import json,sys
try: print(",".join(sorted(json.loads(sys.stdin.read()))))
except Exception: print("PARSE-ERROR")')
  [ "$MUT_KEYS" = "exists,exit_code,name,running" ] \
    && bad "the widened response still looks like four fields - the field check cannot see this mutation" \
    || ok "the field-set check goes RED against the mutant (it sees $(printf '%s' "$MUT_KEYS" | tr ',' ' ' | wc -w | tr -d ' ') keys)"
  printf '%s' "$MUT_BODY" | grep -qiE '"(env|mounts|config|hostconfig|image|networksettings|args|path)"' \
    && ok "the env/mounts/config check goes RED against the mutant" \
    || bad "the widened response exposed no recognisable field - the leak check cannot see this mutation"
  if [ -n "${TARGET_REPO_TOKEN:-}" ]; then
    printf '%s' "$MUT_BODY" | grep -qF -- "$TARGET_REPO_TOKEN" \
      && ok "and the token-oracle check goes RED: the credential IS readable through the mutant" \
      || bad "the mutant leaked the config but not the credential - the token check is untested by it"
  fi

  p8_down
  trap - EXIT INT TERM
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

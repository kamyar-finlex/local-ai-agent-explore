# The composed stack

Four investigations produced four setup scripts — a model-only sandbox, an egress
sandbox, a spawn-dispatcher rig, and a preflight-checked launcher. Each stood alone,
each created its own network, and two of them ran a byte-identical copy of the same
nginx gate. `docker-compose.yml` is all of it as one topology.

```
                       hermes-isolated  (internal: true - no gateway, no route, no DNS)
   ┌──────────────────────────────────────────────────────────────────────┐
   │                                                                      │
   │   hermes (orchestrator)        hermes-dispatcher                     │
   │   cap-drop ALL + 5 caps        owns /var/run/docker.sock             │
   │   NO docker socket             3 verbs, bearer token                 │
   │   HTTPS_PROXY set                     │ builds every create body     │
   │        │            │                 ▼ itself, from a template      │
   │        │            │           hermes-worker-*  (spawned at runtime)│
   │        │            │           cap-drop ALL · read-only · 512 MiB   │
   └────────┼────────────┼─────────────────────────────────────────────────┘
            │            │
            ▼            ▼
   ┌─────────────────┐  ┌────────────────────────┐
   │ ollama-gate     │  │ hermes-egress-proxy    │   both also on hermes-egress
   │ nginx           │  │ squid                  │   read-only rootfs
   │ PATH allowlist  │  │ DOMAIN allowlist       │   ip_forward=0
   │ plaintext HTTP  │  │ CONNECT only, 443 only │   cap-drop ALL + 4 caps
   └────────┬────────┘  └───────────┬────────────┘
            ▼                       ▼
   Ollama on the host       github.com · api.github.com
   (127.0.0.1:11434)
```

Two gates, two mechanisms, one boundary. The `--internal` network is why either
matters: nothing on it has a route anywhere, so the two dual-homed gateways are the
only ways out and each filters by the only thing it can see.

## Up and down

```bash
cp local.env.example local.env          # then set DISPATCH_TOKEN in it
docker compose --profile images build   # builds the proxy and worker images
./run-hermes.sh                         # up + attach to the orchestrator
```

`run-hermes.sh` is a thin wrapper. It exists for the two things a compose file cannot
do itself: source `local.env` (gitignored, machine-specific) and size the
orchestrator's memory cap against the **live** Docker VM. Everything else is compose.

To drive compose directly, export the environment first:

```bash
set -a; . ./local.env; set +a
docker compose up -d          # bring up; preflight gates the orchestrator
docker compose ps
docker attach hermes          # detach with Ctrl-P Ctrl-Q
docker compose logs -f egress-proxy   # the audit trail: every destination attempted
docker compose down           # stop and remove containers and networks
docker compose down --rmi local       # also remove the two locally built images
```

`docker compose up` starts the gateways and the dispatcher, waits for all three to be
healthy, then runs **`preflight`**. The orchestrator declares
`depends_on: {preflight: {condition: service_completed_successfully}}`, so if preflight
exits non-zero the orchestrator never starts:

```
preflight:
  ok: model gate reachable (/api/tags -> 200)
  ok: gate denies /api/pull (403)
  ok: gate default-denies unknown paths (403)
  ok: no direct route to the internet (1.1.1.1 unreachable)
  ok: no outbound DNS and no direct route (example.com unreachable)
  ok: egress proxy listening (answered 400 to a non-proxy request)
  ok: spawn dispatcher healthy (/healthz -> 200)
  preflight OK: no route out, gate allowlist intact, both holes up.
```

That it can actually fail was checked rather than assumed — pointed at a gate that does
not exist, it refuses and exits 1:

```
$ docker run --rm --network hermes-isolated -e GATE_HOST=no-such-gate \
    -v "$PWD/stack-preflight.sh:/preflight.sh:ro" curlimages/curl:latest sh /preflight.sh
preflight:
  REFUSING TO LAUNCH: gate no-such-gate did not serve /api/tags (got 000); ...
exit=1
```

## Verifying it

```bash
./verify-sandbox.sh              # 56 passed, 0 failed
./verify-egress.sh               # 45 passed, 0 failed  (46 with MODEL_CHAT=1)
./verify-spawning.sh dispatcher  # 68 passed, 0 failed
```

## What changed in the translation

### Preserved exactly

Every property that was a `docker run` flag is now a compose key, and
`verify-sandbox.sh` grew a **COMPOSE TRANSLATION** section that asserts each one on the
running container rather than trusting the YAML. Translating a sandbox is precisely the
moment a flag goes missing silently.

| `docker run` flag | compose key | Verified by |
|---|---|---|
| `docker network create --internal` | `networks.isolated.internal: true` | preflight (no route to 1.1.1.1 from inside), `verify-sandbox.sh`, `verify-egress.sh` |
| `--cap-drop ALL` + 5 `--cap-add` | `cap_drop: [ALL]` / `cap_add: [...]` | exact-set check: `CapDrop=[ALL]`, `CapAdd=CAP_CHOWN CAP_DAC_OVERRIDE CAP_FOWNER CAP_SETGID CAP_SETUID` |
| `--security-opt no-new-privileges` | `security_opt: ["no-new-privileges:true"]` | asserted on orchestrator, both gateways and the dispatcher |
| `--read-only` | `read_only: true` | asserted on both gateways and the dispatcher |
| `--sysctl net.ipv4.ip_forward=0` | `sysctls: ["net.ipv4.ip_forward=0"]` | read from `/proc` inside both gateways |
| `--tmpfs ...` | `tmpfs: [...]` | asserted present on the orchestrator and both gateways |
| `--memory` / `--cpus` / `--pids-limit` | `mem_limit` / `cpus` / `pids_limit` | asserted **non-zero** — an unset compose key inspects as `0`, which means *no limit* and is easy to mistake for one |
| no `-v /var/run/docker.sock` | absent from `hermes` | asserted absent on the orchestrator and both gateways; asserted **present** on the dispatcher, which is the one component that may hold it |

The capability note is worth repeating because it is counter-intuitive: a bare
`cap_drop: [ALL]` **breaks** the orchestrator image. s6-overlay drops privileges during
init and dies with `s6-applyuidgid: fatal: unable to set supplementary group list`. The
five capabilities are the minimum s6 needs, and none of them is `NET_ADMIN`, so the
container still cannot install a route out.

### Changed deliberately

**One nginx gate instead of two.** `setup-egress.sh` ran `p2-model-gate` with a
byte-identical copy of `ollama-gate.conf` beside the original `ollama-gate`. There is
now one gate on both networks. Two copies of one policy is a divergence waiting to
happen.

**The preflight moved into the stack.** It used to be shell in `run-hermes.sh`, which
only ran if you used that launcher. It is now a compose service the orchestrator
depends on, so starting the stack any other way still runs it. It also became stronger:
it runs *inside* the isolated network with no Docker socket, so it tests reachability
("there is no route to 1.1.1.1") instead of inspecting configuration
(`Internal == true`).

**The squid client ACL is committed, not generated.** `setup-egress.sh` read the live
network's subnet and wrote `agent-net.conf` at setup time. Compose has no such step, so
the isolated network's subnet is **pinned** (`172.31.0.0/24`) and the ACL lives in
`egress-agent-net.conf`. That trades a generation step for a drift risk, so
`verify-egress.sh` gained a check that the two agree — a stale subnet there would
either deny everything, or, if that subnet were later reused, hand out an open proxy.

**Healthchecks use `netstat`, not `nc -z`.** The obvious `nc -z 127.0.0.1 3128` probe
opens a connection every five seconds, and squid dutifully logs each one as
`error:transaction-end-before-headers`. That log **is** the audit trail, on an 8 MiB
tmpfs. Checking the listener with `netstat` instead measures the same thing without
writing to the evidence.

**The dispatcher's log is unbuffered.** `PYTHONUNBUFFERED=1` — without it the
dispatcher's per-request log sits in a stdio buffer and `docker logs` shows nothing.
Same failure mode as the unprivileged squid that could not write to Docker's root-owned
stdout: the process runs, the audit trail is silently absent.

**The proxy's memory cap went 192m → 256m.** Measured: squid's RSS is ~166 MiB
steady-state, which is 81% of the old cap with no room for a burst. An OOM-killed proxy
takes the egress path down mid-push.

**The worker image carries the proxy wiring.** The dispatcher builds every
container-create body from a fixed template — that is exactly what makes it safe — and
that template has no `Env` key, so a spawned worker inherits nothing from its caller.
Without proxy variables a worker can reach the model gate (plaintext, direct) but has no
idea the egress proxy exists, and every `git push` fails with a DNS error. The variables
are therefore baked into `egress-probe.Dockerfile`. This is wiring, not a control: a
worker that ignores them still has no route anywhere.

### Not composed, on purpose

**The rejected socket proxy.** `verify-spawning.sh proxy` measures
`tecnativa/docker-socket-proxy`, which the harness shows accepting a host-root bind
mount, `Privileged: true`, `NetworkMode: host`, `PidMode: host` and a re-mounted Docker
socket (8 passed, 10 failed — unchanged after this consolidation). Composing a mechanism
the harness proves unsafe would be the wrong artifact to ship, so it stays on the
standalone `p1-*` rig: `./p1-spawn-setup.sh`, run the suite, `./p1-spawn-teardown.sh`.
The suite is kept because the exploit is the evidence for the decision.

**The `p2-*` probe container.** `verify-egress.sh` used a long-lived `p2-agent`
stand-in. It now runs its probes inside the **real orchestrator container**, which has
`git`, `curl` and `python3`. That removes an inferential step rather than adding one.

## Resource reality

Measured on a Docker VM with **7 836 MiB** of RAM. Two numbers matter and they are very
different: what the stack *commits* (the caps the VM must be able to honour) and what it
*uses*.

| Component | Cap | Measured, at rest | Measured, 3 workers cloning |
|---|---|---|---|
| `hermes` (orchestrator) | 2 GiB default, 4 365 MiB when `run-hermes.sh` sizes it to this VM | 303 MiB | 303 MiB |
| `ollama-gate` | 128 MiB | 10.7 MiB | 10.7 MiB |
| `hermes-egress-proxy` | 256 MiB | 155 MiB | 155 MiB |
| `hermes-dispatcher` | 96 MiB | 12.2 MiB | 12.2 MiB |
| 3 × `hermes-worker-*` | 3 × 512 MiB | — | 0.8 MiB each |
| **Total** | **6 381 MiB committed** | **481 MiB** | **483 MiB** |

`verify-sandbox.sh` asserts the committed total fits the VM, because per-container caps
that each fit individually can still not fit together — that failure only becomes
possible once everything shares one VM.

**It fits, with two caveats worth stating rather than hiding.**

1. **It fits the VM, not the VM as actually used.** On the machine this was measured on,
   ~4.4 GiB of the 7 836 MiB was already committed to unrelated containers (a local
   service stack and a Kubernetes control plane), leaving ~2.2 GiB available. The
   stack's 6 381 MiB of caps therefore closes against VM *total* and not against VM
   *free*. Actual use is 483 MiB, so nothing is in danger today — but if the
   orchestrator ever grew into its cap while three workers grew into theirs, this VM
   would OOM. Either shrink `HERMES_MEM_LIMIT` or do not share the VM.
2. **Idle workers measure almost nothing.** 0.8 MiB is a container running `sleep` with
   a shallow clone in an 8 MiB tmpfs. A worker running a real build would approach its
   512 MiB cap, and the committed figure is the one to plan with.

**Disk:** the two locally built images are ~21 MB (squid) and ~67 MB (worker), about
0.2 GB of the VM's 12.1 GiB free. `docker compose down --rmi local` reclaims it.

### A limit the fixed worker template imposes

The dispatcher's template gives each worker `ReadonlyRootfs: true` and a **`/tmp` of
8 MiB**. That is ample for the shallow clone the harness does and nowhere near enough
for a real repository, so a worker cannot currently check out anything of size. The
template is in `p1-dispatcher.py` and is deliberately not caller-controllable, which is
the property that makes the dispatcher safe; changing the tmpfs size means changing that
file, not the request.

## Files

| File | Purpose |
|---|---|
| `docker-compose.yml` | The whole stack: networks, gateways, dispatcher, preflight, orchestrator |
| `stack-preflight.sh` | Refuses to let the orchestrator start into a cage that is not closed |
| `egress-agent-net.conf` | squid's client ACL — must match the pinned subnet in the compose file |
| `run-hermes.sh` | Wrapper: sources `local.env`, sizes the memory cap to the live VM, `up` + attach |
| `local.env.example` | Machine-specific values, including `DISPATCH_TOKEN`. Copy to `local.env` |

Superseded by `docker-compose.yml`, kept because the documents cite them:
`setup-sandbox.sh`, `setup-egress.sh`, `p1-spawn-setup.sh` / `p1-spawn-teardown.sh`.
The `p1-*` pair is still needed to run the rejected-option comparison suite.

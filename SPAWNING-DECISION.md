# TECH-98 — safe container spawning for an untrusted orchestrator

The orchestrator (`hermes`) must spawn and stop worker containers. The obvious
way — bind-mounting `/var/run/docker.sock` into it — hands it effective root on
the host and cancels the point of containerising it. This document records which
of the four candidate mechanisms was chosen, and the **measured** evidence for
rejecting the others. Every figure below is captured output from
`verify-spawning.sh`, not a summary written from memory.

## Decision

**Option (d): a thin, body-validating dispatcher that owns the Docker socket
behind a narrow, authenticated, verb-based interface.**

Option (a), an off-the-shelf path-filtering socket proxy, was prototyped first
and **broken**. It is security theatre for this threat model. The evidence is
below.

## The candidates

| | Mechanism | Verdict |
|---|---|---|
| (a) | Docker socket proxy (tecnativa/docker-socket-proxy), scoped to labelled containers | **Rejected — does not scope by label or body; see below** |
| (b) | Rootless Docker | Rejected — see rationale |
| (c) | Docker-in-Docker (DinD) | Rejected — see rationale |
| (d) | Thin host dispatcher behind a narrow authenticated interface | **Chosen** |

## The hypothesis under test — CONFIRMED

> Most off-the-shelf socket proxies filter by API **endpoint**, not by request
> **body**. If `POST /containers/create` is permitted at all, a caller can still
> pass arbitrary `HostConfig.Binds`, `Privileged: true`, `NetworkMode: host`, or
> `PidMode: host` — making the proxy a Docker socket mount with extra steps.

Confirmed, mechanically and end to end. tecnativa/docker-socket-proxy is an
HAProxy whose entire rule set matches on `path` and method (`GET` vs `POST`).
Its config template contains exactly one rule relevant to spawning:

```
http-request allow if { path,url_dec -m reg -i ^(/v[\d\.]+)?/containers } { env(CONTAINERS) -m bool }
```

There is **no rule that inspects the request body**. To let the orchestrator
create/start/stop/remove workers at all, you must set `CONTAINERS=1` and
`POST=1` — and that single grant blesses *every* `POST /containers/create` body,
whatever it contains. The proxy cannot tell a benign `sleep` worker from one that
bind-mounts `/`.

### Measured — `./verify-spawning.sh proxy` (exit 1)

```
POSITIVE CONTROL  (the mechanism MUST be able to spawn a labelled worker)
  PASS  create labelled worker (201)
  PASS  start worker (204)
  PASS  stop worker (204)
  PASS  remove worker (204)

BODY-VALIDATION  (the crux: does it inspect the create BODY, or only the path?)
  FAIL  host-root bind mount ACCEPTED (201) and the worker read the host FS
        evidence from inside the spawned container: VM_HOSTNAME=debuerreotype HOST_HOME_DIRS=
  FAIL  Privileged:true ACCEPTED (201)
  FAIL  NetworkMode:host ACCEPTED (201)
  FAIL  PidMode:host ACCEPTED (201)
  FAIL  docker.sock bind ACCEPTED (201) - a worker could re-mount the socket

LABEL SCOPING  (can it touch containers it was never meant to?)
  FAIL  stopped UNRELATED non-worker container (p1-bystander) - no label scoping
  FAIL  removed UNRELATED non-worker container (p1-bystander) - no label scoping
  FAIL  can INSPECT unrelated container 'hermes' (200) - full read of others' config
  FAIL  full container INVENTORY disclosed (200) - lists hermes/ollama-gate/etc

CATEGORY LIMITS  (what the path filter DOES still block - to be fair)
  PASS  exec START blocked (403, EXEC=0)
  PASS  image list blocked (403, IMAGES=0)
  PASS  image build blocked (403, BUILD=0)
  PASS  daemon /info blocked (403, INFO=0)

RESULT (proxy): 8 passed, 9 failed
```

The flagship line is the first FAIL. A container was **created and started
entirely through the proxy** with `HostConfig.Binds: ["/:/host:ro"]`, and it read
the host's `/etc/hostname` — `debuerreotype`, the Docker Desktop Linux VM. On
Docker Desktop for macOS the daemon's `/` is the VM root, so this is host-VM
filesystem access; with a read-write bind and the VM's mounted macOS paths it is
a straightforward pivot to the developer's files. The `docker.sock` bind being
accepted is the escalation clincher: a worker can be handed the socket the proxy
was supposed to be protecting.

**What the path filter *does* still buy you** (shown for fairness): with the other
capability flags left at their secure default of `0`, whole endpoint *categories*
are blocked — image pull/build/list, daemon `/info`, and the `/exec/{id}/start`
step. So the proxy is not *nothing*; it is a coarse category firewall. But the
one category you are forced to open — container create — is the one that contains
the entire attack surface. Two caveats even within that "win" column:

- **`POST /containers/{id}/exec` (exec *create*) matches the `/containers` ACL and
  is allowed.** Only `POST /exec/{id}/start` is blocked (by `EXEC=0`), so exec is
  inert, but the surface is not clean — it depends on a second flag staying shut.
- **The full container inventory leaks** via `GET /containers/json` (it lists
  `hermes`, `ollama-gate`, everything), because reads to `/containers` are the
  same ACL as the writes you need.

### Measured — `./verify-spawning.sh dispatcher` (exit 0)

The chosen mechanism passes the identical battery. The smuggling test sends a
`/spawn` body stuffed with `HostConfig.Binds`, `Privileged`, `NetworkMode:host`,
`PidMode:host`, `CapAdd:["ALL"]` and `image:"mongo:7"`, then inspects the
resulting container from the host to prove none of it took effect:

```
POSITIVE CONTROL  (the mechanism MUST be able to spawn/stop/remove a worker)
  PASS  spawn worker (201)
  PASS  worker is actually running
  PASS  worker carries role=hermes-worker
  PASS  stop worker (200)
  PASS  remove worker (200)

BODY-VALIDATION  (smuggled HostConfig must never reach Docker)
  PASS  no host bind mounts (Binds=[])
  PASS  not privileged (Privileged=false)
  PASS  network not host (NetworkMode=p1-spawn-net)
  PASS  pid ns not host (PidMode='<empty>')
  PASS  image forced to alpine:latest (not caller's mongo:7)

AUTHENTICATION
  PASS  no token rejected (401)
  PASS  bad token rejected (401)

LABEL SCOPING  (must refuse containers it does not own)
  PASS  refused to stop unrelated container p1-bystander (403)
  PASS  p1-bystander left running (untouched)
  PASS  refused to remove unrelated container p1-bystander (403)
  PASS  refused to stop the real 'hermes' container (403)
  PASS  hermes still running (guard did not disturb it)

SURFACE  (no raw Docker API, no exec/build/inventory)
  PASS  no raw /containers/create passthrough (404)
  PASS  no exec surface (404)
  PASS  no build surface (404)
  PASS  no inventory disclosure (404)

RESULT (dispatcher): 21 passed, 0 failed
```

## Why (d) works where (a) cannot

The proxy's flaw is structural, not a misconfiguration: it forwards a
caller-supplied create body to Docker. No amount of flag-tuning fixes that,
because there is no flag for "inspect the body." The dispatcher inverts the trust
boundary:

- **The caller never supplies a create body.** It POSTs a name and an optional
  command from a small allowlist. The dispatcher **constructs** every
  `/containers/create` body itself, from a fixed hardened template
  (`p1-dispatcher.py`, `spawn()`). There is no code path by which `Binds`,
  `Privileged`, `NetworkMode`, `PidMode`, `Devices`, or `CapAdd` can be set by a
  request — the fields simply are not read.
- **Destructive verbs are label-scoped.** `stop`/`remove` first `GET` the target
  and refuse (403) anything not carrying `role=hermes-worker`. That is why
  pointing `/stop` at `hermes` is refused with the real `hermes` left running.
- **The surface is three verbs.** No raw Docker API, no `exec`, no `build`, no
  inventory read — all 404. Contrast the proxy, which exposes the whole
  `/containers` tree including reads of every other container.
- **It enforces *more* than the proxy ever could.** Because it owns the template,
  every worker is created with `CapDrop:["ALL"]`, `no-new-privileges`, a memory
  cap, `ReadonlyRootfs`, and a pinned network. A proxy cannot *impose* hardening;
  it can only permit or deny a body it does not read.

## Why (b) and (c) were rejected without a full prototype

- **(b) Rootless Docker** solves a *different* problem. It reduces the blast
  radius of a daemon compromise by running dockerd as a non-root user — worth
  doing on its own merits — but it does **nothing** about the body-validation gap.
  A rootless daemon still honours `HostConfig.Binds` and `Privileged` for
  whatever can reach its socket; the orchestrator would still need a *body-aware*
  broker in front of it. It is complementary to (d), not a substitute, and on
  Docker Desktop for macOS the daemon already runs inside the VM, so the
  incremental host-safety gain here is small. Rejected as a solution to *this*
  ticket; reconsider as defence-in-depth under the dispatcher.

- **(c) Docker-in-Docker** gives the orchestrator its *own* daemon inside a
  privileged container. That privileged container is itself the escape vector
  (`--privileged` DinD is a well-known host-breakout primitive), it double-taxes
  the VM's ~7.65 GiB RAM / ~12 GB disk by running a second daemon and duplicating
  the image cache, and it *still* leaves the orchestrator able to craft arbitrary
  create bodies against its inner daemon. It trades a socket mount for a
  privileged container and buys no body validation. Rejected.

## Residual risk with the dispatcher

Honest limits of the chosen design:

- **The dispatcher is now the crown jewel.** It owns the real socket. A bug in
  *its* body construction or label check is a full-host issue. Mitigation: it is
  ~230 lines of stdlib Python with no request-controlled `HostConfig`, no
  dependencies to audit, and it runs with `no-new-privileges` and its own caps
  dropped. Keep it small and review every change to `spawn()`.
- **Bearer token, not mutual auth.** Anyone who can reach the dispatcher's port
  *and* holds the token gets worker spawn rights. Here the token is a PoC
  placeholder in the container env (same spirit as this repo's `api_key=ollama`).
  In production, inject it from a secret and put the dispatcher on a dedicated
  network only the orchestrator joins.
- **Worker breakout is a separate boundary.** The dispatcher guarantees workers
  are *created* unprivileged and un-mounted; it does not by itself confine what a
  running worker can reach on the network. Pair it with the `--internal` network
  cage from the sibling PoC (`setup-sandbox.sh`) for egress control.
- **Command allowlist is coarse.** `spawn` accepts a small command allowlist
  (`sleep`, `sh`, `cat`, …). `sh` is on it for realistic workers; a worker that
  runs `sh` can do whatever its dropped-capability, read-only, isolated-network
  container permits — which is the point of the *other* boundaries, not this one.
- **Availability, not just safety.** The dispatcher is a single point of failure
  for spawning. That is acceptable: failing closed (no spawn) is the safe mode.

## Reproduce

```bash
./p1-spawn-setup.sh               # brings up option (a) proxy AND option (d) dispatcher, p1-* namespaced
./verify-spawning.sh proxy        # option (a): 8 passed, 9 failed, exit 1  (security theatre)
./verify-spawning.sh dispatcher   # option (d): 21 passed, 0 failed, exit 0 (recommended)
./p1-spawn-teardown.sh            # removes every p1-* container + network
```

The rig is namespaced entirely under `p1-` and never touches `hermes`,
`ollama-gate`, or the `hermes-isolated` network. `p1-bystander` is a deliberately
unrelated, unlabelled container used as the "container I don't own" target so the
destructive tests never point at anything real (the single test that points
`/stop` at the real `hermes` only triggers a read-only label check and asserts
`hermes` stays up).

## Files

| File | Purpose |
|---|---|
| `p1-spawn-setup.sh` | Brings up both candidate mechanisms, `p1-*` namespaced |
| `p1-dispatcher.py` | Option (d): the body-validating dispatcher (stdlib only) |
| `verify-spawning.sh` | Adversarial harness; `proxy` \| `dispatcher`; PASS/FAIL + non-zero exit |
| `p1-spawn-teardown.sh` | Removes every `p1-*` container and the rig network |

## Environment

| | |
|---|---|
| Host | Docker Desktop on macOS (Apple Silicon), VM ~7.65 GiB RAM / ~12 GB disk |
| Proxy | `tecnativa/docker-socket-proxy` (HAProxy 3.4.2), `CONTAINERS=1 POST=1` |
| Dispatcher | `python:3-alpine`, stdlib `http.server` |
| Worker/probe images | `alpine:latest`, `curlimages/curl:latest` (kept small per the VM budget) |

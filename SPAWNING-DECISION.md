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
  FAIL  CREDENTIAL DISCLOSED: read DISPATCH_TOKEN out of another container's .Config.Env (200)

CATEGORY LIMITS  (what the path filter DOES still block - to be fair)
  PASS  exec START blocked (403, EXEC=0)
  PASS  image list blocked (403, IMAGES=0)
  PASS  image build blocked (403, BUILD=0)
  PASS  daemon /info blocked (403, INFO=0)

RESULT (proxy): 8 passed, 10 failed
```

The tenth failure was added once the dispatcher started injecting credentials into
workers (see "What a worker gets" below). Container environments are readable
through `GET /containers/{id}/json`, and the proxy's `/containers` ACL covers
reads as well as writes — so the same grant that lets the caller spawn a worker
lets it lift the bearer token straight out of another container's `.Config.Env`.
A mechanism that hands out credentials cannot also hand out an inspect surface.

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

The chosen mechanism passes the identical battery, plus everything the
credential-and-workspace change below added. The smuggling test sends one
`/spawn` body stuffed with `HostConfig.Binds`, `Privileged`, `NetworkMode:host`,
`PidMode:host`, `CapAdd:["ALL"]`, `ReadonlyRootfs:false`, `image:"mongo:7"`, an
`Env` array (three spellings), a `Tmpfs` map and a `WorkingDir`, then inspects the
resulting container from the host to prove none of it took effect:

```
POSITIVE CONTROL  (the mechanism MUST be able to spawn/stop/remove a worker)
  PASS  spawn worker (201)
  PASS  worker is actually running
  PASS  worker carries role=hermes-worker
  PASS  worker created with cap_drop ALL
  PASS  worker rootfs read-only
  PASS  worker memory capped (512 MiB)
  PASS  worker joined hermes-isolated (no route out except the two gates)
  PASS  stop worker (200)
  PASS  remove worker (200)

BODY-VALIDATION  (smuggled HostConfig, Env and Tmpfs must never reach Docker)
  PASS  no host bind mounts (Binds=[])
  PASS  not privileged (Privileged=false)
  PASS  network not host (NetworkMode=hermes-isolated)
  PASS  pid ns not host (PidMode='<empty>')
  PASS  image forced to hermes-worker:latest (not caller's mongo:7)
  PASS  rootfs still read-only (caller's ReadonlyRootfs:false ignored)
  PASS  caller-supplied Env had no effect (EVIL_INJECTED absent from the worker)
  PASS  caller-supplied Env had no effect (EVIL_LOWERCASE absent from the worker)
  PASS  caller-supplied Env had no effect (EVIL_COMPOSE_STYLE absent from the worker)
  PASS  caller-supplied Env had no effect (LD_PRELOAD absent from the worker)
  PASS  caller could not override PATH (still the image's)
  PASS  caller could not override GITHUB_TOKEN (worker holds the dispatcher's value)
  PASS  caller could not override TARGET_REPO (worker holds the dispatcher's value)
  PASS  no duplicated variable names (15 of 15) - nothing was merged in
  PASS  worker env is image-baked + allowlist only (no extra names)
  PASS  caller could not rename/add a workspace path (Tmpfs: /tmp=size=8m /work=size=384m,mode=1777,exec)
  PASS  caller could not change a tmpfs size (still size=384m / 8m)
  PASS  WorkingDir is the dispatcher's /work (not caller's /attacker)

AUTHENTICATION
  PASS  no token rejected (401)
  PASS  bad token rejected (401)

LABEL SCOPING  (must refuse containers it does not own)
  PASS  refused to stop unrelated container hermes-worker-NOT-a-worker-bystander (403)
  PASS  hermes-worker-NOT-a-worker-bystander left running (untouched)
  PASS  refused to remove unrelated container hermes-worker-NOT-a-worker-bystander (403)
  PASS  refused to stop the real 'hermes' container (403)
  PASS  hermes still running (guard did not disturb it)
  PASS  refused to stop stack component ollama-gate (403)
  PASS  ollama-gate still running (untouched)
  PASS  refused to stop stack component hermes-egress-proxy (403)
  PASS  hermes-egress-proxy still running (untouched)

SURFACE  (no raw Docker API, no exec/build/inventory)
  PASS  no raw /containers/create passthrough (404)
  PASS  no exec surface (404)
  PASS  no build surface (404)
  PASS  no inventory disclosure (404)

WORKSPACE  (one tmpfs, ours, writable - and nothing else got writable)
  PASS  workspace /work is writable by the worker user
  PASS  rootfs outside the workspace is still read-only (/etc refused)
  PASS  worker starts in the workspace (WorkingDir=/work)
        mounts seen from inside: tmpfs /tmp tmpfs rw,nosuid,nodev,noexec,relatime,size=8192k 0 0 tmpfs /work tmpfs rw,nosuid,nodev,relatime,size=393216k 0 0
  PASS  exactly two tmpfs mounts, both the dispatcher's (/tmp + /work)
  PASS  workspace tmpfs sized from dispatcher config (size=384m)
  PASS  /tmp is still small (size=8m)
  PASS  no bind or volume mounts at all (.Mounts empty)

ENV INJECTION  (values from the dispatcher's own environment, never the request)
        scratch dispatcher up: allowlist=GITHUB_TOKEN,TARGET_REPO,P7_SET_ON_PURPOSE,P7_UNSET_ON_PURPOSE,DISPATCH_TOKEN,WORKER_IMAGE
        P7_SET_ON_PURPOSE is set in it; P7_UNSET_ON_PURPOSE deliberately is not; the last two are reserved names
  PASS  scratch dispatcher spawned a worker (201)
  PASS  allowlisted variable that IS set reaches the worker with the dispatcher's value
  PASS  caller could not override a variable that IS injected
  PASS  allowlisted-but-unset P7_UNSET_ON_PURPOSE is ABSENT from the worker (not present-and-empty)
  PASS  caller could not add a variable outside the allowlist (EVIL_ADDED absent)
  PASS  reserved DISPATCH_TOKEN refused by the allowlist (worker cannot spawn workers)
  PASS  reserved WORKER_* name refused by the allowlist (WORKER_IMAGE absent)
  PASS  dispatcher LOGGED the refused allowlist entry
  PASS  dispatcher LOGGED the omitted-because-unset variable
  PASS  spawn log records injected variable NAMES (audit trail)
  PASS  GITHUB_TOKEN injected from the dispatcher's own env (values compared, never printed)
  PASS  TARGET_REPO injected from the dispatcher's own env
  PASS  token not echoed in the spawn response
  PASS  token not echoed in error or health responses
  PASS  token absent from the dispatcher's log (names only)
  PASS  spawn request never carried the credential (argv holds $GITHUB_TOKEN, not its value)
  PASS  shallow git clone of the private target repo through the egress proxy SUCCEEDED
        CLONE_OK files=29 kb=120 WORKSPACE_FREE_KB=262008
  PASS  git can branch and commit inside the workspace (a worker can produce a PR branch)
  PASS  token absent from the worker's own log output

RESULT (dispatcher): 68 passed, 0 failed
```

Two notes on how that transcript was captured, because both affect what it proves:

- **The `ENV INJECTION` section runs against a dispatcher the suite starts
  itself.** The three properties it has to establish — an allowlisted variable
  that IS set reaches the worker, one that is NOT set is absent rather than
  empty, and a reserved name is refused even when an operator asks for it — cannot
  all be true of the same variable in one configuration. So that section stands up
  a second dispatcher from the same `p1-dispatcher.py` with a configuration chosen
  to make each case decidable, and tears it down. It is namespaced `p7-*` and
  labels its workers `p7-scratch-worker`, so neither cleanup path can reach into
  the composed stack.
- **This particular run targeted a `p7-` stand-in** for the composed
  `hermes-dispatcher`: same file, same environment the compose service now
  supplies, started alongside a live stack that was not to be restarted. Rerun
  `./verify-spawning.sh dispatcher` after `docker compose up -d` to reproduce it
  against `hermes-dispatcher` itself; the suite reads its whole configuration off
  whichever container it is pointed at.

## Why (d) works where (a) cannot

The proxy's flaw is structural, not a misconfiguration: it forwards a
caller-supplied create body to Docker. No amount of flag-tuning fixes that,
because there is no flag for "inspect the body." The dispatcher inverts the trust
boundary:

- **The caller never supplies a create body.** It POSTs a name and an optional
  command from a small allowlist. The dispatcher **constructs** every
  `/containers/create` body itself, from a fixed hardened template
  (`p1-dispatcher.py`, `spawn()`). There is no code path by which `Binds`,
  `Privileged`, `NetworkMode`, `PidMode`, `Devices`, `CapAdd`, `Env`, `Tmpfs` or
  `WorkingDir` can be set by a request — the fields simply are not read. Ignoring
  them beats rejecting them: a rejection list has to enumerate every spelling an
  attacker might try, while a template that reads two fields cannot be surprised
  by a third.
- **Destructive verbs are label-scoped.** `stop`/`remove` first `GET` the target
  and refuse (403) anything not carrying `role=hermes-worker`. That is why
  pointing `/stop` at `hermes` is refused with the real `hermes` left running.
- **The surface is three verbs.** No raw Docker API, no `exec`, no `build`, no
  inventory read — all 404. Contrast the proxy, which exposes the whole
  `/containers` tree including reads of every other container.
- **It enforces *more* than the proxy ever could.** Because it owns the template,
  every worker is created with `CapDrop:["ALL"]`, `no-new-privileges`, a memory
  cap, `ReadonlyRootfs`, a pinned network, exactly one writable tmpfs, and exactly
  the credentials the operator allowlisted. A proxy cannot *impose* hardening; it
  can only permit or deny a body it does not read. Nor can a proxy *supply*
  anything: a credential handed to a worker through a proxy would have to travel
  through the caller, which is the one place it must not be.

## What a worker gets, and where it comes from

The template above is what makes the dispatcher safe, and for a while it was also
what made workers useless. With no `Env` key and nothing writable but 8 MiB of
`/tmp`, a worker could not clone a repository, run a build, or open a pull
request — so the acceptance criterion "three workers run concurrently, each
producing a PR on its own branch" was unreachable by construction. Both gaps are
now closed **without adding a single caller-controlled field**.

### Credentials: allowlisted NAMES, dispatcher-owned VALUES

`WORKER_ENV_ALLOWLIST` (default `GITHUB_TOKEN,TARGET_REPO`) is a list of variable
**names**. For each one, the dispatcher copies the value **from its own
environment** into the create body. `worker_env()` does not take the request as an
argument; that is the whole design:

- A caller cannot **name** a variable — the list comes from the dispatcher's
  configuration.
- A caller cannot **add** one — a request's `Env` is read by nothing.
- A caller cannot **override** one — same reason. Note the harness checks this by
  looking for the attacker's string *anywhere* in `.Config.Env`, not just in the
  first entry, because the naive way to leak a caller's environment is to *append*
  it, leaving the dispatcher's value first and the attacker's second.
- A caller cannot **read one back** — the `/spawn` response carries no environment
  information at all: not the values, not even the names. A caller that could read
  back what it was given would have turned an injection point into a credential
  oracle.

Two further rules the allowlist enforces on the *operator*:

- **Unset means omitted, not empty.** `${TARGET_REPO:-}` in compose produces a
  variable that exists and is empty, and a worker that sees `GITHUB_TOKEN=""`
  fails deep inside a `git push` with an authentication error. The dispatcher
  omits it instead, and logs `WARNING: <NAME> is allowlisted but unset` so the
  operator finds out at start-up rather than an hour into a dispatch run.
- **Reserved names are refused.** `DISPATCH_TOKEN`, `DOCKER_SOCK`, `BIND_PORT`,
  `PATH`, `LD_*` and anything starting with `WORKER_` are rejected from the
  allowlist with a logged warning. `DISPATCH_TOKEN` is the sharp one: a worker
  holding the bearer token could spawn more workers, so one config typo would turn
  a worker into a second orchestrator. This is the one place where the dispatcher
  protects the design from its own operator.

The credential never travels through the caller at all, which the suite proves
from the other end: the live-clone worker's `Cmd` contains the literal string
`$GITHUB_TOKEN`, expanded only inside the container, and the harness asserts the
real token appears nowhere in that argv, in any response body, in the dispatcher's
log, or in the worker's own log.

### Workspace: one tmpfs, 384 MiB, and why that number

`ReadonlyRootfs: True` stays. The worker gets exactly one writable mount —
`WORKER_WORK_PATH` (default `/work`), sized by `WORKER_WORK_SIZE` (default
`384m`) — plus the unchanged 8 MiB `/tmp`. There are still no `Binds`, so the
worker has RAM to write in and never a path on the host.

Three measured facts set that size:

1. **A tmpfs is charged to the container's own memory cgroup.** Measured: a
   container with `--memory 128m` and a `512m` tmpfs was OOM-killed after writing
   ~126 MiB into it (`OOMKilled=true`), rather than being given `ENOSPC` at
   512 MiB. So the real ceiling on a worker's workspace is `WORKER_MEMORY`
   (512 MiB per worker here), **not** the `size=` option. The consequence for the
   VM budget is the good news: adding the workspace does **not** change the
   arithmetic in `docker-compose.yml`, because those pages come out of the
   512 MiB a worker was already capped at.
2. **So the size must sit *below* the memory cap, not at it.** 384 MiB leaves
   ~128 MiB of the cap for `git`, `python` and the test runner's own RSS. Set it
   at or above the cap and the failure mode changes from a clean `ENOSPC` — which
   a worker can report — to a `SIGKILL` mid-clone, which looks like a flaky
   ticket. The dispatcher logs a warning when `WORKER_WORK_SIZE >= WORKER_MEMORY`
   rather than silently accepting the worse failure mode. If you need a bigger
   workspace, raise `WORKER_MEMORY` first and re-check the VM budget: three
   workers at 512 MiB are already in it, against a ~7.65 GiB VM.
3. **384 MiB is generous for the actual job.** Measured on the target project: a
   `--depth 1` clone is 120 KiB across 29 files, and a full `pytest` run leaves
   the workspace at 136 KiB. The headroom is not for the checkout, it is for a
   `pip install` into the workspace, a `node_modules`, or build output — the
   things a ticket's acceptance command needs and a 64 MiB workspace would fail
   on for no interesting reason.

Two mount options carry weight and neither follows from the size:

- **`mode=1777`.** Docker gives a fresh tmpfs the ownership and permissions of the
  directory it shadows, and the worker image's `/work` is root-owned `0755` while
  the image runs as `USER worker` (uid 10001). Measured without this option:
  `touch: /work/x: Permission denied`. The workspace would have existed and been
  unusable — a silent version of the bug this change exists to fix.
- **`exec`.** Docker mounts tmpfs `noexec` by default, which breaks every test
  suite that runs something from inside the checkout (a venv's `python`,
  `node_modules/.bin`, `./scripts/test.sh`). It is not a boundary worth keeping
  here: the worker is *already* executing agent-chosen code from its read-only
  rootfs, so `noexec` on the workspace buys nothing and costs the feature.
  `/tmp` keeps the default `noexec`, visible in the transcript above.

### Mutation testing — the suite was made to fail on purpose

New checks that cannot fail are decoration. Two deliberate regressions were
introduced into `p1-dispatcher.py`, the dispatcher restarted on the broken code,
and the suite rerun:

| Mutation | Result | Checks that caught it |
|---|---|---|
| Merge the request's `Env` into the injected env (`env.append(item)` — the shape a future "workers need one more variable" change would take) | **57 passed, 11 failed** | `EVIL_INJECTED` and `LD_PRELOAD` present; `PATH` override changed the outcome of `/spawn`; `GITHUB_TOKEN` and `TARGET_REPO` overridden; duplicated env names (17 unique of 19); unexpected env names; injected variable overridden; `P7_UNSET_ON_PURPOSE` present as the attacker's value; `EVIL_ADDED` added; **worker holds `DISPATCH_TOKEN`** |
| Take the workspace path and size from the request (`req.get("work_path")`, `req.get("work_size")`) | **65 passed, 3 failed** | caller added a tmpfs at its own path (`/hostile=size=4g`); caller resized a tmpfs; smuggled `WorkingDir` took effect |

The first mutation is instructive beyond going red. `PATH=/attacker/bin` reached
Docker, so the worker's own `sleep` entrypoint could no longer be found and the
container failed to start — a caller-supplied environment is not only a
confidentiality problem, it is an availability one. That is why the PATH-override
probe gets its own `/spawn` in the harness: sharing a worker with the rest of the
battery let one mutation abort the checks that should have judged it.

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
  ~445 lines of stdlib Python (about half of it comment) with no
  request-controlled `HostConfig` and no request-controlled `Env`, no dependencies
  to audit, and it runs with `no-new-privileges` and its own caps dropped. Keep it
  small and review every change to `spawn()` and to `worker_env()` — the mutation
  table above is what a bad change to either looks like.
- **Bearer token, not mutual auth.** Anyone who can reach the dispatcher's port
  *and* holds the token gets worker spawn rights. Here the token is a PoC
  placeholder in the container env (same spirit as this repo's `api_key=ollama`).
  In production, inject it from a secret and put the dispatcher on a dedicated
  network only the orchestrator joins.
- **Worker breakout is a separate boundary.** The dispatcher guarantees workers
  are *created* unprivileged and un-mounted; it does not by itself confine what a
  running worker can reach on the network. Pair it with the `--internal` network
  cage from the sibling PoC (`setup-sandbox.sh`) for egress control.
- **An injected variable is visible to anything with host Docker access.**
  `docker inspect <worker>` prints `.Config.Env` in full, and so does
  `GET /containers/{id}/json` for any client that can reach the daemon. The
  dispatcher's guarantee is about the *caller* — the orchestrator cannot name, add,
  override or read back a variable — not about the host. Anyone who can run
  `docker` on this machine can read the token out of a running worker, and could
  have read it out of `hermes` before this change too. The tenth proxy failure
  above is the same fact turned into an exploit: grant a caller the `/containers`
  read surface and you have granted it every credential on the host.
  Consequences accepted here, since the host is the developer's own machine and
  the token is a repo-scoped PAT in a gitignored file. What a production answer
  looks like instead:
  - **Short-lived, narrowly-scoped credentials.** A GitHub App installation token
    (~1 h, scoped to one repository) minted per worker, or an OIDC-federated token
    exchanged at start-up. An hour-old leaked token that can only touch one repo is
    a different class of incident from a long-lived PAT.
  - **Deliver the secret out of band, not in `Env`.** A `tmpfs`-backed file the
    worker reads once and unlinks, or a short-lived unix-socket broker the worker
    authenticates to with its container identity. `Env` is the convenient channel,
    not the good one: it is inherited by every child process, it shows up in
    `/proc/<pid>/environ`, and it is printed by any crash reporter that dumps the
    environment.
  - **Never mint the credential where the workload runs.** Keep the issuing
    identity on the dispatcher side, hand the worker only the derived token, and
    revoke it when the worker is reaped.
  - **Audit and rotate.** The dispatcher already logs which variable *names* each
    worker received; production wants that stream shipped somewhere append-only,
    plus automatic revocation on reap and on suite failure.
- **Command allowlist is coarse.** `spawn` accepts a small command allowlist
  (`sleep`, `sh`, `cat`, …). `sh` is on it for realistic workers; a worker that
  runs `sh` can do whatever its dropped-capability, read-only, isolated-network
  container permits — which is the point of the *other* boundaries, not this one.
- **Availability, not just safety.** The dispatcher is a single point of failure
  for spawning. That is acceptable: failing closed (no spawn) is the safe mode.

## Reproduce

```bash
docker compose up -d              # option (d) is the composed stack: hermes-dispatcher
./verify-spawning.sh dispatcher   # option (d): 68 passed, 0 failed, exit 0 (recommended)

./p1-spawn-setup.sh               # option (a)'s standalone rig, p1-* namespaced
./verify-spawning.sh proxy        # option (a): 8 passed, 10 failed, exit 1 (security theatre)
./p1-spawn-teardown.sh            # removes every p1-* container + network
```

The `proxy` rig is namespaced entirely under `p1-` and never touches `hermes`,
`ollama-gate`, or the `hermes-isolated` network. `p1-bystander` is a deliberately
unrelated, unlabelled container used as the "container I don't own" target so the
destructive tests never point at anything real (the single test that points
`/stop` at the real `hermes` only triggers a read-only label check and asserts
`hermes` stays up). The `dispatcher` suite's own scratch dispatcher and workers are
namespaced `p7-` and removed on exit, including on interrupt.

The credential controls need `TARGET_REPO` and `TARGET_REPO_TOKEN` in the
gitignored `local.env`; without them the suite says so and skips exactly those
checks (the live clone included) rather than passing vacuously.

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
| Worker/probe images | `hermes-worker:latest`, `alpine:latest`, `curlimages/curl:latest` (kept small per the VM budget) |

## Dispatcher configuration

Everything the template is built from. None of it is reachable from a request.

| Variable | Default | What it controls |
|---|---|---|
| `DISPATCH_TOKEN` | *(none — refuses to start)* | Bearer the caller must present |
| `WORKER_IMAGE` | `alpine:latest` | Image every worker runs |
| `WORKER_LABEL_KEY` / `WORKER_LABEL_VALUE` | `role` / `hermes-worker` | Label stamped on workers; the stop/remove scope guard |
| `WORKER_NETWORK` | `p1-spawn-net` | Network workers join |
| `WORKER_MEMORY` | `67108864` (64 MiB) | Per-worker memory cap, in bytes — also the real ceiling on the workspace |
| `WORKER_NAME_PREFIX` | `p1-` | Names `/spawn` will create |
| `WORKER_ENV_ALLOWLIST` | `GITHUB_TOKEN,TARGET_REPO` | Variable **names** copied from the dispatcher's own environment. Reserved names (`DISPATCH_TOKEN`, `PATH`, `LD_*`, `WORKER_*`, …) are refused with a logged warning |
| `WORKER_WORK_PATH` | `/work` | The one writable mount. Refuses to start on `/`, `/etc`, `/tmp`, … |
| `WORKER_WORK_SIZE` | `384m` | Its tmpfs size. Warns if `>= WORKER_MEMORY` |

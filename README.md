# local-ai-agent-explore

Running an autonomous agent orchestrator (**Hermes Agent**) against a **local LLM**
(Ollama), confined so that it can reach *exactly one* network destination — the model
— and nothing else. No internet, no LAN, no host services, no Docker socket.

A proof of concept. The point is not the local model; it is that the cage is
**provider-agnostic**. Swap the model endpoint for a cloud API and every other
boundary stays as-is.

## Verified, not asserted

This PoC treats an **evaluation harness as a first-class deliverable**, alongside the
sandbox itself. A confinement claim nobody can re-run is a claim, not a result — so
the boundary is measured from outside the agent, mechanically, on every run.

> ### → **[COMPOSE.md](COMPOSE.md)** — the whole stack as one `docker-compose.yml`: how to bring it up and down, and how each `docker run` flag was proven to survive the translation
>
> ### → **[RESULTS.md](RESULTS.md)** — full captured output: **33 checks, 0 failures**
>
> ### → **[TESTING.md](TESTING.md)** — reproduce it yourself, step by step
>
> ### → **[SPAWNING-DECISION.md](SPAWNING-DECISION.md)** — spawning workers without a Docker socket: an off-the-shelf socket proxy **broken** (9 failures), a body-validating dispatcher **21/0**
>
> ### → **[MODEL-EVALUATION.md](MODEL-EVALUATION.md)** — which local models can actually orchestrate, and why KV cache decides it

```bash
./verify-sandbox.sh; echo "exit=$?"     # RESULT: 56 passed, 0 failed / exit=0
```

(`RESULTS.md` captures the original 33-check run against the single-container sandbox.
The composed stack adds the COMPOSE TRANSLATION and SPAWN DISPATCHER sections — see
[COMPOSE.md](COMPOSE.md).)

What the harness insists on, and why each matters:

- **Measured from the host, not self-reported.** A model asked whether it can reach
  the internet may simply answer wrongly. The script never asks the agent anything.
- **Probes run inside the real agent container** via `docker exec`, not a lookalike
  container that merely shares its network — no inferential step between the
  evidence and the claim.
- **Aimed at live ports.** A closed port is indistinguishable from a blocked one, so
  the probes target services that are genuinely listening.
- **A positive control.** The model endpoint must come back *reachable*. If it does
  not, the probe cannot detect an open port and every negative result is void — so
  the harness fails rather than reporting a clean sweep.
- **Non-zero exit on any failure**, making it usable as a gate in CI or before a demo.

That discipline paid for itself: it caught a check of our own that **could never
fail** — a `/dev/tcp` probe that reported containment it had never measured
([RESULTS.md §7](RESULTS.md)). `RESULTS.md` also records what was *not* tested, and
one finding that contradicted the prediction the test was written against.

## The problem

An agent orchestrator is a program that executes model-chosen shell commands, browses,
and writes files. Run it the obvious way:

```bash
docker run -it --rm -v ~/.hermes:/opt/data nousresearch/hermes-agent
```

...and it lands on Docker's default bridge network as root. On a typical developer
laptop that means it can reach the open internet **and** every service bound on the
host — databases, object-storage emulators, internal APIs. Verified on the machine
this was built on: MongoDB, MySQL, a LocalStack instance and several local HTTP
services were all reachable from inside that container.

Model access requires one TCP port. Everything else above is incidental.

## The design

```
   ┌─────────────────────────────┐
   │  hermes  (the agent)        │   network: hermes-isolated  (--internal)
   │  cap-drop ALL + 5 caps      │   no gateway · no egress · no outbound DNS
   │  no-new-privileges          │
   │  mem/cpu/pids capped        │
   └──────────────┬──────────────┘
                  │  the only reachable destination
                  ▼
   ┌─────────────────────────────┐
   │  ollama-gate  (nginx)       │   networks: hermes-isolated + bridge
   │  path allowlist, rate limit │   read-only rootfs · ip_forward=0
   └──────────────┬──────────────┘
                  │  host.docker.internal:11434
                  ▼
   ┌─────────────────────────────┐
   │  Ollama on the host         │   bound to 127.0.0.1 only
   └─────────────────────────────┘
```

Two ideas do the work:

1. **`docker network create --internal`** gives a network with no gateway. Containers
   on it cannot route anywhere — not the internet, not the host, not even DNS.
2. **A dual-homed proxy** is the single hole. `ollama-gate` sits on both the internal
   network and the bridge, forwarding one port with a path allowlist. The agent's
   entire reachable universe is that allowlist.

The agent needs no capability to reach the model, so it keeps none that would let it
reach anything else. Notably it has no `NET_ADMIN`, so it cannot install a route.

### What the gate allows

| Allowed | Denied (403) |
|---|---|
| `/v1/*` (OpenAI-compatible) | `/api/pull` — makes the **host** fetch from a remote registry |
| `/api/chat`, `/api/generate`, `/api/embed` | `/api/push` — upload path, i.e. exfiltration |
| `/api/tags`, `/api/ps`, `/api/show`, `/api/version` | `/api/create`, `/api/copy`, `/api/delete`, `/api/blobs` |
| | everything else — default deny |

`/api/pull` deserves emphasis: it is an **indirect internet egress**. The container
cannot reach the network, but that endpoint would make the host fetch arbitrary
content on its behalf. An allowlist that only considered "is this the model port"
would have missed it.

The gate also rate-limits (6 concurrent, ~3 req/s). Inference runs on the host,
outside the container's cgroup, so the agent's memory and CPU limits do not cap what
it can consume; the gate does.

## Setup

Requires Docker and Ollama on the host.

```bash
# 1. Model. Hermes refuses to start below a 64,000-token context window.
ollama pull gpt-oss:20b
ollama create gpt-oss:20b-64k -f Modelfile.gpt-oss-64k

# 2. Machine-specific values, including the spawn dispatcher's token.
cp local.env.example local.env   # then set DISPATCH_TOKEN

# 3. The cage: internal network, model gate, egress proxy, spawn dispatcher.
docker compose --profile images build
./run-hermes.sh

# 4. Prove the boundary holds.
./verify-sandbox.sh && ./verify-egress.sh && ./verify-spawning.sh dispatcher
```

The whole topology is one `docker-compose.yml` — see **[COMPOSE.md](COMPOSE.md)**.
`run-hermes.sh` is a wrapper that sources `local.env` and sizes the memory cap to the
live Docker VM; the preflight assertions are a compose service the orchestrator
`depends_on`, so it **refuses to start** if the network has a route out, the gate is
missing, or an egress path answers anything but 403. A sandbox that silently degrades is
worse than none — and putting the preflight in the stack means it cannot be skipped by
launching some other way.

For the single-container, model-only sandbox that this grew out of, `setup-sandbox.sh`
is still there and still works.

## Verifying it

`verify-sandbox.sh` checks the boundary from the host, independently of anything the
agent reports about itself, and exits non-zero on any failure:

```
NETWORK ISOLATION          internal network, internet unreachable, DNS unreachable
HOST SERVICES              databases and local HTTP services unreachable
GATE ALLOWLIST             egress + admin paths 403, inference paths 200
GATE HARDENING             ip_forward=0, read-only rootfs
OLLAMA EXPOSURE            loopback-only bind
MODEL FITNESS              served context >= 64000
CONTAINER PRIVILEGES       no NET_ADMIN, not privileged, no docker.sock, not on bridge
```

Ask the agent directly too — "fetch https://example.com", "connect to MongoDB on
host.docker.internal:27017" — but treat its answers as claims. Small models sometimes
report success at things they did not do. The script is ground truth.

Captured output from a full run, including the live-agent probes and the code-execution
test, is in **[RESULTS.md](RESULTS.md)**. The procedure to reproduce it — plus the
traps that produced wrong conclusions along the way — is in **[TESTING.md](TESTING.md)**.

## Findings worth keeping

Things that cost real time here, none of them documented obviously:

**Ollama 403s on unfamiliar `Host` headers.** It allowlists `localhost`, `127.0.0.1`
and `host.docker.internal`. A TCP-level forwarder (socat) preserves the original
header and gets 403. The gate must be an HTTP proxy that rewrites it, plus
`proxy_buffering off` or token streaming breaks.

**`OLLAMA_CONTEXT_LENGTH` never reached the server.** Set via `launchctl setenv` and
the app relaunched, twice, asking for 40960 then 65536 — the server served 32768 both
times. The first read of this was "Ollama ignores the variable", which was wrong.
Inspecting the running process settles it:

```bash
launchctl getenv OLLAMA_CONTEXT_LENGTH          # 65536
ps eww -o command= -p "$(pgrep -f 'ollama serve')" | tr ' ' '\n' | grep ^OLLAMA
# OLLAMA_MODELS=... / OLLAMA_NO_CLOUD=0   -- and nothing else
```

The variable is not in the server's environment at all, so 32768 was simply Ollama's
**default**, not an override. A GUI-launched app does not pick up `launchctl setenv`
values this way. The same trap catches **`OLLAMA_NUM_PARALLEL`**, which matters far
more — see [MODEL-EVALUATION.md](MODEL-EVALUATION.md), where it decides whether
concurrent agents are possible at all.

Practical rule either way: a Modelfile `PARAMETER num_ctx` is the reliable lever, it
is clamped to the model's trained maximum, and **only `/api/ps` tells you what is
actually served**. Setting the orchestrator's `context_length` above the served value
makes it start and then silently truncate prompts.

**Bare `--cap-drop ALL` broke the image.** s6-overlay drops privileges during init and
dies with `s6-applyuidgid: fatal: unable to set supplementary group list`. The minimum
working set is `CHOWN, SETUID, SETGID, DAC_OVERRIDE, FOWNER` — none of which is
`NET_ADMIN`, so containment is unaffected. Worth noting the failure was silent in a
piped command: `docker run ... | tail` reports `tail`'s exit code, not Docker's.

**Docker Desktop on macOS reaches a loopback-bound host service** through
`host.docker.internal`. Exposing Ollama on `0.0.0.0` is unnecessary — it stays on
127.0.0.1 and out of reach of the LAN.

**The gate's `ip_forward` defaulted to 1.** It would have routed for anyone who could
set a route. Only capability-dropping prevented that, so `--sysctl
net.ipv4.ip_forward=0` makes it structural rather than incidental.

## Residual risk

Honest limits of this setup:

- **The agent's data directory is writable.** It is how the agent persists skills and
  memory, so it cannot be read-only. An agent can write something there that runs on
  next launch. Mitigation used here: keep that directory under git and review diffs.
  This orchestrator gates unseen hooks behind an interactive prompt by default —
  do not pass its `--accept-hooks` or `--yolo` flags.
- **Root inside the container.** The image requires it. With all capabilities dropped
  and `no-new-privileges`, contained but not zero. On macOS, containers run inside a
  Linux VM, so an escape lands there rather than on the host.
- **The gate is dual-homed** by necessity. It is the one component touching both sides,
  hence read-only rootfs, dropped capabilities, and a tiny config surface.
- **Compute is not fully bounded.** Inference happens on the host; the gate's rate
  limit is the control, not the container's cgroup.
- **Human error dominates.** Every boundary lives in launch flags. Running the bare
  `docker run` restores full access with no warning. Hence the wrapper and preflight.

## Moving to a cloud model

Change two things:

1. The agent's `base_url` → the provider's API endpoint.
2. The gate's `proxy_pass` and allowlist → that provider's host and paths.

The internal network, capability set, absent Docker socket, resource limits, preflight
and audit trail are unchanged. The local model exists so the demo runs offline; it is
not what is being demonstrated.

## Adding HTTPS destinations

The gate's path allowlist works only because the model API is plaintext. An agent that
also needs GitHub — to clone, to push a branch, to file and read issues, to open a pull
request — cannot be filtered that way: over TLS a proxy sees `CONNECT github.com:443`
and nothing else. That case needs a second, separate mechanism: a **domain** allowlist
on a CONNECT proxy, with the `--internal` network still the reason it holds. Both gates
are in the composed stack.

The entire reachable internet is two hosts: `github.com` (all of git over HTTPS,
including push) and `api.github.com` (issues, labels, pull requests).

> ### → **[EGRESS.md](EGRESS.md)** — the design, the empirically determined GitHub
> allowlist, and `./verify-egress.sh` (**45 checks, 0 failures**, 46 with a live
> inference call) including the bypass tests
>
> It also states plainly what a domain allowlist does *not* buy you: allowing
> `github.com` so an agent can push branches allows it to push anything, anywhere on
> `github.com`.

## Planning the work

The sandbox is the substrate; [ORCHESTRATOR.md](ORCHESTRATOR.md) is the contract
the agents inside it follow. The **planner** is the first of them: one issue
labelled `spec` goes in, implementation issues come out — each with the sections
the dispatcher parses, one priority, declared dependencies, and a file list that
lets concurrent tickets avoid each other.

Its design problem is the model, not the prompt. The first version handed a 20B
model a seven-phase procedure to follow; across four live runs it improvised
instead of starting, misread a missing `jq` as a network outage, wrote the
target project's code into its own data directory, stopped after one ticket —
and, on the last run, printed a confident five-ticket plan when the ledger held
two. The pattern was consistent: where the *script* owned control the output was
flawless, and where the *model* owned control it drifted.

So control is inverted. A script runs the whole loop and calls the model only
for decisions — one for the file layout, then one per ticket — each constrained
to a JSON object whose schema is in the prompt, validated on receipt, retried
with the parse error fed back, and, when the retries run out, **stopped loudly
with the raw reply printed**. There is no branch that supplies a value the model
did not send.

```bash
./verify-planner.sh; echo "exit=$?"     # RESULT: 98 passed, 0 failed / exit=0
```

> ### → **[PLANNER.md](PLANNER.md)** — the loop, where exactly the model is
> consulted, the 18-check validator, the measured first-try JSON validity rate,
> and an honest list of what a 20B model will get wrong anyway
>
> The harness checks the validator against `ORCHESTRATOR.md` itself, fires every
> check at a deliberately malformed plan, refuses to report a clean sweep unless
> every check has been *made* to fail — and drives the loop against a mock
> endpoint that returns prose, truncated JSON, a five-ticket array and a mid-run
> 500, proving the planner stops rather than invents. Every ticket carries the
> hash of the reply it came from, so "it did not fabricate" is checked, not
> claimed.

## Doing the work

The **worker** is the other end of the same pipeline: one issue number in, one
pull request out. It clones the target repository into its tmpfs, branches, asks
the model for the contents of each file the ticket declares, runs the ticket's
acceptance command and then the project's full test suite, and opens a pull
request that says `Closes #N`. It cannot merge it.

Control is inverted here for the same reason it is in the planner. The model is
never asked to implement a ticket; it is asked, once per declared file, for the
complete contents of *that* file, and the script does everything else. It never
runs a command, never chooses what happens next, and cannot choose which file it
is writing — a reply about a different path is refused rather than filtered.

The interesting part is what happens when things go wrong, because that is most
of the time. Every outcome has its own exit code: a ticket that does not match
`ORCHESTRATOR.md` is refused **before the clone and before the first model
call**; a reply proposing an extra file is refused and that file never exists; a
failing acceptance command is retried with its own output fed back and, if it
still fails, **nothing is committed**; a test that starts failing is reported
rather than repaired; and "this work needs a file the ticket did not declare" is
a comment on the issue and an exit code of its own, having written nothing at
all. There is no code path in the program that sets a label, merges, or
force-pushes.

```bash
./verify-worker.sh; echo "exit=$?"      # RESULT: 116 passed, 0 failed / exit=0
./verify-worker.sh image                # + one ticket inside hermes-worker:latest
```

> ### → **[WORKER.md](WORKER.md)** — the loop, where exactly the model is
> consulted, the three layers that hold the declared-file list, the mutation test
> that breaks the scope check and proves the harness goes red, and an honest list
> of what will still go wrong on a first real run

## Files

| File | Purpose |
|---|---|
| `docker-compose.yml` | **The whole stack**: internal network, model gate, egress proxy, spawn dispatcher, preflight, orchestrator |
| `COMPOSE.md` | Bringing it up and down; what changed in the consolidation; measured resource use |
| `stack-preflight.sh` | Preflight service — refuses to let the orchestrator start into an open cage |
| `egress-agent-net.conf` | squid's client ACL; must match the pinned subnet in the compose file |
| `setup-sandbox.sh` | Superseded by compose. Creates the internal network and the gate |
| `ollama-gate.conf` | nginx allowlist, Host rewrite, rate limits |
| `run-hermes.sh` | Wrapper: sources `local.env`, sizes the memory cap to the live VM, `up` + attach |
| `verify-sandbox.sh` | Host-side boundary verification |
| `Modelfile.gpt-oss-64k` | Raises served context to 65536 |
| `hermes-config.example.yaml` | Model wiring — placeholders only, no secrets |
| `TESTING.md` | Step-by-step procedure to reproduce the results |
| `RESULTS.md` | Captured output from a full run |
| `MODEL-EVALUATION.md` | Model choice: KV cost, concurrency limits, measured verdict |
| `SPAWNING-DECISION.md` | Spawning workers without a Docker socket, with the exploit |
| `p1-dispatcher.py` | Body-validating spawn dispatcher (the recommendation) |
| `verify-spawning.sh` | Adversarial harness: `proxy` (fails) vs `dispatcher` (passes) |
| `EGRESS.md` | Domain-allowlisted HTTPS egress: design, allowlist, results |
| `setup-egress.sh` | Builds the `p2-*` egress sandbox; `teardown` removes it |
| `egress-proxy.conf` | squid domain allowlist, CONNECT-only, ordered denies |
| `egress-allowed-domains.txt` | The allowlist itself |
| `egress-proxy.Dockerfile` | alpine + squid, ~21 MB |
| `egress-probe.Dockerfile` | Worker stand-in: git, curl, python3 |
| `verify-egress.sh` | Egress verification, including the bypass tests |
| `ORCHESTRATOR.md` | The contract planner, dispatcher and workers all follow |
| `bootstrap-labels.sh` | Creates that contract's labels in the target repo |
| `PLANNER.md` | The planning loop, validator design, measured model reliability, expected failures |
| `hermes-skills/.../orchestrator-planner/` | The planner skill and its two scripts |
| `verify-planner.sh` | Planner verification: contract agreement, positive controls, mock-model loop suites |
| `p3-fixtures/good/` | A conforming plan, as rendered issues, for the validator |
| `p3-fixtures/spec/` | A spec issue, README and seed scenario used as offline planning input |
| `p3-fixtures/model/replies.json` | Twenty canned model replies the harness drives the loop with |
| `WORKER.md` | The worker loop, the scope layers, the mutation test, expected first-run failures |
| `worker.py` | The worker: one ticket in, one pull request out; the model only returns file contents |
| `p4-worker.sh` | The worker container's PID 1, named by the dispatcher's default worker command |
| `p4-worker-instructions.md` | What the worker does, and the whole of what the model inside it is told |
| `verify-worker.sh` | Worker verification: 116 checks, an in-image run, and a mutation control |
| `p5-fixtures/repo/` | The fixture target project a worker is pointed at — no domain, on purpose |
| `p5-fixtures/issues.json` | Fixture GitHub state: one conforming ticket, nine unusable ones |
| `p5-fixtures/model/replies.json` | Sixteen canned scenarios: good, wrong-path, prose, dead endpoint, weakening, leaking |

## Notes

No secrets in this repo. The `api_key` in the example config is the literal string
`ollama`, a placeholder for an endpoint that requires no authentication but whose
client library demands a non-empty value.

Tested on Apple Silicon (M3 Pro, 36 GB) with Docker Desktop and Ollama 0.32.8.
`gpt-oss:20b` is ~13 GB on disk and ~12.8 GB resident at a 65536 window.

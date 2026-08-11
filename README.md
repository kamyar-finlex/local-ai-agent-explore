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

> ### → **[RESULTS.md](RESULTS.md)** — full captured output: **33 checks, 0 failures**
>
> ### → **[TESTING.md](TESTING.md)** — reproduce it yourself, step by step

```bash
./verify-sandbox.sh; echo "exit=$?"     # RESULT: 33 passed, 0 failed / exit=0
```

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

# 2. The cage.
./setup-sandbox.sh

# 3. Point the agent at the gate (see hermes-config.example.yaml).

# 4. Prove the boundary holds.
./verify-sandbox.sh

# 5. Run it.
./run-hermes.sh
```

`run-hermes.sh` runs preflight assertions and **refuses to launch** if the network is
not internal, the gate is missing, or an egress path answers anything but 403. A
sandbox that silently degrades is worse than none.

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

**`OLLAMA_CONTEXT_LENGTH` was ignored.** Set via `launchctl setenv` with the server
restarted, twice, asking for 40960 and 65536 — the server served 32768 both times, its
own default. A Modelfile `PARAMETER num_ctx` works, but is clamped to the model's
trained maximum, so a model declaring 40960 cannot be pushed to 64K at all. Always
read the served value from `/api/ps`; the advertised window and the env var are both
unreliable. Setting the orchestrator's `context_length` above what is actually served
causes silent prompt truncation.

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

## Files

| File | Purpose |
|---|---|
| `setup-sandbox.sh` | Creates the internal network and the gate |
| `ollama-gate.conf` | nginx allowlist, Host rewrite, rate limits |
| `run-hermes.sh` | Preflight-checked launcher |
| `verify-sandbox.sh` | Host-side boundary verification |
| `Modelfile.gpt-oss-64k` | Raises served context to 65536 |
| `hermes-config.example.yaml` | Model wiring — placeholders only, no secrets |
| `TESTING.md` | Step-by-step procedure to reproduce the results |
| `RESULTS.md` | Captured output from a full run |

## Notes

No secrets in this repo. The `api_key` in the example config is the literal string
`ollama`, a placeholder for an endpoint that requires no authentication but whose
client library demands a non-empty value.

Tested on Apple Silicon (M3 Pro, 36 GB) with Docker Desktop and Ollama 0.32.8.
`gpt-oss:20b` is ~13 GB on disk and ~12.8 GB resident at a 65536 window.

# Test results

Boundary verification and live-agent probes for the sandbox in this repo.
Every figure below is captured output, not a summary written from memory.

## Environment

| | |
|---|---|
| Host | Apple M3 Pro, 36 GB unified memory, macOS |
| Docker | Desktop 29.3.1 |
| Ollama | 0.32.8, bound to `127.0.0.1:11434` |
| Model | `gpt-oss:20b-64k` — 20.9B params, MXFP4, ~13 GB on disk, ~12.8 GB resident |
| Served context | 65536 (measured via `/api/ps`) |
| Orchestrator | Hermes Agent v0.20.0, 18 tools / 75 skills loaded |

## 1. Host-side harness

`./verify-sandbox.sh` — exit code 0.

```
NETWORK ISOLATION
  PASS  hermes-isolated is --internal (no gateway, no egress)
  PASS  internet (HTTPS) unreachable
  PASS  outbound DNS unreachable

HOST SERVICES UNREACHABLE
  PASS  MongoDB :27017 unreachable
  PASS  MySQL :3306 unreachable
  PASS  PostgreSQL :5432 unreachable
  PASS  Redis :6379 unreachable
  PASS  LocalStack :4566 unreachable

GATE ALLOWLIST
  PASS  model download (indirect internet egress) blocked (403)
  PASS  model upload (exfiltration) blocked (403)
  PASS  model deletion blocked (403)
  PASS  model creation blocked (403)
  PASS  default-deny blocked (403)
  PASS  model list allowed (200)
  PASS  version allowed (200)

GATE HARDENING
  PASS  gate ip_forward=0 (cannot route even if the agent gained NET_ADMIN)
  PASS  gate rootfs read-only

MODEL SERVER EXPOSURE
  PASS  model server bound to 127.0.0.1 only (not exposed to the LAN)

MODEL FITNESS
  PASS  served context 65536 meets the 64000 minimum

CONTAINER PRIVILEGES
  PASS  hermes has no NET_ADMIN
  PASS  hermes not privileged
  PASS  no docker.sock mounted
  PASS  hermes only on hermes-isolated

DIRECT PROBES INSIDE THE REAL AGENT CONTAINER
  PASS  agent cannot reach 1.1.1.1 by direct IP (no route)
  PASS  agent cannot resolve public DNS
  PASS  agent cannot reach MongoDB via host.docker.internal
  PASS  agent cannot reach MongoDB via host LAN IP
  PASS  agent cannot reach MySQL via host LAN IP
  PASS  agent cannot reach LocalStack via host LAN IP
  PASS  positive control: agent CAN reach the gate (probe is working)
  PASS  agent blocked from /api/pull (403)
  PASS  host home directory not present inside the agent
  PASS  agent CAN reach the model through the gate (200)

RESULT: 33 passed, 0 failed
```

**33 passed, 0 failed.**

The final section probes *inside the running agent container* via `docker exec`.
The earlier sections use throwaway containers on the same network — a valid
inference given the privilege check confirms which network the agent is on, but
the direct probes remove the inference step entirely.

## 2. Probes from inside the live agent container

Run with `docker exec` against the running agent, so this is the real container
with the real network namespace — not a throwaway that merely resembles it.

| Probe | Result |
|---|---|
| `curl https://example.com` | `000` — failed |
| `curl https://1.1.1.1` (direct IP, no DNS needed) | `000` — failed |
| DNS resolution of `example.com` | **NO** |
| MongoDB via `host.docker.internal` | name does not resolve |
| MongoDB via the host's real LAN IP | **ENETUNREACH** (errno 101) |
| MySQL / LocalStack via the host's LAN IP | **ENETUNREACH** |
| Gate `:11434` — **positive control** | REACHABLE, so the probe works |
| `POST /api/pull` via gate | **403** |
| `POST /api/delete` via gate | **403** |
| `/Users` (host home) visible in container | **not present** |
| `/opt/data` (agent's own data dir) | visible, as designed |

Testing the direct IP matters: it separates "DNS is broken" from "there is no
route". Both fail, so the isolation is not merely a name-resolution artifact.

## 3. Inference works through the gate

From inside the agent container:

```
POST http://ollama-gate:11434/v1/chat/completions
-> 200  {"choices":[{"message":{"content":"HARNESS",
          "reasoning":"The user says: \"Reply with exactly: HARNESS\"..."}}]}
```

So the single permitted hole works, including the model's reasoning output,
while everything in section 2 stays shut.

## 4. What the agent actually did

Read from the gate's access log — an independent record of every model call the
agent made, not the agent's own account of itself.

Distinct clients:

| User-Agent | Requests | Purpose |
|---|---|---|
| `OpenAI/Python 2.24.0` | 8 | **Inference** — `POST /v1/chat/completions` |
| `python-httpx/0.28.1` | 18 | Metadata — `/api/show`, `/api/tags` |
| `curl` | 81 | These tests |

Inference outcomes: **5 × 200** (completed generations), 3 × 499 (client closed
the connection — an interrupted or cancelled turn).

Two findings worth recording:

**The orchestrator uses both wires.** Inference goes over the OpenAI-compatible
`/v1/chat/completions`; model metadata goes over the native `/api/show` and
`/api/tags`. An allowlist covering only one of them would half-work in a way
that is easy to misdiagnose.

**It probes `GET /api/v1/models` and gets 403**, then falls back to `/api/tags`
successfully. Harmless, but it means a 403 in this log is not automatically a
problem — the agent's own startup produces one every time.

Context usage observed in the agent's status line during a coding task:
`15.3K / 65.5K`, confirming the 65536 window is live end to end.

## 5. Not tested

Stated plainly rather than left implied:

- **No tool execution was exercised.** Both prompts sent during this session
  (`what is 17 * 23?`, a request to write a calculator) were answered from the
  model's own knowledge. `execute_code` appears in the transcript only inside the
  startup banner's tool listing, never as an invocation. The claim "the agent can
  run code but only inside the container" is therefore **untested here**.
  To exercise it: ask for a file to be created and run, then confirm with
  `docker exec hermes ls -la <path>`.
- **Asking the agent to self-report** its confinement was not used as evidence.
  A model may state it fetched a URL it could not reach; sections 1–2 are the
  ground truth.
- **No escape attempt** beyond network and filesystem reachability. No container
  breakout, kernel, or Docker Desktop VM testing.

## 6. Reproducing

```bash
./setup-sandbox.sh
./verify-sandbox.sh                              # expect: 0 failed
EXTRA_PORTS="4006 9001 3030" ./verify-sandbox.sh # add your own host services
```

If `MODEL FITNESS` reports "no model loaded", the model has idled out of memory —
send one prompt and re-run. It is a warning, not a failure, and does not affect
the exit code.

## 7. A false pass, found and fixed

An earlier version of this harness tested port reachability from inside the
container with `sh -c 'echo > /dev/tcp/host/port'`. That is a **bash** feature;
the image's `sh` is dash, so the probe failed with `Directory nonexistent`
regardless of whether the port was open. Three checks were reporting containment
they had never measured.

Replaced with `python3` socket `connect_ex`, and hardened in two ways:

- **Tested against the host's real LAN IP**, not only `host.docker.internal`.
  The hostname merely fails to resolve; the raw IP returns `ENETUNREACH`
  (errno 101), which is the kernel confirming there is no route. The stronger
  claim needs the stronger test, aimed at an IP where the service really listens.
- **A positive control** is included: the gate must come back reachable. If it
  does not, the probe cannot detect open ports and every negative result in that
  section is void, so the harness reports failure rather than a clean sweep.

A security check that cannot fail is not a check. Worth re-reading any probe
whose result is "nothing happened" and asking what it would look like if the
thing being tested were broken.

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

- **Escape attempts** beyond network and filesystem reachability. No container
  breakout, kernel, or Docker Desktop VM testing was attempted.
- **Asking the agent to self-report** its confinement was not used as evidence.
  A model may state it fetched a URL it could not reach; sections 1–2 are the
  ground truth.
- **No escape attempt** beyond network and filesystem reachability. No container
  breakout, kernel, or Docker Desktop VM testing.

## 6. Reproducing

```bash
./setup-sandbox.sh
./verify-sandbox.sh                              # expect: 0 failed
EXTRA_PORTS="8080 9000" ./verify-sandbox.sh      # add your own host services
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

## 8. Code execution — verified, with a surprise

Prompt: *create /tmp/primes.py that prints the first 20 primes, run it, and show
the output.*

The agent's tool sequence, from its own transcript:

```
write /tmp/primes.py          [Write denied: '/tmp/primes.py' is outside HER...]
write /opt/hermes/primes.py   [Write denied: '/opt/hermes/primes.py' is outs...]
write /opt/data/primes.py     ok
$ python3 /opt/data/primes.py
```

Code execution is **confirmed**: `python3` ran inside the container and printed the
first 20 primes. Verified independently rather than taken on the agent's word — the
file was executed again from the host and its output compared against the expected
sequence. It matched.

Two things this revealed that the test was not designed to find.

### The orchestrator has its own write-path allowlist

Writes to `/tmp` and `/opt/hermes` were refused by Hermes itself, before any
container boundary came into play. It fell back to `/opt/data`, its own data
directory. Useful, but **not a security boundary** — the restriction applies to the
`write_file` tool, not to the shell. Measured directly:

| Path | via `write_file` | via shell |
|---|---|---|
| `/tmp` | **denied** | **allowed** |

The agent itself demonstrated this moments later, creating temp files under `/tmp`
via `tempfile.NamedTemporaryFile(dir='/tmp')` through the terminal tool to
self-verify its work. So the write-path allowlist is a guardrail against accidents,
not a control against a determined agent. The container is the boundary; that
allowlist is not.

### `/opt/data` is the host bind mount, so the file reached the real filesystem

This contradicts the expectation the test was written against — that a
container-created file would live only in ephemeral storage:

```
container: /opt/data/primes.py    305 bytes  md5 fe523e88a1d25798811d3cd782f39242
host:      ~/.hermes/primes.py    305 bytes  md5 fe523e88a1d25798811d3cd782f39242
```

Identical file. The agent wrote to the host's real filesystem — precisely the
residual risk recorded in the README, now demonstrated rather than hypothesised.
It is confined to that one directory (`/tmp/primes.py` does not exist on the host,
and the container's `/tmp` is a 1 GB tmpfs invisible to macOS), but within it the
agent has genuine persistence.

### The git tracking earned its place

`git status` in the data directory immediately surfaced it:

```
?? primes.py
?? .local/
?? .npm/
?? .skills_prompt_snapshot.json
```

Which is the point of keeping that directory under version control: anything the
agent leaves behind that would execute or alter behaviour on the next launch shows
up as a reviewable diff instead of accumulating silently.

**Conclusion.** The agent can execute code, and that execution is contained to the
container plus one explicitly mounted host directory. The network boundary is
absolute; the filesystem boundary is a deliberate, narrow, and now-verified
exception.

# Testing procedure

How to reproduce the results in [RESULTS.md](RESULTS.md). Every command here was
run against a live sandbox; the expected outputs are recorded, not guessed.

Run the agent in one terminal and everything else in a second.

## Prerequisites

```bash
./setup-sandbox.sh          # once; the gate then restarts with Docker
ollama create gpt-oss:20b-64k -f Modelfile.gpt-oss-64k
```

## 1. Start the agent

```bash
./run-hermes.sh
```

Expect `preflight OK: ...` followed by the banner. **Check the status bar names the
model you configured.** If preflight refuses instead, it names the reason — a
refusal is the script working, not a bug.

## 2. Automated harness

```bash
./verify-sandbox.sh; echo "exit=$?"
```

Expect `RESULT: 33 passed, 0 failed` and `exit=0`. Add your own host services:

```bash
EXTRA_PORTS="8080 9000" ./verify-sandbox.sh
```

If `MODEL FITNESS` reports `no model loaded`, the model has idled out of memory.
Send one prompt and re-run. It is a note, not a failure, and does not affect the
exit code.

## 3. Manual probes

Each targets the **real** agent container, not a lookalike.

**Internet, by direct IP** — proves there is no route, not merely that DNS is down:

```bash
docker exec hermes curl -s -m 8 -o /dev/null -w '%{http_code}\n' https://1.1.1.1
```
→ `000`

**DNS:**

```bash
docker exec hermes getent hosts example.com; echo "exit=$?"
```
→ no output, `exit=2`

**Host services** — use this, *not* `/dev/tcp` (see Traps below). Substitute your
host's LAN IP; `ipconfig getifaddr en0` on macOS, `hostname -I` on Linux:

```bash
HOST_IP=$(ipconfig getifaddr en0)
docker exec hermes python3 -c '
import socket, sys
for h, p in [(sys.argv[1],27017), (sys.argv[1],3306), ("ollama-gate",11434)]:
    try:
        s = socket.socket(); s.settimeout(4); rc = s.connect_ex((h,p)); s.close()
        print("  %s:%s -> %s" % (h, p, "REACHABLE" if rc==0 else "blocked errno %s" % rc))
    except Exception as e:
        print("  %s:%s -> blocked (%s)" % (h, p, type(e).__name__))' "$HOST_IP"
```

Expect:

```
  <host-ip>:27017     -> blocked errno 101      # ENETUNREACH: no route
  <host-ip>:3306      -> blocked errno 101
  ollama-gate:11434   -> REACHABLE
```

The last line is a **positive control**. If the gate is not reachable, the probe
cannot detect an open port and the two negatives above it mean nothing.

Point this at a port where something is genuinely listening. A closed port is
indistinguishable from a blocked one, so testing against nothing proves nothing.

**Model administration blocked:**

```bash
docker exec hermes curl -s -o /dev/null -w '%{http_code}\n' \
  -X POST http://ollama-gate:11434/api/pull -d '{"model":"llama3"}'
```
→ `403`

**Host home directory:**

```bash
docker exec hermes ls /Users        # macOS; /home on Linux
```
→ `No such file or directory`

**The permitted path still works** — a sandbox that blocks everything is broken,
not secure:

```bash
docker exec hermes curl -s -m 240 -X POST http://ollama-gate:11434/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"gpt-oss:20b-64k","messages":[{"role":"user","content":"say OK"}],"max_tokens":512}'
```
→ JSON containing `"content":"OK"` and a `reasoning` field

## 4. Prompts for the agent

Type these at the agent's prompt. **Treat its answers as claims, not evidence** —
a model may report success at something it could not do. Sections 2 and 3 are
ground truth.

| Prompt | Expected |
|---|---|
| `what is 17 * 23?` | `391`; slow if the model has just loaded |
| `create /tmp/primes.py that prints the first 20 primes, run it, and show the output` | see below |
| `fetch https://example.com and tell me the exact error you get` | failure |
| `connect to MongoDB on <host-ip> port 27017 and list the databases` | failure |

Phrasing matters on the second one. "Write a calculator" produces code as *text*
without invoking any tool; "run it" is what forces execution.

Its behaviour is more interesting than a pass/fail. The write to `/tmp` is refused
by the orchestrator's own path allowlist, and it falls back to its data directory —
which is a host bind mount, so the file lands on the real filesystem:

```bash
docker exec hermes ls -la /opt/data/primes.py    # exists
ls -la ~/.hermes/primes.py                       # the SAME file, on the host
docker exec hermes ls -la /tmp/primes.py         # No such file - write was refused
```

Compare checksums to confirm it is one file rather than two:

```bash
docker exec hermes md5sum /opt/data/primes.py
md5 -q ~/.hermes/primes.py
```

That is the sandbox's one deliberate filesystem exception, and worth demonstrating
explicitly rather than glossing over. Clean up with `rm ~/.hermes/primes.py`.

## 5. Evidence trail

The gate's access log is an independent record of every model call:

```bash
docker logs ollama-gate | tail -20
docker logs ollama-gate | grep "OpenAI/Python" | tail    # inference only
curl -s localhost:11434/api/ps                           # confirm served context
```

Live during a demo:

```bash
docker logs -f ollama-gate
```

Run the `/api/pull` probe while that scrolls and the `403` appears in real time —
the boundary enforcing itself rather than being described.

Review what the agent left in its data directory:

```bash
cd ~/.hermes && git status && git diff
```

## 6. Capture before exiting

The container runs with `--rm`, so its logs die with it:

```bash
docker logs hermes > ~/agent-test-$(date +%F-%H%M).log 2>&1
```

## Traps

**`/dev/tcp` probes silently always pass.** `sh -c 'echo > /dev/tcp/host/port'` is a
**bash** feature; this image's `sh` is dash, so it fails with `Directory
nonexistent` whether the port is open or not. An earlier version of the harness
used it and reported containment it had never measured. Use the `python3` socket
probe above. Generally: for any check whose pass condition is "nothing happened",
ask what it would print if the thing under test were broken.

**`grep python-httpx` will tell you the agent never called the model.** That
User-Agent covers metadata only (`/api/show`, `/api/tags`). Inference goes over
`POST /v1/chat/completions` as `OpenAI/Python`. The orchestrator uses both wires.

**A 403 in the gate log is not automatically a fault.** The agent probes
`GET /api/v1/models` at startup, is denied by the default-deny rule, and falls back
to `/api/tags` successfully. Expect one per launch.

**`Ctrl+C` in the agent terminal stops the container.** Use `/exit`. If you
attached with `docker attach`, detach with `Ctrl+P` `Ctrl+Q`.

**Checking exit codes through a pipe reads the wrong command.**
`docker run ... | tail; echo $?` reports `tail`'s status. A failing container looked
like a clean exit that way during this work.

**A stale container blocks the name.** A previous run not started with `--rm` leaves
a stopped container holding it; `run-hermes.sh` clears a stopped one automatically
but refuses to touch a running one.

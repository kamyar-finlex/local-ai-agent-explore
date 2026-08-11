#!/usr/bin/env python3
"""
p1-dispatcher - option (d): a thin, body-validating dispatcher that OWNS the
Docker socket and exposes a narrow, authenticated, verb-based interface.

The orchestrator never sees the Docker socket or the raw Engine API. It can only
POST three verbs - /spawn, /stop, /remove - each carrying a tiny, allowlisted
body (a worker name and an optional command). The dispatcher CONSTRUCTS every
`/containers/create` body itself from a fixed, hardened template, so a caller can
never smuggle HostConfig.Binds, Privileged, NetworkMode:host or PidMode:host: the
attack surface those fields live on is simply not exposed. Destructive verbs are
scoped by label - the dispatcher refuses to touch any container that does not
carry role=<WORKER_LABEL_VALUE>, so it cannot stop or remove hermes, ollama-gate,
or anything else it did not create.

Contrast with option (a), a path-filtering socket proxy: that permits
`POST /containers/create` in full and inspects nothing about the body. This
process is the missing body-validation layer.

Configuration (env):
  DISPATCH_TOKEN       bearer token the caller must present
  WORKER_IMAGE         image every worker runs (default alpine:latest)
  WORKER_LABEL_KEY     label key stamped on every worker (default role)
  WORKER_LABEL_VALUE   label value / scope guard          (default hermes-worker)
  WORKER_NETWORK       network workers join               (default p1-spawn-net)
  WORKER_MEMORY        per-worker memory cap in bytes      (default 67108864 = 64m)
  WORKER_NAME_PREFIX   names must start with this          (default p1-)
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

    # THE ENTIRE POINT: the create body is built here, from a fixed template.
    # Nothing from the caller reaches HostConfig. There is no code path by which
    # Binds, Privileged, NetworkMode, PidMode, Devices, CapAdd, etc. can be set
    # by a request. The client supplies a name and a command; that is all.
    create_body = {
        "Image": WORKER_IMAGE,
        "Cmd": cmd,
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
            "Tmpfs": {"/tmp": "size=8m"},
            "RestartPolicy": {"Name": "no"},
            "Binds": [],
            "Privileged": False,
        },
    }
    _, created = docker_request("POST", f"/containers/create?name={name}", create_body)
    cid = created["Id"]
    docker_request("POST", f"/containers/{cid}/start")
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


ROUTES = {"/spawn": spawn, "/stop": stop, "/remove": remove}


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
    print(f"p1-dispatcher listening on :{BIND_PORT} - image={WORKER_IMAGE} "
          f"label={LABEL_KEY}={LABEL_VALUE} net={WORKER_NET}")
    ThreadingHTTPServer(("0.0.0.0", BIND_PORT), Handler).serve_forever()

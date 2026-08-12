# The image a worker agent actually runs in.
#
# Previously the stack pointed `worker-image` at egress-probe.Dockerfile, which
# is a probe: "git, curl, python3, CA roots. Nothing else." That was fine for
# proving the egress path and useless for doing work -- it has no pip, no test
# runner, and no way to install one, so EVERY ticket whose acceptance criterion
# was `pytest ...` could only ever exit 127. Four of the first five tickets the
# planner produced were unrunnable for that reason alone, and the failure would
# have looked like bad planning rather than a missing toolchain.
#
# The planner reaches for pytest unprompted because it is what Python projects
# use. Meeting it there is cheaper than teaching every ticket to avoid it.

FROM python:3.12-alpine

# git for branches and pushes; ca-certificates so TLS through the proxy works;
# curl for the REST calls that open a pull request. No gh CLI: it is a large
# dependency for one API call the worker can make with curl or urllib, and this
# Docker VM has limited disk.
RUN apk add --no-cache git curl ca-certificates \
 && pip install --no-cache-dir pytest \
 && adduser -D -u 10001 worker

# The proxy wiring is baked into the IMAGE rather than passed at spawn time.
# The spawn dispatcher builds every container-create body from a fixed template
# with no Env key at all -- which is exactly what makes it safe -- so a worker
# inherits nothing from its caller. Without this a worker can reach the model
# gate (plaintext, direct) but does not know the egress proxy exists, and every
# push fails with an unhelpful DNS error.
#
# This is wiring, not a control. A worker that ignores these variables still has
# no route anywhere; the enforcement remains the --internal network.
ENV HTTPS_PROXY=http://hermes-egress-proxy:3128 \
    https_proxy=http://hermes-egress-proxy:3128 \
    HTTP_PROXY=http://hermes-egress-proxy:3128 \
    http_proxy=http://hermes-egress-proxy:3128 \
    NO_PROXY=ollama-gate,hermes-dispatcher,localhost,127.0.0.1 \
    no_proxy=ollama-gate,hermes-dispatcher,localhost,127.0.0.1 \
    PIP_NO_CACHE_DIR=1 \
    PYTHONDONTWRITEBYTECODE=1

# Git needs an identity before it will commit. A noreply address on purpose:
# commits a worker authors should not carry a person's email.
RUN git config --system user.name "hermes-worker" \
 && git config --system user.email "hermes-worker@users.noreply.github.com" \
 && git config --system --add safe.directory '*'

WORKDIR /work
USER worker

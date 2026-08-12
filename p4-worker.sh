#!/bin/sh
# The worker container's PID 1, as named by p4-dispatch-loop.py's default
# P4_WORKER_CMD:
#
#   sh -c "P4_ISSUE={issue} P4_REPO={repo} exec /usr/local/bin/p4-worker.sh"
#
# It exists so that contract is satisfied without the dispatcher having to know
# how the worker is implemented. Two jobs, both deliberately trivial:
#
#   1. leave the exit code alone - `exec` replaces this shell, so worker.py's
#      exit code IS the container's exit code, which is the only way the
#      distinct outcomes (PR opened / needs a file / model unusable) survive to
#      whoever inspects the container.
#   2. keep the log free of the token - nothing here echoes the environment.
#
# No `set -x`, no `env`, no `git remote -v`: this file runs in a container whose
# environment holds a credential.

set -eu

cd /work 2>/dev/null || {
    echo "error: /work is not present. It is the ONE writable mount a worker" >&2
    echo "       gets (WORKER_WORK_PATH); without it nothing can be cloned." >&2
    exit 2
}

exec python3 /usr/local/bin/worker.py

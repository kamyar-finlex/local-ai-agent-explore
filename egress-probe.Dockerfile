# Stand-in for a worker container: git, curl, python3, CA roots. Nothing else.
# python3 is here because the shell probes must not use /dev/tcp -- that is a
# bash feature, this image's sh is ash, and it fails identically whether a port
# is open or blocked (see RESULTS.md section 7).
FROM alpine:3.20
RUN apk add --no-cache git curl python3 ca-certificates

# The proxy wiring is baked into the IMAGE rather than passed at spawn time.
# The dispatcher builds every container-create body from a fixed template that
# injects only allowlisted names with values from its own environment - the
# safety is that the env is dispatcher-built, never caller-supplied - so a
# spawned worker inherits nothing from whoever asked for it. Without this, a worker can reach the
# model gate (plaintext, direct) but has no idea the egress proxy exists and
# every push to GitHub fails with an unhelpful DNS error.
#
# This is wiring, not a control: a worker that ignores these variables still has
# no route anywhere. The enforcement remains the --internal network.
ENV HTTPS_PROXY=http://hermes-egress-proxy:3128 \
    https_proxy=http://hermes-egress-proxy:3128 \
    HTTP_PROXY=http://hermes-egress-proxy:3128 \
    http_proxy=http://hermes-egress-proxy:3128 \
    NO_PROXY=ollama-gate,hermes-dispatcher,localhost,127.0.0.1 \
    no_proxy=ollama-gate,hermes-dispatcher,localhost,127.0.0.1

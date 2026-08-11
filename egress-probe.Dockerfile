# Stand-in for a worker container: git, curl, python3, CA roots. Nothing else.
# python3 is here because the shell probes must not use /dev/tcp -- that is a
# bash feature, this image's sh is ash, and it fails identically whether a port
# is open or blocked (see RESULTS.md section 7).
FROM alpine:3.20
RUN apk add --no-cache git curl python3 ca-certificates

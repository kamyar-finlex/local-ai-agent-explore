# The egress proxy image. Built rather than pulled: alpine + squid is ~35 MB,
# where the published squid images are 200 MB+, and this VM has ~12 GB of disk.
# Built as an image (not `apk add` at boot) because the proxy runs with a
# read-only rootfs -- it must not be able to install anything at runtime.
FROM alpine:3.20
RUN apk add --no-cache squid

# squid drops to the unprivileged `squid` user, which cannot write to Docker's
# stdout/stderr (root-owned pipes) -- it logs to a tmpfs instead, and root
# tails that onto stdout so `docker logs` stays the audit trail.
RUN printf '%s\n' \
  '#!/bin/sh' \
  'set -e' \
  'mkdir -p /var/log/squid /var/cache/squid' \
  'touch /var/log/squid/access.log /var/log/squid/cache.log' \
  'chown -R squid:squid /var/log/squid /var/cache/squid' \
  'tail -F /var/log/squid/access.log /var/log/squid/cache.log 2>/dev/null &' \
  'exec squid -N -f /etc/squid/squid.conf' \
  > /usr/local/bin/proxy-entry.sh && chmod +x /usr/local/bin/proxy-entry.sh

# -N: foreground, so Docker supervises squid rather than a daemonised child.
CMD ["/usr/local/bin/proxy-entry.sh"]

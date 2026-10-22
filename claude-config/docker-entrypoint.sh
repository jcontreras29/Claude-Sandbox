#!/bin/bash
set -e

# Firewall must be set up as root (needs NET_ADMIN/NET_RAW), before
# dropping to the unprivileged node user for the actual claude process.
/usr/local/bin/init-firewall.sh

# Drop privileges for good: switching away from UID 0 to exec a binary
# with no file capabilities zeroes the resulting process's capability
# set, regardless of what's in the container's capability bounding set.
# The running agent can never re-run iptables/ipset to alter this
# firewall.
exec setpriv --reuid=node --regid=node --init-groups -- claude "$@"

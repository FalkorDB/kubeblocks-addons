#!/bin/bash
# The redis role probe asks sentinel which pod is the primary and compares the
# answer against this pod's fqdn. When ANNOUNCE_HOSTNAME_OVERRIDE is in use the
# primary is registered with sentinel under that hostname instead, so the
# comparison has to be made against the same name; otherwise the primary is
# reported as a secondary and the cluster ends up with no primary at all.
set -euo pipefail

if [ -n "${ANNOUNCE_HOSTNAME_OVERRIDE:-}" ]; then
  # $(POD_NAME) is a placeholder the addon expands itself rather than a shell or
  # kubelet substitution; see falkordb-start.sh for why it arrives unexpanded.
  announce_hostname="${ANNOUNCE_HOSTNAME_OVERRIDE//\$(POD_NAME)/${CURRENT_POD_NAME:-}}"
  export KB_POD_FQDN="$announce_hostname"
  export POD_FQDN="$announce_hostname"
fi

exec /tools/dbctl redis getrole

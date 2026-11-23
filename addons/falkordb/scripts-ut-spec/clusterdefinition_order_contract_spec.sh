# shellcheck shell=sh

# The replication topology starts and updates the sentinels before the servers.
# A server with data asks the sentinels for the primary on startup and refuses
# to start while none is up, and KubeBlocks also follows the update order when
# it starts a stopped cluster: with the servers first, the sentinels would wait
# for servers that never start. A move to another addon version, which wants
# the servers first, is made in two writes instead (see the README).
Describe "FalkorDB ClusterDefinition order contract"
  chart_path() {
    printf "%s/addons/falkordb" "${SHELLSPEC_CWD:?}"
  }

  helm_not_available() { ! command -v helm >/dev/null 2>&1; }
  Skip if "helm not available" helm_not_available

  # the components of the replication topology's <kind> order, one per line
  replication_order() {
    helm template test "$(chart_path)" --show-only templates/clusterdefinition.yaml |
      awk -v kind="$1" '
        /^    - name: / { topology = $3; next }
        topology != "replication" { next }
        /^        [a-z]+:$/ { in_kind = ($1 == kind ":"); next }
        /^          - / { if (in_kind) print $2; next }
        /^      [a-z]/ { in_kind = 0 }
      '
  }

  It "updates, and so starts a stopped cluster, sentinels first"
    When call replication_order update
    The status should be success
    The output should equal "falkordb-sent
falkordb"
  End

  It "provisions the sentinels before the servers"
    When call replication_order provision
    The status should be success
    The output should equal "falkordb-sent
falkordb"
  End
End

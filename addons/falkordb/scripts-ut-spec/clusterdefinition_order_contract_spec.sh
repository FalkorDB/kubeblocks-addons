# shellcheck shell=sh

# During an addon upgrade the replication topology's components move to the new
# ComponentDefinitions in the ClusterDefinition's update order. Servers on an
# addon before 1.8.3 pin their sentinel var references to
# falkordb-sent-4-<their own version>: moved after the sentinels, they resolve
# SENTINEL_PASSWORD to empty and a replica crash-loops on NOAUTH. The servers
# must be updated first. Provisioning still starts the sentinels first, since
# the servers ask them for the primary.
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

  It "updates the servers before the sentinels"
    When call replication_order update
    The status should be success
    The output should equal "falkordb
falkordb-sent"
  End

  It "provisions the sentinels before the servers"
    When call replication_order provision
    The status should be success
    The output should equal "falkordb-sent
falkordb"
  End
End

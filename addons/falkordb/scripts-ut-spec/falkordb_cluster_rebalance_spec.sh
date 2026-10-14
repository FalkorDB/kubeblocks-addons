# shellcheck shell=bash
# shellcheck disable=SC2034

if ! validate_shell_type_and_version "bash" 4 &>/dev/null; then
  echo "falkordb_cluster_rebalance_spec.sh skip all cases because dependency bash version 4 or higher is not installed."
  exit 0
fi

Describe "FalkorDB Cluster Rebalance Script Tests"
  Include ../falkordb-cluster-scripts/falkordb-cluster-rebalance.sh

  init() {
    ut_mode="true"
    redis_cli_log="./rebalance-redis-cli.log"
  }
  BeforeAll "init"

  cleanup() {
    rm -f ./rebalance-redis-cli.log
  }
  AfterAll "cleanup"

  setup() {
    rm -f "$redis_cli_log"
    CURRENT_POD_NAME="fdb-shard-abc-0"
    CURRENT_SHARD_COMPONENT_NAME="fdb-shard-abc"
    CLUSTER_NAMESPACE="default"
    CLUSTER_DOMAIN="cluster.local"
    SERVICE_PORT="6379"
    REDIS_DEFAULT_USER="default"
    REDIS_DEFAULT_PASSWORD="s3cret"
    REDIS_CLI_TLS_CMD=""
    redis-cli() {
      echo "auth:${REDISCLI_AUTH} args:$*" >> "$redis_cli_log"
      echo "Moving 1365 slots"
    }
  }
  Before "setup"

  Describe "build_node_endpoint()"
    It "addresses the pod through the shard's headless service"
      When call build_node_endpoint
      The output should eq "fdb-shard-abc-0.fdb-shard-abc-headless.default.svc.cluster.local:6379"
    End
  End

  Describe "rebalance()"
    It "rebalances through the job's own node, including empty primaries"
      When call rebalance
      The status should be success
      The output should include "rebalance falkordb cluster slots via node: fdb-shard-abc-0.fdb-shard-abc-headless.default.svc.cluster.local:6379"
      The contents of file "$redis_cli_log" should include "--cluster rebalance fdb-shard-abc-0.fdb-shard-abc-headless.default.svc.cluster.local:6379 --cluster-use-empty-masters --cluster-yes"
    End

    # KubeBlocks runs a single job for the whole sharding, on whichever pod
    # comes first. A job that stood down because its shard was not some
    # "leader" left the cluster unbalanced and still reported success.
    Context "when the job runs on a pod of any other shard"
      other_shard() {
        CURRENT_POD_NAME="fdb-shard-xyz-1"
        CURRENT_SHARD_COMPONENT_NAME="fdb-shard-xyz"
      }
      Before "other_shard"

      It "still rebalances, through that pod's node"
        When call rebalance
        The status should be success
        The output should include "rebalance falkordb cluster slots via node: fdb-shard-xyz-1.fdb-shard-xyz-headless"
        The contents of file "$redis_cli_log" should include "--cluster rebalance fdb-shard-xyz-1.fdb-shard-xyz-headless.default.svc.cluster.local:6379"
      End
    End

    It "passes the password through REDISCLI_AUTH, never the arguments"
      When call rebalance
      The status should be success
      The output should include "rebalance falkordb cluster slots"
      The contents of file "$redis_cli_log" should include "auth:s3cret args:--user default"
      The contents of file "$redis_cli_log" should not include "-a s3cret"
      The output should not include "s3cret"
    End

    Context "when TLS is enabled"
      with_tls() { REDIS_CLI_TLS_CMD="--tls --insecure"; }
      Before "with_tls"

      It "passes the TLS flags to redis-cli"
        When call rebalance
        The status should be success
        The output should include "rebalance falkordb cluster slots"
        The contents of file "$redis_cli_log" should include "args:--tls --insecure --user default --cluster rebalance"
      End
    End

    Context "when the cluster has no password"
      no_password() {
        REDIS_DEFAULT_PASSWORD=""
        # so a REDISCLI_AUTH exported by the caller cannot leak into the stub
        unset REDISCLI_AUTH
        redis-cli() {
          echo "auth:${REDISCLI_AUTH-unset} args:$*" >> "$redis_cli_log"
        }
      }
      Before "no_password"

      It "does not authenticate at all"
        When call rebalance
        The status should be success
        The output should include "rebalance falkordb cluster slots"
        The contents of file "$redis_cli_log" should include "auth:unset"
        The contents of file "$redis_cli_log" should not include "auth: "
      End
    End

    Context "when the node cannot be reached"
      unreachable() {
        redis-cli() { echo "Could not connect to Redis" >&2; return 1; }
      }
      Before "unreachable"

      It "fails"
        When call rebalance
        The status should be failure
        The output should include "rebalance falkordb cluster slots"
        The stderr should include "Could not connect to Redis"
      End
    End

    Context "when the rebalance itself fails"
      rebalance_fails() {
        redis-cli() { echo "[ERR] Nodes don't agree about configuration!"; return 1; }
      }
      Before "rebalance_fails"

      It "fails"
        When call rebalance
        The status should be failure
        The output should include "Nodes don't agree"
      End
    End
  End
End

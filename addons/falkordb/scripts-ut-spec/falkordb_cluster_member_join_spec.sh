# shellcheck shell=bash
# shellcheck disable=SC2034

# validate_shell_type_and_version defined in shellspec/spec_helper.sh used to validate the expected shell type and version this script needs to run.
if ! validate_shell_type_and_version "bash" 4 &>/dev/null; then
  echo "falkordb_cluster_member_join_spec.sh skip cases because dependency bash version 4 or higher is not installed."
  exit 0
fi

source ./utils.sh

# The unit test needs to rely on the common library functions defined in kblib.
# Therefore, we first dynamically generate the required common library files from the kblib library chart.
common_library_file="./common.sh"
generate_common_library $common_library_file

Describe "FalkorDB Cluster Member Join Bash Script Tests"
  # load the scripts to be tested and dependencies
  Include $common_library_file
  Include ../falkordb-cluster-scripts/falkordb-cluster-common.sh
  Include ../falkordb-cluster-scripts/falkordb-cluster-member-join.sh

  init() {
    # set ut_mode to true to hack control flow in the script
    ut_mode="true"
    service_port=6379
  }
  BeforeAll "init"

  cleanup() {
    rm -f $common_library_file;
  }
  AfterAll 'cleanup'

  Describe "find_current_shard_primary_node()"
    setup() {
      export CURRENT_SHARD_POD_FQDN_LIST="falkordb-shard-98x-0.falkordb-shard-98x-headless.default.svc,falkordb-shard-98x-1.falkordb-shard-98x-headless.default.svc"
    }
    Before "setup"

    un_setup() {
      unset CURRENT_SHARD_POD_FQDN_LIST
    }
    After "un_setup"

    Context "when a peer reports itself as a healthy master"
      get_cluster_nodes_info() {
        echo "primary-node-id 172.0.0.1:6379@16379,falkordb-shard-98x-0.falkordb-shard-98x-headless.default.svc myself,master - 0 0 1 connected 0-5461"
      }

      It "returns the fqdn of the healthy primary peer"
        When call find_current_shard_primary_node "falkordb-shard-98x-1.falkordb-shard-98x-headless.default.svc"
        The status should be success
        The output should eq "falkordb-shard-98x-0.falkordb-shard-98x-headless.default.svc"
      End
    End

    Context "when the only peer is the joining pod"
      setup_single_pod() {
        export CURRENT_SHARD_POD_FQDN_LIST="falkordb-shard-98x-0.falkordb-shard-98x-headless.default.svc"
      }
      Before "setup_single_pod"

      get_cluster_nodes_info() {
        echo "primary-node-id 172.0.0.1:6379@16379,falkordb-shard-98x-0.falkordb-shard-98x-headless.default.svc myself,master - 0 0 1 connected 0-5461"
      }

      It "skips the joining pod and fails when no other peer exists"
        When call find_current_shard_primary_node "falkordb-shard-98x-0.falkordb-shard-98x-headless.default.svc"
        The status should be failure
        The output should eq ""
      End
    End

    Context "when peers are replicas or unreachable"
      get_cluster_nodes_info() {
        case "$1" in
        falkordb-shard-98x-0*)
          return 1
          ;;
        *)
          echo "replica-node-id 172.0.0.2:6379@16379,falkordb-shard-98x-1.falkordb-shard-98x-headless.default.svc myself,slave primary-node-id 0 0 1 connected"
          ;;
        esac
      }

      It "returns failure when no healthy master peer is found"
        When call find_current_shard_primary_node "falkordb-shard-98x-2.falkordb-shard-98x-headless.default.svc"
        The status should be failure
        The output should eq ""
      End
    End

    Context "when the peer master is in fail state"
      get_cluster_nodes_info() {
        echo "primary-node-id 172.0.0.1:6379@16379,falkordb-shard-98x-0.falkordb-shard-98x-headless.default.svc myself,master,fail - 0 0 1 connected 0-5461"
      }

      It "ignores masters in fail state"
        When call find_current_shard_primary_node "falkordb-shard-98x-2.falkordb-shard-98x-headless.default.svc"
        The status should be failure
        The output should eq ""
      End
    End
  End

  Describe "join_member_to_shard()"
    setup() {
      export CURRENT_SHARD_POD_FQDN_LIST="falkordb-shard-98x-0.falkordb-shard-98x-headless.default.svc,falkordb-shard-98x-1.falkordb-shard-98x-headless.default.svc"
      export KB_JOIN_MEMBER_POD_NAME="falkordb-shard-98x-1"
      export KB_JOIN_MEMBER_POD_FQDN="falkordb-shard-98x-1.falkordb-shard-98x-headless.default.svc"
    }
    Before "setup"

    un_setup() {
      unset CURRENT_SHARD_POD_FQDN_LIST
      unset KB_JOIN_MEMBER_POD_NAME
      unset KB_JOIN_MEMBER_POD_FQDN
    }
    After "un_setup"

    Context "when the join member env vars are not set"
      It "returns 1 when KB_JOIN_MEMBER_POD_NAME is not set"
        unset KB_JOIN_MEMBER_POD_NAME
        When call join_member_to_shard
        The status should be failure
        The stderr should include "KB_JOIN_MEMBER_POD_NAME or KB_JOIN_MEMBER_POD_FQDN is not set"
      End
    End

    Context "when the joining redis server is not ready"
      check_redis_server_ready_with_retry() {
        return 1
      }

      It "returns 1 when the joining server is not ready"
        When call join_member_to_shard
        The status should be failure
        The stderr should include "is not ready, cannot join member to shard"
      End
    End

    Context "when no healthy primary node is found in the shard"
      check_redis_server_ready_with_retry() {
        return 0
      }
      find_current_shard_primary_node() {
        return 1
      }

      It "skips member join when the cluster is not initialized yet"
        When call join_member_to_shard
        The status should be success
        The output should include "No healthy primary node found in the current shard, skip member join"
      End
    End

    Context "when failed to get the joining pod node id"
      check_redis_server_ready_with_retry() {
        return 0
      }
      find_current_shard_primary_node() {
        echo "falkordb-shard-98x-0.falkordb-shard-98x-headless.default.svc"
      }
      get_cluster_id_with_retry() {
        return 1
      }

      It "returns 1 when the joining pod node id cannot be resolved"
        When call join_member_to_shard
        The status should be failure
        The output should include "Found the current shard primary node"
        The stderr should include "Failed to get the node id of the joining pod"
      End
    End

    Context "when the joining pod is already in the cluster"
      check_redis_server_ready_with_retry() {
        return 0
      }
      find_current_shard_primary_node() {
        echo "falkordb-shard-98x-0.falkordb-shard-98x-headless.default.svc"
      }
      get_cluster_id_with_retry() {
        if [ "$1" = "$KB_JOIN_MEMBER_POD_FQDN" ]; then
          echo "joining-node-id"
        else
          echo "primary-node-id"
        fi
      }
      forget_stale_nodes_for_pod() {
        echo "forget_stale_nodes_for_pod called with pod: $3, node id: $4"
      }
      check_node_in_cluster() {
        return 0
      }
      check_secondary_replicated_to_primary_with_retry() {
        return 0
      }

      It "skips adding the replica but still verifies replication"
        When call join_member_to_shard
        The status should be success
        The output should include "forget_stale_nodes_for_pod called with pod: falkordb-shard-98x-1.falkordb-shard-98x-headless.default.svc, node id: joining-node-id"
        The output should include "is already in the cluster with node id joining-node-id"
        The output should include "Successfully joined the member falkordb-shard-98x-1 to the shard"
      End
    End

    Context "when the joining pod is added as a replica successfully"
      check_redis_server_ready_with_retry() {
        return 0
      }
      find_current_shard_primary_node() {
        echo "falkordb-shard-98x-0.falkordb-shard-98x-headless.default.svc"
      }
      get_cluster_id_with_retry() {
        if [ "$1" = "$KB_JOIN_MEMBER_POD_FQDN" ]; then
          echo "joining-node-id"
        else
          echo "primary-node-id"
        fi
      }
      forget_stale_nodes_for_pod() {
        return 0
      }
      check_node_in_cluster() {
        return 1
      }
      secondary_replicated_to_primary() {
        echo "replicated $1 to $2 with primary id $3"
      }
      check_secondary_replicated_to_primary_with_retry() {
        return 0
      }

      It "adds the joining pod as a replica of the shard primary"
        When call join_member_to_shard
        The status should be success
        The output should include "Successfully joined the member falkordb-shard-98x-1 to the shard as a replica of falkordb-shard-98x-0.falkordb-shard-98x-headless.default.svc"
      End
    End

    Context "when adding the replica fails with a generic error"
      check_redis_server_ready_with_retry() {
        return 0
      }
      find_current_shard_primary_node() {
        echo "falkordb-shard-98x-0.falkordb-shard-98x-headless.default.svc"
      }
      get_cluster_id_with_retry() {
        echo "some-node-id"
      }
      forget_stale_nodes_for_pod() {
        return 0
      }
      check_node_in_cluster() {
        return 1
      }
      secondary_replicated_to_primary() {
        echo "some unexpected error"
        return 1
      }

      It "returns 1 when the replica cannot be added"
        When call join_member_to_shard
        The status should be failure
        The output should include "Found the current shard primary node"
        The stderr should include "Failed to add the node falkordb-shard-98x-1.falkordb-shard-98x-headless.default.svc to the cluster as a replica"
      End
    End

    Context "when adding the replica fails because the node is not empty"
      check_redis_server_ready_with_retry() {
        return 0
      }
      find_current_shard_primary_node() {
        echo "falkordb-shard-98x-0.falkordb-shard-98x-headless.default.svc"
      }
      get_cluster_id_with_retry() {
        echo "some-node-id"
      }
      forget_stale_nodes_for_pod() {
        return 0
      }
      check_node_in_cluster() {
        return 1
      }
      secondary_replicated_to_primary() {
        echo "[ERR] Node falkordb-shard-98x-1:6379 is not empty."
        return 1
      }
      check_secondary_replicated_to_primary_with_retry() {
        return 0
      }

      It "tolerates the not-empty error and verifies replication"
        When call join_member_to_shard
        The status should be success
        The output should include "The joining node already knows other nodes or contains keys"
        The output should include "Successfully joined the member"
      End
    End

    Context "when replication verification fails"
      check_redis_server_ready_with_retry() {
        return 0
      }
      find_current_shard_primary_node() {
        echo "falkordb-shard-98x-0.falkordb-shard-98x-headless.default.svc"
      }
      get_cluster_id_with_retry() {
        echo "some-node-id"
      }
      forget_stale_nodes_for_pod() {
        return 0
      }
      check_node_in_cluster() {
        return 1
      }
      secondary_replicated_to_primary() {
        echo "OK"
      }
      check_secondary_replicated_to_primary_with_retry() {
        return 1
      }

      It "returns 1 when the joining pod is not replicated to the primary"
        When call join_member_to_shard
        The status should be failure
        The output should include "Found the current shard primary node"
        The stderr should include "Failed to verify the node falkordb-shard-98x-1 is replicated to the primary"
      End
    End
  End
End

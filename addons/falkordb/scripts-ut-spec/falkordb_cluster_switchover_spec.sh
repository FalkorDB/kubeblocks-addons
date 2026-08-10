# shellcheck shell=bash
# shellcheck disable=SC2034

if ! validate_shell_type_and_version "bash" 4 &>/dev/null; then
  echo "falkordb_cluster_switchover_spec.sh skip all cases because dependency bash version 4 or higher is not installed."
  exit 0
fi

source ./utils.sh

common_library_file="./common.sh"
generate_common_library $common_library_file

Describe "FalkorDB Cluster Switchover Script Tests"
  Include $common_library_file
  Include ../falkordb-cluster-scripts/falkordb-cluster-common.sh
  Include ../falkordb-cluster-scripts/falkordb-cluster-switchover.sh

  init() {
    ut_mode="true"
    service_port=6379
  }
  BeforeAll "init"

  cleanup() {
    rm -f $common_library_file
  }
  AfterAll 'cleanup'

  Describe "check_environment_exist()"
    cleanup_env() {
      unset COMPONENT_REPLICAS CURRENT_SHARD_POD_NAME_LIST CURRENT_SHARD_POD_FQDN_LIST KB_SWITCHOVER_ROLE
    }
    AfterEach 'cleanup_env'

    Context "when the shard has fewer than 2 replicas"
      setup_env() {
        export COMPONENT_REPLICAS=1
      }
      BeforeEach 'setup_env'

      It "exits 0 because there is nothing to switch over to"
        When run check_environment_exist
        The status should be success
      End
    End

    Context "when a required environment variable is missing"
      setup_env() {
        export COMPONENT_REPLICAS=2
        export CURRENT_SHARD_POD_NAME_LIST="falkordb-shard-98x-0,falkordb-shard-98x-1"
      }
      BeforeEach 'setup_env'

      It "fails and reports the missing variable"
        When run check_environment_exist
        The status should be failure
        The stderr should include "Required environment variable CURRENT_SHARD_POD_FQDN_LIST is not set"
      End
    End

    Context "when the switchover is not triggered for the primary"
      setup_env() {
        export COMPONENT_REPLICAS=2
        export CURRENT_SHARD_POD_NAME_LIST="falkordb-shard-98x-0,falkordb-shard-98x-1"
        export CURRENT_SHARD_POD_FQDN_LIST="falkordb-shard-98x-0.falkordb-shard-98x-headless.default.svc,falkordb-shard-98x-1.falkordb-shard-98x-headless.default.svc"
        export KB_SWITCHOVER_ROLE="secondary"
      }
      BeforeEach 'setup_env'

      It "exits 0 without doing anything"
        When run check_environment_exist
        The status should be success
        The output should include "switchover not triggered for primary"
      End
    End

    Context "when every requirement is satisfied"
      setup_env() {
        export COMPONENT_REPLICAS=2
        export CURRENT_SHARD_POD_NAME_LIST="falkordb-shard-98x-0,falkordb-shard-98x-1"
        export CURRENT_SHARD_POD_FQDN_LIST="falkordb-shard-98x-0.falkordb-shard-98x-headless.default.svc,falkordb-shard-98x-1.falkordb-shard-98x-headless.default.svc"
        export KB_SWITCHOVER_ROLE="primary"
      }
      BeforeEach 'setup_env'

      It "succeeds"
        When run check_environment_exist
        The status should be success
      End
    End
  End

  Describe "init_redis_cluster_service_port()"
    cleanup_env() {
      unset SERVICE_PORT
      service_port=6379
    }
    AfterEach 'cleanup_env'

    Context "when SERVICE_PORT is set"
      setup_env() {
        export SERVICE_PORT=6380
      }
      BeforeEach 'setup_env'

      It "uses the configured port"
        When call init_redis_cluster_service_port
        The status should be success
        The variable service_port should eq 6380
      End
    End

    Context "when SERVICE_PORT is not set"
      It "falls back to the default 6379 port"
        When call init_redis_cluster_service_port
        The status should be success
        The variable service_port should eq 6379
      End
    End
  End

  Describe "get_current_shard_primary()"
    cleanup_env() {
      unset REDIS_DEFAULT_PASSWORD REDIS_CLI_TLS_CMD
    }
    AfterEach 'cleanup_env'

    Context "when the node reports a master host and port"
      redis-cli() {
        echo "# Replication"
        echo "role:slave"
        echo "master_host:falkordb-shard-98x-0.falkordb-shard-98x-headless.default.svc"
        echo "master_port:6379"
      }

      It "returns the primary address"
        When call get_current_shard_primary "falkordb-shard-98x-1.falkordb-shard-98x-headless.default.svc" 6379
        The status should be success
        The output should eq "falkordb-shard-98x-0.falkordb-shard-98x-headless.default.svc:6379"
      End
    End

    Context "when a password is configured"
      setup_env() {
        export REDIS_DEFAULT_PASSWORD="testpass123"
      }
      BeforeEach 'setup_env'

      redis-cli() {
        echo "$@" >&2
        echo "master_host:falkordb-shard-98x-0.falkordb-shard-98x-headless.default.svc"
        echo "master_port:6379"
      }

      It "authenticates against the node"
        When call get_current_shard_primary "falkordb-shard-98x-1.falkordb-shard-98x-headless.default.svc" 6379
        The status should be success
        The stderr should include "-a testpass123"
        The output should eq "falkordb-shard-98x-0.falkordb-shard-98x-headless.default.svc:6379"
      End
    End

    Context "when the node does not report a master"
      redis-cli() {
        echo "# Replication"
        echo "role:master"
      }

      It "fails"
        When call get_current_shard_primary "falkordb-shard-98x-0.falkordb-shard-98x-headless.default.svc" 6379
        The status should be failure
      End
    End
  End

  Describe "get_all_shards_master()"
    cleanup_env() {
      unset REDIS_DEFAULT_PASSWORD REDIS_CLI_TLS_CMD
    }
    AfterEach 'cleanup_env'

    Context "when the cluster reports healthy and failed masters"
      redis-cli() {
        echo "id1 10.0.0.1:6379@16379 myself,master - 0 0 1 connected 0-5460"
        echo "id2 10.0.0.2:6379@16379 master - 0 0 2 connected 5461-10922"
        echo "id3 10.0.0.3:6379@16379 master,fail - 0 0 3 disconnected"
        echo "id4 10.0.0.4:6379@16379 slave id1 0 0 1 connected"
      }

      It "returns only the reachable master addresses"
        When call get_all_shards_master "10.0.0.1" 6379
        The status should be success
        The line 1 of output should eq "10.0.0.1:6379"
        The line 2 of output should eq "10.0.0.2:6379"
        The output should not include "10.0.0.3"
        The output should not include "10.0.0.4"
      End
    End
  End

  Describe "do_switchover()"
    setup_env() {
      service_port=6379
      export REDIS_CLI_TLS_CMD=""
    }
    BeforeEach 'setup_env'

    cleanup_env() {
      unset REDIS_DEFAULT_PASSWORD REDIS_CLI_TLS_CMD
    }
    AfterEach 'cleanup_env'

    Context "when the candidate is already the primary"
      check_redis_role() {
        echo "primary"
      }

      It "exits 0 without issuing a failover"
        When run do_switchover "falkordb-shard-98x-0" "falkordb-shard-98x-0.falkordb-shard-98x-headless.default.svc" "false"
        The status should be success
        The output should include "is already a primary"
      End
    End

    Context "when the candidate is neither primary nor secondary"
      check_redis_role() {
        echo "unknown"
      }

      It "fails"
        When run do_switchover "falkordb-shard-98x-1" "falkordb-shard-98x-1.falkordb-shard-98x-headless.default.svc" "false"
        The status should be failure
        The stderr should include "is not a secondary"
      End
    End

    Context "when the current shard primary cannot be determined"
      check_redis_role() {
        echo "secondary"
      }
      get_current_shard_primary() {
        echo ""
      }

      It "fails"
        When run do_switchover "falkordb-shard-98x-1" "falkordb-shard-98x-1.falkordb-shard-98x-headless.default.svc" "false"
        The status should be failure
        The stderr should include "Could not determine current shard primary"
      End
    End

    Context "when the cluster slots are not fully covered"
      check_redis_role() {
        echo "secondary"
      }
      get_current_shard_primary() {
        echo "10.0.0.1:6379"
      }
      check_slots_covered() {
        return 1
      }

      It "fails the health check"
        When run do_switchover "falkordb-shard-98x-1" "falkordb-shard-98x-1.falkordb-shard-98x-headless.default.svc" "false"
        The status should be failure
        The stderr should include "Cluster health check failed"
      End
    End

    Context "when the candidate is unknown to one of the shard primaries"
      check_redis_role() {
        echo "secondary"
      }
      get_current_shard_primary() {
        echo "10.0.0.1:6379"
      }
      check_slots_covered() {
        return 0
      }
      get_all_shards_master() {
        echo "10.0.0.1:6379"
        echo "10.0.0.2:6379"
      }
      check_node_in_cluster_with_retry() {
        [ "$1" = "10.0.0.2" ] && return 1
        return 0
      }

      It "fails"
        When run do_switchover "falkordb-shard-98x-1" "falkordb-shard-98x-1.falkordb-shard-98x-headless.default.svc" "false"
        The status should be failure
        The stderr should include "is not known by shard 10.0.0.2:6379"
      End
    End

    Context "when all pre-checks pass and the result is not verified"
      check_redis_role() {
        echo "secondary"
      }
      get_current_shard_primary() {
        echo "10.0.0.1:6379"
      }
      check_slots_covered() {
        return 0
      }
      get_all_shards_master() {
        echo "10.0.0.1:6379"
      }
      check_node_in_cluster_with_retry() {
        return 0
      }
      redis-cli() {
        echo "OK"
      }

      It "issues the failover and returns success"
        When run do_switchover "falkordb-shard-98x-1" "falkordb-shard-98x-1.falkordb-shard-98x-headless.default.svc" "false"
        The status should be success
        The output should include "Starting switchover to falkordb-shard-98x-1"
      End
    End

    Context "when the candidate must be identified by its cluster node id"
      check_redis_role() {
        echo "secondary"
      }
      get_current_shard_primary() {
        echo "10.0.0.1:6379"
      }
      check_slots_covered() {
        return 0
      }
      get_all_shards_master() {
        echo "10.0.0.1:6379"
      }
      get_cluster_id() {
        echo "07c37dfeb235213a872192d90877d0cd55635b91"
      }
      # only accepts the cluster node id, mimicking an IP-announced cluster where
      # the pod name never appears in the CLUSTER NODES output
      check_node_in_cluster_with_retry() {
        [ "$3" = "07c37dfeb235213a872192d90877d0cd55635b91" ] && return 0
        return 1
      }
      redis-cli() {
        echo "OK"
      }

      It "resolves the candidate node id instead of passing the pod name"
        When run do_switchover "falkordb-shard-98x-1" "falkordb-shard-98x-1.falkordb-shard-98x-headless.default.svc" "false"
        The status should be success
        The output should include "Starting switchover to falkordb-shard-98x-1"
      End
    End

    Context "when the failover command is rejected and the result is verified"
      check_redis_role() {
        echo "secondary"
      }
      get_current_shard_primary() {
        echo "10.0.0.1:6379"
      }
      check_slots_covered() {
        return 0
      }
      get_all_shards_master() {
        echo "10.0.0.1:6379"
      }
      check_node_in_cluster_with_retry() {
        return 0
      }
      redis-cli() {
        echo "ERR You should send CLUSTER FAILOVER to a replica"
      }

      It "fails"
        When run do_switchover "falkordb-shard-98x-1" "falkordb-shard-98x-1.falkordb-shard-98x-headless.default.svc" "true"
        The status should be failure
        The output should include "Starting switchover to falkordb-shard-98x-1"
        The stderr should include "Cluster Failover command failed"
      End
    End
  End

  Describe "switchover_with_candidate()"
    cleanup_env() {
      unset KB_SWITCHOVER_CANDIDATE_FQDN KB_SWITCHOVER_CANDIDATE_NAME
    }
    AfterEach 'cleanup_env'

    Context "when the candidate is not specified"
      It "fails"
        When run switchover_with_candidate
        The status should be failure
        The stderr should include "KB_SWITCHOVER_CANDIDATE_NAME or KB_SWITCHOVER_CANDIDATE_FQDN is empty"
      End
    End

    Context "when the candidate is specified"
      setup_env() {
        export KB_SWITCHOVER_CANDIDATE_NAME="falkordb-shard-98x-1"
        export KB_SWITCHOVER_CANDIDATE_FQDN="falkordb-shard-98x-1.falkordb-shard-98x-headless.default.svc"
      }
      BeforeEach 'setup_env'

      do_switchover() {
        echo "switchover: $1 $2 $3"
      }

      It "delegates to do_switchover and verifies the result"
        When call switchover_with_candidate
        The status should be success
        The output should eq "switchover: falkordb-shard-98x-1 falkordb-shard-98x-1.falkordb-shard-98x-headless.default.svc true"
      End
    End
  End

  Describe "switchover_without_candidate()"
    setup_env() {
      service_port=6379
      export CURRENT_POD_IP="10.0.0.9"
      export CURRENT_SHARD_POD_NAME_LIST="falkordb-shard-98x-0,falkordb-shard-98x-1"
      export CURRENT_SHARD_POD_FQDN_LIST="falkordb-shard-98x-0.falkordb-shard-98x-headless.default.svc,falkordb-shard-98x-1.falkordb-shard-98x-headless.default.svc"
    }
    BeforeEach 'setup_env'

    cleanup_env() {
      unset CURRENT_POD_IP CURRENT_SHARD_POD_NAME_LIST CURRENT_SHARD_POD_FQDN_LIST
    }
    AfterEach 'cleanup_env'

    Context "when the pod has already been removed from the cluster"
      get_cluster_nodes_info() {
        echo "id1 10.0.0.9:6379@16379 myself,master - 0 0 1 connected"
      }

      It "skips the switchover"
        When call switchover_without_candidate
        The status should be success
        The output should include "no need to perform switch over"
      End
    End

    Context "when no eligible secondary exists in the shard"
      get_cluster_nodes_info() {
        echo "id1 10.0.0.9:6379@16379 myself,master - 0 0 1 connected"
        echo "id2 10.0.0.8:6379@16379 master - 0 0 2 connected"
      }
      check_redis_role() {
        echo "primary"
      }

      It "fails"
        When run switchover_without_candidate
        The status should be failure
        The stderr should include "No eligible secondary found"
      End
    End

    Context "when an eligible secondary exists"
      get_cluster_nodes_info() {
        echo "id1 10.0.0.9:6379@16379 myself,master - 0 0 1 connected"
        echo "id2 10.0.0.8:6379@16379 slave id1 0 0 1 connected"
      }
      check_redis_role() {
        if [ "$1" = "falkordb-shard-98x-1.falkordb-shard-98x-headless.default.svc" ]; then
          echo "secondary"
        else
          echo "primary"
        fi
      }
      do_switchover() {
        echo "switchover: $1 $2 $3"
      }

      It "switches over to that secondary without verifying the result"
        When call switchover_without_candidate
        The status should be success
        The output should include "switchover: falkordb-shard-98x-1 falkordb-shard-98x-1.falkordb-shard-98x-headless.default.svc false"
      End
    End
  End
End

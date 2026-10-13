# shellcheck shell=bash
# shellcheck disable=SC2034

if ! validate_shell_type_and_version "bash" 4 &>/dev/null; then
  echo "reset_master_spec.sh skip all cases because dependency bash version 4 or higher is not installed."
  exit 0
fi

Describe "FalkorDB Reset Master Script Tests"
  Include ../scripts/reset-master.sh

  init() {
    ut_mode="true"
    sentinel_service_port=26379
    export SENTINEL_HEADLESS_SERVICE_NAME="falkordb-sentinel-headless"
    export CLUSTER_NAMESPACE="default"
    export REDIS_COMPONENT_NAME="falkordb"
    export REDIS_CLI_TLS_CMD=""
  }
  BeforeAll "init"

  cleanup() {
    unset SENTINEL_HEADLESS_SERVICE_NAME CLUSTER_NAMESPACE REDIS_COMPONENT_NAME REDIS_CLI_TLS_CMD
  }
  AfterAll "cleanup"

  Describe "reset_master_in_sentinels()"
    Context "when the sentinel pod list is empty"
      setup_env() {
        unset SENTINEL_POD_NAME_LIST
        unset SENTINEL_PASSWORD
      }
      BeforeEach 'setup_env'

      It "exits successfully without contacting any sentinel"
        When run reset_master_in_sentinels
        The status should be success
        The output should equal ""
      End
    End

    Context "when the only sentinel accepts the reset"
      setup_env() {
        export SENTINEL_POD_NAME_LIST="falkordb-sentinel-0"
        export SENTINEL_PASSWORD="sentinelpass"
        unset CUSTOM_SENTINEL_MASTER_NAME
      }
      BeforeEach 'setup_env'

      redis-cli() {
        echo "1"
        return 0
      }

      It "resets the master and exits successfully"
        When run reset_master_in_sentinels
        The status should be success
        The output should include "reset master falkordb in sentinel falkordb-sentinel-0..."
        The output should include "reset master in sentinel falkordb-sentinel-0 succeeded"
      End
    End

    Context "when a password is configured"
      setup_env() {
        export SENTINEL_POD_NAME_LIST="falkordb-sentinel-0"
        export SENTINEL_PASSWORD="sentinelpass"
        unset CUSTOM_SENTINEL_MASTER_NAME
      }
      BeforeEach 'setup_env'

      redis-cli() {
        echo "auth:${REDISCLI_AUTH} args:$*" >&2
        echo "1"
      }

      It "passes it through REDISCLI_AUTH rather than the arguments"
        When run reset_master_in_sentinels
        The status should be success
        The stderr should include "auth:sentinelpass"
        The stderr should not include "-a sentinelpass"
        The output should include "succeeded"
      End
    End

    Context "when no password is configured"
      setup_env() {
        export SENTINEL_POD_NAME_LIST="falkordb-sentinel-0"
        unset SENTINEL_PASSWORD
        unset CUSTOM_SENTINEL_MASTER_NAME
        # so a REDISCLI_AUTH exported by the caller cannot leak into the stub
        unset REDISCLI_AUTH
      }
      BeforeEach 'setup_env'

      redis-cli() {
        echo "auth:${REDISCLI_AUTH-unset} args:$*" >&2
        echo "1"
      }

      # An empty REDISCLI_AUTH still makes redis-cli send `AUTH ""`, which a
      # password-less sentinel rejects.
      It "does not authenticate at all"
        When run reset_master_in_sentinels
        The status should be success
        The stderr should include "auth:unset"
        The stderr should not include " -a "
        The output should include "succeeded"
      End
    End

    Context "when the cluster uses a custom sentinel master name"
      setup_env() {
        export SENTINEL_POD_NAME_LIST="falkordb-sentinel-0"
        unset SENTINEL_PASSWORD
        export CUSTOM_SENTINEL_MASTER_NAME="mymaster"
      }
      BeforeEach 'setup_env'
      AfterEach 'unset CUSTOM_SENTINEL_MASTER_NAME'

      redis-cli() {
        echo "args:$*" >&2
        echo "1"
      }

      It "resets the custom name instead of the component name"
        When run reset_master_in_sentinels
        The status should be success
        The stderr should include "sentinel reset mymaster"
        The stderr should not include "sentinel reset falkordb"
        The output should include "reset master mymaster in sentinel falkordb-sentinel-0..."
      End
    End

    Context "when a sentinel does not monitor the master"
      setup_env() {
        export SENTINEL_POD_NAME_LIST="falkordb-sentinel-0"
        unset SENTINEL_PASSWORD
        unset CUSTOM_SENTINEL_MASTER_NAME
      }
      BeforeEach 'setup_env'

      # SENTINEL RESET answers 0 when the pattern matches no master, e.g. the
      # wrong master name was used.
      redis-cli() {
        echo "0"
      }

      It "treats the reset as failed"
        When run reset_master_in_sentinels
        The status should be failure
        The output should include "reset master in sentinel falkordb-sentinel-0 failed: 0"
      End
    End

    Context "when the first sentinel fails but the second succeeds"
      setup_env() {
        export SENTINEL_POD_NAME_LIST="falkordb-sentinel-0,falkordb-sentinel-1"
        export SENTINEL_PASSWORD="sentinelpass"
        unset CUSTOM_SENTINEL_MASTER_NAME
      }
      BeforeEach 'setup_env'

      redis-cli() {
        echo "$*" >> ./reset-master-calls.log
        if echo "$*" | grep -q "falkordb-sentinel-0"; then
          echo "Could not connect" >&2
          return 1
        fi
        echo "1"
        return 0
      }
      AfterEach 'rm -f ./reset-master-calls.log'

      It "still resets the second sentinel but exits with failure"
        When run reset_master_in_sentinels
        The status should be failure
        The stderr should include "Could not connect"
        The output should include "reset master in sentinel falkordb-sentinel-0 failed"
        The output should include "reset master in sentinel falkordb-sentinel-1 succeeded"
        The contents of file ./reset-master-calls.log should include "falkordb-sentinel-1"
      End
    End

    Context "when every sentinel accepts the reset"
      setup_env() {
        export SENTINEL_POD_NAME_LIST="falkordb-sentinel-0,falkordb-sentinel-1,falkordb-sentinel-2"
        export SENTINEL_PASSWORD="sentinelpass"
        unset CUSTOM_SENTINEL_MASTER_NAME
      }
      BeforeEach 'setup_env'

      redis-cli() {
        echo "1"
      }

      # Each sentinel keeps its own replica list, so stopping after the first
      # one leaves the others pointing at removed pods.
      It "resets the master on all of them"
        When run reset_master_in_sentinels
        The status should be success
        The output should include "reset master in sentinel falkordb-sentinel-0 succeeded"
        The output should include "reset master in sentinel falkordb-sentinel-1 succeeded"
        The output should include "reset master in sentinel falkordb-sentinel-2 succeeded"
      End
    End

    Context "when every sentinel fails"
      setup_env() {
        export SENTINEL_POD_NAME_LIST="falkordb-sentinel-0,falkordb-sentinel-1"
        export SENTINEL_PASSWORD="sentinelpass"
        unset CUSTOM_SENTINEL_MASTER_NAME
      }
      BeforeEach 'setup_env'

      redis-cli() {
        return 1
      }

      It "exits with failure"
        When run reset_master_in_sentinels
        The status should be failure
        The output should include "reset master failed on at least one sentinel"
      End
    End
  End
End

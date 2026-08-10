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
      }
      BeforeEach 'setup_env'

      redis-cli() {
        echo "OK"
        return 0
      }

      It "resets the master and exits successfully"
        When run reset_master_in_sentinels
        The status should be success
        The output should include "reset master in sentinel falkordb-sentinel-0..."
        The output should include "reset master in sentinel falkordb-sentinel-0 succeeded"
      End
    End

    Context "when no password is configured"
      setup_env() {
        export SENTINEL_POD_NAME_LIST="falkordb-sentinel-0"
        unset SENTINEL_PASSWORD
      }
      BeforeEach 'setup_env'

      redis-cli() {
        echo "args:$*"
        return 0
      }

      It "does not pass the -a flag"
        When run reset_master_in_sentinels
        The status should be success
        The output should not include " -a "
        The output should include "succeeded"
      End
    End

    Context "when the first sentinel fails but the second succeeds"
      setup_env() {
        export SENTINEL_POD_NAME_LIST="falkordb-sentinel-0,falkordb-sentinel-1"
        export SENTINEL_PASSWORD="sentinelpass"
      }
      BeforeEach 'setup_env'

      redis-cli() {
        if echo "$*" | grep -q "falkordb-sentinel-0"; then
          echo "Could not connect" >&2
          return 1
        fi
        echo "OK"
        return 0
      }

      It "keeps trying and exits successfully"
        When run reset_master_in_sentinels
        The status should be success
        The stderr should include "Could not connect"
        The output should include "reset master in sentinel falkordb-sentinel-1 succeeded"
      End
    End

    Context "when every sentinel fails"
      setup_env() {
        export SENTINEL_POD_NAME_LIST="falkordb-sentinel-0,falkordb-sentinel-1"
        export SENTINEL_PASSWORD="sentinelpass"
      }
      BeforeEach 'setup_env'

      redis-cli() {
        return 1
      }

      It "exits with failure"
        When run reset_master_in_sentinels
        The status should be failure
        The output should include "reset master in sentinel failed"
      End
    End
  End
End

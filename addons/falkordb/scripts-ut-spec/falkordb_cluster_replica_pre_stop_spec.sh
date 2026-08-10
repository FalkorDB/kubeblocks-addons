# shellcheck shell=bash
# shellcheck disable=SC2034

if ! validate_shell_type_and_version "bash" 4 &>/dev/null; then
  echo "falkordb_cluster_replica_pre_stop_spec.sh skip all cases because dependency bash version 4 or higher is not installed."
  exit 0
fi

source ./utils.sh

common_library_file="./common.sh"
generate_common_library $common_library_file

Describe "FalkorDB Cluster Replica Pre-Stop Script Tests"
  Include ../falkordb-cluster-scripts/falkordb-cluster-replica-pre-stop.sh
  Include $common_library_file

  init() {
    ut_mode="true"
  }
  BeforeAll "init"

  cleanup() {
    rm -f $common_library_file
  }
  AfterAll 'cleanup'

  Describe "acl_save_before_stop()"
    setup_env() {
      export SERVICE_PORT="6379"
      export REDIS_DEFAULT_PASSWORD="testpass123"
      export REDIS_CLI_TLS_CMD=""
    }

    cleanup_env() {
      unset SERVICE_PORT REDIS_DEFAULT_PASSWORD REDIS_CLI_TLS_CMD
    }

    Context "when acl save succeeds with a password"
      BeforeEach 'setup_env'
      AfterEach 'cleanup_env'

      redis-cli() {
        echo "OK"
        return 0
      }

      It "returns success and masks the password in the log"
        When call acl_save_before_stop
        The status should be success
        The output should include "acl save command:"
        The output should include "********"
        The output should not include "testpass123"
        The output should include "executed successfully"
      End
    End

    Context "when acl save succeeds without a password"
      BeforeEach 'setup_env'
      AfterEach 'cleanup_env'

      unset_password() {
        unset REDIS_DEFAULT_PASSWORD
      }
      BeforeEach 'unset_password'

      redis-cli() {
        echo "OK"
        return 0
      }

      It "returns success without the -a flag"
        When call acl_save_before_stop
        The status should be success
        The output should include "acl save command:"
        The output should not include " -a "
        The output should include "executed successfully"
      End
    End

    Context "when TLS is enabled"
      BeforeEach 'setup_env'
      AfterEach 'cleanup_env'

      enable_tls() {
        export REDIS_CLI_TLS_CMD="--tls --insecure"
      }
      BeforeEach 'enable_tls'

      redis-cli() {
        echo "OK"
        return 0
      }

      It "passes the TLS flags through"
        When call acl_save_before_stop
        The status should be success
        The output should include "--tls --insecure"
      End
    End

    Context "when acl save fails"
      BeforeEach 'setup_env'
      AfterEach 'cleanup_env'

      redis-cli() {
        echo "NOAUTH Authentication required"
        return 1
      }

      It "exits with a failure and logs the error output"
        When run acl_save_before_stop
        The status should be failure
        The output should include "failed to execute acl save command"
        The output should include "NOAUTH Authentication required"
      End
    End
  End
End

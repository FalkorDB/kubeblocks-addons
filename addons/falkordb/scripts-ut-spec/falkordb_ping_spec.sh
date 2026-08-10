# shellcheck shell=bash
# shellcheck disable=SC2034

if ! validate_shell_type_and_version "bash" 4 &>/dev/null; then
  echo "falkordb_ping_spec.sh skip all cases because dependency bash version 4 or higher is not installed."
  exit 0
fi

source ./utils.sh

common_library_file="./common.sh"
generate_common_library $common_library_file

Describe "FalkorDB Ping Script Tests"
  Include ../scripts/falkordb-ping.sh
  Include $common_library_file

  init() {
    ut_mode="true"
  }
  BeforeAll "init"

  cleanup() {
    rm -f $common_library_file
  }
  AfterAll 'cleanup'

  Describe "check_redis_ok()"
    setup_env() {
      export SERVICE_PORT="6379"
      export REDIS_DEFAULT_PASSWORD="testpass"
      export REDIS_CLI_TLS_CMD=""
    }

    cleanup_env() {
      unset SERVICE_PORT REDIS_DEFAULT_PASSWORD REDIS_CLI_TLS_CMD
    }

    Context "when redis replies PONG with a password"
      BeforeEach 'setup_env'
      AfterEach 'cleanup_env'

      redis-cli() {
        echo "PONG"
        return 0
      }

      It "returns success"
        When call check_redis_ok
        The status should be success
        The output should include "FalkorDB is ok"
      End
    End

    Context "when redis replies PONG without a password"
      BeforeEach 'setup_env'
      AfterEach 'cleanup_env'

      unset_password() {
        unset REDIS_DEFAULT_PASSWORD
      }
      BeforeEach 'unset_password'

      redis-cli() {
        echo "PONG"
        return 0
      }

      It "returns success"
        When call check_redis_ok
        The status should be success
        The output should include "FalkorDB is ok"
      End
    End

    Context "when redis replies something other than PONG"
      BeforeEach 'setup_env'
      AfterEach 'cleanup_env'

      redis-cli() {
        echo "LOADING Redis is loading the dataset in memory"
        return 0
      }

      It "returns failure"
        When call check_redis_ok
        The status should be failure
        The stderr should include "redis ping failed"
      End
    End

    Context "when the ping times out"
      BeforeEach 'setup_env'
      AfterEach 'cleanup_env'

      redis-cli() {
        return 124
      }

      It "returns failure with a timeout message"
        When call check_redis_ok
        The status should be failure
        The stderr should include "Timed out"
      End
    End

    Context "when a custom port is configured"
      BeforeEach 'setup_env'
      AfterEach 'cleanup_env'

      set_custom_port() {
        export SERVICE_PORT="16379"
      }
      BeforeEach 'set_custom_port'

      redis-cli() {
        if echo "$*" | grep -q -- "-p 16379"; then
          echo "PONG"
          return 0
        fi
        echo "WRONG PORT"
        return 0
      }

      It "connects to the configured port"
        When call check_redis_ok
        The status should be success
        The output should include "FalkorDB is ok"
      End
    End

    Context "when TLS is enabled"
      BeforeEach 'setup_env'
      AfterEach 'cleanup_env'

      enable_tls() {
        export REDIS_CLI_TLS_CMD="--tls --cert /etc/pki/tls/tls.crt"
      }
      BeforeEach 'enable_tls'

      redis-cli() {
        if echo "$*" | grep -q -- "--tls"; then
          echo "PONG"
          return 0
        fi
        echo "NO TLS"
        return 0
      }

      It "passes the TLS flags through"
        When call check_redis_ok
        The status should be success
        The output should include "FalkorDB is ok"
      End
    End
  End

  Describe "retry_check_redis_ok()"
    setup_env() {
      export SERVICE_PORT="6379"
      export REDIS_DEFAULT_PASSWORD="testpass"
      export REDIS_CLI_TLS_CMD=""
    }

    cleanup_env() {
      unset SERVICE_PORT REDIS_DEFAULT_PASSWORD REDIS_CLI_TLS_CMD
    }

    Context "when the first check succeeds"
      BeforeEach 'setup_env'
      AfterEach 'cleanup_env'

      check_redis_ok() {
        return 0
      }

      It "returns success"
        When call retry_check_redis_ok
        The status should be success
      End
    End

    Context "when every check fails"
      BeforeEach 'setup_env'
      AfterEach 'cleanup_env'

      check_redis_ok() {
        return 1
      }
      call_func_with_retry() {
        return 1
      }

      It "returns failure"
        When call retry_check_redis_ok
        The status should be failure
        The stderr should include "FalkorDB is not running."
      End
    End
  End
End

# shellcheck shell=bash
# shellcheck disable=SC2034

if ! validate_shell_type_and_version "bash" 4 &>/dev/null; then
  echo "falkordb_sent_ping_spec.sh skip all cases because dependency bash version 4 or higher is not installed."
  exit 0
fi

source ./utils.sh

common_library_file="./common.sh"
generate_common_library $common_library_file

Describe "FalkorDB Sentinel Ping Script Tests"
  Include ../scripts/falkordb-sent-ping.sh
  Include $common_library_file

  init() {
    ut_mode="true"
  }
  BeforeAll "init"

  cleanup() {
    rm -f $common_library_file
  }
  AfterAll 'cleanup'

  Describe "check_redis_sentinel_ok()"
    setup_env() {
      export SENTINEL_SERVICE_PORT="26379"
      export SENTINEL_PASSWORD="sentinelpass"
      export REDIS_CLI_TLS_CMD=""
    }

    cleanup_env() {
      unset SENTINEL_SERVICE_PORT SENTINEL_PASSWORD REDIS_CLI_TLS_CMD
    }

    Context "when sentinel replies PONG with a password"
      BeforeEach 'setup_env'
      AfterEach 'cleanup_env'

      redis-cli() {
        echo "PONG"
        return 0
      }

      It "returns success"
        When call check_redis_sentinel_ok
        The status should be success
      End
    End

    Context "when sentinel replies PONG without a password"
      BeforeEach 'setup_env'
      AfterEach 'cleanup_env'

      unset_password() {
        unset SENTINEL_PASSWORD
      }
      BeforeEach 'unset_password'

      redis-cli() {
        echo "PONG"
        return 0
      }

      It "returns success"
        When call check_redis_sentinel_ok
        The status should be success
      End
    End

    Context "when the sentinel port is not configured"
      BeforeEach 'setup_env'
      AfterEach 'cleanup_env'

      unset_port() {
        unset SENTINEL_SERVICE_PORT
      }
      BeforeEach 'unset_port'

      redis-cli() {
        if echo "$*" | grep -q -- "-p 26379"; then
          echo "PONG"
          return 0
        fi
        echo "WRONG PORT"
        return 0
      }

      It "falls back to the default 26379 port"
        When call check_redis_sentinel_ok
        The status should be success
      End
    End

    Context "when sentinel replies something other than PONG"
      BeforeEach 'setup_env'
      AfterEach 'cleanup_env'

      redis-cli() {
        echo "ERR unknown"
        return 0
      }

      It "returns failure"
        When call check_redis_sentinel_ok
        The status should be failure
        The stderr should include "redis sentinel ping failed"
      End
    End

    Context "when the ping times out"
      BeforeEach 'setup_env'
      AfterEach 'cleanup_env'

      redis-cli() {
        return 124
      }

      It "returns failure with a timeout message"
        When call check_redis_sentinel_ok
        The status should be failure
        The stderr should include "redis sentinel ping timed out"
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
        When call check_redis_sentinel_ok
        The status should be success
      End
    End
  End

  Describe "retry_check_redis_sentinel_ok()"
    Context "when the first check succeeds"
      check_redis_sentinel_ok() {
        return 0
      }

      It "returns success"
        When call retry_check_redis_sentinel_ok
        The status should be success
      End
    End

    Context "when every check fails"
      check_redis_sentinel_ok() {
        return 1
      }
      call_func_with_retry() {
        return 1
      }

      It "returns failure"
        When call retry_check_redis_sentinel_ok
        The status should be failure
        The stderr should include "FalkorDB sentinel is not running."
      End
    End
  End
End

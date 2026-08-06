# shellcheck shell=bash
# shellcheck disable=SC2034

if ! validate_shell_type_and_version "bash" 4 &>/dev/null; then
  echo "falkordb_sent_account_provision_spec.sh skip cases because dependency bash version 4 or higher is not installed."
  exit 0
fi

Describe "FalkorDB Sentinel Account Provision Script Tests"
  Include ../scripts/falkordb-sent-account-provision.sh

  script_shebang() {
    sed -n '1p' ../scripts/falkordb-sent-account-provision.sh
  }

  init() {
    ut_mode="true"
    export SENTINEL_SERVICE_PORT="26379"
    export SENTINEL_PASSWORD="sentinelpass"
    export REDIS_CLI_TLS_CMD=""
    export KB_ACCOUNT_STATEMENT="ACL SETUSER testuser on >password ~* +@all"
  }
  BeforeAll "init"

  cleanup() {
    unset SENTINEL_SERVICE_PORT SENTINEL_PASSWORD REDIS_CLI_TLS_CMD KB_ACCOUNT_STATEMENT
  }
  AfterAll "cleanup"

  # The cmpd invokes this script through `sh -c`, so the shebang must stay POSIX.
  It "keeps the original /bin/sh shebang"
    When call script_shebang
    The output should equal "#!/bin/sh"
  End

  Describe "provision_sentinel_account()"
    Context "when redis-cli succeeds for both statement and acl save"
      redis-cli() {
        echo "OK"
        return 0
      }

      It "returns success"
        When call provision_sentinel_account
        The status should be success
      End
    End

    Context "when the sentinel password is passed to redis-cli"
      redis_cli_log="./falkordb-sent-account-provision-redis-cli.log"

      redis-cli() {
        printf 'args:%s\n' "$*" >> "$redis_cli_log"
        printf 'auth:%s\n' "${REDISCLI_AUTH:-}" >> "$redis_cli_log"
        echo "OK"
        return 0
      }

      truncate_log() {
        : > "$redis_cli_log"
      }
      Before 'truncate_log'

      remove_log() {
        rm -f "$redis_cli_log"
      }
      After 'remove_log'

      It "uses REDISCLI_AUTH instead of the -a flag"
        When call provision_sentinel_account
        The status should be success
        The contents of file "$redis_cli_log" should include "auth:sentinelpass"
        The contents of file "$redis_cli_log" should not include "-a sentinelpass"
      End
    End

    Context "when it talks to the sentinel port"
      redis_cli_log="./falkordb-sent-account-provision-port.log"

      redis-cli() {
        printf 'args:%s\n' "$*" >> "$redis_cli_log"
        echo "OK"
        return 0
      }

      truncate_log() {
        : > "$redis_cli_log"
      }
      Before 'truncate_log'

      remove_log() {
        rm -f "$redis_cli_log"
      }
      After 'remove_log'

      It "uses SENTINEL_SERVICE_PORT"
        When call provision_sentinel_account
        The status should be success
        The contents of file "$redis_cli_log" should include "-p 26379"
      End
    End

    Context "when account statement returns a Redis error with zero exit"
      redis-cli() {
        if echo "$*" | grep -q "acl save"; then
          echo "OK"
          return 0
        fi
        echo "$REDIS_ERROR_REPLY"
        return 0
      }

      Parameters
        "ERR unknown command"
        "NOAUTH Authentication required."
        "WRONGPASS invalid username-password pair"
        "NOPERM this user has no permissions to run the 'acl' command"
      End

      It "returns failure for $1"
        REDIS_ERROR_REPLY="$1"
        When call provision_sentinel_account
        The status should be failure
        The stderr should include "sentinel account provision failed"
        The stderr should include "$1"
      End
    End

    Context "when redis-cli connection fails on statement"
      redis-cli() {
        if echo "$*" | grep -q "acl save"; then
          echo "OK"
          return 0
        fi
        echo "Could not connect to Redis" >&2
        return 1
      }

      It "returns failure"
        When call provision_sentinel_account
        The status should be failure
        The stderr should include "sentinel account provision failed"
        The stderr should include "connection error"
      End
    End

    Context "when acl save connection fails"
      redis-cli() {
        if echo "$*" | grep -q "acl save"; then
          return 1
        fi
        echo "OK"
        return 0
      }

      It "returns failure with acl save connection error"
        When call provision_sentinel_account
        The status should be failure
        The stderr should include "acl save connection error"
      End
    End

    Context "when acl save returns Redis error with zero exit"
      redis-cli() {
        if echo "$*" | grep -q "acl save"; then
          echo "ERR operation not permitted"
          return 0
        fi
        echo "OK"
        return 0
      }

      It "returns failure with acl save error"
        When call provision_sentinel_account
        The status should be failure
        The stderr should include "acl save error"
      End
    End

    Context "when the account statement fails"
      redis-cli() {
        if echo "$*" | grep -q -- "ACL SETUSER"; then
          echo "statement failed" >&2
          return 42
        fi
        if echo "$*" | grep -q -- "acl save"; then
          echo "ACL_SAVE_SHOULD_NOT_RUN"
          return 0
        fi
        return 0
      }

      It "propagates the statement exit code and skips acl save"
        When run provision_sentinel_account
        The status should equal 42
        The stderr should include "failed to execute KB_ACCOUNT_STATEMENT"
        The stdout should not include "ACL_SAVE_SHOULD_NOT_RUN"
      End
    End
  End
End

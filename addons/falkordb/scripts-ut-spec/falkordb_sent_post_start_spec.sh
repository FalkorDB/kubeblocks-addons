# shellcheck shell=bash
# shellcheck disable=SC2034

if ! validate_shell_type_and_version "bash" 4 &>/dev/null; then
  echo "falkordb_sent_post_start_spec.sh skip all cases because dependency bash version 4 or higher is not installed."
  exit 0
fi

source ./utils.sh

common_library_file="./common.sh"
generate_common_library $common_library_file

Describe "FalkorDB Sentinel Post-Start Script Tests"
  Include ../scripts/falkordb-sent-post-start.sh
  Include $common_library_file

  init() {
    ut_mode="true"
  }
  BeforeAll "init"

  cleanup() {
    rm -f $common_library_file
  }
  AfterAll 'cleanup'

  # Answers a command the way a healthy sentinel does.
  sentinel_reply() {
    case "$1" in
      ping) echo "PONG" ;;
      *) echo "OK" ;;
    esac
  }

  Describe "acl_set_user_for_redis_sentinel()"
    setup_env() {
      export SENTINEL_SERVICE_PORT="26379"
      export SENTINEL_PASSWORD="sentinelpass"
      export SENTINEL_USER="sentineluser"
      export REDIS_CLI_TLS_CMD=""
    }

    cleanup_env() {
      unset SENTINEL_SERVICE_PORT SENTINEL_PASSWORD SENTINEL_USER REDIS_CLI_TLS_CMD
    }

    Context "when the sentinel password is set"
      BeforeEach 'setup_env'
      AfterEach 'cleanup_env'

      redis-cli() {
        sentinel_reply "$(cat)"
      }

      It "sets the sentinel user and saves the ACL"
        When call acl_set_user_for_redis_sentinel
        The status should be success
        The output should include "redis sentinel user and password set successfully."
      End
    End

    Context "when no sentinel password is configured"
      BeforeEach 'setup_env'
      AfterEach 'cleanup_env'

      unset_password() {
        unset SENTINEL_PASSWORD
      }
      BeforeEach 'unset_password'

      redis-cli() {
        echo "SHOULD_NOT_BE_CALLED"
        return 0
      }

      It "does nothing"
        When call acl_set_user_for_redis_sentinel
        The status should be success
        The output should not include "SHOULD_NOT_BE_CALLED"
      End
    End

    Context "when sentinel is not ready on the first ping"
      BeforeEach 'setup_env'
      AfterEach 'cleanup_env'

      # redis-cli exits 0 even when it cannot connect, so the attempts that
      # find no sentinel do too.
      ping_log="./post-start-ping.log"
      redis-cli() {
        local command
        command=$(cat)
        if [ "$command" = "ping" ]; then
          echo "ping" >> "$ping_log"
          if [ "$(wc -l < "$ping_log")" -lt 2 ]; then
            echo "Could not connect to Redis at localhost:26379: Connection refused" >&2
            return 0
          fi
        fi
        sentinel_reply "$command"
      }
      sleep() {
        return 0
      }
      After 'rm -f "$ping_log"'

      It "waits until sentinel answers PONG before setting the user"
        When call acl_set_user_for_redis_sentinel
        The status should be success
        The output should include "redis sentinel user and password set successfully."
        The contents of file "$ping_log" should eq "ping
ping"
      End
    End

    Context "when the sentinel never answers"
      BeforeEach 'setup_env'
      AfterEach 'cleanup_env'

      redis-cli() {
        cat >/dev/null
        echo "Could not connect to Redis at localhost:26379: Connection refused" >&2
        return 0
      }
      sleep() {
        return 0
      }

      It "fails instead of leaving the default user without a password"
        SENTINEL_PING_MAX_RETRIES=2
        When call acl_set_user_for_redis_sentinel
        The status should be failure
        The stderr should include "sentinel did not answer PING after 2 attempts"
        The output should not include "set successfully"
      End
    End

    Context "when the sentinel rejects the password"
      BeforeEach 'setup_env'
      AfterEach 'cleanup_env'

      redis-cli() {
        local command
        command=$(cat)
        case "$command" in
          ping) echo "PONG" ;;
          *) echo "ERR Error in ACL SETUSER modifier" ;;
        esac
      }

      It "fails"
        When call acl_set_user_for_redis_sentinel
        The status should be failure
        The stderr should include "failed to set the password of sentineluser"
        The stderr should not include "sentinelpass"
        The output should not include "set successfully"
      End
    End
  End

  Describe "acl_set_extra_user_for_redis_sentinel()"
    setup_env() {
      export SENTINEL_SERVICE_PORT="26379"
      export SENTINEL_PASSWORD="sentinelpass"
      export REDIS_CLI_TLS_CMD=""
      export FALKORDB_SENT_EXTRA_USER_USERNAME="extrauser"
      export FALKORDB_SENT_EXTRA_USER_PASSWORD="extrapass"
    }

    cleanup_env() {
      unset SENTINEL_SERVICE_PORT SENTINEL_PASSWORD REDIS_CLI_TLS_CMD
      unset FALKORDB_SENT_EXTRA_USER_USERNAME FALKORDB_SENT_EXTRA_USER_PASSWORD FALKORDB_SENT_EXTRA_USER_ACL
    }

    Context "when the extra user is fully configured"
      BeforeEach 'setup_env'
      AfterEach 'cleanup_env'

      redis-cli() {
        sentinel_reply "$(cat)"
      }

      It "creates the extra user"
        When call acl_set_extra_user_for_redis_sentinel
        The status should be success
        The output should include "extra sentinel user extrauser set successfully."
      End
    End

    Context "when custom ACL rules are provided"
      BeforeEach 'setup_env'
      AfterEach 'cleanup_env'

      set_acl() {
        export FALKORDB_SENT_EXTRA_USER_ACL="~monitor:* +@read"
      }
      BeforeEach 'set_acl'

      redis_cli_log="./post-start-redis-cli.log"
      redis-cli() {
        # the command is fed through stdin so that no secret ends up in argv
        local command
        command=$(cat)
        echo "args:$* stdin:$command" >> "$redis_cli_log"
        sentinel_reply "$command"
      }
      After 'rm -f "$redis_cli_log"'

      It "applies the custom ACL rules"
        When call acl_set_extra_user_for_redis_sentinel
        The status should be success
        The output should include "extra sentinel user extrauser set successfully."
        The contents of file "$redis_cli_log" should include "~monitor:* +@read"
        The contents of file "$redis_cli_log" should include "args:-h localhost -p 26379"
      End
    End

    Context "when checking that secrets never reach the process arguments"
      BeforeEach 'setup_env'
      AfterEach 'cleanup_env'

      redis_cli_log="./post-start-redis-cli.log"
      redis-cli() {
        echo "args:$*" >> "$redis_cli_log"
        sentinel_reply "$(cat)"
      }
      After 'rm -f "$redis_cli_log"'

      It "does not pass any password on the command line"
        When call acl_set_extra_user_for_redis_sentinel
        The status should be success
        The output should include "extra sentinel user extrauser set successfully."
        The contents of file "$redis_cli_log" should include "args:-h localhost -p 26379"
        The contents of file "$redis_cli_log" should not include "extrapass"
        The contents of file "$redis_cli_log" should not include "sentinelpass"
      End
    End

    Context "when the extra username is missing"
      BeforeEach 'setup_env'
      AfterEach 'cleanup_env'

      unset_username() {
        unset FALKORDB_SENT_EXTRA_USER_USERNAME
      }
      BeforeEach 'unset_username'

      redis-cli() {
        echo "SHOULD_NOT_BE_CALLED"
        return 0
      }

      It "skips the extra user"
        When call acl_set_extra_user_for_redis_sentinel
        The status should be success
        The output should include "No extra sentinel user configured, skipping."
        The output should not include "SHOULD_NOT_BE_CALLED"
      End
    End

    # an empty REDISCLI_AUTH makes redis-cli send AUTH "", which a password-less sentinel rejects.
    Context "when no sentinel password is configured"
      BeforeEach 'setup_env'
      AfterEach 'cleanup_env'

      no_sentinel_password() {
        unset SENTINEL_PASSWORD
        export REDISCLI_AUTH="inherited"
      }
      BeforeEach 'no_sentinel_password'
      AfterEach 'unset REDISCLI_AUTH'

      redis_cli_log="./post-start-redis-cli.log"
      redis-cli() {
        echo "REDISCLI_AUTH=${REDISCLI_AUTH-<unset>}" >> "$redis_cli_log"
        sentinel_reply "$(cat)"
      }
      After 'rm -f "$redis_cli_log"'

      It "does not set REDISCLI_AUTH"
        When call acl_set_extra_user_for_redis_sentinel
        The status should be success
        The output should include "extra sentinel user extrauser set successfully."
        The contents of file "$redis_cli_log" should include "REDISCLI_AUTH=<unset>"
        The contents of file "$redis_cli_log" should not include "REDISCLI_AUTH=inherited"
      End
    End

    Context "when the extra password is missing"
      BeforeEach 'setup_env'
      AfterEach 'cleanup_env'

      unset_password() {
        unset FALKORDB_SENT_EXTRA_USER_PASSWORD
      }
      BeforeEach 'unset_password'

      redis-cli() {
        echo "SHOULD_NOT_BE_CALLED"
        return 0
      }

      It "skips the extra user"
        When call acl_set_extra_user_for_redis_sentinel
        The status should be success
        The output should include "No extra sentinel user configured, skipping."
        The output should not include "SHOULD_NOT_BE_CALLED"
      End
    End
  End
End

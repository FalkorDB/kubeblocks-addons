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
        echo "OK"
        return 0
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

      ping_attempts=0
      redis-cli() {
        if echo "$*" | grep -q "ping"; then
          ping_attempts=$((ping_attempts + 1))
          if [ "$ping_attempts" -lt 2 ]; then
            return 1
          fi
        fi
        echo "OK"
        return 0
      }
      sleep() {
        return 0
      }

      It "waits until sentinel answers before setting the user"
        When call acl_set_user_for_redis_sentinel
        The status should be success
        The output should include "redis sentinel user and password set successfully."
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
        echo "OK"
        return 0
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

      redis-cli() {
        echo "args:$*"
        return 0
      }

      It "applies the custom ACL rules"
        When call acl_set_extra_user_for_redis_sentinel
        The status should be success
        The output should include "~monitor:* +@read"
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

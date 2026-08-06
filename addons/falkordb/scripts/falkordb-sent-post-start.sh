#!/bin/bash

# This is magic for shellspec ut framework. "test" is a `test [expression]` well known as a shell command.
# Normally test without [expression] returns false. It means that __() { :; }
# function is defined if this script runs directly.
#
# shellspec overrides the test command and returns true *once*. It means that
# __() function defined internally by shellspec is called.
#
# In other words. If not in test mode, __ is just a comment. If test mode, __
# is a interception point.
#
# you should set ut_mode="true" when you want to run the script in shellspec file.
#
# shellcheck disable=SC2034
ut_mode="false"
test || __() {
  # when running in non-unit test mode, set the options "set -e".
  set -e;
}

load_common_library() {
  # the common.sh scripts is mounted to the same path which is defined in the cmpd.spec.scripts
  common_library_file="/scripts/common.sh"
  # shellcheck disable=SC1090
  source "${common_library_file}"
}

sentinel_cli() {
  # the password is passed through REDISCLI_AUTH and the command through stdin so
  # that neither shows up in the process arguments.
  local command="$1"
  (
    export REDISCLI_AUTH="${SENTINEL_PASSWORD}"
    # shellcheck disable=SC2086
    printf '%s\n' "$command" | redis-cli $REDIS_CLI_TLS_CMD -h localhost -p "$sentinel_service_port"
  )
}

wait_for_sentinel() {
  local max_retries=${SENTINEL_PING_MAX_RETRIES:-60}
  local retry=0
  while [ "$retry" -lt "$max_retries" ]; do
    if sentinel_cli "ping" >/dev/null 2>&1; then
      return 0
    fi
    retry=$((retry + 1))
    sleep 1
  done
  echo "Error: sentinel did not answer PING after $max_retries attempts." >&2
  return 1
}

acl_set_user_for_redis_sentinel() {
  # set default user password and replication user password
  if [ -n "$SENTINEL_PASSWORD" ]; then
    sentinel_service_port=${SENTINEL_SERVICE_PORT:-26379}
    wait_for_sentinel || return 1
    sentinel_cli "ACL SETUSER $SENTINEL_USER ON >$SENTINEL_PASSWORD allchannels +@all"
    sentinel_cli "ACL SAVE"
    echo "redis sentinel user and password set successfully."
  fi
}

acl_set_extra_user_for_redis_sentinel() {
  if [ -z "$FALKORDB_SENT_EXTRA_USER_USERNAME" ] || [ -z "$FALKORDB_SENT_EXTRA_USER_PASSWORD" ]; then
    echo "No extra sentinel user configured, skipping."
    return
  fi

  local acl_rules
  acl_rules=${FALKORDB_SENT_EXTRA_USER_ACL:-"~* +@all"}
  sentinel_service_port=${SENTINEL_SERVICE_PORT:-26379}

  wait_for_sentinel || return 1
  sentinel_cli "ACL SETUSER $FALKORDB_SENT_EXTRA_USER_USERNAME ON >$FALKORDB_SENT_EXTRA_USER_PASSWORD $acl_rules"
  sentinel_cli "ACL SAVE"
  echo "extra sentinel user $FALKORDB_SENT_EXTRA_USER_USERNAME set successfully."
}

# This is magic for shellspec ut framework.
# Sometime, functions are defined in a single shell script.
# You will want to test it. but you do not want to run the script.
# When included from shellspec, __SOURCED__ variable defined and script
# end here. The script path is assigned to the __SOURCED__ variable.
${__SOURCED__:+false} : || return 0

# main
load_common_library
acl_set_user_for_redis_sentinel
acl_set_extra_user_for_redis_sentinel

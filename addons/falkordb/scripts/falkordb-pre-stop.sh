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

switchover_script="/scripts/falkordb-switchover.sh"
# The preStop's whole budget within the default 30 s grace period: the role
# check (5 s), the hand-over and ACL SAVE (5 s) take 25 s at most, which leaves
# the server 5 s to shut down after it.
hand_over_timeout_seconds=15

load_common_library() {
  # the common.sh scripts is mounted to the same path which is defined in the cmpd.spec.scripts
  common_library_file="/scripts/common.sh"
  # shellcheck disable=SC1090
  source "${common_library_file}"
}

acl_save_before_stop() {
  service_port=${SERVICE_PORT:-6379}
  if ! is_empty "$REDIS_DEFAULT_PASSWORD"; then
    acl_save_command="timeout 5 redis-cli $REDIS_CLI_TLS_CMD -h localhost -p $service_port -a $REDIS_DEFAULT_PASSWORD acl save"
    logging_mask_acl_save_command="${acl_save_command/$REDIS_DEFAULT_PASSWORD/********}"
  else
    acl_save_command="timeout 5 redis-cli $REDIS_CLI_TLS_CMD -h localhost -p $service_port acl save"
    logging_mask_acl_save_command="$acl_save_command"
  fi
  echo "acl save command: $logging_mask_acl_save_command"
  if output=$($acl_save_command 2>&1); then
    echo "acl save command executed successfully: $output"
  else
    echo "failed to execute acl save command: $output"
    exit 1
  fi
}

# Bounded, like the hand-over itself: a server that hangs must not use up the
# termination grace period before it is even asked to shut down.
current_pod_is_master() {
  local service_port=${SERVICE_PORT:-6379} output
  if ! is_empty "$REDIS_DEFAULT_PASSWORD"; then
    output=$(timeout 5 redis-cli $REDIS_CLI_TLS_CMD -h localhost -p "$service_port" -a "$REDIS_DEFAULT_PASSWORD" --no-auth-warning info replication 2>/dev/null) || return 1
  else
    output=$(timeout 5 redis-cli $REDIS_CLI_TLS_CMD -h localhost -p "$service_port" info replication 2>/dev/null) || return 1
  fi
  [[ "$output" == *role:master* ]]
}

# A primary that just exits leaves the instance without one until Sentinel
# notices and fails over, and if the pod comes back before that, Sentinel still
# names it and it starts as a second primary next to the replica Sentinel then
# promotes. So the primary hands over first, with the switchover action's
# failover, which pauses writes and demotes this pod before it returns. It is
# best effort and bounded to leave the server time to shut down within the
# termination grace period; on failure the pod stops as before.
hand_over_primary_before_stop() {
  if is_empty "$SENTINEL_COMPONENT_NAME" || [[ ${COMPONENT_REPLICAS:-0} -lt 2 ]]; then
    return 0
  fi
  if ! current_pod_is_master; then
    echo "not the primary, nothing to hand over"
    return 0
  fi
  echo "handing the primary role over before stopping"
  if KB_SWITCHOVER_ROLE=primary KB_SWITCHOVER_CANDIDATE_FQDN="" timeout "$hand_over_timeout_seconds" "$switchover_script"; then
    echo "primary role handed over"
  else
    echo "failed to hand the primary role over, stopping anyway"
  fi
}

# This is magic for shellspec ut framework.
# Sometime, functions are defined in a single shell script.
# You will want to test it. but you do not want to run the script.
# When included from shellspec, __SOURCED__ variable defined and script
# end here. The script path is assigned to the __SOURCED__ variable.
${__SOURCED__:+false} : || return 0

# main
load_common_library
hand_over_primary_before_stop
acl_save_before_stop

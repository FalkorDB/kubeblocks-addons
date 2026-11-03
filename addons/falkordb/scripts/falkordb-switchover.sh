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
# shellcheck disable=SC2153
ut_mode="false"
test || __() {
  # when running in non-unit test mode, set the options "set -ex".
  set -ex;
}

declare -A ORIGINAL_PRIORITIES
redis_service_port=${SERVICE_PORT:-6379}
# How long writes on the old primary stay paused at most (see
# failover_with_writes_paused); it covers the waits below with room to spare.
write_pause_ms=30000
replica_catch_up_max_attempts=10
new_primary_max_attempts=15
new_primary_host=""
new_primary_port=""

load_common_library() {
  # the common.sh scripts is mounted to the same path which is defined in the cmpd.spec.scripts
  common_library_file="/scripts/common.sh"
  # shellcheck disable=SC1090
  source "${common_library_file}"
}

check_environment_exist() {
  local required_vars=(
    "SENTINEL_POD_FQDN_LIST"
    "REDIS_POD_FQDN_LIST"
    "REDIS_COMPONENT_NAME"
  )

  if [[ ${COMPONENT_REPLICAS} -lt 2 ]]; then
    exit 0
  fi

  for var in "${required_vars[@]}"; do
    if is_empty "${!var}"; then
      echo "Error: Required environment variable $var is not set." >&2
      return 1
    fi
  done

  if [ "$KB_SWITCHOVER_ROLE" != "primary" ]; then
    echo "switchover not triggered for primary, nothing to do, exit 0."
    exit 0
  fi
}

check_redis_role() {
  local host=$1
  local port=$2
  unset_xtrace_when_ut_mode_false
  local role_info
  if [[ -z "$REDIS_DEFAULT_PASSWORD" ]]; then
    role_info=$(redis-cli $REDIS_CLI_TLS_CMD -h "$host" -p "$port" info replication)
  else
    role_info=$(redis-cli $REDIS_CLI_TLS_CMD -h "$host" -p "$port" -a "$REDIS_DEFAULT_PASSWORD" info replication)
  fi
  status=$?
  set_xtrace_when_ut_mode_false

  if [[ $status -ne 0 ]]; then
    echo "Failed to get role info from $host" >&2
    return 1
  fi

  if echo "$role_info" | grep -q "^role:master"; then
    echo "primary"
  elif echo "$role_info" | grep -q "^role:slave"; then
    echo "secondary"
  else
    echo "unknown"
    return 1
  fi
}

check_redis_kernel_status() {
  local role
  local current_master=""
  local -a redis_pod_fqdn_list
  IFS=',' read -ra redis_pod_fqdn_list <<< "${REDIS_POD_FQDN_LIST}"
  for redis_pod_fqdn in "${redis_pod_fqdn_list[@]}"; do
    role=$(check_redis_role "$redis_pod_fqdn" "$redis_service_port") || continue
    if [[ "$role" == "primary" ]]; then
      if [[ -n "$current_master" ]]; then
        echo "Error: Multiple primaries detected" >&2
        return 1
      fi
      current_master="$redis_pod_fqdn"
    fi
  done

  if [[ -z "$current_master" ]]; then
    echo "Error: No primary found" >&2
    return 1
  fi

  echo "$current_master"
  return 0
}

check_switchover_result() {
  local expected_master="$1"
  local initial_master="$2"
  local max_wait=300
  local wait_interval=5
  local elapsed=0

  while [[ $elapsed -lt $max_wait ]]; do
    local current_master
    if current_master=$(check_redis_kernel_status); then
      # if expected_master is specified, check if it is achieved
      if ! is_empty "$expected_master"; then
        if [[ "$current_master" = "$expected_master"* ]]; then
          echo "Switchover successful: $expected_master is now master"
          return 0
        fi
      # if initial_master is specified, check if it is switched to a different node
      elif ! is_empty "$initial_master"; then
        if [[ "$current_master" != "$initial_master" ]]; then
          echo "Switchover successful: new master is $current_master"
          return 0
        fi
      else
        echo "Error: Neither expected_master nor initial_master specified" >&2
        return 1
      fi
    fi
    sleep_when_ut_mode_false $wait_interval
    elapsed=$((elapsed + wait_interval))
  done

  if ! is_empty "$expected_master"; then
    echo "Switchover verification failed: expected master $expected_master not achieved" >&2
  else
    echo "Switchover verification failed: could not confirm new master" >&2
  fi
  return 1
}

check_connectivity() {
  local host=$1
  local port=$2
  local password=$3
  echo "Checking connectivity to $host on port $port using redis-cli..."
  local result
  unset_xtrace_when_ut_mode_false
  if ! is_empty "$password"; then
    result=$(redis-cli $REDIS_CLI_TLS_CMD -h "$host" -p "$port" -a "$password" PING)
  else
    result=$(redis-cli $REDIS_CLI_TLS_CMD -h "$host" -p "$port" PING)
  fi
  set_xtrace_when_ut_mode_false
  if [[ "$result" == "PONG" ]]; then
    echo "$host is reachable on port $port."
    return 0
  else
    echo "$host is not reachable on port $port." >&2
    return 1
  fi
}

execute_sub_command() {
  local host=$1
  local port=$2
  local password=$3
  local command=$4

  local output
  unset_xtrace_when_ut_mode_false
  if ! is_empty "$password"; then
    output=$(redis-cli $REDIS_CLI_TLS_CMD -h "$host" -p "$port" -a "$password" $command)
  else
    output=$(redis-cli $REDIS_CLI_TLS_CMD -h "$host" -p "$port" $command)
  fi
  local status=$?
  set_xtrace_when_ut_mode_false

  echo "execute_sub_command output: $output"
  if [[ $status -ne 0 ]] || [[ "$output" != "OK" ]]; then
    echo "Command failed with status $status or output not OK." >&2
    return 1
  fi
  echo "Command executed successfully."
  return 0
}

redis_config_get() {
  local host=$1
  local port=$2
  local password=$3
  local command=$4

  local output
  unset_xtrace_when_ut_mode_false
  if ! is_empty "$password"; then
    output=$(redis-cli $REDIS_CLI_TLS_CMD -h "$host" -p "$port" -a "$password" $command)
  else
    output=$(redis-cli $REDIS_CLI_TLS_CMD -h "$host" -p "$port" $command)
  fi
  local status=$?
  set_xtrace_when_ut_mode_false

  if [[ $status -ne 0 ]]; then
    echo "Command failed with status $status." >&2
    return 1
  fi

  if [[ -z "$output" ]]; then
    echo "Command returned no output." >&2
    return 1
  fi

  echo "$output"
  return 0
}

execute_sentinel_failover() {
  local master_name=$1
  local success=false

  if [[ -z "$master_name" ]]; then
    master_name=$REDIS_COMPONENT_NAME
  fi

  local -a sentinel_pod_fqdn_list
  IFS=',' read -ra sentinel_pod_fqdn_list <<< "${SENTINEL_POD_FQDN_LIST}"
  unset_xtrace_when_ut_mode_false
  for sentinel_pod_fqdn in "${sentinel_pod_fqdn_list[@]}"; do
    if call_func_with_retry 3 5 execute_sub_command "$sentinel_pod_fqdn" "$SENTINEL_SERVICE_PORT" "$SENTINEL_PASSWORD" "SENTINEL FAILOVER $master_name"; then
      echo "Sentinel failover started with $sentinel_pod_fqdn"
      success=true
      break
    fi
  done
  set_xtrace_when_ut_mode_false

  if [[ "$success" == false ]]; then
    echo "All Sentinel failover attempts failed." >&2
    return 1
  fi
  return 0
}

# Prints the primary address ("host port") each reachable sentinel reports, one
# line per sentinel.
get_sentinel_master_addrs() {
  local master_name="${CUSTOM_SENTINEL_MASTER_NAME:-$REDIS_COMPONENT_NAME}"
  local sentinel_pod_fqdn output
  local -a sentinel_pod_fqdn_list addr
  IFS=',' read -ra sentinel_pod_fqdn_list <<< "${SENTINEL_POD_FQDN_LIST}"
  for sentinel_pod_fqdn in "${sentinel_pod_fqdn_list[@]}"; do
    output=$(redis_config_get "$sentinel_pod_fqdn" "$SENTINEL_SERVICE_PORT" "$SENTINEL_PASSWORD" "SENTINEL get-master-addr-by-name $master_name" 2>/dev/null) || continue
    read -r -d '' -a addr <<< "$output" || true
    if [ "${#addr[@]}" -eq 2 ]; then
      echo "${addr[0]} ${addr[1]}"
    fi
  done
}

# Returns 0 when the primary has replicas online and every one of them has
# acknowledged its whole replication stream, which stops growing while writes
# are paused. Replicas acknowledge once a second.
replicas_caught_up() {
  local primary_fqdn="$1"
  local info master_offset offsets offset
  info=$(redis_config_get "$primary_fqdn" "$redis_service_port" "$REDIS_DEFAULT_PASSWORD" "INFO replication") || return 1
  info=${info//$'\r'/}
  master_offset=$(echo "$info" | sed -n 's/^master_repl_offset:\([0-9]*\).*/\1/p')
  offsets=$(echo "$info" | sed -n 's/^slave[0-9]*:.*state=online.*offset=\([0-9]*\).*/\1/p')
  if is_empty "$master_offset" || is_empty "$offsets"; then
    echo "$primary_fqdn has no replica online" >&2
    return 1
  fi
  for offset in $offsets; do
    if [ "$offset" -lt "$master_offset" ]; then
      echo "a replica of $primary_fqdn is at offset $offset of $master_offset" >&2
      return 1
    fi
  done
  return 0
}

# Waits for a sentinel to report a primary other than initial_addr, and sets
# new_primary_host and new_primary_port to it.
wait_for_sentinel_to_switch_master() {
  local initial_addr="$1"
  local attempt addr
  new_primary_host=""
  new_primary_port=""
  for ((attempt = 0; attempt < new_primary_max_attempts; attempt++)); do
    while read -r addr; do
      if ! is_empty "$addr" && [ "$addr" != "$initial_addr" ]; then
        read -r new_primary_host new_primary_port <<< "$addr"
        echo "sentinel switched the primary from $initial_addr to $addr"
        return 0
      fi
    done <<< "$(get_sentinel_master_addrs)"
    sleep_when_ut_mode_false 1
  done
  echo "Error: no sentinel reports a primary other than $initial_addr" >&2
  return 1
}

# SENTINEL FAILOVER promotes a replica but leaves the old primary a writable
# master until Sentinel demotes it, some 10 s later, and whatever it acknowledges
# meanwhile is lost when it resyncs from the new primary. So writes on it are
# paused first, the replicas left to catch up, and the old primary is made a
# replica of the new one here as soon as Sentinel has switched. Sentinel cannot
# be left to do it: the pause also blocks the PUBLISH it sends its hellos with,
# and the commands it sends after it on the same link. Paused writers are never
# acknowledged: once the old primary is a replica they get READONLY.
failover_with_writes_paused() {
  local old_primary="$1"
  local initial_addr attempt caught_up=false
  initial_addr=$(get_sentinel_master_addrs | head -n 1)
  if is_empty "$initial_addr"; then
    echo "Error: no sentinel reports the current primary" >&2
    return 1
  fi

  # the timeout only lifts the pause if this script dies half-way
  if ! call_func_with_retry 3 1 execute_sub_command "$old_primary" "$redis_service_port" "$REDIS_DEFAULT_PASSWORD" "CLIENT PAUSE $write_pause_ms WRITE"; then
    echo "Error: failed to pause writes on $old_primary" >&2
    return 1
  fi
  echo "writes paused on $old_primary for up to $write_pause_ms ms"

  for ((attempt = 0; attempt < replica_catch_up_max_attempts; attempt++)); do
    if replicas_caught_up "$old_primary"; then
      caught_up=true
      break
    fi
    sleep_when_ut_mode_false 1
  done
  if [ "$caught_up" != true ]; then
    echo "Error: the replicas of $old_primary did not catch up, not switching over" >&2
    unpause_writes "$old_primary"
    return 1
  fi

  if ! execute_sentinel_failover "$CUSTOM_SENTINEL_MASTER_NAME"; then
    unpause_writes "$old_primary"
    return 1
  fi
  if ! wait_for_sentinel_to_switch_master "$initial_addr"; then
    # If Sentinel switches after all, the old primary takes writes until Sentinel
    # demotes it, as it did before the pause.
    unpause_writes "$old_primary"
    return 1
  fi

  if call_func_with_retry 3 1 execute_sub_command "$old_primary" "$redis_service_port" "$REDIS_DEFAULT_PASSWORD" "REPLICAOF $new_primary_host $new_primary_port"; then
    echo "$old_primary is now a replica of $new_primary_host:$new_primary_port"
  else
    echo "Warning: failed to make $old_primary a replica of $new_primary_host:$new_primary_port, leaving it to sentinel" >&2
  fi
  unpause_writes "$old_primary"
  return 0
}

unpause_writes() {
  local primary_fqdn="$1"
  if call_func_with_retry 3 1 execute_sub_command "$primary_fqdn" "$redis_service_port" "$REDIS_DEFAULT_PASSWORD" "CLIENT UNPAUSE"; then
    echo "writes unpaused on $primary_fqdn"
  else
    echo "Warning: failed to unpause writes on $primary_fqdn, the pause ends after $write_pause_ms ms" >&2
  fi
}

# set target candidate highest priority to make sure it will be promoted to master
set_redis_priorities() {
  local candidate_fqdn="$1"

  local -a redis_pod_fqdn_list
  IFS=',' read -ra redis_pod_fqdn_list <<< "${REDIS_POD_FQDN_LIST}"
  for redis_pod_fqdn in "${redis_pod_fqdn_list[@]}"; do
    call_func_with_retry 3 5 check_connectivity "$redis_pod_fqdn" "$redis_service_port" "$REDIS_DEFAULT_PASSWORD" || return 1

    # Get original priority
    local redis_get_cmd="CONFIG GET replica-priority"
    local original_priority
    original_priority=$(redis_config_get "$redis_pod_fqdn" "$redis_service_port" "$REDIS_DEFAULT_PASSWORD" "$redis_get_cmd" | sed -n '2p')
    status=$?
    if [ $status -ne 0 ]; then
      echo "Error: Failed to get replica-priority for $redis_pod_fqdn" >&2
      return 1
    fi

    # Save original priority to global variable
    ORIGINAL_PRIORITIES[$redis_pod_fqdn]=$original_priority

    local redis_set_cmd
    if [[ "$redis_pod_fqdn" = "$candidate_fqdn"* ]]; then
      redis_set_cmd="CONFIG SET replica-priority 1"
    else
      redis_set_cmd="CONFIG SET replica-priority 100"
    fi

    call_func_with_retry 3 5 execute_sub_command "$redis_pod_fqdn" "$redis_service_port" "$REDIS_DEFAULT_PASSWORD" "$redis_set_cmd" || return 1
  done
  return 0
}

# recover all redis replica-priority
recover_redis_priorities() {
  local -a redis_pod_fqdn_list
  IFS=',' read -ra redis_pod_fqdn_list <<< "${REDIS_POD_FQDN_LIST}"

  echo "Recovering all FalkorDB replica-priority..."
  for redis_pod_fqdn in "${redis_pod_fqdn_list[@]}"; do
    # a pod whose original priority was never recorded (e.g. it was unreachable when
    # the priorities were captured) would otherwise be sent an empty value.
    [ -z "${ORIGINAL_PRIORITIES[$redis_pod_fqdn]+x}" ] && continue
    local redis_set_recover_cmd="CONFIG SET replica-priority ${ORIGINAL_PRIORITIES[$redis_pod_fqdn]}"
    call_func_with_retry 3 5 execute_sub_command "$redis_pod_fqdn" "$redis_service_port" "$REDIS_DEFAULT_PASSWORD" "$redis_set_recover_cmd" || return 1
  done
  echo "All FalkorDB config set replica-priority recovered."
  return 0
}

switchover_with_candidate() {
  # check the role of candidate before switchover
  local candidate_role
  candidate_role=$(check_redis_role "$KB_SWITCHOVER_CANDIDATE_FQDN" "$redis_service_port")
  if [[ "$candidate_role" != "secondary" ]]; then
    echo "Error: Candidate node $KB_SWITCHOVER_CANDIDATE_FQDN is not in secondary role" >&2
    return 1
  fi

  # check redis kernel role before switchover
  local initial_master
  initial_master=$(check_redis_kernel_status) || return 1

  local redis_get_cmd="CONFIG GET replica-priority"
  local redis_set_switchover_cmd="CONFIG SET replica-priority 1"
  local redis_set_lowest_priority_cmd="CONFIG SET replica-priority 100"

  # set target candidate highest priority to make sure it will be promoted to master
  unset_xtrace_when_ut_mode_false
  local set_rc=0
  set_redis_priorities "$KB_SWITCHOVER_CANDIDATE_FQDN" || set_rc=$?

  local switchover_rc=0
  if [ $set_rc -eq 0 ]; then
    failover_with_writes_paused "$initial_master" || switchover_rc=$?
    if [ $switchover_rc -eq 0 ]; then
      check_switchover_result "$KB_SWITCHOVER_CANDIDATE_FQDN" "" || switchover_rc=$?
    fi
  fi

  # recover all replica-priority regardless of the set/switchover result, otherwise
  # a failed switchover leaves the temporary priorities in place and permanently
  # changes which replica sentinel promotes next.
  local recover_rc=0
  recover_redis_priorities || recover_rc=$?
  set_xtrace_when_ut_mode_false

  if [ $set_rc -ne 0 ]; then
    echo "Priority setting failed, attempted recovery" >&2
    return 1
  fi
  if [ $switchover_rc -ne 0 ]; then
    echo "Switchover failed" >&2
    return 1
  fi
  if [ $recover_rc -ne 0 ]; then
    echo "Switchover succeeded but priority recovery failed" >&2
    return 1
  fi
  echo "All FalkorDB config set replica-priority recovered."
}

switchover_without_candidate() {
  # check redis kernel role before switchover
  local initial_master
  initial_master=$(check_redis_kernel_status) || return 1

  # do switchover
  failover_with_writes_paused "$initial_master" || return 1

  # check switchover result using initial_master
  # if no candidate specified, skip check
  # check_switchover_result "" "$initial_master" || return 1
}

# This is magic for shellspec ut framework.
# Sometime, functions are defined in a single shell script.
# You will want to test it. but you do not want to run the script.
# When included from shellspec, __SOURCED__ variable defined and script
# end here. The script path is assigned to the __SOURCED__ variable.
${__SOURCED__:+false} : || return 0

# main
load_common_library
check_environment_exist || exit 1
if is_empty "$KB_SWITCHOVER_CANDIDATE_FQDN"; then
  switchover_without_candidate || exit 1
else
  switchover_with_candidate || exit 1
fi

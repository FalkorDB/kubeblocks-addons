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
  # when running in non-unit test mode, set the options "set -e". Commands are
  # not traced (-x): the Redis and Sentinel passwords are passed as arguments.
  set -e;
}

declare -A ORIGINAL_PRIORITIES
redis_service_port=${SERVICE_PORT:-6379}
# Writes on the old primary stay paused for no longer than sentinel's node-down
# timeout, down-after-milliseconds: in an HA setup a longer pause is downtime.
# It is read from sentinel, and this, the value the addon registers, is used
# when it cannot be.
default_down_after_ms=5000
write_pause_ms=""
# when the pause ends (in ms since the epoch), while writes are paused
fence_deadline_ms=""
# how long a failover that has not switched by the end of the pause is still
# watched: sentinel's failover-timeout (60 s) and a little more
failover_watch_seconds=75
new_primary_host=""
new_primary_port=""
# bounds every redis-cli call; while writes are paused, the time left caps it
redis_cli_timeout_seconds=5
# The original replica priorities a run changes, saved before it changes them and
# removed once all are restored. A run otherwise keeps them only in its own memory,
# so a later run could not restore them when this one could not.
priorities_file=/tmp/falkordb-switchover-priorities

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
    role_info=$(timeout "$(redis_cli_timeout)" redis-cli $REDIS_CLI_TLS_CMD -h "$host" -p "$port" info replication)
  else
    role_info=$(timeout "$(redis_cli_timeout)" redis-cli $REDIS_CLI_TLS_CMD -h "$host" -p "$port" -a "$REDIS_DEFAULT_PASSWORD" info replication)
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

# The one primary when every data pod answers and exactly one of them is primary.
# Unlike check_redis_kernel_status it fails when a pod does not answer, since that
# pod may be a primary too: a repeated switchover is taken as done only on this.
only_primary_of_all_pods() {
  local role primary="" redis_pod_fqdn
  local -a redis_pod_fqdn_list
  IFS=',' read -ra redis_pod_fqdn_list <<< "${REDIS_POD_FQDN_LIST}"
  for redis_pod_fqdn in "${redis_pod_fqdn_list[@]}"; do
    role=$(check_redis_role "$redis_pod_fqdn" "$redis_service_port") || return 1
    if [[ "$role" == "primary" ]]; then
      [[ -z "$primary" ]] || return 1
      primary="$redis_pod_fqdn"
    fi
  done
  [[ -n "$primary" ]] || return 1
  echo "$primary"
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
    result=$(timeout "$(redis_cli_timeout)" redis-cli $REDIS_CLI_TLS_CMD -h "$host" -p "$port" -a "$password" PING)
  else
    result=$(timeout "$(redis_cli_timeout)" redis-cli $REDIS_CLI_TLS_CMD -h "$host" -p "$port" PING)
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
    output=$(timeout "$(redis_cli_timeout)" redis-cli $REDIS_CLI_TLS_CMD -h "$host" -p "$port" -a "$password" $command)
  else
    output=$(timeout "$(redis_cli_timeout)" redis-cli $REDIS_CLI_TLS_CMD -h "$host" -p "$port" $command)
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
    output=$(timeout "$(redis_cli_timeout)" redis-cli $REDIS_CLI_TLS_CMD -h "$host" -p "$port" -a "$password" $command)
  else
    output=$(timeout "$(redis_cli_timeout)" redis-cli $REDIS_CLI_TLS_CMD -h "$host" -p "$port" $command)
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

# EPOCHREALTIME needs bash 5; date is the fallback for older ones.
now_ms() {
  if [ -n "${EPOCHREALTIME:-}" ]; then
    local now="${EPOCHREALTIME/[.,]/}"
    echo $((now / 1000))
  else
    date +%s%3N
  fi
}

# Prints the timeout for the next redis-cli call: redis_cli_timeout_seconds, or
# while writes are paused, the time the pause has left (200 ms at least).
redis_cli_timeout() {
  local limit_ms=$((redis_cli_timeout_seconds * 1000)) left_ms
  if ! is_empty "$fence_deadline_ms"; then
    left_ms=$((fence_deadline_ms - $(now_ms)))
    if [ "$left_ms" -lt "$limit_ms" ]; then
      limit_ms=$left_ms
    fi
  fi
  if [ "$limit_ms" -lt 200 ]; then
    limit_ms=200
  fi
  printf '%d.%03d\n' $((limit_ms / 1000)) $((limit_ms % 1000))
}

fence_time_left() {
  [ "$(now_ms)" -lt "$fence_deadline_ms" ]
}

# One attempt per sentinel, without retry delays: it runs while writes are
# paused, and whether a failover started is read from the sentinels anyway.
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
    if execute_sub_command "$sentinel_pod_fqdn" "$SENTINEL_SERVICE_PORT" "$SENTINEL_PASSWORD" "SENTINEL FAILOVER $master_name"; then
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

# Prints the primary address ("host port") one sentinel reports, and nothing
# when it cannot be asked or reports none.
get_sentinel_master_addr() {
  local sentinel_pod_fqdn="$1" master_name="$2" output
  local -a addr
  output=$(redis_config_get "$sentinel_pod_fqdn" "$SENTINEL_SERVICE_PORT" "$SENTINEL_PASSWORD" "SENTINEL get-master-addr-by-name $master_name" 2>/dev/null) || return 0
  read -r -d '' -a addr <<< "$output" || true
  if [ "${#addr[@]}" -eq 2 ]; then
    echo "${addr[0]} ${addr[1]}"
  fi
}

# Prints the primary address ("host port") each reachable sentinel reports, one
# line per sentinel.
get_sentinel_master_addrs() {
  local master_name="${CUSTOM_SENTINEL_MASTER_NAME:-$REDIS_COMPONENT_NAME}"
  local sentinel_pod_fqdn
  local -a sentinel_pod_fqdn_list
  IFS=',' read -ra sentinel_pod_fqdn_list <<< "${SENTINEL_POD_FQDN_LIST}"
  for sentinel_pod_fqdn in "${sentinel_pod_fqdn_list[@]}"; do
    get_sentinel_master_addr "$sentinel_pod_fqdn" "$master_name"
  done
}

# Prints the down-after-milliseconds of the first sentinel that answers, or
# default_down_after_ms.
get_sentinel_down_after_ms() {
  local master_name="${CUSTOM_SENTINEL_MASTER_NAME:-$REDIS_COMPONENT_NAME}"
  local sentinel_pod_fqdn output value
  local -a sentinel_pod_fqdn_list
  IFS=',' read -ra sentinel_pod_fqdn_list <<< "${SENTINEL_POD_FQDN_LIST}"
  for sentinel_pod_fqdn in "${sentinel_pod_fqdn_list[@]}"; do
    output=$(redis_config_get "$sentinel_pod_fqdn" "$SENTINEL_SERVICE_PORT" "$SENTINEL_PASSWORD" "SENTINEL master $master_name" 2>/dev/null) || continue
    value=$(echo "${output//$'\r'/}" | sed -n '/^down-after-milliseconds$/{n;p;q;}')
    if [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -gt 0 ]; then
      echo "$value"
      return 0
    fi
  done
  echo "$default_down_after_ms"
}

# Returns 0 when every replica that can be reached follows the primary and has
# applied its whole replication stream, which stops growing while writes are
# paused, and the candidate, when there is one, is among them. A replica follows
# the primary when its master_host and master_port name the primary's pod or
# primary_addr, the address sentinel has for it ("host port"), which is what
# replicas are pointed at behind an announce override, a NodePort or a load
# balancer; the offset of a replica of another master means nothing here. Each
# replica is asked itself: the primary lists only the replicas that are online,
# so a replica still syncing would go unchecked, though Sentinel might promote it.
replicas_caught_up() {
  local primary_fqdn="$1" candidate_fqdn="$2" primary_addr="$3"
  local info master_offset pod_fqdn role link offset master_host master_port caught_up=0 candidate_caught_up=false
  local -a redis_pod_fqdn_list
  info=$(redis_config_get "$primary_fqdn" "$redis_service_port" "$REDIS_DEFAULT_PASSWORD" "INFO replication") || return 1
  info=${info//$'\r'/}
  master_offset=$(echo "$info" | sed -n 's/^master_repl_offset:\([0-9]*\).*/\1/p')
  if is_empty "$master_offset"; then
    echo "cannot read the replication offset of $primary_fqdn" >&2
    return 1
  fi
  IFS=',' read -ra redis_pod_fqdn_list <<< "${REDIS_POD_FQDN_LIST}"
  for pod_fqdn in "${redis_pod_fqdn_list[@]}"; do
    [ "$pod_fqdn" = "$primary_fqdn" ] && continue
    if ! info=$(redis_config_get "$pod_fqdn" "$redis_service_port" "$REDIS_DEFAULT_PASSWORD" "INFO replication" 2>/dev/null); then
      if ! is_empty "$candidate_fqdn" && [[ "$pod_fqdn" = "$candidate_fqdn"* ]]; then
        echo "the candidate $pod_fqdn cannot be reached" >&2
        return 1
      fi
      echo "replica $pod_fqdn cannot be reached, skipping it"
      continue
    fi
    info=${info//$'\r'/}
    role=$(echo "$info" | sed -n 's/^role:\([a-z]*\).*/\1/p')
    link=$(echo "$info" | sed -n 's/^master_link_status:\([a-z]*\).*/\1/p')
    offset=$(echo "$info" | sed -n 's/^slave_repl_offset:\([0-9]*\).*/\1/p')
    master_host=$(echo "$info" | sed -n 's/^master_host:\([^[:space:]]*\).*/\1/p')
    master_port=$(echo "$info" | sed -n 's/^master_port:\([0-9]*\).*/\1/p')
    if [ "$role" != "slave" ]; then
      echo "$pod_fqdn is not a replica (role: ${role:-unknown})" >&2
      return 1
    fi
    if ! { [ "$master_host" = "$primary_fqdn" ] && [ "$master_port" = "$redis_service_port" ]; } &&
       { is_empty "$primary_addr" || [ "$master_host $master_port" != "$primary_addr" ]; }; then
      echo "replica $pod_fqdn follows ${master_host:-unknown}:${master_port:-unknown}, not $primary_fqdn" >&2
      return 1
    fi
    if [ "$link" != "up" ] || is_empty "$offset" || [ "$offset" -lt "$master_offset" ]; then
      echo "replica $pod_fqdn is at offset ${offset:-unknown} of $master_offset (link ${link:-unknown})" >&2
      return 1
    fi
    caught_up=$((caught_up + 1))
    if ! is_empty "$candidate_fqdn" && [[ "$pod_fqdn" = "$candidate_fqdn"* ]]; then
      candidate_caught_up=true
    fi
  done
  if [ "$caught_up" -eq 0 ]; then
    echo "$primary_fqdn has no replica that caught up" >&2
    return 1
  fi
  if ! is_empty "$candidate_fqdn" && [ "$candidate_caught_up" != true ]; then
    echo "the candidate $candidate_fqdn is not a replica of $primary_fqdn" >&2
    return 1
  fi
  return 0
}

# Returns 0 and sets new_primary_host and new_primary_port when a sentinel
# reports a primary other than initial_addr that runs as a master. A lagging
# sentinel may still name an earlier primary that is a replica now, and the old
# primary must not be made a replica of one. The sentinels are asked all at
# once and each answer is looked at as it comes, so a slow sentinel does not
# hold up one that has already switched.
sentinel_reports_new_primary() {
  local initial_addr="$1" addr answers index pending
  local master_name="${CUSTOM_SENTINEL_MASTER_NAME:-$REDIS_COMPONENT_NAME}"
  local -a sentinel_pod_fqdn_list query_pids seen
  new_primary_host=""
  new_primary_port=""
  IFS=',' read -ra sentinel_pod_fqdn_list <<< "${SENTINEL_POD_FQDN_LIST}"
  answers=$(mktemp -d) || return 1
  for index in "${!sentinel_pod_fqdn_list[@]}"; do
    # an answer appears whole: it is written aside and then renamed
    { get_sentinel_master_addr "${sentinel_pod_fqdn_list[$index]}" "$master_name" > "$answers/$index.part"
      mv "$answers/$index.part" "$answers/$index"; } &
    query_pids+=($!)
  done
  pending=${#sentinel_pod_fqdn_list[@]}
  while [ "$pending" -gt 0 ]; do
    for index in "${!sentinel_pod_fqdn_list[@]}"; do
      [ -n "${seen[$index]:-}" ] || [ ! -f "$answers/$index" ] && continue
      seen[$index]=1
      pending=$((pending - 1))
      addr=$(cat "$answers/$index")
      if ! is_empty "$addr" && [ "$addr" != "$initial_addr" ]; then
        read -r new_primary_host new_primary_port <<< "$addr"
        if [ "$(check_redis_role "$new_primary_host" "$new_primary_port" 2>/dev/null)" = "primary" ]; then
          echo "sentinel switched the primary from $initial_addr to $addr"
          kill "${query_pids[@]}" 2>/dev/null || true
          rm -rf "$answers"
          return 0
        fi
        echo "a sentinel reports $addr as the primary, but it does not run as one (yet)"
        new_primary_host=""
        new_primary_port=""
      fi
    done
    [ "$pending" -gt 0 ] && sleep 0.05
  done
  wait "${query_pids[@]}" 2>/dev/null || true
  rm -rf "$answers"
  return 1
}

# Returns 0 when a sentinel is failing over the primary, or cannot be asked and
# so may be: SENTINEL FAILOVER marks the failover in progress at once, and the
# mark stays until it switches or gives up.
sentinel_may_be_failing_over() {
  local master_name="${CUSTOM_SENTINEL_MASTER_NAME:-$REDIS_COMPONENT_NAME}"
  local sentinel_pod_fqdn output flags
  local -a sentinel_pod_fqdn_list
  IFS=',' read -ra sentinel_pod_fqdn_list <<< "${SENTINEL_POD_FQDN_LIST}"
  for sentinel_pod_fqdn in "${sentinel_pod_fqdn_list[@]}"; do
    output=$(redis_config_get "$sentinel_pod_fqdn" "$SENTINEL_SERVICE_PORT" "$SENTINEL_PASSWORD" "SENTINEL master $master_name" 2>/dev/null) || return 0
    flags=$(echo "$output" | sed -n '/^flags$/{n;p;q;}')
    if is_empty "$flags" || [[ ",$flags," == *,failover_in_progress,* ]]; then
      return 0
    fi
  done
  return 1
}

# Waits until until_ms for the failover to switch the primary. Returns 0 with the
# new primary in new_primary_host and new_primary_port, 2 when the failover
# ended without switching, and 1 when neither is known by until_ms.
wait_for_sentinel_to_switch_master() {
  local initial_addr="$1" until_ms="$2" poll_seconds="${3:-0.1}"
  while true; do
    if sentinel_reports_new_primary "$initial_addr"; then
      return 0
    fi
    if ! sentinel_may_be_failing_over; then
      # it may have switched just after the first look
      if sentinel_reports_new_primary "$initial_addr"; then
        return 0
      fi
      echo "Error: sentinel is no longer failing over and still reports $initial_addr as the primary" >&2
      return 2
    fi
    if [ "$(now_ms)" -ge "$until_ms" ]; then
      return 1
    fi
    sleep_when_ut_mode_false "$poll_seconds"
  done
}

# SENTINEL FAILOVER promotes a replica but leaves the old primary a writable
# master until Sentinel demotes it, some 10 s later, and whatever it acknowledges
# meanwhile is lost when it resyncs from the new primary. So writes on it are
# paused first, the replicas left to catch up, and the old primary is made a
# replica of the new one here as soon as Sentinel has switched. Sentinel cannot
# be left to do it: the pause also blocks the PUBLISH it sends its hellos with,
# and the commands it sends after it on the same link. Paused writers are never
# acknowledged: once the old primary is a replica they get READONLY.
#
# The pause lasts down-after-milliseconds at most, the node-down time sentinel
# allows, and every step runs within it. A failover that has not switched by
# then is still watched without the pause, and the old primary is demoted as
# soon as it does; what it acknowledged in between may be lost.
failover_with_writes_paused() {
  local old_primary="$1"
  local initial_addr caught_up=false switch_rc=0 failover_rc=0 pause_started_ms
  # Sentinels that disagree on the primary leave no address to tell the new one
  # from, so a stale answer could pass for the switch.
  initial_addr=$(get_sentinel_master_addrs | sort -u)
  if is_empty "$initial_addr"; then
    echo "Error: no sentinel reports the current primary" >&2
    return 1
  fi
  if [ "$(echo "$initial_addr" | wc -l)" -gt 1 ]; then
    echo "Error: the sentinels disagree on the primary ($(echo "$initial_addr" | paste -sd, -)), not switching over" >&2
    return 1
  fi
  write_pause_ms=$(get_sentinel_down_after_ms)

  # The pause counts from before it is asked for, so the deadline never falls
  # after the pause has really ended.
  pause_started_ms=$(now_ms)
  if ! execute_sub_command "$old_primary" "$redis_service_port" "$REDIS_DEFAULT_PASSWORD" "CLIENT PAUSE $write_pause_ms WRITE"; then
    echo "Error: failed to pause writes on $old_primary" >&2
    return 1
  fi
  fence_deadline_ms=$((pause_started_ms + write_pause_ms))
  echo "writes paused on $old_primary for $write_pause_ms ms, sentinel's down-after-milliseconds"

  while fence_time_left; do
    if replicas_caught_up "$old_primary" "$KB_SWITCHOVER_CANDIDATE_FQDN" "$initial_addr"; then
      caught_up=true
      break
    fi
    sleep_when_ut_mode_false 0.1
  done
  # The scan itself may outlast the pause, and the offset it compared with
  # then misses the writes taken since, so the pause must still be running.
  if [ "$caught_up" != true ] || ! fence_time_left; then
    echo "Error: the replicas of $old_primary did not catch up within $write_pause_ms ms, not switching over" >&2
    unpause_writes "$old_primary"
    return 1
  fi

  # A request that timed out, or failed after a sentinel took it, may still have
  # started the failover, so its outcome is read from the sentinels either way.
  execute_sentinel_failover "$CUSTOM_SENTINEL_MASTER_NAME" || failover_rc=$?
  wait_for_sentinel_to_switch_master "$initial_addr" "$fence_deadline_ms" || switch_rc=$?
  if [ $switch_rc -eq 2 ]; then
    unpause_writes "$old_primary"
    return 1
  fi
  if [ $switch_rc -eq 1 ]; then
    # The pause has run out. Keep watching, and demote the old primary the
    # moment the switch shows, so that few of the writes it takes meanwhile
    # are lost.
    fence_deadline_ms=""
    echo "Warning: sentinel has not switched within the $write_pause_ms ms writes may stay paused; $old_primary takes writes again until it is demoted" >&2
    switch_rc=0
    wait_for_sentinel_to_switch_master "$initial_addr" "$(( $(now_ms) + failover_watch_seconds * 1000 ))" 1 || switch_rc=$?
    if [ $switch_rc -eq 1 ]; then
      echo "Error: sentinel is still failing over from $initial_addr after another ${failover_watch_seconds}s" >&2
    fi
    if [ $switch_rc -ne 0 ]; then
      return 1
    fi
  fi
  if [ $failover_rc -ne 0 ]; then
    echo "the failover request failed, but sentinel switched the primary all the same"
  fi

  demote_old_primary "$old_primary" || return 1
  unpause_writes "$old_primary"
  return 0
}

# Makes the old primary a replica of the new one. Unpausing a primary that is
# still a master would let it acknowledge writes the new primary never gets, so
# whatever REPLICAOF answers, success is its reporting itself a replica; a pause
# still running is then left to end on its own.
demote_old_primary() {
  local old_primary="$1" attempt
  for ((attempt = 0; attempt < 3; attempt++)); do
    execute_sub_command "$old_primary" "$redis_service_port" "$REDIS_DEFAULT_PASSWORD" "REPLICAOF $new_primary_host $new_primary_port" || true
    if [ "$(check_redis_role "$old_primary" "$redis_service_port" 2>/dev/null)" = "secondary" ]; then
      echo "$old_primary is now a replica of $new_primary_host:$new_primary_port"
      return 0
    fi
    sleep_when_ut_mode_false 0.1
  done
  echo "Error: $old_primary is not a replica of $new_primary_host:$new_primary_port yet; sentinel demotes it, and a running pause ends on its own" >&2
  return 1
}

# A failed unpause does not fail the switchover: it only keeps writers waiting
# until the pause ends on its own, and loses none of their writes.
unpause_writes() {
  local primary_fqdn="$1"
  fence_deadline_ms=""
  if execute_sub_command "$primary_fqdn" "$redis_service_port" "$REDIS_DEFAULT_PASSWORD" "CLIENT UNPAUSE"; then
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
    # and to a file before the change, so that a later run can restore it if this one cannot
    echo "$redis_pod_fqdn $original_priority" >> "$priorities_file" ||
      echo "Warning: could not save the replica-priority of $redis_pod_fqdn to $priorities_file" >&2

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
  rm -f "$priorities_file"
  echo "All FalkorDB config set replica-priority recovered."
  return 0
}

# Restores the priorities an earlier run saved and could not restore, before this
# run reads or changes any, and removes the file once all are back.
restore_saved_priorities() {
  [ -f "$priorities_file" ] || return 0
  local pod_fqdn priority
  echo "Restoring the replica-priority an earlier switchover could not restore..."
  while read -r pod_fqdn priority; do
    [ -n "$pod_fqdn" ] && [ -n "$priority" ] || continue
    call_func_with_retry 3 5 execute_sub_command "$pod_fqdn" "$redis_service_port" "$REDIS_DEFAULT_PASSWORD" "CONFIG SET replica-priority $priority" || return 1
  done < "$priorities_file"
  rm -f "$priorities_file"
}

switchover_with_candidate() {
  restore_saved_priorities || {
    echo "Error: could not restore the replica-priority an earlier switchover saved in $priorities_file" >&2
    return 1
  }
  # check the role of candidate before switchover
  local candidate_role current_master
  candidate_role=$(check_redis_role "$KB_SWITCHOVER_CANDIDATE_FQDN" "$redis_service_port")
  # KubeBlocks can run the action a second time for the same OpsRequest, before
  # the role labels catch up with the first run; that run has already succeeded.
  # It is done only when every pod answers with the candidate as the one primary.
  if [[ "$candidate_role" == "primary" ]] && current_master=$(only_primary_of_all_pods) &&
    [[ "$current_master" == "$KB_SWITCHOVER_CANDIDATE_FQDN"* ]]; then
    echo "$KB_SWITCHOVER_CANDIDATE_FQDN is already the only primary, nothing to do"
    return 0
  fi
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
  # Priorities an earlier switchover left would steer which replica Sentinel promotes.
  restore_saved_priorities || {
    echo "Error: could not restore the replica-priority an earlier switchover saved in $priorities_file" >&2
    return 1
  }
  # check redis kernel role before switchover
  local initial_master
  initial_master=$(check_redis_kernel_status) || return 1

  # A second run of the action for the same OpsRequest would move the primary
  # back; once every pod answers and the one primary is no longer the pod
  # KubeBlocks asked to switch over, we are done.
  local current_master
  if ! is_empty "$KB_SWITCHOVER_CURRENT_NAME" && current_master=$(only_primary_of_all_pods) &&
    [[ "${current_master%%.*}" != "$KB_SWITCHOVER_CURRENT_NAME" ]]; then
    echo "$KB_SWITCHOVER_CURRENT_NAME is no longer the primary ($current_master is), nothing to do"
    return 0
  fi

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
# The common library turns tracing back on after each redis-cli call it hides,
# which would trace the callers' arguments, passwords among them.
set_xtrace_when_ut_mode_false() { :; }
check_environment_exist || exit 1
if is_empty "$KB_SWITCHOVER_CANDIDATE_FQDN"; then
  switchover_without_candidate || exit 1
else
  switchover_with_candidate || exit 1
fi

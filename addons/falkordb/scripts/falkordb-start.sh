#!/bin/bash

# shellcheck disable=SC2153
# shellcheck disable=SC2207
# shellcheck disable=SC2034

# This is magic for shellspec ut framework. "test" is a `test [expression]` well known as a shell command.
# Normally test without [expression] returns false. It means that __() { :; }
# function is defined if this script runs directly.
#
# shellspec overrides the test command and returns true *once*. It means that
# __() function defined internally by shellspec is called.
#
# In other words. If not in test mode, __ is just a comment. If test mode, __
# is a interception point.
# you should set ut_mode="true" when you want to run the script in shellspec file.
ut_mode="false"
test || __() {
  # when running in non-unit test mode, set the options "set -ex".
  set -ex;
}

primary=""
primary_port="${SERVICE_PORT:-6379}"
redis_template_conf="/etc/conf/redis.conf"
redis_real_conf="/etc/redis/redis.conf"
redis_extra_conf="/etc/conf/extra/redis.conf"
redis_acl_file="/data/users.acl"
redis_acl_file_bak="/data/users.acl.bak"
redis_data_dir="/data"
retry_times=3
retry_delay_second=2
# The start waits for a sentinel failing this pod over (see build_replicaof_config)
# for no longer than sentinel's node-down timeout, down-after-milliseconds: past
# that, an HA setup is in downtime. It is read from sentinel's replies, and this,
# the value the addon registers, is used until one comes. Setting
# sentinel_failover_wait_ms overrides it.
default_down_after_ms=5000
sentinel_failover_wait_ms=""
sentinel_failover_wait_delay_ms=1000
service_port=${SERVICE_PORT:-6379}
redis_server_process_name="redis-server"
redis_server_launcher_pid=""
pending_server_signal=""
proc_root="/proc"

load_common_library() {
  # the common.sh scripts is mounted to the same path which is defined in the cmpd.spec.scripts
  common_library_file="/scripts/common.sh"
  # shellcheck disable=SC1090
  source "${common_library_file}"
}

load_redis_template_conf() {
  # Start from an empty file: it is on an emptyDir that survives a container
  # restart, so appending would keep the last start's lines and whatever
  # Sentinel's CONFIG REWRITE added, including a loadmodule line that, with the
  # --loadmodule the server is started with, loads the module twice and aborts.
  echo "include $redis_template_conf" > $redis_real_conf
  # if the file redis_extra_conf exists, include it too
  if [ -f $redis_extra_conf ]; then
    echo "include $redis_extra_conf" >> $redis_real_conf
  fi
}

extract_lb_host_by_svc_name() {
  local svc_name="$1"
  for lb_composed_name in $(echo "$REDIS_LB_ADVERTISED_HOST" | tr ',' '\n' ); do
    if [[ ${lb_composed_name} == *":"* ]]; then
       if [[ ${lb_composed_name%:*} == "$svc_name" ]]; then
         echo "${lb_composed_name#*:}"
         break
       fi
    else
       break
    fi
  done
}

get_announce_hostname_override_or_default() {
  local default_value="$1"
  local pod_name="$2"
  if is_empty "$ANNOUNCE_HOSTNAME_OVERRIDE"; then
    echo "$default_value"
    return
  fi
  # Each pod has to announce a name of its own, so the override is a template
  # rather than a literal. $(POD_NAME) survives as-is until here because no
  # container declares POD_NAME, and the kubelet leaves unknown references alone.
  echo "${ANNOUNCE_HOSTNAME_OVERRIDE//\$(POD_NAME)/$pod_name}"
}

build_redis_default_accounts() {
  unset_xtrace_when_ut_mode_false
  if ! is_empty "$REDIS_REPL_PASSWORD"; then
    echo "masteruser $REDIS_REPL_USER" >> $redis_real_conf
    echo "masterauth $REDIS_REPL_PASSWORD" >> $redis_real_conf
    echo "user $REDIS_REPL_USER on +psync +replconf +ping >$REDIS_REPL_PASSWORD" >> $redis_acl_file
  fi
  if ! is_empty "$REDIS_SENTINEL_PASSWORD"; then
    echo "user $REDIS_SENTINEL_USER on allchannels +multi +slaveof +ping +exec +subscribe +config|rewrite +role +publish +info +client|setname +client|kill +script|kill >$REDIS_SENTINEL_PASSWORD" >> $redis_acl_file
  fi
  if ! is_empty "$REDIS_DEFAULT_PASSWORD"; then
    echo "protected-mode yes" >> $redis_real_conf
    echo "user default on >$REDIS_DEFAULT_PASSWORD ~* &* +@all " >> $redis_acl_file
  else
    echo "protected-mode no" >> $redis_real_conf
  fi
  set_xtrace_when_ut_mode_false
  echo "aclfile /data/users.acl" >> $redis_real_conf
  echo "build default accounts succeeded!"
}

add_extra_falkordb_user_account() {
  if is_empty "$FALKORDB_EXTRA_USER_USERNAME" || is_empty "$FALKORDB_EXTRA_USER_PASSWORD"; then
    echo "No extra FalkorDB user configured, skipping."
    return
  fi

  local acl_rules="$FALKORDB_EXTRA_USER_ACL"
  if is_empty "$acl_rules"; then
    acl_rules="~* +@all"
  fi

  echo "Adding extra FalkorDB user $FALKORDB_EXTRA_USER_USERNAME to ACL file."
  # Remove any existing entry for this user to prevent duplicates
  if [ -f $redis_acl_file ]; then
    sed "/user $FALKORDB_EXTRA_USER_USERNAME on/d" $redis_acl_file > $redis_acl_file_bak && mv $redis_acl_file_bak $redis_acl_file
  fi
  echo "user $FALKORDB_EXTRA_USER_USERNAME on >$FALKORDB_EXTRA_USER_PASSWORD $acl_rules" >> $redis_acl_file
}

build_announce_ip_and_port() {
  local announce_host_value=""
  local announce_port_value=""
  # build announce ip and port according to whether the announce addr is exist
  if ! is_empty "$redis_announce_host_value" && ! is_empty "$redis_announce_port_value"; then
    echo "redis use nodeport $redis_announce_host_value:$redis_announce_port_value to announce"
    announce_host_value="$redis_announce_host_value"
    announce_port_value="$redis_announce_port_value"
  elif [ "$FIXED_POD_IP_ENABLED" == "true" ]; then
      echo "" > /data/.fixed_pod_ip_enabled
      echo "redis use immutable pod ip $CURRENT_POD_IP to announce"
      announce_host_value="$CURRENT_POD_IP"
  else
    current_pod_fqdn=$(get_target_pod_fqdn_from_pod_fqdn_vars "$REDIS_POD_FQDN_LIST" "$CURRENT_POD_NAME")
    if is_empty "$current_pod_fqdn"; then
      echo "Error: Failed to get current pod: $CURRENT_POD_NAME fqdn from redis pod fqdn list: $REDIS_POD_FQDN_LIST. Exiting."
      exit 1
    fi
    echo "redis use kb pod fqdn $current_pod_fqdn to announce"
    announce_host_value="$current_pod_fqdn"
  fi

  announce_host_value=$(get_announce_hostname_override_or_default "$announce_host_value" "$CURRENT_POD_NAME")
  if ! is_empty "$ANNOUNCE_HOSTNAME_OVERRIDE"; then
    echo "announce hostname override is set, using $announce_host_value for replica announce"
  fi

  {
    if ! is_empty "$announce_port_value"; then
      echo "replica-announce-port $announce_port_value"
    fi
    echo "replica-announce-ip $announce_host_value"
  } >> $redis_real_conf
}

build_redis_service_port() {
  if [ "$TLS_ENABLED" == "true" ]; then
    echo "tls-port $service_port" >> $redis_real_conf
  else
    echo "port $service_port" >> $redis_real_conf
  fi
}

build_redis_tls_config() {
  if [ "$TLS_ENABLED" == "true" ]; then
    TLS_MOUNT_PATH=${TLS_MOUNT_PATH:-/etc/pki/tls}
    {
      echo "tls-cert-file $TLS_MOUNT_PATH/tls.crt"
      echo "tls-key-file $TLS_MOUNT_PATH/tls.key"
      echo "tls-ca-cert-file $TLS_MOUNT_PATH/ca.crt"
      echo "tls-auth-clients no"
      echo "tls-replication yes"
      echo "port 0"
    } >> $redis_real_conf
  fi
}

build_replicaof_config() {
  init_or_get_primary_from_redis_sentinel
  # Sentinel still names this pod while it fails it over after it went away:
  # starting as master then makes a second primary next to the replica Sentinel
  # promotes. Wait for the failover, then ask again. Ask again even when there
  # was nothing to wait for: the failover may have ended since the first answer.
  if check_current_pod_is_primary; then
    wait_while_sentinel_fails_over_current_pod || true
    init_or_get_primary_from_redis_sentinel
  fi
  if check_current_pod_is_primary; then
    return
  else
    echo "replicaof $primary $primary_port" >> $redis_real_conf
  fi
}

# Prints the flags (such as "master,s_down,o_down") the sentinel holds for the
# primary it monitors, followed by its down-after-milliseconds when the reply
# has it, and nothing when it monitors none. Returns 1 when the
# sentinel cannot be asked or its reply cannot be read: redis-cli exits 0 on an
# error reply, so only the reply tells an answer from a failure.
get_sentinel_primary_flags() {
  local sentinel_pod_fqdn="$1" query_timeout="${2:-5}"
  local output
  sentinel_service_port=${SENTINEL_SERVICE_PORT:-26379}
  unset_xtrace_when_ut_mode_false
  if is_empty "$SENTINEL_PASSWORD"; then
    output=$(timeout "$query_timeout" redis-cli $REDIS_CLI_TLS_CMD -h "$sentinel_pod_fqdn" -p "$sentinel_service_port" sentinel master "$REDIS_COMPONENT_NAME" 2>/dev/null)
  else
    output=$(timeout "$query_timeout" redis-cli $REDIS_CLI_TLS_CMD -h "$sentinel_pod_fqdn" -p "$sentinel_service_port" -a "$SENTINEL_PASSWORD" --no-auth-warning sentinel master "$REDIS_COMPONENT_NAME" 2>/dev/null)
  fi
  set_xtrace_when_ut_mode_false
  # the reply is a list of alternating field names and values
  local flags down_after
  output=${output//$'\r'/}
  flags=$(echo "$output" | sed -n '/^flags$/{n;p;q;}')
  down_after=$(echo "$output" | sed -n '/^down-after-milliseconds$/{n;p;q;}')
  if ! is_empty "$flags"; then
    echo "$flags${down_after:+ $down_after}"
    return 0
  fi
  [[ "$output" == *"No such master"* ]]
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

ms_to_seconds() {
  printf '%d.%03d\n' $(($1 / 1000)) $(($1 % 1000))
}

# Returns 0 after waiting while any sentinel is failing over its primary, this
# pod, and 1 straight away when every sentinel answers that none is. A sentinel
# that cannot be asked may be the one running the failover, so it is waited for
# too. A sentinel that only sees the pod down is not: when every pod restarts at
# once that would hand a replica, perhaps behind this pod, the time to be
# promoted. The wait never goes past sentinel's down-after-milliseconds: slow
# sentinels count against it, each query gets at most the time left, and none
# is asked once it is up. A failover a sentinel reported stays in mind until a
# later answer from that sentinel says it is over: one that cannot be asked
# again has not said so. A failover still unresolved at the end exits the start,
# since this pod could otherwise start as a master next to the replica being
# promoted; the container is restarted and asks again. A sentinel that is only
# unreachable, having reported no failover, does not, or it could keep the pod
# from starting.
wait_while_sentinel_fails_over_current_pod() {
  if is_empty "$SENTINEL_COMPONENT_NAME" || is_empty "$SENTINEL_POD_FQDN_LIST"; then
    return 1
  fi
  local sentinel_pod_fqdn reply flags down_after waited=1 failing_over="" unreachable="" remaining
  # the flags each sentinel last reported a failover in progress with
  local -A failover_seen=()
  local started budget_ms="$sentinel_failover_wait_ms" budget_known=true deadline
  started=$(now_ms)
  if is_empty "$budget_ms"; then
    budget_ms=$default_down_after_ms
    budget_known=false
  fi
  deadline=$((started + budget_ms))
  while true; do
    unreachable=""
    for sentinel_pod_fqdn in $(split "$SENTINEL_POD_FQDN_LIST" ","); do
      remaining=$((deadline - $(now_ms)))
      if [ "$remaining" -le 0 ]; then
        unreachable="${unreachable:+$unreachable }$sentinel_pod_fqdn"
        continue
      fi
      [ "$remaining" -gt 5000 ] && remaining=5000
      if ! reply=$(get_sentinel_primary_flags "$sentinel_pod_fqdn" "$(ms_to_seconds "$remaining")"); then
        unreachable="${unreachable:+$unreachable }$sentinel_pod_fqdn"
        continue
      fi
      read -r flags down_after <<< "$reply"
      if [ "$budget_known" != true ] && [[ "$down_after" =~ ^[0-9]+$ ]] && [ "$down_after" -gt 0 ]; then
        budget_ms=$down_after
        deadline=$((started + budget_ms))
        budget_known=true
      fi
      if [[ ",$flags," == *,failover_in_progress,* ]]; then
        failover_seen[$sentinel_pod_fqdn]="$flags"
        # one failover is reason enough to wait; the others are asked next round
        break
      else
        unset "failover_seen[$sentinel_pod_fqdn]"
      fi
    done
    failing_over=""
    for sentinel_pod_fqdn in "${!failover_seen[@]}"; do
      failing_over="${failing_over:+$failing_over, }$sentinel_pod_fqdn (${failover_seen[$sentinel_pod_fqdn]})"
    done
    if is_empty "$failing_over" && is_empty "$unreachable"; then
      return $waited
    fi
    waited=0
    if ! is_empty "$failing_over"; then
      echo "sentinel $failing_over is failing over this pod, its primary; waiting for it before starting."
    else
      echo "sentinel $unreachable cannot be asked and may be failing over this pod, its primary; waiting before starting."
    fi
    remaining=$((deadline - $(now_ms)))
    if [ "$remaining" -le 0 ]; then
      break
    fi
    [ "$remaining" -gt "$sentinel_failover_wait_delay_ms" ] && remaining=$sentinel_failover_wait_delay_ms
    sleep_when_ut_mode_false "$(ms_to_seconds "$remaining")"
    if [ "$(now_ms)" -ge "$deadline" ]; then
      break
    fi
  done
  if ! is_empty "$failing_over"; then
    echo "Error: sentinel $failing_over is still failing over this pod after ${budget_ms} ms, its down-after-milliseconds; refusing to start while it may promote another pod. Exiting."
    exit 1
  fi
  echo "sentinel $unreachable still cannot be asked after ${budget_ms} ms; asking the others for the primary again."
  return 0
}

rebuild_redis_acl_file() {
  if [ -f $redis_acl_file ]; then
    sed "/user default on/d" $redis_acl_file > $redis_acl_file_bak && mv $redis_acl_file_bak $redis_acl_file
    sed "/user $REDIS_REPL_USER on/d" $redis_acl_file > $redis_acl_file_bak && mv $redis_acl_file_bak $redis_acl_file
    sed "/user $REDIS_SENTINEL_USER on/d" $redis_acl_file > $redis_acl_file_bak && mv $redis_acl_file_bak $redis_acl_file
  else
    touch $redis_acl_file
  fi
}

init_or_get_primary_from_redis_sentinel() {
  # check redis sentinel component env
  if ! env_exist SENTINEL_COMPONENT_NAME; then
    # return default primary node if redis sentinel component name is not set
    echo "SENTINEL_COMPONENT_NAME env is not set, try to use default primary node."
    get_default_initialize_primary_node
    return
  fi

  # parse redis sentinel pod fqdn list from $SENTINEL_POD_FQDN_LIST env
  if ! env_exist SENTINEL_POD_FQDN_LIST; then
    echo "Error: Required environment variable SENTINEL_POD_FQDN_LIST is not set."
    exit 1
  fi

  declare -A master_count_map
  local first_redis_primary_host=""
  local first_redis_primary_port=""
  local sentinels_without_primary=0
  sentinel_pod_fqdn_list=($(split "$SENTINEL_POD_FQDN_LIST" ","))
  for sentinel_pod_fqdn in "${sentinel_pod_fqdn_list[@]}"; do
    # get primary info from sentinel
    if retry_get_master_addr_by_name_from_sentinel $retry_times $retry_delay_second "$sentinel_pod_fqdn"; then
      echo "sentinel:$sentinel_pod_fqdn has master info: ${REDIS_SENTINEL_PRIMARY_INFO[*]}"
      if [ "${#REDIS_SENTINEL_PRIMARY_INFO[@]}" -ne 2 ] || [ -z "${REDIS_SENTINEL_PRIMARY_INFO[0]}" ] || [ -z "${REDIS_SENTINEL_PRIMARY_INFO[1]}" ]; then
        echo "Empty primary info retrieved from sentinel: $sentinel_pod_fqdn. Skipping this sentinel."
        continue
      fi

      # increment the count of this master in the map
      host_port_key="${REDIS_SENTINEL_PRIMARY_INFO[0]}:${REDIS_SENTINEL_PRIMARY_INFO[1]}"
      master_count_map[$host_port_key]=$((${master_count_map[$host_port_key]} + 1))

      # track the primary host and port from the first sentinel
      if is_empty "$first_redis_primary_host" && is_empty "$first_redis_primary_port"; then
        first_redis_primary_host=${REDIS_SENTINEL_PRIMARY_INFO[0]}
        first_redis_primary_port=${REDIS_SENTINEL_PRIMARY_INFO[1]}
      fi

      # log if sentinel has different primary node info
      if ! equals "$first_redis_primary_host" "${REDIS_SENTINEL_PRIMARY_INFO[0]}" || ! equals "$first_redis_primary_port" "${REDIS_SENTINEL_PRIMARY_INFO[1]}"; then
        echo "The sentinel:$sentinel_pod_fqdn has different primary node info. First: $first_redis_primary_host:$first_redis_primary_port, Current: ${REDIS_SENTINEL_PRIMARY_INFO[0]}:${REDIS_SENTINEL_PRIMARY_INFO[1]}"
      fi
    else
      if [ "$REDIS_SENTINEL_MONITORS_NO_PRIMARY" == "true" ]; then
        sentinels_without_primary=$((sentinels_without_primary + 1))
      fi
      echo "Failed to retrieve primary info from sentinel: $sentinel_pod_fqdn. Skipping this sentinel."
    fi
  done

  # sentinel is configured but none of them knows the primary. Falling back to
  # the default primary is only safe when nothing can be lost: a pod restarting
  # with persisted data during a sentinel outage could otherwise come up as a
  # second primary (split-brain) or replicate from an empty one (data loss).
  echo "get all primary info from redis sentinel master_count_map: ${master_count_map[*]}"
  if [ ${#master_count_map[@]} -eq 0 ]; then
    if ! redis_data_dir_has_persisted_data; then
      echo "no primary node found from all redis sentinels and $redis_data_dir has no persisted data, use default primary node for first bootstrap."
      get_default_initialize_primary_node
      return
    fi
    # Every sentinel answered and none monitors this component: the sentinels
    # are fresh or lost their state, they are not down. A cluster restored from
    # backup lands here, since its primary is registered (postProvision) only
    # once a pod runs as primary, so failing would never let it register. A nil
    # reply cannot tell fresh from lost state, so ask the other pods: follow a
    # live primary if there is one, and take the default only when none is.
    if [ "$sentinels_without_primary" -eq "${#sentinel_pod_fqdn_list[@]}" ]; then
      echo "every sentinel is reachable and none monitors $REDIS_COMPONENT_NAME, while $redis_data_dir holds persisted data ($persisted_data_entry); looking for a live primary among the other pods."
      if ! find_live_primary_among_peers; then
        echo "Error: cannot tell which pod is the live primary ($live_primary_error); refusing to pick a primary while sentinel monitors none. Exiting."
        exit 1
      fi
      if ! is_empty "$live_primary_fqdn"; then
        echo "follow the live primary $live_primary_fqdn reported by the pod itself."
        primary="$live_primary_fqdn"
        primary_port="$service_port"
        return
      fi
      # Replicas that disagree on their primary (a failover that only partly
      # propagated) leave no safe choice: the other pod may hold newer writes.
      if ! is_empty "$peers_follow_current_pod" && ! is_empty "$peers_follow_other_pod"; then
        echo "Error: no other pod is running as primary, $peers_follow_current_pod replicate from this pod but $peers_follow_other_pod from another; refusing to pick a primary. Exiting."
        exit 1
      fi
      # The replicas still point at the primary that went away. When that is
      # this pod (a restart during a rolling update), it takes the role back:
      # following the default instead would make it a replica of one of its own
      # replicas, and neither would ever serve as primary.
      if ! is_empty "$peers_follow_current_pod"; then
        current_pod_fqdn=$(get_target_pod_fqdn_from_pod_fqdn_vars "$REDIS_POD_FQDN_LIST" "$CURRENT_POD_NAME")
        if is_empty "$current_pod_fqdn"; then
          echo "Error: Failed to get current pod: $CURRENT_POD_NAME fqdn from redis pod fqdn list: $REDIS_POD_FQDN_LIST. Exiting."
          exit 1
        fi
        echo "no other pod is running as primary and $peers_follow_current_pod replicate from this pod, take the primary role back."
        primary="$current_pod_fqdn"
        primary_port="$service_port"
        return
      fi
      # They point at another pod that is not up as primary yet. Taking the
      # default now could promote a replica that missed the latest writes; that
      # pod takes the role back when it restarts.
      if ! is_empty "$peers_follow_other_pod"; then
        echo "Error: no other pod is running as primary and $peers_follow_other_pod replicate from a pod that is not; waiting for it rather than picking the default primary. Exiting."
        exit 1
      fi
      echo "no other pod is running as primary, use default primary node."
      get_default_initialize_primary_node
      return
    fi
    echo "Error: no primary node found from all redis sentinels ($sentinels_without_primary of ${#sentinel_pod_fqdn_list[@]} reachable without a primary) and $redis_data_dir already holds persisted data ($persisted_data_entry); refusing to fall back to the default primary while sentinel is configured. Exiting."
    exit 1
  fi

  # get the primary node with the most counts
  max_count=0
  for host_port in "${!master_count_map[@]}"; do
    if (( ${master_count_map[$host_port]} > max_count )); then
      max_count=${master_count_map[$host_port]}
      primary=$(echo $host_port | cut -d: -f1)
      primary_port=$(echo $host_port | cut -d: -f2)
    fi
  done
}

# Asks every other pod for its replication role. Returns 0 with live_primary_fqdn
# set to the one pod running as master, or empty when none is. A pod that cannot
# be reached is not serving as primary. Replicas are listed in
# peers_follow_current_pod when they replicate from this pod, and in
# peers_follow_other_pod otherwise. Returns 1 with live_primary_error set when
# several pods are masters, or a reachable pod's role cannot be read.
find_live_primary_among_peers() {
  live_primary_fqdn=""
  live_primary_error=""
  peers_follow_current_pod=""
  peers_follow_other_pod=""
  local peer_fqdn peer_role peer_master_host peer_master_port
  for peer_fqdn in $(split "$REDIS_POD_FQDN_LIST" ","); do
    if [[ "$peer_fqdn" == "$CURRENT_POD_NAME".* ]]; then
      continue
    fi
    read -r peer_role peer_master_host peer_master_port <<< "$(get_peer_replication_role "$peer_fqdn")"
    echo "pod $peer_fqdn replication role: ${peer_role:-unreachable}${peer_master_host:+ of $peer_master_host}"
    case "$peer_role" in
      master)
        if ! is_empty "$live_primary_fqdn"; then
          live_primary_error="both $live_primary_fqdn and $peer_fqdn run as master"
          return 1
        fi
        live_primary_fqdn="$peer_fqdn"
        ;;
      slave)
        if peer_replicates_from_current_pod "$peer_master_host" "$peer_master_port"; then
          peers_follow_current_pod="${peers_follow_current_pod:+$peers_follow_current_pod }$peer_fqdn"
        else
          peers_follow_other_pod="${peers_follow_other_pod:+$peers_follow_other_pod }$peer_fqdn"
        fi
        ;;
      "") ;;
      *)
        live_primary_error="pod $peer_fqdn is reachable but its role is unknown"
        return 1
        ;;
    esac
  done
  return 0
}

# Whether a replica's master_host and master_port name this pod, by any of the
# addresses check_current_pod_is_primary recognises. Behind a NodePort the
# replica may still name the node this pod ran on before a restart moved it,
# so there the port alone decides: each pod has its own NodePort.
# In host network mode every pod shares the port, so a node address names
# whichever pod ran on that node, and replicas of any of them share its
# replication ID: only the pod's own names count, and replicas following a
# node address make the start fail closed for an operator to choose.
peer_replicates_from_current_pod() {
  local primary="$1" primary_port="$2"
  if is_empty "$primary" || is_empty "$primary_port"; then
    return 1
  fi
  if equals "$redis_announce_via_nodeport" "true" && equals "$primary_port" "$redis_announce_port_value"; then
    return 0
  fi
  if is_host_network_announce; then
    if contains "$primary" "$CURRENT_POD_NAME.$REDIS_COMPONENT_NAME"; then
      return 0
    fi
    ! is_empty "$ANNOUNCE_HOSTNAME_OVERRIDE" &&
      equals "$primary" "$(get_announce_hostname_override_or_default "" "$CURRENT_POD_NAME")"
    return
  fi
  check_current_pod_is_primary >/dev/null
}

is_host_network_announce() {
  ! is_empty "$REDIS_HOST_NETWORK_PORT" && is_empty "$REDIS_ADVERTISED_PORT"
}

# Prints master, or slave followed by its master_host and master_port, nothing
# when the pod cannot be reached, and unknown when it answers without a role (an
# error reply such as NOAUTH) or as a replica without both of them.
# Every pod listens on $service_port: in host network mode it is the one port
# KubeBlocks allocates for the component (REDIS_HOST_NETWORK_PORT), as
# get_default_initialize_primary_node also assumes.
get_peer_replication_role() {
  local peer_fqdn="$1"
  local output
  unset_xtrace_when_ut_mode_false
  if is_empty "$REDIS_DEFAULT_PASSWORD"; then
    output=$(timeout 5 redis-cli $REDIS_CLI_TLS_CMD -h "$peer_fqdn" -p "$service_port" info replication 2>/dev/null)
  else
    output=$(timeout 5 redis-cli $REDIS_CLI_TLS_CMD -h "$peer_fqdn" -p "$service_port" -a "$REDIS_DEFAULT_PASSWORD" --no-auth-warning info replication 2>/dev/null)
  fi
  local exit_code=$?
  set_xtrace_when_ut_mode_false
  if [ $exit_code -ne 0 ] && is_empty "$output"; then
    return 0
  fi
  case "$output" in
    *role:master*) echo "master" ;;
    *role:slave*)
      local master_host master_port
      master_host=$(echo "$output" | sed -n 's/^master_host:\([^[:space:]]*\).*/\1/p' | head -n 1)
      master_port=$(echo "$output" | sed -n 's/^master_port:\([0-9]*\).*/\1/p' | head -n 1)
      if is_empty "$master_host" || is_empty "$master_port"; then
        echo "unknown"
      else
        echo "slave $master_host $master_port"
      fi
      ;;
    *) echo "unknown" ;;
  esac
}

# Returns 0 and sets persisted_data_entry when $redis_data_dir holds anything
# other than the files this addon writes before the server ever runs. Anything
# unknown counts as data so that the check fails closed: dump.rdb, the AOF dir,
# a restored backup, or a half-finished restore (.kb-data-protection, .restore_keys).
redis_data_dir_has_persisted_data() {
  persisted_data_entry=""
  [ -e "$redis_data_dir" ] || [ -L "$redis_data_dir" ] || return 1
  # a dir that cannot be listed would glob to nothing and look empty
  if [ ! -d "$redis_data_dir" ] || [ ! -r "$redis_data_dir" ] || [ ! -x "$redis_data_dir" ]; then
    persisted_data_entry="$redis_data_dir is not a listable directory"
    return 0
  fi
  local entry
  for entry in "$redis_data_dir"/* "$redis_data_dir"/.[!.]* "$redis_data_dir"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    case "${entry##*/}" in
      # ACL file rebuilt on every start, and its sed temp file
      users.acl|users.acl.bak) ;;
      # marker written by build_announce_ip_and_port
      .fixed_pod_ip_enabled) ;;
      # created by mkfs at the root of a fresh ext* volume
      lost+found) ;;
      *)
        persisted_data_entry="${entry##*/}"
        return 0
        ;;
    esac
  done
  return 1
}

build_sentinel_get_master_addr_by_name_command() {
  local sentinel_pod_fqdn="$1"
  local timeout_value=5
  sentinel_service_port=${SENTINEL_SERVICE_PORT:-26379}
  # TODO: replace $SENTINEL_SERVICE_PORT with each sentinel pod's port when sentinel service port is not the same, for example in HostNetwork mode
  if is_empty "$SENTINEL_PASSWORD"; then
    echo "timeout $timeout_value redis-cli $REDIS_CLI_TLS_CMD -h $sentinel_pod_fqdn -p $sentinel_service_port sentinel get-master-addr-by-name $REDIS_COMPONENT_NAME"
  else
    echo "timeout $timeout_value redis-cli $REDIS_CLI_TLS_CMD -h $sentinel_pod_fqdn -p $sentinel_service_port -a $SENTINEL_PASSWORD sentinel get-master-addr-by-name $REDIS_COMPONENT_NAME"
  fi
}

get_master_addr_by_name_from_sentinel() {
  local master_addr_by_name_command
  local sentinel_pod_fqdn="$1"
  REDIS_SENTINEL_MONITORS_NO_PRIMARY="false"
  unset_xtrace_when_ut_mode_false
  master_addr_by_name_command=$(build_sentinel_get_master_addr_by_name_command "$sentinel_pod_fqdn")
  logging_mask_password_command="${master_addr_by_name_command/$SENTINEL_PASSWORD/********}"
  echo "execute get-master-addr-by-name command: $logging_mask_password_command"
  output=$(eval "$master_addr_by_name_command")
  exit_code=$?
  set_xtrace_when_ut_mode_false

  if [ $exit_code -eq 0 ]; then
    read -r -d '' -a REDIS_SENTINEL_PRIMARY_INFO <<< "$output"
    if [ "${#REDIS_SENTINEL_PRIMARY_INFO[@]}" -eq 2 ] && [ -n "${REDIS_SENTINEL_PRIMARY_INFO[0]}" ] && [ -n "${REDIS_SENTINEL_PRIMARY_INFO[1]}" ]; then
      echo "Successfully retrieved primary info from sentinel"
      return 0
    else
      # a master the sentinel does not monitor is a nil reply, printed as an empty line
      if [ -z "${output//[[:space:]]/}" ] || [ "$output" == "(nil)" ]; then
        REDIS_SENTINEL_MONITORS_NO_PRIMARY="true"
      fi
      echo "Empty primary info retrieved from sentinel"
      return 1
    fi
  else
    if [ $exit_code -eq 124 ]; then
      echo "Timeout occurred while retrieving primary info from sentinel. Retrying..."
    else
      echo "Error occurred while retrieving primary info from sentinel. Retrying..."
    fi
    return 1
  fi
}

retry_get_master_addr_by_name_from_sentinel() {
  local max_retry="$1"
  local retry_delay="$2"
  local sentinel_pod_fqdn="$3"
  if call_func_with_retry "$max_retry" "$retry_delay" get_master_addr_by_name_from_sentinel "$sentinel_pod_fqdn"; then
    return 0
  else
    echo "Failed to retrieve primary info from sentinel: $sentinel_pod_fqdn after $max_retry retries."
    return 1
  fi
}

get_default_initialize_primary_node() {
  # TODO: if has advertise svc and port, we should use it as default primary node info instead of the fqdn
  min_lex_pod=$(min_lexicographical_order_pod "$REDIS_POD_NAME_LIST")
  min_lex_pod_fqdn=$(get_target_pod_fqdn_from_pod_fqdn_vars "$REDIS_POD_FQDN_LIST" "$min_lex_pod")
  if is_empty "$min_lex_pod_fqdn"; then
    echo "Error: Failed to get min lexicographical order pod: $CURRENT_POD_NAME fqdn from redis pod fqdn list: $REDIS_POD_FQDN_LIST. Exiting."
    exit 1
  fi
  echo "get the minimum lexicographical order pod name: $min_lex_pod_fqdn as default primary node"
  primary="$min_lex_pod_fqdn"
  primary_port=$service_port
}

check_current_pod_is_primary() {
  current_pod_fqdn_prefix="$CURRENT_POD_NAME.$REDIS_COMPONENT_NAME"
  if contains "$primary" "$current_pod_fqdn_prefix"; then
    echo "current pod is primary with name mapping, primary node: $primary, pod fqdn prefix:$current_pod_fqdn_prefix"
    return 0
  fi

  # When an announce hostname override is in use, the primary is registered with
  # sentinel under that name, which shares nothing with the in-cluster fqdn the
  # check above looks for. Without this the primary fails to recognise itself and
  # makes itself a replica of its own address.
  if ! is_empty "$ANNOUNCE_HOSTNAME_OVERRIDE"; then
    current_pod_announce_hostname=$(get_announce_hostname_override_or_default "" "$CURRENT_POD_NAME")
    if equals "$primary" "$current_pod_announce_hostname"; then
      echo "current pod is primary with announce hostname mapping, primary node: $primary"
      return 0
    fi
  fi

  if ! is_empty "$redis_announce_host_value" && ! is_empty "$redis_announce_port_value"; then
    if equals "$primary" "$redis_announce_host_value" && equals "$primary_port" "$redis_announce_port_value"; then
      echo "current pod is primary with advertised svc mapping, primary: $primary, primary port: $primary_port, advertised ip:$redis_announce_host_value, advertised port:$redis_announce_port_value"
      return 0
    fi
    echo "redis advertised svc host and port exist but not match, primary: $primary, primary port: $primary_port, advertised ip:$redis_announce_host_value, advertised port:$redis_announce_port_value"
  fi

  if equals "$primary" "$CURRENT_POD_IP" && equals "$primary_port" "$service_port"; then
    echo "current pod is primary with pod ip mapping, primary node: $primary, pod ip:$CURRENT_POD_IP, service port:$service_port"
    return 0
  fi
  return 1
}

build_redis_server_start_cmd() {
  local module_path="${1:-/var/lib/falkordb/bin}"
  local extra_module_args="${FALKORDB_EXTRA_MODULES_ARGS:-}"
  local exec_cmd="redis-server /etc/redis/redis.conf"
  if [ -f "${module_path}/falkordb.so" ]; then
    exec_cmd="$exec_cmd --loadmodule ${module_path}/falkordb.so ${FALKORDB_ARGS} ${extra_module_args}"
  fi
  echo "$exec_cmd"
}

start_redis_server() {
  local exec_cmd
  exec_cmd=$(build_redis_server_start_cmd)
  echo "Starting falkordb server cmd: $exec_cmd"
  # Each server line is tagged "[falkordb] ", replacing redis's own pid/role/timestamp
  # prefix when present. Trailing carriage returns are dropped: `script` runs the
  # server on a pty, which turns every "\n" into "\r\n" (and the INFO section of a
  # crash report, already "\r\n", into "\r\r\n"), leaving stray ^M in the logs.
  local log_format='s/\r+$//; s/^[0-9]+:[A-Z] [0-9]+ [A-Za-z]{3} [0-9]{4} [0-9:.]+ //; s/^/[falkordb] /'
  local log_pid server_status=0
  exec 3> >(sed -u -E "$log_format")
  log_pid=$!
  # This script is the container's PID 1, which ignores SIGTERM unless it traps
  # it, so the server runs in the background and the signal is passed on to it:
  # it shuts down cleanly (and fast) instead of being killed at the end of the
  # grace period. `script` would kill it, so it is signalled directly, and the
  # command is exec'd so the server is the child of `script`, not of a shell.
  # The traps go in first: a signal that comes before the server is running is
  # kept and passed on once it is.
  pending_server_signal=""
  trap 'handle_shutdown_signal TERM' TERM
  trap 'handle_shutdown_signal INT' INT
  if command -v script >/dev/null 2>&1; then
    script -q -f -e -c "exec $exec_cmd" /dev/null >&3 2>&1 &
  else
    eval "exec $exec_cmd" >&3 2>&1 &
  fi
  redis_server_launcher_pid=$!
  # wait returns early when a trapped signal arrives; wait again until the
  # server has exited, then once more for its status.
  while kill -0 "$redis_server_launcher_pid" 2>/dev/null; do
    if ! is_empty "$pending_server_signal"; then
      if forward_signal_to_redis_server "$pending_server_signal"; then
        pending_server_signal=""
      else
        sleep 0.1
        continue
      fi
    fi
    wait "$redis_server_launcher_pid" || true
  done
  wait "$redis_server_launcher_pid" || server_status=$?
  # let sed print the server's last lines before the container exits
  exec 3>&-
  wait "$log_pid" || true
  # Propagate the server's own status so the container exits non-zero after a
  # crash and kubelet records the failure and restarts it.
  echo "falkordb server exited with status $server_status"
  return "$server_status"
}

handle_shutdown_signal() {
  if ! forward_signal_to_redis_server "$1"; then
    echo "falkordb server is not running yet, passing SIG$1 on once it is"
    pending_server_signal="$1"
  fi
}

# Sends the signal to the server started by start_redis_server: the launcher
# itself when it exec'd the server, or its child when `script` runs it on a pty.
# The image has no ps or pkill, so the process is found in /proc. Returns 1
# when there is no such server (yet).
forward_signal_to_redis_server() {
  local signal="$1" proc pid stat ppid found=1
  is_empty "$redis_server_launcher_pid" && return 1
  for proc in "$proc_root"/[0-9]*; do
    [ "$(cat "$proc/comm" 2>/dev/null)" = "$redis_server_process_name" ] || continue
    read -r stat < "$proc/stat" 2>/dev/null || continue
    # the fields after the parenthesised command name are: state ppid ...
    stat=${stat##*) }
    read -r _ ppid _ <<< "$stat"
    pid=${proc##*/}
    if [ "$pid" = "$redis_server_launcher_pid" ] || [ "$ppid" = "$redis_server_launcher_pid" ]; then
      echo "forwarding SIG$signal to falkordb server (pid $pid)"
      kill -"$signal" "$pid" && found=0
    fi
  done
  return $found
}

# TODO: if instanceTemplate is specified, the pod service could not be parsed from the pod ordinal.
parse_redis_announce_addr() {
  if is_empty "$REDIS_ADVERTISED_PORT"; then
     REDIS_ADVERTISED_PORT="$REDIS_LB_ADVERTISED_PORT"
  fi
  # try to get the announce ip and port from REDIS_ADVERTISED_PORT(support NodePort currently) first
  if is_empty "${REDIS_ADVERTISED_PORT}"; then
    echo "Environment variable REDIS_ADVERTISED_PORT not found. Ignoring."
    # if redis is in host network mode, use the host ip and port as the announce ip and port
    if ! is_empty "${REDIS_HOST_NETWORK_PORT}"; then
      echo "redis is in host network mode, use the host ip:$CURRENT_POD_HOST_IP and port:$REDIS_HOST_NETWORK_PORT as the announce ip and port."
      redis_announce_port_value="$REDIS_HOST_NETWORK_PORT"
      redis_announce_host_value="$CURRENT_POD_HOST_IP"
    fi
    return 0
  fi

  local pod_name="$1"
  local found=false
  pod_name_ordinal=$(extract_obj_ordinal "$pod_name")
  # the value format of REDIS_ADVERTISED_PORT is "pod1Svc:advertisedPort1,pod2Svc:advertisedPort2,..."
  advertised_ports=($(split "$REDIS_ADVERTISED_PORT" ","))
  for advertised_port in "${advertised_ports[@]}"; do
    parts=($(split "$advertised_port" ":"))
    local svc_name="${parts[0]}"
    local port="${parts[1]}"
    svc_name_ordinal=$(extract_obj_ordinal "$svc_name")
    if [[ "$svc_name_ordinal" == "$pod_name_ordinal" ]]; then
      echo "Found matching svcName and port for podName '$pod_name', REDIS_ADVERTISED_PORT: $REDIS_ADVERTISED_PORT. svcName: $svc_name, port: $port."
      redis_announce_port_value="$port"
      lb_host=$(extract_lb_host_by_svc_name "$svc_name")
      if [ -n "$lb_host" ]; then
        echo "Found load balancer host for svcName '$svc_name', value is '$lb_host'."
        redis_announce_host_value="$lb_host"
        redis_announce_port_value="${SERVICE_PORT:-6379}"
      else
        redis_announce_host_value="$CURRENT_POD_HOST_IP"
        redis_announce_via_nodeport="true"
      fi
      found=true
      break
    fi
  done

  if equals "$found" false; then
    echo "Error: No matching svcName and port found for podName '$pod_name', REDIS_ADVERTISED_PORT: $REDIS_ADVERTISED_PORT. Exiting."
    exit 1
  fi
}

# build redis.conf
build_redis_conf() {
  load_redis_template_conf
  build_announce_ip_and_port
  build_redis_service_port
  build_redis_tls_config
  build_replicaof_config
  rebuild_redis_acl_file
  build_redis_default_accounts
  add_extra_falkordb_user_account
}

# This is magic for shellspec ut framework.
# Sometime, functions are defined in a single shell script.
# You will want to test it. but you do not want to run the script.
# When included from shellspec, __SOURCED__ variable defined and script
# end here. The script path is assigned to the __SOURCED__ variable.
${__SOURCED__:+false} : || return 0

# main
load_common_library
parse_redis_announce_addr "$CURRENT_POD_NAME"
build_redis_conf
start_redis_server

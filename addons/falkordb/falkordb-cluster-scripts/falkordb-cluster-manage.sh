#!/bin/sh

# shellcheck disable=SC2128
# shellcheck disable=SC2207
# shellcheck disable=SC1090

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
  # when running in non-unit test mode, set the options "set -ex".
  set -ex;
}

# Helper functions for TAB-separated key-value temp file maps
_map_get() { awk -F'\t' -v k="$2" '$1==k{print $2; exit}' "$1"; }
_map_keys() { awk -F'\t' 'NF>0{print $1}' "$1"; }
_map_append() { printf '%s\t%s\n' "$2" "$3" >> "$1"; }
_map_size() { [ -s "$1" ] && grep -c '' "$1" || printf '0'; }

# Temp files for associative maps (initialized in init_cluster_map_files)
_initialize_redis_cluster_primary_nodes=""
_initialize_redis_cluster_secondary_nodes=""
_initialize_pod_name_to_advertise_host_port_map=""
_scale_out_shard_default_primary_node=""
_scale_out_shard_default_other_nodes=""

init_cluster_map_files() {
  _initialize_redis_cluster_primary_nodes=$(mktemp)
  _initialize_redis_cluster_secondary_nodes=$(mktemp)
  _initialize_pod_name_to_advertise_host_port_map=$(mktemp)
  _scale_out_shard_default_primary_node=$(mktemp)
  _scale_out_shard_default_other_nodes=$(mktemp)
}

init_environment(){
  if [ -z "${CURRENT_SHARD_ADVERTISED_PORT}" ]; then
    CURRENT_SHARD_ADVERTISED_PORT="${CURRENT_SHARD_LB_ADVERTISED_PORT}"
  fi
  if [ -z "${CURRENT_SHARD_ADVERTISED_BUS_PORT}" ]; then
    CURRENT_SHARD_ADVERTISED_BUS_PORT="${CURRENT_SHARD_LB_ADVERTISED_BUS_PORT}"
  fi
  if [ -z "${ALL_SHARDS_ADVERTISED_PORT}" ]; then
    ALL_SHARDS_ADVERTISED_PORT="${ALL_SHARDS_LB_ADVERTISED_PORT}"
  fi
  if [ -z "${ALL_SHARDS_ADVERTISED_BUS_PORT}" ]; then
    ALL_SHARDS_ADVERTISED_BUS_PORT="${ALL_SHARDS_LB_ADVERTISED_BUS_PORT}"
  fi
}

load_redis_cluster_common_utils() {
  # the common.sh and falkordb-cluster-common.sh scripts are defined in the falkordb-cluster-scripts-template configmap
  # and are mounted to the same path which defined in the cmpd.spec.scripts
  kblib_common_library_file="/scripts/common.sh"
  redis_cluster_common_library_file="/scripts/falkordb-cluster-common.sh"
  . "${kblib_common_library_file}"
  . "${redis_cluster_common_library_file}"
}
call_func_with_retry_when_ut_mode_false() {
  local max_retries="$1"
  local retry_interval="$2"
  local function_name="$3"
  shift 3

  local retries=0
  while true; do
    if "$function_name" "$@"; then
      return 0
    fi

    retries=$((retries + 1))
    if [ "$retries" -ge "$max_retries" ]; then
      echo "Function '$function_name' failed after $max_retries retries." >&2
      return 1
    fi

    echo "Function '$function_name' failed in $retries times. Retrying in $retry_interval seconds..." >&2
    if [ "$retry_interval" -gt 0 ] 2>/dev/null; then
      sleep_when_ut_mode_false "$retry_interval"
    fi
  done
}

check_initialize_nodes_ready() {
  # $1 is a pipe-separated list of host:port nodes
  for node in $(printf '%s' "$1" | tr '|' '\n'); do
    local host port
    host=$(echo "$node" | cut -d':' -f1)
    port=$(echo "$node" | cut -d':' -f2)
    if ! check_redis_server_ready_with_retry "$host" "$port"; then
      return 1
    fi
  done
  return 0
}

# initialize the other component and pods info
init_other_components_and_pods_info() {
  local current_component="$1"
  local all_pod_ip_list="$2"
  local all_pod_name_list="$3"
  local all_component_list="$4"
  local all_deleting_component_list="$5"
  local all_undeleted_component_list="$6"

  other_components=""
  other_deleting_components=""
  other_undeleted_components=""
  other_undeleted_component_pod_ips=""
  other_undeleted_component_pod_names=""
  other_undeleted_component_nodes=""
  echo "init other components and pods info, current component: $current_component"
  # filter out the components of the given component
  for comp in $(printf '%s\n' "$all_component_list" | tr ',' ' '); do
    if contains "$comp" "$current_component"; then
      echo "skip the component $comp as it is the current component"
      continue
    fi
    other_components="${other_components:+${other_components}|}${comp}"
  done
  for comp in $(printf '%s\n' "$all_deleting_component_list" | tr ',' ' '); do
    if contains "$comp" "$current_component"; then
      echo "skip the component $comp as it is the current component"
      continue
    fi
    other_deleting_components="${other_deleting_components:+${other_deleting_components}|}${comp}"
  done
  for comp in $(printf '%s\n' "$all_undeleted_component_list" | tr ',' ' '); do
    if contains "$comp" "$current_component"; then
      echo "skip the component $comp as it is the current component"
      continue
    fi
    other_undeleted_components="${other_undeleted_components:+${other_undeleted_components}|}${comp}"
  done

  # filter out pods of the given component using parallel iteration via temp files
  _tmp_names=$(mktemp)
  _tmp_ips=$(mktemp)
  _tmp_paste=$(mktemp)
  printf '%s\n' "$all_pod_name_list" | tr ',' '\n' > "$_tmp_names"
  printf '%s\n' "$all_pod_ip_list" | tr ',' '\n' > "$_tmp_ips"
  paste "$_tmp_names" "$_tmp_ips" > "$_tmp_paste"
  rm -f "$_tmp_names" "$_tmp_ips"

  while IFS="$(printf '\t')" read -r _pod_name _pod_ip; do
    [ -z "$_pod_name" ] && continue
    if echo "$_pod_name" | grep -q "$current_component-"; then
      echo "skip the pod $_pod_name as it belongs the component $current_component"
      continue
    fi

    # skip the pod belongs to the deleting component
    _skip=false
    for _deleting_comp in $(printf '%s' "$other_deleting_components" | tr '|' '\n'); do
      if echo "$_pod_name" | grep -q "$_deleting_comp-"; then
        echo "skip the pod $_pod_name as it belongs the deleting component $_deleting_comp"
        _skip=true
        break
      fi
    done
    [ "$_skip" = "true" ] && continue

    other_undeleted_component_pod_ips="${other_undeleted_component_pod_ips:+${other_undeleted_component_pod_ips}|}${_pod_ip}"
    other_undeleted_component_pod_names="${other_undeleted_component_pod_names:+${other_undeleted_component_pod_names}|}${_pod_name}"

    local service_port
    service_port=$(get_pod_service_port_by_network_mode "$_pod_name")

    # TODO: resolve the pod fqdn from the Vars
    pod_name_prefix=$(extract_pod_name_prefix "$_pod_name")
    pod_fqdn="$_pod_name.$pod_name_prefix-headless.$CLUSTER_NAMESPACE.svc.$CLUSTER_DOMAIN"
    other_undeleted_component_nodes="${other_undeleted_component_nodes:+${other_undeleted_component_nodes}|}${pod_fqdn}:${service_port}"
  done < "$_tmp_paste"
  rm -f "$_tmp_paste"

  echo "other_components: $(printf '%s' "${other_components}" | tr '|' ' ')"
  echo "other_deleting_components: $(printf '%s' "${other_deleting_components}" | tr '|' ' ')"
  echo "other_undeleted_components: $(printf '%s' "${other_undeleted_components}" | tr '|' ' ')"
  echo "other_undeleted_component_pod_ips: $(printf '%s' "${other_undeleted_component_pod_ips}" | tr '|' ' ')"
  echo "other_undeleted_component_pod_names: $(printf '%s' "${other_undeleted_component_pod_names}" | tr '|' ' ')"
  echo "other_undeleted_component_nodes: $(printf '%s' "${other_undeleted_component_nodes}" | tr '|' ' ')"
}

find_exist_available_node() {
  local node_ip
  local node_port
  for node in $(printf '%s' "$other_undeleted_component_nodes" | tr '|' '\n'); do
    # the $node is the headless address by default, we should get the real node address from cluster nodes
    node_ip=$(echo "$node" | cut -d':' -f1)
    node_port=$(echo "$node" | cut -d':' -f2)
    if check_slots_covered "$node" "$node_port"; then
      # the $node is the headless address by default, we should get the real node address from cluster nodes
      cluster_nodes_info=$(get_cluster_nodes_info "$node_ip" "$node_port")
      status=$?
      if [ $status -ne 0 ]; then
        echo "Failed to get cluster nodes info in find_exist_available_node" >&2
        return 1
      fi
      # grep my self node and return the nodeIp:port(it may be the announceIp and announcePort, for example when cluster enable NodePort/LoadBalancer service)
      available_node_with_port=$(echo "$cluster_nodes_info" | grep "myself" | awk '{print $2}' | cut -d'@' -f1)
      echo "$available_node_with_port"
      return
    fi
  done
  echo ""
}

extract_pod_name_prefix() {
  local pod_name="$1"
  # shellcheck disable=SC2001
  prefix=$(echo "$pod_name" | sed 's/-[0-9]*$//')
  echo "$prefix"
}

extract_lb_host_by_svc_name() {
  local svc_name="$1"
  for _lbcn in $(printf '%s\n' "$ALL_SHARDS_LB_ADVERTISED_HOST" | tr ',' ' '); do
    lb_composed_name="${_lbcn#*@}"
    case "$lb_composed_name" in
      *:*)
        if [ "${lb_composed_name%:*}" = "$svc_name" ]; then
          echo "${lb_composed_name#*:}"
          break
        fi
        ;;
      *)
        break
        ;;
    esac
  done
}

# get the current component primary node and other nodes for scale in
get_current_comp_nodes_for_scale_in() {

  parse_node_line_info() {
    local line="$1"

    local node_ip_port_fields
    # 10.42.0.227:6379@16379,falkordb-shard-sxj-0.falkordb-shard-sxj-headless.default.svc.cluster.local
    node_ip_port_fields=$(echo "$line" | awk '{print $2}')

    local node_ip_port
    # ip:port without bus port
    node_ip_port=$(echo "$node_ip_port_fields" | awk -F '@' '{print $1}')

    local node_ip
    node_ip=$(echo "$node_ip_port" | cut -d':' -f1)

    local node_port
    node_port=$(echo "$node_ip_port" | cut -d':' -f2)

    local node_fqdn
    # falkordb-shard-sxj-0.falkordb-shard-sxj-headless.default.svc
    node_fqdn=$(echo "$line" | awk '{print $2}' | awk -F ',' '{print $2}')

    local node_role
    node_role=$(echo "$line" | awk '{print $3}')

    echo "$node_ip $node_port $node_fqdn $node_role"
  }

  get_node_address_by_network_mode() {
    local network_mode="$1"
    local node_ip="$2"
    local node_port="$3"
    local node_fqdn="$4"

    case "$network_mode" in
      "advertised_svc")
        echo "$node_ip:$node_port"
        ;;
      "host_network")
        echo "$node_ip:$REDIS_CLUSTER_HOST_NETWORK_PORT"
        ;;
      *)
        # shellcheck disable=SC2153
        echo "$node_fqdn:$SERVICE_PORT"
        ;;
    esac
  }

  categorize_node() {
    local node_address="$1"
    local node_fqdn="$2"
    local node_role="$3"

    case "$node_fqdn" in
      "$CURRENT_SHARD_COMPONENT_NAME"*)
        if contains "$node_role" "master" && ! contains "$node_role" "fail"; then
          current_comp_primary_node="${current_comp_primary_node:+${current_comp_primary_node}|}${node_address}"
        else
          current_comp_other_nodes="${current_comp_other_nodes:+${current_comp_other_nodes}|}${node_address}"
        fi
        ;;
    esac
  }

  local cluster_node="$1"
  local cluster_node_port="$2"
  cluster_nodes_info=$(get_cluster_nodes_info "$cluster_node" "$cluster_node_port")
  status=$?
  if [ $status -ne 0 ]; then
    echo "Failed to get cluster nodes info in get_current_comp_nodes_for_scale_in" >&2
    return 1
  fi

  current_comp_primary_node=""
  current_comp_other_nodes=""

  # if the cluster_nodes_info contains only one line, it means that the cluster not be initialized
  if [ "$(echo "$cluster_nodes_info" | wc -l)" -eq 1 ]; then
    echo "Cluster nodes info contains only one line, returning..."
    return
  fi

  # determine network mode
  local network_mode="default"
  if ! is_empty "$CURRENT_SHARD_ADVERTISED_PORT"; then
    network_mode="advertised_svc"
  elif ! is_empty "$REDIS_CLUSTER_HOST_NETWORK_PORT"; then
    network_mode="host_network"
  fi

  # the output of line is like:
  # 1. using the pod fqdn as the nodeAddr
  # 4958e6dca033cd1b321922508553fab869a29d 10.42.0.227:6379@16379,falkordb-shard-sxj-0.falkordb-shard-sxj-headless.default.svc.cluster.local master - 0 1711958289570 4 connected 0-1364 5461-6826 10923-12287
  # 2. using the nodeport or lb ip as the nodeAddr
  # 4958e6dca033cd1b321922508553fab869a29d 172.10.0.1:31000@31888,falkordb-shard-sxj-0.falkordb-shard-sxj-headless.default.svc.cluster.local master master - 0 1711958289570 4 connected 0-1364 5461-6826 10923-12287
  # 3. using the host network ip as the nodeAddr
  # 4958e6dca033cd1b321922508553fab869a29d 172.10.0.1:1050@1051,falkordb-shard-sxj-0.falkordb-shard-sxj-headless.default.svc.cluster.local master - 0 1711958289570 4 connected 0-1364 5461-6826 10923-12287
  while read -r line; do
    node_info=$(parse_node_line_info "$line")
    node_ip=$(printf '%s' "$node_info" | cut -d' ' -f1)
    node_port=$(printf '%s' "$node_info" | cut -d' ' -f2)
    node_fqdn=$(printf '%s' "$node_info" | cut -d' ' -f3)
    node_role=$(printf '%s' "$node_info" | cut -d' ' -f4)

    node_address=$(get_node_address_by_network_mode "$network_mode" "$node_ip" "$node_port" "$node_fqdn")
    categorize_node "$node_address" "$node_fqdn" "$node_role"
  done << _NODES_EOF_
$cluster_nodes_info
_NODES_EOF_

  echo "current_comp_primary_node: ${current_comp_primary_node}"
  echo "current_comp_other_nodes: ${current_comp_other_nodes}"
}

# init the current shard component default primary and secondary nodes for scale out shard.
# TODO: if advertised address is enable and instanceTemplate is specified, the pod service could not be parsed from the pod ordinal.
# TODO: remove the dependency of the built-in envs like KB_CLUSTER_COMPONENT_XXXX
init_current_comp_default_nodes_for_scale_out() {
  # categorize the scale out node map
  categorize_scale_out_node_map() {
    local pod_name="$1"
    local node_address="$2"
    local pod_ordinal="$3"

    if equals "$pod_ordinal" "$min_lexicographical_pod_ordinal"; then
      _map_append "$_scale_out_shard_default_primary_node" "$pod_name" "$node_address"
    else
      _map_append "$_scale_out_shard_default_other_nodes" "$pod_name" "$node_address"
    fi
  }

  # handle the advertised service network mode (currently only support NodePort service type
  handle_advertised_svc_network_mode() {
    local pod_name="$1"
    local pod_name_ordinal="$2"

    local found_advertised_port=false
    for advertised_info in $(printf '%s\n' "$CURRENT_SHARD_ADVERTISED_PORT" | tr ',' ' '); do
      local advertised_svc advertised_port advertised_svc_ordinal
      advertised_svc=$(echo "$advertised_info" | cut -d':' -f1)
      advertised_port=$(echo "$advertised_info" | cut -d':' -f2)
      advertised_svc_ordinal=$(extract_obj_ordinal "$advertised_svc")

      if [ "$pod_name_ordinal" = "$advertised_svc_ordinal" ]; then
        local pod_host_ip
        lb_host=$(extract_lb_host_by_svc_name "${advertised_svc}")
        if ! is_empty "$lb_host"; then
            echo "Found load balancer host for svcName '$advertised_svc', value is '$lb_host'."
            pod_host_ip="$lb_host"
            advertised_port="${SERVICE_PORT:-6379}"
        else
            pod_host_ip=$(parse_host_ip_from_built_in_envs "$pod_name" "$KB_CLUSTER_COMPONENT_POD_NAME_LIST" "$KB_CLUSTER_COMPONENT_POD_HOST_IP_LIST")
        fi
        status=$?
        if is_empty "$pod_host_ip" || [ $status -ne 0 ]; then
          echo "Failed to get host ip of pod $pod_name" >&2
          return 1
        fi

        categorize_scale_out_node_map "$pod_name" "$pod_host_ip:$advertised_port" "$pod_name_ordinal"
        found_advertised_port=true
        break
      fi
    done

    if [ "$found_advertised_port" = false ]; then
      echo "Advertised port not found for pod $pod_name" >&2
      return 1
    fi
    return 0
  }

  # handle the host network mode
  handle_host_network_mode() {
    local pod_name="$1"
    local pod_name_ordinal="$2"

    local pod_host_ip
    pod_host_ip=$(parse_host_ip_from_built_in_envs "$pod_name" "$KB_CLUSTER_COMPONENT_POD_NAME_LIST" "$KB_CLUSTER_COMPONENT_POD_HOST_IP_LIST")
    if is_empty "$pod_host_ip"; then
      echo "Failed to get host ip of pod $pod_name in host network mode" >&2
      return 1
    fi

    categorize_scale_out_node_map "$pod_name" "$pod_host_ip:$REDIS_CLUSTER_HOST_NETWORK_PORT" "$pod_name_ordinal"
    return 0
  }

  # handle the default network mode
  handle_default_network_mode() {
    local pod_name="$1"
    local pod_name_ordinal="$2"

    local pod_fqdn
    local port="$SERVICE_PORT"

    pod_fqdn=$(get_target_pod_fqdn_from_pod_fqdn_vars "$CURRENT_SHARD_POD_FQDN_LIST" "$pod_name")
    if is_empty "$pod_fqdn"; then
      echo "Error: Failed to get pod $pod_name fqdn from list: $CURRENT_SHARD_POD_FQDN_LIST" >&2
      return 1
    fi

    categorize_scale_out_node_map "$pod_name" "$pod_fqdn:$port" "$pod_name_ordinal"
    return 0
  }

  process_pod_by_network_mode() {
    local network_mode="$1"
    local pod_name="$2"
    local pod_name_ordinal="$3"

    case "$network_mode" in
      "advertised_svc")
        handle_advertised_svc_network_mode "$pod_name" "$pod_name_ordinal"
        ;;
      "host_network")
        handle_host_network_mode "$pod_name" "$pod_name_ordinal"
        ;;
      *)
        handle_default_network_mode "$pod_name" "$pod_name_ordinal"
        ;;
    esac
    return $?
  }

  local min_lexicographical_pod_name
  local min_lexicographical_pod_ordinal
  min_lexicographical_pod_name=$(min_lexicographical_order_pod "$KB_CLUSTER_COMPONENT_POD_NAME_LIST")
  min_lexicographical_pod_ordinal=$(extract_obj_ordinal "$min_lexicographical_pod_name")
  if is_empty "$min_lexicographical_pod_ordinal"; then
    echo "Failed to get the ordinal of the min lexicographical pod $min_lexicographical_pod_name in init_current_comp_default_nodes_for_scale_out" >&2
    return 1
  fi

  # determine network mode
  local network_mode="default"
  if ! is_empty "$CURRENT_SHARD_ADVERTISED_PORT"; then
    network_mode="advertised_svc"
  elif ! is_empty "$REDIS_CLUSTER_HOST_NETWORK_PORT"; then
    network_mode="host_network"
  fi

  for pod_name in $(echo "$KB_CLUSTER_COMPONENT_POD_NAME_LIST" | tr ',' ' '); do
    local pod_name_ordinal
    pod_name_ordinal=$(extract_obj_ordinal "$pod_name")
    process_pod_by_network_mode "$network_mode" "$pod_name" "$pod_name_ordinal" || return 1
  done
  return 0
}

# initialize the redis cluster primary and secondary nodes, use the min lexicographical pod of each shard as the primary nodes by default.
gen_initialize_redis_cluster_node() {
  local is_primary=$1

  categorize_node_maps() {
    local pod_name="$1"
    local host="$2"
    local port="$3"
    local is_primary="$4"

    local node_addr="$host:$port"

    if equals "$is_primary" "true"; then
      _map_append "$_initialize_redis_cluster_primary_nodes" "$pod_name" "$node_addr"
    else
      _map_append "$_initialize_redis_cluster_secondary_nodes" "$pod_name" "$node_addr"
    fi
    _map_append "$_initialize_pod_name_to_advertise_host_port_map" "$pod_name" "$node_addr"
  }

  # determine if pod should be processed based on primary/secondary role
  should_process_pod() {
    local is_primary="$1"
    local pod_ordinal="$2"
    local min_pod_ordinal="$3"

    if [ "$is_primary" = "true" ]; then
      [ "$pod_ordinal" = "$min_pod_ordinal" ]
    else
      [ "$pod_ordinal" != "$min_pod_ordinal" ]
    fi
  }

  # Initialize node with advertised service configuration
  initialize_advertised_svc_node() {
    local pod_name="$1"
    local pod_name_ordinal="$2"
    local is_primary="$3"

    local pod_host_ip
    pod_host_ip=$(parse_host_ip_from_built_in_envs "$pod_name" "$KB_CLUSTER_POD_NAME_LIST" "$KB_CLUSTER_POD_HOST_IP_LIST") || {
      echo "Failed to get host IP for pod: $pod_name" >&2
      return 1
    }

    ## the value format of ALL_SHARDS_ADVERTISED_PORT is "shard-98x@falkordb-shard-98x-falkordb-advertised-0:32024,falkordb-shard-98x-falkordb-advertised-1:31318.shard-cq7@falkordb-shard-cq7-falkordb-advertised-0:31828,falkordb-shard-cq7-falkordb-advertised-1:32000"
    _tmp_shards=$(mktemp)
    printf '%s\n' "$ALL_SHARDS_ADVERTISED_PORT" | tr '.' '\n' > "$_tmp_shards"

    local shard
    while IFS= read -r shard; do
      [ -z "$shard" ] && continue
      local shard_name
      shard_name=$(echo "$shard" | cut -d'@' -f1)

      # skip if pod doesn't belong to current shard
      if ! echo "$pod_name" | grep -q "$shard_name"; then
        continue
      fi

      # shard_advertised_infos like "falkordb-shard-98x-falkordb-advertised-0:32024,falkordb-shard-98x-falkordb-advertised-1:31318"
      local shard_advertised_info
      for shard_advertised_info in $(printf '%s\n' "$shard" | cut -d'@' -f2 | tr ',' ' '); do
        local shard_advertised_svc
        local shard_advertised_port
        local shard_advertised_svc_ordinal

        shard_advertised_svc=$(echo "$shard_advertised_info" | cut -d':' -f1)
        shard_advertised_port=$(echo "$shard_advertised_info" | cut -d':' -f2)
        shard_advertised_svc_ordinal=$(extract_obj_ordinal "$shard_advertised_svc")

        if [ "$pod_name_ordinal" = "$shard_advertised_svc_ordinal" ]; then
          lb_host=$(extract_lb_host_by_svc_name "${shard_advertised_svc}")
          if [ -n "$lb_host" ]; then
            echo "Found load balancer host for svcName '$shard_advertised_svc', value is '$lb_host'."
            pod_host_ip="$lb_host"
            shard_advertised_port="${SERVICE_PORT:-6379}"
          fi
          categorize_node_maps "$pod_name" "$pod_host_ip" "$shard_advertised_port" "$is_primary"
          return 0
        fi
      done
    done < "$_tmp_shards"
    rm -f "$_tmp_shards"
    return 0
  }

  # Initialize node with host network configuration
  initialize_host_network_node() {
    local pod_name="$1"
    local is_primary="$2"

    local pod_host_ip
    pod_host_ip=$(parse_host_ip_from_built_in_envs "$pod_name" "$KB_CLUSTER_POD_NAME_LIST" "$KB_CLUSTER_POD_HOST_IP_LIST") || {
      echo "Failed to get host IP for pod: $pod_name" >&2
      return 1
    }

    local service_port
    service_port=$(get_pod_service_port_by_network_mode "${pod_name}") || {
      echo "Failed to get service port for pod: $pod_name" >&2
      return 1
    }

    categorize_node_maps "$pod_name" "$pod_host_ip" "$service_port" "$is_primary"
    return 0
  }

  # Initialize node with default network configuration
  initialize_default_network_node() {
    local pod_name="$1"
    local is_primary="$2"

    local service_port
    service_port=$(get_pod_service_port_by_network_mode "${pod_name}") || {
      echo "Failed to get service_port for pod: $pod_name" >&2
      return 1
    }

    local all_shard_pod_fqdns
    all_shard_pod_fqdns=$(get_all_shards_pod_fqdns) || {
      echo "Failed to get all shard pod FQDNs" >&2
      return 1
    }

    if is_empty "$all_shard_pod_fqdns"; then
      echo "Failed to get all shard pod FQDNs" >&2
      return 1
    fi

    local pod_fqdn
    pod_fqdn=$(get_target_pod_fqdn_from_pod_fqdn_vars "$all_shard_pod_fqdns" "$pod_name") || {
      echo "Failed to get FQDN for pod: $pod_name" >&2
      return 1
    }

    if is_empty "$pod_fqdn"; then
      echo "Failed to get pod $pod_name fqdn from list: $all_shard_pod_fqdns" >&2
      return 1
    fi

    categorize_node_maps "$pod_name" "$pod_fqdn" "$service_port" "$is_primary"
    return 0
  }

  # determine cluster network mode
  local network_mode="default"
  if ! is_empty "$ALL_SHARDS_ADVERTISED_PORT"; then
    network_mode="advertised_svc"
  elif ! is_empty "$REDIS_CLUSTER_ALL_SHARDS_HOST_NETWORK_PORT"; then
    network_mode="host_network"
  fi

  # get and validate the min lexicographical pod name and ordinal
  local min_lexicographical_pod_name
  local min_lexicographical_pod_ordinal
  min_lexicographical_pod_name=$(min_lexicographical_order_pod "$KB_CLUSTER_POD_NAME_LIST")
  min_lexicographical_pod_ordinal=$(extract_obj_ordinal "$min_lexicographical_pod_name")
  if is_empty "$min_lexicographical_pod_ordinal"; then
    echo "Failed to get the ordinal of the min lexicographical pod $min_lexicographical_pod_name in gen_initialize_redis_cluster_node" >&2
    return 1
  fi

  local pod_name
  for pod_name in $(echo "$KB_CLUSTER_POD_NAME_LIST" | tr ',' ' '); do
    local pod_name_ordinal
    pod_name_ordinal=$(extract_obj_ordinal "$pod_name") || continue

    # skip pods based on primary/secondary role
    if ! should_process_pod "$is_primary" "$pod_name_ordinal" "$min_lexicographical_pod_ordinal"; then
      continue
    fi
    # initialize pod based on network mode
    case "$network_mode" in
      "advertised_svc")
        initialize_advertised_svc_node "$pod_name" "$pod_name_ordinal" "$is_primary" || return 1
        ;;
      "host_network")
        initialize_host_network_node "$pod_name" "$is_primary" || return 1
        ;;
      "default")
        initialize_default_network_node "$pod_name" "$is_primary" || return 1
        ;;
    esac
  done
  return 0
}

gen_initialize_redis_cluster_primary_node() {
  gen_initialize_redis_cluster_node "true"
}

gen_initialize_redis_cluster_secondary_nodes() {
  gen_initialize_redis_cluster_node "false"
}

populate_pod_ip_name_list() {
  # This function populates KB_CLUSTER_POD_IP_LIST and KB_CLUSTER_POD_NAME_LIST
  # by retrieving all shard pod FQDNs and resolving them to IPs via getent hosts
  # 
  # Additionally, it populates KB_CLUSTER_COMPONENT_POD_NAME_LIST and KB_CLUSTER_COMPONENT_POD_HOST_IP_LIST
  # by resolving all pods in the current component (via the component-specific FQDN environment variable).
  #
  # It exports:
  #   KB_CLUSTER_POD_IP_LIST - comma-separated list of ALL pod IPs (all components/shards in cluster)
  #   KB_CLUSTER_POD_NAME_LIST - comma-separated list of ALL pod names (all components/shards in cluster)
  #   KB_CLUSTER_POD_HOST_IP_LIST - comma-separated list of ALL pod IPs (aligned with KB_CLUSTER_POD_NAME_LIST)
  #   KB_CLUSTER_COMPONENT_POD_NAME_LIST - comma-separated list of ALL pods in current component
  #   KB_CLUSTER_COMPONENT_POD_HOST_IP_LIST - comma-separated list of ALL pod IPs in current component
  #
  # Returns:
  #   0 if successful (even with partial failures)
  #   1 if unable to get pod FQDNs

  local pod_fqdns
  local pod_ips=""
  local pod_names=""
  local component_pod_names=""
  local component_pod_ips=""
  local pod_name
  local pod_ip

  # Get all shard pod FQDNs
  if ! pod_fqdns=$(get_all_shards_pod_fqdns); then
    echo "Error: Failed to get all shard pod FQDNs" >&2
    return 1
  fi

  # Handle empty FQDN list
  if [ -z "$pod_fqdns" ]; then
    echo "Error: Failed to get all shard pod FQDNs" >&2
    return 1
  fi

  # Resolve each FQDN to IP
  while IFS= read -r pod_fqdn; do
    [ -z "$pod_fqdn" ] && continue
    # Extract pod name from FQDN (first part before the dot)
    pod_name="${pod_fqdn%%.*}"

    # Resolve FQDN to IP via getent hosts, get the first IP (IPv4)
    local getent_output
    getent_output=$(getent hosts "$pod_fqdn" 2>&1)
    pod_ip=$(echo "$getent_output" | awk '{print $1; exit}')

    # Skip pods that cannot be resolved
    if [ -z "$pod_ip" ]; then
      echo "Warning: Failed to resolve IP for pod FQDN: $pod_fqdn (getent output: $getent_output)" >&2
      continue
    fi

    pod_ips="${pod_ips:+${pod_ips},}${pod_ip}"
    pod_names="${pod_names:+${pod_names},}${pod_name}"
  done << _ALLFQDNS_EOF_
$(printf '%s\n' "$pod_fqdns" | tr ',' '\n')
_ALLFQDNS_EOF_

  # Export all pods (across all components/shards in cluster) as comma-separated values
  export KB_CLUSTER_POD_IP_LIST="$pod_ips"
  export KB_CLUSTER_POD_NAME_LIST="$pod_names"
  # Keep host IP list aligned with resolved pod IPs for downstream consumers
  export KB_CLUSTER_POD_HOST_IP_LIST="$KB_CLUSTER_POD_IP_LIST"

  # Export component-specific pods if CURRENT_SHARD_COMPONENT_NAME is set
  # Use the component-specific FQDN environment variable via CURRENT_SHARD_COMPONENT_SHORT_NAME
  # e.g., for CURRENT_SHARD_COMPONENT_SHORT_NAME="shard-gds", use ALL_SHARDS_POD_FQDN_LIST_SHARD_GDS
  if [ -n "$CURRENT_SHARD_COMPONENT_NAME" ] && [ -n "$CURRENT_SHARD_COMPONENT_SHORT_NAME" ]; then
    # Extract the suffix after "shard-" from the short name
    # For "shard-gds", extract "gds"
    local shard_suffix
    shard_suffix="${CURRENT_SHARD_COMPONENT_SHORT_NAME##*shard-}"

    # Convert to uppercase for env var name
    local component_var_suffix
    component_var_suffix=$(printf '%s' "$shard_suffix" | tr '[:lower:]' '[:upper:]')

    local component_fqdn_var_name="ALL_SHARDS_POD_FQDN_LIST_SHARD_${component_var_suffix}"
    eval "component_pod_fqdns=\$$component_fqdn_var_name"

    if [ -n "$component_pod_fqdns" ]; then
      # Resolve component pod FQDNs to IPs
      while IFS= read -r pod_fqdn; do
        [ -z "$pod_fqdn" ] && continue
        # Extract pod name from FQDN (first part before the dot)
        pod_name="${pod_fqdn%%.*}"

        # Resolve FQDN to IP via getent hosts, get the first IP (IPv4)
        local getent_output
        getent_output=$(getent hosts "$pod_fqdn" 2>&1)
        pod_ip=$(echo "$getent_output" | awk '{print $1; exit}')

        # Skip pods that cannot be resolved
        if [ -z "$pod_ip" ]; then
          echo "Warning: Failed to resolve IP for component pod FQDN: $pod_fqdn (getent output: $getent_output)" >&2
          continue
        fi

        component_pod_names="${component_pod_names:+${component_pod_names},}${pod_name}"
        component_pod_ips="${component_pod_ips:+${component_pod_ips},}${pod_ip}"
      done << _COMPFQDNS_EOF_
$(printf '%s\n' "$component_pod_fqdns" | tr ',' '\n')
_COMPFQDNS_EOF_

      # Export component-specific pods if any were found
      if [ -n "$component_pod_names" ]; then
        export KB_CLUSTER_COMPONENT_POD_NAME_LIST="$component_pod_names"
        export KB_CLUSTER_COMPONENT_POD_HOST_IP_LIST="$component_pod_ips"
      fi
    fi
  fi

  return 0
}

initialize_redis_cluster() {
  init_cluster_map_files

  if is_empty "$KB_CLUSTER_POD_NAME_LIST" || is_empty "$KB_CLUSTER_POD_HOST_IP_LIST"; then
    echo "Error: Required environment variable KB_CLUSTER_POD_NAME_LIST and KB_CLUSTER_POD_HOST_IP_LIST are not set when initializing redis cluster" >&2
    return 1
  fi

  # generate primary and secondary nodes
  gen_initialize_redis_cluster_primary_node
  gen_initialize_redis_cluster_secondary_nodes

  _pn_size=$(_map_size "$_initialize_redis_cluster_primary_nodes")
  if [ "$_pn_size" -eq 0 ] || [ "$_pn_size" -lt 3 ]; then
    echo "Failed to get primary nodes or the primary nodes count is less than 3" >&2
    return 1
  fi

  # check all the primary nodes are ready
  local primary_nodes=""
  local primary_node_list=""
  while IFS="$(printf '\t')" read -r pod_name node_addr; do
    primary_nodes="${primary_nodes}${node_addr} "
    primary_node_list="${primary_node_list:+${primary_node_list}|}${node_addr}"
  done < "$_initialize_redis_cluster_primary_nodes"
  if ! check_initialize_nodes_ready "$primary_node_list"; then
    echo "Primary nodes health check failed" >&2
    return 1
  fi

  # check all the secondary nodes are ready
  if [ -s "$_initialize_redis_cluster_secondary_nodes" ]; then
    secondary_node_list=""
    while IFS="$(printf '\t')" read -r pod_name node_addr; do
      secondary_node_list="${secondary_node_list:+${secondary_node_list}|}${node_addr}"
    done < "$_initialize_redis_cluster_secondary_nodes"
    if ! check_initialize_nodes_ready "$secondary_node_list"; then
      echo "Secondary nodes health check failed" >&2
      return 1
    fi
  fi

  # initialize all the primary nodes
  if create_redis_cluster "$primary_nodes"; then
    echo "FalkorDB cluster initialized primary nodes successfully, cluster nodes: $primary_nodes"
  else
    echo "Failed to create falkordb cluster when initializing" >&2
    return 1
  fi

  # get the first primary node to check the cluster
  first_primary_node=$(echo "$primary_nodes" | awk '{print $1}')
  if check_slots_covered "$first_primary_node" "$SERVICE_PORT"; then
    echo "FalkorDB cluster check primary nodes slots covered successfully."
  else
    echo "Failed to create falkordb cluster when checking slots covered" >&2
    return 1
  fi

  # initialize all the secondary nodes
  if [ ! -s "$_initialize_redis_cluster_secondary_nodes" ]; then
    echo "No secondary nodes to initialize"
    return 0
  fi

  all_secondaries_ready=true
  while IFS="$(printf '\t')" read -r secondary_pod_name secondary_endpoint_with_port; do
    # shellcheck disable=SC2001
    mapping_primary_pod_name=$(echo "$secondary_pod_name" | sed 's/-[0-9]*$/-0/')
    mapping_primary_endpoint_with_port=$(_map_get "$_initialize_pod_name_to_advertise_host_port_map" "$mapping_primary_pod_name")
    if is_empty "$mapping_primary_endpoint_with_port"; then
      echo "Failed to find the mapping primary node for secondary node: $secondary_pod_name" >&2
      return 1
    fi
    mapping_primary_endpoint=$(echo "$mapping_primary_endpoint_with_port" | cut -d':' -f1)
    mapping_primary_port=$(echo "$mapping_primary_endpoint_with_port" | cut -d':' -f2)
    mapping_primary_cluster_id=$(get_cluster_id "$mapping_primary_endpoint" "$mapping_primary_port")
    echo "mapping_primary_fqdn: $mapping_primary_endpoint, mapping_primary_endpoint_with_port: $mapping_primary_endpoint_with_port, mapping_primary_cluster_id: $mapping_primary_cluster_id"
    if is_empty "$mapping_primary_cluster_id"; then
      echo "Failed to get the cluster id from cluster nodes of the mapping primary node: $mapping_primary_endpoint_with_port" >&2
      return 1
    fi
    replicated_output=$(secondary_replicated_to_primary "$secondary_endpoint_with_port" "$mapping_primary_endpoint_with_port" "$mapping_primary_cluster_id")
    status=$?
    if [ $status -ne 0 ] ; then
      echo "Failed to initialize the secondary node $secondary_pod_name, secondary replicated output: $replicated_output" >&2
      return 1
    fi
    echo "FalkorDB cluster initialized secondary node $secondary_pod_name successfully"
    # waiting for all nodes sync the information
    sleep_when_ut_mode_false 5

    # verify secondary node is already in all primary nodes
    if ! verify_secondary_in_all_primaries "$secondary_pod_name" "$primary_node_list"; then
      echo "Failed to verify secondary node $secondary_pod_name in all primary nodes" >&2
      all_secondaries_ready=false
      continue
    fi
    echo "Secondary node $secondary_pod_name successfully joined the cluster and verified in all primaries"
  done < "$_initialize_redis_cluster_secondary_nodes"

  if [ "$all_secondaries_ready" = false ]; then
    echo "Failed to initialize all secondary nodes" >&2
    return 1
  fi
  echo "FalkorDB cluster initialized all secondary nodes successfully"
  return 0
}

verify_secondary_in_all_primaries() {
  local secondary_pod_name="$1"
  local primary_node_list="$2"  # pipe-separated list of host:port primaries
  for primary_node in $(printf '%s' "$primary_node_list" | tr '|' '\n'); do
    local primary_host primary_port
    primary_host=$(echo "$primary_node" | cut -d':' -f1)
    primary_port=$(echo "$primary_node" | cut -d':' -f2)
    retry_count=0
    while ! check_node_in_cluster "$primary_host" "$primary_port" "$secondary_pod_name" && [ $retry_count -lt 30 ]; do
      sleep_when_ut_mode_false 3
      retry_count=$((retry_count + 1))
    done
    # shellcheck disable=SC2086
    if [ $retry_count -eq 30 ]; then
      echo "Secondary node $secondary_pod_name not found in primary $primary_node after retry" >&2
      return 1
    fi
  done
  return 0
}

check_current_shard_other_nodes_are_joined() {
  local current_primary_host="$1"
  local service_port="$2"
  cluster_nodes_info=$(get_cluster_nodes_info "$current_primary_host" "$service_port")
  while IFS="$(printf '\t')" read -r secondary_pod_name _addr; do
    if ! contains "$cluster_nodes_info" "$secondary_pod_name"; then
      echo "Secondary node $secondary_pod_name not found in primary $current_primary_host, need to joined" >&2
      return 1
    fi
  done < "$_scale_out_shard_default_other_nodes"
  return 0
}

scale_out_redis_cluster_shard() {
  init_cluster_map_files
  if is_empty "$CURRENT_SHARD_COMPONENT_SHORT_NAME" || is_empty "$KB_CLUSTER_POD_NAME_LIST" || is_empty "$KB_CLUSTER_POD_HOST_IP_LIST" || is_empty "$KB_CLUSTER_COMPONENT_POD_NAME_LIST" || is_empty "$KB_CLUSTER_COMPONENT_POD_HOST_IP_LIST"; then
    echo "Error: Required environment variable CURRENT_SHARD_COMPONENT_SHORT_NAME, KB_CLUSTER_POD_NAME_LIST, KB_CLUSTER_POD_HOST_IP_LIST, KB_CLUSTER_COMPONENT_POD_NAME_LIST and KB_CLUSTER_COMPONENT_POD_HOST_IP_LIST are not set when scale out redis cluster shard" >&2
    return 1
  fi

  init_other_components_and_pods_info "$CURRENT_SHARD_COMPONENT_SHORT_NAME" "$KB_CLUSTER_POD_IP_LIST" "$KB_CLUSTER_POD_NAME_LIST" "$KB_CLUSTER_COMPONENT_LIST" "$KB_CLUSTER_COMPONENT_DELETING_LIST" "$KB_CLUSTER_COMPONENT_UNDELETED_LIST"
  if init_current_comp_default_nodes_for_scale_out; then
    echo "FalkorDB cluster scale out shard default primary and secondary nodes successfully"
  else
    echo "Failed to initialize the default primary and secondary nodes for scale out" >&2
    return 1
  fi

  # check the current component shard whether is already scaled out
  if [ ! -s "$_scale_out_shard_default_primary_node" ]; then
    echo "Failed to generate primary nodes when scaling out" >&2
    return 1
  fi
  primary_node_with_port=$(awk -F'\t' 'NR==1{print $2}' "$_scale_out_shard_default_primary_node")
  primary_node_fqdn=$(echo "$primary_node_with_port" | awk -F ':' '{print $1}')
  primary_node_port=$(echo "$primary_node_with_port" | awk -F ':' '{print $2}')
  mapping_primary_cluster_id=$(get_cluster_id "$primary_node_fqdn" "$primary_node_port")
  current_primary_joined=false
  if check_slots_covered "$primary_node_with_port" "$SERVICE_PORT"; then
    if check_current_shard_other_nodes_are_joined "$primary_node_fqdn" "$primary_node_port"; then
      echo "The current component shard is already scaled out, no need to scale out again."
      return 0
    fi
    current_primary_joined=true
  fi

  # find the exist available node which is not in the current component
  available_node=$(find_exist_available_node)
  if is_empty "$available_node"; then
    echo "No exist available node found or cluster status is not ok" >&2
    return 1
  fi

  # add the primary node for the current shard
  if [ "$current_primary_joined" = false ]; then
    local scale_out_shard_default_primary
    while IFS="$(printf '\t')" read -r primary_pod_name scale_out_shard_default_primary; do
      if scale_out_shard_primary_join_cluster "$scale_out_shard_default_primary" "$available_node"; then
        echo "FalkorDB cluster scale out shard primary node $primary_pod_name successfully"
      else
        echo "Failed to scale out shard primary node $primary_pod_name" >&2
        return 1
      fi
    done < "$_scale_out_shard_default_primary_node"
  fi

  # waiting for all nodes sync the information
  sleep_when_ut_mode_false 5

  # add the secondary nodes to replicate the primary node
  local scale_out_shard_secondary_node
  while IFS="$(printf '\t')" read -r secondary_pod_name scale_out_shard_secondary_node; do
    true  # body follows
    echo "primary_node_with_port: $primary_node_with_port, primary_node_fqdn: $primary_node_fqdn, mapping_primary_cluster_id: $mapping_primary_cluster_id"
    if check_node_in_cluster "$primary_node_fqdn" "$primary_node_with_port" "$secondary_pod_name"; then
      echo "Secondary node $secondary_pod_name already joined the cluster, skip replicating to primary"
      continue
    fi
    if secondary_replicated_to_primary "$scale_out_shard_secondary_node" "$primary_node_with_port" "$mapping_primary_cluster_id"; then
      echo "FalkorDB cluster scale out shard secondary node $secondary_pod_name successfully"
    else
      echo "Failed to scale out shard secondary node $secondary_pod_name" >&2
      return 1
    fi
  done < "$_scale_out_shard_default_other_nodes"

  # do the reshard
  # TODO: optimize the number of reshard slots according to the cluster status
  local total_slots
  local current_comp_pod_count
  local all_comp_pod_count
  local shard_count
  local slots_per_shard
  total_slots=16384
  current_comp_pod_count=$(echo "$KB_CLUSTER_COMPONENT_POD_NAME_LIST" | tr ',' '\n' | grep -c "^$CURRENT_SHARD_COMPONENT_NAME-")
  all_comp_pod_count=$(echo "$KB_CLUSTER_POD_NAME_LIST" | tr ',' '\n' | grep -c ".*")
  shard_count=$((all_comp_pod_count / current_comp_pod_count))
  slots_per_shard=$((total_slots / shard_count))
  if scale_out_shard_reshard "$primary_node_with_port" "$mapping_primary_cluster_id" "$slots_per_shard"; then
    echo "FalkorDB cluster scale out shard reshard successfully"
  else
    echo "Failed to scale out shard reshard" >&2
    return 1
  fi

  # TODO: rebalance the cluster
  return 0
}

sync_acl_for_redis_cluster_shard() {
  echo "Sync ACL rules for redis cluster shard..."
  set +ex
  redis_base_cmd="redis-cli $REDIS_CLI_TLS_CMD -p $SERVICE_PORT -a $REDIS_DEFAULT_PASSWORD"
  if [ -z "$REDIS_DEFAULT_PASSWORD" ]; then
     redis_base_cmd="redis-cli $REDIS_CLI_TLS_CMD -p $SERVICE_PORT"
  fi
  is_ok=false
  acl_list=""
  # 1. get acl list from other pods
  for pod_name in $(echo "$KB_CLUSTER_POD_NAME_LIST" | tr ',' ' '); do
    pod_ip=$(parse_host_ip_from_built_in_envs "$pod_name" "$KB_CLUSTER_POD_NAME_LIST" "$KB_CLUSTER_POD_IP_LIST")
    if is_empty "$pod_ip"; then
      echo "Failed to get the host ip of the pod $pod_name"
      continue
    fi

    cluster_info=$(get_cluster_info_with_retry "$pod_ip" "$SERVICE_PORT")
    status=$?
    if [ $status -ne 0 ]; then
      continue
    fi
    cluster_state=$(echo "$cluster_info" | awk -F: '/cluster_state/{print $2}' | tr -d '[:space:]')
    if is_empty "$cluster_state" || equals "$cluster_state" "ok"; then
       acl_list=$($redis_base_cmd -h "$pod_ip" ACL LIST)
       is_ok=true
       break
    fi
  done

  if [ "$is_ok" = false ]; then
      echo "Failed to get ACL LIST from other shard pods" >&2
      return 1
  fi

  if [ -z "$acl_list" ]; then
      echo "No ACL rules found in other pods, skip synchronization" >&2
      return
  fi
  # 2. apply acl list to current shard pods
  set -e
  while IFS= read -r user_rule; do
      [ -z "$user_rule" ] && continue

      username=$(printf '%s' "$user_rule" | sed -n 's/^user[[:space:]]\+\([^[:space:]]\+\).*/\1/p')
      if [ -z "$username" ]; then
        # skip invalid user rule
        continue
      fi

      if [ "$username" = "default" ]; then
          continue
      fi
      rule_part="${user_rule#user $username }"
      for pod_fqdn in $(printf '%s\n' "$CURRENT_SHARD_POD_FQDN_LIST" | tr ',' ' '); do
         $redis_base_cmd -h $pod_fqdn ACL SETUSER "$username" $rule_part >&2
         $redis_base_cmd -h $pod_fqdn ACL save >&2
      done
  done << _ACL_EOF_
$acl_list
_ACL_EOF_
  set_xtrace_when_ut_mode_false
}

scale_in_redis_cluster_shard() {
  # check KB_CLUSTER_COMPONENT_IS_SCALING_IN env
  if is_empty "$KB_CLUSTER_COMPONENT_IS_SCALING_IN"; then
    echo "The KB_CLUSTER_COMPONENT_IS_SCALING_IN env is not set, skip scaling in"
    return 0
  fi

  if is_empty "$CURRENT_SHARD_COMPONENT_SHORT_NAME" || is_empty "$KB_CLUSTER_POD_NAME_LIST" || is_empty "$KB_CLUSTER_POD_HOST_IP_LIST" || is_empty "$KB_CLUSTER_COMPONENT_POD_NAME_LIST" || is_empty "$KB_CLUSTER_COMPONENT_POD_HOST_IP_LIST"; then
    echo "Error: Required environment variable CURRENT_SHARD_COMPONENT_SHORT_NAME, KB_CLUSTER_POD_NAME_LIST, KB_CLUSTER_POD_HOST_IP_LIST, KB_CLUSTER_COMPONENT_POD_NAME_LIST and KB_CLUSTER_COMPONENT_POD_HOST_IP_LIST are not set when scale in redis cluster shard" >&2
    return 1
  fi

  # init information for the other components and pods
  init_other_components_and_pods_info "$CURRENT_SHARD_COMPONENT_SHORT_NAME" "$KB_CLUSTER_POD_IP_LIST" "$KB_CLUSTER_POD_NAME_LIST" "$KB_CLUSTER_COMPONENT_LIST" "$KB_CLUSTER_COMPONENT_DELETING_LIST" "$KB_CLUSTER_COMPONENT_UNDELETED_LIST"
  available_node=$(find_exist_available_node)
  available_node_fqdn=$(echo "$available_node" | awk -F ':' '{print $1}')
  available_node_port=$(echo "$available_node" | awk -F ':' '{print $2}')
  get_current_comp_nodes_for_scale_in "$available_node_fqdn" "$available_node_port"

  # Check if the number of shards in the cluster is less than 3 after scaling down.
  current_comp_pod_count=0
  for pod_name in $(printf '%s\n' "$KB_CLUSTER_COMPONENT_POD_NAME_LIST" | tr ',' ' '); do
    case "$pod_name" in
      "$CURRENT_SHARD_COMPONENT_NAME"*) current_comp_pod_count=$((current_comp_pod_count + 1)) ;;
    esac
  done
  _node_count=$(printf '%s' "$other_undeleted_component_nodes" | tr '|' '\n' | grep -c '.'  2>/dev/null || echo 0)
  shard_count=$((_node_count / current_comp_pod_count))
  if [ $shard_count -lt 3 ]; then
    echo "The number of shards in the cluster is less than 3 after scaling in, please check." >&2
    return 1
  fi

  # set the current shard component slot to 0 by rebalance command
  for primary_node in $(printf '%s' "$current_comp_primary_node" | tr '|' '\n'); do
    primary_node_fqdn=$(echo "$primary_node" | awk -F ':' '{print $1}')
    primary_node_port=$(echo "$primary_node" | awk -F ':' '{print $2}')
    primary_node_cluster_id=$(get_cluster_id "$primary_node_fqdn" "$primary_node_port")
    if scale_in_shard_rebalance_to_zero "$primary_node" "$primary_node_cluster_id"; then
      echo "FalkorDB cluster scale in shard rebalance to zero successfully"
    else
      echo "Failed to rebalance the cluster for the current component when scaling in" >&2
      return 1
    fi
  done

  sleep_when_ut_mode_false 5

  # delete the current shard component nodes from the cluster
  _all_to_del="${current_comp_primary_node:+${current_comp_primary_node}${current_comp_other_nodes:+|}}${current_comp_other_nodes}"
  for node_to_del in $(printf '%s' "$_all_to_del" | tr '|' '\n'); do
    node_to_del_fqdn=$(echo "$node_to_del" | awk -F ':' '{print $1}')
    node_to_del_port=$(echo "$node_to_del" | awk -F ':' '{print $2}')
    node_to_del_cluster_id=$(get_cluster_id "$node_to_del_fqdn" "$node_to_del_port")
    if scale_in_shard_del_node "$available_node" "$node_to_del_cluster_id"; then
      echo "FalkorDB cluster scale in shard delete node $node_to_del successfully"
    else
      echo "Failed to delete the node $node_to_del from the cluster when scaling in" >&2
      return 1
    fi
  done
  return 0
}

initialize_or_scale_out_redis_cluster() {
  # TODO: remove random sleep, it's a workaround for the multi components initialization parallelism issue
  sleep_random_second_when_ut_mode_false 10 1

  populate_pod_ip_name_list

  if is_empty "$KB_CLUSTER_POD_IP_LIST" || is_empty "$KB_CLUSTER_POD_NAME_LIST"; then
    echo "Error: Required environment variable KB_CLUSTER_POD_IP_LIST and KB_CLUSTER_POD_NAME_LIST and SERVICE_PORT is not set." >&2
    return 1
  fi

  local initialize_retry_times
  local initialize_retry_interval
  local scale_out_retry_times
  local scale_out_retry_interval
  initialize_retry_times="${POST_PROVISION_INITIALIZE_RETRY_TIMES:-3}"
  initialize_retry_interval="${POST_PROVISION_INITIALIZE_RETRY_INTERVAL:-5}"
  scale_out_retry_times="${POST_PROVISION_SCALE_OUT_RETRY_TIMES:-3}"
  scale_out_retry_interval="${POST_PROVISION_SCALE_OUT_RETRY_INTERVAL:-5}"

  # if the cluster is not initialized, initialize it first.
  # in concurrent lifecycle execution, another component may initialize first,
  # so we re-check initialization state before returning failure.
  if ! check_cluster_initialized "$KB_CLUSTER_POD_IP_LIST" "$KB_CLUSTER_POD_NAME_LIST"; then
    echo "FalkorDB Cluster not initialized, initializing..."
    if call_func_with_retry_when_ut_mode_false "$initialize_retry_times" "$initialize_retry_interval" initialize_redis_cluster; then
      echo "FalkorDB Cluster initialized successfully"
      return 0
    fi

    echo "Initialization retries failed, checking if another component has initialized the cluster..." >&2
    if ! check_cluster_initialized "$KB_CLUSTER_POD_IP_LIST" "$KB_CLUSTER_POD_NAME_LIST"; then
      echo "Failed to initialize FalkorDB Cluster" >&2
      return 1
    fi
    echo "FalkorDB Cluster has been initialized by another component, switching to scale-out flow."
  fi

  if ! call_func_with_retry_when_ut_mode_false "$scale_out_retry_times" "$scale_out_retry_interval" sync_acl_for_redis_cluster_shard; then
    echo "Warning: failed to sync ACL rules before scale out, continuing with best-effort scale out." >&2
  fi

  echo "FalkorDB Cluster already initialized, scaling out the shard..."
  if call_func_with_retry_when_ut_mode_false "$scale_out_retry_times" "$scale_out_retry_interval" scale_out_redis_cluster_shard; then
    echo "FalkorDB Cluster scale out shard successfully"
    return 0
  fi

  # final convergence check in case retry failures were transient.
  if scale_out_redis_cluster_shard; then
    echo "FalkorDB Cluster scale out shard successfully"
    return 0
  fi

  echo "Failed to scale out FalkorDB Cluster shard" >&2
  return 1
}

# This is magic for shellspec ut framework.
# Sometime, functions are defined in a single shell script.
# You will want to test it. but you do not want to run the script.
# When included from shellspec, __SOURCED__ variable defined and script
# end here. The script path is assigned to the __SOURCED__ variable.
${__SOURCED__:+false} : || return 0

# main
if [ $# -eq 1 ]; then
  init_environment
  load_redis_cluster_common_utils
  case $1 in
  --help)
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  --help                show help information"
    echo "  --post-provision      initialize or scale out FalkorDB Cluster Shard"
    echo "  --pre-terminate       stop or scale in FalkorDB Cluster Shard"
    exit 0
    ;;
  --post-provision)
    if initialize_or_scale_out_redis_cluster; then
      echo "FalkorDB Cluster initialized or scale out shard successfully"
    else
      echo "Failed to initialize or scale out FalkorDB Cluster shard" >&2
      exit 1
    fi
    exit 0
    ;;
  --pre-terminate)
    if scale_in_redis_cluster_shard; then
      echo "FalkorDB Cluster scale in shard successfully"
    else
      echo "Failed to scale in FalkorDB Cluster shard" >&2
      exit 1
    fi
    exit 0
    ;;
  *)
    echo "Error: invalid option '$1'"
    exit 1
    ;;
  esac
fi

#!/bin/bash

# shellcheck disable=SC2034
# shellcheck disable=SC1090
# shellcheck disable=SC2153

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

service_port=${SERVICE_PORT:-6379}
retry_times=3
check_ready_times=30
retry_delay_second=2

load_redis_cluster_common_utils() {
  # the common.sh and falkordb-cluster-common.sh scripts are defined in the falkordb-cluster-scripts-template configmap
  # and are mounted to the same path which defined in the cmpd.spec.scripts
  kblib_common_library_file="/scripts/common.sh"
  redis_cluster_common_library_file="/scripts/falkordb-cluster-common.sh"
  source "${kblib_common_library_file}"
  source "${redis_cluster_common_library_file}"
}

# find a healthy primary node of the current shard, excluding the joining pod.
# the memberJoin action can be executed on any pod of the shard (targetPodSelector: Any),
# so the shard primary is discovered by asking each peer whether it sees itself as a
# healthy master in the cluster.
find_current_shard_primary_node() {
  local joining_pod_fqdn="$1"
  local pod_fqdn myself_flags cluster_nodes_info
  for pod_fqdn in $(echo "$CURRENT_SHARD_POD_FQDN_LIST" | tr ',' '\n'); do
    if equals "$pod_fqdn" "$joining_pod_fqdn"; then
      continue
    fi
    cluster_nodes_info=$(get_cluster_nodes_info "$pod_fqdn" "$service_port")
    if [ $? -ne 0 ]; then
      continue
    fi
    myself_flags=$(echo "$cluster_nodes_info" | grep "myself" | awk '{print $3}')
    if contains "$myself_flags" "master" && ! contains "$myself_flags" "fail"; then
      echo "$pod_fqdn"
      return 0
    fi
  done
  return 1
}

# join the new member pod to the current shard as a replica of the shard primary.
# all operations are performed remotely against the joining pod fqdn because the
# action is not guaranteed to run on the joining pod itself.
join_member_to_shard() {
  local joining_pod_name="$KB_JOIN_MEMBER_POD_NAME"
  local joining_pod_fqdn="$KB_JOIN_MEMBER_POD_FQDN"
  if is_empty "$joining_pod_name" || is_empty "$joining_pod_fqdn"; then
    echo "Error: KB_JOIN_MEMBER_POD_NAME or KB_JOIN_MEMBER_POD_FQDN is not set, cannot join member to shard" >&2
    return 1
  fi

  # 1. wait for the joining redis server to be ready
  if ! check_redis_server_ready_with_retry "$joining_pod_fqdn" "$service_port"; then
    echo "The joining FalkorDB server $joining_pod_fqdn is not ready, cannot join member to shard" >&2
    return 1
  fi

  # 2. find a healthy primary node of the current shard
  primary_node_fqdn=$(find_current_shard_primary_node "$joining_pod_fqdn")
  if is_empty "$primary_node_fqdn"; then
    # during initial provisioning the cluster is created by the postProvision action and
    # the startup script, so there may be no initialized primary yet. skip in this case.
    echo "No healthy primary node found in the current shard, skip member join (cluster may not be initialized yet)"
    return 0
  fi
  echo "Found the current shard primary node: $primary_node_fqdn"

  # 3. get the node ID of the joining pod, so membership checks are done by node ID
  # instead of pod name/fqdn only, and stale entries of a previous incarnation with the
  # same fqdn but a different node ID can be cleaned up.
  joining_node_id=$(get_cluster_id_with_retry "$joining_pod_fqdn" "$service_port")
  if is_empty "$joining_node_id"; then
    echo "Failed to get the node id of the joining pod $joining_pod_fqdn" >&2
    return 1
  fi

  # 4. forget any stale entries left behind by a previous incarnation of this pod
  if ! forget_stale_nodes_for_pod "$primary_node_fqdn" "$service_port" "$joining_pod_fqdn" "$joining_node_id"; then
    echo "Failed to forget stale nodes for pod $joining_pod_fqdn, continue to join anyway..." >&2
  fi

  primary_node_id=$(get_cluster_id_with_retry "$primary_node_fqdn" "$service_port")
  if is_empty "$primary_node_id"; then
    echo "Failed to get the node id of the primary node $primary_node_fqdn" >&2
    return 1
  fi

  # 5. add the joining pod as a replica of the shard primary if not already joined
  if check_node_in_cluster "$primary_node_fqdn" "$service_port" "$joining_pod_name" "$joining_node_id"; then
    echo "Node $joining_pod_name is already in the cluster with node id $joining_node_id, skip adding it as a replica"
  else
    replicated_output=$(secondary_replicated_to_primary "$joining_pod_fqdn:$service_port" "$primary_node_fqdn:$service_port" "$primary_node_id")
    replicated_status=$?
    if [ $replicated_status -ne 0 ]; then
      if contains "$replicated_output" "is not empty"; then
        echo "The joining node already knows other nodes or contains keys, verify replication status below..."
      else
        echo "Failed to add the node $joining_pod_fqdn to the cluster as a replica of $primary_node_fqdn, Error message: $replicated_output" >&2
        return 1
      fi
    fi
  fi

  # 6. verify the joining pod is replicated to the shard primary
  if ! check_secondary_replicated_to_primary_with_retry "$primary_node_fqdn" "$service_port" "$joining_pod_name" "$primary_node_id"; then
    echo "Failed to verify the node $joining_pod_name is replicated to the primary $primary_node_fqdn" >&2
    return 1
  fi

  echo "Successfully joined the member $joining_pod_name to the shard as a replica of $primary_node_fqdn"
  return 0
}

# This is magic for shellspec ut framework.
# Sometime, functions are defined in a single shell script.
# You will want to test it. but you do not want to run the script.
# When included from shellspec, __SOURCED__ variable defined and script
# end here. The script path is assigned to the __SOURCED__ variable.
${__SOURCED__:+false} : || return 0

load_redis_cluster_common_utils
if ! join_member_to_shard; then
  echo "Failed to join the member to the shard" >&2
  exit 1
fi
# keep the existing ACL synchronization behavior of the memberJoin action
exec /scripts/sync-acl.sh

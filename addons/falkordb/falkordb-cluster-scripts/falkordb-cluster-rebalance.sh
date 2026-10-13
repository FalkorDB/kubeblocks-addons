#!/bin/bash

# Spreads the slots of a sharded FalkorDB cluster evenly over its primaries,
# including primaries that own no slot yet, with `redis-cli --cluster
# rebalance`. Run by the falkordb-cluster-rebalance OpsDefinition.
#
# The OpsRequest targets the sharding, and KubeBlocks runs the action once per
# shard, all at the same time. Concurrent rebalances plan their moves from the
# same slot map and then migrate the same slots against each other, so only
# one of them may run: the job of the shard whose primary has the smallest node
# ID. The leader is picked from the live CLUSTER NODES rather than from the
# shard names in the pod env, which can lag behind after a scale-out or
# scale-in and leave no shard thinking it is the leader. The other jobs exit
# successfully without touching the cluster.
#
# Self-contained on purpose: the ops pod does not mount the scripts ConfigMap,
# so this file must not source /scripts/common.sh.

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
  set -e;
}

build_node_endpoint() {
  local service_port=${SERVICE_PORT:-6379}
  echo "$CURRENT_POD_NAME.$CURRENT_SHARD_COMPONENT_NAME-headless.$CLUSTER_NAMESPACE.svc.$CLUSTER_DOMAIN:$service_port"
}

# The password goes through REDISCLI_AUTH, which redis-cli also uses for every
# node it connects to in --cluster mode, so it never shows up in the process
# arguments or the job log.
falkordb_cli() {
  local -a user_args=()
  if [ -n "$REDIS_DEFAULT_USER" ]; then
    user_args=(--user "$REDIS_DEFAULT_USER")
  fi
  # An empty REDISCLI_AUTH still makes redis-cli send `AUTH ""`, which a
  # password-less server rejects, so it is only set when there is a password.
  if [ -n "$REDIS_DEFAULT_PASSWORD" ]; then
    # shellcheck disable=SC2086
    REDISCLI_AUTH="$REDIS_DEFAULT_PASSWORD" redis-cli $REDIS_CLI_TLS_CMD "${user_args[@]}" "$@"
  else
    # shellcheck disable=SC2086
    redis-cli $REDIS_CLI_TLS_CMD "${user_args[@]}" "$@"
  fi
}

# Prints the node ID of the primary of the shard this job runs for: the node
# itself when it is a primary, its primary when it is a replica.
own_shard_primary_id() {
  local cluster_nodes="$1"
  echo "$cluster_nodes" | awk '$3 ~ /myself/ {
    if ($3 ~ /master/) { print $1 } else { print $4 }
    exit
  }'
}

# Prints the smallest node ID among the healthy primaries: flagged master,
# not failing, and with a connected cluster-bus link (field 8). A primary that
# lost its link must not win, or every job could stand down while the leader's
# own job, if any, cannot reach the cluster.
leader_primary_id() {
  local cluster_nodes="$1"
  echo "$cluster_nodes" \
    | awk '$3 ~ /master/ && $3 !~ /fail|noaddr|handshake/ && $8 == "connected" { print $1 }' \
    | LC_ALL=C sort | head -n 1
}

is_rebalance_leader() {
  local host="$1"
  local port="$2"
  local cluster_nodes own_id leader_id
  if ! cluster_nodes=$(falkordb_cli -h "$host" -p "$port" cluster nodes) || [ -z "$cluster_nodes" ]; then
    echo "Error: failed to read CLUSTER NODES from $host:$port: $cluster_nodes" >&2
    return 2
  fi
  own_id=$(own_shard_primary_id "$cluster_nodes")
  leader_id=$(leader_primary_id "$cluster_nodes")
  if [ -z "$own_id" ] || [ -z "$leader_id" ]; then
    echo "Error: could not find the primaries in CLUSTER NODES from $host:$port." >&2
    return 2
  fi
  if [ "$own_id" != "$leader_id" ]; then
    echo "shard $CURRENT_SHARD_COMPONENT_NAME (primary $own_id) is not the rebalance leader, primary $leader_id's shard runs it."
    return 1
  fi
  return 0
}

do_rebalance() {
  local node_endpoint="$1"
  echo "rebalance falkordb cluster slots via node: $node_endpoint"
  falkordb_cli --cluster rebalance "$node_endpoint" --cluster-use-empty-masters --cluster-yes
}

rebalance() {
  local node_endpoint host port rc=0
  node_endpoint=$(build_node_endpoint)
  host="${node_endpoint%:*}"
  port="${node_endpoint##*:}"
  is_rebalance_leader "$host" "$port" || rc=$?
  case "$rc" in
    0) do_rebalance "$node_endpoint" ;;
    1) return 0 ;;
    *) return 1 ;;
  esac
}

# This is magic for shellspec ut framework.
# Sometime, functions are defined in a single shell script.
# You will want to test it. but you do not want to run the script.
# When included from shellspec, __SOURCED__ variable defined and script
# end here. The script path is assigned to the __SOURCED__ variable.
${__SOURCED__:+false} : || return 0

# main
rebalance

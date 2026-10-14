#!/bin/bash

# Spreads the slots of a sharded FalkorDB cluster evenly over its primaries,
# including primaries that own no slot yet, with `redis-cli --cluster
# rebalance`. Run by the falkordb-cluster-rebalance OpsDefinition.
#
# The OpsRequest targets the sharding, and with `multiPodSelectionPolicy: Any`
# KubeBlocks runs the action exactly once for the whole sharding, on the first
# available pod in name order across every shard (getTargetPods in
# pkg/operations/custom/utils.go, the same in 1.0, 1.1 and 1.2). So this job is
# the only one, and it rebalances the whole cluster through its own pod's
# node, whichever shard that pod is in. An
# earlier version let only the shard whose primary had the smallest node ID
# act, on the assumption that every shard ran a job; with a single job that
# made the rebalance a no-op that still reported success whenever the chosen
# pod was in another shard.
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

do_rebalance() {
  local node_endpoint="$1"
  echo "rebalance falkordb cluster slots via node: $node_endpoint"
  falkordb_cli --cluster rebalance "$node_endpoint" --cluster-use-empty-masters --cluster-yes
}

rebalance() {
  do_rebalance "$(build_node_endpoint)"
}

# This is magic for shellspec ut framework.
# Sometime, functions are defined in a single shell script.
# You will want to test it. but you do not want to run the script.
# When included from shellspec, __SOURCED__ variable defined and script
# end here. The script path is assigned to the __SOURCED__ variable.
${__SOURCED__:+false} : || return 0

# main
rebalance

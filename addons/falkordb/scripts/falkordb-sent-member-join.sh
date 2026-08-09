#!/bin/bash

# Copies the sentinel monitor configuration onto a sentinel that has just joined
# the component.
#
# The data component registers every sentinel it can see from its postProvision
# action, which runs exactly once when the cluster is created. Sentinels never
# exchange `sentinel monitor` between themselves, so a sentinel added later comes
# up monitoring nothing: it counts towards the quorum but can never vote in a
# failover, and the cluster silently loses its ability to fail over once the
# original sentinels are outnumbered.
#
# KubeBlocks runs memberJoin on an existing member rather than on the new one,
# which is what makes this possible at all. The falkordb password required for
# `auth-pass` is not exposed to the sentinel component, because a credentialVarRef
# from the sentinel back to the data component creates a start-up cycle. A
# sentinel that is already monitoring does however hold that password in the
# config file it rewrites for itself, so the joining member can be configured
# from there without the sentinel component ever needing the credential.

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
#
# shellcheck disable=SC2034
ut_mode="false"
test || __() {
  set -e;
}

redis_sentinel_real_conf="/data/sentinel/redis-sentinel.conf"
sentinel_service_port="${SENTINEL_SERVICE_PORT:-26379}"

load_common_library() {
  # the common.sh scripts is mounted to the same path which is defined in the cmpd.spec.scripts
  common_library_file="/scripts/common.sh"
  # shellcheck disable=SC1090
  source "${common_library_file}"
}

# Names of every master this sentinel currently monitors.
monitored_master_names() {
  [ -f "$redis_sentinel_real_conf" ] || return 0
  awk '$1 == "sentinel" && $2 == "monitor" { print $3 }' "$redis_sentinel_real_conf"
}

# Everything after `sentinel <directive> <master>` on the first matching line.
sentinel_conf_directive_value() {
  local directive="$1"
  local master="$2"
  [ -f "$redis_sentinel_real_conf" ] || return 0
  awk -v directive="$directive" -v master="$master" '
    $1 == "sentinel" && $2 == directive && $3 == master {
      value = $4
      for (i = 5; i <= NF; i++) {
        value = value " " $i
      }
      print value
      exit
    }' "$redis_sentinel_real_conf"
}

sentinel_cli() {
  # the password is passed through REDISCLI_AUTH and the command through stdin so
  # that neither the sentinel password nor the falkordb password shows up in the
  # process arguments.
  local host="$1"
  local command="$2"
  (
    export REDISCLI_AUTH="${SENTINEL_PASSWORD}"
    # shellcheck disable=SC2086
    printf '%s\n' "$command" | redis-cli $REDIS_CLI_TLS_CMD -h "$host" -p "$sentinel_service_port"
  )
}

wait_for_joining_sentinel() {
  local host="$1"
  local max_retries=${SENTINEL_JOIN_MAX_RETRIES:-60}
  local retry=0
  while [ "$retry" -lt "$max_retries" ]; do
    if sentinel_cli "$host" "ping" 2>/dev/null | grep -q "PONG"; then
      return 0
    fi
    retry=$((retry + 1))
    sleep_when_ut_mode_false 1
  done
  echo "Error: sentinel $host did not answer PING after $max_retries attempts." >&2
  return 1
}

# Applies one `SENTINEL set` directive, skipping it when this sentinel has no
# value for it. down-after-milliseconds and friends always exist, auth-user and
# auth-pass only exist when the data component is password protected.
propagate_directive() {
  local host="$1"
  local master="$2"
  local directive="$3"
  local value
  value=$(sentinel_conf_directive_value "$directive" "$master")
  if is_empty "$value"; then
    return 0
  fi
  if ! sentinel_cli "$host" "SENTINEL set $master $directive $value" | grep -q "OK"; then
    echo "Error: failed to set $directive for $master on $host." >&2
    return 1
  fi
}

propagate_master() {
  local host="$1"
  local master="$2"

  local monitor_args
  monitor_args=$(sentinel_conf_directive_value monitor "$master")
  if is_empty "$monitor_args"; then
    echo "no monitor configuration for $master, skipping."
    return 0
  fi

  # SENTINEL monitor fails with "Duplicated master name" when the joining member
  # already knows this master, which happens when the action is retried.
  local known_addr
  known_addr=$(sentinel_cli "$host" "SENTINEL get-master-addr-by-name $master" 2>/dev/null)
  if is_empty "$known_addr"; then
    # $monitor_args holds `<ip> <port> <quorum>`.
    if ! sentinel_cli "$host" "SENTINEL monitor $master $monitor_args" | grep -q "OK"; then
      echo "Error: failed to make $host monitor $master." >&2
      return 1
    fi
  else
    echo "$host already monitors $master, refreshing its settings."
  fi

  local directive
  for directive in down-after-milliseconds failover-timeout parallel-syncs auth-user auth-pass; do
    propagate_directive "$host" "$master" "$directive" || return 1
  done
  echo "$host now monitors $master."
}

propagate_monitor_config_to_joining_member() {
  if is_empty "$KB_JOIN_MEMBER_POD_FQDN"; then
    echo "Error: Required environment variable KB_JOIN_MEMBER_POD_FQDN is not set." >&2
    return 1
  fi

  local masters
  masters=$(monitored_master_names)
  if is_empty "$masters"; then
    # Nothing to hand over. This is the normal case while the cluster is still
    # being created, where the data component registers the sentinels itself.
    echo "this sentinel monitors no master yet, nothing to propagate."
    return 0
  fi

  wait_for_joining_sentinel "$KB_JOIN_MEMBER_POD_FQDN" || return 1

  local master
  while read -r master; do
    if is_empty "$master"; then
      continue
    fi
    propagate_master "$KB_JOIN_MEMBER_POD_FQDN" "$master" || return 1
  done <<< "$masters"
}

# This is magic for shellspec ut framework.
# Sometime, functions are defined in a single shell script.
# You will want to test it. but you do not want to run the script.
# When included from shellspec, __SOURCED__ variable defined and script
# end here. The script path is assigned to the __SOURCED__ variable.
${__SOURCED__:+false} : || return 0

# main
load_common_library
propagate_monitor_config_to_joining_member

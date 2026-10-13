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
# The action is declared with `targetPodSelector: All`, so it runs on every
# sentinel including the joining one. Only a sentinel that already monitors the
# master can hand its configuration over; the rest exit early. Do not narrow this
# to `Any`: KubeBlocks is free to pick the joining member, which knows nothing.
# The falkordb password required for
# `auth-pass` is not exposed to the sentinel component, because a credentialVarRef
# from the sentinel back to the data component creates a start-up cycle. A
# sentinel that is already monitoring does however hold that password in the
# config file it rewrites for itself, so the joining member can be configured
# from there without the sentinel component ever needing the credential.
#
# Sentinels do not replicate ACLs between themselves either, and a new sentinel
# starts with only the users from its start script. Accounts created later
# through the falkordb-sent-account-ops OpsDefinition would be rejected by it,
# so the same sentinels that hand over the monitor configuration also copy
# their ACL onto the joining member.

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

# Like sentinel_cli, but passes the command as separate arguments. ACL rules
# have to go this way: a selector such as `(~key* +get)` is one argument that
# contains a space, which the stdin form would split in two.
sentinel_cli_argv() {
  local host="$1"
  shift
  # An empty REDISCLI_AUTH still makes redis-cli send `AUTH ""`, which a
  # password-less sentinel rejects, so it is only set when there is a password.
  if ! is_empty "${SENTINEL_PASSWORD}"; then
    # shellcheck disable=SC2086
    REDISCLI_AUTH="${SENTINEL_PASSWORD}" redis-cli $REDIS_CLI_TLS_CMD -h "$host" -p "$sentinel_service_port" "$@"
  else
    # shellcheck disable=SC2086
    redis-cli $REDIS_CLI_TLS_CMD -h "$host" -p "$sentinel_service_port" "$@"
  fi
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

is_error_reply() {
  echo "$1" | grep -qE "^(\(error\) )?(ERR|NOPERM|NOAUTH|WRONGPASS|WRONGTYPE)"
}

# Splits the rules of one `ACL LIST` line into the arguments of ACL SETUSER,
# keeping each parenthesised selector together as a single argument. ACL rules
# themselves never contain spaces, only selectors do. The result is left in
# the acl_rule_args array.
split_acl_rules() {
  local rules="$1"
  local -a words
  local word selector=""
  acl_rule_args=()
  read -ra words <<< "$rules"
  for word in "${words[@]}"; do
    if ! is_empty "$selector"; then
      selector="$selector $word"
      if [[ "$word" == *")" ]]; then
        acl_rule_args+=("$selector")
        selector=""
      fi
    elif [[ "$word" == "("* && "$word" != *")" ]]; then
      selector="$word"
    else
      acl_rule_args+=("$word")
    fi
  done
  if ! is_empty "$selector"; then
    acl_rule_args+=("$selector")
  fi
}

# The sentinel whose ACL the joining member copies: the lexicographically
# smallest pod in SENTINEL_POD_NAME_LIST other than the joining member.
acl_source_pod_name() {
  local target="$1"
  echo "$SENTINEL_POD_NAME_LIST" | tr ',' '\n' | while IFS= read -r pod; do
    if ! is_empty "$pod" && [[ "$target" != "$pod."* ]]; then
      echo "$pod"
    fi
  done | LC_ALL=C sort | head -n 1
}

# Makes the ACL of the joining sentinel match this one: every user is rewritten
# from scratch (`reset` first, so rules the target had are not merged in), and
# users this sentinel does not have are deleted. `default` is left alone, its
# password comes from SENTINEL_PASSWORD on every sentinel.
#
# The action runs on every sentinel, but only one of them may be the source.
# With several, a sentinel that briefly lacks an account (one being created
# or removed right now) would delete it again after another sentinel set it,
# and the result would depend on which sync finished last.
sync_acl_to_joining_member() {
  local target="$KB_JOIN_MEMBER_POD_FQDN"
  if is_empty "$target"; then
    echo "Error: Required environment variable KB_JOIN_MEMBER_POD_FQDN is not set." >&2
    return 1
  fi
  local source_pod
  source_pod=$(acl_source_pod_name "$target")
  if is_empty "$source_pod"; then
    echo "Error: no sentinel other than the joining member to copy the ACL from." >&2
    return 1
  fi
  if ! equals "$CURRENT_POD_NAME" "$source_pod"; then
    echo "$source_pod copies its ACL onto the joining member, not this sentinel."
    return 0
  fi

  local acl_list
  if ! acl_list=$(sentinel_cli_argv 127.0.0.1 ACL LIST) || is_empty "$acl_list" || is_error_reply "$acl_list"; then
    echo "Error: failed to read the ACL of this sentinel: $acl_list" >&2
    return 1
  fi

  local source_users=""
  local line username output
  while IFS= read -r line; do
    if [[ ! "$line" =~ ^user[[:space:]]+([^[:space:]]+)[[:space:]]*(.*)$ ]]; then
      continue
    fi
    username="${BASH_REMATCH[1]}"
    source_users="$source_users$username"$'\n'
    if equals "$username" "default"; then
      continue
    fi
    split_acl_rules "${BASH_REMATCH[2]}"
    # The rules hold password hashes, so only the user name is logged.
    echo "syncing ACL user $username to $target."
    if ! output=$(sentinel_cli_argv "$target" ACL SETUSER "$username" reset "${acl_rule_args[@]}" 2>&1) \
      || is_error_reply "$output"; then
      echo "Error: failed to set ACL user $username on $target: $output" >&2
      return 1
    fi
  done <<< "$acl_list"

  local target_users
  if ! target_users=$(sentinel_cli_argv "$target" ACL USERS) || is_error_reply "$target_users"; then
    echo "Error: failed to list the ACL users of $target: $target_users" >&2
    return 1
  fi
  while IFS= read -r username; do
    if is_empty "$username" || equals "$username" "default" || grep -Fxq -- "$username" <<< "$source_users"; then
      continue
    fi
    echo "deleting ACL user $username from $target, this sentinel does not have it."
    if ! output=$(sentinel_cli_argv "$target" ACL DELUSER "$username" 2>&1) || is_error_reply "$output"; then
      echo "Error: failed to delete ACL user $username on $target: $output" >&2
      return 1
    fi
  done <<< "$target_users"

  # Without ACL SAVE the joining sentinel loses the users on its next restart.
  if ! output=$(sentinel_cli_argv "$target" ACL SAVE 2>&1) || ! equals "$output" "OK"; then
    echo "Error: ACL SAVE failed on $target: $output" >&2
    return 1
  fi
  echo "ACL of $target now matches this sentinel."
}

member_join() {
  propagate_monitor_config_to_joining_member || return 1
  sync_acl_to_joining_member || return 1
}

# This is magic for shellspec ut framework.
# Sometime, functions are defined in a single shell script.
# You will want to test it. but you do not want to run the script.
# When included from shellspec, __SOURCED__ variable defined and script
# end here. The script path is assigned to the __SOURCED__ variable.
${__SOURCED__:+false} : || return 0

# main
load_common_library
member_join

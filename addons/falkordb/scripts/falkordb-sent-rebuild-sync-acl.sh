#!/bin/bash

# Copies the ACL of an established sentinel onto a sentinel that was rebuilt.
#
# A rebuilt sentinel keeps its pod name but gets a fresh /data volume, so it
# comes back with only the users from its start script, and memberJoin, which
# syncs the ACL onto a new sentinel, does not fire for it. Accounts created
# through the falkordb-sent-account-ops OpsDefinition would be rejected by it.
#
# Run by the falkordb-register-to-sentinel OpsDefinition with
# REBUILD_SENTINEL_POD_NAME naming the rebuilt sentinel, before it is registered.
# The source is chosen by monitoring the master, so a sentinel must only start
# monitoring once its ACL is complete: if this sync fails, the rebuilt sentinel
# stays unregistered and can never be picked as the source of a later run.
# Without REBUILD_SENTINEL_POD_NAME there is nothing to do: a sync across the
# whole fleet would delete accounts from every sentinel that the chosen source
# happens to lack.
#
# The copy itself is copy_sentinel_acl from falkordb-sent-member-join.sh, so a
# rebuilt sentinel ends up exactly like a joining one.

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

load_libraries() {
  # the ops pod writes both files before it runs this script.
  # shellcheck disable=SC1091
  source /scripts/common.sh
  # Only the functions: the member-join main stops at its __SOURCED__ guard.
  # shellcheck disable=SC1091
  __SOURCED__=1 source /scripts/falkordb-sent-member-join.sh
}

sentinel_master_name() {
  if is_empty "$CUSTOM_SENTINEL_MASTER_NAME"; then
    echo "$REDIS_COMPONENT_NAME"
  else
    echo "$CUSTOM_SENTINEL_MASTER_NAME"
  fi
}

rebuilt_sentinel_pod_fqdn() {
  local fqdn
  while IFS= read -r fqdn; do
    if [[ "$fqdn" == "$REBUILD_SENTINEL_POD_NAME."* ]]; then
      echo "$fqdn"
      return 0
    fi
  done < <(echo "$SENTINEL_POD_FQDN_LIST" | tr ',' '\n')
  return 1
}

# A peer that monitors the master went through registration or memberJoin, so
# it holds the fleet's accounts. Another sentinel that was rebuilt too and not
# recovered yet monitors nothing and would hand over an empty ACL.
# Fails with the reason on stdout when the peer does not monitor the master or
# cannot be asked: redis-cli exits 0 for an error reply such as NOAUTH, so the
# reply is checked as well as the exit status.
is_established_sentinel() {
  local host="$1"
  local master="$2"
  local addr
  if ! addr=$(sentinel_cli_argv "$host" SENTINEL get-master-addr-by-name "$master" 2>&1); then
    echo "it cannot be reached: $addr"
    return 1
  fi
  if is_error_reply "$addr" || [[ "$addr" == "AUTH failed"* ]]; then
    echo "it answered with an error: $addr"
    return 1
  fi
  if is_empty "$addr" || equals "$addr" "(nil)"; then
    echo "it does not monitor $master"
    return 1
  fi
}

# The lexicographically smallest established sentinel other than the rebuilt one,
# the same source choice as memberJoin. Returns 1 when every peer answered and
# none monitors the master, and 2 when none was established but some could not
# be asked.
established_peer_sentinel() {
  local target="$1"
  local master="$2"
  local peer reason unanswered=0
  while IFS= read -r peer; do
    if is_empty "$peer" || equals "$peer" "$target"; then
      continue
    fi
    if reason=$(is_established_sentinel "$peer" "$master"); then
      echo "$peer"
      return 0
    fi
    echo "not copying the ACL from sentinel $peer, $reason." >&2
    if [[ "$reason" != "it does not monitor"* ]]; then
      unanswered=$((unanswered + 1))
    fi
  done < <(echo "$SENTINEL_POD_FQDN_LIST" | tr ',' '\n' | LC_ALL=C sort)
  if [ "$unanswered" -gt 0 ]; then
    return 2
  fi
  return 1
}

sync_acl_to_rebuilt_sentinel() {
  if is_empty "$REBUILD_SENTINEL_POD_NAME"; then
    echo "REBUILD_SENTINEL_POD_NAME is not set, no rebuilt sentinel to sync the ACL to."
    return 0
  fi
  if is_empty "$SENTINEL_POD_FQDN_LIST"; then
    echo "Error: Required environment variable SENTINEL_POD_FQDN_LIST is not set." >&2
    return 1
  fi

  local target
  if ! target=$(rebuilt_sentinel_pod_fqdn); then
    echo "Error: sentinel pod $REBUILD_SENTINEL_POD_NAME is not in SENTINEL_POD_FQDN_LIST: $SENTINEL_POD_FQDN_LIST" >&2
    return 1
  fi

  local master source_host status=0
  master=$(sentinel_master_name)
  source_host=$(established_peer_sentinel "$target" "$master") || status=$?
  case $status in
    1)
      # every sentinel lost its state, none holds an ACL worth copying. The
      # registration that follows still has to run, or the fleet can never recover.
      echo "Warning: no other sentinel monitors $master, there is no ACL to copy onto $target. Accounts created through falkordb-sent-account-ops have to be created again."
      return 0
      ;;
    2)
      echo "Error: no reachable sentinel is established for $master and some could not be asked, not copying an ACL onto $target. Retry once the sentinels are reachable." >&2
      return 1
      ;;
  esac

  # the rebuilt pod may still be starting, it has not been registered yet.
  wait_for_joining_sentinel "$target" || return 1
  copy_sentinel_acl "$source_host" "$source_host" "$target"
}

# This is magic for shellspec ut framework.
# Sometime, functions are defined in a single shell script.
# You will want to test it. but you do not want to run the script.
# When included from shellspec, __SOURCED__ variable defined and script
# end here. The script path is assigned to the __SOURCED__ variable.
${__SOURCED__:+false} : || return 0

# main
load_libraries
sync_acl_to_rebuilt_sentinel

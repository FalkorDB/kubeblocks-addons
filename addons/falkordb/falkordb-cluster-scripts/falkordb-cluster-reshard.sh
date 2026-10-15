#!/bin/bash

# Moves the given hash slots of a sharded FalkorDB cluster to another shard.
# Run by the falkordb-cluster-reshard OpsDefinition.
#
# Parameters, passed by KubeBlocks as environment variables:
#   SLOTS  the slots to move: single slots and inclusive ranges, separated by
#          commas or spaces, e.g. "0-999,5000,6000-6099"
#   TO     the shard to give them to: its short name (shard-98x), its full
#          component name (<cluster>-shard-98x) or the node ID of its primary
#   FROM   optional. When set, every slot in SLOTS must be owned by this shard
#          and the operation is refused otherwise, so a caller working from a
#          stale view of the slot map cannot take slots from the wrong shard.
#
# `redis-cli --cluster reshard` only takes a number of slots and picks which
# ones itself, so it cannot move a given range. This script runs the same
# per-slot protocol it does instead:
#   1. CLUSTER SETSLOT <slot> IMPORTING <source> on the target
#   2. CLUSTER SETSLOT <slot> MIGRATING <target> on the source
#   3. MIGRATE the slot's keys from the source to the target, until none is left
#   4. CLUSTER SETSLOT <slot> NODE <target> on the target, the source and then
#      every other primary
# It talks to every node at the address the node announces in CLUSTER NODES,
# the way redis-cli does, so it works the same over TLS and host networking.
#
# A slot that already belongs to TO is left alone, so running the same request
# twice is harmless. A move that fails half way leaves slots open, and the
# script refuses to start on a cluster with open slots: repair it with
# `redis-cli --cluster fix` first. That is also why the action runs with
# backoffLimit 0, a blind retry would only be refused.
#
# The OpsRequest targets the sharding, and with `multiPodSelectionPolicy: Any`
# KubeBlocks runs the action exactly once, on the first available pod across
# every shard (getTargetPods in pkg/operations/custom/utils.go). The slots can
# belong to any shard, so the pod is only used as an entry point.
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

TOTAL_SLOTS=16384
# Slots are opened and closed in batches, so a failure leaves at most this
# many of them open for `--cluster fix` to deal with.
SLOT_BATCH_SIZE=${SLOT_BATCH_SIZE:-100}
# The same defaults `redis-cli --cluster reshard` uses for --cluster-pipeline
# and --cluster-timeout. A graph is a single key, so a large one takes a while.
MIGRATE_KEYS_PER_CALL=${MIGRATE_KEYS_PER_CALL:-10}
MIGRATE_TIMEOUT_MS=${MIGRATE_TIMEOUT_MS:-60000}

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

# node_cli <host:port> <redis-cli args...>
node_cli() {
  local endpoint="$1"
  shift
  falkordb_cli -h "${endpoint%:*}" -p "${endpoint##*:}" "$@"
}

# node_pipe <host:port>
# Sends the commands on stdin to the node, one per line, and prints one reply
# per line. Lines are parsed the way redis-cli parses its prompt, so an
# argument can be double quoted with C-style escapes.
node_pipe() {
  node_cli "$1"
}

# node_setslot <host:port> <what> <IMPORTING|MIGRATING|NODE> <node id> <slot...>
# Sends CLUSTER SETSLOT <slot> <state> <node id> for every slot in a single
# `redis-cli --pipe` stream. A node saves and fsyncs its nodes.conf after a
# SETSLOT NODE, but only once per batch of commands it reads together, so one
# command at a time would cost an fsync per slot.
node_setslot() {
  local endpoint="$1" what="$2" state="$3" node_id="$4" slot output
  shift 4
  output=$(for slot in "$@"; do
    # shellcheck disable=SC2016 # the $ is RESP's bulk string marker
    printf '*5\r\n$7\r\nCLUSTER\r\n$7\r\nSETSLOT\r\n$%d\r\n%s\r\n$%d\r\n%s\r\n$%d\r\n%s\r\n' \
      "${#slot}" "$slot" "${#state}" "$state" "${#node_id}" "$node_id"
  done | node_cli "$endpoint" --pipe 2>&1 | tr -d '\r')
  if [[ "$output" != *"errors: 0, replies: $#"* ]]; then
    echo "Error: $what:" >&2
    echo "$output" | head -20 >&2
    return 1
  fi
}

# quote_arg <string>
# Prints the string double quoted for redis-cli's command line parser.
quote_arg() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '"%s"' "$s"
}

# parse_slots <spec>
# Prints every slot named by the spec once, in ascending order, one per line.
parse_slots() {
  local spec="$1" item start end slot
  local -a wanted=()
  local -a items
  read -r -a items <<< "${spec//,/ }"
  if [ ${#items[@]} -eq 0 ]; then
    echo "Error: SLOTS is empty, expected slots or ranges such as 0-999,5000" >&2
    return 1
  fi
  for item in "${items[@]}"; do
    # at most 5 digits, so a huge number cannot overflow the arithmetic below
    if [[ "$item" =~ ^([0-9]{1,5})$ ]]; then
      start=$((10#${BASH_REMATCH[1]}))
      end=$start
    elif [[ "$item" =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]]; then
      start=$((10#${BASH_REMATCH[1]}))
      end=$((10#${BASH_REMATCH[2]}))
    elif [[ "$item" =~ ^[0-9]+(-[0-9]+)?$ ]]; then
      echo "Error: slot range '$item' is out of bounds, slots go from 0 to $((TOTAL_SLOTS - 1))" >&2
      return 1
    else
      echo "Error: invalid slot or range '$item' in SLOTS, expected a slot such as 5000 or a range such as 0-999" >&2
      return 1
    fi
    if [ "$start" -ge "$TOTAL_SLOTS" ] || [ "$end" -ge "$TOTAL_SLOTS" ]; then
      echo "Error: slot range '$item' is out of bounds, slots go from 0 to $((TOTAL_SLOTS - 1))" >&2
      return 1
    fi
    if [ "$start" -gt "$end" ]; then
      echo "Error: slot range '$item' ends before it starts" >&2
      return 1
    fi
    for ((slot = start; slot <= end; slot++)); do
      wanted[slot]=1
    done
  done
  for slot in "${!wanted[@]}"; do
    echo "$slot"
  done
}

# load_cluster_nodes <host:port>
# Reads CLUSTER NODES from the node into CLUSTER_NODES.
load_cluster_nodes() {
  local endpoint="$1"
  CLUSTER_NODES=$(node_cli "$endpoint" CLUSTER NODES | tr -d '\r')
  # an error reply such as NOAUTH also exits 0, but a real map always has the
  # node's own `myself` line
  if ! echo "$CLUSTER_NODES" | awk '$3 ~ /myself/ {found = 1} END {exit !found}'; then
    echo "Error: could not read the cluster nodes from $endpoint: ${CLUSTER_NODES:-<empty reply>}" >&2
    return 1
  fi
}

# check_cluster_healthy <host:port>
# Refuses a cluster that is not ok, does not cover every slot, has slots open
# or has nodes that disagree about the slot map. Moving slots on top of any of
# that would make it worse.
check_cluster_healthy() {
  local endpoint="$1" info state check
  info=$(node_cli "$endpoint" CLUSTER INFO | tr -d '\r')
  state=$(echo "$info" | awk -F: '/^cluster_state:/ {print $2; exit}')
  if [ "$state" != "ok" ]; then
    echo "Error: cluster_state is '${state:-unknown}', refusing to move slots on a cluster that is not ok" >&2
    return 1
  fi
  check=$(falkordb_cli --cluster check "$endpoint" 2>&1)
  if [[ "$check" != *"All $TOTAL_SLOTS slots covered"* ]] || \
     [[ "$check" == *"[ERR]"* ]] || \
     [[ "$check" == *"[WARNING] The following slots are open"* ]] || \
     [[ "$check" == *"has slots in importing state"* ]] || \
     [[ "$check" == *"has slots in migrating state"* ]]; then
    echo "Error: the cluster is not stable, refusing to move slots. Repair it with \`redis-cli --cluster fix\` first:" >&2
    echo "$check" >&2
    return 1
  fi
}

is_node_id() {
  [[ "$1" =~ ^[0-9a-f]{40}$ ]]
}

# node_line <node id>
node_line() {
  echo "$CLUSTER_NODES" | awk -v id="$1" '$1 == id {print; exit}'
}

# node_address <node id>
# Prints the host:port the node announces, without the bus port or hostname.
node_address() {
  node_line "$1" | awk '{split($2, a, "@"); print a[1]}'
}

# primary_of <node id>
# Prints the node itself when it is a healthy primary, its primary when it is
# a replica, and fails otherwise.
primary_of() {
  local id="$1" line flags
  line=$(node_line "$id")
  if [ -z "$line" ]; then
    return 1
  fi
  flags=$(echo "$line" | awk '{print $3}')
  if [[ ",$flags," == *",fail,"* ]] || [[ ",$flags," == *",fail?,"* ]] || [[ ",$flags," == *",handshake,"* ]]; then
    return 1
  fi
  if [[ ",$flags," == *",master,"* ]]; then
    echo "$id"
  elif [[ ",$flags," == *",slave,"* ]]; then
    primary_of "$(echo "$line" | awk '{print $4}')"
  else
    return 1
  fi
}

# shard_primary_by_hostname <shard>
# Finds the shard's primary among the nodes whose announced hostname is a pod
# of that shard, <pod>.<shard>-headless.<namespace>.svc... Prints nothing when
# no node announces such a hostname.
shard_primary_by_hostname() {
  local shard="$1" ids id primary found=""
  # the address field is ip:port@bus[,hostname][,aux=value...]
  ids=$(echo "$CLUSTER_NODES" | awk -v suffix=".$shard-headless." '{
    n = split($2, parts, ",")
    if (n >= 2 && parts[2] !~ /=/ && index(parts[2], suffix) > 0) print $1
  }')
  for id in $ids; do
    primary=$(primary_of "$id") || continue
    if [ -n "$found" ] && [ "$found" != "$primary" ]; then
      echo "Error: the nodes of shard $shard report different primaries, $found and $primary" >&2
      return 1
    fi
    found="$primary"
  done
  echo "$found"
}

# shard_primary_by_service <shard>
# Asks a pod of the shard, through the shard's headless service, for its own
# node ID. Used when nodes announce a hostname override instead of their pod
# FQDN, so the hostnames in CLUSTER NODES do not name the shard.
shard_primary_by_service() {
  local shard="$1" endpoint id
  endpoint="$shard-headless.$CLUSTER_NAMESPACE.svc.$CLUSTER_DOMAIN:${SERVICE_PORT:-6379}"
  id=$(node_cli "$endpoint" CLUSTER MYID 2>/dev/null | tr -d '\r')
  if ! is_node_id "$id"; then
    return 1
  fi
  primary_of "$id"
}

# resolve_primary <FROM|TO> <shard name or node id>
# Prints the node ID of the primary that currently serves the shard. A shard
# name is looked up anew every time, because a failover changes which node
# that is. The ALL_SHARDS_* variables are fixed when a pod starts and go stale
# after a scale-out or scale-in, so they are not used.
resolve_primary() {
  local param="$1" value="$2" primary
  if is_node_id "$value"; then
    if [ -z "$(node_line "$value")" ]; then
      echo "Error: $param is $value, but no node with that ID is in the cluster" >&2
      return 1
    fi
    if ! primary=$(primary_of "$value") || [ "$primary" != "$value" ]; then
      echo "Error: $param is $value, which is not a healthy primary; name its shard or its primary instead" >&2
      return 1
    fi
    echo "$value"
    return 0
  fi
  if ! [[ "$value" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
    echo "Error: $param is '$value', which is neither a shard name nor a node ID" >&2
    return 1
  fi
  # a short name such as shard-98x is the component <cluster>-shard-98x
  local -a names=("$value")
  if [ -n "$CLUSTER_NAME" ] && [[ "$value" != "$CLUSTER_NAME"-* ]]; then
    names=("$CLUSTER_NAME-$value" "$value")
  fi
  local name
  primary=""
  for name in "${names[@]}"; do
    primary=$(shard_primary_by_hostname "$name") || return 1
    [ -n "$primary" ] && break
  done
  if [ -z "$primary" ]; then
    for name in "${names[@]}"; do
      primary=$(shard_primary_by_service "$name") && break
      primary=""
    done
  fi
  if [ -z "$primary" ]; then
    echo "Error: $param is '$value', but no healthy primary of a shard by that name is in the cluster" >&2
    return 1
  fi
  echo "$primary"
}

# load_slot_owners
# Fills SLOT_OWNER[slot] with the node ID of the primary that owns the slot.
load_slot_owners() {
  local id slot start end range
  SLOT_OWNER=()
  while read -r id range; do
    if [[ "$range" == *-* ]]; then
      start=${range%-*}
      end=${range#*-}
    else
      start=$range
      end=$range
    fi
    for ((slot = start; slot <= end; slot++)); do
      SLOT_OWNER[slot]=$id
    done
  done < <(echo "$CLUSTER_NODES" | awk '$3 ~ /master/ {
    # [slot->-id] and [slot-<-id] are migrations in flight, not ownership
    for (i = 9; i <= NF; i++) if ($i !~ /^\[/) print $1, $i
  }')
}

# other_primaries <node id...>
# Prints every healthy primary except the given ones.
other_primaries() {
  local exclude=" $* "
  echo "$CLUSTER_NODES" | awk -v exclude="$exclude" \
    '$3 ~ /master/ && $3 !~ /fail/ && index(exclude, " " $1 " ") == 0 {print $1}'
}

# migrate_slot_keys <source id> <target id> <slot>
# Moves every key of the slot from the source to the target with MIGRATE.
migrate_slot_keys() {
  local source_id="$1" target_id="$2" slot="$3"
  local source target_address target_host target_port listing previous="" reply auth
  local -a keys
  source=$(node_address "$source_id")
  target_address=$(node_address "$target_id")
  target_host=${target_address%:*}
  target_port=${target_address##*:}
  # MIGRATE authenticates to the target itself, so the credentials have to be
  # part of the command. They go to redis-cli on stdin, not in its arguments.
  auth=""
  if [ -n "$REDIS_DEFAULT_PASSWORD" ]; then
    if [ -n "$REDIS_DEFAULT_USER" ]; then
      auth="AUTH2 $(quote_arg "$REDIS_DEFAULT_USER") $(quote_arg "$REDIS_DEFAULT_PASSWORD")"
    else
      auth="AUTH $(quote_arg "$REDIS_DEFAULT_PASSWORD")"
    fi
  fi
  while true; do
    # --csv prints the keys quoted and escaped the way the stdin parser reads
    # them back, so a key with a space, a quote or a newline survives the trip
    # a connection, TLS or auth failure also prints nothing, so an empty
    # listing only counts once redis-cli has exited cleanly
    if ! listing=$(node_cli "$source" --csv CLUSTER GETKEYSINSLOT "$slot" "$MIGRATE_KEYS_PER_CALL"); then
      echo "Error: could not list the keys of slot $slot on $source: $listing" >&2
      return 1
    fi
    listing=$(echo "$listing" | tr -d '\r')
    if [ -z "$listing" ]; then
      return 0
    fi
    if [[ "$listing" != \"* ]]; then
      echo "Error: could not list the keys of slot $slot on $source: $listing" >&2
      return 1
    fi
    if [ "$listing" = "$previous" ]; then
      echo "Error: the keys of slot $slot did not leave $source: $listing" >&2
      return 1
    fi
    keys=()
    local rest="$listing"
    while [[ "$rest" =~ ^(\"([^\"\\]|\\.)*\")(,|$) ]]; do
      keys+=("${BASH_REMATCH[1]}")
      rest=${rest:${#BASH_REMATCH[0]}}
    done
    if [ -n "$rest" ] || [ ${#keys[@]} -eq 0 ]; then
      echo "Error: could not parse the keys of slot $slot listed by $source: $listing" >&2
      return 1
    fi
    reply=$(echo "MIGRATE $target_host $target_port \"\" 0 $MIGRATE_TIMEOUT_MS $auth KEYS ${keys[*]}" |
      node_pipe "$source" | tr -d '\r' | grep -v '^$')
    if [ "$reply" != "OK" ] && [ "$reply" != "NOKEY" ]; then
      echo "Error: could not migrate the keys of slot $slot from $source to $target_address: $reply" >&2
      if [[ "$reply" == *BUSYKEY* ]]; then
        echo "The target already holds a key of the same name. Resolve the conflict and run \`redis-cli --cluster fix\`." >&2
      fi
      return 1
    fi
    previous="$listing"
  done
}

# count_slot_keys <host:port> <slot...>
# Prints the number of keys the node holds in each slot, one per line, in the
# order given. Prints nothing and fails unless every count could be read.
count_slot_keys() {
  local endpoint="$1" slot replies
  shift
  replies=$(for slot in "$@"; do
    echo "CLUSTER COUNTKEYSINSLOT $slot"
  done | node_pipe "$endpoint" | tr -d '\r' | grep -v '^$')
  local -a counts
  mapfile -t counts <<< "$replies"
  if [ ${#counts[@]} -ne $# ] || printf '%s\n' "${counts[@]}" | grep -qv '^[0-9][0-9]*$'; then
    echo "Error: could not count the keys of the slots on $endpoint: $(echo "$replies" | head -5)" >&2
    return 1
  fi
  printf '%s\n' "${counts[@]}"
}

# move_slot_batch <source id> <target id> <slot...>
move_slot_batch() {
  local source_id="$1" target_id="$2"
  shift 2
  local -a batch_slots=("$@")
  local source target other
  source=$(node_address "$source_id")
  target=$(node_address "$target_id")

  node_setslot "$target" "mark slots importing on $target" IMPORTING "$source_id" "${batch_slots[@]}" || return 1
  node_setslot "$source" "mark slots migrating on $source" MIGRATING "$target_id" "${batch_slots[@]}" || return 1

  # count first, so empty slots cost nothing more than the SETSLOT calls
  local -a counts
  mapfile -t counts < <(count_slot_keys "$source" "${batch_slots[@]}")
  if [ ${#counts[@]} -ne ${#batch_slots[@]} ]; then
    return 1
  fi
  local i
  for i in "${!batch_slots[@]}"; do
    if [ "${counts[i]}" -gt 0 ]; then
      migrate_slot_keys "$source_id" "$target_id" "${batch_slots[i]}" || return 1
    fi
  done

  # Giving the target a slot that still has keys on the source loses them:
  # the source drops the keys of a slot it learns it no longer owns. So every
  # slot has to be confirmed empty before any SETSLOT NODE, whatever the
  # migration above reported.
  mapfile -t counts < <(count_slot_keys "$source" "${batch_slots[@]}")
  if [ ${#counts[@]} -ne ${#batch_slots[@]} ]; then
    return 1
  fi
  for i in "${!batch_slots[@]}"; do
    if [ "${counts[i]}" -ne 0 ]; then
      echo "Error: slot ${batch_slots[i]} still holds ${counts[i]} keys on $source after the migration, not assigning it" >&2
      return 1
    fi
  done

  # the target first, so the slot is never owned by nobody, then the source,
  # which has no key left in it
  node_setslot "$target" "assign the slots on $target" NODE "$target_id" "${batch_slots[@]}" || return 1
  node_setslot "$source" "assign the slots on $source" NODE "$target_id" "${batch_slots[@]}" || return 1

  # The others would learn it through gossip, since the target bumped its
  # epoch, but telling them closes the window where they still redirect
  # clients to the source. A node that cannot be told here still catches up.
  for other in $(other_primaries "$source_id" "$target_id"); do
    node_setslot "$(node_address "$other")" "assign the slots on $(node_address "$other")" NODE "$target_id" "${batch_slots[@]}" ||
      echo "Warning: $(node_address "$other") will learn the new owner through gossip instead" >&2
  done
}

# format_ranges <slot...>
# Prints ascending slots as compact ranges, e.g. 0-99,200.
format_ranges() {
  local out="" start="" prev="" slot
  for slot in "$@"; do
    if [ -n "$prev" ] && [ "$slot" -eq $((prev + 1)) ]; then
      prev=$slot
      continue
    fi
    if [ -n "$start" ]; then
      [ "$start" -eq "$prev" ] && out+="$start," || out+="$start-$prev,"
    fi
    start=$slot
    prev=$slot
  done
  if [ -n "$start" ]; then
    [ "$start" -eq "$prev" ] && out+="$start" || out+="$start-$prev"
  fi
  echo "${out%,}"
}

reshard() {
  local entry slot owner from_id="" to_id source batch_start
  local -a requested=() to_move=() wrong_owner=()

  if [ -z "$TO" ]; then
    echo "Error: TO is required, the shard to move the slots to" >&2
    return 1
  fi
  local slot_list
  slot_list=$(parse_slots "$SLOTS") || return 1
  mapfile -t requested <<< "$slot_list"

  entry=$(build_node_endpoint)
  echo "move slots $(format_ranges "${requested[@]}") to $TO${FROM:+ from $FROM} via node: $entry"

  check_cluster_healthy "$entry" || return 1
  load_cluster_nodes "$entry" || return 1

  to_id=$(resolve_primary TO "$TO") || return 1
  if [ -n "$FROM" ]; then
    from_id=$(resolve_primary FROM "$FROM") || return 1
    if [ "$from_id" = "$to_id" ]; then
      echo "Error: FROM ($FROM) and TO ($TO) are the same shard, primary $to_id" >&2
      return 1
    fi
  fi
  echo "TO $TO is primary $to_id at $(node_address "$to_id")"
  [ -n "$from_id" ] && echo "FROM $FROM is primary $from_id at $(node_address "$from_id")"

  load_slot_owners
  local -A by_source=()
  for slot in "${requested[@]}"; do
    owner=${SLOT_OWNER[slot]}
    if [ -z "$owner" ]; then
      echo "Error: slot $slot has no owner" >&2
      return 1
    fi
    if [ "$owner" = "$to_id" ]; then
      continue
    fi
    if [ -n "$from_id" ] && [ "$owner" != "$from_id" ]; then
      wrong_owner+=("$slot")
      continue
    fi
    to_move+=("$slot")
    by_source[$owner]+="$slot "
  done
  if [ ${#wrong_owner[@]} -gt 0 ]; then
    echo "Error: FROM is $FROM, but it does not own slots $(format_ranges "${wrong_owner[@]}"); nothing was moved" >&2
    return 1
  fi
  if [ ${#to_move[@]} -eq 0 ]; then
    echo "every requested slot already belongs to $TO, nothing to move"
    return 0
  fi
  echo "moving ${#to_move[@]} slots, $((${#requested[@]} - ${#to_move[@]})) already belong to $TO"

  local -a source_slots
  for source in "${!by_source[@]}"; do
    read -r -a source_slots <<< "${by_source[$source]}"
    echo "moving slots $(format_ranges "${source_slots[@]}") from $source at $(node_address "$source")"
    for ((batch_start = 0; batch_start < ${#source_slots[@]}; batch_start += SLOT_BATCH_SIZE)); do
      if ! move_slot_batch "$source" "$to_id" "${source_slots[@]:batch_start:SLOT_BATCH_SIZE}"; then
        echo "Error: moving slots from $source failed, the cluster may have open slots. Check it with \`redis-cli --cluster check\` and repair it with \`redis-cli --cluster fix\`." >&2
        return 1
      fi
    done
  done

  # every slot must now belong to TO in the target's own view
  load_cluster_nodes "$(node_address "$to_id")" || return 1
  load_slot_owners
  local -a missing=()
  for slot in "${requested[@]}"; do
    [ "${SLOT_OWNER[slot]}" = "$to_id" ] || missing+=("$slot")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    echo "Error: $TO does not own slots $(format_ranges "${missing[@]}") after the move" >&2
    return 1
  fi
  echo "moved ${#to_move[@]} slots to $TO, primary $to_id"
}

# This is magic for shellspec ut framework.
# Sometime, functions are defined in a single shell script.
# You will want to test it. but you do not want to run the script.
# When included from shellspec, __SOURCED__ variable defined and script
# end here. The script path is assigned to the __SOURCED__ variable.
${__SOURCED__:+false} : || return 0

# main
reshard

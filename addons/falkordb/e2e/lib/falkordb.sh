#!/bin/bash
# Shared helpers for the FalkorDB chainsaw e2e scenarios.
#
# Source this from a scenario script:
#   . "$E2E_LIB_DIR/falkordb.sh"
#
# Every helper talks to FalkorDB by exec'ing redis-cli *inside* the target pod and
# reading the password from the container's own REDIS_DEFAULT_PASSWORD env var, so
# no credential is ever passed on a command line or copied out of the cluster.
#
# Keep this file POSIX sh: chainsaw runs every `script:` block through /bin/sh,
# which is bash on macOS but dash on the Ubuntu CI runners.

# `pipefail` is not in POSIX, and dash aborts the whole script on an unknown
# `set -o` option, so ask for it only where it exists.
if (set -o pipefail) 2>/dev/null; then
  set -o pipefail
fi
set -eu

# Container name inside a FalkorDB pod. Sharding pods use a different one.
FDB_CONTAINER="${FDB_CONTAINER:-falkordb}"
# Container name inside a sentinel pod.
FDB_SENTINEL_CONTAINER="${FDB_SENTINEL_CONTAINER:-falkordb-sent}"
# Extra flags appended to every redis-cli invocation, e.g. "-c" for cluster mode
# or the --tls family for a TLS-enabled cluster.
FDB_CLI_FLAGS="${FDB_CLI_FLAGS:-}"
# Default number of attempts / delay used by the retry helpers.
FDB_RETRIES="${FDB_RETRIES:-60}"
FDB_RETRY_DELAY="${FDB_RETRY_DELAY:-5}"

fdb_log() {
  echo "[e2e] $*"
}

fdb_fail() {
  echo "[e2e][FAIL] $*" >&2
  return 1
}

# fdb_state_dir
# Prints (creating it if needed) a scratch directory scoped to the current test
# namespace. Chainsaw runs every script step in a fresh shell, so scenarios that
# need to carry a value from one step to the next park it here.
fdb_state_dir() {
  local dir="${TMPDIR:-/tmp}/falkordb-e2e-${NAMESPACE:-default}"
  mkdir -p "$dir"
  echo "$dir"
}

# fdb_clean_state_dir
# Removes the scratch directory for the current test namespace.
fdb_clean_state_dir() {
  local dir="${TMPDIR:-/tmp}/falkordb-e2e-${NAMESPACE:-default}"
  rm -rf "$dir"
}

# fdb_cli <namespace> <pod> <redis command...>
# Runs a redis-cli command in the given pod and prints the reply on stdout.
fdb_cli() {
  local namespace="$1" pod="$2"
  shift 2
  # The command travels as arguments to redis-cli inside the pod; the password is
  # taken from the container environment and never appears in argv.
  kubectl exec -n "$namespace" "$pod" -c "$FDB_CONTAINER" -- \
    sh -c 'REDISCLI_AUTH="$REDIS_DEFAULT_PASSWORD" exec redis-cli '"$FDB_CLI_FLAGS"' "$@"' _ "$@"
}

# fdb_sentinel_cli <namespace> <pod> <sentinel command...>
# Runs a redis-cli command against the sentinel in the given pod. Sentinel has its
# own account, so it needs different credentials from the servers it monitors.
fdb_sentinel_cli() {
  local namespace="$1" pod="$2"
  shift 2
  kubectl exec -n "$namespace" "$pod" -c "$FDB_SENTINEL_CONTAINER" -- \
    sh -c 'REDISCLI_AUTH="$SENTINEL_PASSWORD" exec redis-cli \
      -p "${SENTINEL_SERVICE_PORT:-26379}" --user "$SENTINEL_USER" '"$FDB_CLI_FLAGS"' "$@"' _ "$@"
}

# fdb_assert_sentinel_monitoring <namespace> <pod>
# Fails unless the sentinel answers SENTINEL masters with at least one master.
#
# redis-cli exits 0 even when the server rejects the command, so a naive check
# treats "WRONGPASS ..." as a successful reply. The body has to be inspected.
fdb_assert_sentinel_monitoring() {
  local namespace="$1" pod="$2" reply masters
  reply="$(fdb_sentinel_cli "$namespace" "$pod" SENTINEL masters 2>&1 | tr -d '\r')"
  case "$reply" in
    "" | *WRONGPASS* | *NOAUTH* | *NOPERM* | *"ERR "* | *"Error:"* | *"Connection refused"*)
      fdb_fail "$pod did not answer SENTINEL masters: ${reply:-<empty reply>}"
      return 1
      ;;
  esac
  # SENTINEL masters returns a flat array; every monitored master contributes a
  # line holding exactly the field name "name".
  masters="$(echo "$reply" | grep -c '^name$' || true)"
  if [ "$masters" -lt 1 ]; then
    fdb_fail "$pod monitors no master: $reply"
    return 1
  fi
  fdb_log "$pod is monitoring $masters master(s)"
}

# fdb_assert_sentinel_peers <namespace> <pod> <expected>
# Fails unless <pod> has discovered exactly <expected> other sentinels.
#
# Monitoring the master is not enough to make a sentinel useful. Leader election
# needs a majority of the whole sentinel set, and a sentinel that has not yet
# discovered its peers votes for itself: with five sentinels and no shared view
# the votes split, every attempt ends in -failover-abort-not-elected, and the
# promotion simply never happens. Waiting for discovery to converge before
# killing the primary is the difference between testing failover and testing
# gossip timing.
fdb_assert_sentinel_peers() {
  local namespace="$1" pod="$2" expected="$3" reply known
  reply="$(fdb_sentinel_cli "$namespace" "$pod" SENTINEL masters 2>&1 | tr -d '\r')"
  known="$(echo "$reply" | grep -A1 '^num-other-sentinels$' | tail -1)"
  case "$known" in
    '' | *[!0-9]*)
      fdb_fail "$pod did not report num-other-sentinels: ${reply:-<empty reply>}"
      return 1
      ;;
  esac
  if [ "$known" -ne "$expected" ]; then
    fdb_fail "$pod knows $known other sentinels, expected $expected"
    return 1
  fi
  fdb_log "$pod knows $known other sentinels"
}

# fdb_sentinel_relax_failover_cooldown <namespace> <cluster> <sentinel-component> <master> [timeout_ms]
# Shortens `failover-timeout` for <master> on every sentinel of a cluster.
#
# Sentinel refuses to start another failover for `failover-timeout * 2` after the
# previous attempt, and the addon configures 60000ms, so the cooldown is two
# minutes. Anything that takes the whole cluster down - a Stop/Start, a rolling
# restart - makes every sentinel observe the master +odown and arms that window.
# A kill inside it is simply ignored: the pod comes back as `+reboot master` and
# no election ever happens. Shrinking the window lets a test assert that failover
# still works without waiting the cooldown out, and if a failover does abort the
# retry comes round twice as fast too.
fdb_sentinel_relax_failover_cooldown() {
  local namespace="$1" cluster="$2" component="$3" master="$4" ms="${5:-20000}"
  local pod reply
  for pod in $(fdb_pods "$namespace" "$cluster" "$component"); do
    reply="$(fdb_sentinel_cli "$namespace" "$pod" SENTINEL set "$master" failover-timeout "$ms" 2>&1 | tr -d '\r')"
    case "$reply" in
      OK) fdb_log "$pod failover-timeout for $master set to ${ms}ms" ;;
      *)
        fdb_fail "$pod refused SENTINEL set $master failover-timeout: ${reply:-<empty reply>}"
        return 1
        ;;
    esac
  done
}

# fdb_sentinel_master_count <namespace> <pod>
# Prints how many masters the sentinel monitors. Unlike
# fdb_assert_sentinel_monitoring it does not treat zero as a failure, so it can
# assert that a sentinel monitors nothing. Fails when the sentinel cannot answer:
# an unreachable sentinel must not pass for one that monitors nothing.
fdb_sentinel_master_count() {
  local namespace="$1" pod="$2" reply status=0
  reply="$(fdb_sentinel_cli "$namespace" "$pod" SENTINEL masters 2>&1)" || status=$?
  reply="$(echo "$reply" | tr -d '\r')"
  if [ "$status" -ne 0 ]; then
    fdb_fail "$pod could not be asked for SENTINEL masters (exit $status): $reply"
    return 1
  fi
  case "$reply" in
    *WRONGPASS* | *NOAUTH* | *NOPERM* | *"ERR "* | *"Error:"* | *"Could not connect"* | *"Connection refused"*)
      fdb_fail "$pod did not answer SENTINEL masters: $reply"
      return 1
      ;;
  esac
  echo "$reply" | grep -c '^name$' || true
}

# fdb_sentinel_master_addr <namespace> <pod> <master>
# Prints `<host> <port>` of the master the sentinel monitors under that name, and
# fails when it does not monitor it or cannot answer. Anything but exactly a host
# and a numeric port is a failure, so two pods failing the same way never compare
# equal.
fdb_sentinel_master_addr() {
  local namespace="$1" pod="$2" master="$3" addr status=0 port
  addr="$(fdb_sentinel_cli "$namespace" "$pod" SENTINEL get-master-addr-by-name "$master" 2>&1)" || status=$?
  addr="$(echo "$addr" | tr -d '\r' | paste -sd' ' -)"
  if [ "$status" -ne 0 ]; then
    fdb_fail "$pod could not be asked for the address of $master (exit $status): $addr"
    return 1
  fi
  port="${addr#* }"
  case "$port" in
    '' | *[!0-9]*) port="" ;;
  esac
  if [ "$(echo "$addr" | wc -w)" -ne 2 ] || [ -z "$port" ]; then
    fdb_fail "$pod does not report an address for $master: ${addr:-<empty reply>}"
    return 1
  fi
  echo "$addr"
}

# fdb_assert_sentinel_user <namespace> <pod> <user> <password>
# Fails unless the sentinel knows the user and accepts its password. Listing the
# user alone would also pass for one whose password was lost.
fdb_assert_sentinel_user() {
  local namespace="$1" pod="$2" user="$3" password="$4" users out
  users="$(fdb_sentinel_cli "$namespace" "$pod" ACL USERS 2>&1 | tr -d '\r')"
  if ! echo "$users" | grep -qx "$user"; then
    fdb_fail "$pod does not know $user, users are: $users"
    return 1
  fi
  # The password goes over stdin into REDISCLI_AUTH, so it is in no process's
  # arguments, neither kubectl's here nor sh's or redis-cli's in the pod.
  out="$(printf '%s\n' "$password" | kubectl exec -i -n "$namespace" "$pod" -c "$FDB_SENTINEL_CONTAINER" -- \
    sh -c 'IFS= read -r REDISCLI_AUTH; export REDISCLI_AUTH
      exec redis-cli -p "${SENTINEL_SERVICE_PORT:-26379}" --user "$1" '"$FDB_CLI_FLAGS"' PING' \
    _ "$user" 2>&1 | tr -d '\r')"
  case "$out" in
    PONG) fdb_log "$user authenticated against $pod" ;;
    *)
      fdb_fail "$user could not authenticate against $pod: $out"
      return 1
      ;;
  esac
}

# fdb_pods <namespace> <cluster> <component>
# Prints the pod names of a component, one per line, in ordinal order.
fdb_pods() {
  local namespace="$1" cluster="$2" component="$3"
  kubectl get pods -n "$namespace" \
    -l "app.kubernetes.io/instance=$cluster,apps.kubeblocks.io/component-name=$component" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort
}

# fdb_pods_with_role <namespace> <cluster> <component> <role>
# Prints the pods KubeBlocks currently labels with the given role.
fdb_pods_with_role() {
  local namespace="$1" cluster="$2" component="$3" role="$4"
  kubectl get pods -n "$namespace" \
    -l "app.kubernetes.io/instance=$cluster,apps.kubeblocks.io/component-name=$component,kubeblocks.io/role=$role" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort
}

# fdb_primary <namespace> <cluster> <component>
# Prints the single pod labelled primary, failing if there is not exactly one.
fdb_primary() {
  local namespace="$1" cluster="$2" component="$3"
  local pods count
  pods="$(fdb_pods_with_role "$namespace" "$cluster" "$component" primary)"
  count="$(echo "$pods" | grep -c . || true)"
  if [ "$count" -ne 1 ]; then
    fdb_fail "expected exactly 1 primary in $cluster/$component, found $count: $(echo "$pods" | tr '\n' ' ')"
    return 1
  fi
  echo "$pods"
}

# fdb_server_role <namespace> <pod>
# Prints the role FalkorDB itself reports: master or slave.
fdb_server_role() {
  local namespace="$1" pod="$2"
  fdb_cli "$namespace" "$pod" INFO replication |
    tr -d '\r' | awk -F: '/^role:/ {print $2; exit}'
}

# fdb_retry <description> <command...>
# Retries a command until it succeeds or the attempt budget is exhausted.
fdb_retry() {
  local description="$1"
  shift
  local attempt=1
  while [ "$attempt" -le "$FDB_RETRIES" ]; do
    if "$@"; then
      return 0
    fi
    fdb_log "waiting for $description (attempt $attempt/$FDB_RETRIES)"
    attempt=$((attempt + 1))
    sleep "$FDB_RETRY_DELAY"
  done
  fdb_fail "timed out waiting for $description"
  return 1
}

# fdb_write_keys <namespace> <pod> <prefix> <count>
# Writes count keys named <prefix>:<n> whose value is the same as the key.
#
# The loop runs inside the container on purpose. One `kubectl exec` per key
# would mean hundreds of API round-trips, which turns a few-second step into a
# multi-minute one and makes the surrounding timeouts meaningless.
fdb_write_keys() {
  local namespace="$1" pod="$2" prefix="$3" count="$4"
  kubectl exec -n "$namespace" "$pod" -c "$FDB_CONTAINER" -- \
    sh -c 'prefix="$1"; count="$2"; i=0
      while [ "$i" -lt "$count" ]; do
        REDISCLI_AUTH="$REDIS_DEFAULT_PASSWORD" redis-cli '"$FDB_CLI_FLAGS"' \
          SET "$prefix:$i" "$prefix:$i" >/dev/null || exit 1
        i=$((i + 1))
      done' _ "$prefix" "$count"
  fdb_log "wrote $count keys with prefix '$prefix' to $pod"
}

# fdb_verify_keys <namespace> <pod> <prefix> <count>
# Fails unless every key written by fdb_write_keys is readable and intact.
fdb_verify_keys() {
  local namespace="$1" pod="$2" prefix="$3" count="$4"
  if ! kubectl exec -n "$namespace" "$pod" -c "$FDB_CONTAINER" -- \
    sh -c 'prefix="$1"; count="$2"; i=0
      while [ "$i" -lt "$count" ]; do
        value=$(REDISCLI_AUTH="$REDIS_DEFAULT_PASSWORD" redis-cli '"$FDB_CLI_FLAGS"' \
          GET "$prefix:$i" | tr -d "\r")
        if [ "$value" != "$prefix:$i" ]; then
          echo "key $prefix:$i holds [$value], expected [$prefix:$i]" >&2
          exit 1
        fi
        i=$((i + 1))
      done' _ "$prefix" "$count"; then
    fdb_fail "keys with prefix '$prefix' are missing or corrupt on $pod"
    return 1
  fi
  fdb_log "verified $count keys with prefix '$prefix' on $pod"
}

# fdb_assert_role <namespace> <pod> <expected master|slave>
fdb_assert_role() {
  local namespace="$1" pod="$2" expected="$3" actual
  actual="$(fdb_server_role "$namespace" "$pod")"
  if [ "$actual" != "$expected" ]; then
    fdb_fail "$pod reports role '$actual', expected '$expected'"
    return 1
  fi
  fdb_log "$pod reports role '$expected'"
}

# fdb_pod_has_role <namespace> <pod> <expected primary|secondary>
# Checks the role label KubeBlocks maintains from the roleProbe.
fdb_pod_has_role() {
  local namespace="$1" pod="$2" expected="$3" actual
  actual="$(kubectl get pod -n "$namespace" "$pod" \
    -o jsonpath='{.metadata.labels.kubeblocks\.io/role}' 2>/dev/null || true)"
  if [ "$actual" != "$expected" ]; then
    fdb_fail "$pod is labelled '$actual', expected '$expected'"
    return 1
  fi
  fdb_log "$pod is labelled '$expected'"
}

# fdb_assert_replication_up <namespace> <pod>
# Fails unless the replica has a live link to its primary.
fdb_assert_replication_up() {
  local namespace="$1" pod="$2" link
  link="$(fdb_cli "$namespace" "$pod" INFO replication |
    tr -d '\r' | awk -F: '/^master_link_status:/ {print $2; exit}')"
  if [ "$link" != "up" ]; then
    fdb_fail "$pod has master_link_status '$link', expected 'up'"
    return 1
  fi
  fdb_log "$pod replication link is up"
}

# fdb_assert_slots_covered <namespace> <pod>
# Fails unless the sharded cluster reports all 16384 hash slots assigned and ok.
fdb_assert_slots_covered() {
  local namespace="$1" pod="$2" info state assigned
  info="$(fdb_cli "$namespace" "$pod" CLUSTER INFO | tr -d '\r')"
  state="$(echo "$info" | awk -F: '/^cluster_state:/ {print $2; exit}')"
  assigned="$(echo "$info" | awk -F: '/^cluster_slots_assigned:/ {print $2; exit}')"
  if [ "$state" != "ok" ]; then
    fdb_fail "cluster_state is '$state', expected 'ok'"
    return 1
  fi
  if [ "$assigned" != "16384" ]; then
    fdb_fail "cluster_slots_assigned is '$assigned', expected 16384"
    return 1
  fi
  fdb_log "all 16384 slots are assigned and the cluster state is ok"
}

# fdb_assert_shards_own_slots <namespace> <pod> <expected shards>
# Fails unless exactly <expected shards> primaries are in the cluster and each one
# owns its full even share of the 16384 slots, give or take 1%.
#
# fdb_assert_slots_covered alone cannot tell a shard that joined but never got
# its slots: the other shards still cover every slot and the cluster reports ok.
# Every path the addon takes splits the slots evenly: creation and rebalance do
# so to within a slot, and a scale-out reshard gives the new shard exactly its
# share while each old shard keeps its share give or take a slot or two of
# rounding. The 1% slack only absorbs that rounding; a shard whose reshard was
# cut short still fails.
fdb_assert_shards_own_slots() {
  local namespace="$1" pod="$2" expected="$3" nodes size primaries floor
  size="$(fdb_cli "$namespace" "$pod" CLUSTER INFO |
    tr -d '\r' | awk -F: '/^cluster_size:/ {print $2; exit}')"
  if [ "$size" != "$expected" ]; then
    fdb_fail "cluster_size is '$size', expected $expected"
    return 1
  fi

  nodes="$(fdb_primary_slots "$namespace" "$pod")"
  primaries="$(echo "$nodes" | grep -c . || true)"
  if [ "$primaries" -ne "$expected" ]; then
    fdb_fail "found $primaries primaries, expected $expected:"
    echo "$nodes" >&2
    return 1
  fi
  floor=$((16384 / expected - 16384 / expected / 100))
  if echo "$nodes" | awk -v floor="$floor" '$3 < floor {bad = 1} END {exit !bad}'; then
    fdb_fail "a primary owns fewer than $floor slots:"
    echo "$nodes" >&2
    return 1
  fi
  fdb_log "all $expected primaries own at least $floor slots each"
}

# fdb_primary_slots <namespace> <pod>
# Prints `<node id> <address> <slots owned>` for every healthy primary the pod
# knows about, one per line, including primaries that own no slot at all.
fdb_primary_slots() {
  local namespace="$1" pod="$2"
  # CLUSTER NODES: <id> <addr> <flags> <master> <ping> <pong> <epoch> <link> <slot>...
  # A slot field is a single slot or a range; [slot-<-id] entries are in-flight
  # migrations and do not count as owned.
  fdb_cli "$namespace" "$pod" CLUSTER NODES | tr -d '\r' |
    awk '$3 ~ /master/ && $3 !~ /fail/ {
      owned = 0
      for (i = 9; i <= NF; i++) {
        if ($i ~ /^\[/) continue
        n = split($i, r, "-")
        owned += (n == 2) ? r[2] - r[1] + 1 : 1
      }
      print $1, $2, owned
    }'
}

# fdb_node_slots <namespace> <pod> <node id>
# Prints how many slots the given primary owns, as <pod> sees it. Fails when the
# pod knows no healthy primary with that ID.
fdb_node_slots() {
  local namespace="$1" pod="$2" id="$3" owned
  owned="$(fdb_primary_slots "$namespace" "$pod" | awk -v id="$id" '$1 == id {print $3; exit}')"
  if [ -z "$owned" ]; then
    fdb_fail "$pod knows no healthy primary $id"
    return 1
  fi
  echo "$owned"
}

# fdb_assert_slots_balanced <namespace> <pod> <expected primaries>
# Fails unless exactly <expected primaries> primaries share the slots evenly:
# the fullest and the emptiest may differ by at most 1% of a share.
#
# fdb_assert_shards_own_slots only puts a floor under each primary, so one
# primary can still hold far more than its share. Once `--cluster rebalance`
# decides to move anything it moves every primary to its exact share, leaving
# them within a slot or two of each other; the 1% only absorbs that rounding.
fdb_assert_slots_balanced() {
  local namespace="$1" pod="$2" expected="$3" nodes primaries spread limit
  nodes="$(fdb_primary_slots "$namespace" "$pod")"
  primaries="$(echo "$nodes" | grep -c . || true)"
  if [ "$primaries" -ne "$expected" ]; then
    fdb_fail "found $primaries primaries, expected $expected:"
    echo "$nodes" >&2
    return 1
  fi
  spread="$(echo "$nodes" | awk 'NR == 1 {min = $3; max = $3}
    {if ($3 < min) min = $3; if ($3 > max) max = $3}
    END {print max - min}')"
  limit=$((16384 / expected / 100))
  if [ "$spread" -gt "$limit" ]; then
    fdb_fail "primaries differ by $spread slots, more than the $limit a balanced cluster allows:"
    echo "$nodes" >&2
    return 1
  fi
  fdb_log "all $expected primaries are balanced to within $spread slots"
}

# fdb_assert_no_open_slots <namespace> <pod>
# Fails while any slot is still marked migrating or importing.
#
# A slot migration that gives up half way leaves the slot open on both sides.
# Every slot is still assigned, so the cluster reports ok and
# fdb_assert_slots_covered passes, but keys in that slot answer with ASK
# redirects and the next reshard refuses to start until someone runs --cluster fix.
fdb_assert_no_open_slots() {
  local namespace="$1" pod="$2" nodes open
  # Read the map first, so a failed CLUSTER NODES is not mistaken for a map
  # with no migration in it. redis-cli exits 0 on an error reply such as
  # NOAUTH, so the exit status is not enough: a real map always has the
  # node's own `myself` line.
  nodes="$(fdb_cli "$namespace" "$pod" CLUSTER NODES 2>&1 | tr -d '\r')" || true
  if ! echo "$nodes" | awk '$3 ~ /myself/ {found = 1} END {exit !found}'; then
    fdb_fail "$pod did not answer CLUSTER NODES: ${nodes:-<empty reply>}"
    return 1
  fi
  open="$(echo "$nodes" | grep '\[' || true)"
  if [ -n "$open" ]; then
    fdb_fail "$pod still sees slots in migration:"
    echo "$open" >&2
    return 1
  fi
  fdb_log "$pod sees no slot in migration"
}

# fdb_cluster_manager <namespace> <pod> <subcommand> [args...]
# Runs `redis-cli --cluster <subcommand> <pod's node> [args...]` inside the pod,
# addressing the node by the same FQDN the addon's own scripts use.
#
# This is how a scenario puts the slot map into a state the addon never leaves
# it in by itself, to prove the addon's tooling copes with it.
fdb_cluster_manager() {
  local namespace="$1" pod="$2" subcommand="$3" flags
  shift 3
  # `-c` only changes how redis-cli follows redirects for a plain command; the
  # cluster manager has no use for it. Any TLS flags are still needed.
  flags="$(echo " $FDB_CLI_FLAGS " | sed 's/ -c / /g')"
  kubectl exec -n "$namespace" "$pod" -c "$FDB_CONTAINER" -- \
    sh -c 'sub="$1"; shift
      REDISCLI_AUTH="$REDIS_DEFAULT_PASSWORD" exec redis-cli '"$flags"' \
        --cluster "$sub" "$POD_FQDN:$SERVICE_PORT" "$@"' _ "$subcommand" "$@"
}

# fdb_slot_owner <namespace> <pod> <slot>
# Prints the node ID of the primary that owns the slot, as <pod> sees it.
fdb_slot_owner() {
  local namespace="$1" pod="$2" slot="$3"
  fdb_cli "$namespace" "$pod" CLUSTER NODES | tr -d '\r' |
    awk -v slot="$slot" '$3 ~ /master/ {
      for (i = 9; i <= NF; i++) {
        if ($i ~ /^\[/) continue
        n = split($i, r, "-")
        if (n == 1) r[2] = r[1]
        if (slot + 0 >= r[1] + 0 && slot + 0 <= r[2] + 0) {print $1; exit}
      }
    }'
}

# fdb_node_first_range <namespace> <pod> <node id>
# Prints `<start> <end>` of the lowest contiguous slot range the primary owns,
# as <pod> sees it.
fdb_node_first_range() {
  local namespace="$1" pod="$2" id="$3"
  fdb_cli "$namespace" "$pod" CLUSTER NODES | tr -d '\r' |
    awk -v id="$id" '$1 == id {
      start = -1
      for (i = 9; i <= NF; i++) {
        if ($i ~ /^\[/) continue
        n = split($i, r, "-")
        if (n == 1) r[2] = r[1]
        if (start < 0 || r[1] + 0 < start) {start = r[1] + 0; end = r[2] + 0}
      }
      if (start >= 0) print start, end
      exit
    }'
}

# fdb_shard_of_node <namespace> <pod> <cluster> <node id>
# Prints the short name (shard-xyz) of the shard the node belongs to, read
# from the pod FQDN the node announces as its hostname:
# <cluster>-shard-xyz-0.<cluster>-shard-xyz-headless.<namespace>.svc...
fdb_shard_of_node() {
  local namespace="$1" pod="$2" cluster="$3" id="$4" host component
  host="$(fdb_cli "$namespace" "$pod" CLUSTER NODES | tr -d '\r' |
    awk -v id="$id" '$1 == id {split($2, a, ","); print a[2]; exit}')"
  component="$(echo "$host" | sed -n 's/^[^.]*\.\(.*\)-headless\..*$/\1/p')"
  if [ -z "$component" ]; then
    fdb_fail "node $id announces no pod hostname: '$host'"
    return 1
  fi
  echo "${component#"$cluster"-}"
}

# fdb_shard_primary <namespace> <pod> <cluster> <shard short name>
# Prints the node ID of the shard's current primary.
fdb_shard_primary() {
  local namespace="$1" pod="$2" cluster="$3" shard="$4" id
  id="$(fdb_cli "$namespace" "$pod" CLUSTER NODES | tr -d '\r' |
    awk -v suffix=".$cluster-$shard-headless." '$3 ~ /master/ && $3 !~ /fail/ &&
      index($2, suffix) > 0 {print $1; exit}')"
  if [ -z "$id" ]; then
    fdb_fail "$pod knows no healthy primary of shard $shard"
    return 1
  fi
  echo "$id"
}

# fdb_assert_node_owns <namespace> <pod> <node id> <slots>
# Fails unless the primary owns every slot in <slots>, a list such as
# "0-99,5000" in the format the falkordb-cluster-reshard ops takes, as <pod>
# sees it.
fdb_assert_node_owns() {
  local namespace="$1" pod="$2" id="$3" slots="$4" missing
  missing="$(fdb_cli "$namespace" "$pod" CLUSTER NODES | tr -d '\r' |
    awk -v id="$id" -v want="$slots" '
      $1 == id {
        for (i = 9; i <= NF; i++) {
          if ($i ~ /^\[/) continue
          n = split($i, r, "-")
          if (n == 1) r[2] = r[1]
          for (s = r[1] + 0; s <= r[2] + 0; s++) owned[s] = 1
        }
      }
      END {
        n = split(want, items, ",")
        for (i = 1; i <= n; i++) {
          m = split(items[i], r, "-")
          if (m == 1) r[2] = r[1]
          for (s = r[1] + 0; s <= r[2] + 0; s++) if (!(s in owned)) out = out " " s
        }
        print out
      }')"
  if [ -n "$missing" ]; then
    fdb_fail "$pod does not see $id own slots:$(echo "$missing" | cut -c1-200)"
    return 1
  fi
  fdb_log "$pod sees $id own slots $slots"
}

# fdb_apply_custom_ops <namespace> <cluster> <ops name> <opsdefinition> [NAME=value...]
# Creates a Custom OpsRequest against the `shard` sharding with the given
# parameters. A scenario uses this rather than a fixed manifest when the
# parameters, such as a shard name, are only known at run time.
fdb_apply_custom_ops() {
  local namespace="$1" cluster="$2" name="$3" opsdef="$4" param params=""
  shift 4
  for param in "$@"; do
    params="$params
        - name: ${param%%=*}
          value: \"${param#*=}\""
  done
  kubectl apply -n "$namespace" -f - <<EOF
apiVersion: operations.kubeblocks.io/v1alpha1
kind: OpsRequest
metadata:
  name: $name
spec:
  clusterName: $cluster
  type: Custom
  custom:
    opsDefinitionName: $opsdef
    components:
      - componentName: shard
        parameters:$params
EOF
}

# fdb_wait_ops_phase <namespace> <ops name> <Succeed|Failed>
# Waits for the OpsRequest to end in the given phase, and fails as soon as it
# ends in the other one rather than waiting out the timeout.
fdb_wait_ops_phase() {
  local namespace="$1" name="$2" want="$3" phase="" attempt=1
  while [ "$attempt" -le "$FDB_RETRIES" ]; do
    phase="$(kubectl get opsrequest -n "$namespace" "$name" \
      -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    if [ "$phase" = "$want" ]; then
      fdb_log "OpsRequest $name is $phase"
      return 0
    fi
    case "$phase" in
      Succeed | Failed | Aborted | Cancelled)
        fdb_fail "OpsRequest $name is $phase, expected $want"
        return 1
        ;;
    esac
    attempt=$((attempt + 1))
    sleep "$FDB_RETRY_DELAY"
  done
  fdb_fail "timed out waiting for OpsRequest $name to be $want, it is '${phase:-unknown}'"
  return 1
}

# fdb_custom_ops_logs <namespace>
# Prints the logs of every Job in the namespace. Custom OpsRequests run their
# actions as Jobs, and the logs are the only record of what each one did.
# Diagnostics only: it keeps going past a Job whose logs cannot be read.
fdb_custom_ops_logs() {
  local namespace="$1" job
  for job in $(kubectl get jobs -n "$namespace" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
    echo "=== $job ==="
    kubectl logs -n "$namespace" "job/$job" --all-containers --tail=200 2>&1 || true
  done
}

# fdb_assert_custom_ops_log <namespace> <text>
# Fails unless some Job's logs include the text. A Custom OpsRequest only
# reports Failed, so a scenario that expects a refusal reads the reason here,
# to tell it apart from a Job that failed for some other reason.
fdb_assert_custom_ops_log() {
  local namespace="$1" text="$2" logs
  # No pipe into grep -q: under pipefail, grep closing the pipe at the first
  # match fails the pipeline although the text was found.
  logs="$(fdb_custom_ops_logs "$namespace")"
  case "$logs" in
    *"$text"*)
      fdb_log "a custom ops Job logged: $text"
      return 0
      ;;
  esac
  fdb_fail "no custom ops Job logged '$text'"
  return 1
}

# fdb_shard_count <namespace> <cluster>
# Prints the number of shard Components currently belonging to the cluster.
fdb_shard_count() {
  local namespace="$1" cluster="$2"
  kubectl get components -n "$namespace" \
    -l "app.kubernetes.io/instance=$cluster" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' |
    grep -c . || true
}

# fdb_sharding_pods <namespace> <cluster> <sharding name>
# Prints every pod belonging to a sharding, across all of its shards.
fdb_sharding_pods() {
  local namespace="$1" cluster="$2" sharding="$3"
  kubectl get pods -n "$namespace" \
    -l "app.kubernetes.io/instance=$cluster,apps.kubeblocks.io/sharding-name=$sharding" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort
}

# fdb_any_sharding_pod <namespace> <cluster> <sharding name>
# Prints one ready pod from the sharding, for use as an entry point to the cluster.
fdb_any_sharding_pod() {
  local namespace="$1" cluster="$2" sharding="$3" pod
  pod="$(kubectl get pods -n "$namespace" \
    -l "app.kubernetes.io/instance=$cluster,apps.kubeblocks.io/sharding-name=$sharding" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -z "$pod" ]; then
    fdb_fail "no running pod found in sharding '$sharding' of cluster '$cluster'"
    return 1
  fi
  echo "$pod"
}

# fdb_sharding_shard_count <namespace> <cluster> <sharding name>
# Prints how many shards (Components) the sharding currently has.
fdb_sharding_shard_count() {
  local namespace="$1" cluster="$2" sharding="$3"
  kubectl get components -n "$namespace" \
    -l "app.kubernetes.io/instance=$cluster,apps.kubeblocks.io/sharding-name=$sharding" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' |
    grep -c . || true
}

# fdb_assert_shard_count <namespace> <cluster> <sharding name> <expected>
fdb_assert_shard_count() {
  local namespace="$1" cluster="$2" sharding="$3" expected="$4" actual
  actual="$(fdb_sharding_shard_count "$namespace" "$cluster" "$sharding")"
  if [ "$actual" -ne "$expected" ]; then
    fdb_fail "sharding '$sharding' has $actual shards, expected $expected"
    return 1
  fi
  fdb_log "sharding '$sharding' has $expected shards"
}

# fdb_config_get <namespace> <pod> <parameter>
# Prints the value of a running-configuration parameter.
fdb_config_get() {
  local namespace="$1" pod="$2" parameter="$3"
  fdb_cli "$namespace" "$pod" CONFIG GET "$parameter" | tr -d '\r' | tail -1
}

# fdb_assert_config <namespace> <pod> <parameter> <expected>
fdb_assert_config() {
  local namespace="$1" pod="$2" parameter="$3" expected="$4" actual
  actual="$(fdb_config_get "$namespace" "$pod" "$parameter")"
  if [ "$actual" != "$expected" ]; then
    fdb_fail "$pod has $parameter '$actual', expected '$expected'"
    return 1
  fi
  fdb_log "$pod has $parameter '$expected'"
}

# fdb_assert_config_not <namespace> <pod> <parameter> <unexpected>
# For values the server normalizes, where only the old value is known exactly.
#
# Anything but a value differing from the old one has to fail, so the reply is
# checked to be a real CONFIG GET reply (the parameter name, then its value)
# first: an error reply or a failed exec also differs from the old value.
fdb_assert_config_not() {
  local namespace="$1" pod="$2" parameter="$3" unexpected="$4" reply actual
  if ! reply="$(fdb_cli "$namespace" "$pod" CONFIG GET "$parameter")"; then
    fdb_fail "could not read $parameter on $pod"
    return 1
  fi
  reply="$(printf '%s' "$reply" | tr -d '\r')"
  if [ "$(printf '%s\n' "$reply" | head -1)" != "$parameter" ]; then
    fdb_fail "$pod did not return $parameter: '$reply'"
    return 1
  fi
  actual="$(printf '%s\n' "$reply" | sed -n 2p)"
  if [ "$actual" = "$unexpected" ]; then
    fdb_fail "$pod still has $parameter '$actual'"
    return 1
  fi
  fdb_log "$pod has $parameter '$actual'"
}

# fdb_assert_external_hostname <description> <value> <suffix>
# Fails unless the value is a name under the given DNS suffix.
#
# The point of an external hostname is that it is what a client outside the
# cluster is handed, so an IP address or an in-cluster FQDN appearing here means
# the announce path silently fell back to its default.
fdb_assert_external_hostname() {
  local description="$1" value="$2" suffix="$3"
  case "$value" in
    *".$suffix")
      fdb_log "$description is $value"
      ;;
    *)
      fdb_fail "$description is '${value:-<empty>}', expected a name under .$suffix"
      return 1
      ;;
  esac
}

# fdb_kill_pod <namespace> <pod>
# Deletes a pod and blocks until a pod of the same name is Ready again.
#
# StatefulSet-backed pods keep their name and volume, so this simulates a node or
# container crash rather than a scale-in.
fdb_kill_pod() {
  local namespace="$1" pod="$2"
  fdb_log "deleting pod $pod to simulate a crash"
  kubectl delete pod -n "$namespace" "$pod" --wait=false >/dev/null
  # --for=delete on a pod that is already gone exits immediately, so this is safe
  # even if the kubelet reaps it before we get here.
  kubectl wait --for=delete pod -n "$namespace" "$pod" --timeout=5m >/dev/null 2>&1 || true
  fdb_log "waiting for $pod to be recreated and Ready"
  kubectl wait --for=create pod -n "$namespace" "$pod" --timeout=5m >/dev/null
  kubectl wait --for=condition=Ready pod -n "$namespace" "$pod" --timeout=10m >/dev/null
  fdb_log "$pod is Ready again"
}

# fdb_assert_pod_count <namespace> <cluster> <component> <expected>
fdb_assert_pod_count() {
  local namespace="$1" cluster="$2" component="$3" expected="$4" actual
  actual="$(fdb_pods "$namespace" "$cluster" "$component" | grep -c . || true)"
  if [ "$actual" -ne "$expected" ]; then
    fdb_fail "$cluster/$component has $actual pods, expected $expected"
    return 1
  fi
  fdb_log "$cluster/$component has $expected pods"
}

# fdb_pvc_capacity_is <namespace> <pvc> <expected>
# Fails unless the claim reports the expected size in status.capacity.
#
# status.capacity is written by the resizer once the volume has really been
# expanded. spec.resources.requests only records what was asked for, so it
# reaches the new size immediately and would make any expansion look successful.
fdb_pvc_capacity_is() {
  local namespace="$1" pvc="$2" expected="$3" actual
  actual="$(kubectl get pvc -n "$namespace" "$pvc" -o jsonpath='{.status.capacity.storage}')"
  if [ "$actual" != "$expected" ]; then
    fdb_fail "pvc $pvc reports capacity '$actual', expected $expected"
    return 1
  fi
}

# fdb_assert_role_counts <namespace> <cluster> <component> <primaries> <secondaries>
# Fails unless the component has exactly the expected number of each role.
fdb_assert_role_counts() {
  local namespace="$1" cluster="$2" component="$3" want_p="$4" want_s="$5"
  local got_p got_s
  got_p="$(fdb_pods_with_role "$namespace" "$cluster" "$component" primary | grep -c . || true)"
  got_s="$(fdb_pods_with_role "$namespace" "$cluster" "$component" secondary | grep -c . || true)"
  if [ "$got_p" -ne "$want_p" ] || [ "$got_s" -ne "$want_s" ]; then
    fdb_fail "$cluster/$component has $got_p primary and $got_s secondary pods, expected $want_p and $want_s"
    return 1
  fi
  fdb_log "$cluster/$component has $want_p primary and $want_s secondary pods"
}

# fdb_assert_all_replicas_linked <namespace> <cluster> <component>
# Fails unless every secondary has a live link to the primary.
fdb_assert_all_replicas_linked() {
  local namespace="$1" cluster="$2" component="$3" pod
  for pod in $(fdb_pods_with_role "$namespace" "$cluster" "$component" secondary); do
    fdb_assert_replication_up "$namespace" "$pod" || return 1
  done
}

# fdb_graph_roundtrip <namespace> <pod> <graph name>
# Creates a node in a graph and reads it back, proving the graph module works.
fdb_graph_roundtrip() {
  local namespace="$1" pod="$2" graph="$3"
  if ! fdb_cli "$namespace" "$pod" MODULE LIST | grep -qi graph; then
    fdb_fail "the graph module is not loaded on $pod"
    return 1
  fi
  fdb_cli "$namespace" "$pod" GRAPH.QUERY "$graph" \
    "CREATE (:Person {name:'alice'})" >/dev/null
  if ! fdb_cli "$namespace" "$pod" GRAPH.QUERY "$graph" \
    "MATCH (p:Person) RETURN p.name" | grep -q alice; then
    fdb_fail "the graph query did not return the node written on $pod"
    return 1
  fi
  fdb_log "graph module round-trip succeeded on $pod"
}

# fdb_primary_service <namespace> <cluster> <component>
# Prints the name of the Service that KubeBlocks pins to the primary.
#
# The name is derived from the componentDefinition, so it is not worth
# hard-coding in every scenario. What identifies it unambiguously is the
# roleSelector, which lands in the Service as a kubeblocks.io/role selector.
fdb_primary_service() {
  local namespace="$1" cluster="$2" component="$3" svc role
  for svc in $(kubectl get svc -n "$namespace" \
    -l "app.kubernetes.io/instance=$cluster,apps.kubeblocks.io/component-name=$component" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
    role="$(kubectl get svc -n "$namespace" "$svc" \
      -o jsonpath='{.spec.selector.kubeblocks\.io/role}')"
    if [ "$role" = primary ]; then
      echo "$svc"
      return 0
    fi
  done
  fdb_fail "no Service in $namespace selects the primary of $cluster/$component"
  return 1
}

# fdb_service_endpoints <namespace> <service>
# Prints the ready pods currently behind a Service, one per line.
fdb_service_endpoints() {
  local namespace="$1" service="$2"
  # An endpoint with no ready condition at all counts as ready, so only an
  # explicit "false" may be filtered out.
  kubectl get endpointslices -n "$namespace" \
    -l "kubernetes.io/service-name=$service" \
    -o jsonpath='{range .items[*].endpoints[*]}{.targetRef.name}{" "}{.conditions.ready}{"\n"}{end}' |
    awk 'NF && $2 != "false" {print $1}' | sort
}

# fdb_assert_service_primary <namespace> <cluster> <component> <pod>
# Fails unless the primary Service routes to exactly the given pod and a client
# connecting through it reaches a writable server.
#
# Applications connect to this Service, never to a pod, so a failover that
# promotes the right pod but leaves the Service pointing at the old one is a
# full outage: every write comes back READONLY. Asserting roles on pods cannot
# see that, because it never goes through the selector.
fdb_assert_service_primary() {
  local namespace="$1" cluster="$2" component="$3" want="$4"
  local svc port got role client
  svc="$(fdb_primary_service "$namespace" "$cluster" "$component")" || return 1

  got="$(fdb_service_endpoints "$namespace" "$svc" | tr '\n' ' ' | sed 's/ *$//')"
  if [ "$got" != "$want" ]; then
    fdb_fail "service $svc routes to '$got' but $want is the primary"
    return 1
  fi

  # Matching endpoints only prove the selector caught up. Dialling the Service
  # by name from another pod also proves DNS, the port mapping and the
  # credentials line up, which is the part an application actually depends on.
  client="$(fdb_pods_with_role "$namespace" "$cluster" "$component" secondary | head -1)"
  [ -n "$client" ] || client="$want"
  port="$(kubectl get svc -n "$namespace" "$svc" -o jsonpath='{.spec.ports[0].port}')"
  role="$(kubectl exec -n "$namespace" "$client" -c "$FDB_CONTAINER" -- \
    sh -c 'REDISCLI_AUTH="$REDIS_DEFAULT_PASSWORD" exec redis-cli -h "$1" -p "$2" '"$FDB_CLI_FLAGS"' INFO replication' \
    _ "$svc" "$port" | tr -d '\r' | awk -F: '/^role:/ {print $2; exit}')"
  if [ "$role" != master ]; then
    fdb_fail "connecting to service $svc from $client reached a server reporting role '$role'"
    return 1
  fi
  fdb_log "service $svc routes to the primary $want and answers as master"
}

# fdb_assert_graph_node <namespace> <pod> <graph name>
# Fails unless the node written by fdb_graph_roundtrip is still readable.
fdb_assert_graph_node() {
  local namespace="$1" pod="$2" graph="$3"
  # GRAPH.QUERY is flagged as a write command even for a pure MATCH, so it is
  # rejected with READONLY on a replica. GRAPH.RO_QUERY is the read-only
  # variant and is the only one usable when asserting against a secondary.
  if ! fdb_cli "$namespace" "$pod" GRAPH.RO_QUERY "$graph" \
    "MATCH (p:Person) RETURN p.name" | grep -q alice; then
    fdb_fail "graph '$graph' lost its node on $pod"
    return 1
  fi
  fdb_log "graph '$graph' still holds its node on $pod"
}

# shellcheck shell=sh
# Helpers the steps of 42-addon-move-servers-first share. Sourced after
# "$E2E_LIB_DIR/falkordb.sh", with NAMESPACE set by chainsaw. POSIX sh, like
# that file: chainsaw runs scripts through /bin/sh, dash on the CI runners.

# installed <falkordb-4|falkordb-sent-4>
# The chart's own definition of a kind, not a copy.
installed() {
  kubectl get componentdefinition -l app.kubernetes.io/name=falkordb \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' |
    grep -E "^$1-[0-9]+\.[0-9]+\.[0-9]+" | sort -V | tail -n 1
}

# comp_def <component>
comp_def() {
  kubectl get component -n "$NAMESPACE" "fdb-move-$1" -o jsonpath='{.spec.compDef}'
}

# move_component <component> <definition>
# Points one component of the Cluster at a definition, leaving the other as it is.
move_component() {
  local index
  index="$(kubectl get cluster -n "$NAMESPACE" fdb-move \
    -o jsonpath='{range .spec.componentSpecs[*]}{.name}{"\n"}{end}' | grep -nx "$1" | cut -d: -f1)"
  [ -n "$index" ] || { fdb_fail "the cluster has no component $1"; return 1; }
  kubectl patch cluster fdb-move -n "$NAMESPACE" --type=json \
    -p "[{\"op\":\"replace\",\"path\":\"/spec/componentSpecs/$((index - 1))/componentDef\",\"value\":\"$2\"}]"
}

# caught_up <kind> <name>: the object's controller acted on its latest spec
caught_up() {
  # shellcheck disable=SC2046 # split into the two generations on purpose
  set -- $(kubectl get "$1" -n "$NAMESPACE" "$2" \
    -o jsonpath='{.metadata.generation} {.status.observedGeneration}')
  [ "$#" -eq 2 ] && [ "$1" = "$2" ]
}

# component_rolled_out <component> <replicas>
# Every pod of the component updated, and the component Running on its spec.
component_rolled_out() {
  caught_up instanceset "fdb-move-$1" &&
    [ "$(kubectl get instanceset -n "$NAMESPACE" "fdb-move-$1" \
      -o jsonpath='{.status.updatedReplicas}/{.status.replicas}')" = "$2/$2" ] &&
    caught_up component "fdb-move-$1" &&
    [ "$(kubectl get component -n "$NAMESPACE" "fdb-move-$1" -o jsonpath='{.status.phase}')" = Running ]
}

cluster_settled() {
  caught_up cluster fdb-move &&
    [ "$(kubectl get cluster -n "$NAMESPACE" fdb-move -o jsonpath='{.status.phase}')" = Running ]
}

# Every server resolved its sentinel vars, checked without printing the
# password, and no server's start script failed: a replica without the
# password exits 1 and restarts in a loop. A restart KubeBlocks makes in place
# ends in a signal, so only a container that last exited 1 counts.
assert_servers_reach_sentinels() {
  local pod last_exit
  for pod in $(fdb_pods "$NAMESPACE" fdb-move falkordb); do
    kubectl exec -n "$NAMESPACE" "$pod" -c falkordb -- sh -c '
      missing=""
      for var in SENTINEL_PASSWORD SENTINEL_USER SENTINEL_COMPONENT_NAME SENTINEL_POD_FQDN_LIST; do
        eval "value=\${$var:-}"
        [ -n "$value" ] || missing="$missing $var"
      done
      [ -z "$missing" ] || { echo "empty:$missing" >&2; exit 1; }' ||
      { fdb_fail "$pod resolved empty sentinel vars"; return 1; }
    last_exit="$(kubectl get pod -n "$NAMESPACE" "$pod" \
      -o jsonpath='{.status.containerStatuses[?(@.name=="falkordb")].lastState.terminated.exitCode}')"
    [ "$last_exit" != 1 ] ||
      { fdb_fail "$pod's falkordb container exited 1 during the move"; return 1; }
    echo "$pod resolved every sentinel var, and its server never failed to start"
  done
}

#!/bin/sh

# shellcheck disable=SC2086
# shellcheck disable=SC2034

ut_mode="false"
test || __() {
  set -e;
}

normalize_role() {
  printf '%s' "$1" | tr -d '\r\n' | tr '[:upper:]' '[:lower:]'
}

get_cluster_state() {
  local service_port
  local cluster_info
  service_port="${KB_SERVICE_PORT:-${SERVICE_PORT:-6379}}"

  if [ -n "${REDIS_DEFAULT_PASSWORD:-}" ]; then
    cluster_info=$(redis-cli ${REDIS_CLI_TLS_CMD:-} -h localhost -p "$service_port" -a "$REDIS_DEFAULT_PASSWORD" cluster info 2>/dev/null || true)
  else
    cluster_info=$(redis-cli ${REDIS_CLI_TLS_CMD:-} -h localhost -p "$service_port" cluster info 2>/dev/null || true)
  fi

  printf '%s\n' "$cluster_info" | awk -F: '/^cluster_state:/{print $2; exit}' | tr -d '[:space:]'
}

run_role_probe() {
  local role_output
  local role
  local current_pod_name
  local pod_ordinal
  local cluster_state

  role_output=$(/tools/dbctl redis getrole 2>/dev/null || true)
  role=$(normalize_role "$role_output")

  case "$role" in
    primary|secondary) ;;
    *)
      return 1
      ;;
  esac

  current_pod_name="${CURRENT_POD_NAME:-}"
  pod_ordinal="${current_pod_name##*-}"

  # During bootstrap/recovery, non-zero ordinal pods can briefly report PRIMARY
  # before replication converges. When cluster_state is not OK, treat that as
  # degraded and fall back to SECONDARY so role probing does not deadlock the
  # component in Updating/Failed.
  if [ "$role" = "primary" ] && [ "$pod_ordinal" != "0" ]; then
    cluster_state=$(get_cluster_state)
    if [ "$cluster_state" != "ok" ]; then
      printf '%s' "secondary"
      return 0
    fi
  fi

  printf '%s' "$role"
  return 0
}

run_role_probe

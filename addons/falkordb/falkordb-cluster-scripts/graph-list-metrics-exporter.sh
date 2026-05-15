#!/bin/sh

set -eu

GRAPH_METRICS_DIR="${GRAPH_METRICS_DIR:-/tmp/graph-metrics}"
GRAPH_METRICS_FILE="${GRAPH_METRICS_DIR}/metrics"
GRAPH_METRICS_HTTP_PORT="${GRAPH_METRICS_HTTP_PORT:-9122}"
GRAPH_METRICS_POLL_INTERVAL_SECONDS="${GRAPH_METRICS_POLL_INTERVAL_SECONDS:-15}"
REDIS_PORT="${SERVICE_PORT:-6379}"

write_metric() {
  count="$1"
  cat > "${GRAPH_METRICS_FILE}" <<EOF
# HELP falkordb_graph_list_count Number of graphs returned by GRAPH.LIST.
# TYPE falkordb_graph_list_count gauge
falkordb_graph_list_count ${count}
EOF
}

get_graph_count() {
  tls_args=""
  if [ "${TLS_ENABLED:-false}" = "true" ]; then
    tls_args="--tls --insecure"
  fi

  # shellcheck disable=SC2086
  output="$(redis-cli --user "${REDIS_DEFAULT_USER}" --pass "${REDIS_DEFAULT_PASSWORD}" ${tls_args} -h 127.0.0.1 -p "${REDIS_PORT}" --raw GRAPH.LIST 2>/dev/null || true)"

  if [ -z "${output}" ]; then
    echo "0"
    return
  fi

  if printf "%s\n" "${output}" | grep -q '^ERR'; then
    echo "0"
    return
  fi

  printf "%s\n" "${output}" | awk 'NF { count += 1 } END { print count + 0 }'
}
start_metrics_server() {
  if busybox --list 2>/dev/null | grep -qx 'httpd'; then
    busybox httpd -f -p "${GRAPH_METRICS_HTTP_PORT}" -h "${GRAPH_METRICS_DIR}" &
    return
  fi

  while true; do
    {
      printf 'HTTP/1.1 200 OK\r\nContent-Type: text/plain; version=0.0.4; charset=utf-8\r\nConnection: close\r\n\r\n'
      cat "${GRAPH_METRICS_FILE}"
    } | nc -l -p "${GRAPH_METRICS_HTTP_PORT}" >/dev/null 2>&1
  done &
}

mkdir -p "${GRAPH_METRICS_DIR}"
write_metric "0"

start_metrics_server
server_pid="$!"
trap 'kill "${server_pid}" 2>/dev/null || true; exit 0' TERM INT

while true; do
  count="$(get_graph_count)"
  case "${count}" in
    ''|*[!0-9]*)
      count="0"
      ;;
  esac

  write_metric "${count}"
  sleep "${GRAPH_METRICS_POLL_INTERVAL_SECONDS}"
done

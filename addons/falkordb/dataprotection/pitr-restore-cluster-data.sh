#!/bin/bash
# Runs after common-scripts.sh and pitr-restore-common.sh.
#
# Restores one shard of a sharded cluster from a continuous aof backup, step 2:
# rebuilds what the source shard held at DP_RESTORE_TIME as an RDB, for
# restore-cluster.sh to write through the cluster. It replays the shard's
# archived AOF, cut at DP_RESTORE_TIME, in a server of its own and saves that
# server's dataset.
#
# The archive cannot go back on the shard's volume as the replication restore
# does: the restored cluster assigns its slots afresh, so every key has to be
# written to whichever shard owns its slot now. That is also what keeps every
# shard to the one DP_RESTORE_TIME, whatever the restored layout.
PITR_WORK_DIR="${DATA_DIR}/.kb-pitr-restore"
PITR_RDB_FILE="${DATA_DIR}/kb-dp-dump.rdb"
PITR_SERVER_PORT=${PITR_SERVER_PORT:-16380}
PITR_LOAD_TIMEOUT_SECONDS=${PITR_LOAD_TIMEOUT_SECONDS:-3600}
FALKORDB_MODULE=${FALKORDB_MODULE:-/var/lib/falkordb/bin/falkordb.so}

pitr_server_cli="redis-cli -h 127.0.0.1 -p ${PITR_SERVER_PORT}"
pitr_server_pid=""

# A server busy replaying may not act on TERM promptly; a watchdog KILLs it
# after PITR_STOP_TIMEOUT_SECONDS so cleanup cannot outlast the restore's deadline.
# (kill -0 cannot tell: the server stays a zombie, and signalable, until waited for.)
function stop_pitr_server() {
  if [ -z "${pitr_server_pid}" ] || ! kill -0 "${pitr_server_pid}" 2>/dev/null; then
    return
  fi
  kill "${pitr_server_pid}" 2>/dev/null
  (sleep "${PITR_STOP_TIMEOUT_SECONDS:-30}"; kill -9 "${pitr_server_pid}" 2>/dev/null) &
  local watchdog=$!
  wait "${pitr_server_pid}" 2>/dev/null
  kill "${watchdog}" 2>/dev/null
  pitr_server_pid=""
}
trap stop_pitr_server EXIT

rm -rf "${PITR_WORK_DIR}" "${PITR_RDB_FILE}"
mkdir -p "${PITR_WORK_DIR}"
get_files_to_restore "${PITR_WORK_DIR}"
truncate_aof "${PITR_WORK_DIR}"

# pitr-backup.sh archives the AOF manifest as <appenddirname>/<appendfilename>.manifest
manifest=$(find "${PITR_WORK_DIR}" -type f -name "*.manifest" | head -n 1)
if [ -z "${manifest}" ]; then
  DP_error_log "No AOF manifest in $pitr_archive"
  exit 1
fi

server_cmd=(redis-server --port "${PITR_SERVER_PORT}" --bind 127.0.0.1 --dir "${PITR_WORK_DIR}"
  --appendonly yes --appenddirname "$(basename "$(dirname "${manifest}")")"
  --appendfilename "$(basename "${manifest}" .manifest)"
  --dbfilename "$(basename "${PITR_RDB_FILE}")" --save "")
if [ -f "${FALKORDB_MODULE}" ]; then
  # shellcheck disable=SC2206
  server_cmd+=(--loadmodule "${FALKORDB_MODULE}" ${FALKORDB_ARGS:-})
fi
DP_log "Replay $pitr_archive: ${server_cmd[*]}"
"${server_cmd[@]}" &
pitr_server_pid=$!

# PING answers LOADING until the AOF is replayed. A server that exits refused the AOF.
# A server busy replaying may not answer at all, so every PING is bounded and the
# deadline is wall-clock time (SECONDS), not a count of rounds.
if ! command -v timeout >/dev/null 2>&1; then
  DP_error_log "timeout is not available to bound the PING of the server replaying $pitr_archive"
  exit 1
fi
pitr_ping_cli="timeout ${PITR_PING_TIMEOUT_SECONDS:-5} ${pitr_server_cli}"
SECONDS=0
until [ "$(${pitr_ping_cli} PING 2>/dev/null | tr -d '\r')" == "PONG" ]; do
  if ! kill -0 "${pitr_server_pid}" 2>/dev/null; then
    DP_error_log "The server replaying $pitr_archive exited before it loaded the AOF"
    exit 1
  fi
  if [ "${SECONDS}" -ge "${PITR_LOAD_TIMEOUT_SECONDS}" ]; then
    DP_error_log "The server replaying $pitr_archive did not load the AOF within ${PITR_LOAD_TIMEOUT_SECONDS}s"
    exit 1
  fi
  sleep 1
done

if [ "$(${pitr_server_cli} SAVE 2>&1 | tr -d '\r')" != "OK" ] || [ ! -f "${PITR_WORK_DIR}/$(basename "${PITR_RDB_FILE}")" ]; then
  DP_error_log "Failed to save the dataset replayed from $pitr_archive"
  exit 1
fi
${pitr_server_cli} SHUTDOWN NOSAVE >/dev/null 2>&1
stop_pitr_server

if ! mv "${PITR_WORK_DIR}/$(basename "${PITR_RDB_FILE}")" "${PITR_RDB_FILE}"; then
  DP_error_log "Failed to move the replayed dataset to ${PITR_RDB_FILE}"
  exit 1
fi
rm -rf "${PITR_WORK_DIR}" && sync
DP_log "Replayed $pitr_archive to ${DP_RESTORE_TIME} in ${PITR_RDB_FILE}"

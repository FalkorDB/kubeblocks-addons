#!/bin/bash
set -e
export PATH="$PATH:$DP_DATASAFED_BIN_PATH"
export DATASAFED_BACKEND_BASE_PATH="$DP_BACKUP_BASE_PATH"
datasafed pull -d zstd-fastest "${DP_BACKUP_NAME}.rdb.zst" ${DATA_DIR}/kb-dp-dump.rdb
# With TLS on, the server sets `port 0` and only listens on the TLS port, so a
# redis:// sinker is refused on every node. REDIS_CLI_TLS_CMD is what tells
# the other data-protection jobs to speak TLS; ape-dts takes it as the URL
# scheme, and keeps that scheme when it follows the cluster to the other
# shards. rediss:// encrypts without verifying the server certificate, the
# same as the --insecure in REDIS_CLI_TLS_CMD.
redis_scheme=redis
case " ${REDIS_CLI_TLS_CMD:-} " in
  *" --tls "*) redis_scheme=rediss ;;
esac
cat >> dts.ini <<EOF
[extractor]
db_type=redis
extract_type=snapshot_file
repl_port=10008
file_path=${DATA_DIR}/kb-dp-dump.rdb

[filter]
do_dbs=0
do_events=
ignore_dbs=
ignore_tbs=
do_tbs=

[sinker]
db_type=redis
sink_type=write
url=${redis_scheme}://default:${REDIS_DEFAULT_PASSWORD}@${DP_DB_HOST}:${DP_DB_PORT}
batch_size=200
is_cluster=true

[router]
db_map=
col_map=
tb_map=

[pipeline]
buffer_size=16000
checkpoint_interval_secs=10

[parallelizer]
parallel_type=redis
parallel_size=1

[runtime]
log_level=info
log4rs_file=./log4rs.yaml
log_dir=./logs
EOF
# ape-dts has been observed to stall forever on an RDB payload it cannot parse.
# An unbounded run leaves the restore job "active" indefinitely, so the restore
# never fails and the cluster never comes up. Bound it so the failure surfaces.
#
# The status is taken with `|| rc=$?` on purpose. Inside `if ! cmd; then`, $?
# is the status of the negation, which is always 0 there, so every ape-dts
# failure used to exit 0 and the restore reported success with empty shards.
rc=0
timeout "${APE_DTS_RESTORE_TIMEOUT:-3600}" "${APE_DTS_BIN:-/ape-dts}" dts.ini || rc=$?
if [ "$rc" -ne 0 ]; then
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 143 ]; then
    echo "ape-dts did not finish within ${APE_DTS_RESTORE_TIMEOUT:-3600}s; failing the restore" >&2
  else
    echo "ape-dts failed with status $rc; failing the restore" >&2
  fi
  exit "$rc"
fi
rm -rf ${DATA_DIR}/kb-dp-dump.rdb && sync

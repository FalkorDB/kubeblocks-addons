#!/bin/bash
# Runs after common-scripts.sh and pitr-restore-common.sh.
#
# Restores one shard of a sharded cluster from a continuous aof backup, step 1:
# the shard starts empty but with the users of its archive at DP_RESTORE_TIME.
# Its data is loaded once the cluster is up, by pitr-restore-cluster-data.sh
# and restore-cluster.sh.
mkdir -p ${DATA_DIR}
res=$(find ${DATA_DIR} -type f)
data_protection_file=${DATA_DIR}/.kb-data-protection
if [ -n "${res}" ] && [ ! -f ${data_protection_file} ]; then
  DP_error_log "${DATA_DIR} is not empty! Please make sure that the directory is empty before restoring the backup."
  exit 1
fi
# touch placeholder file
touch ${data_protection_file}

select_archive_to_restore
case "$pitr_archive" in
*.dir/)
  if ! datasafed pull "${pitr_archive}users.acl" "${DATA_DIR}/users.acl"; then
    DP_error_log "Failed to pull ${pitr_archive}users.acl"
    exit 1
  fi
  ;;
*.tar.zst)
  # pitr-backup.sh archives users.acl at the root of the tar
  datasafed pull -d zstd-fastest "${pitr_archive}" - | tar -xf - -C "${DATA_DIR}" users.acl
  pipe_status=("${PIPESTATUS[@]}")
  if [ "${pipe_status[0]}" -ne 0 ] || [ "${pipe_status[1]}" -ne 0 ]; then
    DP_error_log "Failed to pull users.acl from $pitr_archive (pull: ${pipe_status[0]}, tar: ${pipe_status[1]})"
    exit 1
  fi
  ;;
*)
  DP_error_log "Unknown aof_file type: $pitr_archive"
  exit 1
  ;;
esac

if ! rm -rf "${data_protection_file}"; then
  DP_error_log "Failed to remove ${data_protection_file}"
  exit 1
fi
sync
DP_log "Restored users.acl from $pitr_archive"

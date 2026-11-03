#!/bin/bash
# Runs after common-scripts.sh, switch-data-dir.sh and pitr-restore-common.sh.
mkdir -p ${DATA_DIR}
res=$(find ${DATA_DIR} -type f)
data_protection_file=${DATA_DIR}/.kb-data-protection
if [ -n "${res}" ] && [ ! -f ${data_protection_file} ]; then
  DP_error_log "${DATA_DIR} is not empty! Please make sure that the directory is empty before restoring the backup."
  exit 1
fi
# touch placeholder file
touch ${data_protection_file}

get_files_to_restore
truncate_aof

chmod -R 777 "${DATA_DIR}"
rm -rf ${data_protection_file} && sync
DP_log "Restore complete."

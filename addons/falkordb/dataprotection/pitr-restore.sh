#!/bin/bash
export PATH="$PATH:$DP_DATASAFED_BIN_PATH"
export DATASAFED_BACKEND_BASE_PATH="$DP_BACKUP_BASE_PATH"

function truncate_aof() {
  local aof_file=$(find "$DATA_DIR" -type f -name "*.aof" | sort -r | head -n 1)
  local temp_file="${aof_file}.tmp"
  local restore_time=$(date -d "$DP_RESTORE_TIME" +%s)
  # Values in the AOF can hold any byte, NUL included, and a shell variable
  # cannot, so the file is never copied through the shell. Instead find the
  # byte offset of the first #TS:<t> annotation after the restore time and keep
  # everything before it. Annotations start a line between commands, so the
  # cut leaves only whole commands.
  local offset=$(grep -a -b -o '^#TS:[0-9][0-9]*' "$aof_file" |
    awk -F: -v rt="$restore_time" '$3 + 0 > rt + 0 { print $1; exit }')
  if [ -z "$offset" ]; then
    return
  fi

  DP_log "Truncate aof file: $aof_file at byte $offset"
  if ! head -c "$offset" "$aof_file" >"$temp_file" || ! mv "$temp_file" "$aof_file"; then
    rm -f "$temp_file"
    DP_error_log "Failed to truncate aof file: $aof_file"
    exit 1
  fi
}

function get_files_to_restore() {
  local restore_time=$(date -d "$DP_RESTORE_TIME" +%s)
  if [ -z "$restore_time" ]; then
    DP_error_log "Invalid restore time: $DP_RESTORE_TIME"
    exit 1
  fi

  local filename=$(datasafed list / | sort -Vr | awk -v rt="$restore_time" -F '.' '$1 <= rt {print; exit}')
  if [ -z "$filename" ]; then
    DP_error_log "No backup found for the given restore time: $DP_RESTORE_TIME"
    exit 1
  fi

  case "$filename" in
  *.dir/)
    DP_log "Pull directory: $filename"
    if ! DP_pull_directory "${filename}" "${DATA_DIR}"; then
      DP_error_log "Failed to pull directory: $filename"
      exit 1
    fi
    ;;
  *.tar.zst)
    echo "Pull aof_file: $filename"
    datasafed pull -d zstd-fastest "${filename}" - | tar -xvf - -C "${DATA_DIR}/"
    local pipe_status=("${PIPESTATUS[@]}")
    if [ "${pipe_status[0]}" -ne 0 ] || [ "${pipe_status[1]}" -ne 0 ]; then
      DP_error_log "Failed to pull or extract $filename (pull: ${pipe_status[0]}, tar: ${pipe_status[1]})"
      exit 1
    fi
    ;;
  *)
    DP_error_log "Unknown aof_file type: $filename"
    exit 1
    ;;
  esac
}

mkdir -p ${DATA_DIR}
res=$(find ${DATA_DIR} -type f)
data_protection_file=${DATA_DIR}/.kb-data-protection
if [ -n "${res}" ] && [ ! -f ${data_protection_file} ]; then
  DP_error "${DATA_DIR} is not empty! Please make sure that the directory is empty before restoring the backup."
  exit 1
fi
# touch placeholder file
touch ${data_protection_file}

get_files_to_restore
truncate_aof

chmod -R 777 "${DATA_DIR}"
rm -rf ${data_protection_file} && sync
DP_log "Restore complete."

# shellcheck shell=bash
# Functions shared by the replication (pitr-restore.sh) and the sharded
# (pitr-restore-cluster-*.sh) restores from a continuous aof backup.
export PATH="$PATH:$DP_DATASAFED_BIN_PATH"
export DATASAFED_BACKEND_BASE_PATH="$DP_BACKUP_BASE_PATH"

# Cut the newest AOF under <dir> (default: DATA_DIR) at DP_RESTORE_TIME.
function truncate_aof() {
  local dir=${1:-$DATA_DIR}
  local aof_file=$(find "$dir" -type f -name "*.aof" | sort -r | head -n 1)
  local temp_file="${aof_file}.tmp"
  local restore_time=$(date -d "$DP_RESTORE_TIME" +%s)
  # Values in the AOF can hold any byte, NUL included, and a shell variable
  # cannot, so the file is never copied through the shell. Instead find the
  # byte offset of the first #TS:<t> annotation after the restore time and keep
  # everything before it. Annotations start a line between commands, so the
  # cut leaves only whole commands.
  if [ -z "$aof_file" ]; then
    return
  fi
  # grep exits 1 when the file has no annotation at all; anything above that
  # means the AOF could not be read, and restoring it uncut would ignore the
  # restore time.
  local stamps rc
  stamps=$(grep -a -b -o '^#TS:[0-9][0-9]*' "$aof_file")
  rc=$?
  if [ "$rc" -gt 1 ]; then
    DP_error_log "Failed to read aof file: $aof_file"
    exit 1
  fi
  local offset=$(printf '%s\n' "$stamps" |
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

# Set pitr_archive to the newest archive (a .dir/ or a .tar.zst) that starts at
# or before DP_RESTORE_TIME.
function select_archive_to_restore() {
  local restore_time=$(date -d "$DP_RESTORE_TIME" +%s)
  if [ -z "$restore_time" ]; then
    DP_error_log "Invalid restore time: $DP_RESTORE_TIME"
    exit 1
  fi

  pitr_archive=$(DP_pitr_list_archives | sort -Vr | awk -v rt="$restore_time" -F '.' '$1 <= rt {print; exit}')
  if [ -z "$pitr_archive" ]; then
    DP_error_log "No backup found for the given restore time: $DP_RESTORE_TIME"
    exit 1
  fi
}

# Pull the archive for DP_RESTORE_TIME into <dir> (default: DATA_DIR).
function get_files_to_restore() {
  local dir=${1:-$DATA_DIR}
  select_archive_to_restore

  case "$pitr_archive" in
  *.dir/)
    DP_log "Pull directory: $pitr_archive"
    if ! DP_pull_directory "${pitr_archive}" "${dir}"; then
      DP_error_log "Failed to pull directory: $pitr_archive"
      exit 1
    fi
    ;;
  *.tar.zst)
    echo "Pull aof_file: $pitr_archive"
    datasafed pull -d zstd-fastest "${pitr_archive}" - | tar -xvf - -C "${dir}/"
    local pipe_status=("${PIPESTATUS[@]}")
    if [ "${pipe_status[0]}" -ne 0 ] || [ "${pipe_status[1]}" -ne 0 ]; then
      DP_error_log "Failed to pull or extract $pitr_archive (pull: ${pipe_status[0]}, tar: ${pipe_status[1]})"
      exit 1
    fi
    ;;
  *)
    DP_error_log "Unknown aof_file type: $pitr_archive"
    exit 1
    ;;
  esac
}

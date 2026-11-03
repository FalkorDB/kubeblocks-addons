# shellcheck shell=bash
# Functions shared by the replication (pitr-restore.sh) and the sharded
# (pitr-restore-cluster-*.sh) restores from a continuous aof backup.
export PATH="$PATH:$DP_DATASAFED_BIN_PATH"
export DATASAFED_BACKEND_BASE_PATH="$DP_BACKUP_BASE_PATH"

# Cut the AOF under <dir> (default: DATA_DIR) at DP_RESTORE_TIME.
function truncate_aof() {
  local dir=${1:-$DATA_DIR}
  local manifest=$(find "$dir" -type f -name "*.manifest" | head -n 1)
  local restore_time=$(date -d "$DP_RESTORE_TIME" +%s)
  # pitr-backup.sh archives the manifest with every seq; without it the AOF
  # cannot be cut, and restored uncut it would ignore the restore time.
  if [ -z "$manifest" ]; then
    DP_error_log "No AOF manifest under $dir to truncate"
    exit 1
  fi
  # redis-check-aof parses the RESP framing, so only a #TS: annotation between
  # commands is a cut point: a value can hold any bytes, a "\n#TS:<t>" or a NUL
  # among them, and is neither cut at nor copied through the shell. It keeps the
  # commands stamped up to the restore time, and fails on an AOF it cannot read,
  # which restored uncut would ignore the restore time.
  DP_log "Truncate aof: $manifest to $restore_time"
  if ! redis-check-aof --truncate-to-timestamp "$restore_time" "$manifest" </dev/null; then
    DP_error_log "Failed to truncate aof: $manifest"
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

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
  drop_incr_aof_after "$manifest" "$restore_time"
  if ! redis-check-aof --truncate-to-timestamp "$restore_time" "$manifest" </dev/null; then
    DP_error_log "Failed to truncate aof: $manifest"
    exit 1
  fi
}

# Leave out of <manifest> every INCR file that starts with a #TS: annotation
# later than <restore_time>: it holds nothing to restore. redis-check-aof aborts
# on such a file ("has nothing before timestamp") rather than cut it to nothing,
# and it only cuts the last INCR file, so the one it cuts has to be last. That
# happens whenever the restore time falls between an AOF rewrite (a new base, as
# after a failover) and the first write after it, or before a later INCR file.
# Annotations only grow, so the files left out are the manifest's last ones.
# An INCR file that does not start with an annotation is left to redis-check-aof.
function drop_incr_aof_after() {
  local manifest=$1 restore_time=$2
  local dir name first_ts dropped=()
  dir=$(dirname "$manifest")
  # manifest lines: file <name> seq <n> type <b|h|i> [startoffset <n> endoffset <n>]
  while read -r name; do
    [ -f "$dir/$name" ] || continue
    first_ts=$(head -c 64 "$dir/$name" | head -n 1 | tr -d '\r')
    if [[ "$first_ts" =~ ^#TS:([0-9]+)$ ]] && [ "${BASH_REMATCH[1]}" -gt "$restore_time" ]; then
      dropped+=("$name")
    fi
  done < <(awk '$1 == "file" && $5 == "type" && $6 == "i" { print $2 }' "$manifest")
  [ "${#dropped[@]}" -eq 0 ] && return 0
  DP_log "Leave out INCR AOF written after $restore_time: ${dropped[*]}"
  if ! awk -v drop=" ${dropped[*]} " \
    '!($1 == "file" && $5 == "type" && $6 == "i" && index(drop, " " $2 " "))' \
    "$manifest" > "$manifest.kb-tmp" || ! mv "$manifest.kb-tmp" "$manifest"; then
    DP_error_log "Failed to leave INCR AOF out of $manifest"
    exit 1
  fi
  for name in "${dropped[@]}"; do
    rm -f "$dir/$name"
  done
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

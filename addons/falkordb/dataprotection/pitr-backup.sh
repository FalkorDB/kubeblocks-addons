# shellcheck shell=bash
export PATH="$PATH:$DP_DATASAFED_BIN_PATH"
export DATASAFED_BACKEND_BASE_PATH="$DP_BACKUP_BASE_PATH"

connect_url="redis-cli $REDIS_CLI_TLS_CMD -h ${DP_DB_HOST} -p ${DP_DB_PORT} -a ${DP_DB_PASSWORD}"
if [ -z ${DP_DB_PASSWORD} ]; then
  connect_url="redis-cli $REDIS_CLI_TLS_CMD -h ${DP_DB_HOST} -p ${DP_DB_PORT}"
fi
global_last_purge_time=$(date +%s)
# when the last round that uploaded the live AOF started; see update_aof_file
global_aof_pushed_at=0
# the archive (${base_file_ctime}.${seq}) global_aof_pushed_at was for
global_aof_pushed_prefix=""
global_acl_last_modify_time=0
global_old_size=0
# every write stamped up to this time is in the backup repo
global_archived_until=0

AOF_DIR=$(${connect_url} CONFIG GET appenddirname | awk 'NR==2')
APPEND_FILE_NAME=$(${connect_url} CONFIG GET appendfilename | awk 'NR==2')
AOF_FILE_PREFIX="${DATA_DIR}/${AOF_DIR}/${APPEND_FILE_NAME}"
BASE_FILE_SUFFIX="base.$([ "$($connect_url CONFIG GET aof-use-rdb-preamble | awk 'NR==2')" == "no" ] && echo "aof" || echo "rdb")"
AOF_MANIFEST_FILE="${AOF_FILE_PREFIX}.manifest"

mkdir -p "${AOF_DIR}"

function get_base_file_ctime() {
  local base_file=${1}
  if [ "$BASE_FILE_SUFFIX" = "base.rdb" ]; then
    # use the creation time of the base file as the start time
    ctime=$(redis-check-rdb "$base_file" | grep 'ctime' | awk -F"'" '{print $2}')
    if [ -n "$ctime" ]; then
      echo $ctime
      return
    fi
  fi

  # for aof base file
  # extract the timestamp from the first line of base_file
  timestamp=$(head -n 1 "$base_file" | grep -oP '(?<=#TS:)\d+')

  # ff no timestamp is found, get the file creation time
  if [ -z "$timestamp" ]; then
    timestamp=$(stat -c %W "$base_file")
  fi
  echo "$timestamp"
}

function aof_incr_file() {
  local seq=$1
  # absolute path
  echo "${AOF_FILE_PREFIX}.${seq}.incr.aof"
}

function aof_base_file() {
  local seq=$1
  # absolute path
  echo "${AOF_FILE_PREFIX}.${seq}.${BASE_FILE_SUFFIX}"
}

function get_backup_seq() {
  local remote_aof_dir=$(datasafed list -d / | sort -Vr | head -n 1)
  local remote_aof_seq=$(echo "$remote_aof_dir" | awk -F '.' '{print $2}')
  if [[ -z "$remote_aof_seq" ]] || ! [[ "$remote_aof_seq" =~ ^[0-9]+$ ]]; then
    echo 1
    return
  fi

  local remote_base_file_ctime=$(echo "$remote_aof_dir" | awk -F '.' '{print $1}')
  local local_aof_seq=$(awk '/type i/ { print $4 }' "${AOF_MANIFEST_FILE}")
  local local_base_file_ctime=$(get_base_file_ctime "$(aof_base_file "$local_aof_seq")")

  if [ "$remote_base_file_ctime" -gt "$local_base_file_ctime" ] ||
   { [ "$remote_base_file_ctime" -eq "$local_base_file_ctime" ] && [ "$remote_aof_seq" -gt "$local_aof_seq" ]; }; then
    # in replication mode, when failover happens, if the backup process switch to a new target, we should
    # call BGREWRITEAOF to make sure record from a new start time, which guarantees the consistency of data and continuity of time.
    ${connect_url} BGREWRITEAOF  >/dev/null 2>&1
  fi

  [ "$local_aof_seq" -lt "$remote_aof_seq" ] && echo "$local_aof_seq" || echo "$remote_aof_seq"
}

global_backup_seq=$(get_backup_seq)

function get_backup_files_prefix() {
  local base_file=${1}
  echo "$(get_base_file_ctime "$base_file")"."$global_backup_seq"
}

# generate backup manifest file for remote backup
# returns non-zero when the manifest cannot be written, since an older one may still be in place
function generate_backup_manifest() {
  local backup_manifest="$APPEND_FILE_NAME.manifest"
  local backup_incr_file=$(basename "$(aof_incr_file "$global_backup_seq")")
  local backup_base_file=$(basename "$(aof_base_file "$global_backup_seq")")

  if ! { echo "file $backup_incr_file seq $global_backup_seq type i" >"$AOF_DIR/$backup_manifest" &&
    echo "file $backup_base_file seq $global_backup_seq type b" >>"$AOF_DIR/$backup_manifest"; } 2>/dev/null; then
    return 1
  fi
  echo ""${AOF_DIR}"/${backup_manifest}"
}

# archive aof and rdb file after aof rewrite
function archive_pair_files() {
  local incr_file=$(aof_incr_file "$global_backup_seq")
  local base_file=$(aof_base_file "$global_backup_seq")
  local backup_files_prefix=$(get_backup_files_prefix $base_file)
  local backup_manifest="$APPEND_FILE_NAME.manifest"

  if [ ! -f "$incr_file" ] || [ ! -f "$base_file" ]; then
    DP_log "archive_pair_files: $incr_file or $base_file do not exist"
    return
  fi

  local target_file="${backup_files_prefix}.tar.zst"
  local backup_manifest_file
  if ! backup_manifest_file=$(generate_backup_manifest); then
    DP_error_log "archive_pair_files: failed to write the backup manifest, not archiving ${target_file}"
    return 1
  fi
  # tar keeps streaming past a file it cannot read, so check them all before anything is uploaded:
  # a retry would otherwise overwrite the complete archive of an earlier run with one missing a file.
  local input
  for input in "${backup_manifest_file}" "${incr_file}" "${base_file}" "${DATA_DIR}/users.acl"; do
    if [ ! -r "${input}" ]; then
      DP_error_log "archive_pair_files: cannot read ${input}, not archiving ${target_file}"
      return 1
    fi
  done
  # a retry after a failed .dir removal finds the complete archive of the earlier run here;
  # a failed push must not delete it. If the listing fails, assume it exists.
  local remote_files target_existed=true
  if remote_files=$(datasafed list /) && ! grep -Fxq "${target_file}" <<<"${remote_files}"; then
    target_existed=false
  fi
  # backup files include manifest file, incr file, base file, users.acl
  # and we retains the original directory hierarchy, which makes the recovery process simpler
  tar -cvf - "${backup_manifest_file}" -C "${DATA_DIR}" \
    "${AOF_DIR}/$(basename "${incr_file}")" "${AOF_DIR}/$(basename "${base_file}")" \
    "users.acl" | datasafed push -z zstd - "${target_file}"
  local pipe_status=("${PIPESTATUS[@]}")
  # the tracked files below are the only copy of this segment until the archive is uploaded,
  # so a failed tar or push must leave them, and the remote .dir, in place.
  if [ "${pipe_status[0]}" -ne 0 ] || [ "${pipe_status[1]}" -ne 0 ]; then
    DP_error_log "archive_pair_files: failed to archive ${incr_file} and ${base_file} to ${target_file} (tar: ${pipe_status[0]}, push: ${pipe_status[1]})"
    # push may have stored the part of the stream tar wrote before failing; drop it so a restore cannot pick it.
    if [ "${target_existed}" = true ]; then
      if [ "${pipe_status[0]}" -ne 0 ]; then
        DP_error_log "archive_pair_files: ${target_file} from an earlier run may have been overwritten by this incomplete one; the next run uploads it again"
      fi
    elif ! datasafed rm "${target_file}" >/dev/null 2>&1; then
      DP_error_log "archive_pair_files: failed to remove the incomplete ${target_file}, delete it before restoring from this seq"
    fi
    return 1
  fi

  # delete remote and local uncompressed files we are tracking.
  # a leftover .dir sorts ahead of the archive and a restore would pick its stale copy,
  # so keep the local files and fail: the next run archives this seq again and retries the removal.
  if ! datasafed rm -r "${backup_files_prefix}.dir"; then
    DP_error_log "archive_pair_files: failed to remove ${backup_files_prefix}.dir after archiving it to ${target_file}"
    return 1
  fi
  rm "${incr_file}" "${base_file}"

  DP_log "Archived files: ${incr_file} and ${base_file} to $target_file"
}

function update_aof_file() {
  local incr_file=$(aof_incr_file "$global_backup_seq")
  local base_file=$(aof_base_file "$global_backup_seq")
  local backup_files_prefix=$(get_backup_files_prefix $base_file)
  local backup_manifest
  # taken before anything is read: every write stamped before this second is
  # in the files this round uploads.
  local round_start=$(date +%s)

  if [ ! -f "$incr_file" ] || [ ! -f "$base_file" ]; then
    DP_log "update_aof_file: $incr_file or $base_file do not exist"
    return
  fi
  if ! backup_manifest=$(generate_backup_manifest); then
    DP_error_log "update_aof_file: failed to write the backup manifest, retrying next round"
    return 1
  fi

  # create a directory for backup files we are tracking, and after a aof rewrite, we will archive them in to a tar.zst file
  # global_aof_pushed_at only advances after a successful round, so a failed push is retried on the next round.
  # A new archive is uploaded whole: a rewrite that started before the last round and finished after it
  # leaves a base, and an idle incr, older than global_aof_pushed_at.
  local pushed_at=${global_aof_pushed_at}
  if [ "${backup_files_prefix}" != "${global_aof_pushed_prefix}" ]; then
    pushed_at=0
  fi
  # Times have one second resolution, and a write in the same second as the last upload but after it leaves the
  # modify time equal to it, so a file is uploaded again until its time is older than the last round's start.
  if [ $(get_base_file_ctime "$base_file") -ge ${pushed_at} ]; then
    if ! datasafed push "${base_file}" "${backup_files_prefix}.dir/${AOF_DIR}/$(basename "${base_file}")" ||
      ! datasafed push "${backup_manifest}" "${backup_files_prefix}.dir/${backup_manifest}" ||
      ! datasafed push "${DATA_DIR}/users.acl" "${backup_files_prefix}.dir/users.acl"; then
      DP_error_log "update_aof_file: failed to upload $base_file $backup_manifest users.acl, retrying next round"
      return 1
    fi
    DP_log "Upload file: $base_file $backup_manifest users.acl"
  fi

  # keep updating the latest aof file
  local aof_modify_time=$(stat -c %Y "${incr_file}")
  if [ "${aof_modify_time}" -ge "${pushed_at}" ]; then
    if ! datasafed push "${incr_file}" "${backup_files_prefix}.dir/${AOF_DIR}/$(basename "${incr_file}")"; then
      DP_error_log "update_aof_file: failed to upload $incr_file, retrying next round"
      return 1
    fi
    DP_log "Update file: $incr_file"
  fi

  # keep updating the latest acl file
  local acl_file="${DATA_DIR}/users.acl"
  local acl_modify_time=$(stat -c %Y "${acl_file}")
  if [ "${acl_modify_time}" -gt "${global_acl_last_modify_time}" ]; then
    if ! datasafed push "${acl_file}"  "${backup_files_prefix}.dir/users.acl"; then
      DP_error_log "update_aof_file: failed to upload $acl_file, retrying next round"
      return 1
    fi
    global_acl_last_modify_time=${acl_modify_time}
    DP_log "Update file: $acl_file"
  fi
  global_aof_pushed_at=${round_start}
  global_aof_pushed_prefix=${backup_files_prefix}
  # the #TS: stamps have one second resolution, so the second the round started in may still be taking writes.
  # With appendfsync everysec the server holds back its AOF write for up to 2s while an fsync is running, so
  # commands stamped in those seconds may not be in the file yet: claim only up to AOF_WRITE_DELAY_SECONDS before.
  global_archived_until=$((round_start - 1 - AOF_WRITE_DELAY_SECONDS))
}

function purge_expired_files() {
  local current_unix=$(date +%s)
  local interval_seconds=${PURGE_INTERVAL_SECONDS:-600}
  # the same checks DP_purge_expired_files makes, before the prefix below reads the base file
  if [ -z "${DP_TTL_SECONDS}" ] || [ $((current_unix - global_last_purge_time)) -lt "${interval_seconds}" ]; then
    return
  fi
  # The live seq's base is uploaded once, while its incr keeps being updated, so
  # a seq that lives longer than the TTL would lose its base and be unrestorable.
  local live_dir="$(get_backup_files_prefix "$(aof_base_file "$global_backup_seq")").dir/"
  info=$(DP_purge_expired_files ${current_unix} ${global_last_purge_time} / "${interval_seconds}" "${live_dir}")
  # a pass that found nothing expired still waits out the interval before the next
  global_last_purge_time=${current_unix}
  if [ ! -z "${info}" ]; then
    DP_log "Cleanup expired aof files: ${info}"
    # a sharded backup reports the size of every shard, in save_cluster_backup_status
    if [ "${MODE}" != "cluster" ]; then
      local total_size=$(datasafed stat / | grep TotalSize | awk '{print $2}')
      DP_save_backup_status_info "${total_size}"
    fi
  fi
}

function save_backup_status() {
  # The end is the last time a round uploaded everything (global_archived_until),
  # not now: a round that failed part way, a new seq's .dir missing its base or
  # manifest say, must not put its times in the window.
  if [ "${global_archived_until}" -le 0 ]; then
    return
  fi
  # if no size changes, return
  local total_size=$(datasafed stat / | grep TotalSize | awk '{print $2}')
  if [[ -z ${total_size} || ${total_size} -eq 0 || ${total_size} == ${global_old_size} ]]; then
    return
  fi
  local archives
  if ! archives=$(DP_pitr_list_archives); then
    # leave the status, and global_old_size, for the next round to retry
    DP_error_log "save_backup_status: failed to list the archives, retrying next round"
    return
  fi
  global_old_size=${total_size}
  local start_time=$(awk -F '.' '{print $1}' <<<"${archives}" | sort -n | head -n 1)
  if [ -z "$start_time" ]; then
    start_time=$(date +%s)
    DP_log "save_backup_status: empty start_time from backup repo, use current time"
  fi
  DP_save_backup_status_info "${total_size}" "${start_time}" "${global_archived_until}"
}

# A sharded cluster is backed up by one archiver per shard, each a target of the
# same Backup, archiving its shard to ${DP_BACKUP_BASE_PATH}, a directory named
# after the target under the Backup's path. They all patch the one
# status.timeRange, and a restore to time T replays every shard to T, so the
# Backup can only offer the times every shard covers. Each archiver publishes the
# range its own shard covers to ${ARCHIVE_RANGE_FILE}, reads every shard's, and
# reports their intersection, so the status is the same whichever writes last.
#
# The file holds "<start> <end> <published at> <shard primary id>", with start
# and end 0 while the shard has no archive. Every archiver rewrites its own each
# status round. The window needs a fresh range with an archive from every shard
# of the cluster now, matched by its primary's node id: a shard removed by a
# scale-in (its directory stays in the Backup) owns no slots and is ignored, and
# a live shard with no archive, or whose archiver stopped (its file is older than
# RANGE_STALE_SECONDS), withdraws the window.
ARCHIVE_RANGE_FILE="kb-archive-range"
CLUSTER_STATUS_INTERVAL_SECONDS=${CLUSTER_STATUS_INTERVAL_SECONDS:-15}
RANGE_STALE_SECONDS=${RANGE_STALE_SECONDS:-300}
AOF_WRITE_DELAY_SECONDS=${AOF_WRITE_DELAY_SECONDS:-3}
global_cluster_status_time=0

function publish_archive_range() {
  local archives start end
  if ! archives=$(DP_pitr_list_archives); then
    return
  fi
  start=$(awk -F '.' '{print $1}' <<<"${archives}" | sort -n | head -n 1)
  end=${global_archived_until}
  if [ -z "$start" ]; then
    # Nothing archived yet, or retention has removed every archive: this shard
    # covers no time, which withdraws the window until it does.
    start=0 end=0
  elif [ "${end}" -le 0 ]; then
    # restarted, and no round has completed yet: leave the last range as it is
    return
  fi
  local primary_id
  primary_id=$(shard_primary_id)
  if [ -z "${primary_id}" ]; then
    DP_error_log "publish_archive_range: cannot tell this shard's primary, retrying next round"
    return
  fi
  if ! echo "${start} ${end} $(date +%s) ${primary_id}" | datasafed push - "${ARCHIVE_RANGE_FILE}"; then
    DP_error_log "publish_archive_range: failed to upload ${ARCHIVE_RANGE_FILE}, retrying next round"
  fi
}

# The node ids of the cluster's shards: primaries that own slots. A failed
# primary that still owns slots is a shard whose archive is needed too.
function cluster_shard_ids() {
  ${connect_url} CLUSTER NODES 2>/dev/null |
    awk '$3 ~ /(^|,)master(,|$)/ && NF > 8 { print $1 }'
}

# The node id of the primary of the shard this archiver backs up: the target
# itself, or the primary it replicates.
function shard_primary_id() {
  ${connect_url} CLUSTER NODES 2>/dev/null |
    awk '$3 ~ /(^|,)myself(,|$)/ { print ($3 ~ /(^|,)master(,|$)/) ? $1 : $4; exit }'
}

function save_cluster_backup_status() {
  local root
  root=$(dirname "${DP_BACKUP_BASE_PATH}")
  local shard_ids shards targets target range start end published id now
  local covered=" " cluster_start=0 cluster_end=0 extras=""
  now=$(date +%s)
  shard_ids=" $(cluster_shard_ids | tr '\n' ' ')"
  shards=$(printf '%s' "${shard_ids}" | wc -w | tr -d ' ')
  if [ "${shards}" -eq 0 ]; then
    # A cluster always has a primary that owns slots: CLUSTER NODES failed or
    # answered with an error. Leave the status as it is rather than withdraw it.
    DP_error_log "save_cluster_backup_status: cannot read the cluster's shards, retrying next round"
    return
  fi
  if ! targets=$(DATASAFED_BACKEND_BASE_PATH="${root}" datasafed list -d /); then
    DP_error_log "save_cluster_backup_status: failed to list the shards under ${root}"
    return
  fi
  for target in ${targets}; do
    target=${target%/}
    range=$(DATASAFED_BACKEND_BASE_PATH="${root}" datasafed pull "${target}/${ARCHIVE_RANGE_FILE}" - 2>/dev/null) || continue
    read -r start end published id <<<"${range}"
    if ! [[ "${start}" =~ ^[0-9]+$ && "${end}" =~ ^[0-9]+$ && "${published}" =~ ^[0-9]+$ && -n "${id}" ]]; then
      continue
    fi
    if [[ "${shard_ids}" != *" ${id} "* ]]; then
      DP_log "save_cluster_backup_status: ignoring ${target}, whose primary ${id} owns no slots"
      continue
    fi
    if [ $((now - published)) -gt "${RANGE_STALE_SECONDS}" ]; then
      DP_log "save_cluster_backup_status: ignoring ${target}, whose archiver last published at ${published}"
      continue
    fi
    # a shard with no archive covers no time
    [ "${end}" -eq 0 ] && continue
    [[ "${covered}" == *" ${id} "* ]] || covered="${covered}${id} "
    [ "${start}" -gt "${cluster_start}" ] && cluster_start=${start}
    { [ "${cluster_end}" -eq 0 ] || [ "${end}" -lt "${cluster_end}" ]; } && cluster_end=${end}
    extras="${extras:+${extras},}{\"shard\":\"${target}\",\"start\":\"$(date -u -d @"${start}" +%Y-%m-%dT%H:%M:%SZ)\",\"end\":\"$(date -u -d @"${end}" +%Y-%m-%dT%H:%M:%SZ)\"}"
  done
  local ranges
  ranges=$(printf '%s' "${covered}" | wc -w | tr -d ' ')
  local total_size
  total_size=$(DATASAFED_BACKEND_BASE_PATH="${root}" datasafed stat / | grep TotalSize | awk '{print $2}')
  if [ "${shards}" -eq 0 ] || [ "${ranges}" -lt "${shards}" ] || [ "${cluster_start}" -gt "${cluster_end}" ]; then
    # Some shard covers no time yet, or the shards share none, so no time can
    # be restored. The sidecar merge-patches the status, so the null is what
    # takes an earlier window off the Backup.
    DP_log "save_cluster_backup_status: ${ranges} of ${shards} shards have archived, and they share no time yet"
    echo "{\"totalSize\":\"${total_size}\",\"extras\":[${extras}],\"timeRange\":null}" >"${DP_BACKUP_INFO_FILE}"
    return
  fi
  DP_save_backup_status_info "${total_size}" "${cluster_start}" "${cluster_end}" "" "${extras}"
}

function check_conf() {
  aof_timestamp_enabled=$(${connect_url} CONFIG GET aof-timestamp-enabled 2>/dev/null | awk 'NR==2')
  if [ "$aof_timestamp_enabled" == "no" ]; then
    DP_error_log "aof-timestamp-enabled is not set to yes, set it to yes by 'kbcli cluster edit-config' or 'kbcli cluster configure'"
    ${connect_url} CONFIG SET aof-disable-auto-gc no
    exit 1
  fi

  disable_gc=$(${connect_url} CONFIG GET aof-disable-auto-gc 2>/dev/null | awk 'NR==2')
  if [ "$disable_gc" == "no" ]; then
    ${connect_url} CONFIG SET aof-disable-auto-gc yes
    DP_log "aof-disable-auto-gc set to yes"
  fi
}

# archived files named as ${base_file_ctime}.${seq}.suffix
# we use {base_file_ctime} to track files between different target pods in replication mode and used for restore
# every time a failover happens, we will choose to track the new one target pod with the latest {base_file_ctime}, keep
# time increasing, and use {seq} to track the selected one target pod`s incremental backup files

trap "echo 'Terminating...' && sync && ${connect_url} CONFIG SET aof-disable-auto-gc no && exit 0" TERM
echo "INFO: start to backup"
while true; do
  check_conf

  aof_seq=$(awk '/type i/ { print $4 }' "${AOF_MANIFEST_FILE}")
  while [ "${global_backup_seq}" -lt "${aof_seq}" ]; do
    # stop instead of moving on: the unarchived files are kept, and the next run picks this seq up again
    # from its remote .dir. aof-disable-auto-gc stays yes so the server keeps them until then.
    if ! archive_pair_files; then
      DP_error_log "failed to archive seq ${global_backup_seq}, exiting"
      exit 1
    fi
    global_backup_seq=$((global_backup_seq + 1))
  done

  update_aof_file

  purge_expired_files

  if [ "${MODE}" == "cluster" ]; then
    now=$(date +%s)
    if [ $((now - global_cluster_status_time)) -ge "${CLUSTER_STATUS_INTERVAL_SECONDS}" ]; then
      global_cluster_status_time=${now}
      publish_archive_range
      save_cluster_backup_status
    fi
  else
    save_backup_status
  fi

  sleep "${LOG_ARCHIVE_SECONDS}"
done

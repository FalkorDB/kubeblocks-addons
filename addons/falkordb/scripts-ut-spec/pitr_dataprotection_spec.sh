#!/bin/bash
# shellcheck disable=SC2034

# pitr-backup.sh and pitr-restore.sh run top to bottom, so these cases build
# each one the way the falkordb-for-pitr ActionSet does (common-scripts.sh
# first) and run it against stub datasafed, redis-cli, redis-check-rdb, date,
# stat and sleep binaries. The datasafed stub keeps the backup repo in a local
# directory, so a case can check what was uploaded, removed or restored. The
# sharded restore also stubs redis-server, the server it replays the AOF in.
Describe "FalkorDB PITR dataprotection scripts"
  setup() {
    # Resolved before the scripts change into the work directory.
    dp_dir="$(cd ../dataprotection && pwd)"
    work_dir="$(mktemp -d)"
    stub_dir="$work_dir/bin"
    mkdir -p "$stub_dir" "$work_dir/run" "$work_dir/remote" "$work_dir/data/appendonlydir"

    # `datasafed list|push|pull|rm|stat` over the directory $STUB_REMOTE.
    # STUB_PUSH_RC / STUB_PULL_RC / STUB_RM_RC make push / pull / rm fail; STUB_PUSH_FAIL_ONCE
    # fails only the first push whose remote path contains it.
    cat > "$stub_dir/datasafed" <<'EOF'
#!/bin/bash
echo "$*" >> "$STUB_DATASAFED_LOG"
# paths are relative to DATASAFED_BACKEND_BASE_PATH, as in the real datasafed
STUB_REMOTE="$STUB_REMOTE${DATASAFED_BACKEND_BASE_PATH%/}"
mkdir -p "$STUB_REMOTE"
cmd=$1; shift
case "$cmd" in
list)
  dirs_only=false recursive=false
  while [ $# -gt 1 ]; do
    case "$1" in
    -d) dirs_only=true ;;
    -r) recursive=true ;;
    esac
    shift
  done
  path=${1#/}
  cd "$STUB_REMOTE" || exit 1
  if $recursive; then
    find "${path%/}" -type f | sort
  elif $dirs_only; then
    ls -p | grep '/$'
  else
    ls -p
  fi
  ;;
push)
  [ "$1" = "-z" ] && shift 2
  src=$1 dst=$STUB_REMOTE/$2
  if [ -n "$STUB_PUSH_FAIL_ONCE" ] && [[ "$2" == *"$STUB_PUSH_FAIL_ONCE"* ]] &&
    [ ! -e "$STUB_REMOTE.failed-once" ]; then
    touch "$STUB_REMOTE.failed-once"
    cat > /dev/null
    exit 1
  fi
  if [ "${STUB_PUSH_RC:-0}" -ne 0 ]; then
    cat > /dev/null
    exit "$STUB_PUSH_RC"
  fi
  mkdir -p "$(dirname "$dst")"
  if [ "$src" = "-" ]; then cat > "$dst"; else cp "$src" "$dst"; fi
  ;;
pull)
  [ "$1" = "-d" ] && shift 2
  src=$STUB_REMOTE/$1 dst=$2
  if [ "$dst" = "-" ]; then
    cat "$src"
  elif [ "${STUB_PULL_RC:-0}" -eq 0 ]; then
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
  fi
  exit "${STUB_PULL_RC:-0}"
  ;;
rm)
  [ "${STUB_RM_RC:-0}" -ne 0 ] && exit "$STUB_RM_RC"
  [ "$1" = "-r" ] && shift
  rm -rf "${STUB_REMOTE:?}/$1"
  ;;
stat)
  echo "TotalSize 0"
  ;;
esac
EOF
    cat > "$stub_dir/redis-cli" <<'EOF'
#!/bin/sh
case "$*" in
*"CONFIG GET appenddirname"*) printf 'appenddirname\nappendonlydir\n' ;;
*"CONFIG GET appendfilename"*) printf 'appendfilename\nappendonly.aof\n' ;;
*"CONFIG GET aof-use-rdb-preamble"*) printf 'aof-use-rdb-preamble\nyes\n' ;;
*"CONFIG GET aof-timestamp-enabled"*) printf 'aof-timestamp-enabled\nyes\n' ;;
*"CONFIG GET aof-disable-auto-gc"*) printf 'aof-disable-auto-gc\nyes\n' ;;
# three primaries own slots; the replica and the failed-over primary do not count.
# STUB_FAILED_PRIMARY_SLOTS gives the failed primary slots, which it has not handed over yet.
*"CLUSTER NODES"*)
  echo "a1 10.0.0.1:6379@16379 myself,master - 0 0 1 connected 0-5460"
  echo "b1 10.0.0.2:6379@16379 master - 0 0 2 connected 5461-10922"
  echo "c1 10.0.0.3:6379@16379 master - 0 0 3 connected 10923-16383"
  echo "c2 10.0.0.4:6379@16379 slave c1 0 0 3 connected"
  echo "d1 10.0.0.5:6379@16379 master,fail - 0 0 4 disconnected ${STUB_FAILED_PRIMARY_SLOTS:-}"
  ;;
*" PING"*) echo "${STUB_PING:-PONG}" ;;
# the stub redis-server recorded where it would save; the "RDB" is the AOF it replayed
*" SAVE"*)
  . "$STUB_SERVER_STATE"
  cat "$server_dir"/appendonlydir/*.incr.aof > "$server_dir/$server_dbfilename"
  echo OK
  ;;
*) echo OK ;;
esac
EOF
    # Every base file was created at 1000.
    cat > "$stub_dir/redis-check-rdb" <<'EOF'
#!/bin/sh
echo "[offset 0] Checking RDB file $1"
echo "[info] ctime '1000'"
EOF
    # Now is 2000; `date -d` parses the restore times the cases use, and
    # `date -u -d @<t>` formats <t> as T<t>.
    cat > "$stub_dir/date" <<'EOF'
#!/bin/sh
if [ "$1" = "-u" ] && [ "$2" = "-d" ]; then
  echo "T${3#@}"
  exit 0
fi
if [ "$1" = "-d" ]; then
  case "$2" in
  restore-at-1500) echo 1500 ;;
  restore-at-500) echo 500 ;;
  restore-at-1700) echo 1700 ;;
  *) echo "date: invalid date '$2'" >&2; exit 1 ;;
  esac
  exit 0
fi
case "$*" in
"+%s") echo 2000 ;;
*) echo "1970-01-01 00:33:20" ;;
esac
EOF
    # GNU `stat -c %Y`: every tracked file was last modified at 1500.
    cat > "$stub_dir/stat" <<'EOF'
#!/bin/sh
echo 1500
EOF
    # The backup loop sleeps between rounds forever; end it with the TERM the
    # backup pod would get, after STUB_ROUNDS rounds.
    cat > "$stub_dir/sleep" <<'EOF'
#!/bin/sh
echo round >> "$STUB_SLEEP_LOG"
# STUB_ON_SLEEP runs between rounds, e.g. to rewrite the AOF
[ -z "$STUB_ON_SLEEP" ] || sh -c "$STUB_ON_SLEEP"
[ "$(wc -l < "$STUB_SLEEP_LOG")" -ge "${STUB_ROUNDS:-1}" ] && kill -TERM "$PPID"
exit 0
EOF
    # Records its arguments and where it would save, then waits to be stopped,
    # or exits at once with STUB_SERVER_RC.
    cat > "$stub_dir/redis-server" <<'EOF'
#!/bin/bash
echo "$*" > "$STUB_SERVER_ARGS"
while [ $# -gt 0 ]; do
  case "$1" in
  --dir) echo "server_dir='$2'" >> "$STUB_SERVER_STATE" ;;
  --dbfilename) echo "server_dbfilename='$2'" >> "$STUB_SERVER_STATE" ;;
  esac
  shift
done
[ -n "$STUB_SERVER_RC" ] && exit "$STUB_SERVER_RC"
exec /bin/sleep 30
EOF
    chmod +x "$stub_dir"/*

    export DP_DATASAFED_BIN_PATH="$stub_dir"
    export PATH="$stub_dir:$PATH"
    export DP_BACKUP_BASE_PATH=/
    export DP_DB_HOST=127.0.0.1
    export DP_DB_PORT=6379
    export DP_DB_PASSWORD=""
    export DP_BACKUP_INFO_FILE="$work_dir/backup-info.json"
    export DATA_DIR="$work_dir/data"
    export LOG_ARCHIVE_SECONDS=3
    export STUB_REMOTE="$work_dir/remote"
    export STUB_DATASAFED_LOG="$work_dir/datasafed.log"
    export STUB_SLEEP_LOG="$work_dir/sleep.log"
    export STUB_SERVER_ARGS="$work_dir/server.args"
    export STUB_SERVER_STATE="$work_dir/server.state"
    export FALKORDB_MODULE="$work_dir/falkordb.so"
    : > "$STUB_DATASAFED_LOG"
    : > "$STUB_SLEEP_LOG"
    : > "$STUB_SERVER_STATE"
    unset REDIS_CLI_TLS_CMD DP_TTL_SECONDS DP_RESTORE_KEY_PATTERNS DP_RESTORE_TIME \
      STUB_PUSH_RC STUB_PULL_RC STUB_RM_RC STUB_PUSH_FAIL_ONCE STUB_ROUNDS \
      MODE CLUSTER_STATUS_INTERVAL_SECONDS STUB_PING STUB_SERVER_RC FALKORDB_ARGS \
      STUB_ON_SLEEP STUB_FAILED_PRIMARY_SLOTS PITR_LOAD_TIMEOUT_SECONDS

    # The ActionSets prepend common-scripts.sh (and switch-data-dir.sh for
    # restore), each part on its own lines; common-scripts.sh has no final newline.
    join_scripts common-scripts.sh pitr-backup.sh > "$work_dir/backup.sh"
    join_scripts common-scripts.sh switch-data-dir.sh pitr-restore-common.sh pitr-restore.sh > "$work_dir/restore.sh"
    # falkordb-cluster-for-pitr-v2: prepareData, then the postReady job that rebuilds the RDB
    join_scripts common-scripts.sh pitr-restore-common.sh pitr-restore-cluster-users.sh > "$work_dir/restore-cluster-users.sh"
    join_scripts common-scripts.sh pitr-restore-common.sh pitr-restore-cluster-data.sh > "$work_dir/restore-cluster-data.sh"
  }

  join_scripts() {
    local part
    for part in "$@"; do
      cat "$dp_dir/$part"
      echo
    done
  }

  cleanup() {
    rm -rf "$work_dir"
  }

  BeforeEach 'setup'
  AfterEach 'cleanup'

  # tar -v lists members on stdout or stderr depending on the tar and the
  # mode (GNU tar extracting: stdout; bsdtar: stderr), so both streams are
  # merged into the output. SHELLSPEC_SHELL is the --shell interpreter, so a
  # bash 3.2 run really runs the scripts under bash 3.2.
  run_backup() {
    (cd "$work_dir/run" && "$SHELLSPEC_SHELL" "$work_dir/backup.sh" 2>&1)
  }

  run_restore() {
    (cd "$work_dir/run" && "$SHELLSPEC_SHELL" "$work_dir/restore.sh" 2>&1)
  }

  run_restore_cluster_users() {
    (cd "$work_dir/run" && "$SHELLSPEC_SHELL" "$work_dir/restore-cluster-users.sh" 2>&1)
  }

  run_restore_cluster_data() {
    (cd "$work_dir/run" && "$SHELLSPEC_SHELL" "$work_dir/restore-cluster-data.sh" 2>&1)
  }

  # This archiver is shard-a of a three shard Backup; shard-b and shard-c
  # published their ranges earlier.
  prepare_sharded_backup() {
    export MODE=cluster
    export CLUSTER_STATUS_INTERVAL_SECONDS=0
    export DP_BACKUP_BASE_PATH=/fdb-aof/shard-a
    prepare_rewritten_aof
    rm -rf "$STUB_REMOTE/1000.1.dir"
    echo "file appendonly.aof.1.incr.aof seq 1 type i" > "$DATA_DIR/appendonlydir/appendonly.aof.manifest"
    mkdir -p "$STUB_REMOTE/fdb-aof/shard-b" "$STUB_REMOTE/fdb-aof/shard-c"
    echo "900 1800" > "$STUB_REMOTE/fdb-aof/shard-b/kb-archive-range"
    echo "1200 1950" > "$STUB_REMOTE/fdb-aof/shard-c/kb-archive-range"
  }

  backup_info() {
    cat "$DP_BACKUP_INFO_FILE"
  }

  # Redis has rewritten the AOF to seq 2, so seq 1 is ready to be archived.
  prepare_rewritten_aof() {
    echo "file appendonly.aof.2.incr.aof seq 2 type i" > "$DATA_DIR/appendonlydir/appendonly.aof.manifest"
    echo "base-1" > "$DATA_DIR/appendonlydir/appendonly.aof.1.base.rdb"
    echo "incr-1" > "$DATA_DIR/appendonlydir/appendonly.aof.1.incr.aof"
    echo "user default on nopass ~* +@all" > "$DATA_DIR/users.acl"
    # what an earlier round uploaded while seq 1 was the live AOF
    mkdir -p "$STUB_REMOTE/1000.1.dir/appendonlydir"
    echo "incr-1" > "$STUB_REMOTE/1000.1.dir/appendonlydir/appendonly.aof.1.incr.aof"
  }

  # A tar that writes part of a stream and then fails, like a read error
  # half way through a file.
  fail_tar_after_writing() {
    cat > "$stub_dir/tar" <<'EOF'
#!/bin/sh
echo "partial"
echo "tar: read error" >&2
exit 2
EOF
    chmod +x "$stub_dir/tar"
  }

  # The files a seq 1 archive holds, rooted the way the restore extracts them.
  write_backup_tree() {
    local root=$1
    mkdir -p "$root/appendonlydir"
    printf '%s\n' "file appendonly.aof.1.incr.aof seq 1 type i" "file appendonly.aof.1.base.rdb seq 1 type b" \
      > "$root/appendonlydir/appendonly.aof.manifest"
    echo "base-1" > "$root/appendonlydir/appendonly.aof.1.base.rdb"
    printf '%s\n' "#TS:1100" "SET a 1" "#TS:1600" "SET b 2" > "$root/appendonlydir/appendonly.aof.1.incr.aof"
    echo "user default on nopass ~* +@all" > "$root/users.acl"
  }

  prepare_remote_archive() {
    write_backup_tree "$work_dir/archive"
    (cd "$work_dir/archive" && tar -cf "$STUB_REMOTE/1000.1.tar.zst" .)
  }

  # pitr-backup.sh names the tar members without a ./ prefix
  prepare_remote_archive_as_backed_up() {
    write_backup_tree "$work_dir/archive"
    (cd "$work_dir/archive" && tar -cf "$STUB_REMOTE/1000.1.tar.zst" appendonlydir users.acl)
  }

  prepare_remote_dir() {
    write_backup_tree "$STUB_REMOTE/1000.1.dir"
  }

  # Real RESP framing, with NUL bytes in the value written before the restore
  # time and a NUL-free write after it.
  write_binary_incr() {
    local incr="$STUB_REMOTE/1000.1.dir/appendonlydir/appendonly.aof.1.incr.aof"
    printf '#TS:1100\r\n*3\r\n$3\r\nSET\r\n$3\r\nbin\r\n$5\r\na\000b\000c\r\n' > "$work_dir/expected.aof"
    { cat "$work_dir/expected.aof"; printf '#TS:1600\r\n*3\r\n$3\r\nSET\r\n$4\r\nlate\r\n$1\r\n1\r\n'; } > "$incr"
  }

  restored_incr_matches_expected() {
    cmp "$work_dir/expected.aof" "$DATA_DIR/appendonlydir/appendonly.aof.1.incr.aof"
  }

  restored_incr() {
    cat "$DATA_DIR/appendonlydir/appendonly.aof.1.incr.aof"
  }

  archived_files() {
    tar -tf "$STUB_REMOTE/1000.1.tar.zst" | sed 's|^\./||' | sort | tr '\n' ' '
  }

  incr_pushes() {
    grep -c '^push .*appendonly.aof.1.incr.aof 1000.1.dir/' "$STUB_DATASAFED_LOG"
  }

  Describe "pitr-backup.sh"
    It "archives a rewritten seq, then drops its remote .dir and local files"
      prepare_rewritten_aof
      When run run_backup
      The status should be success
      The output should include "Archived files"
      The output should include "Terminating..."
      The output should include "appendonly.aof.1.incr.aof"
      The result of function archived_files should equal "appendonlydir/appendonly.aof.1.base.rdb appendonlydir/appendonly.aof.1.incr.aof appendonlydir/appendonly.aof.manifest users.acl "
      The path "$STUB_REMOTE/1000.1.dir" should not be exist
      The path "$DATA_DIR/appendonlydir/appendonly.aof.1.base.rdb" should not be exist
      The path "$DATA_DIR/appendonlydir/appendonly.aof.1.incr.aof" should not be exist
    End

    It "keeps the local files and the remote .dir and exits non-zero when the archive upload fails"
      prepare_rewritten_aof
      export STUB_PUSH_RC=42
      When run run_backup
      The status should be failure
      The output should include "ERROR: archive_pair_files: failed to archive"
      The output should include "push: 42"
      The output should not include "Archived files"
      The output should not include "Terminating..."
      The output should include "appendonly.aof.1.incr.aof"
      The contents of file "$STUB_DATASAFED_LOG" should not include "rm -r"
      The path "$STUB_REMOTE/1000.1.dir/appendonlydir/appendonly.aof.1.incr.aof" should be exist
      The path "$DATA_DIR/appendonlydir/appendonly.aof.1.base.rdb" should be exist
      The path "$DATA_DIR/appendonlydir/appendonly.aof.1.incr.aof" should be exist
    End

    It "keeps the local files and uploads nothing when a tracked file cannot be read"
      prepare_rewritten_aof
      rm "$DATA_DIR/users.acl"
      When run run_backup
      The status should be failure
      The output should include "ERROR: archive_pair_files: cannot read $DATA_DIR/users.acl, not archiving 1000.1.tar.zst"
      The contents of file "$STUB_DATASAFED_LOG" should not include "push -z"
      The path "$STUB_REMOTE/1000.1.tar.zst" should not be exist
      The contents of file "$STUB_DATASAFED_LOG" should not include "rm -r"
      The path "$STUB_REMOTE/1000.1.dir/appendonlydir/appendonly.aof.1.incr.aof" should be exist
      The path "$DATA_DIR/appendonlydir/appendonly.aof.1.base.rdb" should be exist
      The path "$DATA_DIR/appendonlydir/appendonly.aof.1.incr.aof" should be exist
    End

    It "uploads nothing when the backup manifest cannot be written"
      prepare_rewritten_aof
      # a directory in the manifest's place makes the write fail, even for root
      mkdir -p "$work_dir/run/appendonlydir/appendonly.aof.manifest"
      When run run_backup
      The status should be failure
      The output should include "ERROR: archive_pair_files: failed to write the backup manifest, not archiving 1000.1.tar.zst"
      The contents of file "$STUB_DATASAFED_LOG" should not include "push"
      The path "$DATA_DIR/appendonlydir/appendonly.aof.1.incr.aof" should be exist
    End

    It "names an incomplete archive it could not remove"
      prepare_rewritten_aof
      fail_tar_after_writing
      export STUB_RM_RC=42
      When run run_backup
      The status should be failure
      The output should include "ERROR: archive_pair_files: failed to remove the incomplete 1000.1.tar.zst"
      The path "$DATA_DIR/appendonlydir/appendonly.aof.1.incr.aof" should be exist
    End

    It "drops the incomplete archive when tar fails after streaming part of it"
      prepare_rewritten_aof
      fail_tar_after_writing
      When run run_backup
      The status should be failure
      The output should include "(tar: 2, push: 0)"
      The path "$STUB_REMOTE/1000.1.tar.zst" should not be exist
      The path "$STUB_REMOTE/1000.1.dir/appendonlydir/appendonly.aof.1.incr.aof" should be exist
      The path "$DATA_DIR/appendonlydir/appendonly.aof.1.incr.aof" should be exist
    End

    It "keeps, and flags, the archive of an earlier run when the retry's tar fails mid-stream"
      prepare_rewritten_aof
      echo "complete archive" > "$STUB_REMOTE/1000.1.tar.zst"
      fail_tar_after_writing
      When run run_backup
      The status should be failure
      The output should include "ERROR: archive_pair_files: 1000.1.tar.zst from an earlier run may have been overwritten"
      The contents of file "$STUB_DATASAFED_LOG" should not include "rm "
      The path "$DATA_DIR/appendonlydir/appendonly.aof.1.incr.aof" should be exist
    End

    It "keeps the archive of an earlier run whose .dir removal failed when the retry's push fails"
      prepare_rewritten_aof
      echo "complete archive" > "$STUB_REMOTE/1000.1.tar.zst"
      export STUB_PUSH_RC=42
      When run run_backup
      The status should be failure
      The output should include "ERROR: archive_pair_files: failed to archive"
      The contents of file "$STUB_REMOTE/1000.1.tar.zst" should equal "complete archive"
      The contents of file "$STUB_DATASAFED_LOG" should not include "rm "
      The path "$DATA_DIR/appendonlydir/appendonly.aof.1.incr.aof" should be exist
    End

    It "keeps the local files and exits non-zero when the archived .dir cannot be removed"
      prepare_rewritten_aof
      export STUB_RM_RC=42
      When run run_backup
      The status should be failure
      The output should include "ERROR: archive_pair_files: failed to remove 1000.1.dir after archiving it to 1000.1.tar.zst"
      The output should not include "Archived files"
      The path "$STUB_REMOTE/1000.1.tar.zst" should be exist
      The path "$STUB_REMOTE/1000.1.dir/appendonlydir/appendonly.aof.1.incr.aof" should be exist
      The path "$DATA_DIR/appendonlydir/appendonly.aof.1.base.rdb" should be exist
      The path "$DATA_DIR/appendonlydir/appendonly.aof.1.incr.aof" should be exist
    End

    It "uploads the live AOF to the seq's .dir"
      prepare_rewritten_aof
      echo "file appendonly.aof.1.incr.aof seq 1 type i" > "$DATA_DIR/appendonlydir/appendonly.aof.manifest"
      When run run_backup
      The status should be success
      The output should include "Update file: $DATA_DIR/appendonlydir/appendonly.aof.1.incr.aof"
      The path "$STUB_REMOTE/1000.1.dir/appendonlydir/appendonly.aof.1.base.rdb" should be exist
      The path "$STUB_REMOTE/1000.1.dir/users.acl" should be exist
      The path "$DATA_DIR/appendonlydir/appendonly.aof.1.incr.aof" should be exist
    End

    It "uploads a new seq whole even when its files are older than the last upload round"
      prepare_rewritten_aof
      echo "file appendonly.aof.1.incr.aof seq 1 type i" > "$DATA_DIR/appendonlydir/appendonly.aof.manifest"
      # A rewrite that started before round 1 (now is 2000) and finished after it:
      # its base (ctime 1000) and idle incr (mtime 1500) are older than round 1.
      export STUB_ON_SLEEP='
        d="$DATA_DIR/appendonlydir"
        echo base-2 > "$d/appendonly.aof.2.base.rdb"
        echo incr-2 > "$d/appendonly.aof.2.incr.aof"
        echo "file appendonly.aof.2.incr.aof seq 2 type i" > "$d/appendonly.aof.manifest"'
      export STUB_ROUNDS=2
      When run run_backup
      The status should be success
      The output should include "Archived files"
      The path "$STUB_REMOTE/1000.1.tar.zst" should be exist
      The path "$STUB_REMOTE/1000.2.dir/appendonlydir/appendonly.aof.2.base.rdb" should be exist
      The path "$STUB_REMOTE/1000.2.dir/appendonlydir/appendonly.aof.2.incr.aof" should be exist
      The path "$STUB_REMOTE/1000.2.dir/users.acl" should be exist
    End

    It "retries a failed upload of the live AOF on the next round"
      prepare_rewritten_aof
      echo "file appendonly.aof.1.incr.aof seq 1 type i" > "$DATA_DIR/appendonlydir/appendonly.aof.manifest"
      export STUB_PUSH_FAIL_ONCE="appendonly.aof.1.incr.aof"
      export STUB_ROUNDS=2
      When run run_backup
      The status should be success
      The output should include "ERROR: update_aof_file: failed to upload $DATA_DIR/appendonlydir/appendonly.aof.1.incr.aof"
      The output should include "Update file: $DATA_DIR/appendonlydir/appendonly.aof.1.incr.aof"
      The result of function incr_pushes should equal 2
    End
  End

  Describe "pitr-restore.sh"
    It "restores a tar.zst archive and truncates the AOF at the restore time"
      prepare_remote_archive
      export DP_RESTORE_TIME=restore-at-1500
      When run run_restore
      The status should be success
      The output should include "Restore complete."
      The output should include "appendonly.aof.1.incr.aof"
      The result of function restored_incr should equal "#TS:1100
SET a 1"
      The path "$DATA_DIR/users.acl" should be exist
      The path "$DATA_DIR/.kb-data-protection" should not be exist
    End

    It "restores a .dir and truncates the AOF at the restore time"
      prepare_remote_dir
      export DP_RESTORE_TIME=restore-at-1500
      When run run_restore
      The status should be success
      The output should include "Pull directory: 1000.1.dir/"
      The output should include "Restore complete."
      The result of function restored_incr should equal "#TS:1100
SET a 1"
      The path "$DATA_DIR/appendonlydir/appendonly.aof.manifest" should be exist
      The path "$DATA_DIR/.kb-data-protection" should not be exist
    End

    It "keeps NUL bytes in the AOF it truncates"
      prepare_remote_dir
      write_binary_incr
      export DP_RESTORE_TIME=restore-at-1500
      When run run_restore
      The status should be success
      The output should include "Truncate aof file: $DATA_DIR/appendonlydir/appendonly.aof.1.incr.aof at byte 43"
      The output should include "Restore complete."
      Assert restored_incr_matches_expected
    End

    It "leaves the AOF alone when nothing in it is after the restore time"
      prepare_remote_dir
      write_binary_incr
      cp "$STUB_REMOTE/1000.1.dir/appendonlydir/appendonly.aof.1.incr.aof" "$work_dir/expected.aof"
      export DP_RESTORE_TIME=restore-at-1700
      When run run_restore
      The status should be success
      The output should not include "Truncate aof file"
      The output should include "Restore complete."
      Assert restored_incr_matches_expected
    End

    It "fails rather than restore an AOF it cannot read uncut"
      prepare_remote_dir
      # a grep that cannot read the file, as on an I/O error
      printf '#!/bin/sh\necho "grep: read error" >&2\nexit 2\n' > "$stub_dir/grep"
      chmod +x "$stub_dir/grep"
      export DP_RESTORE_TIME=restore-at-1500
      When run run_restore
      The status should be failure
      The output should include "ERROR: Failed to read aof file: $DATA_DIR/appendonlydir/appendonly.aof.1.incr.aof"
      The output should not include "Restore complete."
    End

    It "fails when no archive starts at or before the restore time"
      prepare_remote_archive
      export DP_RESTORE_TIME=restore-at-500
      When run run_restore
      The status should be failure
      The output should include "ERROR: No backup found for the given restore time: restore-at-500"
      The output should not include "Restore complete."
      The path "$DATA_DIR/.kb-data-protection" should be exist
    End

    It "fails when the restore time cannot be parsed"
      prepare_remote_archive
      export DP_RESTORE_TIME=yesterday-ish
      When run run_restore
      The status should be failure
      The output should include "ERROR: Invalid restore time: yesterday-ish"
      The output should include "invalid date"
      The output should not include "Restore complete."
    End

    It "fails when the tar.zst pull fails, even if tar read what it got"
      prepare_remote_archive
      export DP_RESTORE_TIME=restore-at-1500
      export STUB_PULL_RC=42
      When run run_restore
      The status should be failure
      The output should include "ERROR: Failed to pull or extract 1000.1.tar.zst (pull: 42, tar: 0)"
      The output should include "appendonly.aof.1.incr.aof"
      The output should not include "Restore complete."
      The path "$DATA_DIR/.kb-data-protection" should be exist
    End

    It "fails when the tar.zst cannot be extracted"
      echo "not a tar" > "$STUB_REMOTE/1000.1.tar.zst"
      export DP_RESTORE_TIME=restore-at-1500
      When run run_restore
      The status should be failure
      The output should include "ERROR: Failed to pull or extract 1000.1.tar.zst (pull: 0, tar:"
      The output should not include "Restore complete."
    End

    It "fails when a file of the .dir cannot be pulled"
      prepare_remote_dir
      export DP_RESTORE_TIME=restore-at-1500
      export STUB_PULL_RC=42
      When run run_restore
      The status should be failure
      The output should include "ERROR: DP_pull_directory: failed to pull 1000.1.dir/"
      The output should include "ERROR: Failed to pull directory: 1000.1.dir/"
      The output should not include "Restore complete."
      The path "$DATA_DIR/.kb-data-protection" should be exist
    End

    It "fails when the .dir is empty"
      mkdir -p "$STUB_REMOTE/1000.1.dir"
      export DP_RESTORE_TIME=restore-at-1500
      When run run_restore
      The status should be failure
      The output should include "ERROR: DP_pull_directory: failed to list files in 1000.1.dir/"
      The output should not include "Restore complete."
    End

    It "fails on an object that is neither a .dir nor a tar.zst"
      echo "junk" > "$STUB_REMOTE/1000.1.bad"
      export DP_RESTORE_TIME=restore-at-1500
      When run run_restore
      The status should be failure
      The output should include "ERROR: Unknown aof_file type: 1000.1.bad"
      The output should not include "Restore complete."
      The path "$DATA_DIR/.kb-data-protection" should be exist
    End
  End

  Describe "pitr-backup.sh in a sharded cluster"
    It "publishes its shard's range and reports the time every shard covers"
      prepare_sharded_backup
      When run run_backup
      The status should be success
      The output should include "Update file: $DATA_DIR/appendonlydir/appendonly.aof.1.incr.aof"
      The path "$STUB_REMOTE/fdb-aof/shard-a/1000.1.dir/appendonlydir/appendonly.aof.1.incr.aof" should be exist
      # the archive starts at its base; the round that started at 2000 covers up to 1999,
      # less the 3s the server may hold back its AOF write
      The contents of file "$STUB_REMOTE/fdb-aof/shard-a/kb-archive-range" should equal "1000 1996"
      The result of function backup_info should include '"timeRange":{"start":"T1200","end":"T1800"}'
      The result of function backup_info should include '{"shard":"shard-a","start":"T1000","end":"T1996"}'
      The result of function backup_info should include '{"shard":"shard-b","start":"T900","end":"T1800"}'
      The result of function backup_info should include '{"shard":"shard-c","start":"T1200","end":"T1950"}'
    End

    It "ignores the stopped range of a shard removed by a scale-in"
      prepare_sharded_backup
      # a fourth shard, gone from the cluster, whose archiver stopped at 1500
      mkdir -p "$STUB_REMOTE/fdb-aof/shard-d"
      echo "800 1500" > "$STUB_REMOTE/fdb-aof/shard-d/kb-archive-range"
      When run run_backup
      The status should be success
      The output should include "ignoring shard-d, whose archive stopped at 1500: the cluster has 3 shards"
      The result of function backup_info should include '"timeRange":{"start":"T1200","end":"T1800"}'
      The result of function backup_info should not include '"shard":"shard-d"'
    End

    It "counts a failed primary that still owns slots as a shard"
      prepare_sharded_backup
      export STUB_FAILED_PRIMARY_SLOTS=0-10
      When run run_backup
      The status should be success
      The output should include "3 of 4 shards have archived"
      The result of function backup_info should include '"timeRange":null'
    End

    It "removes its range once retention has removed every archive"
      prepare_sharded_backup
      # nothing left to archive or restore: no live AOF, no archive in the repo
      rm "$DATA_DIR"/appendonlydir/appendonly.aof.1.*
      mkdir -p "$STUB_REMOTE/fdb-aof/shard-a"
      echo "1000 1999" > "$STUB_REMOTE/fdb-aof/shard-a/kb-archive-range"
      When run run_backup
      The status should be success
      The output should include "update_aof_file:"
      The path "$STUB_REMOTE/fdb-aof/shard-a/kb-archive-range" should not be exist
      The output should include "2 of 3 shards have archived"
      The result of function backup_info should include '"timeRange":null'
    End

    It "withdraws the window while a shard has archived nothing"
      prepare_sharded_backup
      rm "$STUB_REMOTE/fdb-aof/shard-c/kb-archive-range"
      When run run_backup
      The status should be success
      The output should include "2 of 3 shards have archived"
      The result of function backup_info should include '"timeRange":null'
    End

    It "withdraws the window when the shards share no time"
      prepare_sharded_backup
      echo "1900 1950" > "$STUB_REMOTE/fdb-aof/shard-c/kb-archive-range"
      When run run_backup
      The status should be success
      The output should include "they share no time yet"
      The result of function backup_info should include '"timeRange":null'
    End

    It "claims no time for its shard while the live AOF cannot be uploaded"
      prepare_sharded_backup
      export STUB_PUSH_RC=42
      When run run_backup
      The status should be success
      The output should include "ERROR: update_aof_file: failed to upload"
      The path "$STUB_REMOTE/fdb-aof/shard-a/kb-archive-range" should not be exist
      The result of function backup_info should include '"timeRange":null'
    End
  End

  Describe "pitr-restore-cluster-users.sh"
    It "restores only users.acl from a tar.zst archive"
      prepare_remote_archive_as_backed_up
      export DP_RESTORE_TIME=restore-at-1500
      When run run_restore_cluster_users
      The status should be success
      The output should include "Restored users.acl from 1000.1.tar.zst"
      The contents of file "$DATA_DIR/users.acl" should equal "user default on nopass ~* +@all"
      The path "$DATA_DIR/appendonlydir/appendonly.aof.manifest" should not be exist
      The path "$DATA_DIR/.kb-data-protection" should not be exist
    End

    It "restores only users.acl from a .dir"
      prepare_remote_dir
      export DP_RESTORE_TIME=restore-at-1500
      When run run_restore_cluster_users
      The status should be success
      The output should include "Restored users.acl from 1000.1.dir/"
      The contents of file "$DATA_DIR/users.acl" should equal "user default on nopass ~* +@all"
      The path "$DATA_DIR/appendonlydir/appendonly.aof.manifest" should not be exist
    End

    It "fails when no archive starts at or before the restore time"
      prepare_remote_archive_as_backed_up
      export DP_RESTORE_TIME=restore-at-500
      When run run_restore_cluster_users
      The status should be failure
      The output should include "ERROR: No backup found for the given restore time: restore-at-500"
      The path "$DATA_DIR/users.acl" should not be exist
    End
  End

  Describe "pitr-restore-cluster-data.sh"
    # the stub server's "RDB" is the AOF it was given
    rebuilt_rdb() {
      cat "$DATA_DIR/kb-dp-dump.rdb"
    }

    It "replays the AOF cut at the restore time and leaves its RDB for restore-cluster.sh"
      prepare_remote_archive_as_backed_up
      touch "$FALKORDB_MODULE"
      export DP_RESTORE_TIME=restore-at-1500
      When run run_restore_cluster_data
      The status should be success
      The output should include "Replayed 1000.1.tar.zst to restore-at-1500 in $DATA_DIR/kb-dp-dump.rdb"
      The result of function rebuilt_rdb should equal "#TS:1100
SET a 1"
      The contents of file "$STUB_SERVER_ARGS" should include "--appendonly yes --appenddirname appendonlydir --appendfilename appendonly.aof --dbfilename kb-dp-dump.rdb"
      The contents of file "$STUB_SERVER_ARGS" should include "--loadmodule $FALKORDB_MODULE"
      The path "$DATA_DIR/.kb-pitr-restore" should not be exist
      The path "$DATA_DIR/users.acl" should not be exist
    End

    It "fails when the server is still loading at the deadline"
      prepare_remote_dir
      export DP_RESTORE_TIME=restore-at-1500
      export STUB_PING="LOADING Redis is loading the dataset in memory"
      export PITR_LOAD_TIMEOUT_SECONDS=0
      When run run_restore_cluster_data
      The status should be failure
      The output should include "ERROR: The server replaying 1000.1.dir/ did not load the AOF within 0s"
      The path "$DATA_DIR/kb-dp-dump.rdb" should not be exist
    End

    It "fails when the server exits instead of loading the AOF"
      prepare_remote_dir
      export DP_RESTORE_TIME=restore-at-1500
      export STUB_PING="Could not connect to Redis"
      export STUB_SERVER_RC=1
      # the wait loop sleeps while the server starts; do not let the stub end the run
      export STUB_ROUNDS=1000000
      When run run_restore_cluster_data
      The status should be failure
      The output should include "ERROR: The server replaying 1000.1.dir/ exited before it loaded the AOF"
      The path "$DATA_DIR/kb-dp-dump.rdb" should not be exist
    End

    It "fails when no archive starts at or before the restore time"
      prepare_remote_dir
      export DP_RESTORE_TIME=restore-at-500
      When run run_restore_cluster_data
      The status should be failure
      The output should include "ERROR: No backup found for the given restore time: restore-at-500"
      The path "$STUB_SERVER_ARGS" should not be exist
    End
  End
End

#!/bin/bash
# shellcheck disable=SC2034

# pitr-backup.sh and pitr-restore.sh run top to bottom, so these cases build
# each one the way the falkordb-for-pitr ActionSet does (common-scripts.sh
# first) and run it against stub datasafed, redis-cli, redis-check-rdb, date,
# stat and sleep binaries. The datasafed stub keeps the backup repo in a local
# directory, so a case can check what was uploaded, removed or restored.
Describe "FalkorDB PITR dataprotection scripts"
  setup() {
    # Resolved before the scripts change into the work directory.
    dp_dir="$(cd ../dataprotection && pwd)"
    work_dir="$(mktemp -d)"
    stub_dir="$work_dir/bin"
    mkdir -p "$stub_dir" "$work_dir/run" "$work_dir/remote" "$work_dir/data/appendonlydir"

    # `datasafed list|push|pull|rm|stat` over the directory $STUB_REMOTE.
    # STUB_PUSH_RC / STUB_PULL_RC make push / pull fail; STUB_PUSH_FAIL_ONCE
    # fails only the first push whose remote path contains it.
    cat > "$stub_dir/datasafed" <<'EOF'
#!/bin/bash
echo "$*" >> "$STUB_DATASAFED_LOG"
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
*) echo OK ;;
esac
EOF
    # Every base file was created at 1000.
    cat > "$stub_dir/redis-check-rdb" <<'EOF'
#!/bin/sh
echo "[offset 0] Checking RDB file $1"
echo "[info] ctime '1000'"
EOF
    # Now is 2000; `date -d` parses the restore times the cases use.
    cat > "$stub_dir/date" <<'EOF'
#!/bin/sh
if [ "$1" = "-d" ]; then
  case "$2" in
  restore-at-1500) echo 1500 ;;
  restore-at-500) echo 500 ;;
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
[ "$(wc -l < "$STUB_SLEEP_LOG")" -ge "${STUB_ROUNDS:-1}" ] && kill -TERM "$PPID"
exit 0
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
    : > "$STUB_DATASAFED_LOG"
    : > "$STUB_SLEEP_LOG"
    unset REDIS_CLI_TLS_CMD DP_TTL_SECONDS DP_RESTORE_KEY_PATTERNS DP_RESTORE_TIME \
      STUB_PUSH_RC STUB_PULL_RC STUB_PUSH_FAIL_ONCE STUB_ROUNDS

    # The ActionSets prepend common-scripts.sh (and switch-data-dir.sh for
    # restore), each part on its own lines; common-scripts.sh has no final newline.
    join_scripts common-scripts.sh pitr-backup.sh > "$work_dir/backup.sh"
    join_scripts common-scripts.sh switch-data-dir.sh pitr-restore.sh > "$work_dir/restore.sh"
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
  # merged into the output.
  run_backup() {
    (cd "$work_dir/run" && bash "$work_dir/backup.sh" 2>&1)
  }

  run_restore() {
    (cd "$work_dir/run" && bash "$work_dir/restore.sh" 2>&1)
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

  prepare_remote_dir() {
    write_backup_tree "$STUB_REMOTE/1000.1.dir"
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

    It "keeps the local files when tar cannot read the tracked files"
      prepare_rewritten_aof
      rm "$DATA_DIR/users.acl"
      When run run_backup
      The status should be failure
      The output should include "ERROR: archive_pair_files: failed to archive"
      The output should include "users.acl"
      The path "$STUB_REMOTE/1000.1.tar.zst" should not be exist
      The contents of file "$STUB_DATASAFED_LOG" should not include "rm -r"
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
End

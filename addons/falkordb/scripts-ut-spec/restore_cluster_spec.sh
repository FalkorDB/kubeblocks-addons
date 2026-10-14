#!/bin/bash
# shellcheck disable=SC2034

# restore-cluster.sh runs top to bottom with no functions to call, so these
# cases run the real script against stub datasafed and ape-dts binaries and
# check the dts.ini it wrote and the status it exited with.
Describe "FalkorDB sharded restore script"
  # The script runs ape-dts under `timeout` in every case, so without it (or
  # macOS's gtimeout, linked in below) every example would exit 127.
  timeout_not_available() {
    ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1
  }
  Skip if "neither timeout nor gtimeout is installed" timeout_not_available

  setup() {
    # Resolved before run_restore changes into the work directory.
    restore_script="$(cd ../dataprotection && pwd)/restore-cluster.sh"
    work_dir="$(mktemp -d)"
    stub_dir="$work_dir/bin"
    mkdir -p "$stub_dir" "$work_dir/data"

    cat > "$stub_dir/datasafed" <<'EOF'
#!/bin/sh
# `datasafed pull -d <decoder> <remote> <local>`: the dump the script reads.
eval "out=\${$#}"
: > "$out"
EOF
    # Records the dts.ini it was given, then exits with STUB_APE_DTS_RC.
    cat > "$stub_dir/ape-dts" <<'EOF'
#!/bin/sh
cp "$1" "$STUB_RECORDED_INI"
[ -z "$STUB_APE_DTS_SLEEP" ] || sleep "$STUB_APE_DTS_SLEEP"
exit "${STUB_APE_DTS_RC:-0}"
EOF
    chmod +x "$stub_dir/datasafed" "$stub_dir/ape-dts"
    # macOS ships coreutils timeout as gtimeout.
    if ! command -v timeout >/dev/null 2>&1 && command -v gtimeout >/dev/null 2>&1; then
      ln -s "$(command -v gtimeout)" "$stub_dir/timeout"
    fi

    export DP_DATASAFED_BIN_PATH="$stub_dir"
    export PATH="$stub_dir:$PATH"
    export DP_BACKUP_BASE_PATH=/backups
    export DP_BACKUP_NAME=fdb-backup
    export DATA_DIR="$work_dir/data"
    export DP_DB_HOST=fdb-shard-abc-0.fdb-shard-abc-headless
    export DP_DB_PORT=6379
    export REDIS_DEFAULT_PASSWORD=secret
    export APE_DTS_BIN="$stub_dir/ape-dts"
    export STUB_RECORDED_INI="$work_dir/recorded.ini"
    unset REDIS_CLI_TLS_CMD STUB_APE_DTS_RC STUB_APE_DTS_SLEEP APE_DTS_RESTORE_TIMEOUT
  }

  cleanup() {
    rm -rf "$work_dir"
  }

  BeforeEach 'setup'
  AfterEach 'cleanup'

  run_restore() {
    (cd "$work_dir" && sh "$restore_script")
  }

  sinker_url() {
    awk '/^\[sinker\]/ {s = 1} s && /^url=/ {sub(/^url=/, ""); print; exit}' "$STUB_RECORDED_INI"
  }

  Describe "the sinker URL"
    It "is plaintext redis:// when TLS is off"
      When run run_restore
      The status should be success
      The result of function sinker_url should equal "redis://default:secret@fdb-shard-abc-0.fdb-shard-abc-headless:6379"
    End

    It "is rediss:// when the job's redis-cli flags ask for TLS"
      export REDIS_CLI_TLS_CMD="--tls --insecure"
      When run run_restore
      The status should be success
      The result of function sinker_url should equal "rediss://default:secret@fdb-shard-abc-0.fdb-shard-abc-headless:6379"
    End
  End

  Describe "a failed ape-dts run"
    It "fails the restore with ape-dts's own status"
      export STUB_APE_DTS_RC=101
      When run run_restore
      The status should equal 101
      The stderr should include "ape-dts failed with status 101"
    End

    It "fails the restore when ape-dts runs past the timeout"
      export STUB_APE_DTS_SLEEP=5
      export APE_DTS_RESTORE_TIMEOUT=1
      When run run_restore
      The status should equal 124
      The stderr should include "did not finish within 1s"
    End
  End
End

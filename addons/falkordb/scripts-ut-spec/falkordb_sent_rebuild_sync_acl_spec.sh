# shellcheck shell=bash
# shellcheck disable=SC2034

# validate_shell_type_and_version defined in shellspec/spec_helper.sh used to validate the expected shell type and version this script needs to run.
if ! validate_shell_type_and_version "bash" 4 &>/dev/null; then
  echo "falkordb_sent_rebuild_sync_acl_spec.sh skip all cases because dependency bash version 4 or higher is not installed."
  exit 0
fi

source ./utils.sh

# The unit test needs to rely on the common library functions defined in kblib.
# Therefore, we first dynamically generate the required common library files from the kblib library chart.
common_library_file="./common.sh"
generate_common_library $common_library_file

Describe "FalkorDB Sentinel Rebuild ACL Sync Script Tests"

  # copy_sentinel_acl and sentinel_cli_argv come from the member-join script,
  # which the ops pod sources the same way.
  Include ../scripts/falkordb-sent-member-join.sh
  Include ../scripts/falkordb-sent-rebuild-sync-acl.sh
  Include $common_library_file

  init() {
    # set ut_mode to true to hack control flow in the script
    ut_mode="true"
    sentinel_acl_log="./sentinel-rebuild-acl.log"
  }
  BeforeAll "init"

  cleanup() {
    rm -f ./sentinel-rebuild-acl.log
    rm -f $common_library_file
  }
  AfterAll 'cleanup'

  sent0="fdb-falkordb-sent-0.fdb-falkordb-sent-headless.test.svc"
  sent1="fdb-falkordb-sent-1.fdb-falkordb-sent-headless.test.svc"
  sent2="fdb-falkordb-sent-2.fdb-falkordb-sent-headless.test.svc"

  # Records every argument vector, one argument per line between markers. Every
  # sentinel but the ones in $not_monitoring monitors fdb-falkordb and holds the
  # same ACL, the rebuilt one only has default and a leftover user.
  stub_sentinel_cli_argv() {
    sentinel_cli_argv() {
      local host="$1"
      shift
      {
        echo "--- $host"
        printf '%s\n' "$@"
      } >> "$sentinel_acl_log"
      case "$1 $2" in
        "SENTINEL get-master-addr-by-name")
          if [[ " $not_monitoring " == *" $host "* ]] || [ "$3" != "$expected_master" ]; then
            echo ""
          else
            printf '10.42.0.11\n6379\n'
          fi
          ;;
        "ACL LIST")
          echo "user default on #d0 ~* &* +@all"
          echo "user alice on #a1 ~app:* resetchannels -@all +get (~cache:* resetchannels -@all +set)"
          ;;
        "ACL USERS")
          printf 'default\nstale\n'
          ;;
        *) echo "OK" ;;
      esac
    }
  }

  setup() {
    stub_sentinel_cli_argv
    rm -f "$sentinel_acl_log"
    not_monitoring=""
    expected_master="fdb-falkordb"
    REDIS_COMPONENT_NAME="fdb-falkordb"
    SENTINEL_POD_FQDN_LIST="$sent1,$sent2,$sent0"
    REBUILD_SENTINEL_POD_NAME="fdb-falkordb-sent-2"
  }
  Before 'setup'
  After 'unset REBUILD_SENTINEL_POD_NAME SENTINEL_POD_FQDN_LIST REDIS_COMPONENT_NAME CUSTOM_SENTINEL_MASTER_NAME'

  Describe "sync_acl_to_rebuilt_sentinel()"
    It "copies the ACL of the smallest established sentinel onto the rebuilt one"
      When call sync_acl_to_rebuilt_sentinel
      The status should be success
      The stdout should include "ACL of $sent2 now matches $sent0."
      The contents of file "$sentinel_acl_log" should include "--- $sent0
ACL
LIST"
      The contents of file "$sentinel_acl_log" should include "--- $sent2
ACL
SETUSER
alice
reset
on
#a1"
      The contents of file "$sentinel_acl_log" should not include "SETUSER
default"
    End

    It "keeps a selector as a single argument"
      When call sync_acl_to_rebuilt_sentinel
      The status should be success
      The stdout should include "syncing ACL user alice"
      The contents of file "$sentinel_acl_log" should include "+get
(~cache:* resetchannels -@all +set)
"
    End

    It "deletes users the source does not have and persists the ACL"
      When call sync_acl_to_rebuilt_sentinel
      The status should be success
      The stdout should include "deleting ACL user stale from $sent2"
      The contents of file "$sentinel_acl_log" should include "--- $sent2
ACL
DELUSER
stale"
      The contents of file "$sentinel_acl_log" should not include "DELUSER
default"
      The contents of file "$sentinel_acl_log" should include "--- $sent2
ACL
SAVE"
    End

    It "never writes to the source or to the other peers"
      When call sync_acl_to_rebuilt_sentinel
      The status should be success
      The stdout should include "now matches"
      The contents of file "$sentinel_acl_log" should not include "--- $sent0
ACL
SETUSER"
      The contents of file "$sentinel_acl_log" should not include "--- $sent1
ACL
SETUSER"
      The contents of file "$sentinel_acl_log" should not include "--- $sent0
ACL
SAVE"
    End

    It "never logs the password hashes"
      When call sync_acl_to_rebuilt_sentinel
      The status should be success
      The stdout should not include "#a1"
    End

    It "uses the next sentinel when the smallest one monitors nothing"
      not_monitoring="$sent0"
      When call sync_acl_to_rebuilt_sentinel
      The status should be success
      The stdout should include "ACL of $sent2 now matches $sent1."
      The stderr should include "sentinel $sent0 does not monitor fdb-falkordb"
    End

    It "never copies from the rebuilt sentinel, even when its name is the smallest"
      REBUILD_SENTINEL_POD_NAME="fdb-falkordb-sent-0"
      When call sync_acl_to_rebuilt_sentinel
      The status should be success
      The stdout should include "ACL of $sent0 now matches $sent1."
    End

    It "checks the peers under the custom master name"
      CUSTOM_SENTINEL_MASTER_NAME="mymaster"
      expected_master="mymaster"
      When call sync_acl_to_rebuilt_sentinel
      The status should be success
      The stdout should include "ACL of $sent2 now matches $sent0."
    End

    It "does nothing without REBUILD_SENTINEL_POD_NAME"
      unset REBUILD_SENTINEL_POD_NAME
      When call sync_acl_to_rebuilt_sentinel
      The status should be success
      The stdout should include "no rebuilt sentinel to sync the ACL to"
      The path "$sentinel_acl_log" should not be exist
    End

    It "fails when the rebuilt sentinel is not in SENTINEL_POD_FQDN_LIST"
      REBUILD_SENTINEL_POD_NAME="fdb-falkordb-sent-9"
      When call sync_acl_to_rebuilt_sentinel
      The status should be failure
      The stderr should include "sentinel pod fdb-falkordb-sent-9 is not in SENTINEL_POD_FQDN_LIST"
      The path "$sentinel_acl_log" should not be exist
    End

    It "does not match a sentinel whose name only starts with the rebuilt one"
      SENTINEL_POD_FQDN_LIST="$sent0,fdb-falkordb-sent-10.fdb-falkordb-sent-headless.test.svc,$sent1"
      REBUILD_SENTINEL_POD_NAME="fdb-falkordb-sent-1"
      When call sync_acl_to_rebuilt_sentinel
      The status should be success
      The stdout should include "ACL of $sent1 now matches $sent0."
    End

    It "fails when SENTINEL_POD_FQDN_LIST is not set"
      unset SENTINEL_POD_FQDN_LIST
      When call sync_acl_to_rebuilt_sentinel
      The status should be failure
      The stderr should include "SENTINEL_POD_FQDN_LIST is not set"
    End

    It "fails when no other sentinel monitors the master"
      not_monitoring="$sent0 $sent1"
      When call sync_acl_to_rebuilt_sentinel
      The status should be failure
      The stderr should include "no other sentinel monitors fdb-falkordb"
      The contents of file "$sentinel_acl_log" should not include "SETUSER"
    End

    It "fails when the source ACL cannot be read"
      sentinel_cli_argv() {
        case "$3 $4" in
          "get-master-addr-by-name fdb-falkordb") printf '10.42.0.11\n6379\n' ;;
          *) echo "NOPERM this user has no permissions to run the 'acl|list' command"; return 0 ;;
        esac
      }
      When call sync_acl_to_rebuilt_sentinel
      The status should be failure
      The stderr should include "failed to read the ACL of $sent0"
    End

    It "fails when ACL SAVE fails on the rebuilt sentinel"
      sentinel_cli_argv() {
        local host="$1"
        shift
        case "$1 $2" in
          "SENTINEL get-master-addr-by-name") printf '10.42.0.11\n6379\n' ;;
          "ACL LIST") echo "user default on #d0 ~* &* +@all" ;;
          "ACL USERS") echo "default" ;;
          "ACL SAVE") echo "ERR There was an error trying to save the ACLs" ;;
          *) echo "OK" ;;
        esac
      }
      When call sync_acl_to_rebuilt_sentinel
      The status should be failure
      The stderr should include "ACL SAVE failed on $sent2"
    End
  End

  Describe "is_established_sentinel()"
    It "rejects an error reply"
      sentinel_cli_argv() { echo "NOAUTH Authentication required."; }
      When call is_established_sentinel "$sent0" "fdb-falkordb"
      The status should be failure
    End

    It "rejects an unreachable sentinel"
      sentinel_cli_argv() { return 1; }
      When call is_established_sentinel "$sent0" "fdb-falkordb"
      The status should be failure
    End
  End
End

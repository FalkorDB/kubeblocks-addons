# shellcheck shell=bash
# shellcheck disable=SC2034

# validate_shell_type_and_version defined in shellspec/spec_helper.sh used to validate the expected shell type and version this script needs to run.
if ! validate_shell_type_and_version "bash" 4 &>/dev/null; then
  echo "falkordb_sentinel_member_join_spec.sh skip all cases because dependency bash version 4 or higher is not installed."
  exit 0
fi

source ./utils.sh

# The unit test needs to rely on the common library functions defined in kblib.
# Therefore, we first dynamically generate the required common library files from the kblib library chart.
common_library_file="./common.sh"
generate_common_library $common_library_file

Describe "FalkorDB Sentinel Member Join Script Tests"

  Include ../scripts/falkordb-sent-member-join.sh
  Include $common_library_file

  init() {
    # set ut_mode to true to hack control flow in the script
    ut_mode="true"
    redis_sentinel_real_conf="./redis-sentinel.conf"
    sentinel_cli_log="./sentinel-cli.log"
    sentinel_acl_log="./sentinel-acl.log"
  }
  BeforeAll "init"

  cleanup() {
    rm -f ./redis-sentinel.conf
    rm -f ./sentinel-cli.log
    rm -f ./sentinel-acl.log
    rm -f $common_library_file
  }
  AfterAll 'cleanup'

  # Records every command that would be sent to the joining sentinel and answers
  # the way a healthy sentinel does.
  stub_sentinel_cli() {
    sentinel_cli() {
      local host="$1"
      local command="$2"
      printf '%s|%s\n' "$host" "$command" >> "$sentinel_cli_log"
      case "$command" in
        ping) echo "PONG" ;;
        "SENTINEL get-master-addr-by-name"*) echo "" ;;
        *) echo "OK" ;;
      esac
    }
  }

  write_conf() {
    {
      echo "port 26379"
      echo "sentinel myid 4f1b7f0c"
      echo "sentinel monitor fdb-falkordb 10.42.0.11 6379 2"
      echo "sentinel down-after-milliseconds fdb-falkordb 5000"
      echo "sentinel failover-timeout fdb-falkordb 60000"
      echo "sentinel parallel-syncs fdb-falkordb 1"
      echo "sentinel auth-user fdb-falkordb kbreplicator-sentinel"
      echo "sentinel auth-pass fdb-falkordb s3cret"
      echo "sentinel known-replica fdb-falkordb 10.42.0.12 6379"
    } > "$redis_sentinel_real_conf"
  }

  setup() {
    redis_sentinel_real_conf="./redis-sentinel.conf"
    write_conf
    stub_sentinel_cli
    rm -f "$sentinel_cli_log"
    SENTINEL_PASSWORD="sentinel_password"
    KB_JOIN_MEMBER_POD_FQDN="fdb-falkordb-sent-2.fdb-falkordb-sent-headless.test.svc"
  }
  Before 'setup'

  un_setup() {
    unset SENTINEL_PASSWORD
    unset KB_JOIN_MEMBER_POD_FQDN
    unset SENTINEL_JOIN_MAX_RETRIES
  }
  After 'un_setup'

  Describe "monitored_master_names()"
    It "lists every monitored master"
      When call monitored_master_names
      The status should be success
      The stdout should include "fdb-falkordb"
    End

    Context "when the config file does not exist"
      missing_conf() { redis_sentinel_real_conf="./does-not-exist.conf"; }
      Before 'missing_conf'

      It "returns nothing"
        When call monitored_master_names
        The status should be success
        The stdout should equal ""
      End
    End
  End

  Describe "sentinel_conf_directive_value()"
    It "reads the monitor arguments"
      When call sentinel_conf_directive_value monitor fdb-falkordb
      The status should be success
      The stdout should equal "10.42.0.11 6379 2"
    End

    It "reads a single valued directive"
      When call sentinel_conf_directive_value auth-pass fdb-falkordb
      The status should be success
      The stdout should equal "s3cret"
    End

    It "returns nothing for a directive that is not configured"
      When call sentinel_conf_directive_value auth-pass other-master
      The status should be success
      The stdout should equal ""
    End
  End

  Describe "propagate_monitor_config_to_joining_member()"
    It "monitors the master on the joining sentinel and copies its settings"
      When call propagate_monitor_config_to_joining_member
      The status should be success
      The stdout should include "now monitors fdb-falkordb"
      The contents of file "$sentinel_cli_log" should include "SENTINEL monitor fdb-falkordb 10.42.0.11 6379 2"
      The contents of file "$sentinel_cli_log" should include "SENTINEL set fdb-falkordb down-after-milliseconds 5000"
      The contents of file "$sentinel_cli_log" should include "SENTINEL set fdb-falkordb failover-timeout 60000"
      The contents of file "$sentinel_cli_log" should include "SENTINEL set fdb-falkordb parallel-syncs 1"
      The contents of file "$sentinel_cli_log" should include "SENTINEL set fdb-falkordb auth-user kbreplicator-sentinel"
      The contents of file "$sentinel_cli_log" should include "SENTINEL set fdb-falkordb auth-pass s3cret"
      The contents of file "$sentinel_cli_log" should include "fdb-falkordb-sent-2"
    End

    Context "when the joining member is unknown"
      unset_fqdn() { unset KB_JOIN_MEMBER_POD_FQDN; }
      Before 'unset_fqdn'

      It "fails"
        When run propagate_monitor_config_to_joining_member
        The status should be failure
        The stderr should include "KB_JOIN_MEMBER_POD_FQDN is not set"
      End
    End

    Context "when this sentinel monitors no master"
      empty_conf() { : > "$redis_sentinel_real_conf"; }
      Before 'empty_conf'

      It "does nothing"
        When call propagate_monitor_config_to_joining_member
        The status should be success
        The stdout should include "monitors no master yet"
      End
    End

    Context "when the joining member already monitors the master"
      already_monitoring() {
        sentinel_cli() {
          local host="$1"
          local command="$2"
          printf '%s|%s\n' "$host" "$command" >> "$sentinel_cli_log"
          case "$command" in
            ping) echo "PONG" ;;
            "SENTINEL get-master-addr-by-name"*) printf '10.42.0.11\n6379\n' ;;
            *) echo "OK" ;;
          esac
        }
      }
      Before 'already_monitoring'

      It "refreshes the settings without re-monitoring it"
        When call propagate_monitor_config_to_joining_member
        The status should be success
        The stdout should include "already monitors fdb-falkordb"
        The contents of file "$sentinel_cli_log" should not include "SENTINEL monitor fdb-falkordb"
        The contents of file "$sentinel_cli_log" should include "SENTINEL set fdb-falkordb auth-pass s3cret"
      End
    End

    Context "when the master is not password protected"
      no_auth_conf() {
        {
          echo "sentinel monitor fdb-falkordb 10.42.0.11 6379 2"
          echo "sentinel down-after-milliseconds fdb-falkordb 5000"
        } > "$redis_sentinel_real_conf"
      }
      Before 'no_auth_conf'

      It "skips the auth directives"
        When call propagate_monitor_config_to_joining_member
        The status should be success
        The stdout should include "now monitors fdb-falkordb"
        The contents of file "$sentinel_cli_log" should not include "auth-pass"
        The contents of file "$sentinel_cli_log" should not include "auth-user"
      End
    End

    Context "when the joining sentinel never answers PING"
      unreachable() {
        SENTINEL_JOIN_MAX_RETRIES=2
        sentinel_cli() { return 1; }
      }
      Before 'unreachable'

      It "fails instead of looping forever"
        When run propagate_monitor_config_to_joining_member
        The status should be failure
        The stderr should include "did not answer PING"
      End
    End
  End
  Describe "split_acl_rules()"
    It "keeps one argument per rule"
      When call split_acl_rules "on #abc ~* &* +@all"
      The variable "acl_rule_args[@]" should eq "on #abc ~* &* +@all"
      The variable "acl_rule_args[4]" should eq "+@all"
      The variable "acl_rule_args[5]" should be undefined
    End

    It "keeps a selector with spaces together"
      When call split_acl_rules "on #abc resetchannels -@all (~key* resetchannels -@all +get) (~other* +set)"
      The variable "acl_rule_args[3]" should eq "-@all"
      The variable "acl_rule_args[4]" should eq "(~key* resetchannels -@all +get)"
      The variable "acl_rule_args[5]" should eq "(~other* +set)"
      The variable "acl_rule_args[6]" should be undefined
    End

    It "does not expand globs"
      When call split_acl_rules "~* &*"
      The variable "acl_rule_args[0]" should eq "~*"
      The variable "acl_rule_args[1]" should eq "&*"
    End
  End

  Describe "sync_acl_to_joining_member()"
    # Records every argument vector, one argument per line between markers, so
    # the assertions can tell whether a selector reached redis-cli in one piece.
    stub_sentinel_cli_argv() {
      sentinel_cli_argv() {
        local host="$1"
        shift
        {
          echo "--- $host"
          printf '%s\n' "$@"
        } >> "$sentinel_acl_log"
        case "$1 $2" in
          "ACL LIST")
            echo "user default on #d0 ~* &* +@all"
            echo "user alice on #a1 ~app:* resetchannels -@all +get (~cache:* resetchannels -@all +set)"
            echo "user bob off resetchannels -@all"
            ;;
          "ACL USERS")
            printf 'alice\ndefault\nstale\n'
            ;;
          *) echo "OK" ;;
        esac
      }
    }

    acl_setup() {
      stub_sentinel_cli_argv
      rm -f "$sentinel_acl_log"
      SENTINEL_POD_NAME_LIST="fdb-falkordb-sent-1,fdb-falkordb-sent-0,fdb-falkordb-sent-2"
      CURRENT_POD_NAME="fdb-falkordb-sent-0"
    }
    Before 'acl_setup'
    After 'unset CURRENT_POD_NAME SENTINEL_POD_NAME_LIST'

    It "rewrites every user except default on the joining sentinel"
      When call sync_acl_to_joining_member
      The status should be success
      The stdout should include "now matches this sentinel"
      The contents of file "$sentinel_acl_log" should include "--- 127.0.0.1"
      The contents of file "$sentinel_acl_log" should include "--- fdb-falkordb-sent-2.fdb-falkordb-sent-headless.test.svc"
      The contents of file "$sentinel_acl_log" should not include "SETUSER
default"
      The contents of file "$sentinel_acl_log" should include "SETUSER
alice
reset
on
#a1"
      The contents of file "$sentinel_acl_log" should include "SETUSER
bob
reset
off"
    End

    It "passes a selector as a single argument"
      When call sync_acl_to_joining_member
      The status should be success
      The stdout should include "syncing ACL user alice"
      The contents of file "$sentinel_acl_log" should include "+get
(~cache:* resetchannels -@all +set)
"
    End

    It "deletes users this sentinel does not have, but never default"
      When call sync_acl_to_joining_member
      The status should be success
      The stdout should include "deleting ACL user stale"
      The contents of file "$sentinel_acl_log" should include "DELUSER
stale"
      The contents of file "$sentinel_acl_log" should not include "DELUSER
default"
      The contents of file "$sentinel_acl_log" should not include "DELUSER
alice"
    End

    It "persists the ACL on the joining sentinel"
      When call sync_acl_to_joining_member
      The status should be success
      The stdout should include "now matches this sentinel"
      The contents of file "$sentinel_acl_log" should include "ACL
SAVE"
    End

    It "never logs the password hashes"
      When call sync_acl_to_joining_member
      The status should be success
      The stdout should not include "#a1"
    End

    # Only one sentinel may be the source, or one lacking an account that is
    # being created right now would delete it after another one set it.
    Context "when another sentinel is the ACL source"
      not_source() { CURRENT_POD_NAME="fdb-falkordb-sent-1"; }
      Before 'not_source'

      It "leaves the sync to it"
        When call sync_acl_to_joining_member
        The status should be success
        The stdout should include "fdb-falkordb-sent-0 copies its ACL onto the joining member, not this sentinel"
        The path "$sentinel_acl_log" should not be exist
      End
    End

    Context "when this sentinel is the joining member"
      self_join() { CURRENT_POD_NAME="fdb-falkordb-sent-2"; }
      Before 'self_join'

      It "does not sync onto itself"
        When call sync_acl_to_joining_member
        The status should be success
        The stdout should include "not this sentinel"
        The path "$sentinel_acl_log" should not be exist
      End
    End

    Context "when the joining member has the smallest name"
      joining_first() {
        KB_JOIN_MEMBER_POD_FQDN="fdb-falkordb-sent-0.fdb-falkordb-sent-headless.test.svc"
        CURRENT_POD_NAME="fdb-falkordb-sent-1"
      }
      Before 'joining_first'

      It "uses the next sentinel as the source"
        When call sync_acl_to_joining_member
        The status should be success
        The stdout should include "now matches this sentinel"
      End
    End

    Context "when there is no other sentinel"
      only_joining() { SENTINEL_POD_NAME_LIST="fdb-falkordb-sent-2"; }
      Before 'only_joining'

      It "fails"
        When call sync_acl_to_joining_member
        The status should be failure
        The stderr should include "no sentinel other than the joining member"
      End
    End

    Context "when the local ACL cannot be read"
      local_down() {
        sentinel_cli_argv() { echo "Could not connect to Redis at 127.0.0.1:26379"; return 1; }
      }
      Before 'local_down'

      It "fails"
        When call sync_acl_to_joining_member
        The status should be failure
        The stderr should include "failed to read the ACL of this sentinel"
      End
    End

    Context "when the joining sentinel rejects a user"
      reject_setuser() {
        sentinel_cli_argv() {
          local host="$1"
          shift
          case "$1 $2" in
            "ACL LIST") echo "user alice on #a1 ~* +@all" ;;
            "ACL SETUSER") echo "ERR Error in ACL SETUSER modifier '(~x': Syntax error" ;;
            *) echo "OK" ;;
          esac
        }
      }
      Before 'reject_setuser'

      It "fails instead of reporting success"
        When call sync_acl_to_joining_member
        The status should be failure
        The stdout should include "syncing ACL user alice"
        The stderr should include "failed to set ACL user alice"
      End
    End

    Context "when ACL SAVE fails"
      save_fails() {
        sentinel_cli_argv() {
          local host="$1"
          shift
          case "$1 $2" in
            "ACL LIST") echo "user default on #d0 ~* +@all" ;;
            "ACL USERS") echo "default" ;;
            "ACL SAVE") echo "ERR There was an error trying to save the ACLs" ;;
            *) echo "OK" ;;
          esac
        }
      }
      Before 'save_fails'

      It "fails, since the users would be lost on restart"
        When call sync_acl_to_joining_member
        The status should be failure
        The stderr should include "ACL SAVE failed"
      End
    End
  End

  Describe "member_join()"
    member_join_setup() {
      sentinel_cli_argv() {
        local host="$1"
        shift
        printf '%s|%s\n' "$host" "$*" >> "$sentinel_acl_log"
        case "$1 $2" in
          "ACL LIST") echo "user default on #d0 ~* +@all" ;;
          "ACL USERS") echo "default" ;;
          *) echo "OK" ;;
        esac
      }
      rm -f "$sentinel_acl_log"
      SENTINEL_POD_NAME_LIST="fdb-falkordb-sent-0,fdb-falkordb-sent-1,fdb-falkordb-sent-2"
      CURRENT_POD_NAME="fdb-falkordb-sent-0"
    }
    Before 'member_join_setup'
    After 'unset CURRENT_POD_NAME SENTINEL_POD_NAME_LIST'

    It "hands over the monitor configuration and the ACL"
      When call member_join
      The status should be success
      The stdout should include "now monitors fdb-falkordb"
      The stdout should include "now matches this sentinel"
      The contents of file "$sentinel_acl_log" should include "ACL SAVE"
    End

    Context "when the monitor hand-over fails"
      unreachable() {
        SENTINEL_JOIN_MAX_RETRIES=1
        sentinel_cli() { return 1; }
      }
      Before 'unreachable'

      It "fails without touching the ACL"
        When run member_join
        The status should be failure
        The stderr should include "did not answer PING"
        The path "$sentinel_acl_log" should not be exist
      End
    End
  End
End

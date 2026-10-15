# shellcheck shell=bash
# shellcheck disable=SC2034

if ! validate_shell_type_and_version "bash" 4 &>/dev/null; then
  echo "falkordb_cluster_reshard_spec.sh skip all cases because dependency bash version 4 or higher is not installed."
  exit 0
fi

Describe "FalkorDB Cluster Reshard Script Tests"
  Include ../falkordb-cluster-scripts/falkordb-cluster-reshard.sh

  ID_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  ID_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  ID_C="cccccccccccccccccccccccccccccccccccccccc"
  ID_A_REPLICA="dddddddddddddddddddddddddddddddddddddddd"

  # Three shards; shard-a has a replica. Nodes announce their pod FQDN as
  # hostname, and the address field carries an aux field as on Redis 7.2+.
  nodes_before() {
    cat <<EOF
$ID_A 10.0.0.1:6379@16379,fdb-shard-a-0.fdb-shard-a-headless.default.svc.cluster.local,shard-id=1 myself,master - 0 0 1 connected 0-5460
$ID_A_REPLICA 10.0.0.4:6379@16379,fdb-shard-a-1.fdb-shard-a-headless.default.svc.cluster.local,shard-id=1 slave $ID_A 0 0 1 connected
$ID_B 10.0.0.2:6379@16379,fdb-shard-b-0.fdb-shard-b-headless.default.svc.cluster.local,shard-id=2 master - 0 0 2 connected 5461-10922
$ID_C 10.0.0.3:6379@16379,fdb-shard-c-0.fdb-shard-c-headless.default.svc.cluster.local,shard-id=3 master - 0 0 3 connected 10923-16383
EOF
  }

  # The same cluster once slots 0-99 and 5000 went from shard-a to shard-b.
  nodes_after() {
    cat <<EOF
$ID_A 10.0.0.1:6379@16379,fdb-shard-a-0.fdb-shard-a-headless.default.svc.cluster.local,shard-id=1 master - 0 0 1 connected 100-4999 5001-5460
$ID_A_REPLICA 10.0.0.4:6379@16379,fdb-shard-a-1.fdb-shard-a-headless.default.svc.cluster.local,shard-id=1 slave $ID_A 0 0 1 connected
$ID_B 10.0.0.2:6379@16379,fdb-shard-b-0.fdb-shard-b-headless.default.svc.cluster.local,shard-id=2 myself,master - 0 0 4 connected 0-99 5000 5461-10922
$ID_C 10.0.0.3:6379@16379,fdb-shard-c-0.fdb-shard-c-headless.default.svc.cluster.local,shard-id=3 master - 0 0 3 connected 10923-16383
EOF
  }

  init() {
    ut_mode="true"
    redis_cli_log="./reshard-redis-cli.log"
    migrated_flag="./reshard-migrated.flag"
    setslot_log="./reshard-setslot.log"
  }
  BeforeAll "init"

  cleanup() {
    rm -f ./reshard-redis-cli.log ./reshard-migrated.flag ./reshard-migrated.flag.keys ./reshard-setslot.log
  }
  AfterAll "cleanup"

  # A fake cluster: answers each command the script sends and records it.
  # Slot 0 holds two keys until they are migrated; every other slot is empty.
  fake_redis_cli() {
    local host="" port="" stdin=""
    local args="$*"
    if [ ! -t 0 ]; then
      stdin=$(cat)
    fi
    echo "auth:${REDISCLI_AUTH-unset} args:$*" >> "$redis_cli_log"
    [ -n "$stdin" ] && echo "$stdin" | sed 's/^/  stdin: /' >> "$redis_cli_log"
    case " $* " in
      *" --cluster check "*)
        printf '%s\n' "${cluster_check_output:-[OK] All nodes agree about slots configuration.
>>> Check for open slots...
>>> Check slots coverage...
[OK] All 16384 slots covered.}"
        ;;
      *" --pipe"*)
        local n errors=0 state slots
        n=$(echo "$stdin" | grep -c 'SETSLOT' || true)
        state=$(echo "$stdin" | tr -d '\r' | grep -E -m1 '^(IMPORTING|MIGRATING|NODE)$')
        # in RESP the slot is the second line after SETSLOT, past its length
        # shellcheck disable=SC2046
        slots=$(format_ranges $(echo "$stdin" | tr -d '\r' |
          awk 'back == 2 {print} {back = (back ? back + 1 : 0)} $0 == "SETSLOT" {back = 1}'))
        echo "$args" | awk '{for (i = 1; i < NF; i++) if ($i == "-h") print $(i + 1)}' |
          sed "s/$/ $state $slots/" >> "$setslot_log"
        # the slot map changes once the script assigns the slots to the target
        if [ "$state" = "NODE" ]; then
          touch "$migrated_flag"
        fi
        if [ -n "$setslot_error" ]; then
          echo "$setslot_error"
          errors=1
        fi
        echo "All data transferred. Waiting for the last reply..."
        echo "Last reply received from server."
        echo "errors: $errors, replies: $n"
        [ "$errors" -eq 0 ]
        ;;
      *" CLUSTER INFO "*)
        printf 'cluster_state:%s\r\ncluster_slots_assigned:16384\r\n' "${cluster_state:-ok}"
        ;;
      *" CLUSTER NODES "*)
        if [ -f "$migrated_flag" ]; then nodes_after; else nodes_before; fi
        ;;
      *" CLUSTER MYID "*)
        echo "$myid_reply"
        ;;
      *" --csv CLUSTER GETKEYSINSLOT 0 "*)
        if [ -n "$getkeys_fails" ]; then
          echo "Could not connect to Redis at 10.0.0.1:6379: Connection refused" >&2
          return 1
        fi
        if [ -f "$migrated_flag.keys" ]; then echo ""; else echo '"{0}a b","{0}q\"x"'; fi
        ;;
      *)
        if [[ "$stdin" == *"CLUSTER COUNTKEYSINSLOT"* ]]; then
          # slot 0 holds two keys until they are migrated, or for good when
          # keys_stay is set
          local left=2
          if [ -f "$migrated_flag.keys" ] && [ -z "$keys_stay" ]; then left=0; fi
          echo "$stdin" | awk -v left="$left" '{print ($3 == 0) ? left : 0}'
        elif [[ "$stdin" == MIGRATE* ]]; then
          touch "$migrated_flag.keys"
          echo "${migrate_reply:-OK}"
        fi
        ;;
    esac
  }

  setup() {
    rm -f "$redis_cli_log" "$migrated_flag" "$migrated_flag.keys" "$setslot_log"
    CLUSTER_NAME="fdb"
    CURRENT_POD_NAME="fdb-shard-c-0"
    CURRENT_SHARD_COMPONENT_NAME="fdb-shard-c"
    CLUSTER_NAMESPACE="default"
    CLUSTER_DOMAIN="cluster.local"
    SERVICE_PORT="6379"
    REDIS_DEFAULT_USER="default"
    REDIS_DEFAULT_PASSWORD='s3c"ret'
    REDIS_CLI_TLS_CMD=""
    SLOTS="0-99,5000"
    TO="fdb-shard-b"
    FROM=""
    cluster_state="ok"
    cluster_check_output=""
    setslot_error=""
    migrate_reply=""
    myid_reply=""
    getkeys_fails=""
    keys_stay=""
    redis-cli() {
      fake_redis_cli "$@"
    }
    CLUSTER_NODES=$(nodes_before)
  }
  Before "setup"

  Describe "parse_slots()"
    It "expands single slots and ranges in ascending order, once each"
      When call parse_slots "5, 0-2,2 16383"
      The status should be success
      The output should eq "0
1
2
5
16383"
    End

    It "rejects a slot past 16383"
      When call parse_slots "16384"
      The status should be failure
      The stderr should include "out of bounds"
    End

    It "rejects a number too large for shell arithmetic"
      When call parse_slots "99999999999999999999999"
      The status should be failure
      The stderr should include "out of bounds"
    End

    It "rejects a range that ends before it starts"
      When call parse_slots "10-5"
      The status should be failure
      The stderr should include "ends before it starts"
    End

    It "rejects anything that is not a slot or a range"
      When call parse_slots "0-99;rm"
      The status should be failure
      The stderr should include "invalid slot or range"
    End

    It "rejects an empty list"
      When call parse_slots " , "
      The status should be failure
      The stderr should include "SLOTS is empty"
    End
  End

  Describe "format_ranges()"
    It "folds consecutive slots into ranges"
      When call format_ranges 0 1 2 5 7 8
      The output should eq "0-2,5,7-8"
    End
  End

  Describe "quote_arg()"
    It "escapes quotes and backslashes for redis-cli's parser"
      When call quote_arg 'a"b\c'
      The output should eq '"a\"b\\c"'
    End

    It "escapes line breaks, so they cannot split the command"
      When call quote_arg $'a\nb\rc'
      The output should eq '"a\nb\rc"'
    End
  End

  Describe "resolve_primary()"
    It "maps a shard name to its primary through the announced hostnames"
      When call resolve_primary TO fdb-shard-b
      The output should eq "$ID_B"
    End

    It "accepts the shard's short name, without the cluster name"
      When call resolve_primary TO shard-b
      The output should eq "$ID_B"
    End

    It "does not mistake a shard whose name is a prefix of another"
      When call resolve_primary TO fdb-shard
      The status should be failure
      The stderr should include "no healthy primary of a shard by that name"
    End

    It "accepts the node ID of a primary"
      When call resolve_primary TO "$ID_C"
      The output should eq "$ID_C"
    End

    It "refuses the node ID of a replica"
      When call resolve_primary TO "$ID_A_REPLICA"
      The status should be failure
      The stderr should include "not a healthy primary"
    End

    It "refuses a primary the cluster has lost its link to"
      CLUSTER_NODES=$(nodes_before | sed "/^$ID_C/s/ connected / disconnected /")
      When call resolve_primary TO "$ID_C"
      The status should be failure
      The stderr should include "not a healthy primary"
    End

    It "refuses a node ID that is not in the cluster"
      When call resolve_primary TO "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
      The status should be failure
      The stderr should include "no node with that ID"
    End

    Context "when nodes announce a hostname override"
      overridden() {
        CLUSTER_NODES=$(nodes_before | sed 's/,fdb-shard-[a-c]-[0-9][^ ]*,shard-id/,lb.example.com,shard-id/')
        myid_reply="$ID_A_REPLICA"
      }
      Before "overridden"

      It "asks a pod of the shard through its headless service"
        When call resolve_primary TO shard-a
        The output should eq "$ID_A"
        The contents of file "$redis_cli_log" should include "-h fdb-shard-a-headless.default.svc.cluster.local -p 6379 CLUSTER MYID"
      End
    End
  End

  Describe "reshard()"
    It "moves exactly the requested slots and their keys"
      When call reshard
      The status should be success
      The output should include "moving 101 slots, 0 already belong to fdb-shard-b"
      The output should include "moving slots 0-99,5000 from $ID_A at 10.0.0.1:6379"
      The output should include "moved 101 slots to fdb-shard-b, primary $ID_B"
      # importing on the target, migrating on the source
      The contents of file "$redis_cli_log" should include "-h 10.0.0.2 -p 6379 --pipe"
      The contents of file "$redis_cli_log" should include "SETSLOT"
      # the keys go with --csv quoting intact, and the credentials on stdin
      The contents of file "$redis_cli_log" should include 'stdin: MIGRATE 10.0.0.2 6379 "" 0 60000 AUTH2 "default" "s3c\"ret" KEYS "{0}a b" "{0}q\"x"'
    End

    It "never puts the password in redis-cli's arguments"
      When call reshard
      The status should be success
      The output should include "moved 101 slots"
      The contents of file "$redis_cli_log" should not include "-a "
      The contents of file "$redis_cli_log" should include 'auth:s3c"ret args:--user default'
    End

    # The order is what keeps every slot owned and every key reachable: the
    # target imports before the source migrates, and the target takes the
    # slot before the source lets go of it.
    It "opens and closes the slots on each node in redis-cli's order"
      SLOTS="0-99"
      When call reshard
      The status should be success
      The output should include "moved 100 slots"
      The contents of file "$setslot_log" should eq "10.0.0.2 IMPORTING 0-99
10.0.0.1 MIGRATING 0-99
10.0.0.2 NODE 0-99
10.0.0.1 NODE 0-99
10.0.0.3 NODE 0-99"
    End

    It "opens at most SLOT_BATCH_SIZE slots at a time"
      SLOT_BATCH_SIZE=60
      When call reshard
      The status should be success
      The output should include "moved 101 slots"
      The contents of file "$setslot_log" should eq "10.0.0.2 IMPORTING 0-59
10.0.0.1 MIGRATING 0-59
10.0.0.2 NODE 0-59
10.0.0.1 NODE 0-59
10.0.0.3 NODE 0-59
10.0.0.2 IMPORTING 60-99,5000
10.0.0.1 MIGRATING 60-99,5000
10.0.0.2 NODE 60-99,5000
10.0.0.1 NODE 60-99,5000
10.0.0.3 NODE 60-99,5000"
    End

    It "skips slots that already belong to TO"
      SLOTS="0-99,5000,6000-6099"
      When call reshard
      The status should be success
      The output should include "moving 101 slots, 100 already belong to fdb-shard-b"
      The contents of file "$setslot_log" should include "10.0.0.2 IMPORTING 0-99
10.0.0.1 MIGRATING 0-99"
      The contents of file "$setslot_log" should include "10.0.0.2 IMPORTING 5000
10.0.0.1 MIGRATING 5000"
      The contents of file "$setslot_log" should not include "6000"
    End

    It "does nothing when every slot already belongs to TO"
      SLOTS="6000-6099"
      When call reshard
      The status should be success
      The output should include "nothing to move"
      The contents of file "$redis_cli_log" should not include "--pipe"
    End

    It "refuses FROM and TO naming the same shard"
      FROM="$ID_B"
      When call reshard
      The status should be failure
      The output should include "move slots"
      The stderr should include "are the same shard"
      The contents of file "$redis_cli_log" should not include "--pipe"
    End

    It "refuses slots that FROM does not own, and moves none of them"
      FROM="fdb-shard-c"
      When call reshard
      The status should be failure
      The output should include "move slots"
      The stderr should include "does not own slots 0-99,5000; nothing was moved"
      The contents of file "$redis_cli_log" should not include "--pipe"
    End

    It "requires TO"
      TO=""
      When call reshard
      The status should be failure
      The stderr should include "TO is required"
    End

    It "refuses a cluster that is not ok"
      cluster_state="fail"
      When call reshard
      The status should be failure
      The output should include "move slots"
      The stderr should include "cluster_state is 'fail'"
      The contents of file "$redis_cli_log" should not include "--pipe"
    End

    It "refuses a cluster with open slots"
      cluster_check_output="[OK] All 16384 slots covered.
[WARNING] The following slots are open: 400."
      When call reshard
      The status should be failure
      The output should include "move slots"
      The stderr should include "the cluster is not stable"
      The contents of file "$redis_cli_log" should not include "--pipe"
    End

    It "fails when a node rejects SETSLOT"
      setslot_error="ERR I don't know about node xyz"
      When call reshard
      The status should be failure
      The output should include "moving slots"
      The stderr should include "I don't know about node"
      The stderr should include "redis-cli --cluster fix"
    End

    It "fails when MIGRATE does"
      migrate_reply="ERR Target instance replied with error: BUSYKEY Target key name already exists."
      When call reshard
      The status should be failure
      The output should include "moving slots"
      The stderr should include "could not migrate the keys of slot 0"
      The stderr should include "already holds a key of the same name"
    End

    # Assigning a slot whose keys are still on the source makes the source
    # drop them, so neither case may get as far as SETSLOT NODE.
    It "fails, without assigning anything, when the keys cannot be listed"
      getkeys_fails="true"
      When call reshard
      The status should be failure
      The output should include "moving slots"
      The stderr should include "could not list the keys of slot 0"
      The contents of file "$setslot_log" should not include "NODE"
    End

    It "fails, without assigning anything, when keys are left behind"
      keys_stay="true"
      SLOTS="0-99"
      When call reshard
      The status should be failure
      The output should include "moving slots"
      The stderr should include "slot 0 still holds 2 keys"
      The contents of file "$setslot_log" should not include "NODE"
    End

    Context "when the cluster has no password"
      no_password() {
        REDIS_DEFAULT_PASSWORD=""
        unset REDISCLI_AUTH
      }
      Before "no_password"

      It "neither authenticates nor passes AUTH to MIGRATE"
        When call reshard
        The status should be success
        The output should include "moved 101 slots"
        The contents of file "$redis_cli_log" should include "auth:unset"
        The contents of file "$redis_cli_log" should include 'MIGRATE 10.0.0.2 6379 "" 0 60000  KEYS'
      End
    End

    Context "when TLS is enabled"
      with_tls() { REDIS_CLI_TLS_CMD="--tls --insecure"; }
      Before "with_tls"

      It "passes the TLS flags to every redis-cli call"
        When call reshard
        The status should be success
        The output should include "moved 101 slots"
        The contents of file "$redis_cli_log" should include "args:--tls --insecure --user default -h 10.0.0.2 -p 6379 --pipe"
        The contents of file "$redis_cli_log" should include "args:--tls --insecure --user default --cluster check"
      End
    End
  End
End

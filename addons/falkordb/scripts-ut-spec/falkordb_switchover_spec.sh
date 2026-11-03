# shellcheck shell=bash
# shellcheck disable=SC2034

if ! validate_shell_type_and_version "bash" 4 &>/dev/null; then
  echo "redis_switchover_spec.sh skip all cases because dependency bash version 4 or higher is not installed."
  exit 0
fi

source ./utils.sh

common_library_file="./common.sh"
generate_common_library $common_library_file

Describe "FalkorDB Switchover Script Tests"
  Include ../scripts/falkordb-switchover.sh
  Include $common_library_file

  init() {
    ut_mode="true"
  }
  BeforeAll "init"

  # timeout is an external command, so it could not run the redis-cli stubs
  timeout() { shift; "$@"; }

  # A fake clock that sleeping moves on, so the waits measured against the
  # write pause end at once. sleep takes seconds, with decimals.
  fake_now_ms=1000000000
  now_ms() { echo "$fake_now_ms"; }
  sleep_when_ut_mode_false() {
    local whole="${1%%.*}" frac=0
    [[ "$1" == *.* ]] && frac="${1#*.}000" && frac="${frac:0:3}"
    fake_now_ms=$((fake_now_ms + ${whole:-0} * 1000 + 10#$frac))
  }

  cleanup() {
    rm -f $common_library_file
  }
  AfterAll 'cleanup'

  Describe "Environment Check Tests"
    Context "check_environment_exist()"
      It "should fail when no required variables are set"
        unset SENTINEL_POD_FQDN_LIST REDIS_POD_FQDN_LIST REDIS_COMPONENT_NAME KB_SWITCHOVER_ROLE
        export COMPONENT_REPLICAS="2"
        When call check_environment_exist
        The status should be failure
        The stderr should include "Required environment variable SENTINEL_POD_FQDN_LIST is not set"
        The stdout should equal ""
      End

      It "should succeed with all required variables"
        export SENTINEL_POD_FQDN_LIST="sentinel1,sentinel2"
        export REDIS_POD_FQDN_LIST="redis1,redis2"
        export REDIS_COMPONENT_NAME="redis"
        export KB_SWITCHOVER_ROLE="primary"
        export COMPONENT_REPLICAS="2"
        When call check_environment_exist
        The status should be success
        The stdout should equal ""
        The stderr should equal ""
      End

#      It "should exit early when role is not primary"
#        export SENTINEL_POD_FQDN_LIST="sentinel1,sentinel2"
#        export REDIS_POD_FQDN_LIST="redis1,redis2"
#        export REDIS_COMPONENT_NAME="redis"
#        export KB_SWITCHOVER_ROLE="secondary"
#        When call check_environment_exist
#        The status should be success
#        The stdout should include "switchover not triggered for primary, nothing to do"
#        The stderr should equal ""
#      End
    End
  End

  Describe "FalkorDB Operation Tests"
    Context "check_redis_role()"
      setup() {
        export REDIS_DEFAULT_PASSWORD="password123"
      }
      Before 'setup'

      cleanup() {
        unset REDIS_DEFAULT_PASSWORD
      }
      After 'cleanup'

      It "should identify primary role"
        redis-cli() {
          echo "# Replication
role:master
connected_slaves:2"
        }
        When call check_redis_role "localhost" "6379"
        The status should be success
        The output should equal "primary"
        The stderr should equal ""
      End

      It "should identify secondary role"
        redis-cli() {
          echo "# Replication
role:slave
master_host:redis-master"
        }
        When call check_redis_role "localhost" "6379"
        The status should be success
        The output should equal "secondary"
        The stderr should equal ""
      End

      It "should handle redis-cli failure"
        redis-cli() {
          return 1
        }
        When call check_redis_role "localhost" "6379"
        The status should be failure
        The stderr should include "Failed to get role info from localhost"
        The output should equal ""
      End

      It "should handle empty response"
        redis-cli() {
          echo ""
        }
        When call check_redis_role "localhost" "6379"
        The status should be failure
        The output should equal "unknown"
      End
    End

    Context "check_redis_kernel_status()"
      setup() {
        export REDIS_POD_FQDN_LIST="redis1,redis2,redis3"
        export SERVICE_PORT="6379"
      }
      Before 'setup'

      cleanup() {
        unset REDIS_POD_FQDN_LIST
        unset SERVICE_PORT
      }
      After 'cleanup'

      It "should detect single primary correctly"
        check_redis_role() {
          case "$1" in
            "redis1") echo "primary" ;;
            *) echo "secondary" ;;
          esac
        }
        When call check_redis_kernel_status
        The status should be success
        The output should equal "redis1"
        The stderr should equal ""
      End

      It "should fail when multiple primaries detected"
        check_redis_role() {
          echo "primary"
        }
        When call check_redis_kernel_status
        The status should be failure
        The stderr should include "Multiple primaries detected"
        The stdout should equal ""
      End

      It "should fail when no primary found"
        check_redis_role() {
          echo "secondary"
        }
        When call check_redis_kernel_status
        The status should be failure
        The stderr should include "No primary found"
        The stdout should equal ""
      End
    End

    Context "execute_sub_command()"
      It "should succeed with OK response"
        redis-cli() {
          echo "OK"
        }
        When call execute_sub_command "localhost" "6379" "password" "PING"
        The status should be success
        The stdout should include "Command executed successfully"
        The stderr should equal ""
      End

      It "should fail with non-OK response"
        redis-cli() {
          echo "ERROR"
        }
        When call execute_sub_command "localhost" "6379" "password" "PING"
        The status should be failure
        The stderr should include "Command failed"
        The stdout should include "ERROR"
      End

      It "should fail when redis-cli fails"
        redis-cli() {
          return 1
        }
        When call execute_sub_command "localhost" "6379" "password" "PING"
        The status should be failure
        The stderr should include "Command failed"
        The stdout should include "execute_sub_command output:"
      End
    End

    Context "execute_sentinel_failover()"
      setup() {
        export SENTINEL_POD_FQDN_LIST="sentinel1,sentinel2"
        export SENTINEL_SERVICE_PORT="26379"
        export SENTINEL_PASSWORD="sentinel_pass"
      }
      Before 'setup'

      cleanup() {
        unset SENTINEL_POD_FQDN_LIST
        unset SENTINEL_SERVICE_PORT
        unset SENTINEL_PASSWORD
      }
      After 'cleanup'

      It "should succeed with first sentinel"
        execute_sub_command() {
          echo "OK"
          return 0
        }
        When call execute_sentinel_failover "redis"
        The status should be success
        The stdout should include "Sentinel failover started with sentinel1"
        The stderr should equal ""
      End

      It "tries each sentinel once, with no retry delays"
        cmd_log="./failover-cmds"
        execute_sub_command() { echo "$1: $4" >> "$cmd_log"; [ "$1" = "sentinel2" ]; }
        logged_commands() {
          : > "$cmd_log"
          execute_sentinel_failover "redis" >/dev/null
          cat "$cmd_log"
          rm -f "$cmd_log"
        }
        When call logged_commands
        The line 1 of stdout should eq "sentinel1: SENTINEL FAILOVER redis"
        The line 2 of stdout should eq "sentinel2: SENTINEL FAILOVER redis"
        The lines of stdout should eq 2
      End

      It "should fail when all sentinels fail"
        execute_sub_command() {
          return 1
        }
        call_func_with_retry() {
          return 1
        }
        When call execute_sentinel_failover "redis"
        The status should be failure
        The stderr should include "All Sentinel failover attempts failed"
      End
    End
  End

  Describe "Switchover Tests"
    setup() {
      export REDIS_DEFAULT_PASSWORD="redis_pass"
      export SENTINEL_POD_FQDN_LIST="sentinel1,sentinel2"
      export REDIS_POD_FQDN_LIST="redis1,redis2,redis3"
      export KB_SWITCHOVER_CANDIDATE_FQDN="redis2"
      export REDIS_COMPONENT_NAME="redis"
      export SERVICE_PORT="6379"
      export KB_SWITCHOVER_ROLE="primary"
      export SENTINEL_SERVICE_PORT="26379"
      export SENTINEL_PASSWORD="sentinel_pass"
      export COMPONENT_REPLICAS="2"
      MOCK_RESPONSES=()
      RESPONSE_INDEX=0
    }
    Before 'setup'

    cleanup() {
      unset REDIS_DEFAULT_PASSWORD
      unset SENTINEL_POD_FQDN_LIST
      unset REDIS_POD_FQDN_LIST
      unset KB_SWITCHOVER_CANDIDATE_FQDN
      unset REDIS_COMPONENT_NAME
      unset SERVICE_PORT
      unset KB_SWITCHOVER_ROLE
      unset SENTINEL_SERVICE_PORT
      unset SENTINEL_PASSWORD
      unset MOCK_RESPONSES
      unset RESPONSE_INDEX
      unset COMPONENT_REPLICAS
    }
    After 'cleanup'

    Context "replicas_caught_up()"
      # REDIS_POD_FQDN_LIST is redis1,redis2,redis3; redis1 is the primary.
      # replica_info holds each replica's INFO replication, "" for unreachable.
      redis_config_get() {
        case "$1" in
          redis1) printf 'role:master\r\nmaster_repl_offset:500\r\n' ;;
          redis2) [ -n "$redis2_info" ] || return 1; printf '%b' "$redis2_info" ;;
          redis3) [ -n "$redis3_info" ] || return 1; printf '%b' "$redis3_info" ;;
        esac
      }
      caught='role:slave\r\nmaster_host:redis1\r\nmaster_port:6379\r\nmaster_link_status:up\r\nslave_repl_offset:500\r\n'

      It "succeeds when every replica has applied the primary's offset"
        redis2_info="$caught"; redis3_info="$caught"
        When call replicas_caught_up "redis1" ""
        The status should be success
      End

      It "fails while a replica still syncs, though the primary would not list it as online"
        redis2_info="$caught"; redis3_info='role:slave\r\nmaster_host:redis1\r\nmaster_port:6379\r\nmaster_link_status:down\r\nslave_repl_offset:0\r\n'
        When call replicas_caught_up "redis1" ""
        The status should be failure
        The stderr should include "replica redis3 is at offset 0 of 500 (link down)"
      End

      It "fails while a replica is behind"
        redis2_info='role:slave\r\nmaster_host:redis1\r\nmaster_port:6379\r\nmaster_link_status:up\r\nslave_repl_offset:480\r\n'; redis3_info="$caught"
        When call replicas_caught_up "redis1" ""
        The status should be failure
        The stderr should include "replica redis2 is at offset 480 of 500"
      End

      It "skips a replica that cannot be reached"
        redis2_info="$caught"; redis3_info=""
        When call replicas_caught_up "redis1" ""
        The status should be success
        The stdout should include "replica redis3 cannot be reached, skipping it"
      End

      It "fails when the candidate cannot be reached"
        redis2_info="$caught"; redis3_info=""
        When call replicas_caught_up "redis1" "redis3"
        The status should be failure
        The stderr should include "the candidate redis3 cannot be reached"
      End

      It "succeeds with a caught-up candidate"
        redis2_info="$caught"; redis3_info="$caught"
        When call replicas_caught_up "redis1" "redis3"
        The status should be success
      End

      It "fails when no replica can be reached"
        redis2_info=""; redis3_info=""
        When call replicas_caught_up "redis1" ""
        The status should be failure
        The stdout should include "skipping it"
        The stderr should include "redis1 has no replica that caught up"
      End

      It "fails when a replica follows another master, whatever its offset"
        redis2_info="$caught"; redis3_info='role:slave\r\nmaster_host:redis2\r\nmaster_port:6379\r\nmaster_link_status:up\r\nslave_repl_offset:900\r\n'
        When call replicas_caught_up "redis1" "" "redis1 6379"
        The status should be failure
        The stderr should include "replica redis3 follows redis2:6379, not redis1"
      End

      It "accepts a replica that follows the address sentinel has for the primary"
        # behind a load balancer the replicas follow its address, not the pod's name
        lb='role:slave\r\nmaster_host:lb-0.example.com\r\nmaster_port:6379\r\nmaster_link_status:up\r\nslave_repl_offset:500\r\n'
        redis2_info="$lb"; redis3_info="$lb"
        When call replicas_caught_up "redis1" "" "lb-0.example.com 6379"
        The status should be success
      End

      It "fails when another pod runs as a master"
        redis2_info="$caught"; redis3_info='role:master\r\nmaster_repl_offset:900\r\n'
        When call replicas_caught_up "redis1" ""
        The status should be failure
        The stderr should include "redis3 is not a replica (role: master)"
      End
    End

    Context "wait_for_sentinel_to_switch_master()"
      It "returns the first primary that differs from the initial one"
        # sentinel1 still names the old primary, sentinel2 has switched
        get_sentinel_master_addr() { if [ "$1" = sentinel2 ]; then echo "redis2 6379"; else echo "redis1 6379"; fi; }
        check_redis_role() { echo "primary"; }
        check_new_primary() {
          wait_for_sentinel_to_switch_master "redis1 6379" && echo "new=$new_primary_host:$new_primary_port"
        }
        When call check_new_primary
        The status should be success
        The stdout should include "new=redis2:6379"
      End

      It "skips a primary a lagging sentinel names that is a replica now"
        # sentinel1 lags and names an earlier primary, sentinel2 the new one
        get_sentinel_master_addr() { if [ "$1" = sentinel2 ]; then echo "redis2 6379"; else echo "redis3 6379"; fi; }
        check_redis_role() { if [ "$1" = "redis2" ]; then echo "primary"; else echo "secondary"; fi; }
        check_new_primary() {
          wait_for_sentinel_to_switch_master "redis1 6379" && echo "new=$new_primary_host:$new_primary_port"
        }
        When call check_new_primary
        The status should be success
        The stdout should include "redis3 6379 as the primary, but it does not run as one"
        The stdout should include "new=redis2:6379"
      End

      It "returns 2 when the failover ended without switching"
        get_sentinel_master_addr() { echo "redis1 6379"; }
        sentinel_may_be_failing_over() { return 1; }
        When call wait_for_sentinel_to_switch_master "redis1 6379"
        The status should eq 2
        The stderr should include "sentinel is no longer failing over and still reports redis1 6379"
      End

      It "returns 1 when the failover is still running at the deadline"
        get_sentinel_master_addr() { echo "redis1 6379"; }
        sentinel_may_be_failing_over() { return 0; }
        check_deadline() {
          local until_ms=$((fake_now_ms + 500)) rc=0
          wait_for_sentinel_to_switch_master "redis1 6379" "$until_ms" || rc=$?
          echo "rc=$rc at +$((fake_now_ms - until_ms + 500))ms"
        }
        When call check_deadline
        The stdout should eq "rc=1 at +500ms"
      End

      It "takes a switch that happens just as the failover ends"
        # no sentinel has switched at the first look; by the second, after the
        # failover has ended, they have
        switched=""
        get_sentinel_master_addr() { if [ -n "$switched" ]; then echo "redis2 6379"; else echo "redis1 6379"; fi; }
        check_redis_role() { echo "primary"; }
        sentinel_may_be_failing_over() { switched=true; return 1; }
        check_new_primary() {
          wait_for_sentinel_to_switch_master "redis1 6379" && echo "new=$new_primary_host:$new_primary_port"
        }
        When call check_new_primary
        The stdout should include "new=redis2:6379"
      End

      It "does not wait for a slow sentinel when another has switched"
        # sentinel1 takes 3 s to answer, sentinel2 answers at once
        get_sentinel_master_addr() {
          if [ "$1" = sentinel1 ]; then sleep 3; echo "redis1 6379"; else echo "redis2 6379"; fi
        }
        check_redis_role() { echo "primary"; }
        # the real clock in ms: now_ms is the spec's fake one
        real_ms() { local t="${EPOCHREALTIME/[.,]/}"; echo $((t / 1000)); }
        timed() {
          local started elapsed
          started=$(real_ms)
          sentinel_reports_new_primary "redis1 6379" >/dev/null || return 1
          elapsed=$(( $(real_ms) - started ))
          echo "switched to $new_primary_host"
          # well short of sentinel1's 3 s, with room for a slow CI runner
          [ "$elapsed" -lt 2000 ] || echo "took ${elapsed}ms"
        }
        When call timed
        The stdout should eq "switched to redis2"
      End
    End

    Context "sentinel_may_be_failing_over()"
      It "is true while a sentinel marks the failover in progress"
        redis_config_get() { if [ "$1" = "sentinel2" ]; then printf '%s\n' name redis flags "master,failover_in_progress"; else printf '%s\n' name redis flags master; fi; }
        When call sentinel_may_be_failing_over
        The status should be success
      End

      It "is true when a sentinel cannot be asked"
        redis_config_get() { [ "$1" = "sentinel1" ] && printf '%s\n' name redis flags master; }
        When call sentinel_may_be_failing_over
        The status should be success
      End

      It "is false when every sentinel answers without a failover"
        redis_config_get() { printf '%s\n' name redis flags master; }
        When call sentinel_may_be_failing_over
        The status should be failure
      End
    End

    Context "failover_with_writes_paused()"
      # records every command sent to a pod, in order
      execute_sub_command() { echo "cmd $1: $4"; return 0; }
      call_func_with_retry() { shift 2; "$@"; }
      get_sentinel_master_addr() {
        if [ -n "$failover_started" ]; then echo "redis2 6379"; else echo "redis1 6379"; fi
      }
      execute_sentinel_failover() { failover_started=true; echo "failover"; return 0; }
      replicas_caught_up() { return 0; }
      get_sentinel_down_after_ms() { echo 5000; }
      # the old primary turns into a replica, the new one runs as a master
      check_redis_role() { if [ "$1" = "redis2" ]; then echo "primary"; else echo "secondary"; fi; }

      It "pauses writes, fails over, demotes the old primary and only then unpauses"
        failover_started=""
        When call failover_with_writes_paused "redis1"
        The status should be success
        The line 1 of stdout should eq "cmd redis1: CLIENT PAUSE 5000 WRITE"
        The line 3 of stdout should eq "failover"
        The stdout should include "cmd redis1: REPLICAOF redis2 6379"
        The stdout should include "redis1 is now a replica of redis2:6379"
        The output should match pattern "*REPLICAOF redis2 6379*cmd redis1: CLIENT UNPAUSE*"
      End

      It "unpauses and does not fail over when the replicas do not catch up"
        failover_started=""
        replicas_caught_up() { return 1; }
        When call failover_with_writes_paused "redis1"
        The status should be failure
        The stdout should include "cmd redis1: CLIENT UNPAUSE"
        The stdout should not include "failover"
        The stderr should include "did not catch up"
      End

      It "unpauses without demoting when the failover ends without switching"
        failover_started=""
        execute_sentinel_failover() { return 0; }
        sentinel_may_be_failing_over() { return 1; }
        When call failover_with_writes_paused "redis1"
        The status should be failure
        The stdout should include "cmd redis1: CLIENT UNPAUSE"
        The stdout should not include "REPLICAOF"
        The stderr should include "sentinel is no longer failing over and still reports redis1 6379"
      End

      It "watches on without the pause when sentinel has not switched by its end"
        failover_started=""
        execute_sentinel_failover() { return 0; }
        wait_for_sentinel_to_switch_master() { return 1; }
        When call failover_with_writes_paused "redis1"
        The status should be failure
        The stdout should not include "CLIENT UNPAUSE"
        The stdout should not include "REPLICAOF"
        The stderr should include "sentinel has not switched within the 5000 ms writes may stay paused"
        The stderr should include "still failing over from redis1 6379 after another 75s"
      End

      It "watches past the pause only once it has run out, then demotes at once"
        failover_started=""
        waits_file="./switch-waits"
        : > "$waits_file"
        # Each wait logs its deadline and the time it starts. The first, under
        # the pause, runs to its deadline without a switch; the second sees it.
        wait_for_sentinel_to_switch_master() {
          echo "$2 $fake_now_ms" >> "$waits_file"
          if [ "$(wc -l < "$waits_file")" -eq 1 ]; then
            fake_now_ms=$2
            return 1
          fi
          new_primary_host=redis2; new_primary_port=6379
        }
        handed_over() {
          local started=$fake_now_ms rc=0
          failover_with_writes_paused "redis1" >/dev/null 2>&1 || rc=$?
          echo "rc=$rc"
          while read -r until at; do echo "until +$((until - started)) at +$((at - started))"; done < "$waits_file"
          rm -f "$waits_file"
        }
        When call handed_over
        The line 1 of stdout should eq "rc=0"
        # under the pause, until it ends 5000 ms after it began
        The line 2 of stdout should eq "until +5000 at +0"
        # then without it, from the pause's end, for failover_watch_seconds
        The line 3 of stdout should eq "until +80000 at +5000"
      End

      It "does not fail over when the replica scan outlasts the pause"
        failover_started=""
        # the scan passes, but only after the pause has run out
        replicas_caught_up() { fake_now_ms=$((fake_now_ms + 6000)); return 0; }
        When call failover_with_writes_paused "redis1"
        The status should be failure
        The stdout should not include "failover"
        The stdout should include "cmd redis1: CLIENT UNPAUSE"
        The stderr should include "did not catch up within 5000 ms"
      End

      It "pauses writes for the down-after-milliseconds sentinel has"
        failover_started=""
        get_sentinel_down_after_ms() { echo 3000; }
        When call failover_with_writes_paused "redis1"
        The status should be success
        The line 1 of stdout should eq "cmd redis1: CLIENT PAUSE 3000 WRITE"
        The stdout should include "writes paused on redis1 for 3000 ms"
      End

      It "does not switch over while the sentinels disagree on the primary"
        failover_started=""
        get_sentinel_master_addr() { if [ "$1" = sentinel2 ]; then echo "redis3 6379"; else echo "redis1 6379"; fi; }
        When call failover_with_writes_paused "redis1"
        The status should be failure
        The stdout should not include "CLIENT PAUSE"
        The stderr should include "the sentinels disagree on the primary (redis1 6379,redis3 6379)"
      End

      It "checks the candidate has caught up"
        failover_started=""
        KB_SWITCHOVER_CANDIDATE_FQDN="redis3"
        replicas_caught_up() { echo "caught-up check for candidate [$2]"; }
        When call failover_with_writes_paused "redis1"
        The status should be success
        The stdout should include "caught-up check for candidate [redis3]"
        unset KB_SWITCHOVER_CANDIDATE_FQDN
      End

      It "unpauses when the failover cannot be started"
        failover_started=""
        execute_sentinel_failover() { return 1; }
        sentinel_may_be_failing_over() { return 1; }
        When call failover_with_writes_paused "redis1"
        The status should be failure
        The stdout should include "cmd redis1: CLIENT UNPAUSE"
        The stdout should not include "REPLICAOF"
        The stderr should include "sentinel is no longer failing over and still reports redis1 6379"
      End

      It "hands over when the failover request timed out but sentinel switched"
        failover_started=""
        # the sentinel took the request, but the reply did not come in time
        execute_sentinel_failover() { failover_started=true; return 1; }
        When call failover_with_writes_paused "redis1"
        The status should be success
        The stdout should include "the failover request failed, but sentinel switched the primary all the same"
        The output should match pattern "*REPLICAOF redis2 6379*cmd redis1: CLIENT UNPAUSE*"
      End

      It "does not unpause when the request failed and a sentinel may be failing over"
        failover_started=""
        execute_sentinel_failover() { return 1; }
        wait_for_sentinel_to_switch_master() { return 1; }
        When call failover_with_writes_paused "redis1"
        The status should be failure
        The stdout should not include "CLIENT UNPAUSE"
        The stderr should include "sentinel has not switched within the 5000 ms"
      End

      It "does not fail over when writes cannot be paused"
        failover_started=""
        execute_sub_command() { return 1; }
        When call failover_with_writes_paused "redis1"
        The status should be failure
        The stdout should not include "failover"
        The stderr should include "failed to pause writes on redis1"
      End

      It "keeps writes paused and fails when the old primary is still a master"
        failover_started=""
        check_redis_role() { echo "primary"; }
        When call failover_with_writes_paused "redis1"
        The status should be failure
        The stdout should include "cmd redis1: REPLICAOF redis2 6379"
        The stdout should not include "CLIENT UNPAUSE"
        The stderr should include "redis1 is not a replica of redis2:6379 yet"
      End

      It "trusts the role rather than the REPLICAOF reply"
        failover_started=""
        # REPLICAOF answers "OK Already connected to specified master" when Sentinel got there first
        execute_sub_command() { echo "cmd $1: $4"; [[ "$4" != REPLICAOF* ]]; }
        When call failover_with_writes_paused "redis1"
        The status should be success
        The stdout should include "cmd redis1: CLIENT UNPAUSE"
      End

      It "gives up within the pause when the replicas do not catch up"
        failover_started=""
        replicas_caught_up() { return 1; }
        time_taken() {
          local started=$fake_now_ms
          failover_with_writes_paused "redis1" >/dev/null 2>&1
          echo "rc=$? after $((fake_now_ms - started))ms"
        }
        When call time_taken
        The stdout should eq "rc=1 after 5000ms"
      End

      It "fails when no sentinel knows the primary"
        get_sentinel_master_addr() { :; }
        When call failover_with_writes_paused "redis1"
        The status should be failure
        The stdout should not include "CLIENT PAUSE"
        The stderr should include "no sentinel reports the current primary"
      End
    End

    Context "switchover_with_candidate()"
      It "should execute successful switchover"
        check_redis_role() {
          if [ "$1" = "redis2" ]; then
            echo "secondary"
          else
            echo "primary"
          fi
        }
        check_redis_kernel_status() { return 0; }
        set_redis_priorities() { return 0; }
        failover_with_writes_paused() { return 0; }
        check_switchover_result() { return 0; }
        recover_redis_priorities() { return 0; }

        When call switchover_with_candidate
        The status should be success
        The stdout should include "All FalkorDB config set replica-priority recovered"
        The stderr should equal ""
      End

      It "should fail when candidate is primary"
        check_redis_role() {
          echo "primary"
        }
        When call switchover_with_candidate
        The status should be failure
        The stderr should include "not in secondary role"
        The stdout should equal ""
      End
    End

    Context "switchover_without_candidate()"
      It "should execute successful switchover"
        MOCK_RESPONSES=("redis1" "redis2")
        check_redis_kernel_status() {
          local response=${MOCK_RESPONSES[$RESPONSE_INDEX]}
          RESPONSE_INDEX=$((RESPONSE_INDEX + 1))
          echo "$response"
        }
        failover_with_writes_paused() { return 0;}
        check_switchover_result() { return 0; }
        When call switchover_without_candidate
        The status should be success
      End

      It "should fail when initial status check fails"
        check_redis_kernel_status() {
          return 1
        }
        When call switchover_without_candidate
        The status should be failure
        The stdout should equal ""
      End

      It "should fail when sentinel failover fails"
        check_redis_kernel_status() {
          echo "redis1"
        }
        failover_with_writes_paused() {
          return 1
        }
        When call switchover_without_candidate
        The status should be failure
        The stdout should equal ""
      End
    End

    Context "check_switchover_result()"
      It "should succeed when expected master is achieved"
        check_redis_kernel_status() {
          echo "redis2"
        }
        When call check_switchover_result "redis2" ""
        The status should be success
        The stdout should include "Switchover successful: redis2 is now master"
        The stderr should equal ""
      End

      It "should succeed when switched from initial master"
        check_redis_kernel_status() {
          echo "redis2"
        }
        When call check_switchover_result "" "redis1"
        The status should be success
        The stdout should include "Switchover successful: new master is redis2"
        The stderr should equal ""
      End

      It "should fail when neither expected nor initial master specified"
        check_redis_kernel_status() {
          echo "redis2"
        }
        When call check_switchover_result "" ""
        The status should be failure
        The stderr should include "Neither expected_master nor initial_master specified"
        The stdout should equal ""
      End
    End
  End
End
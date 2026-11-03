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

      It "renews the write pause before every attempt"
        # renewals print nothing, so the commands are logged to a file
        cmd_log="./failover-cmds"
        execute_sub_command() { echo "$1: $4" >> "$cmd_log"; [[ "$4" != "SENTINEL FAILOVER"* ]] || [ "$1" = "sentinel2" ]; }
        # retries like the common library's, without the delay: sentinel1 fails
        # all three attempts, sentinel2 takes the first
        call_func_with_retry() {
          local max_retries="$1" retries=0
          shift 2
          until "$@"; do
            retries=$((retries + 1))
            [ "$retries" -lt "$max_retries" ] || return 1
          done
        }
        logged_commands() {
          : > "$cmd_log"
          paused_primary="redis1"
          execute_sentinel_failover "redis" >/dev/null
          paused_primary=""
          cat "$cmd_log"
          rm -f "$cmd_log"
        }
        When call logged_commands
        The line 1 of stdout should eq "redis1: CLIENT PAUSE 30000 WRITE"
        The line 2 of stdout should eq "sentinel1: SENTINEL FAILOVER redis"
        The line 3 of stdout should eq "redis1: CLIENT PAUSE 30000 WRITE"
        The line 4 of stdout should eq "sentinel1: SENTINEL FAILOVER redis"
        The line 5 of stdout should eq "redis1: CLIENT PAUSE 30000 WRITE"
        The line 6 of stdout should eq "sentinel1: SENTINEL FAILOVER redis"
        The line 7 of stdout should eq "redis1: CLIENT PAUSE 30000 WRITE"
        The line 8 of stdout should eq "sentinel2: SENTINEL FAILOVER redis"
        The lines of stdout should eq 8
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
      caught='role:slave\r\nmaster_link_status:up\r\nslave_repl_offset:500\r\n'

      It "succeeds when every replica has applied the primary's offset"
        redis2_info="$caught"; redis3_info="$caught"
        When call replicas_caught_up "redis1" ""
        The status should be success
      End

      It "fails while a replica still syncs, though the primary would not list it as online"
        redis2_info="$caught"; redis3_info='role:slave\r\nmaster_link_status:down\r\nslave_repl_offset:0\r\n'
        When call replicas_caught_up "redis1" ""
        The status should be failure
        The stderr should include "replica redis3 is at offset 0 of 500 (link down)"
      End

      It "fails while a replica is behind"
        redis2_info='role:slave\r\nmaster_link_status:up\r\nslave_repl_offset:480\r\n'; redis3_info="$caught"
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

      It "renews the write pause before every query"
        redis2_info=""; redis3_info="$caught"
        renew_write_pause() { echo "renew"; }
        # one renewal before the primary's query and one before each replica's
        When call replicas_caught_up "redis1" ""
        The status should be success
        The line 1 of stdout should eq "renew"
        The line 2 of stdout should eq "renew"
        The line 3 of stdout should eq "replica redis2 cannot be reached, skipping it"
        The line 4 of stdout should eq "renew"
        The lines of stdout should eq 4
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
        get_sentinel_master_addrs() { printf '%s\n' "redis1 6379" "redis2 6379"; }
        check_redis_role() { echo "primary"; }
        check_new_primary() {
          wait_for_sentinel_to_switch_master "redis1 6379" && echo "new=$new_primary_host:$new_primary_port"
        }
        When call check_new_primary
        The status should be success
        The stdout should include "new=redis2:6379"
      End

      It "skips a primary a lagging sentinel names that is a replica now"
        get_sentinel_master_addrs() { printf '%s\n' "redis1 6379" "redis3 6379" "redis2 6379"; }
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
        get_sentinel_master_addrs() { echo "redis1 6379"; }
        sentinel_may_be_failing_over() { return 1; }
        When call wait_for_sentinel_to_switch_master "redis1 6379"
        The status should eq 2
        The stderr should include "sentinel is no longer failing over and still reports redis1 6379"
      End

      It "returns 1 when the failover is still running after the last attempt"
        new_primary_max_attempts=3
        get_sentinel_master_addrs() { echo "redis1 6379"; }
        sentinel_may_be_failing_over() { return 0; }
        When call wait_for_sentinel_to_switch_master "redis1 6379"
        The status should eq 1
        The stderr should include "still failing over from redis1 6379 after 3 attempts"
        new_primary_max_attempts=75
      End

      It "takes a switch that happens just as the failover ends"
        # the first look finds no switch; by the second, sentinel has switched
        looks_file="./sentinel-looks"
        echo 0 > "$looks_file"
        get_sentinel_master_addrs() {
          local looks=$(( $(cat "$looks_file") + 1 )); echo "$looks" > "$looks_file"
          if [ "$looks" -ge 2 ]; then echo "redis2 6379"; else echo "redis1 6379"; fi
        }
        check_redis_role() { echo "primary"; }
        sentinel_may_be_failing_over() { return 1; }
        check_new_primary() {
          wait_for_sentinel_to_switch_master "redis1 6379" && echo "new=$new_primary_host:$new_primary_port"
          rm -f "$looks_file"
        }
        When call check_new_primary
        The stdout should include "new=redis2:6379"
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
      get_sentinel_master_addrs() {
        if [ -n "$failover_started" ]; then echo "redis2 6379"; else echo "redis1 6379"; fi
      }
      execute_sentinel_failover() { failover_started=true; echo "failover"; return 0; }
      replicas_caught_up() { return 0; }
      # the old primary turns into a replica, the new one runs as a master
      check_redis_role() { if [ "$1" = "redis2" ]; then echo "primary"; else echo "secondary"; fi; }

      It "pauses writes, fails over, demotes the old primary and only then unpauses"
        failover_started=""
        When call failover_with_writes_paused "redis1"
        The status should be success
        The line 1 of stdout should eq "cmd redis1: CLIENT PAUSE 30000 WRITE"
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

      It "keeps writes paused when it cannot tell whether sentinel will switch"
        failover_started=""
        execute_sentinel_failover() { return 0; }
        wait_for_sentinel_to_switch_master() { return 1; }
        When call failover_with_writes_paused "redis1"
        The status should be failure
        The stdout should not include "CLIENT UNPAUSE"
        The stdout should not include "REPLICAOF"
        The stderr should include "cannot tell whether sentinel fails redis1 over; its writes stay paused"
      End

      It "does not switch over while the sentinels disagree on the primary"
        failover_started=""
        get_sentinel_master_addrs() { printf '%s\n' "redis1 6379" "redis3 6379" "redis1 6379"; }
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
        When call failover_with_writes_paused "redis1"
        The status should be failure
        The stdout should include "cmd redis1: CLIENT UNPAUSE"
        The stdout should not include "REPLICAOF"
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

      It "renews the pause at every step it waits on"
        failover_started=""
        cmd_log="./switchover-cmds"
        : > "$cmd_log"
        # renewals print nothing, so the commands are counted in a file
        execute_sub_command() { echo "$4" >> "$cmd_log"; return 0; }
        attempts=0
        replicas_caught_up() { attempts=$((attempts + 1)); [ "$attempts" -ge 3 ]; }
        execute_sentinel_failover() { renew_write_pause; failover_started=true; return 0; }
        count_pauses() {
          failover_with_writes_paused "redis1" >/dev/null || return 1
          grep -c "CLIENT PAUSE 30000 WRITE" "$cmd_log"
          rm -f "$cmd_log"
        }
        When call count_pauses
        The status should be success
        # once to start, twice while the replicas catch up, once before the failover
        The stdout should eq 4
      End

      It "fails when no sentinel knows the primary"
        get_sentinel_master_addrs() { :; }
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
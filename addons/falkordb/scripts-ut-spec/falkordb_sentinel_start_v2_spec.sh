# shellcheck shell=bash
# shellcheck disable=SC2034

# validate_shell_type_and_version defined in shellspec/spec_helper.sh used to validate the expected shell type and version this script needs to run.
if ! validate_shell_type_and_version "bash" 4 &>/dev/null; then
  echo "redis_sentinel_start_v2_spec.sh skip all cases because dependency bash version 4 or higher is not installed."
  exit 0
fi

source ./utils.sh

common_library_file="./common.sh"
generate_common_library $common_library_file

Describe "FalkorDB Start Sentinel Bash Script Tests"
  # load the scripts to be tested and dependencies
  Include ../scripts/falkordb-sent-start-v2.sh
  Include $common_library_file

  init() {
    redis_sentinel_real_conf="./redis_sentinel.conf"
    redis_sentinel_extra_conf="./redis-sentinel-extra.conf"
    redis_sentinel_real_conf_bak="./redis_sentinel.conf.bak"
    # set ut_mode to true to hack control flow in the script
    ut_mode="true"
  }
  BeforeAll "init"

  cleanup() {
    rm -f $redis_sentinel_real_conf;
    rm -f $redis_sentinel_extra_conf;
    rm -f $common_library_file;
  }
  AfterAll 'cleanup'

  clear_announce_override() {
    unset ANNOUNCE_HOSTNAME_OVERRIDE
  }

  Describe "derive_current_pod_fqdn()"
    It "rebuilds the fqdn of a pod that is missing from the peer list"
      When call derive_current_pod_fqdn "redis-redis-sentinel-0.redis-redis-sentinel-headless.default.svc.cluster.local,redis-redis-sentinel-1.redis-redis-sentinel-headless.default.svc.cluster.local" "redis-redis-sentinel-3"
      The status should be success
      The stdout should equal "redis-redis-sentinel-3.redis-redis-sentinel-headless.default.svc.cluster.local"
    End

    It "returns nothing when the peer list carries no domain"
      When call derive_current_pod_fqdn "redis-redis-sentinel-0" "redis-redis-sentinel-3"
      The status should be success
      The stdout should equal ""
    End

    It "returns nothing when the pod name is unknown"
      When call derive_current_pod_fqdn "redis-redis-sentinel-0.redis-redis-sentinel-headless.default.svc.cluster.local" ""
      The status should be success
      The stdout should equal ""
    End
  End

  Describe "build_redis_sentinel_conf()"
    After "clear_announce_override"
    setup() {
        echo "" > $redis_sentinel_real_conf
        echo "" > $redis_sentinel_extra_conf
        sentinel_port="26379"
        CURRENT_POD_NAME="redis-redis-sentinel-0"
        SENTINEL_POD_FQDN_LIST="redis-redis-sentinel-0.redis-redis-sentinel-headless.default.svc.cluster.local,redis-redis-sentinel-1.redis-redis-sentinel-headless.default.svc.cluster.local"
        SENTINEL_USER="default"
        SENTINEL_PASSWORD="sentinel_password"
      }
      Before 'setup'

      un_setup() {
        unset sentinel_port
        unset CURRENT_POD_NAME
        unset SENTINEL_USER
        unset SENTINEL_PASSWOR
        unset redis_sentinel_announce_host_value
        unset redis_sentinel_announce_port_value
      }
      After 'un_setup'

    It "build redis sentinel conf when sentinel_password are set"
      When call build_redis_sentinel_conf
      The status should be success
      The stdout should include "build redis sentinel conf succeeded!"
      The contents of file "$redis_sentinel_real_conf" should include "include $redis_sentinel_extra_conf"
      The contents of file "$redis_sentinel_real_conf" should include "port $sentinel_port"
      The contents of file "$redis_sentinel_real_conf" should include "sentinel announce-ip $CURRENT_POD_NAME.redis-redis-sentinel-headless.default.svc.cluster.local"
      The contents of file "$redis_sentinel_real_conf" should include "resolve-hostnames yes"
      The contents of file "$redis_sentinel_real_conf" should include "announce-hostnames yes"
      The contents of file "$redis_sentinel_real_conf" should include "sentinel sentinel-user $SENTINEL_USER"
      The contents of file "$redis_sentinel_real_conf" should include "sentinel sentinel-pass $SENTINEL_PASSWORD"
    End

    Context "when the pod was added by a scale-out and is missing from the peer list"
      scaled_out() { CURRENT_POD_NAME="redis-redis-sentinel-3"; }
      Before 'scaled_out'

      It "announces the fqdn derived from its peers instead of refusing to start"
        When call build_redis_sentinel_conf
        The status should be success
        The stdout should include "current pod is absent from the sentinel pod fqdn list"
        The contents of file "$redis_sentinel_real_conf" should include "sentinel announce-ip redis-redis-sentinel-3.redis-redis-sentinel-headless.default.svc.cluster.local"
      End
    End

    It "uses override hostname for sentinel announce when provided"
      export ANNOUNCE_HOSTNAME_OVERRIDE="external.sentinel.example.com"
      When call build_redis_sentinel_conf
      The status should be success
      The contents of file "$redis_sentinel_real_conf" should include "sentinel announce-ip $ANNOUNCE_HOSTNAME_OVERRIDE"
      The contents of file "$redis_sentinel_real_conf" should include "sentinel announce-port $sentinel_port"
      The contents of file "$redis_sentinel_real_conf" should include "announce-hostnames yes"
      The contents of file "$redis_sentinel_real_conf" should include "resolve-hostnames yes"
      The stdout should include "announce hostname override is set, using $ANNOUNCE_HOSTNAME_OVERRIDE for sentinel announce"
    End

    It "announces the advertised nodeport address exactly once"
      redis_sentinel_announce_host_value="172.20.0.3"
      redis_sentinel_announce_port_value="31467"
      When call build_redis_sentinel_conf
      The status should be success
      The stdout should include "redis sentinel use nodeport 172.20.0.3:31467 to announce"
      The contents of file "$redis_sentinel_real_conf" should include "sentinel announce-ip 172.20.0.3"
      The contents of file "$redis_sentinel_real_conf" should include "sentinel announce-port 31467"
      # A second, empty announce pair used to be appended here. The bare
      # 'sentinel announce-ip' is an unrecognized statement that redis refuses
      # to start on, and the default port clobbered the advertised one.
      The contents of file "$redis_sentinel_real_conf" should not include "sentinel announce-port $sentinel_port"
      # A nodeport announces a raw address, so hostname resolution must stay off.
      The contents of file "$redis_sentinel_real_conf" should not include "resolve-hostnames"
    End
  End
End
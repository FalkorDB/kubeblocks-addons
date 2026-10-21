# shellcheck shell=bash
# shellcheck disable=SC2034

# we need bash 4 or higher to run this script in some cases
should_skip_when_shell_type_and_version_invalid() {
  # validate_shell_type_and_version defined in shellspec/spec_helper.sh used to validate the expected shell type and version this script needs to run.
  if validate_shell_type_and_version "bash" 4 &>/dev/null; then
    # should not skip
    return 1
  fi
  echo "falkordb_start_spec.sh skip case because dependency bash version 4 or higher is not installed."
  return 0
}

source ./utils.sh

# The unit test needs to rely on the common library functions defined in kblib.
# Therefore, we first dynamically generate the required common library files from the kblib library chart.
common_library_file="./common.sh"
generate_common_library $common_library_file

Describe "FalkorDB Start Bash Script Tests"
  # load the scripts to be tested and dependencies
  Include ../scripts/falkordb-start.sh
  Include $common_library_file

  init() {
    # override name of redis related file defined in falkordb-start.sh because default conf /etc/redis/redis.conf does not exist
    redis_real_conf="./redis.conf"
    redis_extra_conf="./redis-extra.conf"
    redis_acl_file="./users.acl"
    redis_acl_file_bak="./users.acl.bak"
    redis_data_dir="./falkordb-data"
    # set ut_mode to true to hack control flow in the script
    ut_mode="true"
  }
  BeforeAll "init"

  cleanup() {
    rm -f $redis_real_conf;
    rm -f $redis_extra_conf;
    rm -f $redis_acl_file;
    rm -f $common_library_file;
  }
  AfterAll 'cleanup'

  clear_announce_override() {
    unset ANNOUNCE_HOSTNAME_OVERRIDE
  }

  Describe "extract_obj_ordinal()"
    It "extracts ordinal from object name correctly"
      When call extract_obj_ordinal "pod-name-2"
      The status should be success
      The stdout should eq "2"
      The stderr should eq ""
    End

    It "extracts ordinal from object name with different format"
      When call extract_obj_ordinal "3"
      The stdout should eq "3"
      The stderr should eq ""
    End
  End

  Describe "load_redis_template_conf()"
    setup() {
      echo "" > $redis_extra_conf
    }
    Before 'setup'
    It "appends include directive to redis.conf"
      When call load_redis_template_conf
      The contents of file "$redis_real_conf" should include "include /etc/conf/redis.conf"
      The contents of file "$redis_real_conf" should include "include $redis_extra_conf"
    End
  End

  Describe "build_redis_default_accounts()"
    Context 'when all environment variables exist'
      setup() {
        echo "" > $redis_real_conf
        echo "" > $redis_extra_conf
        echo "" > $redis_acl_file
        export REDIS_REPL_PASSWORD="repl_password"
        export REDIS_SENTINEL_PASSWORD="sentinel_password"
        export REDIS_DEFAULT_PASSWORD="default_password"
      }
      Before 'setup'

      un_setup() {
        unset REDIS_REPL_PASSWORD
        unset REDIS_SENTINEL_PASSWORD
        unset REDIS_DEFAULT_PASSWORD
      }
      After 'un_setup'

      It "builds default accounts correctly when all password envs are set"
        When call build_redis_default_accounts
        The status should be success
        The stdout should include "build default accounts succeeded!"
        The contents of file "$redis_real_conf" should include "masteruser $REDIS_REPL_USER"
        The contents of file "$redis_real_conf" should include "masterauth $REDIS_REPL_PASSWORD"
        The contents of file "$redis_real_conf" should include "protected-mode yes"
        The contents of file "$redis_real_conf" should include "aclfile /data/users.acl"
        The contents of file "$redis_acl_file" should include "user $REDIS_REPL_USER on +psync +replconf +ping >$REDIS_REPL_PASSWORD"
        The contents of file "$redis_acl_file" should include "user $REDIS_SENTINEL_USER on allchannels +multi +slaveof +ping +exec +subscribe +config|rewrite +role +publish +info +client|setname +client|kill +script|kill >$REDIS_SENTINEL_PASSWORD"
        The contents of file "$redis_acl_file" should include "user default on >$REDIS_DEFAULT_PASSWORD ~* &* +@all"
      End
    End

    Context 'when default password environment variables exist'
      setup() {
        echo "" > $redis_real_conf
        echo "" > $redis_extra_conf
        echo "" > $redis_acl_file
        export REDIS_DEFAULT_PASSWORD="default_password"
      }
      Before 'setup'

      un_setup() {
        unset REDIS_DEFAULT_PASSWORD
      }
      After 'un_setup'

      It "builds default accounts correctly when only default password env is set"
        When call build_redis_default_accounts
        The status should be success
        The stdout should include "build default accounts succeeded!"
        The contents of file "$redis_real_conf" should include "protected-mode yes"
        The contents of file "$redis_real_conf" should include "aclfile /data/users.acl"
        The contents of file "$redis_acl_file" should include "user default on >$REDIS_DEFAULT_PASSWORD ~* &* +@all"
      End
    End

    Context 'when all environment variables are not exist'
      setup() {
        echo "" > $redis_real_conf
        echo "" > $redis_extra_conf
        echo "" > $redis_acl_file
      }
      Before 'setup'

      It "disables protected mode when no password env is set"
        When call build_redis_default_accounts
        The status should be success
        The stdout should include "build default accounts succeeded!"
        The contents of file "$redis_real_conf" should include "protected-mode no"
      End
    End
  End

  Describe "build_announce_ip_and_port()"
    After "clear_announce_override"
    It "builds announce ip and port correctly when advertised svc is enabled"
      redis_announce_host_value="172.0.0.1"
      redis_announce_port_value="31000"
      When call build_announce_ip_and_port
      The contents of file "$redis_real_conf" should include "replica-announce-port $redis_announce_port_value"
      The contents of file "$redis_real_conf" should include "replica-announce-ip $redis_announce_host_value"
      The stdout should include "redis use nodeport $redis_announce_host_value:$redis_announce_port_value to announce"
    End

    It "builds announce ip and port correctly when advertised svc is not enabled"
      unset redis_announce_host_value
      unset redis_announce_port_value
      export CURRENT_POD_NAME="redis-redis-0"
      export REDIS_POD_FQDN_LIST="redis-redis-0.redis-redis.default.svc.cluster.local,redis-redis-1.redis-redis.default.svc.cluster.local"
      When call build_announce_ip_and_port
      The contents of file "$redis_real_conf" should include "replica-announce-ip redis-redis-0.redis-redis.default.svc.cluster.local"
      The stdout should include "redis use kb pod fqdn redis-redis-0.redis-redis.default.svc.cluster.local to announce"
    End

    It "uses override hostname for replica announce when provided"
      unset redis_announce_host_value
      unset redis_announce_port_value
      export CURRENT_POD_NAME="redis-redis-0"
      export REDIS_POD_FQDN_LIST="redis-redis-0.redis-redis.default.svc.cluster.local,redis-redis-1.redis-redis.default.svc.cluster.local"
      export ANNOUNCE_HOSTNAME_OVERRIDE="external.redis.example.com"
      When call build_announce_ip_and_port
      The contents of file "$redis_real_conf" should include "replica-announce-ip $ANNOUNCE_HOSTNAME_OVERRIDE"
      The stdout should include "announce hostname override is set, using $ANNOUNCE_HOSTNAME_OVERRIDE for replica announce"
    End

    It "expands \$(POD_NAME) in the override so each replica announces its own name"
      unset redis_announce_host_value
      unset redis_announce_port_value
      export CURRENT_POD_NAME="redis-redis-1"
      export REDIS_POD_FQDN_LIST="redis-redis-0.redis-redis.default.svc.cluster.local,redis-redis-1.redis-redis.default.svc.cluster.local"
      export ANNOUNCE_HOSTNAME_OVERRIDE='$(POD_NAME).redis.example.com'
      When call build_announce_ip_and_port
      The contents of file "$redis_real_conf" should include "replica-announce-ip redis-redis-1.redis.example.com"
      The contents of file "$redis_real_conf" should not include 'POD_NAME'
      The stdout should include "announce hostname override is set, using redis-redis-1.redis.example.com for replica announce"
    End

    It "exits with error when failed to get current pod fqdn"
      unset redis_announce_host_value
      unset redis_announce_port_value
      export CURRENT_POD_NAME="redis-redis-2"
      export REDIS_POD_FQDN_LIST="redis-redis-0.redis-redis.default,redis-redis-1.redis-redis.default"
      When run build_announce_ip_and_port
      The status should be failure
      The stdout should include "Error: Failed to get current pod: redis-redis-2 fqdn from redis pod fqdn list: redis-redis-0.redis-redis.default,redis-redis-1.redis-redis.default. Exiting."
    End
  End

  Describe "build_redis_service_port()"
    # `service_port` is resolved from SERVICE_PORT once, when the script is
    # sourced, so the test has to override the resolved variable itself.
    reset_service_port() {
      service_port=${SERVICE_PORT:-6379}
    }
    AfterEach 'reset_service_port'

    It "builds redis service port correctly when SERVICE_PORT env is set"
      service_port="6380"
      When call build_redis_service_port
      The contents of file "$redis_real_conf" should include "port 6380"
    End

    It "builds redis service port with default value when SERVICE_PORT env is not set"
      unset SERVICE_PORT
      service_port=6379
      When call build_redis_service_port
      The contents of file "$redis_real_conf" should include "port 6379"
    End
  End

  Describe "build_redis_tls_config()"
    cleanup_tls_env() {
      unset TLS_ENABLED
      unset TLS_MOUNT_PATH
    }
    AfterEach 'cleanup_tls_env'

    It "writes nothing when TLS is disabled"
      TLS_ENABLED="false"
      When call build_redis_tls_config
      The contents of file "$redis_real_conf" should not include "tls-cert-file"
    End

    It "writes the full TLS config when TLS is enabled"
      TLS_ENABLED="true"
      TLS_MOUNT_PATH="/etc/pki/tls"
      When call build_redis_tls_config
      The contents of file "$redis_real_conf" should include "tls-cert-file /etc/pki/tls/tls.crt"
      The contents of file "$redis_real_conf" should include "tls-key-file /etc/pki/tls/tls.key"
      The contents of file "$redis_real_conf" should include "tls-ca-cert-file /etc/pki/tls/ca.crt"
      The contents of file "$redis_real_conf" should include "tls-auth-clients no"
      The contents of file "$redis_real_conf" should include "tls-replication yes"
      # the plaintext port must be disabled, otherwise redis keeps listening in clear text
      The contents of file "$redis_real_conf" should include "port 0"
    End

    It "falls back to the default TLS mount path when TLS_MOUNT_PATH is unset"
      TLS_ENABLED="true"
      unset TLS_MOUNT_PATH
      When call build_redis_tls_config
      The contents of file "$redis_real_conf" should include "tls-cert-file /etc/pki/tls/tls.crt"
    End
  End

  Describe "parse_redis_announce_addr()"
    It "parses redis advertised service correctly when matching svc is found"
      export REDIS_ADVERTISED_PORT="redis-redis-redis-advertised-0:31000,redis-redis-redis-advertised-1:32000"
      export CURRENT_POD_HOST_IP="10.0.0.1"
      When call parse_redis_announce_addr "redis-redis-0"
      The variable redis_announce_port_value should eq "31000"
      The variable redis_announce_host_value should eq "10.0.0.1"
      The stdout should include "Found matching svcName and port for podName 'redis-redis-0'"
    End

    It "exits with error when no matching svc is found"
      export REDIS_ADVERTISED_PORT="redis-redis-redis-advertised-0:31000,redis-redis-redis-advertised-1:32000"
      export CURRENT_POD_HOST_IP="10.0.0.2"
      When run parse_redis_announce_addr "redis-redis-2"
      The status should be failure
      The stdout should include "Error: No matching svcName and port found for podName 'redis-redis-2'"
    End

    It "ignores parsing when REDIS_ADVERTISED_PORT env is not set"
      unset REDIS_ADVERTISED_PORT
      When call parse_redis_announce_addr "redis-redis-0"
      The status should be success
      The stdout should include "Environment variable REDIS_ADVERTISED_PORT not found. Ignoring."
    End
  End

  Describe "check_current_pod_is_primary()"
    Context 'mapping with pod name'
      un_setup() {
        unset CURRENT_POD_NAME
        unset REDIS_COMPONENT_NAME
        unset primary
      }
      After 'un_setup'

      It "returns true when current pod name matches the primary"
        export CURRENT_POD_NAME="redis-redis-0"
        export REDIS_COMPONENT_NAME="redis-redis"
        primary="redis-redis-0.redis-redis-headless.default"
        When call check_current_pod_is_primary
        The status should be success
        The stdout should include "current pod is primary with name mapping"
      End

      It "returns false when current pod does not match the primary"
        export CURRENT_POD_NAME="redis-redis-1"
        export REDIS_COMPONENT_NAME="redis-redis"
        primary="redis-redis-0.redis-redis-headless.default"
        When call check_current_pod_is_primary
        The status should be failure
      End
    End

    Context 'mapping with pod ip and service port'
      setup() {
        export CURRENT_POD_NAME="redis-redis-0"
        export CURRENT_POD_IP="10.0.0.1"
        service_port="6379"
        primary="10.0.0.1"
        primary_port="6379"
      }
      Before "setup"

      un_setup() {
        unset CURRENT_POD_IP
        unset CURRENT_POD_NAME
        unset service_port
        unset primary
        unset primary_port
      }
      After 'un_setup'

      It "returns true when current pod IP and service port matches the primary"
        When call check_current_pod_is_primary
        The status should be success
        The stdout should include "current pod is primary with pod ip mapping"
      End
    End

    Context 'mapping with advertised svc host and port'
      setup() {
        export CURRENT_POD_NAME="redis-redis-0"
        export CURRENT_POD_IP="10.0.0.1"
        service_port="6379"
        redis_announce_host_value="172.0.0.1"
        redis_announce_port_value="31000"
      }
      Before "setup"

      un_setup() {
        unset CURRENT_POD_IP
        unset service_port
        unset primary
        unset primary_port
        unset redis_announce_host_value
        unset redis_announce_port_value
      }
      After 'un_setup'

      It "returns false when current redis_announce_host_value and redis_announce_port_value exist but not match"
        primary="172.0.0.1"
        primary_port="32000"
        When call check_current_pod_is_primary
        The status should be failure
        The stdout should include "redis advertised svc host and port exist but not match"
      End

      It "returns true when current redis_announce_host_value and redis_announce_port_value matches the primary"
        primary="172.0.0.1"
        primary_port="31000"
        When call check_current_pod_is_primary
        The status should be success
        The stdout should include "current pod is primary with advertised svc mapping"
      End
    End

    Context 'mapping with the announce hostname override'
      setup() {
        export CURRENT_POD_NAME="redis-redis-0"
        export REDIS_COMPONENT_NAME="redis-redis"
        export ANNOUNCE_HOSTNAME_OVERRIDE='$(POD_NAME).redis.example.com'
      }
      Before "setup"

      un_setup() {
        unset CURRENT_POD_NAME
        unset REDIS_COMPONENT_NAME
        unset ANNOUNCE_HOSTNAME_OVERRIDE
        unset primary
      }
      After 'un_setup'

      It "returns true when the primary is this pod under its override hostname"
        primary="redis-redis-0.redis.example.com"
        When call check_current_pod_is_primary
        The status should be success
        The stdout should include "current pod is primary with announce hostname mapping"
      End

      It "returns false when the primary is another pod's override hostname"
        primary="redis-redis-1.redis.example.com"
        When call check_current_pod_is_primary
        The status should be failure
      End
    End
  End

  Describe "rebuild_redis_acl_file()"
    It "rebuilds redis acl file by removing specific user lines"
      echo "user default on >default_password" > $redis_acl_file
      echo "user repl_user on >repl_password" >> $redis_acl_file
      echo "user sentinel_user on >sentinel_password" >> $redis_acl_file
      export REDIS_REPL_USER="repl_user"
      export REDIS_SENTINEL_USER="sentinel_user"
      When call rebuild_redis_acl_file
      The status should be success
      The contents of file "$redis_acl_file" should not include "user default on"
      The contents of file "$redis_acl_file" should not include "user repl_user on"
      The contents of file "$redis_acl_file" should not include "user sentinel_user on"
    End

    It "creates an empty redis acl file if it does not exist"
      rm -f $redis_acl_file
      When call rebuild_redis_acl_file
      The path "$redis_acl_file" should be exist
      The contents of file "$redis_acl_file" should eq ""
    End
  End

  Describe "add_extra_falkordb_user_account()"
    Context 'when both username and password are provided'
      setup() {
        echo "" > $redis_acl_file
        export FALKORDB_EXTRA_USER_USERNAME="extra_user"
        export FALKORDB_EXTRA_USER_PASSWORD="extra_password"
        export FALKORDB_EXTRA_USER_ACL="~* +@all"
      }
      Before 'setup'

      un_setup() {
        unset FALKORDB_EXTRA_USER_USERNAME
        unset FALKORDB_EXTRA_USER_PASSWORD
        unset FALKORDB_EXTRA_USER_ACL
      }
      After 'un_setup'

      It "adds extra user to acl file with custom ACL rules"
        When call add_extra_falkordb_user_account
        The status should be success
        The stdout should include "Adding extra FalkorDB user extra_user to ACL file."
        The contents of file "$redis_acl_file" should include "user extra_user on >extra_password ~* +@all"
      End
    End

    Context 'when username and password are provided but ACL is not'
      setup() {
        echo "" > $redis_acl_file
        export FALKORDB_EXTRA_USER_USERNAME="extra_user"
        export FALKORDB_EXTRA_USER_PASSWORD="extra_password"
        unset FALKORDB_EXTRA_USER_ACL
      }
      Before 'setup'

      un_setup() {
        unset FALKORDB_EXTRA_USER_USERNAME
        unset FALKORDB_EXTRA_USER_PASSWORD
      }
      After 'un_setup'

      It "adds extra user with default ACL rules when ACL env is not set"
        When call add_extra_falkordb_user_account
        The status should be success
        The stdout should include "Adding extra FalkorDB user extra_user to ACL file."
        The contents of file "$redis_acl_file" should include "user extra_user on >extra_password ~* +@all"
      End
    End

    Context 'when username or password is not provided'
      setup() {
        echo "" > $redis_acl_file
        unset FALKORDB_EXTRA_USER_USERNAME
        unset FALKORDB_EXTRA_USER_PASSWORD
      }
      Before 'setup'

      It "skips adding extra user when username is missing"
        When call add_extra_falkordb_user_account
        The status should be success
        The stdout should include "No extra FalkorDB user configured, skipping."
        The contents of file "$redis_acl_file" should eq ""
      End
    End

    Context 'when password is missing but username is provided'
      setup() {
        echo "" > $redis_acl_file
        export FALKORDB_EXTRA_USER_USERNAME="extra_user"
        unset FALKORDB_EXTRA_USER_PASSWORD
      }
      Before 'setup'

      un_setup() {
        unset FALKORDB_EXTRA_USER_USERNAME
      }
      After 'un_setup'

      It "skips adding extra user when password is missing"
        When call add_extra_falkordb_user_account
        The status should be success
        The stdout should include "No extra FalkorDB user configured, skipping."
        The contents of file "$redis_acl_file" should eq ""
      End
    End
  End

  Describe "build_sentinel_get_master_addr_by_name_command()"
    It "builds sentinel get-master-addr-by-name command correctly"
      export REDIS_COMPONENT_NAME="redis-redis"
      export SENTINEL_SERVICE_PORT="26379"
      When call build_sentinel_get_master_addr_by_name_command "sentinel1.redis-sentinel-headless"
      The output should eq "timeout 5 redis-cli  -h sentinel1.redis-sentinel-headless -p 26379 sentinel get-master-addr-by-name redis-redis"
    End

    It "builds sentinel get-master-addr-by-name command correctly"
      export REDIS_COMPONENT_NAME="redis-redis"
      export SENTINEL_SERVICE_PORT="26379"
      export SENTINEL_PASSWORD="sentinel_password"
      When call build_sentinel_get_master_addr_by_name_command "sentinel1.redis-sentinel-headless"
      The output should eq "timeout 5 redis-cli  -h sentinel1.redis-sentinel-headless -p 26379 -a sentinel_password sentinel get-master-addr-by-name redis-redis"
    End
  End

  Describe "get_master_addr_by_name_from_sentinel()"
    It "handles empty sentinel password"
      unset SENTINEL_PASSWORD
      build_sentinel_get_master_addr_by_name_command() {
        echo "echo $SENTINEL_PASSWORD 1111"
      }
      When call get_master_addr_by_name_from_sentinel "sentinel1.redis-sentinel-headless"
      The status should be failure
      The stdout should include "Empty primary info retrieved from sentinel"
      The stdout should include "execute get-master-addr-by-name command: echo  1111"
    End

    It "handles not empty sentinel password"
      SENTINEL_PASSWORD="sentinel_password"
      build_sentinel_get_master_addr_by_name_command() {
        echo "echo $SENTINEL_PASSWORD"
      }
      When call get_master_addr_by_name_from_sentinel "sentinel1.redis-sentinel-headless"
      The status should be failure
      The stdout should include "Empty primary info retrieved from sentinel"
      The stdout should include "execute get-master-addr-by-name command: echo ********"
    End

    It "retrieves primary info from sentinel successfully"
      # Mock the command to get redis master addr info from sentinel
      build_sentinel_get_master_addr_by_name_command() {
        mock_output="172.18.0.3 31081"
        # shellcheck disable=SC2028
        echo "echo '$mock_output'"
      }
      When call get_master_addr_by_name_from_sentinel "sentinel1.redis-sentinel-headless"
      The status should be success
      The stdout should include "Successfully retrieved primary info from sentinel"
    End

    It "handles empty primary info from sentinel"
      build_sentinel_get_master_addr_by_name_command() {
        echo "echo ''"
      }
      When call get_master_addr_by_name_from_sentinel "sentinel1.redis-sentinel-headless"
      The status should be failure
      The stdout should include "Empty primary info retrieved from sentinel"
    End

    It "retries on timeout error from sentinel"
      build_sentinel_get_master_addr_by_name_command() {
        echo "return 124"
      }
      When call get_master_addr_by_name_from_sentinel "sentinel1.redis-sentinel-headless"
      The status should be failure
      The stdout should include "Timeout occurred while retrieving primary info from sentinel. Retrying..."
    End

    It "retries on other errors from sentinel"
      build_sentinel_get_master_addr_by_name_command() {
        echo "return 1"
      }
      When call get_master_addr_by_name_from_sentinel "sentinel1.redis-sentinel-headless"
      The status should be failure
      The stdout should include "Error occurred while retrieving primary info from sentinel. Retrying..."
    End
  End

  Describe "retry_get_master_addr_by_name_from_sentinel()"
    It "retries to get primary info from sentinel successfully"
      get_master_addr_by_name_from_sentinel() {
        # mock get_master_addr_by_name_from_sentinel success
        return 0
      }
      When call retry_get_master_addr_by_name_from_sentinel 2 1 "sentinel1.redis-sentinel-headless"
      The status should be success
    End

    It "retries to get primary info from sentinel and fails"
      get_master_addr_by_name_from_sentinel() {
        # mock get_master_addr_by_name_from_sentinel failure
        return 1
      }
      When call retry_get_master_addr_by_name_from_sentinel 1 1 "sentinel1.redis-sentinel-headless"
      The status should be failure
      The stdout should include "Failed to retrieve primary info from sentinel"
      The stderr should include "Function 'get_master_addr_by_name_from_sentinel' failed after 1 retries"
    End
  End

  Describe "get_default_initialize_primary_node()"
    Context "when min lexicographical order pod fqdn exists"
      setup() {
        export REDIS_POD_NAME_LIST="redis-2,redis-1,redis-0"
        export REDIS_POD_FQDN_LIST="redis-2.redis-headless.default,redis-1.redis-headless.default,redis-0.redis-headless.default"
        service_port="6379"
      }
      Before "setup"

      un_setup() {
        unset REDIS_POD_NAME_LIST
        unset REDIS_POD_FQDN_LIST
        unset service_port
      }
      After "un_setup"

      It "gets the minimum lexicographical order pod name as default primary node"
        When call get_default_initialize_primary_node
        The variable primary should eq "redis-0.redis-headless.default"
        The variable primary_port should eq "6379"
        The stdout should include "get the minimum lexicographical order pod name: redis-0.redis-headless.default as default primary node"
      End
    End

    Context "when min lexicographical order pod fqdn does not exist"
      setup() {
        export REDIS_POD_NAME_LIST="redis-2,redis-1,redis-0"
        export REDIS_POD_FQDN_LIST="redis-2.redis-headless.default,redis-1.redis-headless.default"
        service_port="6379"
      }
      Before "setup"

      un_setup() {
        unset REDIS_POD_NAME_LIST
        unset REDIS_POD_FQDN_LIST
        unset service_port
      }
      After "un_setup"

      It "exits with error if failed to get min lexicographical order pod fqdn"
        When run get_default_initialize_primary_node
        The status should be failure
        The stdout should include "Error: Failed to get min lexicographical order pod: $CURRENT_POD_NAME fqdn from redis pod fqdn list: redis-2.redis-headless.default,redis-1.redis-headless.default. Exiting."
      End
    End
  End

  Describe "init_or_get_primary_from_redis_sentinel()"
    Context "when SENTINEL_COMPONENT_NAME is not set"
      setup() {
        primary=""
        primary_port=""
        unset SENTINEL_COMPONENT_NAME
      }
      Before "setup"

      It "gets default primary node if SENTINEL_COMPONENT_NAME is not set"
        Skip if "shell type and version unmatch, please check!" should_skip_when_shell_type_and_version_invalid
        get_default_initialize_primary_node() {
          # shellcheck disable=SC2034
          primary="fake-primary"
          # shellcheck disable=SC2034
          primary_port="fake-primary-port"
        }
        When call init_or_get_primary_from_redis_sentinel
        The status should be success
        The stdout should include "SENTINEL_COMPONENT_NAME env is not set, try to use default primary node"
        The variable primary should eq "fake-primary"
        The variable primary_port should eq "fake-primary-port"
      End
    End

    Context "when SENTINEL_POD_FQDN_LIST is not set"
      setup() {
        export SENTINEL_COMPONENT_NAME="redis-sentinel"
        unset SENTINEL_POD_FQDN_LIST
      }
      Before "setup"

      un_setup() {
        unset SENTINEL_COMPONENT_NAME
      }
      After "un_setup"

      It "exits with error if SENTINEL_POD_FQDN_LIST is not set"
        Skip if "shell type and version unmatch, please check!" should_skip_when_shell_type_and_version_invalid
        When run init_or_get_primary_from_redis_sentinel
        The status should be failure
        The stdout should include "Error: Required environment variable SENTINEL_POD_FQDN_LIST is not set."
      End
    End

    Context "when primary info is retrieved from sentinels"
      setup() {
        export SENTINEL_COMPONENT_NAME="redis-sentinel"
        export SENTINEL_POD_FQDN_LIST="sentinel-0.redis-sentinel-headless,sentinel-1.redis-sentinel-headless,sentinel-2.redis-sentinel-headless"
      }
      Before "setup"

      un_setup() {
        unset SENTINEL_COMPONENT_NAME
        unset SENTINEL_POD_FQDN_LIST
      }
      After "un_setup"

      It "retrieves primary info from multiple sentinels and selects the one with max count"
        Skip if "shell type and version unmatch, please check!" should_skip_when_shell_type_and_version_invalid
        build_sentinel_get_master_addr_by_name_command() {
          mock_output="172.18.0.3 31081"
          # shellcheck disable=SC2028
          echo "echo '$mock_output'"
        }
        When call init_or_get_primary_from_redis_sentinel
        The status should be success
        The variable primary should eq "172.18.0.3"
        The variable primary_port should eq "31081"
        The stdout should include "sentinel:sentinel-0.redis-sentinel-headless has master info: 172.18.0.3 31081"
        The stdout should include "sentinel:sentinel-1.redis-sentinel-headless has master info: 172.18.0.3 31081"
        The stdout should include "sentinel:sentinel-2.redis-sentinel-headless has master info: 172.18.0.3 31081"
      End
    End

    Context "when no sentinel returns primary info"
      setup() {
        # shellcheck disable=SC2034
        retry_times=1
        # shellcheck disable=SC2034
        retry_delay_second=1
        export REDIS_POD_NAME_LIST="redis-1,redis-0"
        export SENTINEL_COMPONENT_NAME="redis-sentinel"
        export SENTINEL_POD_FQDN_LIST="sentinel-0.redis-sentinel-headless,sentinel-1.redis-sentinel-headless"
        primary=""
        primary_port=""
        # the files the scripts write before the server ever runs, plus mkfs's lost+found
        mkdir -p "$redis_data_dir/lost+found"
        echo "user default on" > "$redis_data_dir/users.acl"
        echo "" > "$redis_data_dir/.fixed_pod_ip_enabled"
      }
      Before "setup"

      un_setup() {
        unset REDIS_POD_NAME_LIST
        unset SENTINEL_COMPONENT_NAME
        unset SENTINEL_POD_FQDN_LIST
        chmod 755 "$redis_data_dir" 2>/dev/null
        rm -rf "$redis_data_dir"
      }
      After "un_setup"

      # by default every sentinel is reachable and monitors no master (nil reply)
      build_sentinel_get_master_addr_by_name_command() {
        echo "echo ''"
      }
      unreachable_sentinels() {
        build_sentinel_get_master_addr_by_name_command() {
          echo "false"
        }
      }
      get_default_initialize_primary_node() {
        echo "default primary fallback called"
        # shellcheck disable=SC2034
        primary="fake-primary1"
        # shellcheck disable=SC2034
        primary_port="fake-primary-port1"
      }

      It "falls back to the default primary when the data dir holds no persisted data"
        Skip if "shell type and version unmatch, please check!" should_skip_when_shell_type_and_version_invalid
        When call init_or_get_primary_from_redis_sentinel
        The status should be success
        The stdout should include "Empty primary info retrieved from sentinel"
        The stdout should include "Failed to retrieve primary info from sentinel: sentinel-1.redis-sentinel-headless"
        The stdout should include "no primary node found from all redis sentinels and $redis_data_dir has no persisted data, use default primary node for first bootstrap."
        The stdout should include "default primary fallback called"
        The stderr should include "Function 'get_master_addr_by_name_from_sentinel' failed after 1 retries"
        The variable primary should eq "fake-primary1"
        The variable primary_port should eq "fake-primary-port1"
      End

      It "falls back to the default primary when the data dir does not exist"
        Skip if "shell type and version unmatch, please check!" should_skip_when_shell_type_and_version_invalid
        rm -rf "$redis_data_dir"
        When call init_or_get_primary_from_redis_sentinel
        The status should be success
        The stdout should include "default primary fallback called"
        The stderr should include "Function 'get_master_addr_by_name_from_sentinel' failed after 1 retries"
        The variable primary should eq "fake-primary1"
      End

      Context "when sentinels are down"
        Parameters
          "dump.rdb" file
          "appendonlydir" dir
          "appendonly.aof" file
          "temp-123.rdb" file
          ".kb-data-protection" file
          ".restore_keys" dir
        End

        It "exits non-zero without the default primary when sentinels are down and $1 is persisted"
          Skip if "shell type and version unmatch, please check!" should_skip_when_shell_type_and_version_invalid
          unreachable_sentinels
          if [ "$2" = "dir" ]; then mkdir -p "$redis_data_dir/$1"; else echo "persisted" > "$redis_data_dir/$1"; fi
          When run init_or_get_primary_from_redis_sentinel
          The status should be failure
          The stdout should include "Error occurred while retrieving primary info from sentinel"
          The stdout should include "Error: no primary node found from all redis sentinels (0 of 2 reachable without a primary) and $redis_data_dir already holds persisted data ($1); refusing to fall back to the default primary while sentinel is configured. Exiting."
          The stdout should not include "default primary fallback called"
          The stdout should not include "use default primary node for first bootstrap"
          The stderr should include "Function 'get_master_addr_by_name_from_sentinel' failed after 1 retries"
        End
      End

      Context "when every sentinel is reachable and monitors no master"
        peers_setup() {
          export CURRENT_POD_NAME="redis-1"
          export REDIS_POD_FQDN_LIST="redis-0.redis-headless.default,redis-1.redis-headless.default,redis-2.redis-headless.default"
          service_port="6379"
          echo "persisted" > "$redis_data_dir/dump.rdb"
        }
        Before "peers_setup"

        peers_un_setup() {
          unset CURRENT_POD_NAME
          unset REDIS_POD_FQDN_LIST
          unset service_port
        }
        After "peers_un_setup"

        It "falls back to the default primary with persisted data when no other pod runs as primary"
          Skip if "shell type and version unmatch, please check!" should_skip_when_shell_type_and_version_invalid
          # a cluster restored from backup: data is in place, sentinels are fresh, peers still starting
          get_peer_replication_role() {
            [ "$1" = "redis-1.redis-headless.default" ] && echo "asked the current pod"
            return 0
          }
          When call init_or_get_primary_from_redis_sentinel
          The status should be success
          The stdout should include "every sentinel is reachable and none monitors $REDIS_COMPONENT_NAME, while $redis_data_dir holds persisted data (dump.rdb); looking for a live primary among the other pods."
          The stdout should include "pod redis-0.redis-headless.default replication role: unreachable"
          The stdout should include "pod redis-2.redis-headless.default replication role: unreachable"
          The stdout should not include "asked the current pod"
          The stdout should include "no other pod is running as primary, use default primary node."
          The stdout should include "default primary fallback called"
          The stderr should include "Function 'get_master_addr_by_name_from_sentinel' failed after 1 retries"
          The variable primary should eq "fake-primary1"
        End

        It "follows a live primary instead of the default when sentinels lost their state"
          Skip if "shell type and version unmatch, please check!" should_skip_when_shell_type_and_version_invalid
          get_peer_replication_role() {
            case "$1" in
              redis-2.*) echo "master" ;;
              *) echo "slave redis-2.redis-headless.default 6379" ;;
            esac
          }
          When call init_or_get_primary_from_redis_sentinel
          The status should be success
          The stdout should include "follow the live primary redis-2.redis-headless.default reported by the pod itself."
          The stdout should not include "default primary fallback called"
          The stderr should include "Function 'get_master_addr_by_name_from_sentinel' failed after 1 retries"
          The variable primary should eq "redis-2.redis-headless.default"
          The variable primary_port should eq "6379"
        End

        It "takes the primary role back when the other pods replicate from it"
          Skip if "shell type and version unmatch, please check!" should_skip_when_shell_type_and_version_invalid
          # the primary restarts in a rolling update after the sentinels lost their state
          get_peer_replication_role() { echo "slave redis-1.redis-headless.default 6379"; }
          When call init_or_get_primary_from_redis_sentinel
          The status should be success
          The stdout should include "pod redis-0.redis-headless.default replication role: slave of redis-1.redis-headless.default"
          The stdout should include "no other pod is running as primary and redis-0.redis-headless.default redis-2.redis-headless.default replicate from this pod, take the primary role back."
          The stdout should not include "default primary fallback called"
          The stderr should include "Function 'get_master_addr_by_name_from_sentinel' failed after 1 retries"
          The variable primary should eq "redis-1.redis-headless.default"
          The variable primary_port should eq "6379"
        End

        It "takes the primary role back when a replica names it by its announce hostname"
          Skip if "shell type and version unmatch, please check!" should_skip_when_shell_type_and_version_invalid
          get_announce_hostname_override_or_default() { echo "redis-1.example.com"; }
          ANNOUNCE_HOSTNAME_OVERRIDE="redis-{pod}.example.com"
          get_peer_replication_role() {
            case "$1" in
              redis-0.*) echo "slave redis-1.example.com 6379" ;;
            esac
          }
          When call init_or_get_primary_from_redis_sentinel
          The status should be success
          The stdout should include "no other pod is running as primary and redis-0.redis-headless.default replicate from this pod, take the primary role back."
          The stderr should include "Function 'get_master_addr_by_name_from_sentinel' failed after 1 retries"
          The variable primary should eq "redis-1.redis-headless.default"
        End

        It "exits non-zero instead of the default when the other pods replicate from a pod that is not up"
          Skip if "shell type and version unmatch, please check!" should_skip_when_shell_type_and_version_invalid
          # redis-0, the default, is a replica of redis-2, which is restarting
          get_peer_replication_role() {
            case "$1" in
              redis-0.*) echo "slave redis-2.redis-headless.default 6379" ;;
            esac
          }
          When run init_or_get_primary_from_redis_sentinel
          The status should be failure
          The stdout should include "Error: no other pod is running as primary and redis-0.redis-headless.default replicate from a pod that is not; waiting for it rather than picking the default primary. Exiting."
          The stdout should not include "default primary fallback called"
          The stderr should include "Function 'get_master_addr_by_name_from_sentinel' failed after 1 retries"
        End

        It "exits non-zero when some replicas follow this pod and others another one"
          Skip if "shell type and version unmatch, please check!" should_skip_when_shell_type_and_version_invalid
          get_peer_replication_role() {
            case "$1" in
              redis-0.*) echo "slave redis-1.redis-headless.default 6379" ;;
              redis-2.*) echo "slave 10.0.0.9 6379" ;;
            esac
          }
          When run init_or_get_primary_from_redis_sentinel
          The status should be failure
          The stdout should include "Error: no other pod is running as primary, redis-0.redis-headless.default replicate from this pod but redis-2.redis-headless.default from another; refusing to pick a primary. Exiting."
          The stdout should not include "take the primary role back"
          The stdout should not include "default primary fallback called"
          The stderr should include "Function 'get_master_addr_by_name_from_sentinel' failed after 1 retries"
        End

        It "takes the primary role back behind a NodePort after moving to another node"
          Skip if "shell type and version unmatch, please check!" should_skip_when_shell_type_and_version_invalid
          # the replica still names the node redis-1 ran on before the restart
          redis_announce_via_nodeport="true"
          redis_announce_host_value="172.18.0.4"
          redis_announce_port_value="31001"
          CURRENT_POD_IP="10.42.0.7"
          get_peer_replication_role() {
            case "$1" in
              redis-0.*) echo "slave 172.18.0.3 31001" ;;
            esac
          }
          When call init_or_get_primary_from_redis_sentinel
          The status should be success
          The stdout should include "no other pod is running as primary and redis-0.redis-headless.default replicate from this pod, take the primary role back."
          The stderr should include "Function 'get_master_addr_by_name_from_sentinel' failed after 1 retries"
          The variable primary should eq "redis-1.redis-headless.default"
        End

        It "does not match another pod's NodePort on this pod's old node"
          Skip if "shell type and version unmatch, please check!" should_skip_when_shell_type_and_version_invalid
          redis_announce_via_nodeport="true"
          redis_announce_host_value="172.18.0.4"
          redis_announce_port_value="31001"
          get_peer_replication_role() {
            case "$1" in
              redis-0.*) echo "slave 172.18.0.4 31002" ;;
            esac
          }
          When run init_or_get_primary_from_redis_sentinel
          The status should be failure
          The stdout should include "replicate from a pod that is not; waiting for it"
          The stderr should include "Function 'get_master_addr_by_name_from_sentinel' failed after 1 retries"
        End

        It "exits non-zero when several other pods run as master"
          Skip if "shell type and version unmatch, please check!" should_skip_when_shell_type_and_version_invalid
          get_peer_replication_role() { echo "master"; }
          When run init_or_get_primary_from_redis_sentinel
          The status should be failure
          The stdout should include "Error: cannot tell which pod is the live primary (both redis-0.redis-headless.default and redis-2.redis-headless.default run as master); refusing to pick a primary while sentinel monitors none. Exiting."
          The stdout should not include "default primary fallback called"
          The stderr should include "Function 'get_master_addr_by_name_from_sentinel' failed after 1 retries"
        End

        It "exits non-zero when a reachable pod's role cannot be read"
          Skip if "shell type and version unmatch, please check!" should_skip_when_shell_type_and_version_invalid
          get_peer_replication_role() { echo "unknown"; }
          When run init_or_get_primary_from_redis_sentinel
          The status should be failure
          The stdout should include "(pod redis-0.redis-headless.default is reachable but its role is unknown)"
          The stdout should not include "default primary fallback called"
          The stderr should include "Function 'get_master_addr_by_name_from_sentinel' failed after 1 retries"
        End
      End

      It "exits non-zero with persisted data when only some sentinels are reachable"
        Skip if "shell type and version unmatch, please check!" should_skip_when_shell_type_and_version_invalid
        build_sentinel_get_master_addr_by_name_command() {
          if [ "$1" = "sentinel-0.redis-sentinel-headless" ]; then echo "echo ''"; else echo "false"; fi
        }
        echo "persisted" > "$redis_data_dir/dump.rdb"
        When run init_or_get_primary_from_redis_sentinel
        The status should be failure
        The stdout should include "(1 of 2 reachable without a primary)"
        The stdout should not include "default primary fallback called"
        The stderr should include "Function 'get_master_addr_by_name_from_sentinel' failed after 1 retries"
      End

      It "exits non-zero when sentinels answer with an error reply and data is persisted"
        Skip if "shell type and version unmatch, please check!" should_skip_when_shell_type_and_version_invalid
        build_sentinel_get_master_addr_by_name_command() {
          echo "echo 'NOAUTH Authentication required.'"
        }
        echo "persisted" > "$redis_data_dir/dump.rdb"
        When run init_or_get_primary_from_redis_sentinel
        The status should be failure
        The stdout should include "(0 of 2 reachable without a primary)"
        The stdout should not include "default primary fallback called"
        The stderr should include "Function 'get_master_addr_by_name_from_sentinel' failed after 1 retries"
      End

      running_as_root() { [ "$(id -u)" = "0" ]; }

      It "exits non-zero when sentinels are down and the data dir cannot be listed"
        Skip if "shell type and version unmatch, please check!" should_skip_when_shell_type_and_version_invalid
        Skip if "root can list any dir" running_as_root
        unreachable_sentinels
        echo "persisted" > "$redis_data_dir/dump.rdb"
        chmod 100 "$redis_data_dir"
        When run init_or_get_primary_from_redis_sentinel
        The status should be failure
        The stdout should include "already holds persisted data ($redis_data_dir is not a listable directory)"
        The stdout should not include "default primary fallback called"
        The stderr should include "Function 'get_master_addr_by_name_from_sentinel' failed after 1 retries"
      End
    End
  End

  Describe "get_peer_replication_role()"
    timeout() { shift; "$@"; }

    It "reports master from info replication"
      redis-cli() { printf '# Replication\r\nrole:master\r\nconnected_slaves:1\r\n'; }
      When call get_peer_replication_role "redis-0.redis-headless.default"
      The output should eq "master"
    End

    It "reports slave from info replication"
      redis-cli() { printf '# Replication\r\nrole:slave\r\nmaster_host:redis-0\r\nmaster_port:6379\r\n'; }
      When call get_peer_replication_role "redis-1.redis-headless.default"
      The output should eq "slave redis-0 6379"
    End

    It "reports unknown for a replica without master_port"
      redis-cli() { printf '# Replication\r\nrole:slave\r\nmaster_host:redis-0\r\n'; }
      When call get_peer_replication_role "redis-1.redis-headless.default"
      The output should eq "unknown"
    End

    It "prints nothing when the pod cannot be reached"
      redis-cli() { echo "Could not connect to Redis" >&2; return 1; }
      When call get_peer_replication_role "redis-0.redis-headless.default"
      The status should be success
      The output should eq ""
    End

    It "reports unknown on an error reply"
      redis-cli() { echo "NOAUTH Authentication required."; }
      When call get_peer_replication_role "redis-0.redis-headless.default"
      The output should eq "unknown"
    End
  End

  Describe "build_redis_server_start_cmd()"
    module_dir="./falkordb-module"

    module_setup() {
      mkdir -p "$module_dir"
      touch "$module_dir/falkordb.so"
    }
    Before 'module_setup'

    module_un_setup() {
      rm -rf "$module_dir"
      unset FALKORDB_ARGS
      unset FALKORDB_EXTRA_MODULES_ARGS
    }
    After 'module_un_setup'

    It "appends the extra module args when FALKORDB_EXTRA_MODULES_ARGS is set"
      export FALKORDB_ARGS="THREAD_COUNT 4"
      export FALKORDB_EXTRA_MODULES_ARGS="CACHE_SIZE 50"
      When call build_redis_server_start_cmd "$module_dir"
      The status should be success
      The stdout should include "--loadmodule $module_dir/falkordb.so THREAD_COUNT 4 CACHE_SIZE 50"
    End

    It "passes no extra module args when FALKORDB_EXTRA_MODULES_ARGS is unset"
      export FALKORDB_ARGS="THREAD_COUNT 4"
      When call build_redis_server_start_cmd "$module_dir"
      The status should be success
      The stdout should include "--loadmodule $module_dir/falkordb.so THREAD_COUNT 4"
      The stdout should not include "''"
    End

    It "starts without the module when falkordb.so is not present"
      rm -f "$module_dir/falkordb.so"
      When call build_redis_server_start_cmd "$module_dir"
      The status should be success
      The stdout should eq "redis-server /etc/redis/redis.conf"
    End
  End

  Describe "start_redis_server()"
    # Stand-in for util-linux `script -q -f -e -c <cmd> /dev/null`, which runs
    # <cmd> and exits with its status (the host's script may be BSD-flavoured).
    script() {
      while [ $# -gt 0 ]; do
        if [ "$1" = "-c" ]; then eval "$2"; return $?; fi
        shift
      done
    }

    It "exits with the server's non-zero status when the server crashes"
      build_redis_server_start_cmd() { echo "sh -c 'echo crashed; exit 139'"; }
      When call start_redis_server
      The status should eq 139
      The stdout should include "[falkordb] crashed"
      The stdout should include "falkordb server exited with status 139"
    End

    It "exits successfully when the server shuts down cleanly"
      build_redis_server_start_cmd() { echo "sh -c 'echo bye; exit 0'"; }
      When call start_redis_server
      The status should be success
      The stdout should include "[falkordb] bye"
    End

    It "prints the crash report one clean, tagged line at a time"
      # A pty hands back "\r\n" line endings, and "\r\r\n" for the INFO section
      # of a crash report, which already uses "\r\n".
      build_redis_server_start_cmd() {
        echo "printf '1:M 13 Oct 2026 10:00:00.000 # Redis crashed by signal: 11\\r\\n# Server\\r\\r\\n\\r\\n'; exit 139"
      }
      When call start_redis_server
      The status should eq 139
      The line 2 of stdout should eq "[falkordb] # Redis crashed by signal: 11"
      The line 3 of stdout should eq "[falkordb] # Server"
      The line 4 of stdout should eq "[falkordb] "
      The stdout should not include "$(printf '\r')"
    End

    It "exits with the server's status and tags its lines when script is unavailable"
      command() {
        if [ "$1" = "-v" ] && [ "$2" = "script" ]; then return 1; fi
        builtin command "$@"
      }
      build_redis_server_start_cmd() { echo "sh -c 'echo 1:M 13 Oct 2026 10:00:00.000 crashed; exit 139'"; }
      When call start_redis_server
      The status should eq 139
      The line 2 of stdout should eq "[falkordb] crashed"
      The stdout should include "falkordb server exited with status 139"
    End
  End
End

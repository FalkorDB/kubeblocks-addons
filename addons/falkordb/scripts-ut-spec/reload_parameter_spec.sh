# shellcheck shell=bash
# shellcheck disable=SC2034

if ! validate_shell_type_and_version "bash" 4 &>/dev/null; then
  echo "reload_parameter_spec.sh skip all cases because dependency bash version 4 or higher is not installed."
  exit 0
fi

Describe "FalkorDB Reload Parameter Script Tests"
  Include ../scripts/reload-parameter.sh

  redis_cli_log="./reload-parameter-redis-cli.log"
  redis_cli_args_log="./reload-parameter-redis-cli-args.log"

  init() {
    ut_mode="true"
    export REDIS_CLI_LOG="$redis_cli_log"
    export REDIS_CLI_ARGS_LOG="$redis_cli_args_log"
  }
  BeforeAll "init"

  cleanup() {
    rm -f "$redis_cli_log" "$redis_cli_args_log"
  }
  AfterAll 'cleanup'

  setup() {
    : > "$redis_cli_log"
    : > "$redis_cli_args_log"
    export MOCK_SET_REPLY="OK"
    export MOCK_GET_REPLY="parameter\nvalue"
    unset REDIS_DEFAULT_PASSWORD
    unset REDIS_CLI_TLS_CMD
  }
  Before 'setup'

  # redis-cli reads the command from stdin, the mock records what it received
  # and replies with the canned reply configured by each example.
  Mock redis-cli
    printf 'args:%s\n' "$*" >> "$REDIS_CLI_ARGS_LOG"
    printf 'auth:%s\n' "${REDISCLI_AUTH:-}" >> "$REDIS_CLI_LOG"
    mock_command_line=$(cat)
    printf '%s\n' "$mock_command_line" >> "$REDIS_CLI_LOG"
    case "$mock_command_line" in
      "CONFIG SET"*) printf '%b\n' "$MOCK_SET_REPLY" ;;
      "CONFIG GET"*) printf '%b\n' "$MOCK_GET_REPLY" ;;
    esac
  End

  Describe "reload_redis_parameter()"
    It "sends a multi token value as a single quoted argument"
      When call reload_redis_parameter "falkordbe.ldap_default_acl_rules" "on resetpass"
      The status should be success
      The stdout should include "Parameter falkordbe.ldap_default_acl_rules applied successfully"
      The contents of file "$redis_cli_log" should include 'CONFIG SET falkordbe.ldap_default_acl_rules "on resetpass"'
    End

    It "keeps the subkey with the value when the name carries a subkey"
      When call reload_redis_parameter "client-output-buffer-limit normal" "0 0 0"
      The status should be success
      The stdout should include "applied successfully"
      The contents of file "$redis_cli_log" should include 'CONFIG SET client-output-buffer-limit "normal 0 0 0"'
    End

    It "does not append a trailing space when the subkey carries the whole value"
      When call reload_redis_parameter "client-output-buffer-limit normal" ""
      The status should be success
      The stdout should include "applied successfully"
      The contents of file "$redis_cli_log" should include 'CONFIG SET client-output-buffer-limit "normal"'
    End

    It "translates the empty string marker into an empty value"
      When call reload_redis_parameter "falkordbe.ldap_servers" '""'
      The status should be success
      The stdout should include "applied successfully"
      The contents of file "$redis_cli_log" should include 'CONFIG SET falkordbe.ldap_servers ""'
    End

    It "escapes quotes and backslashes in the value"
      When call reload_redis_parameter "falkordbe.ldap_search_filter" '(cn="a\b")'
      The status should be success
      The stdout should include "applied successfully"
      The contents of file "$redis_cli_log" should include 'CONFIG SET falkordbe.ldap_search_filter "(cn=\"a\\b\")"'
    End

    It "fails when the server rejects the value"
      export MOCK_SET_REPLY="ERR CONFIG SET failed - argument couldn't be parsed into an integer"
      When call reload_redis_parameter "falkordbe.ldap_timeout_connection" "not-a-number"
      The status should be failure
      The stderr should include "Error: failed to set parameter falkordbe.ldap_timeout_connection"
      The stderr should include "argument couldn't be parsed into an integer"
      The stdout should equal ""
    End

    It "fails when the server replies with an unknown parameter error"
      export MOCK_SET_REPLY="ERR Unknown option or number of arguments for CONFIG SET - 'falkordbe.typo'"
      When call reload_redis_parameter "falkordbe.typo" "1"
      The status should be failure
      The stderr should include "Error: failed to set parameter falkordbe.typo"
      The stdout should equal ""
    End

    It "fails when the parameter cannot be read back"
      export MOCK_GET_REPLY=""
      When call reload_redis_parameter "falkordbe.ldap_servers" "ldap://ldap.example.com"
      The status should be failure
      The stderr should include "Error: parameter falkordbe.ldap_servers is unknown to the server"
      The stdout should equal ""
    End

    It "fails when the server does not reply at all"
      export MOCK_SET_REPLY=""
      When call reload_redis_parameter "maxmemory" "100mb"
      The status should be failure
      The stderr should include "no reply from server"
      The stdout should equal ""
    End

    It "does not expose the password or the value in the process arguments"
      export REDIS_DEFAULT_PASSWORD="s3cret-password"
      When call reload_redis_parameter "falkordbe.ldap_search_bind_passwd" "bind-secret"
      The status should be success
      The stdout should include "applied successfully"
      The contents of file "$redis_cli_log" should include "auth:s3cret-password"
      The contents of file "$redis_cli_args_log" should not include "s3cret-password"
      The contents of file "$redis_cli_args_log" should not include "bind-secret"
      The contents of file "$redis_cli_args_log" should not include "-a"
    End

    It "does not set REDISCLI_AUTH when no password is configured"
      When call reload_redis_parameter "maxmemory" "100mb"
      The status should be success
      The stdout should include "applied successfully"
      The contents of file "$redis_cli_log" should include "auth:"
      The contents of file "$redis_cli_log" should not include "auth:s3cret"
    End
  End

  Describe "reload_parameters_from_environment()"
    # A name such as 'falkordbe.ldap_servers' is not a valid shell identifier,
    # so `export` cannot create it. The kernel accepts it when kubelet builds
    # the container environment, which is exactly how KubeBlocks delivers the
    # parameter, so `env` is mocked to reproduce that environment here.
    Mock env
      printf '%s\n' "$MOCK_ENV"
    End

    It "applies a module config whose name carries a dot and underscores"
      export MOCK_ENV="falkordbe.ldap_servers=ldap://ldap.example.com"
      When call reload_parameters_from_environment
      The status should be success
      The stdout should include "Parameter falkordbe.ldap_servers applied successfully"
      The contents of file "$redis_cli_log" should include 'CONFIG SET falkordbe.ldap_servers "ldap://ldap.example.com"'
    End

    It "ignores KubeBlocks and container runtime variables"
      export MOCK_ENV="KB_POD_NAME=falkordb-0"
      When call reload_parameters_from_environment
      The status should be failure
      The stderr should include "reconfigure was invoked without any parameter to apply"
      The contents of file "$redis_cli_log" should not include "CONFIG SET"
    End
  End
End

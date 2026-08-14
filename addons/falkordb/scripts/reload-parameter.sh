#!/bin/bash

# shellcheck disable=SC2034
ut_mode="false"
test || __() {
  set -e;
}

service_port=${SERVICE_PORT:-6379}

# Quote a value the way redis-cli parses arguments read from stdin, so that
# multi token values (e.g. 'on resetpass') are sent as a single argument.
quote_redis_value() {
  local escaped
  escaped=$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
  printf '"%s"' "$escaped"
}

# Run a redis command, keeping secrets out of the process arguments: the
# command (and therefore its values, e.g. LDAP bind passwords) is fed through
# stdin and the password is passed via the REDISCLI_AUTH env var.
run_redis_command() {
  local command="$1"
  if [ -z "${REDIS_DEFAULT_PASSWORD:-}" ]; then
    # shellcheck disable=SC2086
    printf '%s\n' "$command" | redis-cli $REDIS_CLI_TLS_CMD -p "$service_port" 2>&1
  else
    # shellcheck disable=SC2086
    printf '%s\n' "$command" | REDISCLI_AUTH="${REDIS_DEFAULT_PASSWORD}" redis-cli $REDIS_CLI_TLS_CMD -p "$service_port" 2>&1
  fi
}

# redis-cli exits 0 even when the server replies with an error, so the reply
# itself has to be inspected.
last_reply_line() {
  printf '%s' "$1" | tr -d '\r' | grep -v '^[[:space:]]*$' | tail -n 1
}

apply_redis_parameter() {
  local paramName="$1"
  local paramValue="$2"
  local output=""
  local reply=""

  output=$(run_redis_command "CONFIG SET ${paramName} $(quote_redis_value "${paramValue}")") || true
  reply=$(last_reply_line "$output")
  if [ "$reply" != "OK" ]; then
    echo "Error: failed to set parameter ${paramName}: ${reply:-no reply from server}" >&2
    return 1
  fi

  output=$(run_redis_command "CONFIG GET ${paramName}") || true
  if [ -z "$(last_reply_line "$output")" ]; then
    echo "Error: parameter ${paramName} is unknown to the server, it was not applied" >&2
    return 1
  fi

  echo "Parameter ${paramName} applied successfully"
}

reload_redis_parameter() {
  set -e
  local paramName=""
  local paramValue=""
  # shellcheck disable=SC2086
  for val in $(echo "${1}" | tr ' ' '\n'); do
    if [ -z "${paramName}" ]; then
      paramName="${val}"
    elif [ -z "${paramValue}" ]; then
      paramValue="${val}"
    else
      paramValue="${paramValue} ${val}"
    fi
  done

  # The separator is only added when both halves are non empty, otherwise the
  # value picks up a trailing space that is now sent to the server verbatim,
  # because apply_redis_parameter quotes it.
  if [ -z "${paramValue}" ]; then
    paramValue="${*:2}"
  elif [ -n "${*:2}" ]; then
    paramValue="${paramValue} ${*:2}"
  fi

  if [ "$paramValue" = "\"\"" ]; then
    paramValue=""
  fi

  apply_redis_parameter "${paramName}" "${paramValue}"
}

# KubeBlocks hands the changed parameters to this action through one of two
# channels, depending on the version of the operator that is running:
#
#   * as positional arguments, which is what the reconfigureArgs field on the
#     InstanceSet CRD produces, and
#   * as environment variables named after the parameter, which is the only
#     channel available on 1.2.0-alpha.1, where the CRD has no reconfigureArgs
#     field at all and the agent merges the parameter map into the environment
#     of the exec'd command. reconfigureArgs appears in 1.2.0-alpha.2.
#
# Names such as 'maxmemory-policy' are not valid shell identifiers, so the
# environment has to be walked with `env` rather than read by expansion. Only
# all lowercase names are considered, which is what every redis directive looks
# like and what no KubeBlocks or container runtime variable looks like, and each
# candidate is confirmed to be a real directive before anything is applied, so
# an unrelated variable can never reach CONFIG SET.
#
# Dots and underscores are part of the accepted alphabet because module configs
# are namespaced by the module that registers them, e.g. the enterprise module's
# 'falkordbe.ldap_servers'. Rejecting them here skipped every enterprise
# parameter and, when a change touched nothing else, failed the whole action
# with "reconfigure was invoked without any parameter to apply".
reload_parameters_from_environment() {
  set -e
  local applied=0
  local entry name value output

  while IFS= read -r entry; do
    name="${entry%%=*}"
    value="${entry#*=}"

    case "$name" in
      "" | [-._]* | *[!a-z0-9._-]*) continue ;;
    esac

    output=$(run_redis_command "CONFIG GET ${name}") || true
    if [ -z "$(last_reply_line "$output")" ]; then
      continue
    fi

    apply_redis_parameter "${name}" "${value}"
    applied=$((applied + 1))
  done < <(env)

  if [ "$applied" -eq 0 ]; then
    echo "ERROR: reconfigure was invoked without any parameter to apply" >&2
    return 1
  fi
}

# This is magic for shellspec ut framework.
${__SOURCED__:+false} : || return 0

if [ $# -ge 2 ]; then
  reload_redis_parameter "$@"
else
  reload_parameters_from_environment
fi

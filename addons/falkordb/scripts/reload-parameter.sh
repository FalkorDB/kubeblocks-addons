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

# This is magic for shellspec ut framework.
${__SOURCED__:+false} : || return 0

reload_redis_parameter "$@"

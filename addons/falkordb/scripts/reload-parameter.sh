#!/bin/sh
set -e

paramName=""
paramValue=""
_first_arg="${1:-}"
shift 1 2>/dev/null || true
for val in $(printf '%s\n' "$_first_arg" | tr ' ' '\n'); do
  if [ -z "${paramName}" ]; then
    paramName="${val}"
  elif [ -z "${paramValue}" ]; then
    paramValue="${val}"
  else
    paramValue="${paramValue} ${val}"
  fi
done

if [ -z "${paramValue}" ]; then
  paramValue="$*"
else
  if [ $# -gt 0 ]; then
    paramValue="${paramValue} $*"
  fi
fi
if [ "$paramValue" = "\"\"" ]; then
  paramValue=""
fi
service_port=${SERVICE_PORT:-6379}
if [ -z $REDIS_DEFAULT_PASSWORD ]; then
  redis-cli $REDIS_CLI_TLS_CMD -p $service_port CONFIG SET ${paramName} "${paramValue}"
else
  redis-cli $REDIS_CLI_TLS_CMD -p $service_port -a ${REDIS_DEFAULT_PASSWORD} CONFIG SET ${paramName} "${paramValue}"
fi

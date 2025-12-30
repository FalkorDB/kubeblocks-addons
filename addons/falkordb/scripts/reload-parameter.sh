#!/bin/bash
set -e

# Helper: add --tls if TLS_ENABLED is true
redis_cli_tls_flag() {
  if [ "${TLS_ENABLED}" = "true" ]; then
    echo "--tls"
  fi
}

paramName=""
paramValue=""
for val in $(echo "${1}" | tr ' ' '\n'); do
  if [ -z "${paramName}" ]; then
    paramName="${val}"
  elif [ -z "${paramValue}" ]; then
    paramValue="${val}"
  else
    paramValue="${paramValue} ${val}"
  fi
done

if  [ -z "${paramValue}" ]; then
  paramValue="${@:2}"
else
  paramValue="${paramValue} ${@:2}"
fi
redis-cli $(redis_cli_tls_flag) -a ${REDIS_DEFAULT_PASSWORD} CONFIG SET ${paramName} "${paramValue}"
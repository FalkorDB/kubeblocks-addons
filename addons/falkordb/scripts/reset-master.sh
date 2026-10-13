#!/bin/bash

# Runs `SENTINEL RESET` on every sentinel so they forget replicas that no
# longer exist, e.g. after the data component was scaled down.
#
# Every sentinel keeps its own replica list, so resetting just one of them
# leaves the others still trying to reach the removed pods. All of them are
# reset, and the action fails if any of them could not be.

# shellcheck disable=SC2034
ut_mode="false"
test || __() {
  set -e;
}

sentinel_service_port=${SENTINEL_SERVICE_PORT:-26379}

# The data component registers itself under CUSTOM_SENTINEL_MASTER_NAME when it
# is set (see falkordb-register-to-sentinel.sh), so the reset has to use the
# same name or it silently matches nothing.
sentinel_master_name() {
  if [ -n "${CUSTOM_SENTINEL_MASTER_NAME}" ]; then
    echo "${CUSTOM_SENTINEL_MASTER_NAME}"
  else
    echo "${REDIS_COMPONENT_NAME}"
  fi
}

reset_master_in_sentinels() {
  if [ -z "${SENTINEL_POD_NAME_LIST}" ]; then
    exit 0
  fi
  local master_name
  master_name=$(sentinel_master_name)
  local failed=0
  local sentinel_pod fqdn output
  # shellcheck disable=SC2086
  for sentinel_pod in $(echo ${SENTINEL_POD_NAME_LIST} | tr ',' '\n'); do
    echo "reset master ${master_name} in sentinel ${sentinel_pod}..."
    fqdn="$sentinel_pod.$SENTINEL_HEADLESS_SERVICE_NAME.$CLUSTER_NAMESPACE.svc.cluster.local"
    # The password goes through REDISCLI_AUTH so it stays out of the process
    # arguments. SENTINEL RESET replies with the number of masters it reset, so
    # 0 means this sentinel does not monitor the master under that name.
    # shellcheck disable=SC2086
    if output=$(REDISCLI_AUTH="${SENTINEL_PASSWORD}" redis-cli $REDIS_CLI_TLS_CMD -h "$fqdn" -p "$sentinel_service_port" sentinel reset "${master_name}") \
      && [[ "$output" =~ ^[0-9]+$ ]] && [ "$output" -gt 0 ]; then
      echo "reset master in sentinel ${sentinel_pod} succeeded"
    else
      echo "reset master in sentinel ${sentinel_pod} failed: ${output:-no reply}"
      failed=1
    fi
  done
  if [ "$failed" -ne 0 ]; then
    echo "reset master failed on at least one sentinel"
    exit 1
  fi
}

# This is magic for shellspec ut framework.
${__SOURCED__:+false} : || return 0

reset_master_in_sentinels

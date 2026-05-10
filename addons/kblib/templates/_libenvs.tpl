{{/*
Library of envs related functions implemented in Bash. Currently, the following functions are available:
- env_exist: Check if a single environment variable exists in the system's environment variables.
- env_exists: Check if multiple environment variables exist in the system's environment variables.
*/}}

{{/*
This function is used to check if a single environment variable exists in the system's environment variables.

Usage:
    env_exist "ENV_NAME"
Result:
    true if the provided environment variable exists in the system's environment variables, false otherwise
Example:
    if env_exist "ENV1"; then
      echo "ENV1 exists"
    else
      echo "ENV1 does not exist"
    fi
*/}}
{{- define "kblib.envs.env_exist" }}
env_exist() {
  local env_name="$1"
  local env_value=""
  eval "env_value=\${$env_name-}"
  if [ -z "$env_value" ]; then
    echo "false, $env_name does not exist"
    return 1
  fi

  return 0
}
{{- end }}

{{/*
This function is used to check if multiple environment variables exist in the system's environment variables.

Usage:
    env_exists "ENV1" "ENV2" "ENV3"
Result:
    true if all the provided environment variables exist in the system's environment variables, false otherwise
Example:
    if env_exists "ENV1" "ENV2" "ENV3"; then
      echo "All environment variables exist"
    else
      echo "Some environment variables do not exist"
    fi
*/}}
{{- define "kblib.envs.env_exists" }}
env_exists() {
  local missing_envs=""
  local env_value=""
  for env in "$@"; do
    eval "env_value=\${$env-}"
    if [ -z "$env_value" ]; then
      if [ -z "$missing_envs" ]; then
        missing_envs="$env"
      else
        missing_envs="$missing_envs $env"
      fi
    fi
  done

  if [ -z "$missing_envs" ]; then
    return 0
  else
    echo "false, the following environment variables do not exist: $missing_envs"
    return 1
  fi
}
{{- end }}
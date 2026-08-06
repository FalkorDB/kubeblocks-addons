# shellcheck shell=sh

Describe "FalkorDB lifecycle script reference contract"
  repo_root() {
    printf "%s" "${SHELLSPEC_CWD:?}"
  }

  chart_path() {
    printf "%s/addons/falkordb" "$(repo_root)"
  }

  helm_not_available() { ! command -v helm >/dev/null 2>&1; }
  Skip if "helm not available" helm_not_available

  # Every "/scripts/<name>.sh" path used by a lifecycle action, exec probe or
  # command must resolve to a key of the rendered scripts ConfigMaps. The keys
  # are the basenames of the globbed script files, so renaming or moving a
  # script silently breaks the reference unless it is checked here.
  missing_script_references() {
    tmp_render=$(mktemp -t falkordb-scripts-render-XXXXXX)
    tmp_keys=$(mktemp -t falkordb-scripts-keys-XXXXXX)
    helm template test "$(chart_path)" >"$tmp_render" || return $?

    sed -n 's/^  \([A-Za-z0-9_.-]*\.sh\): .*$/\1/p' "$tmp_render" | sort -u >"$tmp_keys"

    grep -oE '/scripts/[A-Za-z0-9_.-]+\.sh' "$tmp_render" | sed 's|^/scripts/||' | sort -u |
      while IFS= read -r script_name; do
        if ! grep -qx "$script_name" "$tmp_keys"; then
          echo "$script_name"
        fi
      done
  }

  cleanup_render() {
    [ -n "${tmp_render:-}" ] && rm -f "$tmp_render" 2>/dev/null
    [ -n "${tmp_keys:-}" ] && rm -f "$tmp_keys" 2>/dev/null
    true
  }
  AfterEach 'cleanup_render'

  It "resolves every referenced /scripts/*.sh path to a scripts ConfigMap key"
    When call missing_script_references
    The status should be success
    The output should equal ""
  End
End

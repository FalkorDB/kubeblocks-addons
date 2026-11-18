# shellcheck shell=sh

# Var references between components must keep resolving while an addon upgrade
# has the components on different ComponentDefinitions, e.g. the data component
# on falkordb-4-<new> and its sentinel still on falkordb-sent-4-<old>.
# KubeBlocks matches a var reference's compDef by name prefix or regular
# expression; a reference pinned to "<definition>-<chart version>" matches
# nothing in that window and, being optional, resolves to an empty value (an
# empty SENTINEL_PASSWORD made replicas crash-loop on NOAUTH, see issue #56).
Describe "FalkorDB ComponentDefinition var reference contract"
  repo_root() {
    printf "%s" "${SHELLSPEC_CWD:?}"
  }

  chart_path() {
    printf "%s/addons/falkordb" "$(repo_root)"
  }

  helm_not_available() { ! command -v helm >/dev/null 2>&1; }
  Skip if "helm not available" helm_not_available

  render_chart() {
    tmp_render=$(mktemp -t falkordb-cmpd-render-XXXXXX)
    helm template test "$(chart_path)" >"$tmp_render"
  }

  chart_version() {
    sed -n 's/^version: *//p' "$(chart_path)/Chart.yaml" | tr -d '"' | head -n 1
  }

  # compDef values of the var references inside the rendered
  # ComponentDefinitions, one per line
  cmpd_var_ref_comp_defs() {
    render_chart || return $?
    awk '
      /^kind: /     { in_cmpd = ($2 == "ComponentDefinition") }
      in_cmpd && /^ +compDef: / { sub(/^ +compDef: */, ""); print }
    ' "$tmp_render"
  }

  # names of the rendered ComponentDefinitions, one per line
  cmpd_names() {
    render_chart || return $?
    awk '
      /^kind: /   { in_cmpd = ($2 == "ComponentDefinition"); next }
      in_cmpd && /^  name: / { print $2; in_cmpd = 0 }
    ' "$tmp_render"
  }

  # the var references pinned to an addon version (any "-X.Y.Z" in the
  # name, not just the current chart version), if any
  version_pinned_refs() {
    cmpd_var_ref_comp_defs | grep -E -- '-[0-9]+\.[0-9]+\.[0-9]+' || true
  }

  # references to the given kind of component: "sentinel" or "shard"
  refs_to() {
    case "$1" in
      sentinel) cmpd_var_ref_comp_defs | grep -F -- "falkordb-sent-" ;;
      shard) cmpd_var_ref_comp_defs | grep -F -- "falkordb-cluster-" ;;
    esac | sort -u
  }

  # succeeds when KubeBlocks would match ComponentDefinition <name> against a
  # var reference's compDef <ref>: by name prefix, or as a regular expression
  kb_matches() {
    case "$1" in
      "$2"*) return 0 ;;
    esac
    printf '%s\n' "$1" | grep -Eq -- "$2"
  }

  # the <kind> references, exact names and prefixes included, that do not
  # match ComponentDefinition <name>
  refs_not_matching() {
    name="$1"
    refs_to "$2" | while IFS= read -r ref; do
      kb_matches "$name" "$ref" || echo "$ref"
    done
  }

  # the <kind> references that do match ComponentDefinition <name>
  refs_matching() {
    name="$1"
    refs_to "$2" | while IFS= read -r ref; do
      if kb_matches "$name" "$ref"; then echo "$ref"; fi
    done
  }

  cleanup_render() {
    [ -n "${tmp_render:-}" ] && rm -f "$tmp_render" 2>/dev/null
    true
  }
  AfterEach 'cleanup_render'

  It "renders var references in the ComponentDefinitions"
    When call cmpd_var_ref_comp_defs
    The status should be success
    The output should include "^falkordb-sent-4-"
    The output should include "^falkordb-cluster-4-"
  End

  It "pins no var reference to an addon version"
    When call version_pinned_refs
    The status should be success
    The output should equal ""
  End

  It "renders the definitions the references point at under the chart version"
    When call cmpd_names
    The status should be success
    The output should include "falkordb-sent-4-$(chart_version)"
    The output should include "falkordb-cluster-4-$(chart_version)"
  End

  Describe "across addon versions"
    Parameters
      "sentinel" "falkordb-sent-4-0.0.1"
      "sentinel" "falkordb-sent-4-99.0.0"
      "shard" "falkordb-cluster-4-0.0.1"
      "shard" "falkordb-cluster-4-99.0.0"
    End

    It "resolves every $1 reference against a $1 definition of another addon version ($2)"
      When call refs_not_matching "$2" "$1"
      The status should be success
      The output should equal ""
    End
  End

  Describe "across major versions"
    Parameters
      "sentinel" "falkordb-sent-5-1.0.0"
      "shard" "falkordb-cluster-5-1.0.0"
    End

    It "does not let any $1 reference match another major version ($2)"
      When call refs_matching "$2" "$1"
      The status should be success
      The output should equal ""
    End
  End
End

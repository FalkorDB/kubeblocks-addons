#!/usr/bin/env python3
"""Register a released FalkorDB image as a supported version of the falkordb addon.

Updates every file that has to know about a supported version:

  addons/falkordb/values.yaml            mirrorVersions, and optionally serviceVersion/defaultImageTag
  addons/falkordb/Chart.yaml             chart version and appVersion
  addons/falkordb/README.md              the supported-versions table and the "Valid options" hints
  addons-cluster/falkordb/values.yaml    default cluster version
  addons-cluster/falkordb/values.schema.json  default cluster version
  addons-cluster/falkordb/Chart.yaml     appVersion
  examples/falkordb/*.yaml               serviceVersion pinned in the examples
  examples/falkordb/README.md            the supported-versions table and the "Valid options" hints

Comments and formatting are preserved throughout.

Outputs `key=value` lines to $GITHUB_OUTPUT when running inside GitHub Actions.
"""

import argparse
import os
import re
import sys
from pathlib import Path

from ruamel.yaml import YAML
from ruamel.yaml.scalarstring import DoubleQuotedScalarString as DQ

REPO_ROOT = Path(__file__).resolve().parent.parent
ADDON_DIR = REPO_ROOT / "addons" / "falkordb"
CLUSTER_DIR = REPO_ROOT / "addons-cluster" / "falkordb"
EXAMPLES_DIR = REPO_ROOT / "examples" / "falkordb"

VALUES_FILE = ADDON_DIR / "values.yaml"
CHART_FILE = ADDON_DIR / "Chart.yaml"
ADDON_README = ADDON_DIR / "README.md"
CLUSTER_VALUES_FILE = CLUSTER_DIR / "values.yaml"
CLUSTER_SCHEMA_FILE = CLUSTER_DIR / "values.schema.json"
CLUSTER_CHART_FILE = CLUSTER_DIR / "Chart.yaml"

SEMVER_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")


def parse_version(version):
    match = SEMVER_RE.match(version)
    if not match:
        raise ValueError(f"invalid version '{version}', expected MAJOR.MINOR.PATCH")
    return tuple(int(part) for part in match.groups())


def set_output(**kwargs):
    output_file = os.environ.get("GITHUB_OUTPUT")
    for key, value in kwargs.items():
        line = f"{key}={value}"
        print(line)
        if output_file:
            with open(output_file, "a", encoding="utf-8") as handle:
                handle.write(line + "\n")


def bump_patch(version):
    major, minor, patch = parse_version(version)
    return f"{major}.{minor}.{patch + 1}"


def rewrite(path, replacer):
    """Apply replacer to the file's text, writing it back only if it changed."""
    if not path.exists():
        return False
    original = path.read_text(encoding="utf-8")
    updated = replacer(original)
    if updated == original:
        return False
    path.write_text(updated, encoding="utf-8")
    return True


def supported_versions(entry):
    """The versions of one major, newest first, as the docs list them."""
    versions = [str(item["version"]) for item in entry.get("mirrorVersions") or []]
    return sorted(set(versions), key=parse_version, reverse=True)


def refresh_version_lists(path, major, versions):
    """Update the docs that enumerate the supported versions of a major.

    Two shapes carry the list: the `| 4.0 | a, b, c |` row of the Versions
    table, and the `# Valid options are: [a, b, c]` hint above serviceVersion.
    """
    joined = ", ".join(versions)
    table_row = re.compile(rf"^(\|\s*{re.escape(major)}\.0\s*\|).*?(\|\s*)$", re.MULTILINE)
    options = re.compile(r"^(\s*#\s*Valid options are: )\[[^\]]*\](\s*)$", re.MULTILINE)

    def replacer(text):
        text = table_row.sub(rf"\g<1> {joined} \g<2>", text)
        return options.sub(rf"\g<1>[{joined}]\g<2>", text)

    return rewrite(path, replacer)


def retarget_service_version(path, old, new):
    """Repoint a pinned serviceVersion, quoted or bare, at the new default."""
    pattern = re.compile(rf'^(\s*serviceVersion:\s*)"?{re.escape(old)}"?(\s*)$', re.MULTILINE)

    def replacer(text):
        return pattern.sub(lambda m: f'{m.group(1)}"{new}"{m.group(2)}', text)

    return rewrite(path, replacer)


def update_cluster_chart_files(version):
    """Point the falkordb-cluster chart at the new default version.

    Its own chart version is a pre-release string managed by the release
    tooling, so only appVersion and the user-facing defaults move here.
    """
    changed = rewrite(
        CLUSTER_VALUES_FILE,
        lambda text: re.sub(r"^version:\s*\S+\s*$", f"version: {version}\n", text, flags=re.MULTILINE),
    )
    changed |= rewrite(
        CLUSTER_CHART_FILE,
        lambda text: re.sub(r'^appVersion:\s*\S+\s*$', f'appVersion: "{version}"\n', text, flags=re.MULTILINE),
    )
    # Editing the JSON as text keeps the hand-maintained formatting intact; a
    # json round-trip reflows the whole schema.
    changed |= rewrite(
        CLUSTER_SCHEMA_FILE,
        lambda text: re.sub(
            r'("version"\s*:\s*\{[^}]*?"default"\s*:\s*)"[^"]*"',
            lambda m: f'{m.group(1)}"{version}"',
            text,
        ),
    )
    return changed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True, help="released FalkorDB version, e.g. 4.20.2")
    parser.add_argument("--image-tag", help="image tag of the release (default: v<version>)")
    parser.add_argument("--repository", help="override the image repository for this version")
    parser.add_argument(
        "--set-default",
        action="store_true",
        help="make this the default serviceVersion for its major when it is the highest known version",
    )
    parser.add_argument(
        "--bump-chart",
        action="store_true",
        help="bump the chart patch version in Chart.yaml",
    )
    args = parser.parse_args()

    version = args.version.lstrip("v").strip()
    parse_version(version)
    image_tag = args.image_tag or f"v{version}"
    major = version.split(".")[0]

    yaml = YAML()
    yaml.preserve_quotes = True
    yaml.width = 4096
    yaml.indent(mapping=2, sequence=4, offset=2)

    values = yaml.load(VALUES_FILE)
    entries = values.get("falkordbVersions") or []
    entry = next((item for item in entries if str(item.get("major")) == major), None)
    if entry is None:
        print(
            f"error: no falkordbVersions entry for major version '{major}'. "
            "A new major version requires new component definitions and must be added manually.",
            file=sys.stderr,
        )
        return 1

    mirror_versions = entry.setdefault("mirrorVersions", [])
    if any(str(item.get("version")) == version for item in mirror_versions):
        print(f"version {version} is already supported, nothing to do")
        set_output(changed="false", version=version)
        return 0

    new_mirror = {"version": DQ(version), "imageTag": DQ(image_tag)}
    if args.repository:
        new_mirror["repository"] = DQ(args.repository)
    mirror_versions.insert(0, new_mirror)

    is_new_default = False
    previous_default = str(entry.get("serviceVersion", "0.0.0"))
    if args.set_default:
        if parse_version(version) > parse_version(previous_default):
            entry["serviceVersion"] = DQ(version)
            entry["defaultImageTag"] = DQ(image_tag)
            is_new_default = True

    yaml.dump(values, VALUES_FILE)

    chart = yaml.load(CHART_FILE)
    chart_version = str(chart["version"])
    if args.bump_chart:
        chart_version = bump_patch(chart_version)
        chart["version"] = chart_version
    # appVersion tracks the default version of the first (newest) major
    if is_new_default and entries and entries[0] is entry:
        chart["appVersion"] = DQ(version)
    yaml.dump(chart, CHART_FILE)

    versions = supported_versions(entry)
    refresh_version_lists(ADDON_README, major, versions)
    refresh_version_lists(EXAMPLES_DIR / "README.md", major, versions)

    # The examples and the cluster chart advertise one concrete version, so they
    # only move when the new release actually becomes the default.
    if is_new_default:
        update_cluster_chart_files(version)
        for example in sorted(EXAMPLES_DIR.glob("*.yaml")):
            retarget_service_version(example, previous_default, version)
        retarget_service_version(EXAMPLES_DIR / "README.md", previous_default, version)

    print(f"added FalkorDB {version} ({image_tag}) to the supported versions")
    set_output(
        changed="true",
        version=version,
        image_tag=image_tag,
        chart_version=chart_version,
        is_default=str(is_new_default).lower(),
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Register a released FalkorDB image as a supported version of the falkordb addon.

Updates addons/falkordb/values.yaml (mirrorVersions, and optionally the default
serviceVersion/defaultImageTag) and addons/falkordb/Chart.yaml (chart version and
appVersion), preserving comments and formatting.

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
VALUES_FILE = REPO_ROOT / "addons" / "falkordb" / "values.yaml"
CHART_FILE = REPO_ROOT / "addons" / "falkordb" / "Chart.yaml"

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
    if args.set_default:
        current_default = str(entry.get("serviceVersion", "0.0.0"))
        if parse_version(version) > parse_version(current_default):
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

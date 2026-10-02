#!/usr/bin/env python3
"""Verify the narrow iOS privacy and background-capability baseline from Info.plist."""

from __future__ import annotations

import argparse
import plistlib
import re
import sys
from pathlib import Path
from typing import Any
from xml.parsers.expat import ExpatError

FORBIDDEN_KEYS = {
    "NSCameraUsageDescription",
    "NSPhotoLibraryUsageDescription",
    "NSPhotoLibraryAddUsageDescription",
    "NSLocationWhenInUseUsageDescription",
    "NSLocationAlwaysUsageDescription",
    "NSLocationAlwaysAndWhenInUseUsageDescription",
    "NSLocationTemporaryUsageDescriptionDictionary",
    "NSFaceIDUsageDescription",
    "NSUserTrackingUsageDescription",
    "UIBackgroundModes",
    "NSAppTransportSecurity",
    "NSBonjourServices",
}


def _is_forbidden_key(key: Any) -> bool:
    """Reject all permission-purpose strings, not only today's known APIs."""
    return isinstance(key, str) and (
        key in FORBIDDEN_KEYS or key.endswith("UsageDescription")
    )


class BaselineError(ValueError):
    """Raised when an Info.plist does not match the reviewed baseline."""


def _find_forbidden_keys(value: Any, path: str = "") -> list[str]:
    """Find forbidden activation keys anywhere in nested plist dictionaries."""
    found: list[str] = []
    if isinstance(value, dict):
        for key, child in value.items():
            key_path = f"{path}.{key}" if path else str(key)
            if _is_forbidden_key(key):
                found.append(key_path)
            found.extend(_find_forbidden_keys(child, key_path))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            found.extend(_find_forbidden_keys(child, f"{path}[{index}]"))
    return found


def _xcode_object_body(project: str, object_id: str) -> str:
    """Extract one top-level Xcode project object, failing on missing/duplicate IDs."""
    declaration = re.compile(
        rf"(?m)^\t\t{re.escape(object_id)} /\* [^*\n]+ \*/ = \{{\n"
    )
    matches = list(declaration.finditer(project))
    if len(matches) != 1:
        raise BaselineError(
            f"Xcode project object {object_id!r} must occur exactly once"
        )
    start = matches[0].end()
    end = project.find("\n\t\t};", start)
    if end < 0:
        raise BaselineError(f"Xcode project object {object_id!r} is unterminated")
    return project[start:end]


def resolve_runner_bundle_id(project_path: Path) -> str:
    """Resolve Runner's consistent PRODUCT_BUNDLE_IDENTIFIER across its configs."""
    try:
        project = project_path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise BaselineError(f"cannot read Xcode project: {error}") from error

    runner_objects = re.findall(
        r"(?m)^\t\t([A-F0-9]+) /\* Runner \*/ = \{\n", project
    )
    runner_targets = []
    for object_id in runner_objects:
        body = _xcode_object_body(project, object_id)
        if re.search(r"(?m)^\t\t\tisa = PBXNativeTarget;$", body):
            runner_targets.append((object_id, body))
    if len(runner_targets) != 1:
        raise BaselineError("Xcode project must contain exactly one Runner native target")
    _, target = runner_targets[0]

    config_lists = re.findall(
        r"(?m)^\t\t\tbuildConfigurationList = ([A-F0-9]+) /\*[^\n]*\*/;",
        target,
    )
    if len(config_lists) != 1:
        raise BaselineError("Runner target must reference exactly one build configuration list")
    config_list = _xcode_object_body(project, config_lists[0])
    if not re.search(r"(?m)^\t\t\tisa = XCConfigurationList;$", config_list):
        raise BaselineError("Runner configuration list has an unexpected object type")
    config_groups = re.findall(
        r"(?s)buildConfigurations = \((.*?)\);", config_list
    )
    if len(config_groups) != 1:
        raise BaselineError("Runner configuration list must contain one configuration array")
    config_ids = re.findall(r"([A-F0-9]+) /\* [^*\n]+ \*/", config_groups[0])
    if not config_ids or len(config_ids) != len(set(config_ids)):
        raise BaselineError("Runner configuration list is empty or ambiguous")

    bundle_ids: list[str] = []
    for config_id in config_ids:
        config = _xcode_object_body(project, config_id)
        if not re.search(r"(?m)^\t\t\tisa = XCBuildConfiguration;$", config):
            raise BaselineError(f"Runner configuration {config_id!r} has an unexpected type")
        settings_groups = re.findall(r"(?s)buildSettings = \{(.*?)\};", config)
        if len(settings_groups) != 1:
            raise BaselineError(f"Runner configuration {config_id!r} has ambiguous build settings")
        values = re.findall(
            r"(?m)^\s*PRODUCT_BUNDLE_IDENTIFIER\s*=\s*([^;]+);",
            settings_groups[0],
        )
        if len(values) != 1:
            raise BaselineError(
                f"Runner configuration {config_id!r} must define one bundle identifier"
            )
        bundle_id = values[0].strip().strip('"')
        if not bundle_id or "$(" in bundle_id:
            raise BaselineError(
                f"Runner configuration {config_id!r} has no concrete bundle identifier"
            )
        bundle_ids.append(bundle_id)

    if len(set(bundle_ids)) != 1:
        raise BaselineError(
            f"Runner configurations disagree on bundle identifier: {sorted(set(bundle_ids))}"
        )
    return bundle_ids[0]


def verify_plist(
    path: Path,
    expected_bundle_id: str | None = None,
    expected_minimum_os_version: str | None = None,
) -> str | None:
    """Verify an XML or binary plist and return its minimum OS version."""
    if not path.is_file():
        raise BaselineError(f"plist does not exist or is not a file: {path}")
    try:
        with path.open("rb") as plist_file:
            info = plistlib.load(plist_file)
    except (
        OSError,
        plistlib.InvalidFileException,
        ValueError,
        TypeError,
        ExpatError,
    ) as error:
        raise BaselineError(f"cannot parse plist: {error}") from error

    if not isinstance(info, dict):
        raise BaselineError("plist root must be a dictionary")

    if expected_bundle_id is not None:
        actual_bundle_id = info.get("CFBundleIdentifier")
        if actual_bundle_id != expected_bundle_id:
            raise BaselineError(
                "CFBundleIdentifier must equal the expected bundle ID "
                f"{expected_bundle_id!r}, found {actual_bundle_id!r}"
            )

    forbidden = _find_forbidden_keys(info)
    if forbidden:
        raise BaselineError(f"activation-only plist keys are not allowed: {', '.join(forbidden)}")

    minimum_os = info.get("MinimumOSVersion")
    if minimum_os is not None and not isinstance(minimum_os, str):
        raise BaselineError("MinimumOSVersion must be a string when present")
    if expected_minimum_os_version is not None:
        if not re.fullmatch(r"\d+(?:\.\d+)*", expected_minimum_os_version):
            raise BaselineError("expected minimum OS version must be numeric")
        if minimum_os != expected_minimum_os_version:
            raise BaselineError(
                "MinimumOSVersion must equal the expected value "
                f"{expected_minimum_os_version!r}, found {minimum_os!r}"
            )
    return minimum_os


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plist", required=True, type=Path)
    parser.add_argument("--bundle-id", help="require this exact CFBundleIdentifier")
    parser.add_argument(
        "--xcode-project",
        type=Path,
        help="derive the expected app bundle ID from this Xcode Runner target",
    )
    parser.add_argument(
        "--minimum-os-version",
        help="require this exact numeric MinimumOSVersion (otherwise informational only)",
    )
    args = parser.parse_args(argv)
    try:
        expected_bundle_id = args.bundle_id
        if args.xcode_project is not None:
            project_bundle_id = resolve_runner_bundle_id(args.xcode_project)
            if expected_bundle_id is not None and expected_bundle_id != project_bundle_id:
                raise BaselineError(
                    "explicit bundle ID does not match the Xcode Runner target: "
                    f"{expected_bundle_id!r} != {project_bundle_id!r}"
                )
            expected_bundle_id = project_bundle_id
        minimum_os = verify_plist(
            args.plist, expected_bundle_id, args.minimum_os_version
        )
    except BaselineError as error:
        print(f"iOS baseline verification failed: {error}", file=sys.stderr)
        return 1

    print(f"Verified iOS Info.plist baseline: {args.plist}")
    print("Activation-only usage strings, background modes, ATS, and Bonjour settings: (none)")
    if args.minimum_os_version is None:
        print(f"MinimumOSVersion (informational only): {minimum_os or '(not set)'}")
    else:
        print(f"MinimumOSVersion: {minimum_os} (expected {args.minimum_os_version})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

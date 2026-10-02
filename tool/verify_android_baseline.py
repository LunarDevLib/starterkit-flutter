#!/usr/bin/env python3
"""Verify the narrow Android permission/component baseline from a built APK."""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ANDROID_NS = "http://schemas.android.com/apk/res/android"
ANDROID = f"{{{ANDROID_NS}}}"
EXPECTED_MIN_SDK = "24"
EXPECTED_DEBUG_PERMISSIONS = {"android.permission.INTERNET"}
EXPECTED_RELEASE_PERMISSIONS: set[str] = set()
FORBIDDEN_COMPONENT_TAGS = {"service", "receiver", "provider", "activity-alias"}
COMPONENT_TAGS = FORBIDDEN_COMPONENT_TAGS | {"activity"}


class BaselineError(ValueError):
    """Raised when the APK manifest does not match the reviewed baseline."""


def resolve_apkanalyzer() -> str:
    """Find Android SDK's apkanalyzer without installing or changing tools."""
    executable = shutil.which("apkanalyzer")
    if executable:
        return executable

    sdk_roots = (os.environ.get("ANDROID_HOME"), os.environ.get("ANDROID_SDK_ROOT"))
    executable_names = ("apkanalyzer", "apkanalyzer.bat")
    for sdk_root in filter(None, sdk_roots):
        for name in executable_names:
            candidate = Path(sdk_root) / "cmdline-tools" / "latest" / "bin" / name
            if candidate.is_file():
                return str(candidate)
    raise BaselineError(
        "apkanalyzer is required (PATH or ANDROID_HOME/ANDROID_SDK_ROOT "
        "cmdline-tools/latest/bin); Android SDK tools are not installed by this check"
    )


def verify_manifest_xml(xml_text: str, variant: str) -> tuple[set[str], list[str]]:
    """Validate manifest XML and return declared permissions/components."""
    if variant not in {"debug", "release"}:
        raise BaselineError(f"unsupported APK variant: {variant}")
    try:
        root = ET.fromstring(xml_text)
    except ET.ParseError as error:
        raise BaselineError(f"apkanalyzer did not return parseable manifest XML: {error}") from error
    if root.tag != "manifest":
        raise BaselineError(f"expected manifest root element, got {root.tag!r}")

    permissions = {
        element.get(ANDROID + "name", "")
        for element in root
        if element.tag.rsplit("}", 1)[-1].startswith("uses-permission")
    }
    expected_permissions = (
        EXPECTED_DEBUG_PERMISSIONS if variant == "debug" else EXPECTED_RELEASE_PERMISSIONS
    )
    if permissions != expected_permissions:
        raise BaselineError(
            f"{variant} permissions must be {sorted(expected_permissions)}, "
            f"found {sorted(permissions)}"
        )

    uses_sdk = next(
        (element for element in root if element.tag.rsplit("}", 1)[-1] == "uses-sdk"),
        None,
    )
    min_sdk = uses_sdk.get(ANDROID + "minSdkVersion") if uses_sdk is not None else None
    if min_sdk != EXPECTED_MIN_SDK:
        raise BaselineError(
            f"minSdkVersion must be {EXPECTED_MIN_SDK}, found {min_sdk!r}"
        )

    application = next(
        (element for element in root if element.tag.rsplit("}", 1)[-1] == "application"),
        None,
    )
    if application is None:
        raise BaselineError("manifest is missing application element")
    allow_backup = application.get(ANDROID + "allowBackup")
    if allow_backup != "false":
        raise BaselineError(f"application android:allowBackup must be false, found {allow_backup!r}")

    components: list[str] = []
    for child in application:
        tag = child.tag.rsplit("}", 1)[-1]
        if tag not in COMPONENT_TAGS:
            continue
        name = child.get(ANDROID + "name", "<unnamed>")
        components.append(f"{tag}={name}")
        if tag in FORBIDDEN_COMPONENT_TAGS:
            raise BaselineError(f"optional/vendor Android component is not allowed: {tag} {name}")

    activities = {
        component.partition("=")[2]
        for component in components
        if component.startswith("activity=")
    }
    activity_name = next(iter(activities), "")
    expected_main_activity = len(activities) == 1 and (
        activity_name == "MainActivity" or activity_name.endswith(".MainActivity")
    )
    if not expected_main_activity:
        raise BaselineError(
            "application must declare only its MainActivity, "
            f"found {sorted(activities)}"
        )
    return permissions, sorted(components)


def inspect_apk(apk: Path, variant: str, apkanalyzer: str) -> tuple[set[str], list[str]]:
    if not apk.is_file():
        raise BaselineError(f"APK does not exist: {apk}")
    result = subprocess.run(
        [apkanalyzer, "manifest", "print", str(apk)],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        diagnostic = result.stderr.strip() or f"exit code {result.returncode}"
        raise BaselineError(f"apkanalyzer failed for {apk}: {diagnostic}")
    return verify_manifest_xml(result.stdout, variant)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apk", required=True, type=Path)
    parser.add_argument("--variant", required=True, choices=("debug", "release"))
    args = parser.parse_args(argv)
    try:
        apkanalyzer = resolve_apkanalyzer()
        permissions, components = inspect_apk(args.apk, args.variant, apkanalyzer)
    except BaselineError as error:
        print(f"Android baseline verification failed: {error}", file=sys.stderr)
        return 1

    print(f"Verified {args.variant} APK manifest: {args.apk}")
    print(f"Permissions: {', '.join(sorted(permissions)) if permissions else '(none)'}")
    print(f"Application components: {', '.join(components)}")
    print(f"Minimum SDK: {EXPECTED_MIN_SDK}; allowBackup: false")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Verify the narrow Android permission/component baseline from a built APK."""

from __future__ import annotations

import argparse
import os
import re
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
SIGNATURE_IPC_PERMISSION_SUFFIX = ".DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION"
_ANDROID_PACKAGE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+$")
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


def _is_exact_signature_protection_level(value: str | None) -> bool:
    """Accept signature's symbolic value or only its numeric flag value 2."""
    if value == "signature":
        return True
    if value is None:
        return False
    if value.startswith(("0x", "0X")):
        digits = value[2:]
        return bool(re.fullmatch(r"[0-9a-fA-F]+", digits)) and int(digits, 16) == 2
    return bool(re.fullmatch(r"[0-9]+", value)) and int(value, 10) == 2


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

    permission_uses = [
        element.get(ANDROID + "name", "")
        for element in root
        if element.tag.rsplit("}", 1)[-1].startswith("uses-permission")
    ]
    if len(permission_uses) != len(set(permission_uses)):
        raise BaselineError("duplicate uses-permission entries are not allowed")

    permission_declaration_nodes = [
        element
        for element in root
        if element.tag.rsplit("}", 1)[-1]
        in {"permission", "permission-tree", "permission-group"}
    ]
    if any(
        element.tag.rsplit("}", 1)[-1] != "permission"
        for element in permission_declaration_nodes
    ):
        raise BaselineError("permission-tree and permission-group declarations are not allowed")
    permission_declarations = permission_declaration_nodes
    declared_names = [
        element.get(ANDROID + "name", "") for element in permission_declarations
    ]
    guard_names = [
        name
        for name in permission_uses + declared_names
        if name.endswith(SIGNATURE_IPC_PERMISSION_SUFFIX)
    ]
    signature_guard: str | None = None
    if guard_names:
        manifest_package = root.get("package", "")
        if not _ANDROID_PACKAGE.fullmatch(manifest_package):
            raise BaselineError(
                "a valid manifest package is required for the signature IPC permission"
            )
        signature_guard = f"{manifest_package}{SIGNATURE_IPC_PERMISSION_SUFFIX}"
        if any(name != signature_guard for name in guard_names):
            raise BaselineError(
                "only the manifest package's exact signature IPC permission is allowed"
            )
        if permission_uses.count(signature_guard) != 1:
            raise BaselineError(
                "the signature IPC permission must be requested exactly once"
            )
        if len(permission_declarations) != 1 or declared_names != [signature_guard]:
            raise BaselineError(
                "the signature IPC permission must have exactly one matching declaration"
            )
        protection_level = permission_declarations[0].get(ANDROID + "protectionLevel")
        if not _is_exact_signature_protection_level(protection_level):
            raise BaselineError(
                "the signature IPC permission protectionLevel must equal signature (2) exactly"
            )
    elif permission_declarations:
        raise BaselineError("application-defined permission declarations are not allowed")

    permissions = set(permission_uses)
    platform_permissions = permissions - ({signature_guard} if signature_guard else set())
    expected_permissions = (
        EXPECTED_DEBUG_PERMISSIONS if variant == "debug" else EXPECTED_RELEASE_PERMISSIONS
    )
    if platform_permissions != expected_permissions:
        raise BaselineError(
            f"{variant} platform permissions must be {sorted(expected_permissions)}, "
            f"found {sorted(platform_permissions)}"
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
    signature_guards = {
        permission
        for permission in permissions
        if permission.endswith(SIGNATURE_IPC_PERMISSION_SUFFIX)
    }
    platform_permissions = permissions - signature_guards
    print(
        "Platform permissions: "
        f"{', '.join(sorted(platform_permissions)) if platform_permissions else '(none)'}"
    )
    print(
        "App-defined signature IPC guard: "
        f"{', '.join(sorted(signature_guards)) if signature_guards else '(none)'}"
    )
    print(f"Application components: {', '.join(components)}")
    print(f"Minimum SDK: {EXPECTED_MIN_SDK}; allowBackup: false")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

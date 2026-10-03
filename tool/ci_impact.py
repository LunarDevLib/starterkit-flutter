#!/usr/bin/env python3
"""Conservative, stdlib-only changed-path routing for the Flutter CI matrix."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from typing import Iterable


FLAG_NAMES = (
    "full",
    "android_source",
    "ios_source",
    "renamed_android",
    "renamed_ios",
    "qr_android",
    "qr_ios",
)
OUTPUT_KEYS = (*FLAG_NAMES, "reason")
_KNOWN_PURE_PACKAGES = {
    "starterkit_connectivity",
    "starterkit_preferences",
    "starterkit_webview",
    "starterkit_platform",
    "starterkit_qr_barcode",
}
_DOC_ROOTS = ("docs/",)
_BASELINE_ANDROID = {
    "tool/verify_android_baseline.py",
    "tool/prepare_qr_consumer.py",
    "tool/qr_evidence.py",
}
_BASELINE_IOS = {"tool/verify_ios_baseline.py"}
_QR_SHARED_TOOLS = {"tool/prepare_qr_consumer.py", "tool/qr_evidence.py"}
_QR_FIXTURE_PREFIX = "test/tool/fixtures/qr_consumer/"
_ANDROID_NATIVE_CONFIG_NAMES = {
    "AndroidManifest.xml",
    "build.gradle",
    "build.gradle.kts",
    "settings.gradle",
    "settings.gradle.kts",
    "gradle.properties",
    "consumer-rules.pro",
    "proguard-rules.pro",
}
_IOS_NATIVE_CONFIG_NAMES = {"Package.swift", "project.pbxproj", "Info.plist"}


def _full(reason: str) -> dict[str, object]:
    return {**{name: True for name in FLAG_NAMES}, "reason": reason or "conservative full routing"}


def _valid_path(path: object) -> bool:
    if not isinstance(path, str) or not path:
        return False
    try:
        path.encode("utf-8", "strict")
    except UnicodeError:
        return False
    if any(ord(character) < 32 or 127 <= ord(character) <= 159 for character in path):
        return False
    if path.startswith("/") or "\\" in path or re.match(r"^[A-Za-z]:", path):
        return False
    parts = path.split("/")
    return all(part not in ("", ".", "..") for part in parts)


def _flags(**enabled: bool) -> dict[str, object]:
    values = {name: False for name in FLAG_NAMES}
    values.update(enabled)
    return values


def _native_package_route(path: str, package: str, platform: str) -> tuple[dict[str, bool] | None, str]:
    parts = path.split("/")
    platform_index = 2
    relative_parts = parts[platform_index + 1 :]
    name = parts[-1]
    if not relative_parts:
        return None, "native package platform configuration"
    if platform == "android":
        config = (
            name in _ANDROID_NATIVE_CONFIG_NAMES
            or name.endswith(".gradle")
            or name.endswith(".gradle.kts")
            or name.endswith(".properties")
            or "gradle/wrapper" in "/".join(relative_parts)
            or "/gradle/" in "/" + "/".join(relative_parts) + "/"
        )
    else:
        config = (
            name in _IOS_NATIVE_CONFIG_NAMES
            or name.endswith(".podspec")
            or name.endswith(".entitlements")
            or name.endswith(".xcconfig")
        )
    if config:
        # Obvious platform build/plugin metadata needs both source and renamed validation.
        route = {f"{platform}_source": True, f"renamed_{platform}": True}
        if package == "starterkit_qr_barcode":
            route[f"qr_{platform}"] = True
        return route, f"{platform} native package build/plugin metadata"
    if name in {"README.md", "LICENSE", "NOTICE"} or name.endswith(".md"):
        return _flags(), "native package documentation"
    source_suffixes = {
        "android": (".kt", ".java", ".aidl", ".c", ".cc", ".cpp", ".cxx", ".h", ".hpp"),
        "ios": (".swift", ".m", ".mm", ".c", ".cc", ".cpp", ".h", ".hpp"),
    }
    if not name.endswith(source_suffixes[platform]):
        return None, "ambiguous native package configuration or artifact"
    if platform == "android":
        route = {"android_source": True}
    else:
        route = {"ios_source": True}
    if package == "starterkit_qr_barcode":
        route.update({f"{platform}_source": True, f"renamed_{platform}": True, f"qr_{platform}": True})
    return route, f"{platform} native package implementation"


def _route_one(path: str) -> tuple[dict[str, bool] | None, str]:
    """Return known route flags, or None when this path must force full CI."""
    if path in ("pubspec.yaml", "pubspec.lock", "analysis_options.yaml", "l10n.yaml"):
        return None, "root dependency or analysis configuration"
    if path == ".github" or path.startswith(".github/"):
        return None, "workflow or CI configuration"
    if path.startswith("tool/"):
        if path in _QR_SHARED_TOOLS:
            return {
                "android_source": True,
                "ios_source": True,
                "renamed_android": True,
                "renamed_ios": True,
                "qr_android": True,
                "qr_ios": True,
            }, "shared QR consumer/evidence tool"
        if path in _BASELINE_ANDROID:
            return {
                "android_source": True,
                "renamed_android": True,
                "qr_android": True,
            }, "Android baseline/consumer helper"
        if path in _BASELINE_IOS:
            return {"ios_source": True, "renamed_ios": True, "qr_ios": True}, "iOS baseline helper"
        return None, "tooling change"
    if path.startswith("test/tool/"):
        if path == _QR_FIXTURE_PREFIX.rstrip("/") or path.startswith(_QR_FIXTURE_PREFIX):
            return {
                "android_source": True,
                "ios_source": True,
                "renamed_android": True,
                "renamed_ios": True,
                "qr_android": True,
                "qr_ios": True,
            }, "shared QR consumer fixture"
        if path == "test/tool/test_verify_android_baseline.py":
            return {"android_source": True, "renamed_android": True, "qr_android": True}, "Android baseline verifier test"
        if path == "test/tool/test_verify_ios_baseline.py":
            return {"ios_source": True, "renamed_ios": True, "qr_ios": True}, "iOS baseline verifier test"
        if path == "test/tool/test_qr_helpers.py":
            return {
                "android_source": True,
                "ios_source": True,
                "renamed_android": True,
                "renamed_ios": True,
                "qr_android": True,
                "qr_ios": True,
            }, "shared QR helper test"
        return None, "tool test or collector change"
    if path.startswith("packages/"):
        parts = path.split("/")
        if len(parts) < 3 or parts[1] not in _KNOWN_PURE_PACKAGES:
            return None, "unknown package or package metadata"
        package, area = parts[1], parts[2]
        if area in {"pubspec.yaml", "pubspec.lock", "analysis_options.yaml"} and len(parts) == 3:
            return None, "package metadata or configuration"
        if parts[-1].endswith(".podspec"):
            route = {"ios_source": True, "renamed_ios": True}
            if package == "starterkit_qr_barcode":
                route["qr_ios"] = True
            return route, "iOS package plugin metadata"
        if area in {"android", "ios"}:
            return _native_package_route(path, package, area)
        if area == "l10n.yaml":
            return None, "package configuration"
        if area in {"lib", "test"}:
            if package == "starterkit_qr_barcode":
                return {
                    "android_source": True,
                    "ios_source": True,
                    "renamed_android": True,
                    "renamed_ios": True,
                    "qr_android": True,
                    "qr_ios": True,
                }, "shared QR Dart source/test"
            return _flags(), "pure Dart package source/test"
        if (area in {"README.md", "LICENSE"} and len(parts) == 3) or area == "docs":
            return _flags(), "package documentation"
        return None, "unclassified package path"
    if path == "android" or path.startswith("android/"):
        return {"android_source": True, "renamed_android": True, "qr_android": True}, "root Android platform configuration"
    if path == "ios" or path.startswith("ios/"):
        return {"ios_source": True, "renamed_ios": True, "qr_ios": True}, "root iOS platform configuration"
    if path.startswith("lib/") or path.startswith("assets/"):
        return {"android_source": True, "ios_source": True}, "shared application runtime source/assets"
    if path.startswith("test/"):
        if path == "test/ci_source_test.dart":
            return None, "CI workflow integration test"
        return _flags(), "root Dart test"
    if path in {"README.md", "PROJECT_OVERVIEW.md", "AGENTS.md", "LICENSE"} or any(
        path.startswith(prefix) for prefix in _DOC_ROOTS
    ):
        return _flags(), "documentation-only change"
    return None, "unclassified or shared configuration path"


def classify_paths(paths: Iterable[str], force_full: bool = False) -> dict[str, object]:
    """Map a complete changed-path set to a fixed conservative route object."""
    if force_full:
        return _full("explicit full routing requested")
    try:
        materialized = list(paths)
    except Exception:
        return _full("changed paths unavailable")
    if any(not _valid_path(path) for path in materialized):
        return _full("unsafe or malformed changed path")
    if not materialized:
        return {**_flags(), "reason": "valid diff contains no changed paths"}
    combined = _flags()
    reasons: list[str] = []
    for path in materialized:
        route, reason = _route_one(path)
        if route is None:
            return _full(reason)
        for name, value in route.items():
            combined[name] = bool(combined[name] or value)
        if reason not in reasons:
            reasons.append(reason)
    combined["reason"] = "; ".join(reasons) or "known changed paths"
    return combined


def _sha(value: object) -> str | None:
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-fA-F]{40}|[0-9a-fA-F]{64}", value):
        return None
    if set(value) == {"0"}:
        return None
    return value.lower()


def _git(repo: str, *args: str) -> bytes:
    completed = subprocess.run(
        ["git", "-C", repo, *args],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return completed.stdout


def _parse_name_status_z(data: bytes) -> list[str]:
    """Parse git diff --name-status -z, keeping both rename/copy endpoints."""
    if not data:
        return []
    if not data.endswith(b"\0"):
        raise ValueError("unterminated NUL-delimited git path output")
    fields = data[:-1].split(b"\0")
    paths: list[str] = []
    index = 0
    while index < len(fields):
        try:
            status = fields[index].decode("ascii", "strict")
        except UnicodeError as error:
            raise ValueError("invalid git status encoding") from error
        index += 1
        if re.fullmatch(r"[RC][0-9]{1,3}", status):
            count = 2
        elif status in {"A", "M", "D", "T", "U", "X", "B"}:
            count = 1
        else:
            raise ValueError("unrecognized git diff status")
        if index + count > len(fields):
            raise ValueError("missing path in git diff output")
        for raw_path in fields[index : index + count]:
            try:
                path = raw_path.decode("utf-8", "strict")
            except UnicodeError as error:
                raise ValueError("git path is not valid UTF-8") from error
            if not _valid_path(path):
                raise ValueError("unsafe git path")
            paths.append(path)
        index += count
    return paths


def detect_paths(repo: str, event_name: str, event: object) -> tuple[list[str], str]:
    """Read complete trusted-base diffs. Any ambiguity returns an error for FULL routing."""
    if not isinstance(event, dict):
        raise ValueError("event JSON must be an object")
    if event_name == "pull_request":
        pr = event.get("pull_request")
        if not isinstance(pr, dict):
            raise ValueError("pull_request metadata is missing")
        base_obj, head_obj = pr.get("base"), pr.get("head")
        base = _sha(base_obj.get("sha") if isinstance(base_obj, dict) else None)
        head = _sha(head_obj.get("sha") if isinstance(head_obj, dict) else None)
        if base is None or head is None:
            raise ValueError("invalid or zero pull request SHA")
        merge_base = _git(repo, "merge-base", base, head).decode("ascii", "strict").strip()
        valid_merge = _sha(merge_base)
        if valid_merge is None:
            raise ValueError("invalid merge-base SHA")
        raw = _git(repo, "diff", "--name-status", "-z", "--find-renames", "--find-copies", "--find-copies-harder", valid_merge, head, "--")
        return _parse_name_status_z(raw), "pull request merge-base to head"
    if event_name == "push":
        before, after = _sha(event.get("before")), _sha(event.get("after"))
        if before is None or after is None:
            raise ValueError("invalid or zero push before/after SHA")
        raw = _git(repo, "diff", "--name-status", "-z", "--find-renames", "--find-copies", "--find-copies-harder", before, after, "--")
        return _parse_name_status_z(raw), "push before to after"
    raise ValueError("unrecognized event; no trusted diff")


def _load_event(path: str) -> object:
    with open(path, "r", encoding="utf-8") as stream:
        return json.load(stream, object_pairs_hook=_unique_object)


def _unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--event-name", required=True)
    parser.add_argument("--event-path", required=True)
    parser.add_argument("--output-file", required=True)
    parser.add_argument("--full", action="store_true")
    args = parser.parse_args(argv)
    if args.full:
        routing = _full("explicit full routing requested")
    else:
        try:
            event = _load_event(args.event_path)
            paths, diff_reason = detect_paths(os.path.abspath(args.repo), args.event_name, event)
            routing = classify_paths(paths)
            if not routing["full"]:
                routing["reason"] = f"{diff_reason}: {routing['reason']}"
        except Exception as error:
            # Detector uncertainty is an intentional full route, never a fast skip.
            routing = _full(f"detector uncertainty: {type(error).__name__}")
    try:
        with open(args.output_file, "w", encoding="utf-8", newline="\n") as stream:
            json.dump(routing, stream, ensure_ascii=True, separators=(",", ":"))
            stream.write("\n")
    except OSError as error:
        print(f"cannot write routing output: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

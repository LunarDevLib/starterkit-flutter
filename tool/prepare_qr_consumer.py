#!/usr/bin/env python3
"""Create an isolated app copy which explicitly opts into the QR plugin."""

from __future__ import annotations

import argparse
import re
import shutil
from pathlib import Path


ENTRYPOINT = Path("test/tool/fixtures/qr_consumer/main.dart")
FIXTURE = Path(__file__).parent / "fixtures/qr_consumer/main.dart.template"
GENERATED = (
    ".git", ".serena", ".slim", ".dart_tool", "build", ".gradle", ".build", ".kotlin", ".swiftpm",
    "Pods", ".symlinks", "ephemeral", "DerivedData", "__pycache__",
    ".flutter-plugins", ".flutter-plugins-dependencies", "local.properties",
    "GeneratedPluginRegistrant.*", "Generated.xcconfig", "flutter_export_environment.sh",
    "Flutter.podspec", "*.framework", "*.xcframework",
)


def prepare(source: Path, destination: Path) -> None:
    source = source.resolve(strict=True)
    destination = destination.resolve()
    if not source.is_dir():
        raise ValueError("consumer source must be a directory")
    if destination == source or source in destination.parents or destination in source.parents:
        raise ValueError("consumer source and destination must be disjoint")
    if destination.exists():
        raise ValueError(f"refusing to reuse existing consumer directory: {destination}")
    package = source / "packages/starterkit_qr_barcode/pubspec.yaml"
    if not package.is_file():
        raise ValueError(f"optional QR package is missing: {package}")
    if not re.search(r"(?m)^name:\s*starterkit_qr_barcode\s*$", package.read_text(encoding="utf-8")):
        raise ValueError("optional QR package identity is invalid")
    root_pubspec = source / "pubspec.yaml"
    text = root_pubspec.read_text(encoding="utf-8")
    if re.search(r"(?:^|[\s,{])['\"]?starterkit_qr_barcode['\"]?\s*:", text):
        raise ValueError("consumer source already declares starterkit_qr_barcode")
    if len(re.findall(r"(?m)^dependencies:[ \t]*$", text)) != 1 or not re.search(r"(?m)^name:\s*\w+", text):
        raise ValueError("root pubspec has no simple dependencies section")
    fixture_bytes = FIXTURE.read_bytes()
    if not fixture_bytes or not (source / "lib/main.dart").is_file():
        raise ValueError("consumer entrypoint fixture or source lib/main.dart is missing/empty")

    ignore = shutil.ignore_patterns(*GENERATED)
    shutil.copytree(source, destination, ignore=ignore)
    consumer_pubspec = destination / "pubspec.yaml"
    copied = consumer_pubspec.read_text(encoding="utf-8")
    copied = re.sub(
        r"(?m)^dependencies:\s*$",
        "dependencies:\n  starterkit_qr_barcode: {path: packages/starterkit_qr_barcode}",
        copied,
        count=1,
    )
    consumer_pubspec.write_text(copied, encoding="utf-8")
    entrypoint = destination / ENTRYPOINT
    entrypoint.parent.mkdir(parents=True, exist_ok=True)
    entrypoint.write_bytes(fixture_bytes)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    args = parser.parse_args()
    try:
        prepare(args.source, args.destination)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    print(f"Prepared isolated QR consumer at {args.destination}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Fail-closed QR integration evidence; selected inputs, not whole build trees."""

from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import re
import shutil
import struct
import subprocess
import zipfile
import xml.etree.ElementTree as ET
from pathlib import Path


PLUGIN = "starterkit_qr_barcode"
ZXING = "com.google.zxing:core:3.5.3"
REGISTRATION = "StarterkitQrBarcodePlugin"
PLUGIN_CLASS = "dev.lunardev.starterkit.qr_barcode." + REGISTRATION
CONTROL = "StarterkitPlatformPlugin"
GENERATED_DIRS = {"build", ".dart_tool", ".gradle", ".build", "Pods", ".symlinks",
                  "ephemeral", ".git", ".slim", ".serena", ".kotlin", ".swiftpm", "__pycache__"}
QR_TOKENS = re.compile(r"qr_barcode|QrBarcode|zxing", re.IGNORECASE)


def read_nonempty(path: Path) -> str:
    text = path.read_text(encoding="utf-8", errors="strict")
    if not text.strip():
        raise ValueError(f"missing/empty evidence: {path}")
    return text


def registrations(paths: list[Path], platform: str) -> str:
    if not paths:
        raise ValueError("generated registrant evidence is required")
    texts = []
    native = False
    for path in paths:
        text = read_nonempty(path)
        if path.name == ".flutter-plugins-dependencies":
            data = json.loads(text)
            plugins = data.get("plugins", {}).get(platform)
            if not isinstance(plugins, list) or not plugins or not all(
                isinstance(item, dict) and isinstance(item.get("name"), str) for item in plugins
            ) or "starterkit_platform" not in [item["name"] for item in plugins]:
                raise ValueError("invalid Flutter plugin graph or missing baseline control")
        else:
            markers = ("class GeneratedPluginRegistrant", "registerWith(") if platform == "android" else (
                "@implementation GeneratedPluginRegistrant", "registerWithRegistry:")
            if not all(marker in text for marker in markers) or CONTROL not in text:
                raise ValueError("invalid native registrant or missing baseline control")
            native = True
        texts.append(text)
    if not native:
        raise ValueError("native generated registrant is required, not just Flutter metadata")
    return "\n".join(texts)


def dex_classes(data: bytes) -> set[str]:
    """Read DEX class definitions (not an arbitrary class-name string grep)."""
    if len(data) < 112 or not re.fullmatch(rb"dex\n0\d\d\x00", data[:8]):
        raise ValueError("APK contains an invalid/truncated DEX header")
    if struct.unpack_from("<I", data, 32)[0] != len(data) or struct.unpack_from("<I", data, 36)[0] != 112:
        raise ValueError("DEX file/header size mismatch")
    if struct.unpack_from("<I", data, 40)[0] != 0x12345678:
        raise ValueError("unsupported DEX byte order")

    def table(offset: int, stride: int) -> tuple[int, int]:
        size, start = struct.unpack_from("<II", data, offset)
        if size == 0 or start < 112 or start + size * stride > len(data):
            raise ValueError("missing/invalid DEX structural table")
        return size, start

    string_count, strings = table(56, 4)
    type_count, types = table(64, 4)
    class_count, classes = table(96, 32)
    result = set()
    for index in range(class_count):
        type_index = struct.unpack_from("<I", data, classes + index * 32)[0]
        if type_index >= type_count:
            raise ValueError("DEX class type index out of range")
        string_index = struct.unpack_from("<I", data, types + type_index * 4)[0]
        if string_index >= string_count:
            raise ValueError("DEX descriptor index out of range")
        start = struct.unpack_from("<I", data, strings + string_index * 4)[0]
        if start < 112 or start >= len(data):
            raise ValueError("DEX string offset out of range")
        # Skip bounded ULEB128 UTF-16 length; class descriptors use ASCII.
        for _ in range(5):
            if start >= len(data):
                raise ValueError("truncated DEX string length")
            byte = data[start]
            start += 1
            if byte < 128:
                break
        else:
            raise ValueError("invalid DEX string length")
        end = data.find(b"\x00", start)
        if end < 0:
            raise ValueError("unterminated DEX descriptor")
        descriptor = data[start:end].decode("utf-8")
        if not descriptor.startswith("L") or not descriptor.endswith(";"):
            raise ValueError("invalid DEX class descriptor")
        result.add(descriptor[1:-1].replace("/", "."))
    return result


def check(mode: str, graph: Path, registrants: list[Path], apk: Path,
          variant: str = "debug", mapping: Path | None = None) -> dict:
    graph_text = read_nonempty(graph)
    expected_configuration = variant + "RuntimeClasspath"
    if not all(re.search(pattern, graph_text, re.MULTILINE) for pattern in (
        r"^> Task :app:dependencies(?:\s|$)", "^" + expected_configuration + r"(?:\s|$)",
        r"^BUILD SUCCESSFUL(?:\s|$)", r"\bproject :starterkit_platform(?:\s|$)"
    )) or re.search(r"\bFAILED\b|\(n\)", graph_text):
        raise ValueError("invalid/unresolved app runtime graph or missing baseline module control")
    registration_text = registrations(registrants, "android")
    registered = REGISTRATION in registration_text
    coordinates = re.findall(r"com\.google\.zxing:core:([^\s]+)(?:\s+->\s+([^\s]+))?", graph_text)
    selected = [replacement or requested for requested, replacement in coordinates]
    if mode == "default":
        if QR_TOKENS.search(graph_text + registration_text):
            raise ValueError("default graph/registrants contain QR or ZXing identifiers")
    elif not re.search(r"\bproject :starterkit_qr_barcode(?:\s|$)", graph_text) or not selected or any(version != "3.5.3" for version in selected) or not registered:
        raise ValueError("opt-in must resolve the QR module, ZXing exactly 3.5.3, and native registration")

    with zipfile.ZipFile(apk) as archive:
        if archive.testzip() is not None:
            raise ValueError("APK ZIP integrity check failed")
        entries = [name for name in archive.namelist() if re.fullmatch(r"classes\d*\.dex", name)]
        if not entries or "AndroidManifest.xml" not in archive.namelist():
            raise ValueError("APK must contain manifest and DEX evidence")
        classes = set()
        qr_identifiers = False
        for name in entries:
            data = archive.read(name)
            classes.update(dex_classes(data))
            qr_identifiers |= any(token in data.lower() for token in (
                b"qr_barcode", b"qrbarcode", b"com/google/zxing", b"com.google.zxing"))
    linked_vendor = []
    if mode == "default":
        if qr_identifiers:
            raise ValueError("default APK DEX contains QR/ZXing implementation identifiers")
    else:
        aliases = {}
        if variant == "release":
            if mapping is None:
                raise ValueError("release opt-in requires R8 mapping plus structural DEX linkage")
            aliases = dict(re.findall(r"^([^ #\s][^\s]*) -> ([^\s]+):$", read_nonempty(mapping), re.MULTILINE))
            if not aliases or PLUGIN_CLASS not in aliases:
                raise ValueError("R8 mapping lacks QR plugin class identity")
        if aliases.get(PLUGIN_CLASS, PLUGIN_CLASS) not in classes:
            raise ValueError("APK class definitions lack the mapped QR plugin")
        linked_vendor = sorted(original for original, renamed in aliases.items()
                               if original.startswith("com.google.zxing.") and renamed in classes)
        if variant == "debug":
            linked_vendor = sorted(name for name in classes if name.startswith("com.google.zxing."))
        if not linked_vendor:
            raise ValueError("APK class definitions lack mapped ZXing implementation")
    return {"classification": mode, "variant": variant, "graph": str(graph),
            "registrants": [str(path) for path in registrants], "selected_zxing_versions": selected,
            "plugin_registered": registered, "apk_dex_entries": entries,
            "defined_class_count": len(classes), "linked_zxing_classes": linked_vendor,
            "r8_mapping": str(mapping) if mapping else None,
            "limitation": "Build/link evidence, not device decode execution. Default DEX name checks are corroborated by resolved graphs; obfuscated release names alone cannot prove absence."}


def hashes(root: Path, output: Path, includes: list[Path] | None = None) -> None:
    root = root.resolve(strict=True)
    files = set()
    for relative in includes or [Path(".")]:
        selected = (root / relative).resolve(strict=True)
        if selected != root and root not in selected.parents:
            raise ValueError("hash inputs must be inside their root")
        candidates = [selected] if selected.is_file() else selected.rglob("*")
        for path in candidates:
            if path.is_file() and path.resolve() != output.resolve() and not any(
                part in GENERATED_DIRS for part in path.relative_to(selected if selected.is_dir() else selected.parent).parts
            ):
                files.add(path)
    records = [{"path": path.relative_to(root).as_posix(),
                "sha256": hashlib.sha256(path.read_bytes()).hexdigest()} for path in sorted(files)]
    if not records:
        raise ValueError("no selected hash inputs")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(records, indent=2) + "\n", encoding="utf-8")


def ios_tool_sections(capture: str) -> tuple[str, str]:
    sections = []
    for label in ("NM", "OTOOL"):
        matches = list(re.finditer(r"(?ms)^" + label + r":\n(.*?)(?=^STDERR:|^NM:|^OTOOL:|\Z)", capture))
        if len(matches) != 1 or not matches[0].group(1).strip():
            raise ValueError("missing/duplicate/truncated native " + label + " capture")
        sections.append(matches[0].group(1))
    return sections[0], sections[1]


def ios_slice_sections(capture: str) -> dict[str, tuple[str, str]]:
    nm, otool = ios_tool_sections(capture)
    inventories = re.findall(r"(?m)^ARCHS: ([^\n]*)$", capture)
    declared = inventories[0].split() if len(inventories) == 1 else []
    if (len(inventories) != 1 or not declared or len(set(declared)) != len(declared)
            or any(not re.fullmatch(r"[A-Za-z0-9_]+", arch) for arch in declared)):
        raise ValueError("invalid native architecture inventory")

    def split(text):
        headers = list(re.finditer(r"(?m)^.+ \((?:for )?architecture ([A-Za-z0-9_]+)\):\n", text))
        if not headers:
            # Unlabelled output is usable only for an explicitly recorded thin image.
            if len(declared) != 1 or re.search(r"\((?:for )?architecture\b", text):
                raise ValueError("native slice architecture is not established")
            return {declared[0]: text}
        if text[:headers[0].start()].strip():
            raise ValueError("mixed labelled/unlabelled native slice capture")
        slices = {}
        for index, header in enumerate(headers):
            arch = header.group(1)
            body = text[header.end():headers[index + 1].start() if index + 1 < len(headers) else len(text)]
            if arch in slices or not body.strip():
                raise ValueError("duplicate/empty native slice capture")
            slices[arch] = body
        if set(slices) != set(declared):
            raise ValueError("native slice capture does not match architecture inventory")
        return slices

    symbols, loads = split(nm), split(otool)
    if set(symbols) != set(loads):
        raise ValueError("native NM/OTOOL architecture mismatch")
    return {arch: (symbols[arch], loads[arch]) for arch in symbols}


def check_ios(mode: str, pod_lock: Path, registrants: list[Path], link_evidence: Path) -> dict:
    lock_text = read_nonempty(pod_lock)
    registrant_text = registrations(registrants, "ios")
    linked_text = read_nonempty(link_evidence)
    if not all(token in lock_text for token in ("PODS:", "DEPENDENCIES:", "SPEC CHECKSUMS:", "starterkit_platform")):
        raise ValueError("invalid Pod lock or missing baseline pod control")
    if not all(token in linked_text for token in ("FILE:", "NM:", "OTOOL:", CONTROL, "starterkit_platform.framework")):
        raise ValueError("invalid native link evidence or missing baseline linkage control")
    if mode == "default" and QR_TOKENS.search(lock_text + registrant_text + linked_text):
        raise ValueError("default iOS evidence contains QR/ZXing identifiers")
    if mode == "opt-in":
        if not re.search(r"(?m)^  - starterkit_qr_barcode \(1\.0\.0\)", lock_text):
            raise ValueError("opt-in Pod lock lacks QR pod version 1.0.0")
        records = {}
        for match in re.finditer(r"(?ms)^FILE: ([^\n]+)\n(.*?)(?=^FILE:|\Z)", linked_text):
            name, capture = match.groups()
            if name in records:
                raise ValueError("duplicate native binary capture: " + name)
            ios_tool_sections(capture)
            records[name] = capture
        framework_name = "Frameworks/starterkit_qr_barcode.framework/starterkit_qr_barcode"
        if "Runner" not in records or framework_name not in records or REGISTRATION not in registrant_text:
            raise ValueError("opt-in requires Runner, generated registration and QR framework")
        runner = ios_slice_sections(records["Runner"])
        framework = ios_slice_sections(records[framework_name])
        debug = ios_slice_sections(records["Runner.debug.dylib"]) if "Runner.debug.dylib" in records else {}

        def loads(record, install_name):
            return record is not None and any(
                line.strip().split(" (compatibility version", 1)[0] == install_name
                for line in record[1].splitlines()
            )

        qr_install_name = "@rpath/starterkit_qr_barcode.framework/starterkit_qr_barcode"
        for arch, image in runner.items():
            qr_slice = framework.get(arch)
            defined_plugin = qr_slice is not None and re.search(
                r"(?m)^[ \t]*(?:[0-9a-fA-F]+\s+)?[TtDSs]\s+\S*StarterkitQrBarcodePlugin$", qr_slice[0])
            direct = loads(image, qr_install_name)
            via_debug = loads(image, "@rpath/Runner.debug.dylib") and loads(debug.get(arch), qr_install_name)
            if not defined_plugin or not (direct or via_debug):
                raise ValueError("opt-in requires defined QR class and complete Runner load chain for slice " + arch)
    return {"classification": mode, "pod_lock": str(pod_lock),
            "registrants": [str(path) for path in registrants],
            "plugin_present_in_link_evidence": REGISTRATION in linked_text,
            "limitation": "Native symbol/framework linkage is not runtime decode proof. System ImageIO already exists in the baseline; no framework-absence claim."}


def copy_file(root: Path, relative: Path, output: Path) -> Path:
    target = output / (Path(*relative.parts[1:]) if relative.parts[0] == "build" else relative)
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(root / relative, target)
    return target


def diagnostic(output: Path, callback) -> dict:
    try:
        result = {"status": "ACTUAL_PASS", **callback()}
    except (OSError, ValueError, zipfile.BadZipFile) as error:
        output.write_text(json.dumps({"status": "ACTUAL_FAIL", "error": str(error)}, indent=2) + "\n")
        raise
    output.write_text(json.dumps(result, indent=2) + "\n")
    return result


def collect_android(root: Path, mode: str) -> None:
    import verify_android_baseline as baseline

    output = root / "build/ci-qr-evidence"
    output.mkdir(parents=True, exist_ok=True)
    registrants = [copy_file(root, Path(path), output) for path in (
        ".flutter-plugins-dependencies", "android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java")]
    identity = re.search(r'applicationId\s*=\s*"([^"]+)"', read_nonempty(root / "android/app/build.gradle.kts"))
    if identity is None:
        raise ValueError("app applicationId identity missing")
    for variant in ("debug", "release"):
        graph = output / (variant + "RuntimeClasspath.txt")
        with graph.open("w") as stream:
            subprocess.run([str(root / "android/gradlew"), "--project-dir", str(root / "android"),
                            ":app:dependencies", "--configuration", variant + "RuntimeClasspath"],
                           stdout=stream, stderr=subprocess.STDOUT, check=True)
        apk = copy_file(root, Path(f"build/app/outputs/flutter-apk/app-{variant}.apk"), output)
        manifest = subprocess.run([baseline.resolve_apkanalyzer(), "manifest", "print", str(apk)],
                                  capture_output=True, text=True)
        (output / f"app-{variant}-manifest.xml").write_text(manifest.stdout)
        (output / f"app-{variant}-apkanalyzer.stderr.txt").write_text(manifest.stderr)
        manifest.check_returncode()
        manifest = manifest.stdout
        baseline.verify_manifest_xml(manifest, variant)
        if ET.fromstring(manifest).get("package") != identity.group(1):
            raise ValueError("built APK identity does not match consumer applicationId")
        mapping = None
        if mode == "opt-in" and variant == "release":
            mapping = copy_file(root, Path("build/app/outputs/mapping/release/mapping.txt"), output)
        diagnostic(output / f"{variant}-check.json", lambda: check(mode, graph, registrants, apk, variant, mapping))
    if mode == "opt-in":
        unit_count = 0
        for relative in ("build/starterkit_qr_barcode/test-results/testDebugUnitTest",
                         "build/starterkit_qr_barcode/reports/tests/testDebugUnitTest"):
            source = root / relative
            if not source.is_dir() or not any(source.rglob("*")):
                raise ValueError("required native QR test reports missing: " + relative)
            if "test-results" in relative:
                unit_count = junit_count(source)
            shutil.copytree(source, output / Path(*Path(relative).parts[1:]), dirs_exist_ok=True)
        (output / "native-junit-summary.json").write_text(json.dumps({"executed_tests": unit_count}, indent=2) + "\n")
    selected_inputs(root, output)
    hashes(output, output / "artifact-hashes.json")


def junit_count(root: Path) -> int:
    count = 0
    for path in sorted(root.glob("*.xml")):
        try:
            suite = ET.parse(path).getroot()
        except ET.ParseError as error:
            raise ValueError("invalid native JUnit report: " + str(path)) from error
        if suite.tag != "testsuite":
            raise ValueError("native JUnit report must contain a testsuite")
        tests, skipped, failures, errors = (int(suite.get(key, "0")) for key in ("tests", "skipped", "failures", "errors"))
        if min(tests, skipped, failures, errors) < 0 or failures or errors or tests <= skipped:
            raise ValueError("native JUnit report has failed/empty/nonexecuted tests")
        count += tests - skipped
    if count == 0:
        raise ValueError("native JUnit XML execution evidence is missing")
    return count


def selected_inputs(root: Path, output: Path) -> None:
    includes = [Path(path) for path in ("pubspec.yaml", "pubspec.lock", "tool/prepare_qr_consumer.py",
                "tool/qr_evidence.py", "tool/fixtures/qr_consumer", "packages/starterkit_qr_barcode",
                "android/app/build.gradle.kts", "ios/Runner/Info.plist", "ios/Runner.xcodeproj/project.pbxproj")]
    if (root / "test/tool/fixtures/qr_consumer/main.dart").is_file():
        includes.append(Path("test/tool/fixtures/qr_consumer/main.dart"))
    hashes(root, output / "selected-input-hashes.json", includes)


def collect_ios(root: Path, mode: str, variant: str, app: Path) -> None:
    output = root / "build/ci-qr-evidence" / variant
    output.mkdir(parents=True, exist_ok=True)
    lock = copy_file(root, Path("ios/Podfile.lock"), output)
    registrants = [copy_file(root, Path(path), output) for path in (
        ".flutter-plugins-dependencies", "ios/Runner/GeneratedPluginRegistrant.m")]
    copy_file(root, Path("ios/Runner/GeneratedPluginRegistrant.h"), output)
    shutil.copytree(app, output / "Runner.app", dirs_exist_ok=True)
    info = plistlib.loads((app / "Info.plist").read_bytes())
    binaries = [app / info["CFBundleExecutable"]]
    # Xcode debug builds put the app's plugin imports/loads in this dylib;
    # Runner is a launcher which loads it, not a direct plugin consumer.
    debug_dylib = app / (info["CFBundleExecutable"] + ".debug.dylib")
    if debug_dylib.is_file():
        binaries.append(debug_dylib)
    for framework in sorted((app / "Frameworks").glob("*.framework")):
        if framework.stem not in ("App", "Flutter"):
            binaries.append(framework / framework.stem)
    linked = output / "native-linkage.txt"
    with linked.open("w") as stream:
        for binary in binaries:
            if not binary.is_file() or binary.stat().st_size == 0:
                raise ValueError("missing/empty native binary: " + str(binary))
            stream.write(f"FILE: {binary.relative_to(app)}\n")
            inventory = subprocess.run(["xcrun", "lipo", "-archs", str(binary)], capture_output=True, text=True)
            inventory.check_returncode()
            arches = inventory.stdout.split()
            if not arches or len(set(arches)) != len(arches) or any(not re.fullmatch(r"[A-Za-z0-9_]+", arch) for arch in arches):
                raise ValueError("invalid lipo architecture inventory: " + str(binary))
            stream.write("ARCHS: " + " ".join(arches) + "\n")
            for label, tool, flag in (("NM", "nm", "-g"), ("OTOOL", "otool", "-L")):
                stream.write(f"{label}:\n")
                diagnostics = []
                for arch in arches:
                    result = subprocess.run(["xcrun", tool, "-arch", arch, flag, str(binary)], capture_output=True, text=True)
                    headers = re.findall(r"(?m)^.+ \((?:for )?architecture ([A-Za-z0-9_]+)\):\n", result.stdout)
                    if any(value != arch for value in headers) or len(headers) > 1:
                        raise ValueError("native tool returned unexpected architecture: " + str(binary))
                    body = re.sub(r"(?m)^.+ \((?:for )?architecture [A-Za-z0-9_]+\):\n", "", result.stdout)
                    if not body.strip():
                        raise ValueError("empty native tool slice capture: " + str(binary))
                    stream.write(f"{binary.relative_to(app)} (architecture {arch}):\n{body}\n")
                    diagnostics.append(result.stderr)
                    stream.flush()
                    result.check_returncode()
                stream.write("STDERR:\n" + "\n".join(diagnostics) + "\n")
    diagnostic(output / "check.json", lambda: check_ios(mode, lock, registrants, linked))
    selected_inputs(root, output)
    hashes(output, output / "artifact-hashes.json")


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    evidence = sub.add_parser("check-graph")
    evidence.add_argument("--mode", choices=("default", "opt-in"), required=True)
    evidence.add_argument("--graph", type=Path, required=True)
    evidence.add_argument("--registrant", type=Path, action="append", default=[])
    evidence.add_argument("--apk", type=Path, required=True)
    evidence.add_argument("--variant", choices=("debug", "release"), default="debug")
    evidence.add_argument("--mapping", type=Path)
    evidence.add_argument("--output", type=Path, required=True)
    manifest = sub.add_parser("hashes")
    manifest.add_argument("--root", type=Path, required=True)
    manifest.add_argument("--include", type=Path, action="append")
    manifest.add_argument("--output", type=Path, required=True)
    ios = sub.add_parser("check-ios")
    ios.add_argument("--mode", choices=("default", "opt-in"), required=True)
    ios.add_argument("--pod-lock", type=Path, required=True)
    ios.add_argument("--registrant", type=Path, action="append", default=[])
    ios.add_argument("--link-evidence", type=Path, required=True)
    ios.add_argument("--output", type=Path, required=True)
    for name in ("collect-android", "collect-ios"):
        collect = sub.add_parser(name)
        collect.add_argument("--root", type=Path, default=Path.cwd())
        collect.add_argument("--mode", choices=("default", "opt-in"), required=True)
        if name == "collect-ios":
            collect.add_argument("--variant", choices=("simulator", "release"), required=True)
            collect.add_argument("--app", type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.command == "check-graph":
            diagnostic(args.output, lambda: check(args.mode, args.graph, args.registrant, args.apk, args.variant, args.mapping))
        elif args.command == "hashes":
            hashes(args.root, args.output, args.include)
        elif args.command == "check-ios":
            diagnostic(args.output, lambda: check_ios(args.mode, args.pod_lock, args.registrant, args.link_evidence))
        elif args.command == "collect-android":
            collect_android(args.root.resolve(strict=True), args.mode)
        else:
            collect_ios(args.root.resolve(strict=True), args.mode, args.variant, args.app.resolve(strict=True))
    except (OSError, ValueError, zipfile.BadZipFile, subprocess.CalledProcessError, struct.error) as error:
        if args.command.startswith("collect-"):
            output = args.root / "build/ci-qr-evidence/collection-error.json"
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(json.dumps({"status": "ACTUAL_FAIL", "error": str(error)}, indent=2) + "\n")
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

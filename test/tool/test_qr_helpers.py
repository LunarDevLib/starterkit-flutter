import importlib.util
import base64
import json
import struct
import tempfile
import subprocess
import types
import unittest
import zipfile
import zlib
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


prepare = load("prepare_qr_consumer", ROOT / "tool/prepare_qr_consumer.py")
evidence = load("qr_evidence", ROOT / "tool/qr_evidence.py")


def dex(*names):
    """Minimal structural DEX table fixture; not an executable Android app."""
    count = len(names)
    strings = 112
    types = strings + count * 4
    classes = types + count * 4
    result = bytearray(classes + count * 32)
    result[:8] = b"dex\n035\x00"
    struct.pack_into("<II", result, 36, 112, 0x12345678)
    struct.pack_into("<II", result, 56, count, strings)
    struct.pack_into("<II", result, 64, count, types)
    struct.pack_into("<II", result, 96, count, classes)
    for index, name in enumerate(names):
        descriptor = ("L" + name.replace(".", "/") + ";").encode()
        struct.pack_into("<I", result, strings + index * 4, len(result))
        struct.pack_into("<I", result, types + index * 4, index)
        struct.pack_into("<I", result, classes + index * 32, index)
        result.extend(bytes([len(descriptor)]) + descriptor + b"\x00")
    struct.pack_into("<I", result, 32, len(result))
    return bytes(result)


class PrepareQrConsumerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.base = self.root / "base"
        self.base.mkdir()
        (self.base / "pubspec.yaml").write_text("name: baseline\ndependencies:\n  flutter:\n    sdk: flutter\ndev_dependencies:\n  test: ^1.0.0\n")
        package = self.base / "packages/starterkit_qr_barcode"
        package.mkdir(parents=True)
        (package / "pubspec.yaml").write_text("name: starterkit_qr_barcode\n")
        (self.base / "lib").mkdir()
        (self.base / "lib/main.dart").write_text("void main() {}\n")
        self.destination = self.root / "consumer"

    def fingerprint(self):
        return {path.relative_to(self.base): path.read_bytes() for path in self.base.rglob("*") if path.is_file()}

    def test_creates_copy_only_activates_consumer_and_keeps_real_entrypoint(self):
        before = self.fingerprint()
        prepare.prepare(self.base, self.destination)
        self.assertIn("starterkit_qr_barcode: {path: packages/starterkit_qr_barcode}", (self.destination / "pubspec.yaml").read_text())
        self.assertEqual(before, self.fingerprint())
        self.assertEqual((self.destination / "lib/main.dart").read_bytes(), before[Path("lib/main.dart")])
        entry = self.destination / prepare.ENTRYPOINT
        self.assertTrue(entry.is_file())
        self.assertIn("await capability.decode", entry.read_text())
        self.assertIn("WidgetsFlutterBinding.ensureInitialized", entry.read_text())
        self.assertIn("runApp(Text(result.kind.name", entry.read_text())
        self.assertFalse((ROOT / "tool/fixtures/qr_consumer/main.dart").exists())

    def test_fixture_uses_valid_encoded_png_with_real_chunk_checksums(self):
        text = prepare.FIXTURE.read_text()
        import re
        encoded = re.search(r"'([A-Za-z0-9+/=]{80,})'", text).group(1)
        image = base64.b64decode(encoded, validate=True)
        self.assertEqual(image[:8], b"\x89PNG\r\n\x1a\n")
        offset = 8
        chunks = []
        while offset < len(image):
            size = struct.unpack_from(">I", image, offset)[0]
            payload = image[offset + 4:offset + size + 8]
            self.assertEqual(zlib.crc32(payload), struct.unpack_from(">I", image, offset + size + 8)[0])
            chunks.append(payload[:4])
            if payload[:4] == b"IDAT":
                self.assertEqual(zlib.decompress(payload[4:]), b"\x00\xff\xff\xff")
            offset += size + 12
        self.assertEqual(chunks, [b"IHDR", b"IDAT", b"IEND"])

    def test_copies_fresh_without_nested_native_or_flutter_build_state(self):
        stale = ["build/output", "android/.gradle/cache", "ios/Pods/pod", "ios/.symlinks/plugins/plugin",
                 "ios/Flutter/ephemeral/state", "packages/starterkit_qr_barcode/ios/.build/object",
                 "packages/starterkit_qr_barcode/android/build/object", "android/local.properties",
                 "android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java",
                 "ios/Runner/GeneratedPluginRegistrant.m", "ios/Flutter/Generated.xcconfig"]
        for relative in stale:
            path = self.base / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("stale")
        before = self.fingerprint()
        prepare.prepare(self.base, self.destination)
        for relative in stale:
            self.assertFalse((self.destination / relative).exists(), relative)
        self.assertEqual(before, self.fingerprint())

    def test_refuses_existing_destination_without_mutating_it(self):
        self.destination.mkdir()
        (self.destination / "owned").write_text("preserve")
        with self.assertRaises(ValueError):
            prepare.prepare(self.base, self.destination)
        self.assertEqual((self.destination / "owned").read_text(), "preserve")

    def test_refuses_inside_source_same_source_and_parent(self):
        before = self.fingerprint()
        for destination in (self.base / "target", self.base, self.root):
            with self.subTest(destination=destination), self.assertRaises(ValueError):
                prepare.prepare(self.base, destination)
        self.assertEqual(before, self.fingerprint())
        self.assertFalse((self.base / "target").exists())

    def test_refuses_preopted_source_including_inline_and_quoted_yaml(self):
        for text in ("dependencies:\n  starterkit_qr_barcode: any\n", "dependencies: {starterkit_qr_barcode: any}\n",
                     "dependencies:\n    'starterkit_qr_barcode': any\n"):
            (self.base / "pubspec.yaml").write_text("name: app\n" + text)
            with self.subTest(text=text), self.assertRaises(ValueError):
                prepare.prepare(self.base, self.destination)
            self.assertFalse(self.destination.exists())

    def test_missing_fixture_and_invalid_source_do_not_create_partial_destination(self):
        with patch.object(prepare, "FIXTURE", self.root / "missing-fixture"):
            with self.assertRaises(OSError):
                prepare.prepare(self.base, self.destination)
        self.assertFalse(self.destination.exists())
        (self.base / "lib/main.dart").unlink()
        with self.assertRaises(ValueError):
            prepare.prepare(self.base, self.destination)
        self.assertFalse(self.destination.exists())
        with self.assertRaises(OSError):
            prepare.prepare(self.root / "missing-source", self.destination)
        with self.assertRaises(ValueError):
            prepare.prepare(self.base / "pubspec.yaml", self.destination)


class QrEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.graph = self.root / "graph.txt"
        self.registrant = self.root / "GeneratedPluginRegistrant.java"
        self.apk = self.root / "app.apk"
        self.mapping = self.root / "mapping.txt"
        self.write_inputs()

    def write_apk(self, *names, data=None):
        with zipfile.ZipFile(self.apk, "w") as apk:
            apk.writestr("AndroidManifest.xml", b"fixture")
            apk.writestr("classes.dex", data if data is not None else dex(*names))

    def write_inputs(self, mode="default", version="3.5.3", variant="debug"):
        self.graph.write_text("> Task :app:dependencies\n" + variant + "RuntimeClasspath - app runtime\n"
                              "+--- project :starterkit_platform\n" +
                              ("+--- project :starterkit_qr_barcode\n     \\--- com.google.zxing:core:" + version + "\n" if mode == "opt-in" else "") + "BUILD SUCCESSFUL\n")
        self.registrant.write_text("public final class GeneratedPluginRegistrant {\nvoid registerWith() {\n"
                                  "new StarterkitPlatformPlugin();\n" +
                                  ("new StarterkitQrBarcodePlugin();\n" if mode == "opt-in" else "") + "}}\n")
        self.write_apk(*([evidence.PLUGIN_CLASS, "com.google.zxing.MultiFormatReader"] if mode == "opt-in" else ["example.MainActivity"]))

    def check(self, mode="default", variant="debug", mapping=None):
        return evidence.check(mode, self.graph, [self.registrant], self.apk, variant, mapping)

    def test_valid_default_and_optin_controls(self):
        self.assertEqual(self.check()["classification"], "default")
        self.write_inputs("opt-in")
        result = self.check("opt-in")
        self.assertTrue(result["plugin_registered"])
        self.assertEqual(result["selected_zxing_versions"], ["3.5.3"])
        self.assertEqual(result["defined_class_count"], 2)

    def test_any_zxing_version_or_module_in_default_graph_fails(self):
        for value in ("com.google.zxing:core:3.5.4", "com.google.zxing:android-integration:1.0", "project :starterkit_qr_barcode"):
            self.write_inputs()
            self.graph.write_text(self.graph.read_text() + value)
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.check()

    def test_optin_uses_selected_version_not_requested_version(self):
        for version in ("3.5.4", "3.5.3 -> 3.5.4", "3.5.3 FAILED", "3.5.3 -> com.other:lib:1.0"):
            self.write_inputs("opt-in", version)
            with self.subTest(version=version), self.assertRaises(ValueError):
                self.check("opt-in")
        self.write_inputs("opt-in", "3.5.4 -> 3.5.3")
        self.assertEqual(self.check("opt-in")["selected_zxing_versions"], ["3.5.3"])

    def test_empty_missing_wrong_module_and_unresolved_graph_fail(self):
        original = self.graph.read_text()
        for text in ("", "debugRuntimeClasspath\n", original.replace(":app:dependencies", ":library:dependencies"),
                     original.replace("starterkit_platform", "other"), original + "unresolved (n)\n"):
            self.graph.write_text(text)
            with self.subTest(text=text), self.assertRaises(ValueError):
                self.check()
        self.graph.unlink()
        with self.assertRaises(OSError):
            self.check()

    def test_empty_missing_and_malformed_registrants_fail(self):
        for text in ("", "GeneratedPluginRegistrant", "class GeneratedPluginRegistrant { void registerWith() {} }"):
            self.registrant.write_text(text)
            with self.subTest(text=text), self.assertRaises(ValueError):
                self.check()
        with self.assertRaises(ValueError):
            evidence.check("default", self.graph, [], self.apk)
        self.registrant.unlink()
        with self.assertRaises(OSError):
            self.check()

    def test_metadata_without_native_registration_is_not_enough(self):
        metadata = self.root / ".flutter-plugins-dependencies"
        metadata.write_text(json.dumps({"plugins": {"android": [{"name": "starterkit_platform"}]}}))
        with self.assertRaises(ValueError):
            evidence.check("default", self.graph, [metadata], self.apk)
        metadata.write_text("{}")
        with self.assertRaises(ValueError):
            evidence.check("default", self.graph, [metadata, self.registrant], self.apk)

    def test_apk_without_dex_bad_zip_empty_dex_and_string_only_linkage_fail(self):
        with zipfile.ZipFile(self.apk, "w") as apk:
            apk.writestr("AndroidManifest.xml", b"fixture")
        with self.assertRaises(ValueError):
            self.check()
        self.apk.write_bytes(b"not a zip")
        with self.assertRaises(zipfile.BadZipFile):
            self.check()
        for data in (b"", b"StarterkitQrBarcodePlugin com/google/zxing/MultiFormatReader"):
            self.write_apk(data=data)
            with self.assertRaises(ValueError):
                self.check()

    def test_default_both_debug_and_release_dex_detect_zxing(self):
        for variant in ("debug", "release"):
            self.write_inputs(variant=variant)
            self.write_apk("com.google.zxing.MultiFormatReader")
            with self.subTest(variant=variant), self.assertRaises(ValueError):
                self.check(variant=variant)

    def test_release_requires_mapping_and_defined_mapped_plugin_and_vendor(self):
        self.write_inputs("opt-in", variant="release")
        with self.assertRaises(ValueError):
            self.check("opt-in", "release")
        self.mapping.write_text(evidence.PLUGIN_CLASS + " -> a.b:\ncom.google.zxing.MultiFormatReader -> a.c:\n")
        self.write_apk("a.b", "a.c")
        result = self.check("opt-in", "release", self.mapping)
        self.assertEqual(result["linked_zxing_classes"], ["com.google.zxing.MultiFormatReader"])
        for names in (("a.b",), ("a.c",), ("unrelated.Class",)):
            self.write_apk(*names)
            with self.subTest(names=names), self.assertRaises(ValueError):
                self.check("opt-in", "release", self.mapping)
        self.mapping.write_text("")
        with self.assertRaises(ValueError):
            self.check("opt-in", "release", self.mapping)

    def test_hashes_selected_inputs_skip_generated_and_self_deterministically(self):
        (self.root / "source.txt").write_text("input")
        (self.root / "build").mkdir()
        (self.root / "build/generated").write_text("ignore")
        output = self.root / "hashes.json"
        evidence.hashes(self.root, output)
        first = output.read_bytes()
        evidence.hashes(self.root, output)
        self.assertEqual(first, output.read_bytes())
        names = [record["path"] for record in json.loads(first)]
        self.assertNotIn("build/generated", names)
        self.assertNotIn("hashes.json", names)
        self.assertIn("source.txt", names)
        evidence.hashes(self.root, output, [Path("source.txt")])
        self.assertEqual([item["path"] for item in json.loads(output.read_text())], ["source.txt"])
        with self.assertRaises(ValueError):
            evidence.hashes(self.root, output, [Path("..")])

    def test_diagnostic_json_persists_failure(self):
        self.graph.write_text("")
        output = self.root / "check.json"
        with self.assertRaises(ValueError):
            evidence.diagnostic(output, self.check)
        self.assertEqual(json.loads(output.read_text())["status"], "ACTUAL_FAIL")

    def test_junit_requires_real_executed_nonfailing_xml_suites(self):
        suite = self.root / "TEST-unit.xml"
        for text in ('<testsuite tests="0"/>', '<testsuite tests="2" skipped="2"/>',
                     '<testsuite tests="2" failures="1"/>', '<testsuite tests="2" errors="1"/>',
                     '<testsuite tests="2" errors="-1"/>', '<testsuites/>', 'not XML'):
            suite.write_text(text)
            with self.subTest(text=text), self.assertRaises(ValueError):
                evidence.junit_count(self.root)
        suite.write_text('<testsuite tests="4" skipped="1" failures="0" errors="0"/>')
        self.assertEqual(evidence.junit_count(self.root), 3)

    def test_android_collector_stages_both_graphs_apks_mapping_reports_and_hashes(self):
        root = self.root / "app"
        root.mkdir()
        files = {
            "android/app/build.gradle.kts": 'applicationId = "example.app"',
            "android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java":
                "class GeneratedPluginRegistrant { void registerWith() { StarterkitPlatformPlugin; StarterkitQrBarcodePlugin; }}",
            ".flutter-plugins-dependencies": json.dumps({"plugins": {"android": [{"name": "starterkit_platform"}, {"name": evidence.PLUGIN}]}}),
            "build/app/outputs/mapping/release/mapping.txt": evidence.PLUGIN_CLASS + " -> a.b:\ncom.google.zxing.MultiFormatReader -> a.c:\n",
            "build/starterkit_qr_barcode/test-results/testDebugUnitTest/TEST-Unit.xml": '<testsuite tests="5" failures="0" errors="0" skipped="0"/>',
            "build/starterkit_qr_barcode/reports/tests/testDebugUnitTest/index.html": "fixture report",
        }
        for relative, text in files.items():
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        for variant, names in (("debug", [evidence.PLUGIN_CLASS, "com.google.zxing.MultiFormatReader"]), ("release", ["a.b", "a.c"])):
            apk = root / f"build/app/outputs/flutter-apk/app-{variant}.apk"
            apk.parent.mkdir(parents=True, exist_ok=True)
            with zipfile.ZipFile(apk, "w") as archive:
                archive.writestr("classes.dex", dex(*names))
                archive.writestr("AndroidManifest.xml", b"fixture")
        fake_baseline = types.SimpleNamespace(resolve_apkanalyzer=lambda: "apkanalyzer", verify_manifest_xml=lambda text, variant: None)

        def command(args, **kwargs):
            if ":app:dependencies" in args:
                configuration = args[-1]
                kwargs["stdout"].write("> Task :app:dependencies\n" + configuration + "\nproject :starterkit_platform\nproject :starterkit_qr_barcode\ncom.google.zxing:core:3.5.3\nBUILD SUCCESSFUL\n")
                return subprocess.CompletedProcess(args, 0)
            return subprocess.CompletedProcess(args, 0, '<manifest package="example.app"/>', "")

        with patch.dict("sys.modules", {"verify_android_baseline": fake_baseline}), patch.object(evidence.subprocess, "run", side_effect=command), patch.object(evidence, "selected_inputs"):
            evidence.collect_android(root, "opt-in")
        output = root / "build/ci-qr-evidence"
        for variant in ("debug", "release"):
            self.assertEqual(json.loads((output / f"{variant}-check.json").read_text())["status"], "ACTUAL_PASS")
        self.assertTrue((output / ".flutter-plugins-dependencies").is_file())
        self.assertEqual(json.loads((output / "native-junit-summary.json").read_text())["executed_tests"], 5)
        hashed = [item["path"] for item in json.loads((output / "artifact-hashes.json").read_text())]
        self.assertIn("app/outputs/flutter-apk/app-debug.apk", hashed)
        self.assertIn("app/outputs/flutter-apk/app-release.apk", hashed)
        self.assertIn("app/outputs/mapping/release/mapping.txt", hashed)
        self.assertIn("starterkit_qr_barcode/test-results/testDebugUnitTest/TEST-Unit.xml", hashed)
        self.assertNotIn("artifact-hashes.json", hashed)


class IosEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.lock = self.root / "Podfile.lock"
        self.registrant = self.root / "GeneratedPluginRegistrant.m"
        self.link = self.root / "link.txt"
        self.inputs()

    def inputs(self, mode="default"):
        qr = mode == "opt-in"
        self.lock.write_text("PODS:\n  - starterkit_platform (1.0.0)\n" + ("  - starterkit_qr_barcode (1.0.0)\n" if qr else "") + "DEPENDENCIES:\nSPEC CHECKSUMS:\n")
        self.registrant.write_text("@implementation GeneratedPluginRegistrant\nregisterWithRegistry:\nStarterkitPlatformPlugin\n" + ("StarterkitQrBarcodePlugin\n" if qr else ""))
        self.link.write_text("FILE: Runner\nNM:\n U StarterkitPlatformPlugin\nOTOOL:\n@rpath/starterkit_platform.framework/starterkit_platform\n" +
                             ("@rpath/starterkit_qr_barcode.framework/starterkit_qr_barcode\nFILE: Frameworks/starterkit_qr_barcode.framework/starterkit_qr_barcode\nNM:\n T StarterkitQrBarcodePlugin\nOTOOL:\n" if qr else ""))

    def check(self, mode="default"):
        return evidence.check_ios(mode, self.lock, [self.registrant], self.link)

    def test_valid_default_and_linked_optin(self):
        self.assertEqual(self.check()["classification"], "default")
        self.inputs("opt-in")
        self.assertTrue(self.check("opt-in")["plugin_present_in_link_evidence"])

    def test_empty_lock_registrant_or_link_cannot_prove_absence(self):
        for path in (self.lock, self.registrant, self.link):
            self.inputs()
            path.write_text("")
            with self.subTest(path=path), self.assertRaises(ValueError):
                self.check()

    def test_optin_requires_each_lock_registration_framework_and_symbol(self):
        for path, old, new in ((self.lock, "starterkit_qr_barcode (1.0.0)", "starterkit_qr_barcode (2.0.0)"),
                               (self.registrant, "StarterkitQrBarcodePlugin", "OtherPlugin"),
                               (self.link, "StarterkitQrBarcodePlugin", "OtherPlugin"),
                               (self.link, " T StarterkitQrBarcodePlugin", " U StarterkitQrBarcodePlugin"),
                               (self.link, "@rpath/starterkit_qr_barcode.framework/starterkit_qr_barcode", "@rpath/other.framework/other")):
            self.inputs("opt-in")
            path.write_text(path.read_text().replace(old, new))
            with self.subTest(path=path, old=old), self.assertRaises(ValueError):
                self.check("opt-in")

    def test_default_detects_plugin_or_vendor_in_each_input(self):
        for path in (self.lock, self.registrant, self.link):
            for token in ("starterkit_qr_barcode", "com.google.zxing:core:3.5.4"):
                self.inputs()
                path.write_text(path.read_text() + token)
                with self.subTest(path=path, token=token), self.assertRaises(ValueError):
                    self.check()

    def test_ios_collector_stages_actual_app_binaries_registrants_and_link_capture(self):
        import plistlib
        app = self.root / "build/ios/iphoneos/Runner.app"
        app.mkdir(parents=True)
        (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "Runner"}))
        (app / "Runner").write_bytes(b"mock Mach-O")
        for name in ("starterkit_platform", "starterkit_qr_barcode"):
            framework = app / "Frameworks" / (name + ".framework")
            framework.mkdir(parents=True)
            (framework / name).write_bytes(b"mock framework Mach-O")
        ios = self.root / "ios/Runner"
        ios.mkdir(parents=True)
        self.inputs("opt-in")
        (self.root / "ios/Podfile.lock").write_bytes(self.lock.read_bytes())
        (ios / "GeneratedPluginRegistrant.m").write_bytes(self.registrant.read_bytes())
        (ios / "GeneratedPluginRegistrant.h").write_text("generated header")
        (self.root / ".flutter-plugins-dependencies").write_text(json.dumps({"plugins": {"ios": [{"name": "starterkit_platform"}, {"name": evidence.PLUGIN}]}}))

        def command(args, **kwargs):
            binary = Path(args[-1])
            if args[1] == "nm":
                text = " T StarterkitQrBarcodePlugin\n" if binary.name == evidence.PLUGIN else " T StarterkitPlatformPlugin\n"
            else:
                text = "@rpath/starterkit_platform.framework/starterkit_platform\n@rpath/starterkit_qr_barcode.framework/starterkit_qr_barcode\n"
            return subprocess.CompletedProcess(args, 0, text, "")

        with patch.object(evidence.subprocess, "run", side_effect=command), patch.object(evidence, "selected_inputs"):
            evidence.collect_ios(self.root, "opt-in", "release", app)
        output = self.root / "build/ci-qr-evidence/release"
        self.assertEqual(json.loads((output / "check.json").read_text())["status"], "ACTUAL_PASS")
        self.assertTrue((output / "Runner.app/Runner").is_file())
        self.assertTrue((output / "ios/Podfile.lock").is_file())
        self.assertTrue((output / "ios/Runner/GeneratedPluginRegistrant.m").is_file())
        hashed = [item["path"] for item in json.loads((output / "artifact-hashes.json").read_text())]
        self.assertIn("Runner.app/Frameworks/starterkit_qr_barcode.framework/starterkit_qr_barcode", hashed)
        self.assertIn("native-linkage.txt", hashed)


if __name__ == "__main__":
    unittest.main()

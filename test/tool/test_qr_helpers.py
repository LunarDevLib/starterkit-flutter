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
                             ("@rpath/starterkit_qr_barcode.framework/starterkit_qr_barcode\nFILE: Frameworks/starterkit_qr_barcode.framework/starterkit_qr_barcode\nNM:\n T StarterkitQrBarcodePlugin\nOTOOL:\n@rpath/starterkit_qr_barcode.framework/starterkit_qr_barcode\n" if qr else ""))
        self.link.write_text(self.link.read_text().replace("FILE: Runner\n", "FILE: Runner\nARCHS: arm64\n").replace(
            "FILE: Frameworks/starterkit_qr_barcode.framework/starterkit_qr_barcode\n",
            "FILE: Frameworks/starterkit_qr_barcode.framework/starterkit_qr_barcode\nARCHS: arm64\n"))

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

    def debug_link_fixture(self):
        # Reduced from PR6/run37115604364's real simulator artifact. The app
        # launcher loads Runner.debug.dylib; that image loads the QR framework.
        self.inputs("opt-in")
        self.link.write_text(
            "FILE: Runner\nNM:\n00000001000008b8 T ___debug_blank_executor_main\nSTDERR:\n\n"
            "OTOOL:\n/actual/Runner (architecture arm64):\n"
            "\t@rpath/Runner.debug.dylib (compatibility version 0.0.0, current version 0.0.0)\nSTDERR:\n\n"
            "FILE: Runner.debug.dylib\nNM:\n                 U _OBJC_CLASS_$__TtC19starterkit_platform24StarterkitPlatformPlugin\nSTDERR:\n\n"
            "OTOOL:\n/actual/Runner.debug.dylib (architecture arm64):\n"
            "\t@rpath/starterkit_platform.framework/starterkit_platform (compatibility version 1.0.0, current version 1.0.0)\n"
            "\t@rpath/starterkit_qr_barcode.framework/starterkit_qr_barcode (compatibility version 1.0.0, current version 1.0.0)\nSTDERR:\n\n"
            "FILE: Frameworks/starterkit_qr_barcode.framework/starterkit_qr_barcode\nNM:\n"
            "0000000000018b80 S _OBJC_CLASS_$__TtC21starterkit_qr_barcode25StarterkitQrBarcodePlugin\nSTDERR:\n\n"
            "OTOOL:\n/actual/starterkit_qr_barcode (architecture arm64):\n"
            "\t@rpath/starterkit_qr_barcode.framework/starterkit_qr_barcode (compatibility version 1.0.0, current version 1.0.0)\nSTDERR:\n\n"
        )
        self.link.write_text(self.link.read_text().replace("\nNM:", "\nARCHS: arm64\nNM:"))

    def test_real_xcode_debug_dylib_shape_preserves_defined_class_and_runner_load_chain(self):
        self.debug_link_fixture()
        self.assertTrue(self.check("opt-in")["plugin_present_in_link_evidence"])

    def test_debug_linkage_requires_both_runner_edges_not_an_unloaded_embedded_framework(self):
        for old, new in (("@rpath/Runner.debug.dylib", "@rpath/other.debug.dylib"),
                         ("\t@rpath/starterkit_qr_barcode.framework/starterkit_qr_barcode", "\t@rpath/other.framework/other"),
                         ("FILE: Runner.debug.dylib", "FILE: other.debug.dylib"),
                         ("FILE: Frameworks/starterkit_qr_barcode.framework/starterkit_qr_barcode", "FILE: Frameworks/other.framework/other")):
            self.debug_link_fixture()
            self.link.write_text(self.link.read_text().replace(old, new))
            with self.subTest(old=old), self.assertRaises(ValueError):
                self.check("opt-in")

    def test_real_debug_shape_rejects_undefined_only_or_symbols_outside_framework_nm(self):
        symbol = "0000000000018b80 S _OBJC_CLASS_$__TtC21starterkit_qr_barcode25StarterkitQrBarcodePlugin"
        for replacement in (symbol.replace(" S ", " U "), "", "StarterkitQrBarcodePlugin",
                            "STDERR:\n" + symbol, "OTOOL:\n" + symbol):
            self.debug_link_fixture()
            self.link.write_text(self.link.read_text().replace(symbol, replacement))
            with self.subTest(replacement=replacement), self.assertRaises(ValueError):
                self.check("opt-in")

    def test_real_debug_shape_rejects_missing_registration_and_baseline_controls(self):
        for path, token in ((self.registrant, "StarterkitQrBarcodePlugin"),
                            (self.registrant, "StarterkitPlatformPlugin"),
                            (self.lock, "starterkit_platform"),
                            (self.link, "StarterkitPlatformPlugin"),
                            (self.link, "starterkit_platform.framework")):
            self.debug_link_fixture()
            path.write_text(path.read_text().replace(token, "unrelated"))
            with self.subTest(path=path, token=token), self.assertRaises(ValueError):
                self.check("opt-in")

    def test_real_debug_shape_rejects_empty_truncated_and_duplicate_file_captures(self):
        for mutate in (
            lambda text: text.split("FILE: Frameworks/starterkit_qr_barcode.framework/")[0],
            lambda text: text.split("0000000000018b80 S")[0],
            lambda text: text.replace("FILE: Runner.debug.dylib\nARCHS: arm64\nNM:", "FILE: Runner.debug.dylib\nARCHS: arm64\n"),
            lambda text: text + "FILE: Runner\nNM:\n T fake\nOTOOL:\n@rpath/other\n",
        ):
            self.debug_link_fixture()
            self.link.write_text(mutate(self.link.read_text()))
            with self.subTest(mutate=mutate), self.assertRaises(ValueError):
                self.check("opt-in")

    def collector_inputs(self):
        import plistlib
        app = self.root / "build/ios/iphoneos/Runner.app"
        app.mkdir(parents=True)
        (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "Runner"}))
        (app / "Runner").write_bytes(b"mock Mach-O")
        (app / "Runner.debug.dylib").write_bytes(b"mock debug Mach-O")
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
            if args[1] == "lipo":
                text = " ".join(getattr(self, "collector_arches", ("arm64",))) + "\n"
            elif args[1] == "nm":
                text = " T StarterkitQrBarcodePlugin\n" if binary.name == evidence.PLUGIN else " T StarterkitPlatformPlugin\n"
            elif binary.name == "Runner":
                text = "@rpath/Runner.debug.dylib\n"
            else:
                text = "@rpath/starterkit_platform.framework/starterkit_platform\n@rpath/starterkit_qr_barcode.framework/starterkit_qr_barcode\n"
            return subprocess.CompletedProcess(args, 0, text, "")
        return app, command

    def test_ios_collector_stages_actual_app_binaries_registrants_and_link_capture(self):
        app, command = self.collector_inputs()
        with patch.object(evidence.subprocess, "run", side_effect=command), patch.object(evidence, "selected_inputs"):
            evidence.collect_ios(self.root, "opt-in", "release", app)
        output = self.root / "build/ci-qr-evidence/release"
        self.assertEqual(json.loads((output / "check.json").read_text())["status"], "ACTUAL_PASS")
        self.assertTrue((output / "Runner.app/Runner").is_file())
        self.assertTrue((output / "Runner.app/Runner.debug.dylib").is_file())
        self.assertIn("FILE: Runner.debug.dylib\n", (output / "native-linkage.txt").read_text())
        self.assertTrue((output / "ios/Podfile.lock").is_file())
        self.assertTrue((output / "ios/Runner/GeneratedPluginRegistrant.m").is_file())
        hashed = [item["path"] for item in json.loads((output / "artifact-hashes.json").read_text())]
        self.assertIn("Runner.app/Frameworks/starterkit_qr_barcode.framework/starterkit_qr_barcode", hashed)
        self.assertIn("native-linkage.txt", hashed)

    def test_ios_collector_fails_missing_empty_or_truncated_framework_binary(self):
        app, command = self.collector_inputs()
        binary = app / "Frameworks/starterkit_qr_barcode.framework/starterkit_qr_barcode"
        for content in (None, b"", b"truncated"):
            if content is None:
                binary.unlink()
            else:
                binary.write_bytes(content)

            def capture(args, **kwargs):
                if Path(args[-1]) == binary and content == b"truncated":
                    return subprocess.CompletedProcess(args, 1, "", "truncated Mach-O")
                return command(args, **kwargs)

            with self.subTest(content=content), patch.object(evidence.subprocess, "run", side_effect=capture), self.assertRaises((ValueError, subprocess.CalledProcessError)):
                evidence.collect_ios(self.root, "opt-in", "release", app)

    def test_ios_collector_missing_debug_dylib_cannot_fall_back_to_framework_presence(self):
        app, command = self.collector_inputs()
        (app / "Runner.debug.dylib").unlink()
        with patch.object(evidence.subprocess, "run", side_effect=command), self.assertRaises(ValueError):
            evidence.collect_ios(self.root, "opt-in", "release", app)

    def slice_fixture(self, debug=True, arches=("arm64", "x86_64")):
        self.inputs("opt-in")
        qr = "@rpath/starterkit_qr_barcode.framework/starterkit_qr_barcode"
        symbol = "0000000000018b80 S _OBJC_CLASS_$__TtC21starterkit_qr_barcode25StarterkitQrBarcodePlugin"

        def record(name, symbols, loads):
            return ("FILE: " + name + "\nARCHS: " + " ".join(arches) + "\nNM:\n"
                    + "".join(f"{name} (for architecture {arch}):\n{symbols}\n" for arch in arches)
                    + "STDERR:\n\nOTOOL:\n"
                    + "".join(f"{name} (architecture {arch}):\n{loads}\n" for arch in arches)
                    + "STDERR:\n\n")

        records = [record("Runner", " U StarterkitPlatformPlugin", "\t@rpath/Runner.debug.dylib" if debug else "\t" + qr)]
        if debug:
            records.append(record("Runner.debug.dylib", " U StarterkitPlatformPlugin", "\t" + qr))
        records.append(record("Frameworks/starterkit_qr_barcode.framework/starterkit_qr_barcode", symbol,
                              "\t@rpath/starterkit_platform.framework/starterkit_platform\n\t" + qr))
        self.link.write_text("".join(records))
        return records

    def test_slice_aware_valid_fat_direct_and_debug_paths_with_reordered_records(self):
        for debug in (False, True):
            records = self.slice_fixture(debug=debug)
            self.link.write_text("".join(reversed(records)))
            self.assertEqual(self.check("opt-in")["classification"], "opt-in")

    def test_missing_runner_cannot_be_impersonated_by_first_debug_dylib(self):
        records = self.slice_fixture()
        self.link.write_text("".join(records[1:]))
        with self.assertRaises(ValueError):
            self.check("opt-in")

    def test_disjoint_architectures_cannot_supply_different_load_edges(self):
        records = self.slice_fixture()
        records[0] = records[0].replace("\t@rpath/Runner.debug.dylib", "\t@rpath/unloaded.debug.dylib", 1)
        start = records[1].index("Runner.debug.dylib (architecture x86_64):")
        records[1] = records[1][:start] + records[1][start:].replace("\t@rpath/starterkit_qr_barcode.framework/starterkit_qr_barcode", "\t@rpath/unloaded.framework/unloaded", 1)
        self.link.write_text("".join(records))
        with self.assertRaises(ValueError):
            self.check("opt-in")

    def test_each_executable_slice_requires_each_edge_and_its_defined_qr_class(self):
        for arch in ("arm64", "x86_64"):
            for missing in ("runner-edge", "debug-edge", "defined-class"):
                records = self.slice_fixture()
                index = {"runner-edge": 0, "debug-edge": 1, "defined-class": 2}[missing]
                header = f"(for architecture {arch}):" if missing == "defined-class" else f"(architecture {arch}):"
                start = records[index].index(header)
                before, after = records[index][:start], records[index][start:]
                if missing == "defined-class":
                    after = after.replace(" S _OBJC_CLASS_", " U _OBJC_CLASS_", 1)
                else:
                    token = "@rpath/Runner.debug.dylib" if missing == "runner-edge" else "@rpath/starterkit_qr_barcode.framework/starterkit_qr_barcode"
                    after = after.replace(token, "@rpath/unloaded", 1)
                records[index] = before + after
                self.link.write_text("".join(records))
                with self.subTest(arch=arch, missing=missing), self.assertRaises(ValueError):
                    self.check("opt-in")

    def test_missing_image_slice_or_nm_otool_architecture_mismatch_fails(self):
        import re
        for index in (0, 1, 2):
            for label in ("NM", "OTOOL"):
                records = self.slice_fixture()
                marker = "for architecture" if label == "NM" else "architecture"
                section = records[index].index(label + ":\n")
                before, after = records[index][:section], records[index][section:]
                after = re.sub(r"(?ms)^[^\n]+ \(" + marker + r" x86_64\):\n.*?(?=^STDERR:|\Z)", "", after, count=1)
                records[index] = before + after
                self.link.write_text("".join(records))
                with self.subTest(index=index, label=label), self.assertRaises(ValueError):
                    self.check("opt-in")

    def test_duplicate_architecture_blocks_inventories_and_tool_sections_fail(self):
        for token, replacement in (("ARCHS: arm64 x86_64", "ARCHS: arm64 arm64"),
                                   ("ARCHS: arm64 x86_64", "ARCHS: arm64 x86_64\nARCHS: arm64 x86_64"),
                                   ("(for architecture x86_64):", "(for architecture arm64):"),
                                   ("(architecture x86_64):", "(architecture arm64):"),
                                   ("STDERR:\n\nOTOOL:", "STDERR:\n\nNM:\n T fake\nSTDERR:\n\nOTOOL:")):
            records = self.slice_fixture()
            self.link.write_text("".join(records).replace(token, replacement, 1))
            with self.subTest(token=token), self.assertRaises(ValueError):
                self.check("opt-in")

    def test_thin_release_requires_explicit_single_slice_inventory(self):
        import re
        records = self.slice_fixture(debug=False, arches=("arm64",))
        text = re.sub(r"(?m)^.+ \((?:for )?architecture arm64\):\n", "", "".join(records))
        self.link.write_text(text)
        self.assertEqual(self.check("opt-in")["classification"], "opt-in")
        for wrong in (text.replace("ARCHS: arm64\n", ""), text.replace("ARCHS: arm64", "ARCHS: arm64 x86_64")):
            self.link.write_text(wrong)
            with self.assertRaises(ValueError):
                self.check("opt-in")

    def test_labelled_fat_captures_cannot_hide_slices_without_an_explicit_inventory(self):
        self.slice_fixture()
        self.link.write_text(self.link.read_text().replace("ARCHS: arm64 x86_64\n", ""))
        with self.assertRaises(ValueError):
            self.check("opt-in")

    def test_collector_records_lipo_inventory_and_calls_both_tools_for_every_slice(self):
        self.collector_arches = ("arm64", "x86_64")
        app, command = self.collector_inputs()
        calls = []

        def capture(args, **kwargs):
            calls.append(args)
            return command(args, **kwargs)

        with patch.object(evidence.subprocess, "run", side_effect=capture), patch.object(evidence, "selected_inputs"):
            evidence.collect_ios(self.root, "opt-in", "simulator", app)
        text = (self.root / "build/ci-qr-evidence/simulator/native-linkage.txt").read_text()
        self.assertEqual(text.count("ARCHS: arm64 x86_64\n"), 4)
        for binary in ("Runner", "Runner.debug.dylib", "starterkit_platform", evidence.PLUGIN):
            for arch in self.collector_arches:
                for tool in ("nm", "otool"):
                    self.assertEqual(sum(args[1] == tool and args[2:4] == ["-arch", arch] and Path(args[-1]).name == binary for args in calls), 1)

    def test_collector_rejects_invalid_or_failed_lipo_and_empty_wrong_arch_tool_output(self):
        app, command = self.collector_inputs()
        for failure in ("lipo-exit", "empty-inventory", "duplicate-inventory", "unsafe-inventory", "wrong-tool-arch", "empty-tool"):
            def capture(args, **kwargs):
                if args[1] == "lipo":
                    if failure == "lipo-exit":
                        return subprocess.CompletedProcess(args, 1, "", "bad binary")
                    if failure in ("empty-inventory", "duplicate-inventory", "unsafe-inventory"):
                        text = {"empty-inventory": "", "duplicate-inventory": "arm64 arm64", "unsafe-inventory": "-arch"}[failure]
                        return subprocess.CompletedProcess(args, 0, text, "")
                elif failure in ("wrong-tool-arch", "empty-tool"):
                    text = "binary (architecture x86_64):\n T fake\n" if failure == "wrong-tool-arch" else ""
                    return subprocess.CompletedProcess(args, 0, text, "")
                return command(args, **kwargs)
            with self.subTest(failure=failure), patch.object(evidence.subprocess, "run", side_effect=capture), self.assertRaises((ValueError, subprocess.CalledProcessError)):
                evidence.collect_ios(self.root, "opt-in", "simulator", app)

    def test_collector_captures_explicit_thin_release_direct_linkage(self):
        app, command = self.collector_inputs()
        (app / "Runner.debug.dylib").unlink()

        def capture(args, **kwargs):
            if args[1] == "otool" and Path(args[-1]).name == "Runner":
                return subprocess.CompletedProcess(args, 0, "@rpath/starterkit_qr_barcode.framework/starterkit_qr_barcode\n", "")
            return command(args, **kwargs)

        with patch.object(evidence.subprocess, "run", side_effect=capture), patch.object(evidence, "selected_inputs"):
            evidence.collect_ios(self.root, "opt-in", "release", app)
        output = self.root / "build/ci-qr-evidence/release"
        self.assertEqual(json.loads((output / "check.json").read_text())["status"], "ACTUAL_PASS")
        self.assertEqual((output / "native-linkage.txt").read_text().count("ARCHS: arm64\n"), 3)


if __name__ == "__main__":
    unittest.main()

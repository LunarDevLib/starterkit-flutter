import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tool"))
import ci_impact  # noqa: E402


class CiImpactClassifierTest(unittest.TestCase):
    def test_docs_and_known_pure_package_changes_are_fast(self):
        for path in ("README.md", "AGENTS.md", "docs/CI.md", "packages/starterkit_preferences/lib/prefs.dart", "packages/starterkit_platform/test/share_test.dart"):
            with self.subTest(path=path):
                result = ci_impact.classify_paths([path])
                self.assertFalse(result["full"])
                self.assertFalse(any(result[name] for name in ci_impact.FLAG_NAMES[1:]))

    def test_android_only_and_ios_only_routes(self):
        android = ci_impact.classify_paths(["packages/starterkit_platform/android/src/Push.kt"])
        self.assertEqual(
            {"full": False, "android_source": True, "ios_source": False, "renamed_android": False,
             "renamed_ios": False, "qr_android": False, "qr_ios": False},
            {key: android[key] for key in ci_impact.FLAG_NAMES},
        )
        ios = ci_impact.classify_paths(["packages/starterkit_platform/ios/Classes/Push.swift"])
        self.assertTrue(ios["ios_source"])
        self.assertFalse(ios["android_source"])

    def test_qr_platforms_and_shared_fixtures(self):
        android = ci_impact.classify_paths(["packages/starterkit_qr_barcode/android/src/Push.kt"])
        self.assertTrue(android["android_source"] and android["renamed_android"] and android["qr_android"])
        self.assertFalse(android["qr_ios"])
        ios = ci_impact.classify_paths(["packages/starterkit_qr_barcode/ios/Classes/Push.swift"])
        self.assertTrue(ios["ios_source"] and ios["renamed_ios"] and ios["qr_ios"])
        shared = ci_impact.classify_paths(["test/tool/fixtures/qr_consumer/main.dart"])
        for flag in ci_impact.FLAG_NAMES[1:]:
            self.assertTrue(shared[flag], flag)

    def test_native_plugin_metadata_selects_corresponding_renamed_platform(self):
        for path in (
            "packages/starterkit_platform/android/src/main/AndroidManifest.xml",
            "packages/starterkit_platform/android/build.gradle.kts",
            "packages/starterkit_platform/android/gradle/wrapper/gradle-wrapper.properties",
        ):
            with self.subTest(path=path):
                route = ci_impact.classify_paths([path])
                self.assertFalse(route["full"])
                self.assertTrue(route["android_source"] and route["renamed_android"])
                self.assertFalse(route["ios_source"] or route["renamed_ios"] or route["qr_android"] or route["qr_ios"])
        for path in (
            "packages/starterkit_platform/ios/Package.swift",
            "packages/starterkit_platform/ios/Classes/Starterkit.podspec",
            "packages/starterkit_platform/ios/Runner.xcodeproj/project.pbxproj",
            "packages/starterkit_platform/ios/Runner/Info.plist",
            "packages/starterkit_platform/starterkit_platform.podspec",
        ):
            with self.subTest(path=path):
                route = ci_impact.classify_paths([path])
                self.assertFalse(route["full"])
                self.assertTrue(route["ios_source"] and route["renamed_ios"])
                self.assertFalse(route["android_source"] or route["renamed_android"] or route["qr_android"] or route["qr_ios"])
        qr_config = ci_impact.classify_paths(["packages/starterkit_qr_barcode/android/src/main/AndroidManifest.xml"])
        self.assertTrue(qr_config["android_source"] and qr_config["renamed_android"] and qr_config["qr_android"])
        self.assertFalse(qr_config["ios_source"] or qr_config["qr_ios"])

    def test_native_code_is_source_only_but_unknown_metadata_is_full(self):
        android = ci_impact.classify_paths(["packages/starterkit_platform/android/src/main/kotlin/example/PushPlugin.kt"])
        self.assertTrue(android["android_source"])
        self.assertFalse(android["renamed_android"] or android["ios_source"] or android["qr_android"])
        ios = ci_impact.classify_paths(["packages/starterkit_platform/ios/Classes/PushPlugin.swift"])
        self.assertTrue(ios["ios_source"])
        self.assertFalse(ios["renamed_ios"] or ios["android_source"] or ios["qr_ios"])
        self.assertTrue(ci_impact.classify_paths(["packages/starterkit_platform/android/unknown.yaml"])["full"])

    def test_unknown_config_and_tool_changes_force_full(self):
        for path in ("packages/new_package/lib/file.dart", "pubspec.yaml", "packages/starterkit_platform/pubspec.yaml",
                     "tool/new_helper.py",
                     "test/tool/test_ci_impact.py", "test/ci_source_test.dart", "analysis_options.yaml", ".github/workflows/flutter.yml"):
            with self.subTest(path=path):
                self.assertTrue(ci_impact.classify_paths([path])["full"])

    def test_platform_baseline_and_qr_helper_tests_cover_intended_platforms(self):
        android = ci_impact.classify_paths(["test/tool/test_verify_android_baseline.py"])
        self.assertTrue(android["android_source"] and android["renamed_android"] and android["qr_android"])
        self.assertFalse(android["ios_source"])
        ios = ci_impact.classify_paths(["test/tool/test_verify_ios_baseline.py"])
        self.assertTrue(ios["ios_source"] and ios["renamed_ios"] and ios["qr_ios"])
        self.assertFalse(ios["android_source"])
        helpers = ci_impact.classify_paths(["test/tool/test_qr_helpers.py"])
        for flag in ci_impact.FLAG_NAMES[1:]:
            self.assertTrue(helpers[flag], flag)

    def test_empty_docs_union_and_manual_full(self):
        self.assertFalse(ci_impact.classify_paths([])["full"])
        docs_union = ci_impact.classify_paths(["README.md", "docs/CI.md"])
        self.assertFalse(docs_union["full"])
        android_union = ci_impact.classify_paths(["docs/CI.md", "android/app/build.gradle"])
        self.assertTrue(android_union["android_source"] and android_union["renamed_android"] and android_union["qr_android"])
        self.assertTrue(all(ci_impact.classify_paths([], force_full=True)[flag] for flag in ci_impact.FLAG_NAMES))

    def test_unsafe_malformed_and_unicode_invalid_paths_force_full(self):
        for path in ("/etc/passwd", "../outside", "a/../../b", "bad\\path", "bad\ud800", "bad\nname"):
            with self.subTest(path=repr(path)):
                self.assertTrue(ci_impact.classify_paths([path])["full"])
        self.assertTrue(ci_impact.classify_paths([None])["full"])


class CiImpactGitEventTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.repo = Path(self.temp.name)
        self._git("init", "-q")
        self._git("config", "user.email", "ci@example.test")
        self._git("config", "user.name", "CI Test")
        (self.repo / "mystery.txt").write_text("base\n")
        (self.repo / "README.md").write_text("docs\n")
        self.base = self._commit("base")

    def tearDown(self):
        self.temp.cleanup()

    def _git(self, *args):
        return subprocess.run(["git", "-C", str(self.repo), *args], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout.decode().strip()

    def _commit(self, message):
        self._git("add", "--all")
        self._git("commit", "-qm", message)
        return self._git("rev-parse", "HEAD")

    def test_pull_request_uses_merge_base_and_nul_paths(self):
        (self.repo / "docs" ).mkdir()
        (self.repo / "docs" / "guide.md").write_text("new docs")
        head = self._commit("add docs")
        event = {"pull_request": {"base": {"sha": self.base}, "head": {"sha": head}}}
        paths, reason = ci_impact.detect_paths(str(self.repo), "pull_request", event)
        self.assertEqual(["docs/guide.md"], paths)
        self.assertIn("merge-base", reason)
        self.assertFalse(ci_impact.classify_paths(paths)["full"])

    def test_rename_keeps_both_endpoints_and_unknown_origin_forces_full(self):
        (self.repo / "docs").mkdir()
        self._git("mv", "mystery.txt", "docs/new.md")
        head = self._commit("rename unknown into doc")
        event = {"pull_request": {"base": {"sha": self.base}, "head": {"sha": head}}}
        paths, _ = ci_impact.detect_paths(str(self.repo), "pull_request", event)
        self.assertIn("mystery.txt", paths)
        self.assertIn("docs/new.md", paths)
        self.assertTrue(ci_impact.classify_paths(paths)["full"])

    def test_copy_from_unchanged_source_is_detected_with_both_names(self):
        (self.repo / "docs").mkdir()
        (self.repo / "docs" / "copied.md").write_text((self.repo / "mystery.txt").read_text())
        head = self._commit("copy unchanged unknown source")
        event = {"pull_request": {"base": {"sha": self.base}, "head": {"sha": head}}}
        paths, _ = ci_impact.detect_paths(str(self.repo), "pull_request", event)
        self.assertIn("mystery.txt", paths)
        self.assertIn("docs/copied.md", paths)
        self.assertTrue(ci_impact.classify_paths(paths)["full"])

    def test_deleted_unknown_and_push_diff_are_complete(self):
        (self.repo / "mystery.txt").unlink()
        after = self._commit("delete unknown")
        push_paths, _ = ci_impact.detect_paths(str(self.repo), "push", {"before": self.base, "after": after})
        self.assertEqual(["mystery.txt"], push_paths)
        self.assertTrue(ci_impact.classify_paths(push_paths)["full"])

    def test_invalid_zero_sha_or_event_uncertainty_raises_for_full_fallback(self):
        with self.assertRaises(ValueError):
            ci_impact.detect_paths(str(self.repo), "push", {"before": "0" * 40, "after": self.base})
        with self.assertRaises(ValueError):
            ci_impact.detect_paths(str(self.repo), "schedule", {})
        with self.assertRaises(ValueError):
            ci_impact.detect_paths(str(self.repo), "pull_request", {})

    def test_name_status_parser_preserves_rename_copy_both_names(self):
        rename = ci_impact._parse_name_status_z(b"R100\0old path\0new path\0")
        copy = ci_impact._parse_name_status_z(b"C075\0unknown-source\0README.md\0")
        self.assertEqual(["old path", "new path"], rename)
        self.assertEqual(["unknown-source", "README.md"], copy)
        self.assertTrue(ci_impact.classify_paths(copy)["full"])
        with self.assertRaises(ValueError):
            ci_impact._parse_name_status_z(b"R100\0only-old\0")

    def test_cli_bad_event_json_emits_exact_full_schema(self):
        with tempfile.TemporaryDirectory() as temp:
            event_file = Path(temp) / "event.json"
            output = Path(temp) / "route.json"
            event_file.write_text("{")
            status = ci_impact.main(["--repo", str(self.repo), "--event-name", "push", "--event-path", str(event_file), "--output-file", str(output)])
            self.assertEqual(0, status)
            route = json.loads(output.read_text())
            self.assertEqual(set(ci_impact.OUTPUT_KEYS), set(route))
            self.assertTrue(all(type(route[flag]) is bool and route[flag] for flag in ci_impact.FLAG_NAMES))
            self.assertTrue(route["reason"])

    def test_cli_unrecognized_or_missing_history_fails_full_not_fast(self):
        with tempfile.TemporaryDirectory() as temp:
            event_file = Path(temp) / "event.json"
            output = Path(temp) / "route.json"
            for event_name, payload in (("workflow_dispatch", {}), ("push", {"before": "0" * 40, "after": self.base})):
                event_file.write_text(json.dumps(payload))
                status = ci_impact.main(["--repo", str(self.repo), "--event-name", event_name, "--event-path", str(event_file), "--output-file", str(output)])
                self.assertEqual(0, status)
                route = json.loads(output.read_text())
                self.assertTrue(all(route[flag] for flag in ci_impact.FLAG_NAMES))


if __name__ == "__main__":
    unittest.main()

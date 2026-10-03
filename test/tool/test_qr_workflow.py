"""Focused wiring regressions without adding a YAML runtime dependency to CI."""

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = (ROOT / ".github/workflows/flutter.yml").read_text()


def job(name):
    match = re.search(r"(?ms)^  " + re.escape(name) + r":\n(.*?)(?=^  [\w-]+:|\Z)", WORKFLOW)
    assert match is not None, name
    return match.group(1)


class QrWorkflowTests(unittest.TestCase):
    def test_only_main_push_pr_and_manual_triggers(self):
        self.assertIn("  push:\n    branches: [main]", WORKFLOW)
        self.assertIn("  pull_request:\n", WORKFLOW)
        self.assertIn("  workflow_dispatch:\n", WORKFLOW)
        self.assertNotIn("branches: [feat/", WORKFLOW)

    def test_baseline_source_and_renamed_android_preserved(self):
        for name in ("verify", "renamed-copy"):
            text = job(name)
            for command in ("flutter pub get --enforce-lockfile", "flutter gen-l10n", "flutter analyze",
                            "flutter test", "flutter build apk --debug", "flutter build apk --release",
                            "--variant debug", "--variant release", "collect-android --mode default"):
                self.assertIn(command, text, (name, command))
            self.assertIn("build/ci-qr-evidence/", text)
            self.assertIn("--destination \"$consumer\"", text)
            self.assertIn("--target test/tool/fixtures/qr_consumer/main.dart", text)
            self.assertIn(":starterkit_qr_barcode:testDebugUnitTest", text)
            self.assertIn("collect-android --mode opt-in", text)
        self.assertIn("canonical template unexpectedly passed product readiness", job("verify"))
        self.assertIn("dart run tool/validate_template.dart --release-readiness", job("renamed-copy"))

    def test_both_ios_identities_and_variants_default_and_optin(self):
        for name, mode in (("ios-simulator", "default"), ("qr-opt-in-ios", "opt-in")):
            text = job(name)
            for variant in ("simulator", "release"):
                self.assertEqual(text.count(f"collect-ios --mode {mode} --variant {variant}"), 2)
            self.assertIn("--bundle-id com.example.flutterstarterkit", text)
            self.assertIn("--bundle-id dev.example.sampleportable", text)
            self.assertIn("--minimum-os-version 15.0 --variant debug", text)
            self.assertIn("--minimum-os-version 15.0 --variant release", text)
            self.assertIn("--release-readiness", text)
        self.assertEqual(job("qr-opt-in-ios").count("--target test/tool/fixtures/qr_consumer/main.dart"), 4)

    def test_qr_swift_fixtures_early_and_dart_locked_checks_retained(self):
        swift = job("swift-policy")
        self.assertIn("swift test --package-path packages/starterkit_qr_barcode/ios", swift)
        self.assertLess(swift.index("starterkit_qr_barcode"), swift.index("starterkit_preferences"))
        self.assertIn("needs: [verify, swift-policy]", job("ios-simulator"))
        self.assertIn("needs: [verify, swift-policy, ios-simulator]", job("qr-opt-in-ios"))
        for name in ("verify", "renamed-copy", "ios-simulator"):
            text = job(name)
            self.assertIn("packages/starterkit_qr_barcode", text)
            self.assertIn("flutter pub get --enforce-lockfile", text)
            self.assertIn("flutter analyze --no-pub", text)
            self.assertIn("flutter test --no-pub", text)

    def test_qr_locked_resolution_precedes_root_checks_in_each_baseline_lane(self):
        qr = "packages/starterkit_qr_barcode"
        source = job("verify")
        resolve = source.index("working-directory: " + qr)
        locked_pub = source.index("run: flutter pub get --enforce-lockfile", resolve)
        for command in ("dart format --output=none", "- run: flutter analyze\n", "name: Test template or consuming product"):
            self.assertLess(locked_pub, source.index(command), command)

        renamed = job("renamed-copy")
        checks = renamed.split("- name: Validate renamed copy\n", 1)[1].split("\n      - name:", 1)[0]
        locked_pub = checks.index(f"(cd {qr} && flutter pub get --enforce-lockfile")
        for command in ("dart format --output=none", "flutter analyze\n", "flutter test --exclude-tags template-only"):
            self.assertLess(locked_pub, checks.index(command), command)
        self.assertIn(f"(cd {qr} && flutter analyze --no-pub && flutter test --no-pub)", checks)

        ios = job("ios-simulator")
        source_checks, renamed_checks = ios.split("- name: Bootstrap fresh copy and iOS simulator build", 1)
        for checks, test_command in ((source_checks, "flutter test\n"), (renamed_checks, "flutter test --exclude-tags template-only")):
            locked_pub = checks.index(f"(cd {qr} && flutter pub get --enforce-lockfile")
            for command in ("dart format --output=none", "flutter analyze\n", test_command):
                self.assertLess(locked_pub, checks.index(command), command)

    def test_uploads_follow_default_evidence_and_never_upload_whole_build_tree(self):
        for name, capture, upload in (
            ("verify", "Capture default QR absence evidence", "Upload default Android QR absence evidence"),
            ("renamed-copy", "Capture renamed default QR absence evidence", "Upload renamed default Android QR absence evidence"),
        ):
            text = job(name)
            self.assertLess(text.index(capture), text.index(upload))
        self.assertNotRegex(WORKFLOW, r"path:.*qr-[^\n]*consumer/build/\s*$")
        self.assertNotRegex(WORKFLOW, r"hashes --root build(?:\s|$)")


if __name__ == "__main__":
    unittest.main()

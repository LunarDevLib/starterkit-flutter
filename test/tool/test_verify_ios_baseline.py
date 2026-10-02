import contextlib
import io
import plistlib
import tempfile
import unittest
from pathlib import Path

from tool.verify_ios_baseline import (
    BaselineError,
    main,
    resolve_runner_bundle_id,
    verify_plist,
)


BASELINE = {
    "CFBundleIdentifier": "com.example.flutterstarterkit",
    "CFBundleDisplayName": "Flutter Starter Kit",
    "CFBundleURLTypes": [{"CFBundleURLSchemes": ["flutter-starterkit"]}],
}


class VerifyIOSBaselineTest(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.path = Path(self.temp_dir.name) / "Info.plist"

    def write_plist(self, value, fmt=plistlib.FMT_XML):
        with self.path.open("wb") as output:
            plistlib.dump(value, output, fmt=fmt)

    def write_xcode_project(self, bundle_ids, *, duplicate_runner=False):
        project_path = Path(self.temp_dir.name) / "project.pbxproj"
        configurations = "\n".join(
            f'''\t\t{config_id} /* {name} */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = {bundle_id};
\t\t\t}};
\t\t\tname = {name};
\t\t}};'''
            for config_id, name, bundle_id in zip(
                ("C001", "C002", "C003"),
                ("Debug", "Release", "Profile"),
                bundle_ids,
            )
        )
        project = f'''/* Begin PBXGroup section */
\t\tA000 /* Runner */ = {{
\t\t\tisa = PBXGroup;
\t\t}};
/* End PBXGroup section */
/* Begin PBXNativeTarget section */
\t\tA001 /* Runner */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = B001 /* Build configuration list for PBXNativeTarget "Runner" */;
\t\t}};
\t\tA002 /* RunnerTests */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = B002 /* Build configuration list for PBXNativeTarget "RunnerTests" */;
\t\t}};
/* End PBXNativeTarget section */
/* Begin XCConfigurationList section */
\t\tB001 /* Build configuration list for PBXNativeTarget "Runner" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\tC001 /* Debug */,
\t\t\t\tC002 /* Release */,
\t\t\t\tC003 /* Profile */,
\t\t\t);
\t\t}};
\t\tB002 /* Build configuration list for PBXNativeTarget "RunnerTests" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\tT001 /* Debug */,
\t\t\t);
\t\t}};
/* End XCConfigurationList section */
/* Begin XCBuildConfiguration section */
{configurations}
\t\tT001 /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.example.product.RunnerTests;
\t\t\t}};
\t\t}};
/* End XCBuildConfiguration section */
'''
        if duplicate_runner:
            project += '''\t\tA003 /* Runner */ = {
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = B001 /* Build configuration list for PBXNativeTarget "Runner" */;
\t\t};
'''
        project_path.write_text(project, encoding="utf-8")
        return project_path

    def test_resolves_consistent_runner_identity_and_excludes_runner_tests(self):
        for bundle_id in (
            "com.example.flutterstarterkit",
            "dev.example.productapp",
        ):
            with self.subTest(bundle_id=bundle_id):
                project = self.write_xcode_project([bundle_id] * 3)
                self.assertEqual(resolve_runner_bundle_id(project), bundle_id)

    def test_rejects_runner_configuration_identity_drift(self):
        project = self.write_xcode_project(
            ["dev.example.productapp", "dev.example.productapp", "dev.example.other"]
        )
        with self.assertRaisesRegex(BaselineError, "configurations disagree"):
            resolve_runner_bundle_id(project)

    def test_cli_uses_xcode_identity_and_rejects_stale_explicit_identity(self):
        bundle_id = "dev.example.productapp"
        project = self.write_xcode_project([bundle_id] * 3)
        self.write_plist(
            {
                **BASELINE,
                "CFBundleIdentifier": bundle_id,
                "MinimumOSVersion": "15.0",
            }
        )
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            result = main(
                [
                    "--plist",
                    str(self.path),
                    "--xcode-project",
                    str(project),
                    "--minimum-os-version",
                    "15.0",
                ]
            )
        self.assertEqual(result, 0)
        self.assertIn("Verified iOS Info.plist baseline", stdout.getvalue())

        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            result = main(
                [
                    "--plist",
                    str(self.path),
                    "--xcode-project",
                    str(project),
                    "--bundle-id",
                    "com.example.flutterstarterkit",
                ]
            )
        self.assertEqual(result, 1)
        self.assertIn("does not match the Xcode Runner target", stderr.getvalue())

    def test_rejects_missing_or_ambiguous_runner_target(self):
        missing = Path(self.temp_dir.name) / "missing-runner.pbxproj"
        missing.write_text("/* empty project */", encoding="utf-8")
        with self.assertRaisesRegex(BaselineError, "exactly one Runner native target"):
            resolve_runner_bundle_id(missing)

        ambiguous = self.write_xcode_project(
            ["dev.example.productapp"] * 3, duplicate_runner=True
        )
        with self.assertRaisesRegex(BaselineError, "exactly one Runner native target"):
            resolve_runner_bundle_id(ambiguous)

    def test_accepts_source_and_renamed_bundle_ids(self):
        for bundle_id in ("com.example.flutterstarterkit", "dev.example.portableapp"):
            with self.subTest(bundle_id=bundle_id):
                self.write_plist({**BASELINE, "CFBundleIdentifier": bundle_id})
                self.assertIsNone(verify_plist(self.path, bundle_id))

    def test_accepts_binary_plist(self):
        self.write_plist(
            {**BASELINE, "MinimumOSVersion": "15.0"}, fmt=plistlib.FMT_BINARY
        )
        self.assertEqual(verify_plist(self.path), "15.0")

    def test_minimum_os_version_is_informational(self):
        self.write_plist({**BASELINE, "MinimumOSVersion": "12.0"})
        self.assertEqual(verify_plist(self.path), "12.0")

    def test_expected_minimum_os_version_requires_exact_match(self):
        self.write_plist({**BASELINE, "MinimumOSVersion": "15.0"})
        self.assertEqual(verify_plist(self.path, expected_minimum_os_version="15.0"), "15.0")
        with self.assertRaisesRegex(BaselineError, "must equal the expected value"):
            verify_plist(self.path, expected_minimum_os_version="15")

    def test_expected_minimum_os_version_rejects_missing_or_nonnumeric_value(self):
        self.write_plist(BASELINE)
        with self.assertRaisesRegex(BaselineError, "must equal the expected value"):
            verify_plist(self.path, expected_minimum_os_version="15.0")
        with self.assertRaisesRegex(BaselineError, "must be numeric"):
            verify_plist(self.path, expected_minimum_os_version="15beta")

    def test_rejects_each_activation_only_key(self):
        forbidden_keys = (
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
        )
        for key in forbidden_keys:
            with self.subTest(key=key):
                self.write_plist({**BASELINE, key: "enabled"})
                with self.assertRaisesRegex(BaselineError, key):
                    verify_plist(self.path)

    def test_rejects_forbidden_key_nested_in_dictionary(self):
        self.write_plist({**BASELINE, "Nested": {"NSCameraUsageDescription": "camera"}})
        with self.assertRaisesRegex(BaselineError, "NSCameraUsageDescription"):
            verify_plist(self.path)

    def test_rejects_unlisted_privacy_usage_description_keys(self):
        for key in ("NSMicrophoneUsageDescription", "NSBluetoothAlwaysUsageDescription"):
            with self.subTest(key=key):
                self.write_plist({**BASELINE, key: "optional capability"})
                with self.assertRaisesRegex(BaselineError, key):
                    verify_plist(self.path)

    def test_rejects_nested_background_and_network_activation_keys(self):
        for key in ("UIBackgroundModes", "NSAppTransportSecurity", "NSBonjourServices"):
            with self.subTest(key=key):
                self.write_plist({**BASELINE, "Nested": [{key: "enabled"}]})
                with self.assertRaisesRegex(BaselineError, key):
                    verify_plist(self.path)

    def test_rejects_bundle_identity_mismatch(self):
        self.write_plist(BASELINE)
        with self.assertRaisesRegex(BaselineError, "CFBundleIdentifier"):
            verify_plist(self.path, "dev.example.different")

    def test_rejects_missing_path(self):
        with self.assertRaisesRegex(BaselineError, "does not exist"):
            verify_plist(self.path)

    def test_rejects_malformed_plist(self):
        self.path.write_bytes(b"not a plist")
        with self.assertRaisesRegex(BaselineError, "cannot parse plist"):
            verify_plist(self.path)

    def test_rejects_malformed_xml_plist(self):
        self.path.write_bytes(b"<?xml version='1.0'?><plist><dict>")
        with self.assertRaisesRegex(BaselineError, "cannot parse plist"):
            verify_plist(self.path)

    def test_rejects_non_dictionary_root(self):
        self.write_plist(["not", "a", "dictionary"])
        with self.assertRaisesRegex(BaselineError, "root must be a dictionary"):
            verify_plist(self.path)

    def test_rejects_non_string_minimum_os_version(self):
        self.write_plist({**BASELINE, "MinimumOSVersion": 15})
        with self.assertRaisesRegex(BaselineError, "must be a string"):
            verify_plist(self.path)


if __name__ == "__main__":
    unittest.main()

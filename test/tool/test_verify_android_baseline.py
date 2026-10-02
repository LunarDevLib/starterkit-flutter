import unittest

from tool.verify_android_baseline import BaselineError, verify_manifest_xml


ANDROID = 'xmlns:android="http://schemas.android.com/apk/res/android"'


def manifest(
    permissions="",
    components="",
    min_sdk="24",
    allow_backup="false",
    package=None,
    declarations="",
):
    package_attribute = f' package="{package}"' if package is not None else ""
    return f'''<manifest {ANDROID}{package_attribute}>
  {permissions}
  {declarations}
  <uses-sdk android:minSdkVersion="{min_sdk}" />
  <application android:allowBackup="{allow_backup}">
    <activity android:name=".MainActivity" />
    {components}
  </application>
</manifest>'''


class VerifyAndroidBaselineTest(unittest.TestCase):
    def test_debug_allows_only_flutter_debug_internet_permission(self):
        permissions, components = verify_manifest_xml(
            manifest('<uses-permission android:name="android.permission.INTERNET" />'),
            "debug",
        )
        self.assertEqual(permissions, {"android.permission.INTERNET"})
        self.assertEqual(components, ["activity=.MainActivity"])

    def test_release_requires_zero_permissions(self):
        permissions, _ = verify_manifest_xml(manifest(), "release")
        self.assertEqual(permissions, set())

    def test_accepts_exact_signature_guard_for_neutral_and_renamed_packages(self):
        for variant, package, platform_permissions in (
            ("debug", "org.example.sample", '<uses-permission android:name="android.permission.INTERNET" />'),
            ("release", "dev.example.sampleportable", ""),
        ):
            guard = f"{package}.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION"
            for protection in ("signature", "2", "0x2", "0x00000002"):
                with self.subTest(variant=variant, package=package, protection=protection):
                    permissions, _ = verify_manifest_xml(
                        manifest(
                            permissions=(
                                platform_permissions
                                + f'<uses-permission android:name="{guard}" />'
                            ),
                            package=package,
                            declarations=(
                                f'<permission android:name="{guard}" '
                                f'android:protectionLevel="{protection}" />'
                            ),
                        ),
                        variant,
                    )
                    expected = {guard}
                    if variant == "debug":
                        expected.add("android.permission.INTERNET")
                    self.assertEqual(permissions, expected)

    def test_rejects_guard_from_a_different_package_namespace(self):
        package = "org.example.sample"
        foreign = "org.other.app.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION"
        with self.assertRaisesRegex(BaselineError, "manifest package's exact"):
            verify_manifest_xml(
                manifest(
                    permissions=f'<uses-permission android:name="{foreign}" />',
                    package=package,
                    declarations=(
                        f'<permission android:name="{foreign}" '
                        'android:protectionLevel="signature" />'
                    ),
                ),
                "release",
            )

    def test_rejects_missing_guard_declaration(self):
        package = "org.example.sample"
        guard = f"{package}.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION"
        with self.assertRaisesRegex(BaselineError, "exactly one matching declaration"):
            verify_manifest_xml(
                manifest(
                    permissions=f'<uses-permission android:name="{guard}" />',
                    package=package,
                ),
                "release",
            )

    def test_rejects_guard_declaration_without_matching_use(self):
        package = "org.example.sample"
        guard = f"{package}.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION"
        with self.assertRaisesRegex(BaselineError, "requested exactly once"):
            verify_manifest_xml(
                manifest(
                    package=package,
                    declarations=(
                        f'<permission android:name="{guard}" '
                        'android:protectionLevel="signature" />'
                    ),
                ),
                "release",
            )

    def test_requires_valid_manifest_package_for_signature_guard(self):
        guard = "not a valid package.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION"
        with self.assertRaisesRegex(BaselineError, "valid manifest package"):
            verify_manifest_xml(
                manifest(
                    permissions=f'<uses-permission android:name="{guard}" />',
                    package="not a valid package",
                    declarations=(
                        f'<permission android:name="{guard}" '
                        'android:protectionLevel="signature" />'
                    ),
                ),
                "release",
            )

    def test_rejects_guard_protection_levels_other_than_exact_signature(self):
        package = "org.example.sample"
        guard = f"{package}.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION"
        for protection in (
            "normal",
            "dangerous",
            "signature|privileged",
            "0",
            "1",
            "3",
            "0x12",
            "0x2|privileged",
            "2garbage",
            "0xGG",
            "+2",
        ):
            with self.subTest(protection=protection):
                with self.assertRaisesRegex(BaselineError, "signature \\(2\\) exactly"):
                    verify_manifest_xml(
                        manifest(
                            permissions=f'<uses-permission android:name="{guard}" />',
                            package=package,
                            declarations=(
                                f'<permission android:name="{guard}" '
                                f'android:protectionLevel="{protection}" />'
                            ),
                        ),
                        "release",
                    )

    def test_rejects_duplicate_guard_requests_and_declarations(self):
        package = "org.example.sample"
        guard = f"{package}.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION"
        use = f'<uses-permission android:name="{guard}" />'
        declaration = (
            f'<permission android:name="{guard}" '
            'android:protectionLevel="signature" />'
        )
        with self.assertRaisesRegex(BaselineError, "duplicate uses-permission"):
            verify_manifest_xml(
                manifest(permissions=use + use, package=package, declarations=declaration),
                "release",
            )
        with self.assertRaisesRegex(BaselineError, "exactly one matching declaration"):
            verify_manifest_xml(
                manifest(permissions=use, package=package, declarations=declaration + declaration),
                "release",
            )

    def test_guard_does_not_allow_other_permissions_or_declarations(self):
        package = "org.example.sample"
        guard = f"{package}.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION"
        guard_use = f'<uses-permission android:name="{guard}" />'
        guard_declaration = (
            f'<permission android:name="{guard}" '
            'android:protectionLevel="signature" />'
        )
        with self.assertRaisesRegex(BaselineError, "platform permissions"):
            verify_manifest_xml(
                manifest(
                    permissions=(
                        guard_use
                        + '<uses-permission android:name="android.permission.CAMERA" />'
                    ),
                    package=package,
                    declarations=guard_declaration,
                ),
                "release",
            )
        with self.assertRaisesRegex(BaselineError, "exactly one matching declaration"):
            verify_manifest_xml(
                manifest(
                    permissions=guard_use,
                    package=package,
                    declarations=(
                        guard_declaration
                        + '<permission android:name="org.example.other" '
                        'android:protectionLevel="signature" />'
                    ),
                ),
                "release",
            )

    def test_rejects_permission_suffix_lookalike(self):
        package = "org.example.sample"
        lookalike = f"{package}.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION_EXTRA"
        with self.assertRaisesRegex(BaselineError, "platform permissions"):
            verify_manifest_xml(
                manifest(
                    permissions=f'<uses-permission android:name="{lookalike}" />',
                    package=package,
                ),
                "release",
            )

    def test_rejects_permission_tree_and_group_declarations(self):
        for tag in ("permission-tree", "permission-group"):
            with self.subTest(tag=tag):
                declaration = f'<{tag} android:name="org.example.group" />'
                with self.assertRaisesRegex(BaselineError, tag):
                    verify_manifest_xml(
                        manifest(declarations=declaration),
                        "release",
                    )

    def test_accepts_bootstrapped_fully_qualified_main_activity(self):
        xml = manifest().replace(
            'android:name=".MainActivity"',
            'android:name="dev.example.sampleportable.MainActivity"',
        )
        _, components = verify_manifest_xml(xml, "release")
        self.assertEqual(
            components,
            ["activity=dev.example.sampleportable.MainActivity"],
        )

    def test_rejects_camera_permission(self):
        with self.assertRaisesRegex(BaselineError, "permissions"):
            verify_manifest_xml(
                manifest('<uses-permission android:name="android.permission.CAMERA" />'),
                "debug",
            )

    def test_rejects_connectivity_permission_without_explicit_activation(self):
        with self.assertRaisesRegex(BaselineError, "permissions"):
            verify_manifest_xml(
                manifest(
                    '<uses-permission android:name="android.permission.INTERNET" />'
                    '<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />'
                ),
                "debug",
            )

    def test_rejects_internet_permission_in_release(self):
        with self.assertRaisesRegex(BaselineError, "permissions"):
            verify_manifest_xml(
                manifest('<uses-permission android:name="android.permission.INTERNET" />'),
                "release",
            )

    def test_rejects_optional_service_provider_and_receiver(self):
        for tag, name in (
            ("service", "vendor.BackgroundService"),
            ("provider", "androidx.startup.InitializationProvider"),
            ("receiver", "vendor.PushReceiver"),
        ):
            with self.subTest(tag=tag):
                component = f'<{tag} android:name="{name}" />'
                with self.assertRaisesRegex(BaselineError, name):
                    verify_manifest_xml(manifest(components=component), "release")

    def test_rejects_backup_enabled(self):
        with self.assertRaisesRegex(BaselineError, "allowBackup"):
            verify_manifest_xml(manifest(allow_backup="true"), "release")

    def test_rejects_minimum_sdk_drift(self):
        with self.assertRaisesRegex(BaselineError, "minSdkVersion"):
            verify_manifest_xml(manifest(min_sdk="23"), "release")

    def test_rejects_unexpected_activity(self):
        with self.assertRaisesRegex(BaselineError, "MainActivity"):
            verify_manifest_xml(
                manifest(components='<activity android:name="vendor.SetupActivity" />'),
                "release",
            )

    def test_rejects_malformed_manifest(self):
        with self.assertRaisesRegex(BaselineError, "parseable"):
            verify_manifest_xml("<manifest>", "release")


if __name__ == "__main__":
    unittest.main()

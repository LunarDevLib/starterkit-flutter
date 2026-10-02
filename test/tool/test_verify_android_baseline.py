import unittest

from tool.verify_android_baseline import BaselineError, verify_manifest_xml


ANDROID = 'xmlns:android="http://schemas.android.com/apk/res/android"'


def manifest(permissions="", components="", min_sdk="24", allow_backup="false"):
    return f'''<manifest {ANDROID}>
  {permissions}
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

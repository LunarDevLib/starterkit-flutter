# Core package and native CI evidence

CI pins Flutter 3.47.4. The source and fresh renamed-copy lanes resolve the root
lockfile with `flutter pub get --enforce-lockfile` and independently resolve,
analyze, and test the local `starterkit_connectivity` package against its own
lockfile. Formatting includes that package's Dart `lib` and `test` paths without
formatting native or generated files.

Linux and macOS each run localization generation, template validation,
formatting, root analysis/tests, and the package checks. The macOS job performs
those source checks before its unsigned iOS simulator build and repeats the
checks for the freshly bootstrapped copy before its iOS simulator build. Android
source and renamed-copy jobs compile debug and unsigned release APKs and run
`tool/verify_android_baseline.py` on both APKs using Android SDK `apkanalyzer`.
CI does not install SDK tools or alter global SDK configuration; a missing SDK
tool or unreadable APK manifest fails the gate instead of producing a static
success claim.

The APK manifest gate currently expects minimum SDK 24, `allowBackup=false`,
debug's Flutter-generated `INTERNET` platform permission only, no release
platform permissions, and only the baseline `.MainActivity` application
component. Both variants may also contain the exact app-identity-scoped
`<manifest package>.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION` request, paired
with one matching `<permission>` declaration whose protection level is exactly
the Android `signature` protection level (numeric value 2; the verifier accepts
its symbolic spelling or an exact decimal/hex encoding). The verifier derives
that name from the APK manifest package and reports it separately as an
app-defined signature IPC guard, not a platform permission. It does not
authorize hardware or personal-data access or activate an optional capability.
Permission declarations/requests outside the variant platform allowlist and
exact signature pair, plus providers, receivers, services, and activity
aliases, are rejected. Actual component names are reported for later
capability-removal audits. This is a narrow baseline check, not a general
Android security certification or the future capability-harness policy.

Each Android lane writes these build outputs before verification:

```text
build/app/outputs/flutter-apk/app-debug.apk
build/app/outputs/flutter-apk/app-release.apk
```

The workflow publishes those APKs as short-retention CI evidence. It does not
upload full iOS build trees or require signing credentials. Native compilation
success means compile evidence only; it does not claim device execution,
release signing, store readiness, or OS-delivered deep-link behavior.

# Core package and native CI evidence

CI pins Flutter 3.47.4. The source and fresh renamed-copy lanes resolve the root
lockfile with `flutter pub get --enforce-lockfile` and independently resolve,
analyze, and test the local `starterkit_connectivity` and
`starterkit_preferences` packages against their own lockfiles. Formatting
includes both packages' Dart `lib` and `test` paths without formatting native
or generated files. These are Dart package checks; they do not claim native
plugin test coverage.

Linux and macOS each run localization generation, template validation,
formatting, root analysis/tests, and the package checks. The macOS job performs
those source checks before its unsigned iOS simulator build and repeats the
checks for the freshly bootstrapped copy before its iOS simulator build. Android
source and renamed-copy jobs compile debug and unsigned release APKs and run
`tool/verify_android_baseline.py` on both APKs using Android SDK `apkanalyzer`.
CI does not install SDK tools or alter global SDK configuration; a missing SDK
tool or unreadable APK manifest fails the gate instead of producing a static
success claim.

The macOS source and renamed-copy lanes also verify the actual built iOS
simulator and unsigned release `Runner.app/Info.plist` files with
`tool/verify_ios_baseline.py`, requiring the corresponding bundle ID, no
privacy usage-description, background-mode, ATS, or Bonjour activation keys, and
`MinimumOSVersion=15.0`.
Available plist files are uploaded as short-retention artifacts even when a
later verification step fails. The source's iOS 13 deployment declarations are
automatically migrated by the frozen Flutter 3.47.4 build; iOS 15 is the
effective supported runtime floor. This is build-plist evidence, not device
execution evidence.

Native unit-test wiring runs Android's
`:starterkit_preferences:testDebugUnitTest` task for both source and renamed
copies, and runs `swift test --package-path packages/starterkit_preferences/ios`
for both source and renamed copies on macOS before either unsigned iOS build.
These are host-side unit tests, not device or simulator execution evidence. The
macOS job can run when the verify job has produced a template-identity output,
even if an Android manifest gate failed, provided the workflow was not
cancelled. This preserves native-test/build diagnostics without masking failure:
the verify job remains failed and the overall workflow remains failed. No
`continue-on-error` or manifest-gate bypass is introduced.

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
build/app/outputs/flutter-apk/manifest-diagnostics/app-debug-manifest.xml
build/app/outputs/flutter-apk/manifest-diagnostics/app-release-manifest.xml
build/ci-android-diagnostics/debugRuntimeClasspath.txt
build/ci-android-diagnostics/releaseRuntimeClasspath.txt
```

For each Android source and renamed-copy lane, Flutter builds the debug APK
first, allowing Flutter to prepare clean-checkout Android prerequisites before
direct Gradle invocations. The lane then runs the preferences JUnit task and
captures both runtime dependency reports before attempting the release APK.
The release build still runs after a unit-test or graph-capture failure when
the debug build succeeded; those earlier failures remain CI failures. Both APK
variants are built before either manifest gate runs. The workflow prints each
available APK's complete decoded binary manifest before validation. Gradle is
invoked with `--project-dir android` so its Android project directory is
correct while diagnostics are written under the repository's `build/` path.
It uploads available APKs, manifest dumps, and graph reports with an
`always()` artifact step, so the first fail-closed verifier error does not hide
the remaining manifest surfaces. Upload warns when earlier failures produced
no files; build, manifest-extraction, and validation failures remain failures.
Artifacts are short-retention CI evidence. The workflow does not upload full
iOS build trees or require signing credentials. Native compilation success
means compile evidence only; it does not claim device execution, release
signing, store readiness, or OS-delivered deep-link behavior.
The actual native-plugin inventory and any broader capability policy remain
unresolved; this baseline verifier does not approve new native components,
permissions, or capabilities.

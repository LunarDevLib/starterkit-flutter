# Dependency decisions

Initial Core/Baseline decision log. A dependency being available does not mean
its feature is active. The default app remains generic, network-free, and does
not read credentials, write preferences, or start external services.

## Baseline

| Package | Decision |
| --- | --- |
| `flutter_riverpod` | Existing state-management baseline; preserve its existing version constraint. |
| `go_router` | Existing routing baseline; preserve its existing version constraint. |
| `intl` | Existing localization baseline; preserve its existing version constraint. |
| Flutter SDK packages | `flutter`, `flutter_localizations`, and `flutter_test` remain SDK dependencies. |

## Core: pinned or local, not activated

These direct dependencies are exact-version pins or project-owned packages.
Keep integrations dormant until a scoped feature explicitly uses them and adds
relevant tests.

| Package | Version | License | Rationale and limits |
| --- | --- | --- | --- |
| `http` | 1.6.0 | BSD-3-Clause | Small Dart HTTP client for future explicit requests. No endpoint, client, request, or internet permission is configured by adding the package. |
| `flutter_secure_storage` | 11.2.0 | BSD-3-Clause | Secure-storage adapter for future credential features. No credential reads/writes, migration, or cipher operation is invoked by the template. Its inspected Android defaults are RSA-OAEP key wrapping and AES-GCM storage; keep defaults unless separately reviewed. |
| `starterkit_preferences` | 1.0.0 (local) | Project-owned | Narrow non-sensitive preference adapter used by Starter Core. Fixed method-channel registration does not open storage; only validated `read`, `write`, or `remove` calls access preferences. |
| `starterkit_connectivity` | 1.0.0 (local) | Project-owned | Native interface-status stream; registration installs channels only, and observation starts on explicit subscription. Not an internet-reachability check. |

### Inert registration audit

Registration behavior is dependency-specific and must not be generalized from
one plugin to another. The local preference plugin installs its fixed channel
without opening storage; the local connectivity plugin installs channels
without starting observation. The secure-storage package's registration
creates channels and an Android worker thread; its inspected source performs
storage operations only after a method call, but an idle worker is not a claim
of zero native activity.

- `flutter_secure_storage` Android:
  `flutter_secure_storage-11.2.0/android/src/main/java/com/it_nomads/fluttersecurestorage/FlutterSecureStoragePlugin.java`.
  `onAttachedToEngine` captures application context, starts a worker thread,
  and installs a method channel. Configuration, initialization and storage
  operations happen only after a method call. Defaults are defined in
  `FlutterSecureStorageConfig.java`.
- Darwin:
  `flutter_secure_storage_darwin-0.4.3/darwin/flutter_secure_storage_darwin/Sources/flutter_secure_storage_darwin/FlutterSecureStorageDarwinPlugin.swift`.
  Registration creates method/event channels and a plugin instance; keychain
  reads/writes happen only in method handlers.
- `starterkit_preferences` is owned source at
  `packages/starterkit_preferences`. Android registration installs the method
  channel; a validated operation lazily opens its fixed store on a serial
  worker. iOS registration installs the method channel; operations alone
  address the fixed defaults key prefix. See
  [the native preferences contract](core/PREFERENCES_NATIVE.md). This is a
  Starter Core dependency, not an optional capability.
- `http` is a Dart package and does not create/start a client or issue traffic
  merely by being a dependency.

These are source inspections, not runtime/build evidence.

## Optional capabilities

### WebView

`starterkit_webview` 1.0.0 is a project-owned local Flutter plugin. It is present
as a dependency so source and renamed Android/iOS builds compile the native adapter,
but the default app does not import or construct it. Plugin registration only
registers a platform-view factory; it does not construct a WebView, load content,
request permissions, or start network traffic.

Android uses `androidx.webkit:webkit:1.17.1` in the capability plugin. The native
bridge requires runtime support for both `WEB_MESSAGE_LISTENER` and
`DOCUMENT_START_SCRIPT`; otherwise the WebView remains usable but the bridge is
reported unavailable. iOS uses the system WebKit framework. No vendor SDK is used.

Remote WebView content is not functional on the Android baseline until a consuming
product deliberately adds `android.permission.INTERNET`. The capability itself
declares no platform permission.

### Camera / Gallery

`starterkit_platform` 1.0.0 is a project-owned local Flutter plugin. Its
registration installs one method channel and keeps all media work dormant until
an explicit capability call. The plugin manifest declares no permission.

Android Camera uses an external camera intent with an activation-only, product-owned
FileProvider authority and private cache output. Gallery uses the system Photo
Picker on API 33+ or `ACTION_OPEN_DOCUMENT` below it; neither path requires broad
storage permission. iOS Camera uses AVFoundation authorization plus
`UIImagePickerController` and therefore requires a product-supplied
`NSCameraUsageDescription` only when activated. iOS Gallery uses `PHPicker` on
iOS 14+ and does not require broad Photos authorization.

Both paths bound result bytes and pixel count before product use and return only
capability-owned temporary copies. No third-party camera, picker, or permission
package is added.

iOS media validation uses the SDK-provided ImageIO framework and system zlib
(`import zlib`, permissive zlib license), classified as Optional native/system
dependencies of this capability. No package download, vendored parser, vendor SDK,
OS-floor change, or permission is introduced. System-library maintenance follows
Apple OS updates. PNG container/CRC and bounded compressed-stream validation runs
only during an explicit media operation; plugin registration does not perform
decoding, file work, or initialize an external service. ImageIO's bounded decode
is not a guarantee of strict malformed-file rejection for every supported codec.

### Location

`starterkit_platform` also exposes an opt-in, disabled-by-default one-shot
foreground Location capability. Plugin registration installs its channel only;
permission lookup, prompting, lifecycle observation and location-manager work
begin only for explicit API operations. The Dart implementation adds no package.
Android uses framework `LocationManager`; iOS uses the optional system
CoreLocation framework. These are native/system dependencies maintained with
their respective OS releases, not vendor SDKs.

The plugin adds no permission or usage string. Product activation owns Android
coarse-location manifest permission and iOS `NSLocationWhenInUseUsageDescription`;
the default starter app remains without them. Background location, an Always
purpose string, network endpoints, persistence, and third-party geolocation or
permission packages are not part of this capability. Source policy and Dart
contract tests do not constitute device or remote consumer CI evidence; consumer
CI is pending for this change.

## Optional future integrations (not implemented)

Dio, cloud SDKs, Sentry, Firebase services, third-party geolocation/image-picker/
camera packages, and biometric packages are not included or configured. They require separate
capability-specific approval, platform/permission review, and tests.

`connectivity_plus` was explicitly rejected for this Core set: in
`connectivity_plus-7.3.2/ios/connectivity_plus/Sources/connectivity_plus/ConnectivityPlusPlugin.swift`,
plugin registration constructs `PathMonitorConnectivityProvider`; its
initializer in `PathMonitorConnectivityProvider.swift` calls
`ensurePathMonitor()`, which starts `NWPathMonitor` during engine/plugin
registration. That violates the requirement to keep network-observer
subscription out of engine registration. The local `starterkit_connectivity`
adapter instead starts and stops observation with its stream subscription.

## Development dependencies

`flutter_lints` provides lint rules, and `flutter_test` is Flutter SDK supplied.
They do not enable runtime integrations.

## Forbidden by default

Firebase, Sentry, generic WebView, third-party geolocation/image-picker/camera,
`permission_handler`, and Firebase messaging dependencies remain forbidden by
the template validator. Project-owned `starterkit_webview` and
`starterkit_platform` are reviewed capability packages and remain disconnected
from the default app. The merged Android manifest has one app-defined,
signature-protected dynamic-receiver IPC guard, validated against the actual
manifest package by the APK baseline gate. This is not a hardware or
personal-data platform permission and does not activate an optional capability.
No such optional capability permissions, external service startup, tracking,
or implicit credential access are enabled by these dependency decisions. See
[the Android CI manifest contract](core/CI.md) for the exact pair requirement.

## Platform notes

The Dart/Flutter SDK constraints and iOS 13.0 minimum are unchanged. The Android
application explicitly declares API 24, matching Flutter 3.47.4's effective
baseline build floor. The frozen template's literal `minSdk = 23` is automatically
migrated by Flutter's `MinSdkVersionMigration` to `flutter.minSdkVersion` (24).
Both source and renamed baseline builds in [run 36981590356](https://github.com/LunarDevLib/starterkit-flutter/actions/runs/36981590356)
reported `Upgrading build.gradle.kts`. This correction makes that existing build
behavior explicit rather than reducing an established API-23 runtime guarantee.

The resolved `flutter_secure_storage` 11.2.0 Android Gradle source also requires
API 24; its README's API-23 statement is stale. Darwin dependencies
`shared_preferences_foundation` 2.5.7 and `flutter_secure_storage_darwin` 0.4.3
require iOS 13.0. The local connectivity library declares Android 23/iOS 13;
the application floor remains 24. These are source/configuration facts. Native
compilation of the new Core dependency set still requires its own CI evidence.

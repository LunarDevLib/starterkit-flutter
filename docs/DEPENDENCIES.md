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

## Core: pinned, not activated

These direct dependencies are exact-version pins. Keep integrations dormant
until a scoped feature explicitly uses them and adds relevant tests.

| Package | Version | License | Rationale and limits |
| --- | --- | --- | --- |
| `http` | 1.6.0 | BSD-3-Clause | Small Dart HTTP client for future explicit requests. No endpoint, client, request, or internet permission is configured by adding the package. |
| `shared_preferences` | 2.5.5 | BSD-3-Clause | Simple non-sensitive key/value persistence, not a database or credential store. No app data is read or written by default. |
| `flutter_secure_storage` | 11.2.0 | BSD-3-Clause | Secure-storage adapter for future credential features. No credential reads/writes, migration, or cipher operation is invoked by the template. Its inspected Android defaults are RSA-OAEP key wrapping and AES-GCM storage; keep defaults unless separately reviewed. |
| `starterkit_connectivity` | 1.0.0 (local) | Project-owned | Native interface-status stream; registration installs channels only, and observation starts on explicit subscription. Not an internet-reachability check. |

### Inert registration audit

Flutter plugin registration for these three dependencies provides platform
channels/handlers; it does not itself perform an HTTP request, read or write a
credential/preference, migrate storage, or activate hardware/telemetry.

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
- `shared_preferences` uses its federated `shared_preferences_android` and
  `shared_preferences_foundation` platform implementations. Registration sets
  up the method channel; storage access requires an explicit API method call.
- `http` is a Dart package and does not create/start a client or issue traffic
  merely by being a dependency.

These are source inspections, not runtime/build evidence.

## Optional future integrations (not implemented)

Dio, cloud SDKs, WebViews, Sentry, Firebase services, camera, and biometric
packages are not included or configured. They
require separate capability-specific approval, platform/permission review,
and tests.

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

Firebase, Sentry, WebView, geolocation, image picker, camera,
`permission_handler`, and Firebase messaging dependencies remain forbidden by
the template validator until their deliberate capability integration is
approved. No active Android permissions, external service startup, tracking,
or implicit credential access are enabled by these dependency decisions.

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

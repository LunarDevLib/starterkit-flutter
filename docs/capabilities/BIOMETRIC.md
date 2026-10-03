# Biometric

## Status

- Classification: Optional Capability
- Implemented: Yes (Dart API and native policy/adapter lanes)
- Tested: Dart contract tests; native policy coverage included; native/consumer CI pending
- Default connected: No
- Startup availability query, prompt, hardware check, or context creation: No
- Baseline permission: None

## Purpose

Offer an explicit, biometric-only OS authentication prompt before a product-owned
local protected action. Availability is advisory; only an authenticated result
from the explicit authentication operation may gate that action.

## Semantic Contract

- Constructing the default-disabled capability performs no native call. Disabled
  availability, authentication (including invalid reasons), and cancellation
  perform zero native calls, timers, random-ID generation, or service startup.
- `availability()` is a non-prompting snapshot and is not authorization. A
  product must still handle the actual `authenticated` result for every protected
  action; a `ready` availability response is not sufficient.
- Authentication requires a nonempty trimmed product reason whose original UTF-8
  encoding is at most 256 bytes and contains no NUL. Invalid reason returns
  `denied/biometric.invalid_reason` without opening a prompt.
- Operations have a secure random 32-character lowercase hexadecimal request ID.
  Results are immutable, and only `BiometricResult.authenticated` on the exact
  authenticated kind/code pair indicates native success.
- There is no automatic authentication deadline or watchdog. An OS prompt may
  remain pending until an OS result or explicit cancellation. Products must
  retain operation handles and cancel them when their protected action/lifecycle
  ends. Explicit cancellation settles the Dart result first, then sends at most
  one request-ID-scoped native cancellation; acknowledgement is bounded to one
  second. Repeated pending cancellation shares its acknowledgement future;
  cancellation after a native terminal result returns false without an RPC.
- Payloads and result codes are strictly validated. Native exception details,
  prompt text, and reason strings are never surfaced as errors or logged.

## Flutter API

Package: `packages/starterkit_platform` (separate `biometric.dart` export and
also exported by `starterkit_platform.dart`).

```dart
const biometric = StarterBiometricCapability(enabled: true);
final availability = await biometric.availability(); // advisory; no prompt

if (availability.state == BiometricAvailabilityState.ready) {
  final operation = biometric.authenticate(reason: 'Confirm this action');
  final result = await operation.result;
  if (result.authenticated) {
    // Perform only the product-owned local action guarded by this prompt.
  }
  // Keep the handle while pending; cancel explicitly when the action is abandoned.
}
```

Availability reports `ready`, `permissionRequired`, `noHardware`, `notEnrolled`,
`lockedOut`, or `unavailable`, with a fixed whitelisted code. Authentication
distinguishes authenticated, cancelled, denied, locked out, unavailable, invalid,
conflict, and safe platform failure. Availability is separate from authentication
and cannot authorize a protected action.

## Android

The adapter uses framework `BiometricManager` and `BiometricPrompt` on API 29+;
API 24–28 remains supported by the package but reports this capability unavailable
without touching API 29 classes. API 29 uses the platform-default biometric
prompt and has no `BIOMETRIC_STRONG` class-strength guarantee. API 30+ consistently
checks and prompts for `BIOMETRIC_STRONG`; a failed strong check does not fall back
to a weaker biometric or device credential. Neither path uses keyguard/passcode,
FingerprintManager, AndroidX Biometric, or a runtime permission dialog.

On API 30+, only an actual successful biometric authentication callback is
authenticated; credential/unknown callback types fail closed. Android's
`onAuthenticationFailed` is nonterminal (the system can retry); terminal errors
map to safe cancelled, locked-out, unavailable, or failure outcomes.

## iOS

The adapter uses a fresh `LAContext` per explicit request and the biometric-only
`deviceOwnerAuthenticationWithBiometrics` policy for both capability assessment
and authentication. There is no passcode policy, shared context, keychain use,
retry loop, or fallback. iOS reports `authenticationFailed` as terminal denied,
unlike Android's retry notification. Success requires a true OS reply with no
contradictory error; no modality or class-strength guarantee is inferred.

Only Face ID requires a product-supplied, nonempty `NSFaceIDUsageDescription`.
Touch ID does not require this key and must not be blocked for its absence. The
capability check is advisory and non-prompting. It must not run from the evaluate
reply callback. The canonical prompt is biometric-only; Face ID lockout recovery
outside the app does not constitute successful app fallback authentication.

## Dependencies

The implementation uses only native platform APIs: Android framework biometric
APIs and Apple's optional `LocalAuthentication` system framework. No additional
Dart package, Gradle dependency, vendor SDK, endpoint, or biometric package is
used. Native framework maintenance follows the corresponding OS releases.

## Permissions

The plugin adds no manifest permission or iOS usage-description string. Android
products activating this capability should declare the normal
`android.permission.USE_BIOMETRIC` permission. It is activation-only and does not
trigger a runtime permission prompt. iOS products using Face ID must supply a
meaningful `NSFaceIDUsageDescription`; Touch ID products do not require it.

## Native Config

Registration installs the independent `starterkit/platform/biometric` channel
only; it performs no availability query, prompt, hardware access, `LAContext`
creation, observer registration, or timer startup. Product activation may add:

```xml
<uses-permission android:name="android.permission.USE_BIOMETRIC" />
```

For a Face ID product only, add to its `Info.plist`:

```xml
<key>NSFaceIDUsageDescription</key>
<string>Explain the specific local action that uses Face ID.</string>
```

Do not add Android device-credential fallback configuration. Do not add a Face ID
usage key to a Touch ID-only product merely because the capability is present.

## Vendor Config

None. No vendor key, SDK, remote endpoint, account, or external service is used.

## Activation

1. Keep the package only if the product uses at least one platform capability.
2. Compose `StarterBiometricCapability(enabled: true)` only in the explicit
   product action that needs it; do not connect it to default navigation/startup.
3. Add Android `USE_BIOMETRIC` in the product manifest and, for Face ID only,
   add a nonempty `NSFaceIDUsageDescription`.
4. Treat availability as advisory. Start authentication from an explicit user
   action, retain its operation handle, and authorize the local protected action
   only if `result.authenticated` is true.
5. Handle every result kind; explicitly cancel abandoned pending work and account
   for OS/device lifecycle behavior before release.

## Deactivation

Disconnect the product action and remove its biometric capability composition.
Remove `USE_BIOMETRIC` and the Face ID usage string if no remaining product
feature needs them. The package may remain when Media or Location is still used.

## Failure Model

Denial, user/system cancellation, lockout, no hardware, no enrollment, missing
configuration, unavailable host/platform, conflict, malformed response, and safe
platform failure are distinct outcomes. Missing plugin is unavailable;
`PlatformException` and other transport exceptions map to fixed safe failures.
Malformed maps, wrong IDs, unknown kind/code pairs, and extra or missing fields
fail closed. A dead channel can leave an uncancelled authentication result pending;
bounded cancellation acknowledgement does not prove that OS UI/hardware stopped.

## Tests

- Dart channel contract tests: `packages/starterkit_platform/test/biometric_test.dart`.
- Android production policy tests: `packages/starterkit_platform/android/src/test/`.
- iOS Foundation production policy tests: `packages/starterkit_platform/ios/Tests/`.
- Source/renamed consumer native builds are compile gates, not device prompt,
  enrollment, lockout, foreground, or lifecycle evidence.

## Security Notes

Biometric APIs report a local OS authentication event only. This capability does
not establish backend session identity, server authorization, cryptographic key
binding, secure storage, access to biometric templates, or proof of a particular
biometric modality/assurance class. Do not treat availability as authorization.
Do not log reasons, native exception strings, biometric data, or authentication
payloads. No biometric data is returned to the application.

## Known Limitations

API 24–28 Android reports unavailable. API 29 Android follows the platform-default
biometric policy and does not promise the API 30+ strong-biometric policy. A
custom Android `Activity` that does not meet the supported Flutter activity and
lifecycle contract fails closed. Authentication has no automatic timeout; a
pending result can persist if the native channel dies and its operation handle is
not explicitly cancelled. A bounded acknowledgement cannot prove that a detached
OS prompt has stopped. Face ID missing-key preflight behavior is not guaranteed
by Apple documentation, and actual device behavior is not proven by CI. No device
enrollment, prompt, lockout recovery, or OS lifecycle behavior is claimed as
verified by Dart/native policy tests.

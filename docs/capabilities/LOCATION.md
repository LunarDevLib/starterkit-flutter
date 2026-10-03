# Location

## Status

- Classification: Optional Capability
- Implemented: Yes (Dart API and native policy/adapter lanes)
- Tested: Dart contract tests passed; native policy coverage included, final native/consumer CI pending
- Default connected: No
- Startup permission query, prompt, or location work: No
- Baseline permission: None

## Purpose

Obtain one bounded, approximate-capable foreground location sample after an
explicit product action. Permission status and the contextual permission request
are separate from sample acquisition.

## Semantic contract

- Constructing a capability does not call the platform. The default is disabled;
  disabled status/query/request/locate/cancel paths make zero channel calls.
- `permissionStatus()` only reads current authorization and never prompts or
  starts tracking. `requestPermission()` is explicit and contextual. `locate()`
  never requests permission.
- Results distinguish success, cancellation, denial, restriction, unavailability,
  timeout, invalid data, conflict, and failure. Native text and exception payloads
  are never exposed as product error messages.
- A sample contains latitude, longitude, accuracy in meters, approximate/reduced
  accuracy state, and age. The Dart boundary rejects malformed types, non-finite
  or out-of-range coordinates, negative accuracy/age, and samples older than the
  caller's bound.
- At most one native Location permission/sample operation is pending at once;
  Location does not interfere with Media operations. Cancellation is request-ID
  scoped and old IDs cannot cancel newer work.
- Location is one-shot and foreground-only. There is no background tracking,
  history, persistence, endpoint, upload, map, geocoding, or anti-mock guarantee.

## Flutter API

Package: `packages/starterkit_platform` (exported by `starterkit_platform.dart`).

```dart
const location = StarterLocationCapability(enabled: true);

final permission = await location.permissionStatus(); // no prompt
if (permission.status != LocationPermissionStatus.granted) {
  final request = location.requestPermission(); // explicit, in-context only
  final requestResult = await request.result;
}

final operation = location.locate(); // never prompts
final result = await operation.result;
if (result.isSuccess) {
  final sample = result.location!;
  // Apply product-owned purpose, consent, retention, and data-use policy.
}
// An in-flight operation may be cancelled with `await operation.cancel()`.
```

`LocationLimits` defaults to a 15-second operation timeout and 5-second maximum
sample age; both are runtime-validated in the inclusive 1–60,000 ms range.
Permission requests default to a 60-second timeout (maximum 60 seconds). Secure
32-character lowercase hexadecimal request IDs are generated per explicit
operation. Operation results and values are immutable. The Dart watchdog settles
at the requested deadline, then best-effort cancels the same ID; a late platform
reply is ignored. A per-operation monotonic clock is also checked when replies,
errors, or caller cancellation are processed, so a delayed watchdog cannot let a
post-deadline result win. Cancellation acknowledgement is bounded to one second.
Directly constructed `ForegroundLocation` samples also validate finite bounded
coordinates, non-negative finite accuracy, and age up to the hard 60-second limit.

## Android

The native adapter uses framework `LocationManager`, preferring enabled NETWORK
then GPS providers, and removes its one-shot listener on every terminal path. It
requests coarse location only. Products may separately configure fine permission;
the capability reports OS authorization accurately and does not promise precision.
No last-known-location fallback, fused/vendor client, service, receiver,
background permission, persistence, or location logging is used.

The plugin manifest does not declare location permissions. Product activation
must add only `android.permission.ACCESS_COARSE_LOCATION` to its manifest and
request it in context. Do not add `ACCESS_BACKGROUND_LOCATION`; fine permission
is not required by this capability.

Android allocates permission request codes from process-wide range `0x5400`–
`0x54ff` (256 explicit permission requests per process lifetime), separate from
the Media range `0x5300`–`0x53ff`. Codes are not reused; exhaustion fails closed.
Consuming products must keep `0x5400`–`0x54ff` exclusive to Location. This is an
application-process limit, not a platform-wide request-code registry.

## iOS

The adapter uses CoreLocation with a per-operation, lazy `CLLocationManager`,
when-in-use authorization, one-shot `requestLocation`, and approximately
hundred-meter desired accuracy. It reports reduced accuracy through the
approximate flag. It does not request Always authorization, full accuracy,
background tracking, or start a manager at plugin registration.

The consuming product must supply a non-empty `NSLocationWhenInUseUsageDescription`
before requesting permission or locating. No `NSLocationAlways...` purpose string,
background mode, or entitlement is needed or recommended.

## Dependencies

Only platform framework APIs are used: Android framework LocationManager and
Apple CoreLocation. CoreLocation is an optional system framework dependency;
there is no geolocation/permission vendor package, network service, or new Dart
package. Framework maintenance follows the supported OS releases.

## Permissions and product policy

The template declares no location permission or usage-description string.
Products explicitly activating Location own the user-facing purpose, consent,
collection, retention, access, and deletion policies. Ask for coarse/when-in-use
access only in context; do not request background or fine access by default.
Coordinates and permission data must not be written to logs or sent to an endpoint
without a separately reviewed product feature and policy.

## Native Config

The plugin registers `starterkit/platform/location` handlers without querying
permission, creating a manager, observing lifecycle, or starting hardware work.
When a product deliberately activates Location, its Android manifest may add:

```xml
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
```

The iOS product may add this purpose string to its `Info.plist`:

```xml
<key>NSLocationWhenInUseUsageDescription</key>
<string>Explain the specific user-facing feature that needs approximate location.</string>
```

Do not add `ACCESS_FINE_LOCATION`, `ACCESS_BACKGROUND_LOCATION`, an Always
purpose string, background modes, or entitlements by default. Fine access is not
needed for this capability; if a product separately declares it, report actual
OS authorization without claiming a precision guarantee.

## Vendor Config

None. There is no vendor key, SDK, remote endpoint, account, or external service
to configure. Do not add a geolocation or permission-handler package for this
capability.

## Activation

1. Keep `starterkit_platform` only if the product uses at least one capability.
2. Construct `StarterLocationCapability(enabled: true)` only in the explicit
   product composition/action that owns the feature.
3. Android: add `ACCESS_COARSE_LOCATION` only; do not add background access.
4. iOS: add a clear `NSLocationWhenInUseUsageDescription` only.
5. Query status if useful, then request permission explicitly and contextually.
6. Handle every `LocationResultKind`; call `locate()` only after an explicit user
   action and apply product-owned purpose/retention policy.
7. Validate the product's permission configuration, foreground behavior and
   real device/provider interactions before release.

## Deactivation

Disconnect and remove Location capability composition and user flows. Remove the
product's coarse permission and when-in-use purpose string if no remaining feature
needs them. The local plugin may remain when Media is still used; remove the
package only when no capability from it is used.

## Failure model

Permission denial/restriction, disabled or unavailable providers, missing
configuration, missing plugin, operation conflict, timeout, caller cancellation,
background/detach cancellation, invalid/stale samples, and safe platform failure
are separate outcomes. Platform exceptions are mapped to fixed safe codes.
Unknown/malformed envelopes fail closed. If a native channel is dead, Dart can
settle its caller and request cancellation but cannot prove the operating system
stopped hardware work.

## Tests

- Dart channel contract and watchdog tests: `packages/starterkit_platform/test/`.
- Android Location policy tests: `packages/starterkit_platform/android/src/test/`.
- iOS Location policy tests: `packages/starterkit_platform/ios/Tests/`.
- Source and renamed native builds provide compile gates in consumer CI; those
  gates are not device/provider or permission-dialog evidence.

Remote consumer CI is pending for this change. Hardware location, provider
availability, permission prompts, actual OS foreground transitions, and signing
remain unverified until device/integration checks.

## Security notes

Treat coordinates and authorization state as sensitive personal data. Do not log
coordinates, IDs alongside user identity, provider payloads, or platform exception
text. Use least-privilege coarse/when-in-use authorization. Keep purpose,
collection consent, data minimization and retention product-owned and explicit.

## Known limitations

The public OS APIs may return a recent cached sample when it is within the explicit
maximum-age bound; no guarantee of a newly measured GNSS fix or hardware freshness
is made. Approximate/reduced authorization may limit precision. OS and device
provider behavior varies. The capability does not reject mock locations. A dead
native channel prevents the Dart caller from confirming hardware teardown. iOS
accepts at most 1,000 ms of future timestamp skew and rejects larger future dates;
this is not a general stale-sample clamping rule.

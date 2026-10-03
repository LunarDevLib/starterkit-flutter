# Push

## Status and boundary

Push provides native notification permission adapters and a disconnected Dart
provider facade in the existing `starterkit_platform` plugin.
There is **no bundled production push provider**, vendor SDK, APNs registration
delegate, event channel, background service, notification posting or message bus.
Provider credentials, physical permission prompts, device lifecycle, delivery,
signing and iOS 13 execution remain **NOT_RUN**.

The default `SampleApp` does not import or compose Push. Construction is inert;
`StarterPushCapability` defaults to disabled. Every disabled action returns
`push.disabled` before any channel call, provider registration or stream access.
Permission, registration and message activation are separate explicit actions.
None is a delivery receipt or an instruction to route/open a URL.

## Public API and product provider

```dart
import 'package:starterkit_platform/starterkit_platform.dart';

// productPushProvider is a product implementation of PushProvider, not a
// provider supplied by this starter kit. Construction does not start it.
final push = StarterPushCapability(
  enabled: true,
  provider: productPushProvider,
);
final permission = await push.permissionStatus(); // Does not register.
// Request only after an explicit product decision/action:
// final permission = await push.requestPermission();
final registration = await push.register(); // Does not request permission.
final messages = push.activateMessages(onMessage: (message) {
  // Product validates its own meaning; do not automatically navigate or log it.
});
// On product lifecycle teardown:
await messages.close();
```

`PushProvider` is a Dart port with just:

```dart
Future<PushProviderRegistration> register();
Stream<Object?> get messages;
```

The product implements SDK/APNs configuration, platform callback forwarding,
registration policy, credentials, token upload/storage/removal, retry/refresh,
logout and delivery outside this facade. For example, a successful provider
registration returns
`PushProviderRegistration(PushProviderRegistrationKind.registered, token: token)`.
Other typed provider kinds are `denied`, `unavailable`, `cancelled`, `failure`;
they must not include a token. No provider implementation or fake is shipped in
production; injected fakes exist only in unit tests.

### Registration

`register()` returns `PushRegistrationResult` with final `kind`, `code`, and
nullable `token`. Tokens are opaque and case-preserved, including supplied edge
spaces; no universal APNs hex format is imposed. A token must be nonblank,
at most 4096 UTF-8 bytes, valid UTF-16 and free of C0/C1 controls. Only a validated
registered result exposes a token. The facade never caches, uploads or logs it.

| Kind | Fixed code |
|---|---|
| registered | `push.registered` |
| denied | `push.registration_denied` |
| unavailable | `push.disabled`, `push.provider_not_configured`, `push.provider_unavailable` |
| cancelled | `push.registration_cancelled` |
| invalid | `push.invalid_provider_result` |
| failure | `push.registration_failed` |

Provider exceptions return a fixed failure without SDK text/details. Invalid
tokens or inconsistent typed provider outcomes return invalid with no token.
There is no automatic permission request, message subscription, retry, timeout,
registration cancellation, refresh or logout API. Provider ownership does not
imply those product actions have been implemented or tested.

### Permission channel

`permissionStatus()` and `requestPermission()` return `PushPermissionResult`
(`PushPermissionKind kind`, `String code`). They use
`starterkit/platform/push`, respectively `permissionStatus` and
`requestPermission`, with **null arguments**. They do not access the provider;
an enabled facade may query permission even without a configured provider.

Native response is exactly `{kind: String, code: String}`. Accepted pairs:

| Kind | Code |
|---|---|
| granted | `push.permission_granted` |
| notDetermined | `push.permission_not_determined` |
| denied | `push.permission_denied` |
| restricted | `push.permission_restricted` |
| unavailable | `push.permission_not_configured`, `push.activity_unavailable`, `push.platform_unavailable` |
| conflict | `push.operation_in_progress` |
| invalid | `push.invalid_arguments` |
| failure | `push.permission_failed`, `push.engine_detached`, `push.activity_detached`, `push.dispatch_failed` |

Extra keys, wrong types, unknown or mismatched pairs return
`failure/push.invalid_native_response`. Missing plugin maps to
`unavailable/push.platform_unavailable`; other transport exceptions map to
`failure/push.permission_failed`. `unavailable/push.disabled` and
`failure/push.invalid_native_response` are Dart-only results, not accepted native
replies. No raw error or provider payload is exposed in fixed permission codes.

Native contract: Android API 33+ requires product-configured
`POST_NOTIFICATIONS` before a prompt; absent configuration returns unavailable.
API 24–32 reports actual OS notification enablement without a runtime request.
iOS queries/requests alert, badge and sound using UNUserNotificationCenter only
on explicit actions; authorized/provisional/ephemeral map to granted. The plugin
does not call `registerForRemoteNotifications`, install a notification delegate,
or configure entitlements/background delivery. Product integration owns those
choices. These are native contract statements, not device evidence from mocks.

## Explicit message activation

`activateMessages({required void Function(PushMessage) onMessage})` returns a
`PushMessageActivation`. Only enabled, configured calls read/listen to
`provider.messages`; they never register or request permission. The handle
initially reports `active/push.messages_active`, or
`unavailable/push.disabled` / `unavailable/push.provider_not_configured`.

Each inbound raw value must be a map with **only** `title`, `body`, optional
`data`. A supplied title/body must be a string (not null), title ≤256 UTF-8 bytes,
body ≤2048 bytes; at least one must be nonblank. Text is preserved unchanged.
All strings reject malformed UTF-16 and C0/C1 controls, including tabs/newlines.
Data, if supplied, must be a String→String map with ≤32 entries, nonblank
keys ≤64 UTF-8 bytes and values ≤512 UTF-8 bytes. Empty data/values are permitted.
Keys normalized to lowercase ASCII letters must not contain `password`,
`secret`, `token`, `authorization`, `credential`, `apikey`, or `privatekey`.
This scoped key check is not universal secret detection: never supply secrets
in any field or log tokens/payloads.

Accepted `PushMessage` fields are final; its data map is an immutable copy, not
a reference to the provider's mutable map. No raw payload is returned on failure.
Invalid messages are dropped and terminally set
`failure/push.invalid_message`; provider getter/listen/stream/cancellation or
product `onMessage` exceptions set `failure/push.message_failed`. No raw
exception is logged or rethrown. A failure stops/fences further callbacks and
cancels the subscription. The handle's `kind`/`code` reflect its current status;
they are not a delivery promise or a background error/event stream.

`Future<void> close()` fences callbacks immediately and cancels at most once.
It is idempotent, including after errors; existing terminal failure/unavailable
status remains. Normal close or stream completion reports
`closed/push.messages_closed`. No later callback is delivered through that handle.
There is no automatic replay, cache, navigation or shared queue. Each activation
owns one ordinary StreamSubscription; the provider chooses its stream's
single/broadcast semantics. Unsupported repeated subscription fails safely.

## Activation and removal

1. Keep the default app disconnected. Compose an enabled facade only in the
   product feature requiring Push, using the existing platform dependency.
2. Implement/configure the product provider deliberately. Add any required SDK,
   credentials, Android permission, APNs entitlement/delegate or background
   configuration only in that product's explicit integration scope, not here.
3. Make permission requests and remote registration separate user/product
   decisions. Handle all fixed denied/unavailable/cancelled/invalid/failure
   outcomes; lack of an optional provider must not break the baseline app.
4. Activate messages explicitly, validate product-specific semantics without
   automatic routing, and retain/close the handle on product teardown.
5. Verify physical prompts, SDK/APNs callbacks, delivery and signed devices for
   the actual product; permission/registration/activation success is insufficient.

To deactivate, disable/remove product composition and close any previously
activated handles; changing a new instance to disabled does not close an old
handle. Remove product handlers/provider configuration and product-owned token
state/SDK registration according to its lifecycle. No facade logout/unregister
guarantee is implied. Keep shared platform code/dependencies while other
capabilities use them; remove the dependency only when none remain.

## Verification boundary

Focused tests: `packages/starterkit_platform/test/push_test.dart`, injected
test-only providers and mock permission channel. They cover inert defaults,
action separation, strict permission pairs, bounded tokens/messages, immutable
snapshots, fixed failures, explicit subscription and idempotent close/late fences.
**ACTUAL_PASS:** 19 Push tests plus all 53 existing platform Dart tests (72 total)
in an isolated Dart-only package copy using Flutter 3.47.4/Dart 3.13.3. Locked
offline resolution, package analysis and owned-file format checks passed.
Android production Kotlin compilation and seven Push policy tests passed locally.
Swift tests and native app integration require the existing CI checks; unit tests
do not establish physical permission prompts or delivery. No production provider,
remote endpoint or device is exercised.

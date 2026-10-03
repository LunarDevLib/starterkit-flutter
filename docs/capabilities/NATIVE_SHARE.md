# Native Share

## Status and scope

Native Share is an optional, disconnected API in the existing
`starterkit_platform` plugin. Dart source and focused contract tests are provided;
native adapter/build and integration evidence belongs to the assigned native/CI
lanes. Actual chooser execution, recipient delivery, device/provider behavior and
production signing are **NOT RUN** by the Dart checks.

The capability shares a product-supplied text, HTTPS URL and/or one image-file
URI only after an explicit enabled call. It does not acquire images/files, fetch
URLs, navigate, create files/caches, or add app UI, dependencies, permissions,
default navigation, startup work or automatic sharing. The default `SampleApp`
does not import or compose it. No vendor SDK/service is required.

## Public contract

```dart
import 'package:starterkit_platform/starterkit_platform.dart';

const share = StarterNativeShareCapability(enabled: true);
final result = await share.share(
  text: 'Product-selected message',
  httpsUrl: 'https://example.com/page',
  // Supply the source rectangle in the attached iOS host view's logical points.
  anchor: const NativeShareAnchor(x: 12, y: 24, width: 80, height: 40),
);
// Inspect result.kind and result.code; no outcome proves recipient delivery.
```

Construction defaults to `enabled: false`. Disabled calls return
`unavailable/share.disabled` **before validation, file access or any native call**.
`share({String? text, String? httpsUrl, String? fileUri,
NativeShareAnchor? anchor})` returns an immutable `NativeShareResult` with final
`kind` and `code`. There are no public operation IDs, timeout/cancel API or queue.
The anchor has final `double` fields `x`, `y`, `width`, `height`; origin must be
finite/nonnegative, dimensions finite/positive, and both extents (`x + width`,
`y + height`) finite. Native iOS also validates it
against the attached presentation view. Dart does not invent host bounds.

### Payload rules

- At least one supplied value must be nonempty. Empty text may accompany a valid
  URL/file; an explicitly supplied empty URL or file URI is invalid.
- Text is preserved exactly, including spaces and Unicode; no trimming or
  normalization. Maximum 4000 Unicode code points and 16384 UTF-8 bytes. Lone
  UTF-16 surrogates and C0/C1 controls are rejected, including tabs/newlines.
- HTTPS URL maximum 2048 UTF-8 bytes; strict ASCII DNS host/authority, HTTPS only,
  no whitespace/control, credentials, fragment, non-443 port, trailing-dot host,
  malformed percent escapes or suspicious authority. An explicit port must be
  exactly `443`; URLs are forwarded unchanged, never fetched or opened.
- Sensitive query keys are refused case-insensitively in raw **and once-decoded**
  names, including substring matches from the frozen list: `token`,
  `access_token`, `authorization`, `auth`, `api_key`, `key`, `password`, `secret`,
  `session`, `code`. Single percent-encoded names do not bypass the Dart check;
  native validation remains authoritative for nested encoding. This bounded rule is
  not universal secret detection; products must not supply secrets in any field.
- One `fileUri`, maximum 2048 UTF-8 bytes; no controls, query, fragment,
  credentials, port, malformed percent escapes or arbitrary scheme. Dart checks
  URI syntax and snapshots immutable wire values but performs **no file I/O**.
  Actual readability, type/size and authorization are native/product concerns.

### Platform-specific file and presentation behavior

- **Android:** supply an authorized `content://` image URI. Native validation
  requires readable bounded size ≤10 MiB, uses fixed `image/*`, scoped read grant
  and ClipData for the explicit system chooser. No new FileProvider or broad
  permission is introduced. Successful launch reports `presented`; Android
  cannot reliably infer chooser cancellation or recipient delivery.
- **iOS:** supply a product-selected `file://` URI for an existing readable
  regular file ≤10 MiB, not a directory or network URL. The product owns access
  authorization and the host-relative anchor. Native presentation uses
  UIActivityViewController only with an attached presentation host; UIKit
  completion maps to `completed` or `cancelled`, not verified delivery.
- Dart accepts either platform's transport syntax; it does not make a content
  URI work on iOS or a file URI work on Android. There is no universal image
  format/provider guarantee. Native missing access/host fails safely.
- Native iOS permits one pending callback, rejects a conflicting operation, and
  clears/settles its pending operation on detach. This is the native contract,
  not device-runtime evidence established by Dart mocks. No hardware dismissal,
  background completion or artificial deadline guarantee is implied.

## Channel and outcomes

Channel `starterkit/platform/share`, method `share`; optional keys only
`text`, `httpsUrl`, `fileUri`, `anchor`. An anchor map has exactly
`x`, `y`, `width`, `height` as doubles. The accepted payload is snapshotted
synchronously before the first asynchronous boundary.

Native response is exactly `{kind: String, code: String}`. Accepted pairs:

| Kind | Code |
|---|---|
| presented | `share.presented` |
| completed | `share.completed` |
| cancelled | `share.cancelled`, `share.engine_detached` |
| invalid | `share.invalid_payload` |
| unavailable | `share.platform_unavailable`, `share.host_unavailable`, `share.file_unavailable` |
| conflict | `share.operation_in_progress` |
| failure | `share.platform_failure` |

Missing plugin maps to `unavailable/share.platform_unavailable`; platform/other
transport exceptions map to fixed `failure/share.platform_failure` without raw
details. Wrong keys/types, unknown or mismatched pairs return
`invalid/share.invalid_native_response`. `share.disabled` and
`share.invalid_native_response` are Dart-only outcomes, not trusted native replies.
No result means “delivered,” “received,” or authorization for a later action.

## Activation and deactivation

1. Use the existing `starterkit_platform` dependency; no new plugin/vendor or
   baseline platform configuration is needed for this capability.
2. Import/compose it only in the product action that explicitly needs sharing,
   and enable it deliberately. Leave `SampleApp` and its routing untouched.
3. Product-select the bounded payload, authorize any file access, and supply the
   iOS anchor from the actual presentation host. Do not log payloads/query values.
4. Handle every result kind safely. Cancellation is normal; platform/file/host
   unavailability must not break the baseline app. A chooser launch or completion
   is not recipient confirmation.
5. Validate real chooser, device/provider and native integration behavior for
   the product separately from Dart contract tests.

To deactivate, construct with `enabled: false` or remove the product action,
imports and composition; release product-owned access/grants/resources through
the product's existing lifecycle. Do not remove shared platform plugin code or
dependencies needed by other capabilities. Remove the plugin dependency only
when no remaining platform capability uses it.

## Verification boundary

Focused unit tests: `packages/starterkit_platform/test/native_share_test.dart`.
**ACTUAL_PASS:** 13 Native Share tests and all 40 existing platform Dart tests
(53 total) in an isolated Dart-only package copy with Flutter 3.47.4/Dart 3.13.3;
locked offline resolution, package analysis and owned-file format checks passed.
They exercise disabled zero native/file calls, payload preservation and bounds,
encoded sensitive keys, platform URI syntax, immutable anchor/wire snapshot,
strict response pairs and fixed transport failures. They do not execute native
choosers, file permission grants, UIKit/Activity lifecycle or delivery. Native
and final source/consumer CI validation remain separately owned.

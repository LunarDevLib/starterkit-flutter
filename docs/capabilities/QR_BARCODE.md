# QR / Barcode

## Status

- Classification: Optional capability in a separate plugin package
- Implemented: Dart API and native adapter source; final consumer integration evidence pending
- Tested: 10 Dart contract tests and 31 direct Android JVM tests; Swift and consumer CI pending
- Default connected: No
- Default startup work, decoder worker, camera access, and permission: None
- Device/provider test: NOT RUN

## Purpose and scope

Decode a still image supplied as encoded bytes. This is separate from Gallery:
Gallery lets a person select an image, while this package only decodes bytes that
the consuming product already has. There is no live camera, frame stream, camera
picker, photo picker, filesystem path, URL fetch, permission prompt, navigation,
retention, or startup service in this capability.

Decoded text is untrusted data. The adapter preserves payload text exactly and
does not trim, normalize, execute, navigate to, fetch, or interpret a URL or path.
Products must apply their own domain validation before acting on decoded content.

## Flutter API

Package: `starterkit_qr_barcode` in `packages/starterkit_qr_barcode`.

```dart
import 'dart:typed_data';

import 'package:starterkit_qr_barcode/starterkit_qr_barcode.dart';

const qr = StarterQrBarcodeCapability(enabled: true);
final QrBarcodeResult result = await qr.decode(Uint8List.fromList(imageBytes));
if (result.isSuccess) {
  for (final code in result.codes) {
    // Treat code.value as untrusted text; validate for the product's use.
  }
}
```

Construction defaults to `enabled: false`. Disabled calls return
`unavailable/qr.disabled` without validating or copying input and perform zero
native calls. Enabled input must be nonempty and at most 10 MiB. Empty and
oversized input return `invalid/qr.invalid_image` and
`invalid/qr.image_too_large` respectively, before platform invocation. Accepted
bytes are defensively snapshotted synchronously before the first asynchronous
boundary. There is no public request ID, timeout, or cancellation API; the
MethodChannel correlates concurrent replies.

`QrBarcodeResult`, its `codes` list, and each `QrBarcodeCode` are immutable.
Formats are `QrBarcodeFormat.qr`, `.ean13`, and `.code128`, mapped on the wire to
`QR`, `EAN13`, and `Code128`. Success requires 1–16 valid codes. Each exact,
nonempty payload is at most 2048 UTF-8 bytes; their aggregate is at most 32768
UTF-8 bytes. Malformed Unicode and C0/C1 controls (U+0000–U+001F,
U+007F–U+009F) are rejected. Values are not silently truncated. These Dart
transport safety bounds are implementation policy, not claims about identical
native normalization.

The channel is `starterkit/qr_barcode`, method `decodeImage`, with the exact
argument `{bytes: Uint8List}`. Native responses use only the frozen kind/code
pairs and exact keys: non-success `{kind, code}`, success `{kind, code, codes}`;
each code has exactly `{value, format}`. Unknown pairs, wrong types, unexpected
keys, invalid payloads/formats/counts, or malformed result lists fail closed as
`invalid/qr.invalid_native_response`. Missing plugin maps to
`unavailable/qr.platform_unavailable`; platform and other transport exceptions
map to the fixed `failure/qr.platform_failure`. Raw exception text is not
returned.

## Native behavior and evidence

The package is isolated from the root/default app dependency graph. Android uses
the plugin-local ZXing core 3.5.3 dependency (Apache-2.0); iOS uses system
ImageIO/Vision. Registration is intended to set up the channel only; decoding is
explicit and off-main. Android bounds dimensions before rasterization and limits
its working bitmap to 8,000,000 pixels by downsampling. That Android working
limit is not an iOS input rejection rule. Both adapters are scoped to QR,
EAN-13, and Code 128, but unsupported-format reporting is asymmetric: Android's
all-format detection can report unsupported, while iOS requests the three
supported symbologies and may report no result for another format.

Native source/build, production decoder fixtures, concurrency/lifecycle fences,
and source/renamed opt-in linkage require their assigned native and integration
CI evidence. Documentation and Dart channel tests do not establish those gates.
The iOS simulator-only Vision revision-1/CPU workaround is not a device behavior
claim. Device/provider testing, image-quality/orientation coverage, production
signing, live-camera behavior, and real iOS-device behavior are **NOT RUN**.

## Dependencies and permissions

The Dart package has no third-party runtime package dependency. Android's pinned
ZXing 3.5.3 decoder is isolated to this optional plugin; iOS relies on system
ImageIO/Vision. No camera, media, storage, or network permission is introduced
for still-image decoding. Do not infer plugin/vendor absence in built artifacts
from plist or manifest checks alone; graph, registrant, and linkage evidence is
required for default and opt-in consumers.

## Activation

1. Add `starterkit_qr_barcode` only to the explicit consuming product, not the
   starter's default dependency graph.
2. Import and construct `StarterQrBarcodeCapability(enabled: true)` only in the
   product action that needs still-image decoding.
3. Supply bounded encoded image bytes from the product's separately chosen
   source. This capability itself does not select or acquire an image.
4. Handle every result kind and validate payload semantics for the product
   before using a decoded value; never execute or navigate based solely on it.
5. Verify the actual source-identity and renamed opt-in consumers, and separately
   confirm the default consumers remain unconnected and free of the plugin.

Activate Gallery independently if the product needs a picker; do not couple its
activation to this decoder. Do not add camera/picker behavior to this package,
modify `SampleApp`, or add decoder permissions. The sample app remains generic
and network-free.

## Tests and limitations

- Dart channel boundary tests: `packages/starterkit_qr_barcode/test/`.
- Android production plugin compilation and 31 direct JVM tests passed, including
  real ZXing roundtrips and production-used worker/lifecycle helpers. Android
  BitmapFactory, Handler, engine callbacks, and app linkage need separate evidence.
- iOS shared-production ImageIO/Vision fixtures and native plugin build:
  integration CI pending.
- Default absence and source/renamed opt-in registration/linkage evidence:
  integration CI pending.

Detach invalidates the caller's operation but does not forcibly interrupt CPU
decoding; process admission remains held until the worker unwinds. If the Android
main delivery boundary is lost, callback references are cleared without replying
off-main, and the Dart Future may remain unresolved. No completion timeout or
hardware/resource-teardown guarantee is implied.

The package is still-image-only and does not guarantee barcode detection for any
particular camera, resolution, orientation, image quality, or device. Native
decoder execution and device behavior must not be inferred from Dart tests.

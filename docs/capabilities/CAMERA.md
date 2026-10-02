# Camera

## Status

- Classification: Optional Capability
- Implemented: Yes
- Default connected: No
- Startup capture/prompt: No
- Baseline permission: None

## Purpose

Capture one still image only after an explicit product action and return a
bounded capability-owned temporary copy.

## Semantic contract

- No camera access or permission prompt occurs at startup.
- Success, cancellation, denial, unavailability, invalid output and failure are distinct.
- Result bytes and pixel count are bounded before product use.
- Temporary output is private to the application and cleanup is explicit.
- The capability does not provide continuous preview, video recording, cropping,
  upload, retention policy, or background capture.

## Flutter API

Package: `packages/starterkit_platform`

```dart
final camera = StarterCameraCapability(
  androidFileProviderAuthority: 'com.example.app.fileprovider',
);

final permission = await camera.requestPermission();
final result = await camera.capture();
if (result.isSuccess) {
  final image = result.image!;
  // consume the bounded temporary file
  await camera.cleanup(image);
}
```

Constructing the capability has no platform side effect.

## Android

The implementation launches the system/external camera app with
`MediaStore.ACTION_IMAGE_CAPTURE` and a product-owned `FileProvider` output URI.

The Starter Kit does **not** declare a FileProvider or `CAMERA` permission. For
this external-intent flow, activation should normally avoid declaring
`CAMERA`; declaring it changes Android permission requirements.

Activation must add a narrow provider owned by the product, for example:

```xml
<provider
    android:name="androidx.core.content.FileProvider"
    android:authorities="${applicationId}.fileprovider"
    android:exported="false"
    android:grantUriPermissions="true">
    <meta-data
        android:name="android.support.FILE_PROVIDER_PATHS"
        android:resource="@xml/file_paths" />
</provider>
```

The provider path should be limited to the capability cache directory, for example:

```xml
<paths xmlns:android="http://schemas.android.com/apk/res/android">
    <cache-path name="starterkit_media" path="starterkit_media/" />
</paths>
```

The Dart capability accepts only the matching
`<applicationId>.fileprovider` authority. URI grants are carried only on the
explicit camera intent and revoked after the result. The implementation does not
require a package-visibility `<queries>` declaration; missing camera handlers are
reported from the launch attempt.

## iOS

The implementation uses AVFoundation authorization and
`UIImagePickerController`. A non-empty `NSCameraUsageDescription` must be
supplied by the consuming product before permission request/capture is allowed.

Permission request and capture remain separate explicit operations.

The frozen project builds with Flutter 3.47.4. Although its checked-in iOS
deployment declarations say iOS 13, Flutter's build migration raises the
effective built minimum to iOS 15. iOS 15 is therefore the supported runtime
floor; the source declaration is not evidence of iOS 13 support.

## Result bounds

Default limits:

- 10 MiB maximum output bytes
- 40 million maximum pixels

Caller-provided limits cannot exceed:

- 20 MiB
- 50 million pixels

Invalid/oversized output is rejected and deleted.

## Activation

1. Keep/add `starterkit_platform`.
2. Android: add a private cache FileProvider with the exact product authority.
3. iOS: add a clear `NSCameraUsageDescription`.
4. Present camera UI only from an explicit product action.
5. Request iOS camera permission in context.
6. Handle every `MediaResultKind`.
7. Define retention and call `cleanup` when the temporary file is no longer needed.
8. Run platform/device checks for actual camera availability and permission dialogs.

## Deactivation

Remove camera UI/composition, Android FileProvider/path XML used only for Camera,
iOS usage description, and related retained files. Remove `starterkit_platform`
only when no other capability in that package is used.

## Tests

- Dart contract tests: `packages/starterkit_platform/test/`
- Android media policy tests: `packages/starterkit_platform/android/src/test/`
- iOS media policy tests: `packages/starterkit_platform/ios/Tests/`
- Source and renamed Android/iOS builds compile the native plugin in CI.

Real camera capture and permission dialogs require device/integration validation.

## Security notes

Do not expose broad file paths. Keep FileProvider roots narrow, use temporary
private output, do not log image paths or metadata, and apply separate product
policy before upload or persistence.

## Known limitations

Android uses an external camera intent rather than an embedded camera preview.
iOS uses the system camera picker. The Starter Kit does not claim device-level
capture behavior from simulator/unit evidence alone.

On Android, Camera and Gallery share 256 request-code allocations per app-process
lifetime (`0x5300`–`0x53ff`). Each launch attempt that allocates a code consumes it,
even if launch fails; codes are never reused after detach, failure or plugin
replacement, preventing stale external ActivityResults from being reassigned to
later media operations. Exhaustion returns `MediaResultKind.failure` with code
`media.request_codes_exhausted` before picker launch; the capability does not
automatically restart the process. Availability and permission checks do not
consume codes. Consuming products must keep this range exclusive to Media:
Android provides no global request-code registry guaranteeing freedom from
collisions with deliberately overlapping plugins. This Android-only limit is
neither an iOS limit nor a product-delivery guarantee.

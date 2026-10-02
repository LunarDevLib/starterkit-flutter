# Gallery

## Status

- Classification: Optional Capability
- Implemented: Yes
- Default connected: No
- Startup picker/prompt: No
- Baseline Photos/storage permission: None

## Purpose

Let a user explicitly select one still image through the platform picker and
return a bounded capability-owned temporary copy.

## Semantic contract

- Selection starts only after an explicit product action.
- Cancellation is a normal non-success outcome.
- Broad media-library/storage access is not requested by the baseline.
- Only image content is accepted.
- Result bytes and pixel count are bounded before product use.
- The returned file is a private temporary copy with explicit cleanup.

## Flutter API

Package: `packages/starterkit_platform`

```dart
final gallery = StarterGalleryCapability();
final result = await gallery.pickImage();

if (result.isSuccess) {
  final image = result.image!;
  // consume bounded private copy
  await gallery.cleanup(image);
}
```

## Android

API 33+ uses the platform Photo Picker. Older supported Android versions use
`ACTION_OPEN_DOCUMENT` with `image/*`.

No broad storage permission is declared. The selected `content://` stream is
copied into the capability cache with a hard byte cap, then image dimensions are
inspected before the path is returned.

## iOS

iOS 14+ uses `PHPickerViewController`, which does not require broad Photos
authorization for user selection. The Starter Kit intentionally reports Gallery
as unavailable on iOS 13 instead of falling back to a broad photo-library access
flow.

The effective project runtime floor is iOS 15: the frozen Flutter 3.47.4 build
migrates the checked-in iOS 13 deployment declarations to iOS 15. The retained
iOS 13 availability guard reflects the picker's API availability and fallback
behavior; it does not establish iOS 13 support for a built app.

The provider file is checked for size and dimensions before being copied into the
capability-owned temporary directory.

## Result bounds

Gallery uses the same `MediaLimits` contract as Camera:

- default 10 MiB / 40 million pixels
- hard ceiling 20 MiB / 50 million pixels

## Activation

1. Keep/add `starterkit_platform`.
2. Add explicit product UI that opens Gallery.
3. Do not add storage/Photos permissions solely for this picker contract.
4. Handle cancel/unavailable/invalid/failure distinctly.
5. Define retention and call `cleanup` after use.
6. Test real picker/provider behavior on supported devices.

## Deactivation

Remove picker UI/composition and any product retention logic. There should be no
Gallery-only permission to remove for this contract. Remove
`starterkit_platform` only if no other platform capability uses it.

## Tests

- Dart contract tests: `packages/starterkit_platform/test/`
- Android media policy tests: `packages/starterkit_platform/android/src/test/`
- iOS media policy tests: `packages/starterkit_platform/ios/Tests/`
- Source and renamed Android/iOS builds compile the plugin in CI.

Actual OS picker/provider behavior remains device integration evidence.

## Security notes

Treat selected image content as untrusted. Bound size before copy/use, inspect
dimensions without full decode where possible, avoid logging source URI/path or
metadata, and never execute data derived from image metadata.

## Known limitations

One still image only. No editing, multi-select, cloud-provider guarantee,
persistent URI permission, or product upload/storage behavior is included.
iOS 13 is below the effective project runtime floor.

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

# WebView

## Status

- Classification: Optional Capability
- Implemented: Yes
- Default connected: No
- Startup side effect: No WebView creation or navigation
- Default permission request: No

## Purpose

Embed a specifically trusted web experience behind an explicit Android/iOS
native security boundary.

## Semantic contract

- Only the exact configured HTTPS origin is internal.
- HTTP, malformed URLs, ambiguous authorities, unknown schemes and unapproved
  frame navigations are blocked.
- Untrusted HTTPS or allowlisted app schemes are externalized only from an
  explicit user-initiated main-frame navigation.
- Mixed content is denied on Android.
- TLS errors are never bypassed.
- Browser camera, microphone, geolocation and file-selection surfaces are
  denied by default where the native platform exposes a denial hook.
- Bridge is disabled by default.
- When bridge is enabled, source origin and main-frame status are checked at
  the native boundary before the request is parsed.
- Bridge envelopes are bounded to 16 KiB. The only v1 sample method is
  `app.getVersion`; unknown methods are rejected.
- Bundled local content is isolated and never receives the trusted remote
  bridge authority.

## Flutter API

Package: `packages/starterkit_webview`

```dart
final config = StarterWebViewConfiguration(
  trustedOrigin: 'https://app.example.com',
  startUrl: 'https://app.example.com/start',
);

StarterWebView(
  configuration: config,
  onCreated: (controller) async {
    await controller.loadStart();
  },
);
```

Constructing the configuration has no platform effect. Plugin registration
registers only a platform-view factory. A native WebView is created only when
`StarterWebView` is composed, and no navigation starts until the host calls
`loadStart()` or `load()`.

## Android

The plugin owns the native WebView and uses AndroidX WebKit 1.17.1.

Bridge activation additionally requires runtime support for
`WEB_MESSAGE_LISTENER` and `DOCUMENT_START_SCRIPT`. The JavaScript object
is injected only for the configured trusted origin. The message listener still
checks `sourceOrigin` and `isMainFrame` before accepting an envelope.

The capability manifest declares no permission. A consuming product that loads
remote content must deliberately add:

```xml
<uses-permission android:name="android.permission.INTERNET" />
```

The Starter Kit baseline intentionally does not add it.

## iOS

The plugin owns a `WKWebView`. Navigation uses `WKNavigationAction`
main-frame/link-activation metadata. Bridge messages validate
`WKScriptMessage.frameInfo.isMainFrame`, the frame request URL, and
`securityOrigin` against the configured trusted origin. Authentication
challenges use default system handling; the capability never accepts an
invalid server trust.

No usage description or entitlement is added by the capability.

## Activation

1. Confirm the web product and exact trusted HTTPS origin.
2. Keep the local `starterkit_webview` dependency or add it if it was pruned.
3. Add Android `INTERNET` only when remote content is actually needed.
4. Construct `StarterWebViewConfiguration` with the exact origin.
5. Compose `StarterWebView` in an intentional product screen/route.
6. Call `loadStart()` or a trusted `load()` URL explicitly.
7. Leave bridge disabled unless the web/native contract was reviewed.
8. If bridge is enabled, verify `bridgeAvailable()` on target Android WebView
   versions and test trusted main-frame, subframe, untrusted-origin, malformed
   envelope and unknown-method behavior.
9. Run unit, app build, simulator/device and product navigation checks.

## Deactivation / pruning

Remove the screen/route/composition, product-owned network permission and any
web credentials or domain configuration. If the product will not use WebView,
the local dependency and `packages/starterkit_webview` source may be pruned.

## Tests

- Dart policy/config tests: `packages/starterkit_webview/test/`
- Android JVM policy tests: `packages/starterkit_webview/android/src/test/`
- iOS Swift policy tests: `packages/starterkit_webview/ios/Tests/`
- Source and renamed Android/iOS app builds compile the native plugin in CI.

These checks are not a claim of physical-device WebView behavior. Android
runtime bridge/navigation instrumentation and physical-device WebKit behavior
remain separate integration evidence.

## Known limitations

- v1 exposes only the safe sample bridge method `app.getVersion`; there is no
  generic product bridge API.
- Android bridge availability depends on the installed WebView implementation
  supporting the required AndroidX WebKit features.
- The capability does not establish trust in the web application's own backend,
  content, authentication or authorization.

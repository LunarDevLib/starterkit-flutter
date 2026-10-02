# Flutter Template architecture

## Minimal SampleApp baseline

The default runtime is a small, network-free in-memory sample app, not a product starter core.

```text
main.dart → bootstrap() → ProviderScope
                          └─ sampleRepositoryProvider = InMemorySampleRepository
                             → SampleApp → sampleRouterProvider
                               ├─ / → sample list
                               └─ /samples/:id → sample detail lookup by ID
```

Bootstrap injects only `InMemorySampleRepository`. It supplies three stable records (`first`,
`second`, `third`). List and detail have independent loading/content/error states; detail lookup
distinguishes not-found from failure. Error states can retry, detail has a back action, and unknown
routes render a separate fallback page. Sample data strings are fixed English; UI chrome is localized
with en/ko ARB resources. Light and dark themes follow system preference. Some controls expose
semantics labels/actions; this is not a claim of comprehensive accessibility or device validation.

The default composition does not initialize authentication, network clients, persistent preferences,
secure storage, telemetry, crash reporting, push, or background networking.

## Growth rules

- Keep feature behavior and contracts under `lib/features/<feature>/`; include only layers justified by
  actual responsibilities.
- Use feature-local state and repository boundaries when the feature needs asynchronous or replaceable
  data access. Avoid abstractions without a concrete need.
- Keep presentation responsible for rendering state and translating user actions; put data access behind
  the feature's repository contract.
- Compose concrete dependencies at the app boundary (`bootstrap`/`ProviderScope`). Do not introduce a
  global mutable service locator or hidden process-wide dependency state.
- Do not add a pass-through use-case layer. Add application orchestration only when it owns meaningful
  policy or coordination.
- Add routes deliberately; test observable state, direct route entry, ID handling, errors and navigation.
- Keep ARB as localization input and regenerate generated output with `flutter gen-l10n`.
- Treat new platform permissions, plugins, network access and persistent storage as explicit product
  decisions, not automatic template defaults.

## Bootstrap and validation

`tool/bootstrap_project.dart` replaces package name, display name, bundle/application ID and custom URL
scheme in a project copy. It supports dry-run review, validation and staged rollback, but not whole-repo
atomicity, signing setup, secrets or product security review. Scheme registration is retained as a
renameable identity; direct route tests do not prove OS-delivered external deep linking.

`tool/validate_template.dart` checks template-specific identity and policy invariants. CI additionally
gates locked dependency resolution, localization generation, formatting, analysis, tests, Android debug
APK, unsigned iOS simulator build and a renamed-copy validation. These checks are not release signing,
real-device, external deep-link or product security evidence.


## Optional capability boundary

Optional capabilities live outside the default app composition. Their source and
native adapters may be compiled by CI, but the baseline must not import or create
them.

The WebView capability is implemented as the local `starterkit_webview` plugin.
Registration is inert: Android/iOS register only a platform-view factory. A product
must explicitly compose `StarterWebView`, create its controller, and call
`loadStart()` or `load()`.

WebView security semantics are enforced natively rather than relying only on Dart
navigation callbacks: exact trusted HTTPS origin, main-frame/user-gesture external
navigation, mixed-content denial on Android, no TLS bypass, default denial of media/
geolocation/file chooser requests where the platform exposes them, and a bridge that
is disabled by default. When the bridge is enabled, only the bounded
`app.getVersion` sample method is exposed; product-specific bridge methods require
separate review.

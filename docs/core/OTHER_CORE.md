# Optional core utilities

These small APIs are opt-in building blocks; they do not change SampleApp's
routes, bootstrap, or feature-local state.

## Deep links

`DeepLinkParser` takes the application's configured URI scheme explicitly and
parses only `scheme://app/` and `scheme://app/samples/<id>`. It returns a typed
route value or a safe `AppFailure`; unknown route paths are `notFound`, while
malformed or unsafe input is `validation`. IDs are limited to 1–80 ASCII
letters, digits, underscores, and hyphens. Input is limited to 2 KiB; an
optional `returnTo` is limited to 256 characters and must independently match
`/` or `/samples/<id>`. Duplicate, unknown, and secret-bearing query keys,
external return paths, encoded separators, traversal, fragments, and malformed
or control-bearing input are rejected. Parsing does not access app identity,
register an OS URL scheme, establish external-delivery capability, or wire a
router. Existing stable-ID navigation in the sample router remains unchanged.

## Lifecycle

`LifecycleMonitor` is inert until `start`; callers own explicit start, stop,
and dispose. Flutter `resumed` maps to foreground; `paused` and `hidden` to
background; `inactive` and `detached` retain distinct states. Stopped or
disposed monitors ignore late events. A process kill is not guaranteed to
deliver a final lifecycle event, and a recreated process does not imply or
invent prior state.

## Connectivity

`ConnectivityMonitor` uses the vendor-neutral `unknown`, `offline`, and
`onlineLike` states and the optional native package through
`StarterkitConnectivitySource`. Nothing observes connectivity by default. The
composing app must both explicitly configure the native integration and pass a
true readiness check, then intentionally call `start`. Android activation also
requires the app to declare `ACCESS_NETWORK_STATE`; absent configuration,
readiness, or native support produces `unknown` plus a safe `AppFailure`, not a
raw platform error. Stop cancels the subscription; generation fencing ignores
late values/errors. `onlineLike` is only an OS interface hint and never proves
internet or backend reachability. No remote feature-flag SDK is included.

## Flags and UI state

`FeatureFlags` is an immutable copy of local values, accepts only bounded safe
keys, and defaults unknown keys to false. `CommonUiState<T>` provides simple
loading/content/empty/error values; errors carry `AppFailure`. These utilities
do not require baseline feature adoption or impose presentation styling.

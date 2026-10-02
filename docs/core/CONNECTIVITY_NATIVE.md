# Native connectivity package

`starterkit_connectivity` is an optional low-level Flutter plugin for coarse
network-interface status. It is not part of the baseline app dependency graph
or bootstrap. Importing the package, constructing `StarterkitConnectivity`, and
registering its native plugin install only a channel; none starts a native
observer or performs a network/reachability request.

Application code opts in by subscribing:

```dart
final connectivity = StarterkitConnectivity();
final subscription = connectivity.events().listen((status) {
  // Treat this as a UI/interface hint, not proof a service can be reached.
});

// When the owning feature is no longer active:
await subscription.cancel();
```

The channel is `starterkit/connectivity/events`, a Flutter `EventChannel` whose
event payload is a single string. The exact wire values are `unknown`,
`offline`, and `onlineLike`. Unknown or malformed values decode to
`ConnectivityStatus.unknown`. The native stream starts on `onListen` and stops
on `onCancel`; teardown is idempotent and callbacks from an earlier
subscription are ignored.

On Android, apps that opt into observing must add
`<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />`
to their application manifest. The plugin only checks this declaration/grant;
it never requests permission. Without it, the subscribed stream emits
`unknown` and does not register a callback. No `INTERNET` declaration is
needed for interface inspection. Android reports `onlineLike` when the active
network advertises `NET_CAPABILITY_INTERNET`, `offline` when there is no active
network or that capability is absent, and `unknown` when inspection fails.
This capability does not verify internet or backend reachability.

On iOS 13+, the plugin lazily creates and starts `NWPathMonitor` only while
subscribed. A satisfied path maps to `onlineLike`; other path states map to
`offline`. It does not probe a host, endpoint, or backend. Native errors,
missing Android permission, or unrecognized values are represented as
`unknown` (platform stream errors may still be delivered by Flutter).
Monitoring has no default/global observer and ends when the subscription is
canceled or its Flutter engine/plugin is detached.

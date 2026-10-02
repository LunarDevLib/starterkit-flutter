# Native preferences package

`starterkit_preferences` is an optional Flutter plugin for small, non-sensitive
string preferences. It is not part of the baseline dependency graph or bootstrap.
Constructing `StarterkitPreferences` and registering the native plugin are inert;
storage is accessed only after an operation passes validation.

```dart
final preferences = StarterkitPreferences();
await preferences.write('display.name', 'Sample');
final name = await preferences.read('display.name');
await preferences.remove('display.name');
```

The frozen Dart API is `StarterkitPreferences({MethodChannel? channel})` with
`Future<String?> read(String key)`, `Future<void> write(String key, String value)`,
and `Future<void> remove(String key)`. The default channel is
`starterkit/preferences`. Calls use exactly `read {key}`, `write {key, value}`,
and `remove {key}`. Reads return a string or null; mutations return null. Extra
arguments and unknown methods are rejected before storage access.

Keys must be 1–128 ASCII bytes matching `^[A-Za-z0-9_.-]+$`. The lowercase key
with non-alphanumeric characters removed must not contain `token`, `access`,
`refresh`, `password`, `secret`, `cookie`, `auth`, `apikey`, or `credential`.
Values may be empty, but must be at most 4096 UTF-8 bytes and contain no NUL.
Both Dart and native sides validate before channel invocation/storage access.
Native errors use fixed codes: `preference.invalid_key`,
`preference.invalid_value`, `preference.invalid_arguments`,
`preference.unavailable`, and `preference.operation_failed`; no value or raw
native exception is returned.

Android lazily opens the fixed app-private `starterkit_preferences_v1` store on
a serial worker after a valid operation; successful writes/removals require
`commit()` to return true. iOS lazily addresses standard defaults under the
`starterkit.preferences.v1.` key prefix and rejects values whose stored type or
size is invalid. iOS does not call `synchronize()` or claim durable completion.
Queued work is invalidated on engine detach and accepted calls complete once;
an already executing mutation is not promised rollback. Neither platform adds
permissions, providers, services, background work, observers, startup reads,
migration, bulk APIs, or selectable suites. Android library min SDK is 23 (the
host runtime must be at least API 24); iOS deployment target is 13.0.

These general preferences are not credential storage. Do not store tokens,
passwords, secrets, or other sensitive data here. Platform backup behavior and
durability are not strengthened by this wrapper.

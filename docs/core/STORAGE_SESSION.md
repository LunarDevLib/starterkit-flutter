# Storage and session implementations

## Mobile stores

`SharedPreferencesPreferenceStore` creates `SharedPreferencesAsync` lazily. It
accepts only bounded non-sensitive keys and UTF-8 string values (4 KiB maximum).
Normalized key checks reject token, access, refresh, password, secret, cookie,
authorization, API-key, and credential names. Preferences are never a
credential fallback.

`FlutterSecureByteStore` is an operation-time adapter over
`FlutterSecureStorage`. It base64 encodes copied bytes, rejects oversized
encoded strings before decoding, then enforces the 64 KiB decoded limit. The
default Android options are the package's standard RSA-OAEP/AES-GCM options;
iOS uses `first_unlock_this_device` Keychain accessibility. Constructors perform
no plugin calls or credential reads. Platform and plugin errors become safe
`AppFailure` values without forwarding native messages.

## File logout intent

Composition supplies an existing persistent app-private directory to
`FileLogoutIntentStore`. That directory must be canonical and must not contain
symlink path components. One manager/writer in one isolate owns a marker path.
The marker content is fixed at `starterkit.logout-intent.v1\n`; malformed,
unreadable, oversized, non-file, or symlink markers fail closed. Reads consume at
most marker-size plus one byte. Unrelated stale staging files are ignored.

`markPending` creates a unique exclusive sibling stage, writes and flushes its
fixed versioned contents, closes it, and performs one same-directory rename over
the old marker. It never removes the old marker first or falls back to
copy/delete. A failed rename preserves the prior marker and cleans only its own
regular stage file. `clear` is idempotent when the marker is missing and
propagates other failures.

The durability guarantee is ordinary process restart after completed flush and
rename. There is no parent-directory fsync or abrupt-power-loss certification;
a crash before rename completion or simultaneous marker/delete failure leaves
durability unproven. Path checks reduce accidental symlink hazards but do not
claim confinement against a hostile same-UID process racing filesystem calls.

## Session manager

Construction begins in `SessionUnknown` and touches no store. `restore` checks
the logout marker before any secure read. Invalid/unreadable marker state fails
closed. `signOut` synchronously advances its generation, drops its private
credential, sets the local revocation barrier, and updates state to
`SessionSignedOut` before returning its persistence future. State-stream events
are delivered asynchronously. A single recoverable queue orders all store
operations.

Logout marks pending before attempting credential deletion, and attempts both
operations even if marking fails. Successful logout retains the marker. Only an
explicit successful sign-in (mark pending, write copied credential, clear
marker) removes it and clears local revocation. Generation checks prevent a
stale restore or sign-in from publishing credentials or clearing a newer
logout. Both marker and deletion failures report
`session.logout_durability_unproven`. Disposal invalidates authorization and
events but waits for already queued logout persistence to finish.

Session states contain no credential. `copyCredentialForAuthorization()` is an
explicit, copied in-memory access point for a later authorization boundary;
there is no implicit credential restore outside an explicit `restore()` call,
JWT/OAuth parsing, refresh policy, or startup composition here.

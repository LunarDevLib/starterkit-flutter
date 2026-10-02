# Network boundary

`HttpApiClient` is an explicit, inert-by-construction implementation of the
`ApiClient` contract. It uses `package:http` and a request-owned `IOClient`; no
client is created until `execute` passes request validation. The base endpoint
must be an HTTPS URI with a host, no credentials/query/fragment, and a trailing
slash. Its effective path is checked for traversal, encoded separators, and
controls. Cleartext endpoints are not supported.

Requests are relative to that endpoint. Paths are checked again at execution,
including encoded traversal and encoded separators; query data is supplied
separately. Transport-managed headers (including authorization, cookies,
framing, caller-supplied `Accept-Encoding`, and proxy fields) are rejected
case-insensitively. The transport sets `Accept-Encoding: identity` explicitly.
An authenticated request explicitly invokes its injected `AuthorizationProvider`;
there is no credential restoration or storage access. An unauthenticated request
never invokes it. Authorization values must be complete, nonempty, bounded, and
free of control characters.

`NetworkPolicy` documents the shared request/response bounds and supplies the
default whole-operation timeout (30 seconds). A call's timeout includes
authorization, send, and streamed response consumption. Cancellation and
deadline abort the request stream, best-effort cancel response consumption,
and synchronously close the request-owned client. Cancellation cleanup is not
awaited, so an uncooperative stream cannot delay the terminal failure. Redirects are disabled. Requests are never automatically
retried or logged, and response content encoding other than `identity` is
rejected rather than transparently decompressed.

The transport factory is injectable for deterministic tests; production's
default factory creates an `HttpClient` with automatic decompression disabled.
The factory contract is one client per call because the client is closed on all
terminal paths.

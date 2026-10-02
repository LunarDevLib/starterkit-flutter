# Remote Config

## Status
- Classification: Optional Capability
- Implemented: Yes
- Default connected: No
- Constructor/startup fetch: None

## Purpose
Explicitly fetch a bounded typed configuration snapshot and expose only allowlisted feature values with safe local defaults.

## Semantic contract
The wire schema is `{version, expires_at, values}`. A fetch rejects malformed top-level fields, unknown/protected keys, type mismatches, oversized responses, invalid versions and expired/overlong TTLs before applying anything. Valid data is applied atomically; overlapping requests use latest-started-wins semantics. After expiry, reads fall back to local defaults. Remote values cannot control endpoint/trust/permission/auth/token/secret/security settings.

## Platform implementation
Pure Dart: `lib/capabilities/services/remote_config.dart`. Android/iOS share the same typed store and injected Core `ApiClient`.

## Dependencies
Starter Core `ApiClient` only. No Firebase Remote Config or vendor SDK.

## Required permissions
None inherent. Network permission/configuration is activation-only for a consuming product.

## Required native config
None.

## Required vendor config
None. Product owns the HTTPS backend schema and endpoint.

## Activation
1. Define safe local defaults and a narrow `RemoteValueType` schema.
2. Configure an allowlisted Core HTTPS client.
3. Compose `RemoteConfigService`.
4. Choose an explicit fetch point; do not fetch from constructor/startup by default.
5. Connect only non-security product flags.
6. Test malformed/unknown/type/expiry/concurrency/network cases.

## Deactivation
Remove fetch call sites, consumers/composition and endpoint configuration. Keep or restore safe local defaults before removing the capability.

## Failure model
Transport/status/cancellation and schema/expiry failures do not partially update the active snapshot. There is no automatic retry or background refresh.

## Tests
`test/capabilities/services/service_capabilities_test.dart` verifies typed atomic apply, invalid-data preservation, expiry fallback and stale fetch protection.

## Security notes
Remote config is not an authorization or security boundary. Protected key names are rejected even if mistakenly present in the supplied schema. Do not put secrets in configuration.

## Known limitations
No persistence, signatures, push invalidation, experiment assignment, automatic refresh, rollback protocol or cross-device consistency.

# Analytics

## Status
- Classification: Optional Capability
- Implemented: Yes
- Default connected: No
- Startup side effect: None
- Default consent/tracking: None

## Purpose
Submit one explicitly constructed analytics event through the existing Core network boundary after explicit product consent.

## Semantic contract
Denied consent performs zero transport calls. Event names are bounded safe codes. Fields are limited to `screen`, `action`, `category`, `value`, and `success` with typed values, bounded text, finite decimals, and a bounded JSON body. There is no device identifier, automatic screen tracking, queue, retry, startup initialization, or implicit flush.

## Platform implementation
Pure Dart: `lib/capabilities/services/analytics.dart`. Android and iOS share the same Dart contract and use an explicitly injected Core `ApiClient`.

## Dependencies
Starter Core `ApiClient` only. No vendor SDK or additional Flutter/native package.

## Required permissions
None inherent. A consuming Android product that actually sends events needs network access as part of its product network configuration; the Starter Kit baseline remains permission-free.

## Required native config
None.

## Required vendor config
None. The product owns its HTTPS endpoint/backend contract and must not embed server secrets.

## Activation
1. Define a minimal event schema and privacy/legal basis.
2. Configure an allowlisted Core HTTPS `ApiClient`.
3. Obtain product consent and construct `AnalyticsService` with the current consent value.
4. Compose explicit submit calls only at reviewed product events.
5. Add product tests for consent revocation, endpoint failure and data minimization.
6. Add Android network permission only if the product has real network behavior.

## Deactivation
Remove submit call sites, service composition, consent state and endpoint configuration. Remove network permission only if no other product feature uses it.

## Failure model
Invalid event data fails before transport. Core cancellation/network/status failures propagate. There is no implicit retry or delivery guarantee.

## Tests
`test/capabilities/services/service_capabilities_test.dart` verifies consent zero-call behavior, typed serialization and validation. Source and renamed app CI run the tests.

## Security notes
Do not put PII, credentials, tokens, cookies, secrets or arbitrary user text into analytics fields. The bounded field names are not a substitute for product data review.

## Known limitations
No persistence, batching, identity, automatic capture, consent UI/storage, backend schema or vendor adapter.

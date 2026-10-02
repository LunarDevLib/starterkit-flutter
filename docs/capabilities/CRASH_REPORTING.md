# Crash Reporting

## Status
- Classification: Optional Capability
- Implemented: Yes
- Default connected: No
- Startup/fatal hook: None
- Automatic upload: None

## Purpose
Explicitly submit a bounded handled/nonfatal issue code through the existing Core network boundary.

## Semantic contract
Only enumerated handled issue kinds, bounded safe codes and four allowlisted context keys (`operation`, `screen`, `component`, `stage`) can be serialized. Denied consent performs zero transport calls. The capability never hooks fatal handlers, captures stack traces, or uploads automatically.

## Platform implementation
Pure Dart: `lib/capabilities/services/crash_reporting.dart`, shared by Android/iOS through an explicitly injected Core `ApiClient`.

## Dependencies
Starter Core `ApiClient` only. No Sentry, Crashlytics or other crash vendor SDK.

## Required permissions
None inherent. Product network configuration is required only after explicit activation.

## Required native config
None; no fatal handler is installed.

## Required vendor config
None. The product supplies its own HTTPS backend if it activates submission.

## Activation
1. Review privacy/retention and consent.
2. Configure an allowlisted Core HTTPS client.
3. Compose `CrashReportingService` explicitly.
4. Call it only from intentional handled-error boundaries using safe codes.
5. Test consent denial, invalid context, cancellation and backend failures.

## Deactivation
Remove call sites, consent/composition and endpoint configuration. Remove product network permission if no other feature needs it.

## Failure model
Invalid code/context fails before transport. Core failures propagate. No retry, offline queue or guaranteed delivery is supplied.

## Tests
`test/capabilities/services/service_capabilities_test.dart` verifies zero-call denial, bounded serialization and context rejection.

## Security notes
No raw exception text, stack traces, tokens, cookies, credentials, PII or arbitrary context. Codes are identifiers, not log payloads.

## Known limitations
Handled/nonfatal submission only. No fatal capture, symbolication, automatic interception, offline queue or vendor backend.

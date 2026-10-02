# Capability Matrix

Optional capabilities are implemented independently and remain disconnected from
the default SampleApp. Presence of source or a dependency does not activate a
capability.

| Capability | Implemented | Tested | Default connected | Docs |
| --- | --- | --- | --- | --- |
| WebView | Yes | Dart policy + Android policy + iOS policy + native compile gates | No | [WEBVIEW](capabilities/WEBVIEW.md) |
| Push | Planned | No | No | Planned |
| Camera | Planned | No | No | Planned |
| Gallery | Planned | No | No | Planned |
| Location | Planned | No | No | Planned |
| QR / Barcode | Planned | No | No | Planned |
| Biometric | Planned | No | No | Planned |
| Analytics | Yes | Dart unit/contract tests + source/renamed CI | No | [ANALYTICS](capabilities/ANALYTICS.md) |
| Crash Reporting | Yes | Dart unit/contract tests + source/renamed CI | No | [CRASH_REPORTING](capabilities/CRASH_REPORTING.md) |
| Social Login | Planned | No | No | Planned |
| Native Share | Planned | No | No | Planned |
| App Update | Planned | No | No | Planned |
| Remote Config | Yes | Dart unit/contract tests + source/renamed CI | No | [REMOTE_CONFIG](capabilities/REMOTE_CONFIG.md) |

Maps and Payments are outside the v1 implementation scope.

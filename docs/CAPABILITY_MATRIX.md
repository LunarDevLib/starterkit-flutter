# Capability Matrix

Optional capabilities are implemented independently and remain disconnected from
the default SampleApp. Presence of source or a dependency does not activate a
capability.

| Capability | Implemented | Tested | Default connected | Docs |
| --- | --- | --- | --- | --- |
| WebView | Yes | Dart policy + Android policy + iOS policy + native compile gates | No | [WEBVIEW](capabilities/WEBVIEW.md) |
| Push | Planned | No | No | Planned |
| Camera | Yes | Dart contract + Android policy + iOS policy + native compile gates | No | [CAMERA](capabilities/CAMERA.md) |
| Gallery | Yes | Dart contract + Android policy + iOS policy + native compile gates | No | [GALLERY](capabilities/GALLERY.md) |
| Location | Yes | Dart contract tests passed; native/consumer CI pending (no device PASS) | No | [LOCATION](capabilities/LOCATION.md) |
| QR / Barcode | Dart API implemented; native/consumer evidence pending | Dart contract tests; native fixtures/CI pending | No | [QR_BARCODE](capabilities/QR_BARCODE.md) |
| Biometric | Yes | Dart contract tests + native policy coverage; native/consumer CI pending | No | [BIOMETRIC](capabilities/BIOMETRIC.md) |
| Analytics | Planned | No | No | Planned |
| Crash Reporting | Planned | No | No | Planned |
| Social Login | Planned | No | No | Planned |
| Native Share | Dart API implemented; native/integration CI pending | 13 Dart share tests + 40 existing platform tests passed; device/UI NOT_RUN | No | [NATIVE_SHARE](capabilities/NATIVE_SHARE.md) |
| App Update | Planned | No | No | Planned |
| Remote Config | Planned | No | No | Planned |

Maps and Payments are outside the v1 implementation scope.

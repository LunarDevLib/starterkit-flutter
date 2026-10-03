# Capability Matrix

Optional capabilities are implemented independently and remain disconnected from
the default SampleApp. Presence of source or a dependency does not activate a
capability.

| Capability | Implemented | Tested | Default connected | Docs |
| --- | --- | --- | --- | --- |
| WebView | Yes | Dart policy + Android policy + iOS policy + native compile gates | No | [WEBVIEW](capabilities/WEBVIEW.md) |
| Push | Dart facade + product provider port implemented; native/CI pending | 18 Push + 53 existing platform Dart tests passed; provider/device NOT_RUN | No | [PUSH](capabilities/PUSH.md) |
| Camera | Yes | Dart contract + Android policy + iOS policy + native compile gates | No | [CAMERA](capabilities/CAMERA.md) |
| Gallery | Yes | Dart contract + Android policy + iOS policy + native compile gates | No | [GALLERY](capabilities/GALLERY.md) |
| Location | Yes | Dart contract tests passed; native/consumer CI pending (no device PASS) | No | [LOCATION](capabilities/LOCATION.md) |
| QR / Barcode | Dart API implemented; native/consumer evidence pending | Dart contract tests; native fixtures/CI pending | No | [QR_BARCODE](capabilities/QR_BARCODE.md) |
| Biometric | Yes | Dart contract tests + native policy coverage; native/consumer CI pending | No | [BIOMETRIC](capabilities/BIOMETRIC.md) |
| Analytics | Optional Dart validation service with product transport | Contract tests provided; production backend/consent/device NOT RUN | No | [ANALYTICS](capabilities/ANALYTICS.md) |
| Crash Reporting | Optional handled-report service with product transport; no automatic capture | No result claimed here; production backend/consent/device NOT RUN | No | [CRASH_REPORTING](capabilities/CRASH_REPORTING.md) |
| Social Login | Optional OAuth/PKCE Dart service with product browser and token ports | No result claimed here; real provider/browser/backend/device NOT RUN | No | [SOCIAL_LOGIN](capabilities/SOCIAL_LOGIN.md) |
| Native Share | Dart API implemented; native/integration CI pending | 13 Dart share tests + 40 existing platform tests passed; device/UI NOT_RUN | No | [NATIVE_SHARE](capabilities/NATIVE_SHARE.md) |
| App Update | Dart validation API with product-supplied ports | Contract tests provided; production service/store/device NOT RUN | No | [APP_UPDATE](capabilities/APP_UPDATE.md) |
| Remote Config | Planned | No | No | Planned |

Maps and Payments are outside the v1 implementation scope.

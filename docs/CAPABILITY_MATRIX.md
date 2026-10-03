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
| Location | Planned | No | No | Planned |
| QR / Barcode | Planned | No | No | Planned |
| Biometric | Planned | No | No | Planned |
| Analytics | Planned | No | No | Planned |
| Crash Reporting | Planned | No | No | Planned |
| Social Login | Planned | No | No | Planned |
| Native Share | Planned | No | No | Planned |
| App Update | Planned | No | No | Planned |
| Remote Config | Planned | No | No | Planned |

Maps and Payments are outside the v1 implementation scope.

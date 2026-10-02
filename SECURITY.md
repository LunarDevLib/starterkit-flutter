# Flutter Template — 보안 경계

이 문서는 기본 템플릿 동작과 일부 플랫폼 설정을 설명하며 제품 보안 보증을 제공하지 않습니다.
실제 제품은 기능, 데이터 흐름, 의존성, 배포 설정을 별도로 검토해야 합니다.

## 기본 앱

- `main.dart`는 bootstrap을 통해 `SampleApp`을 시작하고 bootstrap은 in-memory sample repository만
  주입합니다.
- 기본 경로에는 로그인/세션, 원격 API, 영구 설정 저장, secure storage, telemetry, crash upload,
  push 등록 또는 background network 작업이 없습니다.
- Android main manifest에는 불필요한 `INTERNET` 권한이 없어야 합니다. Flutter 개발 tooling이
  사용하는 debug/profile manifest의 `INTERNET`은 개발용이며 기본 release 앱이 네트워크 사용
  권한을 가진다는 의미가 아닙니다. Plugin을 추가하면 merged manifest와 실제 권한을 다시
  확인하세요.
- 기본 앱에서 iOS Keychain 접근 그룹 entitlement는 필요하지 않습니다. 비밀/민감한 데이터 저장을
  추가한다면 적절한 저장 방식을 제품별로 선택하고 실제 platform 설정과 접근 그룹을 검증하세요.
- 샘플 데이터는 고정 문자열이며 민감정보가 아닙니다. 네트워크를 사용하지 않는다는 사실은
  offline sync, 암호화 저장, 제품 인증 또는 전반적인 보안 검증을 의미하지 않습니다.

## 제품 기능을 추가할 때

- 코드, 문서, 로그, dart-defines, 저장소에 비밀값, token, password, 개인 데이터를 넣지 않습니다.
- 실제로 필요한 platform permission만 기능 시점에 추가하고 validator 정책 및 merged build 결과를
  함께 검토합니다.
- 외부 통신을 추가하면 HTTPS/TLS, endpoint/environment 설정, credentials, timeout/cancellation,
  오류 노출과 mutation 재시도 정책을 정의하고 테스트합니다.
- 로그에 authorization, token, password, cookie, 개인식별정보 또는 민감한 request/response body를
  남기지 않습니다. 로깅 라이브러리나 안전한 redaction 계층은 현재 기본 앱에 제공되지 않습니다.
- 민감한 저장이 필요할 때 저장소의 존재만으로 플랫폼 보호를 가정하지 말고 lifecycle, 접근 권한,
  logout/expiry 삭제 및 실제 기기 동작을 검증합니다.
- Push, analytics, crash reporting, remote config, social login 등은 기본 기능이 아닙니다. 도입 시
  명시적 통합, 동의/데이터 처리, 최소 권한, 정책과 테스트를 포함하세요.

## Identity, scheme 및 검증 한계

Bootstrap과 template validator는 앱 identity placeholder 교체와 템플릿 정책 일부를 돕지만
signing, secret 관리, 침투 테스트, 규제 준수 또는 제품별 보안 검토를 대신하지 않습니다. Rename
가능한 custom URL scheme은 플랫폼 등록 정보이며, SampleApp의 직접 라우트 테스트가 OS에서 전달되는
외부 deep link를 검증하지 않습니다. 제품은 실제 URL ownership/conflict, 입력 검증, 앱 간 전달과
플랫폼 설정을 별도로 확인해야 합니다.

기본 앱에서 불필요한 Android main `INTERNET` 권한과 iOS Keychain entitlement를 제거하는 것이
기본 최소화입니다. 기능/플러그인 변경 시 manifest, entitlements, Info.plist, signing 및 CI 결과를
다시 확인하세요.

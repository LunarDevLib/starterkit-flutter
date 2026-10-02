# Flutter Starter Kit

재사용 가능한 Flutter 앱 스타터 키트입니다. 기본 실행 앱인 `SampleApp`은 세 개의 고정된
샘플을 메모리에서 보여 주는 목록/상세 예제이며 네트워크를 사용하지 않습니다. 이는 offline-first
동기화, 로그인, 원격 데이터 또는 제품용 보안 기능을 제공한다는 뜻이 아닙니다.

기본 identity는 package `flutter_starterkit`, 표시 이름 `Flutter Starter Kit`, Android/iOS ID
`com.example.flutterstarterkit`, URL scheme `flutter-starterkit`, version `1.0.0+1`입니다.

## 사전 요구사항

- Flutter 3.47.4 (Dart 3.13.3)
- Android/iOS 빌드에 필요한 각 플랫폼 도구체인

## 새 프로젝트로 부트스트랩

저장소를 복제하고 새 복사본에서 실행하세요. 먼저 `--dry-run`으로 검토한 다음 같은 인자를
사용해 실제 적용합니다. 아래 값은 예시이므로 제품 identity로 교체하세요.

```sh
dart tool/bootstrap_project.dart \
  --package-name sample_app \
  --app-name 'Sample App' \
  --bundle-id dev.example.sampleapp \
  --scheme sample-app \
  --dry-run
```

```sh
dart tool/bootstrap_project.dart \
  --package-name sample_app \
  --app-name 'Sample App' \
  --bundle-id dev.example.sampleapp \
  --scheme sample-app
```

부트스트랩은 템플릿 identity 치환 도구이며 signing, secret 관리, 백엔드 연동, 보안 검토를
대신하지 않습니다. 도구 실행 중 다른 편집기나 프로세스가 동일 복사본을 수정하지 마세요.
실패 복구는 적용 단계별 파일 rollback을 지원하지만 저장소 전체의 원자적 복구는 보장하지 않습니다.

## 기본 실행과 동작

```sh
flutter pub get --enforce-lockfile
flutter gen-l10n
dart run tool/validate_template.dart
dart format --output=none --set-exit-if-changed lib test tool
flutter analyze
flutter test
flutter run
```

실행 경로는 `main.dart` → `bootstrap()` → `SampleApp`입니다. bootstrap은
`InMemorySampleRepository`만 주입합니다. `/`에는 `first`, `second`, `third`가 표시되고
`/samples/:id`는 ID로 상세를 조회합니다. 목록과 상세는 각각 로딩/콘텐츠/오류 상태를 가지며,
알 수 없는 ID는 상세 not-found 상태로 구분됩니다. 오류에는 retry, 상세에는 back 동작이
있습니다. 알 수 없는 경로는 별도 오류 화면으로 처리합니다.

샘플 텍스트는 영어 고정 데이터이고 UI 문구는 영어/한국어 ARB로 현지화됩니다. 앱 테마는
시스템 설정을 따르는 light/dark 테마를 제공합니다. 샘플 상호작용 일부에 접근성 semantics와
레이블이 지정되어 있습니다. 이는 전체 화면, 동적 글자 크기, 스크린리더 또는 실제 기기에 대한
접근성 적합성 보증이 아닙니다.

기본 앱은 auth, 설정 저장, secure storage, API/network client, telemetry, crash upload,
push 또는 background network 작업을 초기화하지 않습니다. 기능을 추가하려면 실제 요구에 맞게
모델, 상태, 라우팅, 의존성 주입, 오류 흐름, 현지화와 테스트를 함께 구현하세요. 확장 안내는
[기능 확장 가이드](FEATURE_SETUP.md), 구조 원칙은 [아키텍처](docs/ARCHITECTURE.md)를
참조하세요.

## 템플릿 및 복사본 검증

일반 개발은 위의 기본 실행 명령을 사용합니다. 원본 템플릿에서는 `flutter test`로 canonical
identity를 사용하는 `template-only` bootstrap fixture까지 실행합니다. 부트스트랩된 소비 복사본은
다음처럼 release placeholder를 검사하고 템플릿 전용 fixture를 제외하세요:

```sh
dart run tool/validate_template.dart --release-readiness
flutter test --exclude-tags template-only
```

템플릿 CI는 locked dependency resolution, l10n, validator, format/analyze/test, Android debug APK,
unsigned iOS simulator build 및 renamed-copy 검증을 수행합니다. validator는 identity residue와
템플릿 정책 일부를 확인하지만 signing, 배포, 외부 URL scheme 전달, 실제 기기 동작 또는 보안
검토를 증명하지 않습니다. 앱 테스트는 직접 라우트 동작을 검사하며 OS에서 전달되는 외부 deep
link를 검증하지 않습니다. 소비 제품은 자체 요구에 맞는 검증을 유지해야 합니다.

## 문서

- [프로젝트 개요](PROJECT_OVERVIEW.md)
- [기능 확장 가이드](FEATURE_SETUP.md)
- [보안 경계](SECURITY.md)
- [아키텍처와 성장 규칙](docs/ARCHITECTURE.md)


## Optional Capabilities

Starter Kit capability code may be present as an inert dependency without being
part of the default runtime. The default SampleApp does not import, create, route
to, or automatically load any optional capability.

The first implemented optional capability is the native-backed WebView boundary
in `packages/starterkit_webview`. It is disconnected by default and requires
explicit product composition. Remote content additionally requires the product
to add the Android `INTERNET` permission; the Starter Kit baseline does not add
it. Bridge support is disabled by default and, when enabled, validates the trusted
HTTPS source origin and main-frame status at the native WebView boundary.

See [Capability Matrix](docs/CAPABILITY_MATRIX.md) and
[WebView capability](docs/capabilities/WEBVIEW.md).

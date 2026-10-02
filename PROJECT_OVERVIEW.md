# Flutter Starter Kit — 프로젝트 개요

Flutter Starter Kit은 기본 앱 `SampleApp`과 재사용 가능한 Flutter 빌드/검증 기반을 제공합니다.
기본 앱은 네트워크가 없는 인메모리 샘플이며 제품 백엔드, 인증, 오프라인 동기화 기능이 아닙니다.
기본 identity는 package `flutter_starterkit`, 표시 이름 `Flutter Starter Kit`, Android/iOS ID
`com.example.flutterstarterkit`, URL scheme `flutter-starterkit`, version `1.0.0+1`입니다.

## 기본 실행 경로

```text
lib/main.dart
  → app/bootstrap/bootstrap.dart
    → ProviderScope (InMemorySampleRepository 주입)
      → app/SampleApp
        → sampleRouterProvider
          → / : 샘플 목록
          → /samples/:id : ID 기반 상세
```

목록은 `first`, `second`, `third` 세 샘플을 표시합니다. 상세는 항목 전체 대신 ID를 라우트에
담아 repository에서 찾습니다. 목록과 상세는 독립적으로 loading/content/error 상태를 가지며,
상세 not-found는 오류와 구분됩니다. 오류 화면은 retry, 상세 화면은 back을 제공하고 잘못된
경로는 unknown-route 화면으로 처리됩니다. 샘플 문구는 영어 고정 데이터이고 UI chrome은
en/ko ARB로 현지화됩니다. light/dark 테마는 시스템 설정을 따릅니다.

일부 상호작용은 semantics 및 레이블을 제공합니다. 이는 모든 화면의 접근성, 스크린리더 호환성,
큰 글자 또는 실제 기기 검증을 의미하지 않습니다. 기본 실행은 네트워크나 영구 설정 저장을
사용하지 않으며 제품 인증·원격 API·동기화를 제공하지 않습니다.

## 구성과 확장 지점

- `lib/app/`: bootstrap, `SampleApp`, sample routing, theme
- `lib/features/sample/`: 샘플 모델, in-memory repository, 상태와 목록/상세 화면
- `lib/shared/widgets/`: sample 화면의 공용 상태/반응형 위젯
- `lib/l10n/`: ARB 입력 및 생성된 localization
- `tool/`: 템플릿 identity bootstrap 및 validator
- `android/`, `ios/`: Flutter 플랫폼 빌드/앱 identity 구성

새 제품 기능은 필요한 코드와 플랫폼 권한만 명시적으로 추가하세요. feature-local 상태/데이터
경계, 앱 bootstrap 의존성 주입, ID 라우팅, 오류/not-found/retry 흐름, 현지화와 테스트를
제품 계약에 맞춰 확장해야 합니다. 세부 원칙은 [아키텍처 문서](docs/ARCHITECTURE.md),
절차는 [기능 확장 가이드](FEATURE_SETUP.md)를 참조하세요.

## Bootstrap, validator, CI

`tool/bootstrap_project.dart`는 package name, 표시 이름, bundle/application ID 및 custom URL
scheme를 복사본에서 교체합니다. 먼저 dry-run으로 변경을 검토할 수 있습니다. 도구는 rename
잔여 항목을 검사하고 단계별 rollback을 지원하지만 저장소 전체의 원자성, signing/secret 설정,
제품별 scheme 동작을 보장하지 않습니다. Custom scheme이 플랫폼에 등록되어 있어도 외부 앱에서
OS가 링크를 전달하는 동작이 검증됐다는 뜻은 아닙니다.

`tool/validate_template.dart`는 템플릿 구조와 정책 일부, identity residue 및 localization 입력을
검증합니다. CI는 locked dependencies, l10n, validator, format/analyze/test, Android debug APK,
unsigned iOS simulator build 및 renamed-copy 검증을 게이트합니다. 이는 배포/서명, 실제 장치,
외부 deep link 또는 보안 적합성 검증을 대체하지 않습니다. 실행 이력을 확인하지 않고 문서에서
현재 build/test 성공을 주장하지 않습니다.

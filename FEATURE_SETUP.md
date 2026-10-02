# 기능 확장 가이드

기본 `SampleApp`은 네트워크 없는 in-memory 목록/상세 예제입니다. 아래는 새 제품 기능을 이
최소 기반 위에 추가할 때의 간단한 체크리스트이며, 기존 인증·설정·API 모듈을 활성화하는
절차가 아닙니다.

## 기본 예제

`/`는 고정된 세 샘플을 보여주고 `/samples/:id`는 ID를 사용해 상세 데이터를 조회합니다. 목록과
상세는 각자의 loading/content/error 상태를 가지며, 상세의 not-found 상태, retry/back 동작과
unknown-route 화면이 있습니다. 화면은 en/ko ARB와 시스템 light/dark 테마를 사용합니다. 기본
경로는 네트워크나 영구 설정 저장소를 초기화하지 않습니다. 샘플 동작/접근성 semantics는
예시이지 제품 수준의 접근성 검증을 의미하지 않습니다.

## 새 기능 추가

1. 요구사항, 데이터 소유자, 오류 및 보안 경계를 먼저 정하고 최소 기능 범위를 정의합니다.
2. `lib/features/<feature>/` 아래 필요한 도메인/데이터/상태/UI 책임만 추가합니다. 의미 없는
   빈 계층이나 범용 모듈 묶음을 만들지 않습니다.
3. 실제 필요한 경우 repository 계약을 두고 구현체를 앱 경계의 bootstrap/ProviderScope에서
   명시적으로 주입합니다. 네트워크가 필요하지 않은 기능에 네트워크 권한이나 플러그인을 추가하지
   않습니다.
4. 라우트, loading/error/empty/not-found 상태, 오류 이후 retry 가능성, 현지화 문구와 접근성
   semantics를 요구사항에 맞게 설계합니다.
5. repository/state 단위 테스트와 화면/라우팅 widget 테스트를 작성하고 native permission 및
   의존성 변경을 검토합니다.

ARB 입력은 `lib/l10n/app_en.arb`, `app_ko.arb`에 추가하고 `flutter gen-l10n`으로 생성합니다.
생성된 파일을 직접 편집하지 마세요. 구조 및 의존성 원칙은
[아키텍처 문서](docs/ARCHITECTURE.md), 제품 경계는 [보안 가이드](SECURITY.md)를 참조하세요.

## 프로젝트 identity bootstrap

복제한 새 작업 복사본에서 `tool/bootstrap_project.dart`를 사용하고 먼저 dry-run 결과를
검토하세요. 예시 값은 제품 identity로 바꾸세요:

```sh
dart tool/bootstrap_project.dart \
  --package-name sample_app \
  --app-name 'Sample App' \
  --bundle-id dev.example.sampleapp \
  --scheme sample-app \
  --dry-run
```

검토 후 `--dry-run`을 빼고 다시 실행합니다. 이 도구는 identity placeholder 교체 및 residue
검증을 지원하지만 signing, secrets, backend 설정 또는 보안 검토를 대신하지 않으며 저장소 전체의
원자적 rollback을 보장하지 않습니다. scheme 등록은 유지되지만 외부 앱에서 OS가 링크를 전달하는
동작은 검증된 것으로 간주하지 마세요. 도구 한계와 변경 범위는 [README](README.md)를
참조하세요.

## 검증

일반 개발 및 원본 템플릿에서는 `flutter test`를 사용합니다. 이 테스트에는 canonical identity를
전제로 하는 `template-only` bootstrap fixture가 포함됩니다. 복사본을 rename한 뒤에는 fixture를
제외하고 release-readiness 검증을 실행하세요:

```sh
flutter pub get --enforce-lockfile
flutter gen-l10n
dart run tool/validate_template.dart
dart format --output=none --set-exit-if-changed lib test tool
flutter analyze
flutter test
```

```sh
dart run tool/validate_template.dart --release-readiness
flutter test --exclude-tags template-only
```

템플릿 CI는 Android debug APK, unsigned iOS simulator build 및 renamed-copy 검증도 수행합니다.
validator/CI 성공은 배포, 외부 deep link, 실제 기기 또는 보안 적합성 증거가 아닙니다.

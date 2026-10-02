import '../failure/app_failure.dart';

/// A minimal presentation state vocabulary that keeps failures typed and safe.
sealed class CommonUiState<T> {
  const CommonUiState();
}

final class CommonLoading<T> extends CommonUiState<T> {
  const CommonLoading();
}

final class CommonContent<T> extends CommonUiState<T> {
  const CommonContent(this.value);

  final T value;
}

final class CommonEmpty<T> extends CommonUiState<T> {
  const CommonEmpty();
}

final class CommonError<T> extends CommonUiState<T> {
  const CommonError(this.failure);

  final AppFailure failure;
}

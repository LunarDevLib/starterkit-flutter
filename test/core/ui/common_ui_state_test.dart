import 'package:flutter_starterkit/core/failure/app_failure.dart';
import 'package:flutter_starterkit/core/ui/common_ui_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('models loading, content, empty and safe typed failure states', () {
    expect(const CommonLoading<int>(), isA<CommonUiState<int>>());
    expect(const CommonContent<int>(3), isA<CommonUiState<int>>());
    expect(const CommonEmpty<int>(), isA<CommonUiState<int>>());
    final failure = AppFailure(
      FailureKind.network,
      code: 'network.error',
      localizationKey: 'failure.network_error',
    );
    final error = CommonError<int>(failure);
    expect(error.failure, same(failure));
    expect(error.failure.toString(), isNot(contains('sensitive')));
  });
}

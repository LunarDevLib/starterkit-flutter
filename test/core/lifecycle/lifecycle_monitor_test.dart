import 'package:flutter/widgets.dart';
import 'package:flutter_starterkit/core/lifecycle/lifecycle_monitor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('maps lifecycle states into distinct semantic values', () {
    expect(
      lifecycleStatusFor(AppLifecycleState.resumed),
      LifecycleStatus.foreground,
    );
    expect(
      lifecycleStatusFor(AppLifecycleState.paused),
      LifecycleStatus.background,
    );
    expect(
      lifecycleStatusFor(AppLifecycleState.hidden),
      LifecycleStatus.background,
    );
    expect(
      lifecycleStatusFor(AppLifecycleState.inactive),
      LifecycleStatus.inactive,
    );
    expect(
      lifecycleStatusFor(AppLifecycleState.detached),
      LifecycleStatus.detached,
    );
  });

  test(
    'construction is inert and start, stop, dispose are explicit/idempotent',
    () {
      final source = _FakeLifecycleSource();
      final received = <LifecycleStatus>[];
      final monitor = LifecycleMonitor(source: source, onChanged: received.add);
      expect(source.startCount, 0);

      monitor.start();
      monitor.start();
      expect(source.startCount, 1);
      source.emit(LifecycleStatus.foreground);
      expect(monitor.status, LifecycleStatus.foreground);
      expect(received, [LifecycleStatus.foreground]);

      final staleCallback = source.callback!;
      monitor.stop();
      monitor.stop();
      expect(source.stopCount, 1);
      staleCallback(LifecycleStatus.background);
      expect(monitor.status, LifecycleStatus.foreground);

      monitor.start();
      expect(source.startCount, 2);
      monitor.dispose();
      monitor.dispose();
      expect(source.stopCount, 2);
      source.emit(LifecycleStatus.detached);
      expect(received, [LifecycleStatus.foreground]);
      expect(monitor.isDisposed, isTrue);
      monitor.start();
      expect(source.startCount, 2);
    },
  );
}

final class _FakeLifecycleSource implements LifecycleEventSource {
  void Function(LifecycleStatus status)? callback;
  int startCount = 0;
  int stopCount = 0;

  @override
  void start(void Function(LifecycleStatus status) onStatus) {
    startCount++;
    callback = onStatus;
  }

  @override
  void stop() {
    stopCount++;
    callback = null;
  }

  void emit(LifecycleStatus status) => callback?.call(status);
}

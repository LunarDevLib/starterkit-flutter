import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/sample_item.dart';
import '../domain/sample_repository.dart';

final sampleRepositoryProvider = Provider<SampleRepository>(
  (ref) => throw StateError(
    'sampleRepositoryProvider must be overridden at the app boundary.',
  ),
);

sealed class SampleListState {
  const SampleListState();
}

final class SampleListLoading extends SampleListState {
  const SampleListLoading();
}

final class SampleListContent extends SampleListState {
  const SampleListContent(this.items);

  final List<SampleItem> items;
}

final class SampleListError extends SampleListState {
  const SampleListError();
}

class SampleListNotifier extends Notifier<SampleListState> {
  var _generation = 0;

  @override
  SampleListState build() {
    _load(emitLoading: false);
    return const SampleListLoading();
  }

  void retry() => _load();

  Future<void> _load({bool emitLoading = true}) async {
    final generation = ++_generation;
    if (emitLoading) state = const SampleListLoading();
    try {
      final items = await Future<List<SampleItem>>.sync(
        () => ref.read(sampleRepositoryProvider).fetchItems(),
      );
      if (!ref.mounted || generation != _generation) return;
      state = SampleListContent(List.unmodifiable(items));
    } catch (_) {
      if (!ref.mounted || generation != _generation) return;
      state = const SampleListError();
    }
  }
}

final sampleListProvider =
    NotifierProvider.autoDispose<SampleListNotifier, SampleListState>(
      SampleListNotifier.new,
    );

sealed class SampleDetailState {
  const SampleDetailState();
}

final class SampleDetailLoading extends SampleDetailState {
  const SampleDetailLoading();
}

final class SampleDetailContent extends SampleDetailState {
  const SampleDetailContent(this.item);

  final SampleItem item;
}

final class SampleDetailNotFound extends SampleDetailState {
  const SampleDetailNotFound();
}

final class SampleDetailError extends SampleDetailState {
  const SampleDetailError();
}

class SampleDetailNotifier extends Notifier<SampleDetailState> {
  SampleDetailNotifier(this.id);

  final String id;
  var _generation = 0;

  @override
  SampleDetailState build() {
    _load(emitLoading: false);
    return const SampleDetailLoading();
  }

  void retry() => _load();

  Future<void> _load({bool emitLoading = true}) async {
    final generation = ++_generation;
    if (emitLoading) state = const SampleDetailLoading();
    try {
      final item = await Future<SampleItem?>.sync(
        () => ref.read(sampleRepositoryProvider).fetchItem(id),
      );
      if (!ref.mounted || generation != _generation) return;
      state = item == null
          ? const SampleDetailNotFound()
          : SampleDetailContent(item);
    } catch (_) {
      if (!ref.mounted || generation != _generation) return;
      state = const SampleDetailError();
    }
  }
}

final sampleDetailProvider = NotifierProvider.autoDispose
    .family<SampleDetailNotifier, SampleDetailState, String>(
      (id) => SampleDetailNotifier(id),
    );

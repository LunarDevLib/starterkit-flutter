import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_starterkit/features/sample/application/sample_providers.dart';
import 'package:flutter_starterkit/features/sample/data/in_memory_sample_repository.dart';
import 'package:flutter_starterkit/features/sample/domain/sample_item.dart';
import 'package:flutter_starterkit/features/sample/domain/sample_repository.dart';

void main() {
  group('InMemorySampleRepository', () {
    test('returns the three native reference records exactly', () async {
      final items = await InMemorySampleRepository().fetchItems();

      expect(
        items.map((item) => [item.id, item.title, item.description]).toList(),
        [
          [
            'first',
            'First item',
            'A small example of repository-backed content.',
          ],
          [
            'second',
            'Second item',
            'This detail is resolved from a stable item ID.',
          ],
          [
            'third',
            'Third item',
            'Replace the in-memory source when real data is needed.',
          ],
        ],
      );
      expect(await InMemorySampleRepository().fetchItem('second'), items[1]);
      expect(await InMemorySampleRepository().fetchItem('missing'), isNull);
    });
  });

  group('sampleListProvider', () {
    test('a synchronous repository exception settles in Error', () async {
      final container = _container(
        _FakeSampleRepository(fetchItems: () => throw StateError('offline')),
      );
      addTearDown(container.dispose);
      final subscription = container.listen(sampleListProvider, (_, _) {});

      expect(container.read(sampleListProvider), isA<SampleListLoading>());
      await _flushAsync();
      expect(container.read(sampleListProvider), isA<SampleListError>());
      subscription.close();
    });

    test('transitions from Loading to Content', () async {
      final completer = Completer<List<SampleItem>>();
      final repository = _FakeSampleRepository(
        fetchItems: () => completer.future,
      );
      final container = _container(repository);
      addTearDown(container.dispose);

      final subscription = container.listen(sampleListProvider, (_, _) {});
      expect(container.read(sampleListProvider), isA<SampleListLoading>());

      completer.complete([_item('first')]);
      await _flushAsync();

      expect(container.read(sampleListProvider), isA<SampleListContent>());
      expect(
        (container.read(
          sampleListProvider,
        ) as SampleListContent).items.single.id,
        'first',
      );
      subscription.close();
    });

    test('retry emits Loading then Content after a repository error', () async {
      var attempts = 0;
      final repository = _FakeSampleRepository(
        fetchItems: () async {
          if (attempts++ == 0) throw StateError('offline');
          return [_item('second')];
        },
      );
      final container = _container(repository);
      addTearDown(container.dispose);
      final subscription = container.listen(sampleListProvider, (_, _) {});

      await _flushAsync();
      expect(container.read(sampleListProvider), isA<SampleListError>());

      container.read(sampleListProvider.notifier).retry();
      expect(container.read(sampleListProvider), isA<SampleListLoading>());
      await _flushAsync();
      expect(container.read(sampleListProvider), isA<SampleListContent>());
      expect(
        (container.read(
          sampleListProvider,
        ) as SampleListContent).items.single.id,
        'second',
      );
      subscription.close();
    });

    test('a newer overlapping request suppresses the older result', () async {
      final first = Completer<List<SampleItem>>();
      final second = Completer<List<SampleItem>>();
      var calls = 0;
      final repository = _FakeSampleRepository(
        fetchItems: () => calls++ == 0 ? first.future : second.future,
      );
      final container = _container(repository);
      addTearDown(container.dispose);
      final subscription = container.listen(sampleListProvider, (_, _) {});

      container.read(sampleListProvider.notifier).retry();
      second.complete([_item('newer')]);
      await _flushAsync();
      first.complete([_item('older')]);
      await _flushAsync();

      expect(
        (container.read(
          sampleListProvider,
        ) as SampleListContent).items.single.id,
        'newer',
      );
      subscription.close();
    });

    test('a completed request after disposal does not write state', () async {
      final completer = Completer<List<SampleItem>>();
      final container = _container(
        _FakeSampleRepository(fetchItems: () => completer.future),
      );
      final subscription = container.listen(sampleListProvider, (_, _) {});

      subscription.close();
      await _flushAsync();
      completer.complete([_item('late')]);
      await _flushAsync();

      container.dispose();
    });
  });

  group('sampleDetailProvider', () {
    test('a synchronous lookup exception settles in Error', () async {
      final container = _container(
        _FakeSampleRepository(fetchItem: (_) => throw StateError('offline')),
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        sampleDetailProvider('first'),
        (_, _) {},
      );

      expect(
        container.read(sampleDetailProvider('first')),
        isA<SampleDetailLoading>(),
      );
      await _flushAsync();
      expect(
        container.read(sampleDetailProvider('first')),
        isA<SampleDetailError>(),
      );
      subscription.close();
    });

    test('looks up its stable ID independently and resolves Content', () async {
      String? requestedId;
      final container = _container(
        _FakeSampleRepository(
          fetchItem: (id) async {
            requestedId = id;
            return _item(id);
          },
        ),
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        sampleDetailProvider('stable-id'),
        (_, _) {},
      );

      expect(
        container.read(sampleDetailProvider('stable-id')),
        isA<SampleDetailLoading>(),
      );
      await _flushAsync();
      final state = container.read(sampleDetailProvider('stable-id'));
      expect(requestedId, 'stable-id');
      expect(state, isA<SampleDetailContent>());
      expect((state as SampleDetailContent).item.id, 'stable-id');
      subscription.close();
    });

    test('resolves missing IDs to NotFound', () async {
      final container = _container(
        _FakeSampleRepository(fetchItem: (_) async => null),
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        sampleDetailProvider('missing'),
        (_, _) {},
      );

      await _flushAsync();
      expect(
        container.read(sampleDetailProvider('missing')),
        isA<SampleDetailNotFound>(),
      );
      subscription.close();
    });

    test('NotFound retry loads the same ID and recovers', () async {
      final requestedIds = <String>[];
      final retryResult = Completer<SampleItem?>();
      final repository = _FakeSampleRepository(
        fetchItem: (id) {
          requestedIds.add(id);
          return requestedIds.length == 1
              ? Future<SampleItem?>.value(null)
              : retryResult.future;
        },
      );
      final container = _container(repository);
      addTearDown(container.dispose);
      final subscription = container.listen(
        sampleDetailProvider('second'),
        (_, _) {},
      );

      await _flushAsync();
      expect(
        container.read(sampleDetailProvider('second')),
        isA<SampleDetailNotFound>(),
      );
      container.read(sampleDetailProvider('second').notifier).retry();
      expect(
        container.read(sampleDetailProvider('second')),
        isA<SampleDetailLoading>(),
      );
      retryResult.complete(_item('second'));
      await _flushAsync();
      expect(
        container.read(sampleDetailProvider('second')),
        isA<SampleDetailContent>(),
      );
      expect(requestedIds, ['second', 'second']);
      subscription.close();
    });

    test(
      'error retry keeps the same ID and emits Loading before the result',
      () async {
        var attempts = 0;
        final requestedIds = <String>[];
        final repository = _FakeSampleRepository(
          fetchItem: (id) async {
            requestedIds.add(id);
            if (attempts++ == 0) throw StateError('offline');
            return _item(id);
          },
        );
        final container = _container(repository);
        addTearDown(container.dispose);
        final subscription = container.listen(
          sampleDetailProvider('same-id'),
          (_, _) {},
        );

        await _flushAsync();
        expect(
          container.read(sampleDetailProvider('same-id')),
          isA<SampleDetailError>(),
        );

        container.read(sampleDetailProvider('same-id').notifier).retry();
        expect(
          container.read(sampleDetailProvider('same-id')),
          isA<SampleDetailLoading>(),
        );
        await _flushAsync();
        expect(
          container.read(sampleDetailProvider('same-id')),
          isA<SampleDetailContent>(),
        );
        expect(requestedIds, ['same-id', 'same-id']);
        subscription.close();
      },
    );

    test(
      'a completed request after family disposal does not write state',
      () async {
        final completer = Completer<SampleItem?>();
        final container = _container(
          _FakeSampleRepository(fetchItem: (_) => completer.future),
        );
        final subscription = container.listen(
          sampleDetailProvider('late'),
          (_, _) {},
        );

        subscription.close();
        await _flushAsync();
        completer.complete(_item('late'));
        await _flushAsync();

        container.dispose();
      },
    );
  });

  test('sampleRepositoryProvider requires an app-boundary override', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(
      () => container.read(sampleRepositoryProvider),
      throwsA(
        predicate(
          (Object error) => error.toString().contains('must be overridden'),
        ),
      ),
    );
  });
}

ProviderContainer _container(SampleRepository repository) => ProviderContainer(
  overrides: [sampleRepositoryProvider.overrideWithValue(repository)],
);

SampleItem _item(String id) =>
    SampleItem(id: id, title: 'Title $id', description: 'Description $id');

Future<void> _flushAsync() => Future<void>.delayed(Duration.zero);

class _FakeSampleRepository implements SampleRepository {
  _FakeSampleRepository({
    Future<List<SampleItem>> Function()? fetchItems,
    Future<SampleItem?> Function(String id)? fetchItem,
  }) : _fetchItems = fetchItems ?? (() async => const []),
       _fetchItem = fetchItem ?? ((_) async => null);

  final Future<List<SampleItem>> Function() _fetchItems;
  final Future<SampleItem?> Function(String id) _fetchItem;

  @override
  Future<List<SampleItem>> fetchItems() => _fetchItems();

  @override
  Future<SampleItem?> fetchItem(String id) => _fetchItem(id);
}

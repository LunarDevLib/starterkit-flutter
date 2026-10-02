import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_starterkit/app/routing/sample_router.dart';
import 'package:flutter_starterkit/app/sample_app.dart';
import 'package:flutter_starterkit/features/sample/application/sample_providers.dart';
import 'package:flutter_starterkit/features/sample/domain/sample_item.dart';
import 'package:flutter_starterkit/features/sample/domain/sample_repository.dart';
import 'package:flutter_starterkit/features/sample/presentation/sample_detail_page.dart';
import 'package:flutter_starterkit/features/sample/presentation/sample_list_page.dart';
import 'package:flutter_starterkit/features/sample/presentation/sample_unknown_route_page.dart';

void main() {
  testWidgets('cold start shows sample list without auth or storage setup', (
    tester,
  ) async {
    final repository = _FakeSampleRepository();
    final router = createSampleRouter();
    addTearDown(router.dispose);

    await tester.pumpWidget(_app(repository, router));
    await tester.pumpAndSettle();

    expect(find.byType(SampleListPage), findsOneWidget);
    expect(find.text('Second item'), findsOneWidget);
    expect(repository.listReads, 1);
  });

  testWidgets('selecting the second item resolves detail by its ID and backs', (
    tester,
  ) async {
    final repository = _FakeSampleRepository();
    final router = createSampleRouter();
    addTearDown(router.dispose);

    await tester.pumpWidget(_app(repository, router));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Second item'));
    await tester.pumpAndSettle();

    expect(find.byType(SampleDetailPage), findsOneWidget);
    expect(find.text('Second item'), findsOneWidget);
    expect(repository.detailReads, ['second']);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(SampleListPage), findsOneWidget);
  });

  testWidgets('direct unknown sample ID shows NotFound and supports retry', (
    tester,
  ) async {
    final repository = _FakeSampleRepository();
    final router = createSampleRouter(initialLocation: '/samples/unknown');
    addTearDown(router.dispose);

    await tester.pumpWidget(_app(repository, router));
    await tester.pumpAndSettle();

    expect(find.byType(SampleDetailPage), findsOneWidget);
    expect(repository.detailReads, ['unknown']);
    expect(find.text('Try again'), findsOneWidget);

    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(repository.detailReads, ['unknown', 'unknown']);
    expect(find.byType(SampleDetailPage), findsOneWidget);
  });

  testWidgets('unmatched route shows the dedicated unknown-route page', (
    tester,
  ) async {
    final repository = _FakeSampleRepository();
    final router = createSampleRouter();
    addTearDown(router.dispose);

    await tester.pumpWidget(_app(repository, router));
    await tester.pumpAndSettle();
    router.go('/not-a-sample-route');
    await tester.pumpAndSettle();

    expect(find.byType(SampleUnknownRoutePage), findsOneWidget);
  });
}

Widget _app(_FakeSampleRepository repository, GoRouter router) => ProviderScope(
  overrides: [
    sampleRepositoryProvider.overrideWithValue(repository),
    sampleRouterProvider.overrideWithValue(router),
  ],
  child: const SampleApp(),
);

final class _FakeSampleRepository implements SampleRepository {
  static const _items = [
    SampleItem(
      id: 'first',
      title: 'First item',
      description: 'First sample detail',
    ),
    SampleItem(
      id: 'second',
      title: 'Second item',
      description: 'Second sample detail',
    ),
    SampleItem(
      id: 'third',
      title: 'Third item',
      description: 'Third sample detail',
    ),
  ];

  var listReads = 0;
  final detailReads = <String>[];

  @override
  Future<List<SampleItem>> fetchItems() async {
    listReads++;
    return _items;
  }

  @override
  Future<SampleItem?> fetchItem(String id) async {
    detailReads.add(id);
    for (final item in _items) {
      if (item.id == id) return item;
    }
    return null;
  }
}

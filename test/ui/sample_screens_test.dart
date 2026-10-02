import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_starterkit/app/theme/app_theme.dart';
import 'package:flutter_starterkit/features/sample/application/sample_providers.dart';
import 'package:flutter_starterkit/features/sample/domain/sample_item.dart';
import 'package:flutter_starterkit/features/sample/domain/sample_repository.dart';
import 'package:flutter_starterkit/features/sample/presentation/sample_detail_page.dart';
import 'package:flutter_starterkit/features/sample/presentation/sample_list_page.dart';
import 'package:flutter_starterkit/features/sample/presentation/sample_unknown_route_page.dart';
import 'package:flutter_starterkit/l10n/app_localizations.dart';
import 'package:flutter_starterkit/l10n/app_localizations_en.dart';
import 'package:flutter_starterkit/l10n/app_localizations_ko.dart';

Widget localizedTestWidget({
  required Widget child,
  Locale locale = const Locale('en'),
  TextScaler textScaler = TextScaler.noScaling,
  ThemeData? theme,
}) {
  return MaterialApp(
    locale: locale,
    theme: theme ?? AppTheme.light(),
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    home: MediaQuery(
      data: MediaQueryData(textScaler: textScaler),
      child: child,
    ),
  );
}

const _sampleItems = [
  SampleItem(
    id: 'first',
    title: 'First item',
    description: 'First sample detail content',
  ),
  SampleItem(
    id: 'second',
    title: 'Second item',
    description: 'Second sample detail content',
  ),
  SampleItem(
    id: 'third',
    title: 'Third item',
    description: 'Third sample detail content',
  ),
];

class _MockSampleRepository implements SampleRepository {
  _MockSampleRepository({this.itemLookup});

  final SampleItem? Function(String id)? itemLookup;
  int fetchItemsCallCount = 0;
  final List<String> fetchItemCalls = [];

  @override
  Future<List<SampleItem>> fetchItems() async {
    fetchItemsCallCount++;
    return _sampleItems;
  }

  @override
  Future<SampleItem?> fetchItem(String id) async {
    fetchItemCalls.add(id);
    if (itemLookup != null) {
      return itemLookup!(id);
    }
    for (final item in _sampleItems) {
      if (item.id == id) return item;
    }
    return null;
  }
}

void main() {
  group('SampleListView (pure widget)', () {
    testWidgets('renders loading state with accessible label', (tester) async {
      final l10n = AppLocalizationsEn();
      await tester.pumpWidget(
        localizedTestWidget(
          child: SampleListView(
            state: const SampleListLoading(),
            onItemSelected: (_) {},
          ),
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.bySemanticsLabel(l10n.loading), findsOneWidget);
    });

    testWidgets('renders error state and triggers retry callback', (
      tester,
    ) async {
      final l10n = AppLocalizationsEn();
      var retried = false;

      await tester.pumpWidget(
        localizedTestWidget(
          child: SampleListView(
            state: const SampleListError(),
            onItemSelected: (_) {},
            onRetry: () => retried = true,
          ),
        ),
      );

      expect(find.text(l10n.errorTitle), findsOneWidget);
      expect(find.text(l10n.sampleErrorMessage), findsOneWidget);
      expect(find.text(l10n.retry), findsOneWidget);

      await tester.tap(find.text(l10n.retry));
      expect(retried, isTrue);
    });

    testWidgets('renders empty state when items list is empty', (tester) async {
      final l10n = AppLocalizationsEn();
      await tester.pumpWidget(
        localizedTestWidget(
          child: SampleListView(
            state: const SampleListContent([]),
            onItemSelected: (_) {},
          ),
        ),
      );

      expect(find.text(l10n.emptyTitle), findsOneWidget);
      expect(find.text(l10n.emptyMessage), findsOneWidget);
    });

    testWidgets('renders content list and passes ID only on selection', (
      tester,
    ) async {
      String? selectedId;

      await tester.pumpWidget(
        localizedTestWidget(
          child: SampleListView(
            state: const SampleListContent(_sampleItems),
            onItemSelected: (id) => selectedId = id,
          ),
        ),
      );

      expect(find.text('First item'), findsOneWidget);
      expect(find.text('Second item'), findsOneWidget);
      expect(find.text('Third item'), findsOneWidget);

      await tester.tap(find.text('Second item'));
      expect(selectedId, 'second');
    });

    testWidgets(
      'renders properly with 200% text scale factor without overflow',
      (tester) async {
        await tester.pumpWidget(
          localizedTestWidget(
            textScaler: const TextScaler.linear(2.0),
            child: SampleListView(
              state: const SampleListContent(_sampleItems),
              onItemSelected: (_) {},
            ),
          ),
        );

        expect(tester.takeException(), isNull);
        expect(find.text('First item'), findsOneWidget);
      },
    );

    testWidgets('renders localized Korean text correctly', (tester) async {
      final ko = AppLocalizationsKo();
      await tester.pumpWidget(
        localizedTestWidget(
          locale: const Locale('ko'),
          child: SampleListView(
            state: const SampleListContent(_sampleItems),
            onItemSelected: (_) {},
          ),
        ),
      );

      expect(find.text(ko.sampleListTitle), findsOneWidget);
      expect(find.text(ko.sampleListSubtitle), findsOneWidget);
    });
  });

  group('SampleDetailView (pure widget)', () {
    testWidgets('renders loading state with back button', (tester) async {
      var backed = false;
      await tester.pumpWidget(
        localizedTestWidget(
          child: SampleDetailView(
            state: const SampleDetailLoading(),
            onBack: () => backed = true,
          ),
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.tap(find.byType(IconButton));
      expect(backed, isTrue);
    });

    testWidgets('renders not found state and triggers retry', (tester) async {
      final l10n = AppLocalizationsEn();
      var retried = false;

      await tester.pumpWidget(
        localizedTestWidget(
          child: SampleDetailView(
            state: const SampleDetailNotFound(),
            onBack: () {},
            onRetry: () => retried = true,
          ),
        ),
      );

      expect(find.text(l10n.sampleDetailNotFoundTitle), findsOneWidget);
      expect(find.text(l10n.sampleDetailNotFoundMessage), findsOneWidget);
      expect(find.text(l10n.retry), findsOneWidget);

      await tester.tap(find.text(l10n.retry));
      expect(retried, isTrue);
    });

    testWidgets('renders error state and triggers retry', (tester) async {
      final l10n = AppLocalizationsEn();
      var retried = false;

      await tester.pumpWidget(
        localizedTestWidget(
          child: SampleDetailView(
            state: const SampleDetailError(),
            onBack: () {},
            onRetry: () => retried = true,
          ),
        ),
      );

      expect(find.text(l10n.errorTitle), findsOneWidget);
      expect(find.text(l10n.sampleErrorMessage), findsOneWidget);

      await tester.tap(find.text(l10n.retry));
      expect(retried, isTrue);
    });

    testWidgets('renders content details and triggers back action', (
      tester,
    ) async {
      var backed = false;
      final item = _sampleItems[1]; // second

      await tester.pumpWidget(
        localizedTestWidget(
          child: SampleDetailView(
            state: SampleDetailContent(item),
            onBack: () => backed = true,
          ),
        ),
      );

      expect(find.text(item.title), findsOneWidget);
      expect(find.text(item.description), findsOneWidget);
      expect(find.text('#${item.id}'), findsOneWidget);

      await tester.tap(find.byType(IconButton));
      expect(backed, isTrue);
    });

    testWidgets(
      'renders properly with 200% text scale factor without overflow',
      (tester) async {
        await tester.pumpWidget(
          localizedTestWidget(
            textScaler: const TextScaler.linear(2.0),
            child: SampleDetailView(
              state: SampleDetailContent(_sampleItems[0]),
              onBack: () {},
            ),
          ),
        );

        expect(tester.takeException(), isNull);
        expect(find.text('First item'), findsOneWidget);
      },
    );

    testWidgets('renders localized Korean detail strings', (tester) async {
      final ko = AppLocalizationsKo();
      await tester.pumpWidget(
        localizedTestWidget(
          locale: const Locale('ko'),
          child: SampleDetailView(
            state: const SampleDetailNotFound(),
            onBack: () {},
          ),
        ),
      );

      expect(find.text(ko.sampleDetailNotFoundTitle), findsOneWidget);
      expect(find.text(ko.sampleDetailNotFoundMessage), findsOneWidget);
      expect(find.text(ko.retry), findsOneWidget);
    });
  });

  group('SampleUnknownRoutePage', () {
    testWidgets('renders 404, localized title, message and back button', (
      tester,
    ) async {
      final l10n = AppLocalizationsEn();
      var backed = false;

      await tester.pumpWidget(
        localizedTestWidget(
          child: SampleUnknownRoutePage(onBack: () => backed = true),
        ),
      );

      expect(find.text('404'), findsOneWidget);
      expect(find.text(l10n.sampleUnknownRouteTitle), findsOneWidget);
      expect(find.text(l10n.sampleUnknownRouteMessage), findsOneWidget);
      expect(find.text(l10n.sampleUnknownRouteBack), findsOneWidget);

      await tester.tap(find.text(l10n.sampleUnknownRouteBack));
      expect(backed, isTrue);
    });

    testWidgets('renders localized Korean 404 strings', (tester) async {
      final ko = AppLocalizationsKo();

      await tester.pumpWidget(
        localizedTestWidget(
          locale: const Locale('ko'),
          child: SampleUnknownRoutePage(onBack: () {}),
        ),
      );

      expect(find.text(ko.sampleUnknownRouteTitle), findsOneWidget);
      expect(find.text(ko.sampleUnknownRouteMessage), findsOneWidget);
      expect(find.text(ko.sampleUnknownRouteBack), findsOneWidget);
    });
  });

  group('SampleListPage (Riverpod wrapper)', () {
    testWidgets('fetches and displays items from repository', (tester) async {
      final repository = _MockSampleRepository();
      String? selectedId;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [sampleRepositoryProvider.overrideWithValue(repository)],
          child: localizedTestWidget(
            child: SampleListPage(onItemSelected: (id) => selectedId = id),
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('First item'), findsOneWidget);
      expect(find.text('Second item'), findsOneWidget);
      expect(find.text('Third item'), findsOneWidget);
      expect(repository.fetchItemsCallCount, 1);

      await tester.tap(find.text('Third item'));
      expect(selectedId, 'third');
    });
  });

  group('SampleDetailPage (Riverpod wrapper)', () {
    testWidgets('loads and displays single item details', (tester) async {
      final repository = _MockSampleRepository();
      var backed = false;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [sampleRepositoryProvider.overrideWithValue(repository)],
          child: localizedTestWidget(
            child: SampleDetailPage(id: 'second', onBack: () => backed = true),
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('Second item'), findsOneWidget);
      expect(find.text('Second sample detail content'), findsOneWidget);
      expect(find.text('#second'), findsOneWidget);
      expect(repository.fetchItemCalls, ['second']);

      await tester.tap(find.byType(IconButton));
      expect(backed, isTrue);
    });

    testWidgets('retrying not found requests the same ID', (tester) async {
      final repository = _MockSampleRepository(itemLookup: (id) => null);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [sampleRepositoryProvider.overrideWithValue(repository)],
          child: localizedTestWidget(
            child: SampleDetailPage(id: 'missing-id', onBack: () {}),
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(repository.fetchItemCalls, ['missing-id']);
      expect(find.text('Try again'), findsOneWidget);

      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();

      expect(repository.fetchItemCalls, ['missing-id', 'missing-id']);
    });
  });

  group('Accessibility & Semantics', () {
    testWidgets('headings have header semantics', (tester) async {
      await tester.pumpWidget(
        localizedTestWidget(
          child: const SampleListView(
            state: SampleListContent(_sampleItems),
            onItemSelected: _dummyOnItemSelected,
          ),
        ),
      );

      final headerFinder = find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.header == true,
      );
      expect(headerFinder, findsAtLeastNWidgets(1));
    });

    testWidgets('interactive controls have at least 48dp dimension', (
      tester,
    ) async {
      await tester.pumpWidget(
        localizedTestWidget(
          child: const SampleDetailView(
            state: SampleDetailContent(
              SampleItem(id: '1', title: 'T', description: 'D'),
            ),
            onBack: _dummyOnBack,
          ),
        ),
      );

      final iconButtonFinder = find.byType(IconButton);
      final size = tester.getSize(iconButtonFinder);
      expect(size.width, greaterThanOrEqualTo(48.0));
      expect(size.height, greaterThanOrEqualTo(48.0));
    });
  });
}

void _dummyOnItemSelected(String id) {}
void _dummyOnBack() {}

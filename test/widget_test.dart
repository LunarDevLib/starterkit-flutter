import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_starterkit/app/sample_app.dart';
import 'package:flutter_starterkit/features/sample/application/sample_providers.dart';
import 'package:flutter_starterkit/features/sample/data/in_memory_sample_repository.dart';

void main() {
  testWidgets('renders the canonical SampleApp', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sampleRepositoryProvider.overrideWithValue(
            InMemorySampleRepository(),
          ),
        ],
        child: const SampleApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.text('Sample items'), findsOneWidget);
    expect(find.text('First item'), findsOneWidget);
  });
}

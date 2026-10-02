import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/sample/application/sample_providers.dart';
import '../../features/sample/data/in_memory_sample_repository.dart';
import '../sample_app.dart';

Future<void> bootstrap() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    ProviderScope(
      overrides: [
        sampleRepositoryProvider.overrideWithValue(InMemorySampleRepository()),
      ],
      child: const SampleApp(),
    ),
  );
}

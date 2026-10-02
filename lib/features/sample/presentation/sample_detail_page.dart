import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/async_state_views.dart';
import '../../../shared/widgets/responsive_page.dart';
import '../application/sample_providers.dart';
import '../domain/sample_item.dart';

/// Pure presentational widget for the sample detail screen.
class SampleDetailView extends StatelessWidget {
  const SampleDetailView({
    required this.state,
    required this.onBack,
    this.onRetry,
    super.key,
  });

  final SampleDetailState state;
  final VoidCallback onBack;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    return ResponsivePage(
      child: Column(
        key: const ValueKey('sample_detail_root'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildTopBar(context, l10n, theme),
          const SizedBox(height: 24),
          _buildBody(context, l10n, theme),
        ],
      ),
    );
  }

  Widget _buildTopBar(
    BuildContext context,
    AppLocalizations l10n,
    ThemeData theme,
  ) {
    return Semantics(
      label: l10n.sampleBackLabel,
      button: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minWidth: kMinInteractiveDimension,
          minHeight: kMinInteractiveDimension,
        ),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: IconButton.filledTonal(
            icon: const Icon(Icons.arrow_back_rounded),
            tooltip: l10n.sampleBackLabel,
            onPressed: onBack,
          ),
        ),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    AppLocalizations l10n,
    ThemeData theme,
  ) {
    switch (state) {
      case SampleDetailLoading():
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 48),
          child: LoadingStateView(label: l10n.loading),
        );
      case SampleDetailNotFound():
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 48),
          child: Center(
            child: ErrorStateView(
              title: l10n.sampleDetailNotFoundTitle,
              message: l10n.sampleDetailNotFoundMessage,
              retryLabel: l10n.retry,
              onRetry: onRetry,
            ),
          ),
        );
      case SampleDetailError():
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 48),
          child: Center(
            child: ErrorStateView(
              title: l10n.errorTitle,
              message: l10n.sampleErrorMessage,
              retryLabel: l10n.retry,
              onRetry: onRetry,
            ),
          ),
        );
      case SampleDetailContent(item: final item):
        return _SampleDetailContentCard(item: item);
    }
  }
}

class _SampleDetailContentCard extends StatelessWidget {
  const _SampleDetailContentCard({required this.item});

  final SampleItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text(item.title, style: theme.textTheme.displaySmall),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: theme.colorScheme.secondaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            '#${item.id}',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSecondaryContainer,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(height: 24),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: SizedBox(
              width: double.infinity,
              child: Text(
                item.description,
                style: theme.textTheme.bodyLarge?.copyWith(height: 1.6),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Page wrapper that connects [sampleDetailProvider] to [SampleDetailView].
class SampleDetailPage extends ConsumerWidget {
  const SampleDetailPage({required this.id, required this.onBack, super.key});

  final String id;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(sampleDetailProvider(id));
    return SampleDetailView(
      state: state,
      onBack: onBack,
      onRetry: () => ref.read(sampleDetailProvider(id).notifier).retry(),
    );
  }
}

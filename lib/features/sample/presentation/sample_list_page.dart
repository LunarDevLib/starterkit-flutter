import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/async_state_views.dart';
import '../../../shared/widgets/responsive_page.dart';
import '../application/sample_providers.dart';
import '../domain/sample_item.dart';

/// Pure presentational widget for the sample list screen.
class SampleListView extends StatelessWidget {
  const SampleListView({
    required this.state,
    required this.onItemSelected,
    this.onRetry,
    super.key,
  });

  final SampleListState state;
  final void Function(String id) onItemSelected;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    return ResponsivePage(
      child: Column(
        key: const ValueKey('sample_list_root'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const BrandMark(),
          const SizedBox(height: 32),
          Semantics(
            header: true,
            child: Text(
              l10n.sampleListTitle,
              style: theme.textTheme.displaySmall,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.sampleListSubtitle,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 28),
          _buildBody(context, l10n, theme),
        ],
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    AppLocalizations l10n,
    ThemeData theme,
  ) {
    switch (state) {
      case SampleListLoading():
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 48),
          child: LoadingStateView(label: l10n.loading),
        );
      case SampleListError():
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
      case SampleListContent(items: final items):
        if (items.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 48),
            child: Center(
              child: EmptyStateView(
                title: l10n.emptyTitle,
                message: l10n.emptyMessage,
              ),
            ),
          );
        }
        return ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: items.length,
          separatorBuilder: (context, index) => const SizedBox(height: 12),
          itemBuilder: (context, index) {
            final item = items[index];
            return _SampleItemCard(
              item: item,
              a11yLabel: l10n.sampleItemA11yLabel(item.title),
              onTap: () => onItemSelected(item.id),
            );
          },
        );
    }
  }
}

class _SampleItemCard extends StatelessWidget {
  const _SampleItemCard({
    required this.item,
    required this.a11yLabel,
    required this.onTap,
  });

  final SampleItem item;
  final String a11yLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      label: a11yLabel,
      button: true,
      container: true,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 64),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.title,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          item.description,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: theme.colorScheme.onSurfaceVariant,
                    size: 24,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Page wrapper that connects [sampleListProvider] to [SampleListView].
class SampleListPage extends ConsumerWidget {
  const SampleListPage({required this.onItemSelected, super.key});

  final void Function(String id) onItemSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(sampleListProvider);
    return SampleListView(
      state: state,
      onItemSelected: onItemSelected,
      onRetry: () => ref.read(sampleListProvider.notifier).retry(),
    );
  }
}

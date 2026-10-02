import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/sample/presentation/sample_detail_page.dart';
import '../../features/sample/presentation/sample_list_page.dart';
import '../../features/sample/presentation/sample_unknown_route_page.dart';

final sampleRouterProvider = Provider<GoRouter>((ref) {
  final router = createSampleRouter();
  ref.onDispose(router.dispose);
  return router;
});

GoRouter createSampleRouter({String initialLocation = '/'}) => GoRouter(
  initialLocation: initialLocation,
  errorBuilder: (context, state) =>
      SampleUnknownRoutePage(onBack: () => GoRouter.of(context).go('/')),
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => SampleListPage(
        onItemSelected: (id) =>
            context.push('/samples/${Uri.encodeComponent(id)}'),
      ),
    ),
    GoRoute(
      path: '/samples/:id',
      builder: (context, state) => SampleDetailPage(
        id: state.pathParameters['id']!,
        onBack: () {
          if (GoRouter.of(context).canPop()) {
            GoRouter.of(context).pop();
          } else {
            GoRouter.of(context).go('/');
          }
        },
      ),
    ),
  ],
);

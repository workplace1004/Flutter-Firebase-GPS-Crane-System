import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

import 'features/auth/blocked_screen.dart';
import 'features/auth/login_screen.dart';
import 'features/auth/register_screen.dart';
import 'features/chat/chat_list_screen.dart';
import 'features/earnings/earnings_screen.dart';
import 'features/evaluation/evaluation_screen.dart';
import 'features/home/driver_home_screen.dart';
import 'features/notifications/notifications_screen.dart';
import 'features/notifications/thread_read.dart';
import 'features/orders/orders_screen.dart';
import 'features/profile/driver_profile_screen.dart';
import 'features/service/active_service_screen.dart';
import 'features/settlements/settlements_screen.dart';
import 'features/shell/driver_shell.dart';

abstract final class Routes {
  static const login = '/entrar';
  static const blocked = '/cuenta-bloqueada';
  static const register = '/registro';

  // The four tabs.
  static const home = '/';
  static const orders = '/pedidos';
  static const chats = '/chat';
  static const profile = '/perfil';

  /// The job in progress. Lives in the Inicio tab, in place of the map.
  static const activeService = '/servicio';

  // Full-screen pages opened over the tabs.
  static const chat = '/servicio/:id/chat';
  static const earnings = '/ganancias';
  static const evaluation = '/evaluacion';
  static const notifications = '/notificaciones';
  static const settlements = '/cortes';
  static const settlement = '/cortes/:id';

  static String settlementFor(String id) => '/cortes/$id';

  /// A conversation a customer opened from the map, before any job.
  static const chatRequest = '/chat-solicitud/:id';

  static String chatRequestFor(String id) => '/chat-solicitud/$id';

  static String chatFor(String id) => '/servicio/$id/chat';
}

/// The pages a signed-out chofer may be on.
const Set<String> _signedOutRoutes = {Routes.login, Routes.register};

/// Router for the chofer app.
///
/// A signed-out chofer can reach two pages: sign-in and registration.
/// Registering opens an `inactive` account, so a new chofer lands on the
/// blocked screen and stays there until the office has verified the
/// documents. It is the account lifecycle, not the absence of a sign-up page,
/// that keeps a grúa without papers off the road.
///
/// Signed in, everything lives in four tabs under a bottom bar (see
/// [DriverShell]); a conversation and the earnings breakdown open over them.
///
/// The other rule is that an active job wins. If `currentServiceId` is set, the
/// Inicio tab shows the service screen instead of the map — a force-quit
/// mid-tow reopens on the tow.
final routerProvider = Provider<GoRouter>((ref) {
  final refresh = _RouterRefresh(ref);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    initialLocation: Routes.home,
    refreshListenable: refresh,
    redirect: (context, state) {
      final auth = ref.read(authStateProvider);
      if (auth.isLoading) return null;

      final location = state.matchedLocation;
      final onSignedOutPage = _signedOutRoutes.contains(location);
      if (auth.value == null) {
        return onSignedOutPage ? null : Routes.login;
      }

      final driver = ref.read(currentDriverProvider).value;
      // Hold still until the chofer record arrives; bouncing to the blocked
      // screen on a null we have not loaded yet reads as a suspension.
      if (driver == null) return onSignedOutPage ? Routes.home : null;

      if (!driver.status.canWork) {
        return location == Routes.blocked ? null : Routes.blocked;
      }

      if (onSignedOutPage || location == Routes.blocked) {
        return Routes.home;
      }

      final active = ref.read(activeDriverServiceProvider).value;
      if (active != null && location == Routes.home) return Routes.activeService;
      if (active == null && location == Routes.activeService) return Routes.home;

      return null;
    },
    routes: [
      GoRoute(path: Routes.login, builder: (_, _) => const LoginScreen()),
      GoRoute(path: Routes.register, builder: (_, _) => const RegisterScreen()),
      GoRoute(path: Routes.blocked, builder: (_, _) => const BlockedScreen()),
      StatefulShellRoute.indexedStack(
        builder: (_, _, shell) => DriverShell(navigationShell: shell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: Routes.home,
                builder: (_, _) => const DriverHomeScreen(),
              ),
              GoRoute(
                path: Routes.activeService,
                builder: (_, _) => const ActiveServiceScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: Routes.orders,
                builder: (_, _) => const OrdersScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: Routes.chats,
                builder: (_, _) => const ChatListScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: Routes.profile,
                builder: (_, _) => const DriverProfileScreen(),
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: Routes.chat,
        builder: (_, state) {
          final id = state.pathParameters['id'] ?? '';
          return MarkThreadRead(
            targetId: id,
            child: ServiceChatScreen(serviceId: id, role: UserRole.driver),
          );
        },
      ),
      GoRoute(path: Routes.earnings, builder: (_, _) => const EarningsScreen()),
      GoRoute(
        path: Routes.evaluation,
        builder: (_, _) => const EvaluationScreen(),
      ),
      GoRoute(
        path: Routes.settlements,
        builder: (_, _) => const SettlementsScreen(),
      ),
      GoRoute(
        path: Routes.settlement,
        builder: (_, state) => SettlementDetailScreen(
          settlementId: state.pathParameters['id'] ?? '',
        ),
      ),
      GoRoute(
        path: Routes.notifications,
        builder: (_, _) => const NotificationsScreen(),
      ),
      GoRoute(
        path: Routes.chatRequest,
        builder: (_, state) {
          final id = state.pathParameters['id'] ?? '';
          return MarkThreadRead(
            targetId: id,
            child: RequestChatScreen(requestId: id, role: UserRole.driver),
          );
        },
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      body: EmptyState(
        title: 'Página no encontrada',
        message: 'La dirección ${state.uri} no existe.',
        icon: Icons.error_outline,
        actionLabel: 'Ir al inicio',
        onAction: () => context.go(Routes.home),
      ),
    ),
  );
});

class _RouterRefresh extends ChangeNotifier {
  _RouterRefresh(Ref ref) {
    _subscriptions = [
      ref.listen(authStateProvider, (_, _) => notifyListeners()),
      ref.listen(currentDriverProvider, (_, _) => notifyListeners()),
      ref.listen(activeDriverServiceProvider, (_, _) => notifyListeners()),
    ];
  }

  late final List<ProviderSubscription<Object?>> _subscriptions;

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.close();
    }
    super.dispose();
  }
}

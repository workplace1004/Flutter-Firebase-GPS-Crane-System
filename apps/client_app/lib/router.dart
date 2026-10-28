import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

import 'features/auth/otp_screen.dart';
import 'features/auth/phone_screen.dart';
import 'features/auth/profile_setup_screen.dart';
import 'features/auth/register_screen.dart';
import 'features/auth/welcome_screen.dart';
import 'features/chat/chat_list_screen.dart';
import 'features/history/history_screen.dart';
import 'features/history/service_detail_screen.dart';
import 'features/home/home_screen.dart';
import 'features/profile/profile_screen.dart';
import 'features/request/request_controller.dart';
import 'features/request/request_screen.dart';
import 'features/shell/client_shell.dart';
import 'features/tracking/tracking_screen.dart';

abstract final class Routes {
  static const welcome = '/bienvenida';
  static const phone = '/telefono';
  static const register = '/registro';
  static const otp = '/codigo';
  static const profileSetup = '/completar-perfil';

  // The four tabs.
  static const home = '/';
  static const history = '/historial';
  static const chats = '/chat';
  static const profile = '/perfil';

  /// The tow in flight. Lives in the Inicio tab, in place of the map.
  static const tracking = '/servicio';

  // Full-screen pages opened over the tabs.
  static const request = '/solicitar';
  static const chat = '/servicio/:id/chat';
  static const serviceDetail = '/historial/:id';

  /// A chat opened from a nearby truck, before any job.
  static const chatRequest = '/chat-solicitud/:id';

  static String trackingFor(String id) => '/servicio?id=$id';

  static String chatFor(String id) => '/servicio/$id/chat';

  static String chatRequestFor(String id) => '/chat-solicitud/$id';

  /// The request form, with a truck from the home map to offer the job first.
  static String requestTruck(NearbyTruck truck) => Uri(
    path: request,
    queryParameters: {'grua': truck.ref, 'tipo': truck.truckType.wire},
  ).toString();

  static String detailFor(String id) => '/historial/$id';
}

/// Router for the customer app.
///
/// Two redirects carry all the routing logic, and both read from streams rather
/// than from a snapshot taken at build time:
///
/// 1. Not signed in → the welcome screen. Signed in but with no name yet → the
///    profile step, because a chofer needs somebody to ask for on arrival.
/// 2. A customer with a service in flight is sent to tracking wherever they
///    were headed. This is what makes a cold start after a force-quit land on
///    the tow that is actually happening, rather than on a request button that
///    would be refused.
///
/// Signed in, everything lives in four tabs under a bottom bar (see
/// [ClientShell]). The request form, a conversation and an invoice open over
/// them, full-screen: each is one job to finish, not a place to browse from.
final routerProvider = Provider<GoRouter>((ref) {
  final refresh = _RouterRefresh(ref);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    initialLocation: Routes.home,
    refreshListenable: refresh,
    redirect: (context, state) {
      final auth = ref.read(authStateProvider);
      // Hold the current route until the first auth snapshot arrives, so the
      // app does not flash the welcome screen for a signed-in user.
      if (auth.isLoading) return null;

      final signedIn = auth.value != null;
      final location = state.matchedLocation;
      final onAuthFlow =
          location == Routes.welcome ||
          location == Routes.phone ||
          location == Routes.register ||
          location == Routes.otp;

      if (!signedIn) return onAuthFlow ? null : Routes.welcome;

      // Hold until the profile has loaded once. After that, no document is
      // the same as no name: the server has not made it yet, or making it
      // failed, and either way the profile step is where it gets fixed.
      // Treating "no document" as complete sent a brand-new customer home
      // with no name for the chofer to ask for.
      final profile = ref.read(currentUserProvider);
      if (profile.isLoading && !profile.hasValue) return null;
      final user = profile.value;
      if (user == null || !user.hasProfile) {
        return location == Routes.profileSetup ? null : Routes.profileSetup;
      }

      if (onAuthFlow || location == Routes.profileSetup) {
        return Routes.home;
      }

      final active = ref.read(activeClientServiceProvider).value;
      if (active != null &&
          (location == Routes.home || location == Routes.request)) {
        return Routes.trackingFor(active.id);
      }
      if (active == null && location == Routes.tracking) return Routes.home;

      return null;
    },
    routes: [
      GoRoute(path: Routes.welcome, builder: (_, _) => const WelcomeScreen()),
      GoRoute(path: Routes.phone, builder: (_, _) => const PhoneScreen()),
      GoRoute(path: Routes.register, builder: (_, _) => const RegisterScreen()),
      GoRoute(
        path: Routes.otp,
        builder: (_, state) => OtpScreen(
          verificationId: state.uri.queryParameters['vid'] ?? '',
          phone: state.uri.queryParameters['phone'] ?? '',
        ),
      ),
      GoRoute(
        path: Routes.profileSetup,
        builder: (_, _) => const ProfileSetupScreen(),
      ),
      StatefulShellRoute.indexedStack(
        builder: (_, _, shell) => ClientShell(navigationShell: shell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(path: Routes.home, builder: (_, _) => const HomeScreen()),
              GoRoute(
                path: Routes.tracking,
                builder: (_, state) => TrackingScreen(
                  serviceId: state.uri.queryParameters['id'] ?? '',
                ),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: Routes.history,
                builder: (_, _) => const HistoryScreen(),
                routes: [
                  // Inside the tab, so closing an invoice comes back to the
                  // list with the bar still there.
                  GoRoute(
                    path: ':id',
                    builder: (_, state) => ServiceDetailScreen(
                      serviceId: state.pathParameters['id'] ?? '',
                    ),
                  ),
                ],
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
                builder: (_, _) => const ProfileScreen(),
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: Routes.request,
        builder: (_, state) {
          final ref = state.uri.queryParameters['grua'];
          return RequestScreen(
            preferredTruck: ref == null || ref.isEmpty
                ? null
                : PreferredTruck(
                    ref: ref,
                    truckType: TruckType.fromWire(
                      state.uri.queryParameters['tipo'],
                    ),
                  ),
          );
        },
      ),
      GoRoute(
        path: Routes.chat,
        builder: (_, state) => ServiceChatScreen(
          serviceId: state.pathParameters['id'] ?? '',
          role: UserRole.client,
        ),
      ),
      GoRoute(
        path: Routes.chatRequest,
        builder: (_, state) => RequestChatScreen(
          requestId: state.pathParameters['id'] ?? '',
          role: UserRole.client,
        ),
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

/// Bridges the auth, profile and active-service providers into something
/// GoRouter will listen to.
class _RouterRefresh extends ChangeNotifier {
  _RouterRefresh(Ref ref) {
    _subscriptions = [
      ref.listen(authStateProvider, (_, _) => notifyListeners()),
      ref.listen(currentUserProvider, (_, _) => notifyListeners()),
      ref.listen(activeClientServiceProvider, (_, _) => notifyListeners()),
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

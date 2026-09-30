import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

import 'features/auth/admin_login_screen.dart';
import 'features/cash/cash_screen.dart';
import 'features/clients/clients_screen.dart';
import 'features/drivers/drivers_screen.dart';
import 'features/evaluations/evaluations_screen.dart';
import 'features/insurers/insurers_screen.dart';
import 'features/invoices/fiscal_settings_screen.dart';
import 'features/invoices/invoices_screen.dart';
import 'features/operations/operations_screen.dart';
import 'features/portal/change_password_screen.dart';
import 'features/portal/new_service_screen.dart';
import 'features/portal/portal_dashboard_screen.dart';
import 'features/portal/portal_invoices_screen.dart';
import 'features/portal/portal_map_screen.dart';
import 'features/portal/portal_service_detail_screen.dart';
import 'features/portal/portal_services_screen.dart';
import 'features/portal/portal_shell.dart';
import 'features/portal/portal_users_screen.dart';
import 'features/reports/reports_screen.dart';
import 'features/services/services_screen.dart';
import 'features/settlements/settlements_screen.dart';
import 'features/shell/admin_shell.dart';
import 'features/trucks/trucks_screen.dart';
import 'features/verification/license_verification_screen.dart';

abstract final class Routes {
  static const login = '/entrar';
  static const operations = '/';
  static const services = '/servicios';
  static const clients = '/clientes';
  static const drivers = '/choferes';
  static const licenses = '/verificacion';
  static const trucks = '/gruas';
  static const reports = '/reportes';
  static const evaluations = '/evaluaciones';
  static const cash = '/efectivo';
  static const settlements = '/cortes';
  static const insurers = '/aseguradoras';
  static const insurer = '/aseguradoras/:id';
  static const defaultTariff = '/tarifa-base';

  static String insurerFor(String id) => '/aseguradoras/$id';

  static const invoices = '/facturas';
  static const fiscalSettings = '/facturas/comprobantes';
  static const invoice = '/facturas/:id';

  static String invoiceFor(String id) => '/facturas/$id';

  // The insurance companies' portal. Nothing outside it is theirs, and
  // nothing inside it is the office's.
  static const portal = '/portal';
  static const portalNew = '/portal/nuevo';
  static const portalMap = '/portal/mapa';
  static const portalServices = '/portal/servicios';
  static const portalService = '/portal/servicios/:id';
  static const portalUsers = '/portal/usuarios';
  static const portalPassword = '/portal/clave';
  static const portalInvoices = '/portal/facturas';
  static const portalInvoice = '/portal/facturas/:id';

  static String portalInvoiceFor(String id) => '/portal/facturas/$id';

  /// The company's managers only: its people, and its invoices.
  static bool isManagersOnly(String location) =>
      location == portalUsers ||
      location == portalInvoices ||
      location.startsWith('$portalInvoices/');

  static String portalServiceFor(String id) => '/portal/servicios/$id';

  static bool isPortal(String location) =>
      location == portal || location.startsWith('$portal/');

  /// The Servicios page with one service's record open.
  static String serviceDetail(String id) => '/servicios?id=$id';

  /// The map with one live service selected.
  static String operationsFor(String id) => '/?id=$id';

  /// The Servicios page with a search already typed in.
  static String servicesSearch(String query) =>
      Uri(path: services, queryParameters: {'q': query}).toString();
}

/// Router for the operations panel.
///
/// Every route is URL-addressable so a dispatcher can paste a link to a service
/// into WhatsApp and the person who opens it lands on that service, and so a
/// browser refresh does not throw away where they were.
///
/// Permissions are re-checked on the server for every callable regardless of
/// what this table allows. A route guard is a convenience for the person using
/// the panel, never a security boundary.
final routerProvider = Provider<GoRouter>((ref) {
  final refresh = _RouterRefresh(ref);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    initialLocation: Routes.operations,
    refreshListenable: refresh,
    redirect: (context, state) {
      final auth = ref.read(authStateProvider);
      if (auth.isLoading) return null;

      final signedIn = auth.value != null;
      final location = state.matchedLocation;

      if (!signedIn) return location == Routes.login ? null : Routes.login;

      // A session restored from a page refresh never passes through the login
      // screen, so the role check has to live here too. Without it an account
      // with no role lands in the panel and every query fails with a
      // permission error that reads like an outage.
      final roleValue = ref.read(currentRoleProvider);
      if (roleValue.isLoading) return null;
      final role = roleValue.value ?? UserRole.unknown;
      if (!role.canUsePanel) {
        return location == Routes.login ? null : Routes.login;
      }

      // An insurance company's people live in the portal and only there.
      if (role.isInsurer) {
        if (!Routes.isPortal(location)) return Routes.portal;
        final memberValue = ref.read(myInsurerMemberProvider);
        // Until the person's own record arrives, nothing is decided on a
        // guess; the redirect runs again when it does.
        if (!memberValue.hasValue) return null;
        final member = memberValue.value;
        // A password somebody else has seen is changed before anything else.
        if (member != null &&
            member.mustChangePassword &&
            location != Routes.portalPassword) {
          return Routes.portalPassword;
        }
        if (Routes.isManagersOnly(location) && !(member?.canManageMembers ?? false)) {
          return Routes.portal;
        }
        return null;
      }

      // The office has its own screens for all of this.
      if (Routes.isPortal(location)) return Routes.operations;
      if (location == Routes.login) return Routes.operations;
      return null;
    },
    routes: [
      GoRoute(path: Routes.login, builder: (_, _) => const AdminLoginScreen()),
      ShellRoute(
        builder: (context, state, child) => PortalShell(
          location: state.matchedLocation,
          child: child,
        ),
        routes: [
          GoRoute(
            path: Routes.portal,
            builder: (_, _) => const PortalDashboardScreen(),
          ),
          GoRoute(
            path: Routes.portalNew,
            builder: (_, _) => const NewServiceScreen(),
          ),
          GoRoute(
            path: Routes.portalMap,
            builder: (_, _) => const PortalMapScreen(),
          ),
          GoRoute(
            path: Routes.portalServices,
            builder: (_, _) => const PortalServicesScreen(),
          ),
          GoRoute(
            path: Routes.portalService,
            builder: (_, state) => PortalServiceDetailScreen(
              serviceId: state.pathParameters['id'] ?? '',
            ),
          ),
          GoRoute(
            path: Routes.portalUsers,
            builder: (_, _) => const PortalUsersScreen(),
          ),
          GoRoute(
            path: Routes.portalPassword,
            builder: (_, _) => const ChangePasswordScreen(),
          ),
          GoRoute(
            path: Routes.portalInvoices,
            builder: (_, _) => const PortalInvoicesScreen(),
          ),
          GoRoute(
            path: Routes.portalInvoice,
            builder: (_, state) => PortalInvoiceDetailScreen(
              invoiceId: state.pathParameters['id'] ?? '',
            ),
          ),
        ],
      ),
      ShellRoute(
        builder: (context, state, child) => AdminShell(
          location: state.matchedLocation,
          child: child,
        ),
        routes: [
          GoRoute(
            path: Routes.operations,
            builder: (_, state) => OperationsScreen(
              selectedServiceId: state.uri.queryParameters['id'],
            ),
          ),
          GoRoute(
            path: Routes.services,
            builder: (_, state) => ServicesScreen(
              initialQuery: state.uri.queryParameters['q'],
              openServiceId: state.uri.queryParameters['id'],
            ),
          ),
          GoRoute(path: Routes.clients, builder: (_, _) => const ClientsScreen()),
          GoRoute(path: Routes.drivers, builder: (_, _) => const DriversScreen()),
          GoRoute(
            path: Routes.licenses,
            builder: (_, _) => const LicenseVerificationScreen(),
          ),
          GoRoute(path: Routes.trucks, builder: (_, _) => const TrucksScreen()),
          GoRoute(path: Routes.reports, builder: (_, _) => const ReportsScreen()),
          GoRoute(
            path: Routes.evaluations,
            builder: (_, _) => const EvaluationsScreen(),
          ),
          GoRoute(path: Routes.cash, builder: (_, _) => const CashScreen()),
          GoRoute(
            path: Routes.settlements,
            builder: (_, _) => const SettlementsScreen(),
          ),
          GoRoute(
            path: Routes.insurers,
            builder: (_, _) => const InsurersScreen(),
          ),
          GoRoute(
            path: Routes.insurer,
            builder: (_, state) =>
                InsurerDetailScreen(insurerId: state.pathParameters['id'] ?? ''),
          ),
          GoRoute(
            path: Routes.defaultTariff,
            builder: (_, _) => const DefaultTariffScreen(),
          ),
          GoRoute(
            path: Routes.invoices,
            builder: (_, _) => const InvoicesScreen(),
          ),
          // Before the id route, which would otherwise take "comprobantes".
          GoRoute(
            path: Routes.fiscalSettings,
            builder: (_, _) => const FiscalSettingsScreen(),
          ),
          GoRoute(
            path: Routes.invoice,
            builder: (_, state) =>
                InvoiceDetailScreen(invoiceId: state.pathParameters['id'] ?? ''),
          ),
        ],
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      body: EmptyState(
        title: 'Página no encontrada',
        message: 'La dirección ${state.uri} no existe.',
        icon: Icons.error_outline,
        actionLabel: 'Ir al inicio',
        // The redirect sends each kind of account to its own start page.
        onAction: () => context.go(Routes.operations),
      ),
    ),
  );
});

class _RouterRefresh extends ChangeNotifier {
  _RouterRefresh(Ref ref) {
    // The role matters as much as the session: the redirect refuses anyone
    // without a panel claim, so it has to re-run when that claim arrives. A
    // company person's own record decides the forced password change and the
    // users page, so that too.
    _subscriptions = [
      ref.listen(authStateProvider, (_, _) => notifyListeners()),
      ref.listen(currentRoleProvider, (_, _) => notifyListeners()),
      ref.listen(myInsurerMemberProvider, (_, _) => notifyListeners()),
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

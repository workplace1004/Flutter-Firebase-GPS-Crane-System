import 'package:admin_web/app.dart';
import 'package:admin_web/features/portal/address_field.dart';
import 'package:admin_web/features/portal/portal_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';
import 'package:grua_testing/grua_testing.dart';
import 'package:intl/date_symbol_data_local.dart';

/// The insurance company's portal inside the panel: who gets in, what they
/// see, ordering a tow at the price shown, and cancelling it.
Future<void> main() async {
  setUpAll(() => initializeDateFormatting('es_DO'));

  const config = AppConfig(
    flavor: Flavor.dev,
    appKind: AppKind.admin,
    firebaseProjectId: 'grua-rd-test',
    googleMapsApiKey: '',
    useEmulators: false,
    emulatorHost: 'localhost',
    functionsRegion: 'us-east1',
  );

  const operatorEmail = 'restrepo@segurosdemo.do';
  const managerEmail = 'marta@segurosdemo.do';

  Future<void> signIn(
    WidgetTester tester,
    DemoBackend backend,
    String email,
  ) async {
    tester.view
      ..devicePixelRatio = 1.0
      ..physicalSize = const Size(1440, 1600);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appConfigProvider.overrideWithValue(config),
          ...demoOverrides(backend: backend, role: UserRole.admin, actingAs: 'admin-1'),
          // No Places key in a test: the order form suggests these instead.
          knownPlacesProvider.overrideWithValue(_places),
        ],
        child: const AdminApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, email);
    await tester.enterText(find.byType(TextFormField).last, 'secret123');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Entrar'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
  }

  /// Stops the demo dispatch the test started, so no timer outlives it.
  Future<void> finish(WidgetTester tester, DemoBackend backend) async {
    backend.dispose();
    await tester.pump();
  }

  String location(WidgetTester tester) {
    final context = tester.element(find.byType(Scaffold).first);
    return GoRouter.of(context).state.matchedLocation;
  }

  Future<void> go(WidgetTester tester, String path) async {
    GoRouter.of(tester.element(find.byType(Scaffold).first)).go(path);
    await tester.pumpAndSettle(const Duration(milliseconds: 500));
  }

  Future<void> nav(WidgetTester tester, String route) async {
    await tester.tap(find.byKey(Key('portal-nav-$route')));
    await tester.pumpAndSettle(const Duration(milliseconds: 500));
  }

  /// Types into an address field and takes the first suggestion.
  Future<void> pickPlace(WidgetTester tester, String field, String typed) async {
    await tester.enterText(find.byKey(Key('$field-input')), typed);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('$field-suggestion-0')));
    await tester.pumpAndSettle(const Duration(milliseconds: 500));
  }

  Future<String> orderTow(
    WidgetTester tester,
    DemoBackend backend, {
    String claim = 'SIN-2024-001489',
  }) async {
    await nav(tester, '/portal/nuevo');
    await tester.enterText(find.byKey(const Key('claim-number')), claim);
    await tester.enterText(find.byKey(const Key('insured-name')), 'Juan Carlos Pérez');
    await tester.enterText(find.byKey(const Key('vehicle-plate')), 'g123456');
    await pickPlace(tester, 'pickup', 'zona colonial');
    await pickPlace(tester, 'dropoff', 'autocentro');
    await tester.ensureVisible(find.byKey(const Key('order-service')));
    await tester.tap(find.byKey(const Key('order-service')));
    await tester.pumpAndSettle(const Duration(milliseconds: 500));
    return backend.allServices
        .firstWhere((s) => s.insurance?.claimNumber == claim)
        .id;
  }

  testWidgets('an operator lands on the portal and sees only its own menu', (tester) async {
    final backend = DemoBackend()..seed();
    await signIn(tester, backend, operatorEmail);

    expect(location(tester), '/portal');
    expect(find.byType(PortalShell), findsOneWidget);
    expect(find.byKey(const Key('portal-company-name')), findsOneWidget);
    expect(find.text('Seguros Demo, S.A.'), findsOneWidget);
    expect(find.text('Agente Restrepo'), findsOneWidget);
    expect(find.byKey(const Key('kpi-month-services')), findsOneWidget);
    expect(find.byKey(const Key('kpi-month-cost')), findsOneWidget);
    expect(find.byKey(const Key('kpi-average-arrival')), findsOneWidget);
    // The office's screens and the company's users page are not offered.
    expect(find.text('Operaciones'), findsNothing);
    expect(find.text('Choferes'), findsNothing);
    expect(find.text('Cortes'), findsNothing);
    expect(find.byKey(const Key('portal-nav-/portal/usuarios')), findsNothing);
    // A customer's history is not the company's.
    expect(find.text('Todavía no has pedido ningún servicio.'), findsOneWidget);
    await finish(tester, backend);
  });

  testWidgets('an operator is kept inside the portal', (tester) async {
    final backend = DemoBackend()..seed();
    await signIn(tester, backend, operatorEmail);

    for (final path in ['/', '/servicios', '/aseguradoras', '/cortes', '/portal/usuarios']) {
      await go(tester, path);
      expect(location(tester), '/portal', reason: path);
    }
    // A customer's tow is "not found", not shown.
    await go(tester, '/portal/servicios/svc-history-0');
    expect(find.byKey(const Key('portal-service-missing')), findsOneWidget);
    await finish(tester, backend);
  });

  testWidgets('the office is kept out of the portal', (tester) async {
    final backend = DemoBackend()..seed();
    await signIn(tester, backend, 'ops@gruasrd.do');

    expect(location(tester), '/');
    await go(tester, '/portal/nuevo');
    expect(location(tester), '/');
    expect(find.byType(PortalShell), findsNothing);
    await finish(tester, backend);
  });

  testWidgets('a manager also manages the company’s people', (tester) async {
    final backend = DemoBackend()..seed();
    await signIn(tester, backend, managerEmail);

    await nav(tester, '/portal/usuarios');
    expect(location(tester), '/portal/usuarios');
    expect(find.byKey(const Key('insurer-user-insurer-operator-1')), findsOneWidget);
    expect(find.byKey(const Key('add-insurer-user')), findsOneWidget);
    // Their colleague has controls; their own row does not.
    expect(find.byKey(const Key('insurer-user-active-insurer-operator-1')), findsOneWidget);
    expect(find.byKey(const Key('insurer-user-active-insurer-manager-1')), findsNothing);
    expect(find.byKey(const Key('insurer-user-self-insurer-manager-1')), findsOneWidget);
    await finish(tester, backend);
  });

  testWidgets('the form refuses an order without a claim or places', (tester) async {
    final backend = DemoBackend()..seed();
    await signIn(tester, backend, operatorEmail);
    await nav(tester, '/portal/nuevo');

    expect(find.byKey(const Key('price-waiting')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('order-service')));
    await tester.tap(find.byKey(const Key('order-service')));
    await tester.pumpAndSettle();

    expect(find.text('Escribe el número de siniestro.'), findsOneWidget);
    expect(find.byKey(const Key('places-missing')), findsOneWidget);
    expect(backend.allServices.where((s) => s.insurerId.isNotEmpty), isEmpty);
    await finish(tester, backend);
  });

  testWidgets('orders a tow at the price shown, then finds it in the history', (tester) async {
    final backend = DemoBackend()..seed();
    await signIn(tester, backend, operatorEmail);
    await nav(tester, '/portal/nuevo');

    await pickPlace(tester, 'pickup', 'zona colonial');
    expect(find.byKey(const Key('price-waiting')), findsOneWidget);
    await pickPlace(tester, 'dropoff', 'autocentro');

    // Zona Colonial to Autocentro: a light vehicle in the 0–10 km zone.
    expect(find.byKey(const Key('price-preview')), findsOneWidget);
    expect(find.textContaining('0–10 km'), findsOneWidget);
    expect(find.text(250000.formatDOP), findsWidgets);
    expect(find.text(45000.formatDOP), findsOneWidget);
    expect(find.text(295000.formatDOP), findsOneWidget);

    // An SUV is priced in its own column.
    await tester.tap(find.byKey(const Key('vehicle-type')));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Jeepeta ·').last);
    await tester.pumpAndSettle(const Duration(milliseconds: 500));
    expect(find.text(320000.formatDOP), findsWidgets);

    await tester.enterText(find.byKey(const Key('claim-number')), 'SIN-2024-001489');
    await tester.enterText(find.byKey(const Key('insured-name')), 'Juan Carlos Pérez');
    await tester.enterText(find.byKey(const Key('insured-phone')), '809-555-0123');
    await tester.enterText(find.byKey(const Key('vehicle-plate')), 'g123456');
    await tester.enterText(find.byKey(const Key('vehicle-make')), 'Toyota');
    await tester.ensureVisible(find.byKey(const Key('order-service')));
    await tester.tap(find.byKey(const Key('order-service')));
    await tester.pumpAndSettle(const Duration(milliseconds: 500));

    final service = backend.allServices.singleWhere((s) => s.insurerId == 'ins-demo');
    expect(service.insurance?.claimNumber, 'SIN-2024-001489');
    expect(service.vehicle.type, VehicleType.suv);
    expect(service.vehicle.plate, 'G123456');
    expect(service.billing?.subtotalCents, 320000);
    expect(service.pickup.address, 'Zona Colonial, Santo Domingo');

    expect(location(tester), '/portal/servicios/${service.id}');
    expect(find.text('Siniestro SIN-2024-001489'), findsOneWidget);
    expect(find.text(377600.formatDOP), findsOneWidget);

    await nav(tester, '/portal/servicios');
    expect(find.byKey(Key('portal-service-${service.id}')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('portal-services-search')), 'g123');
    await tester.pumpAndSettle();
    expect(find.byKey(Key('portal-service-${service.id}')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('portal-services-search')), 'nada que ver');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('portal-services-empty')), findsOneWidget);

    // The front page counts it.
    await nav(tester, '/portal');
    expect(
      find.descendant(
        of: find.byKey(const Key('kpi-month-services')),
        matching: find.text('1'),
      ),
      findsOneWidget,
    );
    await finish(tester, backend);
  });

  testWidgets('a second tow for the same claim is refused on the form', (tester) async {
    final backend = DemoBackend()..seed();
    await signIn(tester, backend, operatorEmail);
    await orderTow(tester, backend);

    await nav(tester, '/portal/nuevo');
    await tester.enterText(find.byKey(const Key('claim-number')), 'sin 2024 001489');
    await pickPlace(tester, 'pickup', 'zona colonial');
    await pickPlace(tester, 'dropoff', 'autocentro');
    await tester.ensureVisible(find.byKey(const Key('order-service')));
    await tester.tap(find.byKey(const Key('order-service')));
    await tester.pumpAndSettle(const Duration(milliseconds: 500));

    expect(find.byKey(const Key('order-error')), findsOneWidget);
    expect(
      find.text('Ya hay una grúa en curso para ese número de siniestro.'),
      findsOneWidget,
    );
    expect(location(tester), '/portal/nuevo');
    expect(backend.allServices.where((s) => s.insurerId == 'ins-demo'), hasLength(1));
    await finish(tester, backend);
  });

  testWidgets('the company cancels its own tow', (tester) async {
    final backend = DemoBackend()..seed();
    await signIn(tester, backend, operatorEmail);
    final id = await orderTow(tester, backend);
    await go(tester, '/portal/servicios/$id');

    await tester.tap(find.byKey(const Key('portal-cancel-service')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('portal-cancel-reason')), 'Duplicado');
    await tester.tap(find.byKey(const Key('portal-confirm-cancel')));
    await tester.pumpAndSettle(const Duration(milliseconds: 500));

    final service = backend.service(id)!;
    expect(service.status, ServiceStatus.cancelled);
    expect(service.cancellation?.by, CancelledBy.insurer);
    expect(find.text('Servicio cancelado.'), findsOneWidget);
    expect(find.byKey(const Key('portal-cancel-service')), findsNothing);
    expect(find.text('No se factura.'), findsOneWidget);
    await finish(tester, backend);
  });

  testWidgets('the live map lists the tows in flight', (tester) async {
    final backend = DemoBackend()..seed();
    await signIn(tester, backend, operatorEmail);
    await nav(tester, '/portal/mapa');
    expect(find.byKey(const Key('portal-map-empty')), findsOneWidget);

    final id = await orderTow(tester, backend);
    await nav(tester, '/portal/mapa');
    expect(find.byKey(const Key('portal-live-map')), findsOneWidget);
    expect(find.byKey(Key('portal-map-card-$id')), findsOneWidget);
    await tester.tap(find.byKey(Key('portal-map-card-$id')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Siniestro SIN-2024-001489'), findsOneWidget);
    await finish(tester, backend);
  });

  testWidgets('a temporary password is changed before anything else', (tester) async {
    final backend = DemoBackend()
      ..seed()
      ..requirePasswordChange('insurer-operator-1');
    await signIn(tester, backend, operatorEmail);

    expect(location(tester), '/portal/clave');
    expect(find.byKey(const Key('password-change-required')), findsOneWidget);
    await go(tester, '/portal/nuevo');
    expect(location(tester), '/portal/clave');

    await tester.enterText(find.byKey(const Key('password-current')), 'secret123');
    await tester.enterText(find.byKey(const Key('password-new')), 'corta');
    await tester.enterText(find.byKey(const Key('password-repeat')), 'corta');
    await tester.tap(find.byKey(const Key('password-save')));
    await tester.pumpAndSettle();
    expect(find.text('Usa al menos 8 caracteres.'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('password-new')), 'Titan2026seguro');
    await tester.enterText(find.byKey(const Key('password-repeat')), 'Titan2026otro');
    await tester.tap(find.byKey(const Key('password-save')));
    await tester.pumpAndSettle();
    expect(find.text('Las contraseñas no coinciden.'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('password-repeat')), 'Titan2026seguro');
    await tester.tap(find.byKey(const Key('password-save')));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(backend.insurerMember('ins-demo', 'insurer-operator-1')!.mustChangePassword, isFalse);
    expect(location(tester), '/portal');
    await go(tester, '/portal/nuevo');
    expect(location(tester), '/portal/nuevo');
    await finish(tester, backend);
  });

  testWidgets('a suspended company is shown why, and nothing else', (tester) async {
    final backend = DemoBackend()
      ..seed()
      ..updateInsurer(
      'ins-demo',
      status: InsurerStatus.suspended,
      statusReason: 'Pagos atrasados',
    );
    await signIn(tester, backend, operatorEmail);

    expect(find.byKey(const Key('portal-blocked')), findsOneWidget);
    expect(find.textContaining('Pagos atrasados'), findsOneWidget);
    expect(find.byKey(const Key('portal-nav-/portal/nuevo')), findsNothing);

    await tester.tap(find.text('Cerrar sesión'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(location(tester), '/entrar');
    await finish(tester, backend);
  });

  testWidgets('a deactivated person is refused', (tester) async {
    final backend = DemoBackend()
      ..seed()
      ..updateInsurerUser(
      insurerId: 'ins-demo',
      uid: 'insurer-operator-1',
      active: false,
    );
    await signIn(tester, backend, operatorEmail);

    expect(find.byKey(const Key('portal-blocked')), findsOneWidget);
    expect(find.textContaining('desactivado'), findsOneWidget);
    await finish(tester, backend);
  });

  testWidgets('a claim older than the latest tows is found in the whole history', (tester) async {
    // A clock that moves, so each tow is newer than the last.
    var clock = DateTime.utc(2026, 9, 1, 12);
    final backend = DemoBackend(
      clock: () => clock = clock.add(const Duration(seconds: 1)),
      dispatchDelay: const Duration(hours: 1),
    )..seed();
    for (var i = 0; i < 201; i++) {
      backend.createInsurerService(
        insurerId: 'ins-demo',
        insurerName: 'Seguros Demo, S.A.',
        requestedBy: 'insurer-operator-1',
        pickup: const ServiceLocation(geo: DoLocations.santoDomingo),
        dropoff: const ServiceLocation(geo: DoLocations.santoDomingo),
        vehicle: const ServiceVehicle(),
        insurance: InsuranceClaim(claimNumber: 'SIN-OLD-${i.toString().padLeft(3, '0')}'),
      );
    }
    await signIn(tester, backend, operatorEmail);
    await nav(tester, '/portal/servicios');

    // The oldest is past the latest 200 the page loads.
    await tester.enterText(find.byKey(const Key('portal-services-search')), 'sin old 000');
    await tester.pumpAndSettle();
    expect(find.text('Ningún servicio reciente coincide con la búsqueda.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('portal-search-history')));
    await tester.pumpAndSettle(const Duration(milliseconds: 500));
    final oldest = backend.allServices.singleWhere((s) => s.insurance?.claimNumber == 'SIN-OLD-000');
    expect(find.byKey(Key('portal-service-${oldest.id}')), findsOneWidget);

    // A claim nobody filed says so.
    await tester.enterText(find.byKey(const Key('portal-services-search')), 'SIN-NADA');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('portal-search-history')));
    await tester.pumpAndSettle(const Duration(milliseconds: 500));
    expect(find.text('Ningún servicio con ese número de siniestro.'), findsOneWidget);
    await finish(tester, backend);
  });

  testWidgets('every portal page fits the narrowest screen it allows', (tester) async {
    final backend = DemoBackend()..seed();
    await signIn(tester, backend, managerEmail);
    final id = await orderTow(tester, backend);
    tester.view.physicalSize = const Size(1024, 768);
    await tester.pumpAndSettle();

    for (final path in [
      '/portal',
      '/portal/nuevo',
      '/portal/mapa',
      '/portal/servicios',
      '/portal/servicios/$id',
      '/portal/usuarios',
      '/portal/clave',
    ]) {
      await go(tester, path);
      expect(location(tester), path);
      expect(tester.takeException(), isNull, reason: path);
    }
    await finish(tester, backend);
  });
}

/// What the order form offers by name in these tests.
const _places = [
  ServiceLocation(
    geo: LatLng(18.4780, -69.9312),
    address: 'Taller Autocentro, Av. 27 de Febrero, Santo Domingo',
  ),
  ServiceLocation(
    geo: LatLng(18.4735, -69.8844),
    address: 'Zona Colonial, Santo Domingo',
  ),
];

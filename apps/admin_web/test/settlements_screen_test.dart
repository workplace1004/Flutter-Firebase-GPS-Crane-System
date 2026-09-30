import 'package:admin_web/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';
import 'package:grua_testing/grua_testing.dart';
import 'package:intl/date_symbol_data_local.dart';

/// The office's side of the weekly corte: what to pay and collect on Friday,
/// recording the transfer, and cancelling a corte that came out wrong.
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

  Widget harness(DemoBackend backend, {UserRole role = UserRole.admin}) =>
      ProviderScope(
        overrides: [
          appConfigProvider.overrideWithValue(config),
          ...demoOverrides(backend: backend, role: role, actingAs: 'admin-1'),
        ],
        child: const AdminApp(),
      );

  Future<void> open(WidgetTester tester, DemoBackend backend, {UserRole role = UserRole.admin}) async {
    tester.view
      ..devicePixelRatio = 1.0
      ..physicalSize = const Size(1440, 1200);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(harness(backend, role: role));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'ops@gruasrd.do');
    await tester.enterText(find.byType(TextFormField).last, 'secret123');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Entrar'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.text('Cortes'));
    await tester.pumpAndSettle();
  }

  Finder kpi(String key, String value) => find.descendant(
        of: find.byKey(Key(key)),
        matching: find.text(value),
      );

  testWidgets('the office pays a corte and records the transfer', (tester) async {
    final backend = DemoBackend(dispatchDelay: const Duration(milliseconds: 20))
      ..seed();
    addTearDown(backend.dispose);
    final driverId = (await tester.runAsync(() => _aWeek(backend)))!;
    final id = backend
        .generateDriverSettlements(driverId: driverId, actorId: 'admin-1')
        .valueOrNull!
        .single;

    await open(tester, backend);

    expect(find.text('Cortes semanales'), findsOneWidget);
    expect(kpi('kpi-to-pay', 95000.formatDOP), findsOneWidget);
    expect(kpi('kpi-to-collect', 0.formatDOP), findsOneWidget);

    await tester.tap(find.byKey(Key('settlement-row-$id')));
    await tester.pumpAndSettle();
    expect(find.byType(SettlementView), findsOneWidget);
    expect(
      find.text('SALDO FINAL A FAVOR DEL CONDUCTOR: ${95000.formatDOP}'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('pay-settlement')));
    await tester.pumpAndSettle();

    // No reference, no payment.
    await tester.tap(find.byKey(const Key('confirm-settlement')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settlement-error')), findsOneWidget);
    expect(find.textContaining('número de la transferencia'), findsOneWidget);
    expect(backend.driverSettlement(id)!.isPending, isTrue);

    await tester.enterText(find.byKey(const Key('settlement-reference')), 'BPD-778812');
    await tester.tap(find.byKey(const Key('confirm-settlement')));
    await tester.pumpAndSettle();

    expect(find.text('Corte marcado como pagado.'), findsOneWidget);
    final paid = backend.driverSettlement(id)!;
    expect(paid.status, SettlementStatus.settled);
    expect(paid.reference, 'BPD-778812');

    // Gone from pending; still there under "Todos", with its reference.
    expect(find.text('No hay cortes pendientes.'), findsOneWidget);
    expect(kpi('kpi-to-pay', 0.formatDOP), findsOneWidget);
    await tester.tap(find.byKey(const Key('show-all-settlements')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Ref. BPD-778812'), findsOneWidget);
  });

  testWidgets('a corte cancelled gives its jobs to the next one', (tester) async {
    final backend = DemoBackend(dispatchDelay: const Duration(milliseconds: 20))
      ..seed();
    addTearDown(backend.dispose);
    final driverId = (await tester.runAsync(() => _aWeek(backend, insurer: false)))!;
    final id = backend
        .generateDriverSettlements(driverId: driverId, actorId: 'admin-1')
        .valueOrNull!
        .single;

    await open(tester, backend);
    expect(kpi('kpi-to-collect', 80000.formatDOP), findsOneWidget);

    await tester.tap(find.byKey(Key('settlement-row-$id')));
    await tester.pumpAndSettle();
    expect(find.text('Registrar pago del chofer'), findsOneWidget);

    await tester.tap(find.byKey(const Key('void-settlement')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('settlement-void-reason')), 'Precio equivocado');
    await tester.tap(find.byKey(const Key('confirm-settlement')));
    await tester.pumpAndSettle();

    expect(find.text('Corte anulado.'), findsOneWidget);
    expect(backend.driverSettlement(id)!.status, SettlementStatus.voided);

    // "Generar cortes ahora" picks the same jobs up again — with the page
    // saying it is working for as long as the call takes, not just a button
    // that has quietly gone grey.
    await tester.tap(find.byKey(const Key('generate-settlements')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const Key('settlements-generating')), findsOneWidget);
    expect(find.text('Generando cortes…'), findsWidgets);
    final button = tester.widget<ButtonStyleButton>(
      find.byKey(const Key('generate-settlements')),
    );
    expect(button.onPressed, isNull);

    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settlements-generating')), findsNothing);
    expect(find.text('Se generó 1 corte.'), findsOneWidget);
    expect(kpi('kpi-to-collect', 80000.formatDOP), findsOneWidget);

    await tester.tap(find.byKey(const Key('generate-settlements')));
    await tester.pumpAndSettle();
    expect(find.text('No hay servicios nuevos para cortar.'), findsOneWidget);
  });

  testWidgets('a dispatcher sees the cortes but cannot pay or make them',
      (tester) async {
    final backend = DemoBackend(dispatchDelay: const Duration(milliseconds: 20))
      ..seed();
    addTearDown(backend.dispose);
    final driverId = (await tester.runAsync(() => _aWeek(backend)))!;
    final id = backend
        .generateDriverSettlements(driverId: driverId, actorId: 'admin-1')
        .valueOrNull!
        .single;

    await open(tester, backend, role: UserRole.ops);

    expect(find.byKey(const Key('generate-settlements')), findsNothing);
    await tester.tap(find.byKey(Key('settlement-row-$id')));
    await tester.pumpAndSettle();
    expect(find.byType(SettlementView), findsOneWidget);
    expect(find.byKey(const Key('pay-settlement')), findsNothing);
    expect(find.byKey(const Key('void-settlement')), findsNothing);
  });
}

const _pickup = ServiceLocation(
  geo: DoLocations.santoDomingo,
  address: 'Av. 27 de Febrero',
);

final _dropoff = ServiceLocation(
  geo: LatLng(
    DoLocations.santoDomingo.latitude + 0.008,
    DoLocations.santoDomingo.longitude,
  ),
);

Future<Service> _assigned(DemoBackend backend, String id) async {
  for (var i = 0; i < 100; i++) {
    final s = backend.service(id);
    if (s?.driverId != null) return s!;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  throw StateError('Nobody took $id');
}

void _finish(DemoBackend backend, Service s) {
  for (final (to, event) in [
    (ServiceStatus.arrived, ServiceEventName.markArrived),
    (ServiceStatus.inProgress, ServiceEventName.startService),
    (ServiceStatus.completed, ServiceEventName.completeService),
  ]) {
    backend.transition(s.id, to, event, s.driverId!, UserRole.driver);
  }
}

/// An insurer job (RD$1,750 to the chofer), unless [insurer] is false, then a
/// cash job of RD$4,000 (RD$800 to Titan), for the same chofer.
Future<String> _aWeek(DemoBackend backend, {bool insurer = true}) async {
  String? driverId;
  if (insurer) {
    final job = await _assigned(
      backend,
      backend
          .createInsurerService(
            insurerId: 'ins-demo',
            insurerName: 'Seguros Demo',
            requestedBy: 'op-demo',
            pickup: _pickup,
            dropoff: _dropoff,
            vehicle: const ServiceVehicle(),
            insurance: const InsuranceClaim(claimNumber: 'SIN-1'),
          )
          .id,
    );
    driverId = job.driverId;
    _finish(backend, job);
  }
  final cash = await _assigned(
    backend,
    backend
        .createService(
          clientId: 'demo-client-1',
          pickup: _pickup,
          dropoff: _dropoff,
          vehicle: const ServiceVehicle(),
          truckType: TruckType.gancho,
          quote: const Quote(totalCents: 400000),
          route: const ServiceRoute(distanceMeters: 1000),
          preferredDriverId: driverId,
        )
        .id,
  );
  _finish(backend, cash);
  return cash.driverId!;
}

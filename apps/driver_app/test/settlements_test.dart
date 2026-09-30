import 'dart:async';

import 'package:driver_app/app.dart';
import 'package:driver_app/features/home/location_publisher.dart';
import 'package:driver_app/router.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';
import 'package:grua_testing/grua_testing.dart';
import 'package:intl/date_symbol_data_local.dart';

/// The chofer's side of the weekly corte: what Friday will say so far, and
/// each corte the office made, laid out like the printed one.
Future<void> main() async {
  setUpAll(() => initializeDateFormatting('es_DO'));

  const config = AppConfig(
    flavor: Flavor.dev,
    appKind: AppKind.driver,
    firebaseProjectId: 'grua-rd-test',
    googleMapsApiKey: '',
    useEmulators: false,
    emulatorHost: 'localhost',
    functionsRegion: 'us-east1',
  );

  Widget harness(DemoBackend backend) => ProviderScope(
        overrides: [
          appConfigProvider.overrideWithValue(config),
          ...demoOverrides(backend: backend, role: UserRole.driver),
          locationPublisherProvider.overrideWith((ref) => null),
        ],
        child: const DriverApp(),
      );

  Future<void> frames(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> signIn(WidgetTester tester) async {
    await tester.enterText(find.byType(TextFormField).first, 'driver1@gruasrd.do');
    await tester.enterText(find.byType(TextFormField).last, 'secret123');
    await tester.pump();
    await tester.tap(find.text('ENTRAR'));
    await frames(tester);
  }

  GoRouter router(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(DriverApp)))
          .read(routerProvider);

  testWidgets('the chofer follows the week, then reads the corte',
      (tester) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(430, 2400);
    addTearDown(tester.view.reset);

    final backend = DemoBackend(dispatchDelay: const Duration(milliseconds: 20))
      ..seed();
    addTearDown(backend.dispose);

    final driverId = (await tester.runAsync(() => _aWeek(backend)))!;
    backend.currentUserId = driverId;

    await tester.pumpWidget(harness(backend));
    await tester.pump();
    await signIn(tester);

    // Before Friday: what the corte will say so far.
    unawaited(router(tester).push(Routes.earnings));
    await frames(tester);
    final running = find.byKey(const Key('running-settlement'));
    expect(running, findsOneWidget);
    expect(
      find.descendant(of: running, matching: find.text('Titan te debe ${95000.formatDOP}')),
      findsOneWidget,
    );

    // Friday: the office makes the corte.
    final id = backend
        .generateDriverSettlements(driverId: driverId, actorId: 'admin')
        .valueOrNull!
        .single;
    await frames(tester);
    expect(
      find.descendant(of: running, matching: find.text('Sin saldo esta semana')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('open-settlements')));
    await frames(tester);
    expect(find.text('Mis cortes'), findsOneWidget);
    expect(find.textContaining('Titan te paga ${95000.formatDOP}'), findsOneWidget);

    await tester.tap(find.byKey(Key('settlement-$id')));
    await frames(tester);

    expect(find.byKey(const Key('settlement-insurer')), findsOneWidget);
    expect(find.byKey(const Key('settlement-cash')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('settlement-insurer')),
        matching: find.text(175000.formatDOP),
      ),
      findsWidgets,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('settlement-cash')),
        matching: find.text(80000.formatDOP),
      ),
      findsWidgets,
    );
    expect(
      find.text('SALDO FINAL A FAVOR DEL CONDUCTOR: ${95000.formatDOP}'),
      findsOneWidget,
    );
    expect(find.textContaining('Pendiente de pago'), findsOneWidget);

    // The office pays; the chofer sees it.
    backend.settleDriverSettlement(id, reference: 'BPD-778812');
    await frames(tester);
    expect(find.textContaining('Referencia BPD-778812'), findsOneWidget);
  });

  testWidgets('a corte in Titan’s favour says the chofer pays', (tester) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(430, 2400);
    addTearDown(tester.view.reset);

    final backend = DemoBackend(dispatchDelay: const Duration(milliseconds: 20))
      ..seed();
    addTearDown(backend.dispose);

    final driverId = (await tester.runAsync(() => _aWeek(backend, insurer: false)))!;
    backend.currentUserId = driverId;
    final id = backend
        .generateDriverSettlements(driverId: driverId, actorId: 'admin')
        .valueOrNull!
        .single;

    await tester.pumpWidget(harness(backend));
    await tester.pump();
    await signIn(tester);
    unawaited(router(tester).push(Routes.settlementFor(id)));
    await frames(tester);

    expect(
      find.text('SALDO FINAL A FAVOR DE TITAN: ${80000.formatDOP}'),
      findsOneWidget,
    );
    expect(find.textContaining('El conductor paga a Titan'), findsOneWidget);
    expect(find.text('Sin servicios en este período.'), findsOneWidget);
  });

  testWidgets('the chofer sees one balance: unpaid cortes plus this week', (tester) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(430, 2400);
    addTearDown(tester.view.reset);

    final backend = DemoBackend(dispatchDelay: const Duration(milliseconds: 20))
      ..seed();
    addTearDown(backend.dispose);

    final driverId = (await tester.runAsync(() => _aWeek(backend)))!;
    backend.currentUserId = driverId;
    // The cash is in hand, so the chofer is free and on the home screen.
    final cash = backend.allServices.singleWhere(
      (s) => s.driverId == driverId && s.status == ServiceStatus.completed,
    );
    backend.confirmCashCollected(cash.id, driverId, 400000);

    await tester.pumpWidget(harness(backend));
    await tester.pump();
    await signIn(tester);
    expect(router(tester).state.matchedLocation, Routes.home);

    // On the home screen, one tap from the cortes.
    final pill = find.byKey(const Key('home-balance'));
    expect(pill, findsOneWidget);
    expect(
      find.descendant(of: pill, matching: find.text('Titan te debe ${95000.formatDOP}')),
      findsOneWidget,
    );

    unawaited(router(tester).push(Routes.earnings));
    await frames(tester);
    final balance = find.byKey(const Key('driver-balance'));
    expect(
      find.descendant(of: balance, matching: find.text('Titan te debe ${95000.formatDOP}')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: balance, matching: find.text('+${95000.formatDOP}')),
      findsOneWidget,
      reason: 'all of it is this week so far',
    );

    // Friday: the corte is made and not yet paid. Still owed, now as a corte.
    backend.generateDriverSettlements(driverId: driverId, actorId: 'admin');
    await frames(tester);
    expect(
      find.descendant(of: balance, matching: find.text('Titan te debe ${95000.formatDOP}')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: balance, matching: find.text('Cortes pendientes de pago (1)')),
      findsOneWidget,
    );
    expect(find.descendant(of: balance, matching: find.text('Próximo pago')), findsOneWidget);

    // Paid: nothing is owed either way.
    final id = backend.driverSettlements(driverId: driverId).single.id;
    backend.settleDriverSettlement(id, reference: 'BPD-778812');
    await frames(tester);
    expect(
      find.descendant(of: balance, matching: find.text('Estás al día con Titan')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('open-settlements')));
    await frames(tester);
    expect(find.text('Mis cortes'), findsOneWidget);
    expect(find.byKey(const Key('driver-balance')), findsOneWidget);

    router(tester).go(Routes.home);
    await frames(tester);
    expect(find.byKey(const Key('home-balance')), findsNothing);
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
/// cash job of RD$4,000 (RD$800 to Titan) — for the same chofer.
///
/// The insurer job goes first: it closes as soon as it is done, while a cash
/// job keeps its chofer busy until the cash is confirmed.
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
  if (driverId != null && cash.driverId != driverId) {
    throw StateError('The cash job went to ${cash.driverId}, not $driverId');
  }
  _finish(backend, cash);
  return cash.driverId!;
}

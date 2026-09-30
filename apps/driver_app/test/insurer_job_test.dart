import 'dart:async';

import 'package:clock/clock.dart';
import 'package:driver_app/app.dart';
import 'package:driver_app/features/home/location_publisher.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';
import 'package:grua_testing/grua_testing.dart';
import 'package:intl/date_symbol_data_local.dart';

/// A tow an insurance company ordered, from the chofer's side.
///
/// What changes for the chofer: they see what they earn, they are told not to
/// charge the person at the roadside, they phone the insured rather than
/// chatting with an app nobody has, and the job closes by itself when it is
/// done — there is no cash to confirm.
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

  Widget harness(DemoBackend backend, {Stream<Offer?>? offers}) =>
      ProviderScope(
        overrides: [
          appConfigProvider.overrideWithValue(config),
          ...demoOverrides(backend: backend, role: UserRole.driver),
          locationPublisherProvider.overrideWith((ref) => null),
          if (offers != null)
            incomingOfferProvider.overrideWith((ref) => offers),
        ],
        child: const DriverApp(),
      );

  Future<void> frames(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> signIn(WidgetTester tester) async {
    await tester.enterText(
      find.byType(TextFormField).first,
      'driver1@gruasrd.do',
    );
    await tester.enterText(find.byType(TextFormField).last, 'secret123');
    await tester.pump();
    await tester.tap(find.text('ENTRAR'));
    await frames(tester);
  }

  testWidgets('the job screen shows the earnings and says not to charge',
      (tester) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(430, 1400);
    addTearDown(tester.view.reset);

    final backend = DemoBackend(dispatchDelay: const Duration(milliseconds: 20))
      ..seed();
    addTearDown(backend.dispose);

    final service =
        (await tester.runAsync(() => _dispatchedInsurerService(backend)))!;
    backend.currentUserId = service.driverId!;

    await tester.pumpWidget(harness(backend));
    await tester.pump();
    await signIn(tester);

    expect(find.text('EN SERVICIO'), findsOneWidget);

    // What the chofer takes home: 70% of RD$ 2,500.
    final earnings = find.byKey(const Key('job-earnings'));
    await tester.ensureVisible(earnings);
    expect(earnings, findsOneWidget);
    expect(
      find.descendant(of: earnings, matching: find.text('Ganancia por este servicio')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: earnings, matching: find.text(175000.formatDOP)),
      findsOneWidget,
    );

    // Nobody pays at the roadside, and the insurer's total is not the
    // chofer's business.
    expect(find.byKey(const Key('job-billed-to-insurer')), findsOneWidget);
    expect(find.textContaining('no cobres al cliente'), findsOneWidget);
    expect(find.text('Cobrar en efectivo'), findsNothing);
    expect(find.text(295000.formatDOP), findsNothing);

    // The claim, for the taller.
    expect(find.text('Siniestro SIN-2024-01489'), findsOneWidget);

    // The insured has no app: a phone call, not a chat or an in-app call.
    expect(find.byKey(const Key('insured-call')), findsOneWidget);
    expect(find.byKey(const Key('client-chat')), findsNothing);
    expect(find.byKey(const Key('client-call')), findsNothing);
    expect(find.byKey(const Key('client-video-call')), findsNothing);
    expect(find.text('Asegurado de Seguros Demo'), findsOneWidget);
  });

  testWidgets('an incoming insurer offer shows what the chofer earns',
      (tester) async {
    final backend = DemoBackend()
      ..seed()
      ..currentUserId = 'driver-1';
    final offers = StreamController<Offer?>();
    addTearDown(offers.close);

    await tester.pumpWidget(harness(backend, offers: offers.stream));
    await tester.pump();
    await signIn(tester);

    offers.add(
      Offer(
        serviceId: 'svc-insurer',
        driverId: 'driver-1',
        serviceCode: 'GR-260916-0001',
        pickupAddress: 'Av. 27 de Febrero',
        pickupGeo: DoLocations.santoDomingo,
        paymentMethod: PaymentMethod.insurer,
        netEarningsCents: 175000,
        grossCents: 250000,
        distanceMeters: 1200,
        etaSeconds: 180,
        expiresAt: clock.now().toUtc().add(const Duration(seconds: 25)),
      ),
    );
    await frames(tester);

    expect(find.text('NUEVA SOLICITUD'), findsOneWidget);
    expect(find.text(175000.formatDOP), findsOneWidget);
    expect(
      find.text('Ganancia por este servicio · Aseguradora'),
      findsOneWidget,
    );
  });

  test('an insurer job closes by itself and pays the chofer 70%', () async {
    final backend = DemoBackend(dispatchDelay: const Duration(milliseconds: 20))
      ..seed();
    addTearDown(backend.dispose);
    final container = ProviderContainer(
      overrides: demoOverrides(backend: backend, role: UserRole.driver),
    );
    addTearDown(container.dispose);

    final service = await _dispatchedInsurerService(backend);
    final driverId = service.driverId!;
    backend.currentUserId = driverId;

    expect(service.clientId, isEmpty);
    expect(service.isInsurerJob, isTrue);
    expect(service.canChat, isFalse);
    expect(service.billing?.subtotalCents, 250000);
    expect(service.quote.totalCents, 295000);

    final offer = await container
        .read(offerRepositoryProvider)
        .watchOffer(service.id, driverId)
        .first;
    expect(offer?.netEarningsCents, 175000);
    expect(offer?.paymentMethod, PaymentMethod.insurer);

    final gateway = container.read(functionsGatewayProvider);
    expect(
      (await gateway.markArrived(serviceId: service.id, position: _pickup.geo))
          .isOk,
      isTrue,
    );
    expect(
      (await gateway.startService(serviceId: service.id, photoPaths: const []))
          .isOk,
      isTrue,
    );
    expect(
      (await gateway.completeService(
        serviceId: service.id,
        position: _dropoff.geo,
        photoPaths: const [],
      ))
          .isOk,
      isTrue,
    );

    // Closed without a "cobrado", waiting for the month's invoice.
    final done = backend.service(service.id)!;
    expect(done.status, ServiceStatus.closed);
    expect(done.payment.status, PaymentStatus.toInvoice);
    expect(backend.driver(driverId)?.currentServiceId, isNull);

    final entry =
        backend.earningEntries(driverId).firstWhere((e) => e.serviceId == service.id);
    expect(entry.grossCents, 250000);
    expect(entry.netCents, 175000);
    expect(entry.commissionCents, 75000);
    // The office owes the chofer, not the other way round.
    expect(entry.driverOwesCompany, isFalse);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('a company with its own rate pays that share', () async {
    final backend = DemoBackend(dispatchDelay: const Duration(milliseconds: 20))
      ..seed()
      ..setInsurerPayoutBps('ins-demo', 6500);
    addTearDown(backend.dispose);

    final service = await _dispatchedInsurerService(backend);
    final offer = await DemoOfferRepository(backend)
        .watchOffer(service.id, service.driverId!)
        .first;
    expect(offer?.netEarningsCents, 162500);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('a customer job still pays the chofer 80%', () async {
    final backend = DemoBackend(dispatchDelay: const Duration(milliseconds: 20))
      ..seed();
    addTearDown(backend.dispose);

    final created = backend.createService(
      clientId: 'demo-client-1',
      pickup: _pickup,
      dropoff: _dropoff,
      vehicle: const ServiceVehicle(condition: VehicleCondition.noArranca),
      truckType: TruckType.gancho,
      quote: const Quote(totalCents: 400000),
      route: const ServiceRoute(distanceMeters: 1200),
    );
    final service = await _waitForDriver(backend, created.id);
    final offer = await DemoOfferRepository(backend)
        .watchOffer(service.id, service.driverId!)
        .first;
    expect(offer?.netEarningsCents, 320000);
    expect(offer?.paymentMethod, PaymentMethod.cash);
  }, timeout: const Timeout(Duration(seconds: 30)));
}

const _pickup = ServiceLocation(
  geo: DoLocations.santoDomingo,
  address: 'Av. 27 de Febrero',
);

/// About a kilometre away: the 0–10 km zone, RD$ 2,500 for a car.
final _dropoff = ServiceLocation(
  geo: LatLng(
    DoLocations.santoDomingo.latitude + 0.008,
    DoLocations.santoDomingo.longitude,
  ),
  address: 'Taller Autocentro',
);

Future<Service> _dispatchedInsurerService(DemoBackend backend) async {
  final created = backend.createInsurerService(
    insurerId: 'ins-demo',
    insurerName: 'Seguros Demo',
    requestedBy: 'op-demo',
    pickup: _pickup,
    dropoff: _dropoff,
    vehicle: const ServiceVehicle(
      make: 'Toyota',
      model: 'Corolla',
      plate: 'G123456',
      color: 'Azul',
    ),
    insurance: const InsuranceClaim(
      claimNumber: 'SIN-2024-01489',
      policyNumber: 'POL-5789023-DR',
      insuredName: 'Juan Carlos Pérez',
      insuredPhone: '+18095550123',
    ),
  );
  return await _waitForDriver(backend, created.id);
}

Future<Service> _waitForDriver(DemoBackend backend, String id) async {
  for (var i = 0; i < 100; i++) {
    final service = backend.service(id);
    if (service?.driverId != null) return service!;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  throw StateError('Nobody took $id');
}

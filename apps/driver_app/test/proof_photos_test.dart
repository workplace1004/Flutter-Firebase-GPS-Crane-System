import 'dart:convert';
import 'dart:typed_data';

import 'package:driver_app/app.dart';
import 'package:driver_app/features/home/location_publisher.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';
import 'package:grua_testing/grua_testing.dart';
import 'package:intl/date_symbol_data_local.dart';

/// The chofer's photos of the vehicle at pickup: the record of its condition
/// when it changed hands.
///
/// The bug this pins down: "Iniciar servicio" sent two made-up names instead
/// of photos, so a finished tow carried no evidence of anything.
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

  final sources = <PhotoSource>[];

  Widget harness(DemoBackend backend) => ProviderScope(
    overrides: [
      appConfigProvider.overrideWithValue(config),
      ...demoOverrides(backend: backend, role: UserRole.driver),
      locationPublisherProvider.overrideWith((ref) => null),
      photoPickerProvider.overrideWithValue((source) async {
        sources.add(source);
        return PickedPhoto(name: 'frente.png', bytes: _png);
      }),
    ],
    child: const DriverApp(),
  );

  Future<void> frames(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Signs in as the chofer holding a job they have just arrived at.
  Future<Service> arrived(WidgetTester tester, DemoBackend backend) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(430, 1400);
    addTearDown(tester.view.reset);

    final service = (await tester.runAsync(() => _dispatched(backend)))!;
    final driverId = service.driverId!;
    backend
      ..currentUserId = driverId
      ..transition(
        service.id,
        ServiceStatus.accepted,
        ServiceEventName.acceptService,
        driverId,
        UserRole.driver,
      )
      ..transition(
        service.id,
        ServiceStatus.arrived,
        ServiceEventName.markArrived,
        driverId,
        UserRole.driver,
      );

    await tester.pumpWidget(harness(backend));
    await tester.pump();
    await tester.enterText(
      find.byType(TextFormField).first,
      'driver1@gruasrd.do',
    );
    await tester.enterText(find.byType(TextFormField).last, 'secret123');
    await tester.pump();
    await tester.tap(find.text('ENTRAR'));
    await frames(tester);

    final start = find.widgetWithText(ElevatedButton, 'INICIAR SERVICIO');
    await tester.ensureVisible(start);
    await tester.tap(start);
    await frames(tester);
    return service;
  }

  setUp(sources.clear);

  testWidgets('the vehicle is photographed before it is loaded', (
    tester,
  ) async {
    final backend = DemoBackend(dispatchDelay: const Duration(milliseconds: 20))
      ..seed();
    addTearDown(backend.dispose);

    final service = await arrived(tester, backend);

    // Nothing moves until there is at least one photo.
    expect(find.byKey(const Key('proof-photos-pickup')), findsOneWidget);
    final submit = find.byKey(const Key('proof-photos-submit'));
    expect(tester.widget<ElevatedButton>(submit).onPressed, isNull);

    await tester.tap(find.byKey(const Key('proof-photo-add')));
    await frames(tester);
    await tester.tap(find.byKey(const Key('proof-photo-add')));
    await frames(tester);
    expect(find.byKey(const Key('proof-photo-1')), findsOneWidget);
    // From the camera, never the gallery: an old photo proves nothing.
    expect(sources, [PhotoSource.camera, PhotoSource.camera]);

    await tester.tap(submit);
    await frames(tester);

    final started = backend.service(service.id)!;
    expect(started.status, ServiceStatus.inProgress);
    expect(started.pickupPhotoPaths, hasLength(2));
    for (final path in started.pickupPhotoPaths) {
      expect(path, startsWith('service_photos/${service.id}/pickup_'));
      // What was filed is what the office can open.
      expect(backend.uploadUrl(path), startsWith('data:image/png'));
    }

    // Loading the vehicle sets the simulated truck driving; stop it before
    // the test ends rather than leave its timer running.
    await tester.pumpWidget(const SizedBox.shrink());
    backend.dispose();
  });

  testWidgets('backing out of the photos leaves the job where it was', (
    tester,
  ) async {
    final backend = DemoBackend(dispatchDelay: const Duration(milliseconds: 20))
      ..seed();
    addTearDown(backend.dispose);

    final service = await arrived(tester, backend);

    await tester.tap(find.text('Todavía no'));
    await frames(tester);

    expect(find.byKey(const Key('proof-photos-pickup')), findsNothing);
    final unchanged = backend.service(service.id)!;
    expect(unchanged.status, ServiceStatus.arrived);
    expect(unchanged.pickupPhotoPaths, isEmpty);
  });
}

/// A real one-pixel PNG, so the thumbnail decodes.
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==',
);

Future<Service> _dispatched(DemoBackend backend) async {
  final created = backend.createInsurerService(
    insurerId: 'ins-demo',
    insurerName: 'Seguros Demo',
    requestedBy: 'op-demo',
    pickup: const ServiceLocation(
      geo: DoLocations.santoDomingo,
      address: 'Av. 27 de Febrero',
    ),
    dropoff: ServiceLocation(
      geo: LatLng(
        DoLocations.santoDomingo.latitude + 0.008,
        DoLocations.santoDomingo.longitude,
      ),
      address: 'Taller Autocentro',
    ),
    vehicle: const ServiceVehicle(make: 'Toyota', model: 'Corolla'),
    insurance: const InsuranceClaim(claimNumber: 'SIN-1'),
  );
  for (var i = 0; i < 100; i++) {
    final service = backend.service(created.id);
    if (service?.driverId != null) return service!;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  throw StateError('Nobody took ${created.id}');
}

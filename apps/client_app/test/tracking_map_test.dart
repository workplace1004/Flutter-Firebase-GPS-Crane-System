import 'package:client_app/features/tracking/tracking_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';
import 'package:grua_testing/grua_testing.dart';
import 'package:intl/date_symbol_data_local.dart';

/// The map the customer watches while they wait.
///
/// The bug this pins down: the camera follows the truck, so the map was built
/// `interactive: false` to stop the two fighting. That took the whole map away
/// from somebody sitting on the shoulder who wants to zoom in on the street
/// the grúa is turning into. Following now yields to the customer's own move.
Future<void> main() async {
  setUpAll(() => initializeDateFormatting('es_DO'));

  const pickup = ServiceLocation(
    geo: LatLng(19.1221, -70.6367),
    address: 'Jarabacoa',
    reference: 'Frente al colmado',
  );
  const dropoff = ServiceLocation(
    geo: LatLng(19.1300, -70.6400),
    address: 'Carr. Palo Blanco',
  );

  // The demo backend walks a service through the whole lifecycle on timers.
  // This test is about the map, so the cascade is stopped inside the test body
  // — a tearDown runs too late for the "no pending timers" check.
  late DemoBackend backend;

  Future<void> stopTheClock(WidgetTester tester) async {
    backend.dispose();
    await tester.pump();
  }

  Future<GruaMap> pumpTracking(
    WidgetTester tester, {
    void Function(Service service)? before,
  }) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(430, 900);
    addTearDown(tester.view.reset);

    backend = DemoBackend()..seed();
    final service = backend.createService(
      clientId: 'demo-client-1',
      pickup: pickup,
      dropoff: dropoff,
      vehicle: const ServiceVehicle(make: 'Toyota', model: 'Corolla'),
      truckType: TruckType.gancho,
      quote: const Quote(totalCents: 250000),
      route: const ServiceRoute(distanceMeters: 4200),
    );
    before?.call(service);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appConfigProvider.overrideWithValue(
            const AppConfig(
              flavor: Flavor.dev,
              appKind: AppKind.client,
              firebaseProjectId: 'grua-rd-test',
              googleMapsApiKey: '',
              useEmulators: false,
              emulatorHost: 'localhost',
              functionsRegion: 'us-east1',
            ),
          ),
          ...demoOverrides(backend: backend),
        ],
        child: MaterialApp(
          theme: AppTheme.phone(),
          home: TrackingScreen(serviceId: service.id),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    return tester.widget<GruaMap>(find.byType(GruaMap));
  }

  testWidgets("the chofer's card shows their photo, not a letter", (
    tester,
  ) async {
    // The bug: the card drew the first letter of the chofer's name whatever
    // photo they had, and a chofer assigned by hand had none on the service
    // to draw anyway.
    const photo = 'data:image/png;base64,iVBORw0KGgo=';
    await pumpTracking(
      tester,
      before: (service) {
        final driver = backend.allDrivers.firstWhere(
          (d) => d.truckType == TruckType.gancho && d.status.canWork && !d.isBusy,
        );
        backend
          ..storeUpload('drivers/${driver.id}/photo.png', photo)
          ..setDriverPhoto(driver.id, 'drivers/${driver.id}/photo.png');
        expect(
          backend.assignServiceManually(serviceId: service.id, driverId: driver.id),
          isNull,
        );
      },
    );
    await tester.pump(const Duration(milliseconds: 400));

    final avatar = tester.widget<DriverAvatar>(find.byKey(const Key('driver-photo')));
    expect(avatar.photoUrl, photo);

    await stopTheClock(tester);
  });

  testWidgets('the map takes gestures, and reports the ones it did not make', (
    tester,
  ) async {
    final map = await pumpTracking(tester);

    // The bug: neither of these was true. Panning and pinching were off, and
    // nothing on the screen could tell a customer's move from the camera's.
    expect(map.interactive, isTrue);
    expect(map.onUserMove, isNotNull);

    await stopTheClock(tester);
  });

  testWidgets('while searching, only the tow is drawn — no straight copy', (
    tester,
  ) async {
    // The bug: the red leg is the truck's way to the pickup, and with no truck
    // yet it fell back to pickup → destination. That drew a straight red line
    // right over the tow the map was already drawing along the road.
    final map = await pumpTracking(tester);

    expect(map.route, isEmpty, reason: 'no truck, so no leg to the pickup');
    expect(map.routes, hasLength(1));
    expect(map.routes.single.color, BrandColors.ink);

    await stopTheClock(tester);
  });

  testWidgets('a move by the customer stops the camera chasing the truck', (
    tester,
  ) async {
    var map = await pumpTracking(tester);
    final startedAt = map.center;

    // Nothing to recentre yet: the camera is still the truck's.
    expect(find.byKey(const Key('follow-truck')), findsNothing);

    map.onUserMove!();
    await tester.pump();

    // The customer has the camera: the button to give it back appears, and
    // the centre stops being handed to the map.
    expect(find.byKey(const Key('follow-truck')), findsOneWidget);
    map = tester.widget<GruaMap>(find.byType(GruaMap));
    expect(map.center, startedAt);

    // Handing it back puts the truck in charge again.
    await tester.tap(find.byKey(const Key('follow-truck')));
    await tester.pump();
    expect(find.byKey(const Key('follow-truck')), findsNothing);

    await stopTheClock(tester);
  });
}

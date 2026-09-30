import 'package:client_app/app.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';
import 'package:grua_testing/grua_testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// "Grúas cerca de ti": a real search, on a clock, that the customer can stop,
/// restart and reconfigure.
///
/// The demo fleet is seeded around Santo Domingo — four trucks in the city,
/// one in Santiago and one in Higüey — so the radius genuinely decides who is
/// found.
Future<void> main() async {
  setUpAll(() => initializeDateFormatting('es_DO'));
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const gazcue = LatLng(18.4795, -69.9420);

  Widget harness(DemoBackend backend) => ProviderScope(
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
          myPositionProvider.overrideWith(
            (ref) => Stream.value((position: gazcue, heading: 0)),
          ),
        ],
        child: const ClientApp(),
      );

  /// Frames without settling: the countdown repaints every second for as
  /// long as the search runs.
  Future<void> advance(WidgetTester tester, Duration by) async {
    final steps = by.inMilliseconds ~/ 250;
    for (var i = 0; i < steps; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  Future<DemoBackend> signIn(WidgetTester tester) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(430, 900);
    addTearDown(tester.view.reset);

    final backend = DemoBackend()..seed();
    await tester.pumpWidget(harness(backend));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Entrar con Teléfono'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, '8095551234');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enviar código'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await tester.enterText(find.byType(TextField).first, '123456');
    await advance(tester, const Duration(seconds: 2));
    return backend;
  }

  GruaMap homeMap(WidgetTester tester) => tester.widget<GruaMap>(find.byType(GruaMap));

  Iterable<MapMarker> trucksOn(GruaMap map) =>
      map.markers.where((m) => m.kind == MapMarkerKind.truckIdle);

  /// The shaded area searched. The radar rings travelling across it carry no
  /// fill, which is what tells the two apart.
  MapCircle areaOn(GruaMap map) =>
      map.circles.singleWhere((c) => c.fillOpacity > 0);

  Iterable<MapCircle> ringsOn(GruaMap map) =>
      map.circles.where((c) => c.fillOpacity == 0);

  testWidgets('the search finds the free trucks inside the radius and puts '
      'them on the map', (tester) async {
    await signIn(tester);

    expect(find.textContaining('Buscando…'), findsOneWidget);

    final map = homeMap(tester);
    // The area searched, drawn and framed.
    expect(areaOn(map).center, gazcue);
    expect(areaOn(map).radiusMeters, 5000);
    expect(map.fitTo, isNotEmpty);

    // Found: only the ones really within 5 km of the customer.
    final found = trucksOn(map).toList();
    expect(found, isNotEmpty);
    for (final truck in found) {
      expect(truck.position.distanceTo(gazcue), lessThanOrEqualTo(5200));
    }
    expect(find.text('${found.length} grúas disponibles en 5 km'), findsOneWidget);
  });

  testWidgets('a radar sweeps the area while the search runs, and stops with it',
      (tester) async {
    // A still circle says where the search would look; the rings say it is
    // looking right now.
    await signIn(tester);

    final rings = ringsOn(homeMap(tester)).toList();
    expect(rings, hasLength(3));
    for (final ring in rings) {
      expect(ring.center, gazcue);
      // Inside the area searched, and never a full-screen fill at birth.
      expect(ring.radiusMeters, greaterThan(0));
      expect(ring.radiusMeters, lessThanOrEqualTo(5000));
      expect(ring.strokeOpacity, greaterThanOrEqualTo(0));
    }

    // They travel: a moment later they are somewhere else.
    final before = rings.map((r) => r.radiusMeters).toList();
    await tester.pump(const Duration(milliseconds: 400));
    final after = ringsOn(homeMap(tester)).map((r) => r.radiusMeters).toList();
    expect(after, isNot(before));

    // Stopped, the map goes quiet: the area stays, the rings go.
    await tester.tap(find.byKey(const Key('nearby-trucks-row')));
    await advance(tester, const Duration(seconds: 1));
    expect(ringsOn(homeMap(tester)), isEmpty);
    expect(areaOn(homeMap(tester)).radiusMeters, 5000);
  });

  testWidgets('a truck that comes online mid-search drops onto the map',
      (tester) async {
    // Trucks found at the start have long since landed; one that appears
    // while the customer watches should arrive, not blink into place.
    final backend = await signIn(tester);
    final settled = trucksOn(homeMap(tester)).toList();
    expect(settled, isNotEmpty);
    expect(settled.every((m) => m.arrival == 1), isTrue);

    // A chofer who was out of range drives into it: the next check finds a
    // truck that was not there before.
    final far = backend.allLive.firstWhere(
      (p) => p.position.distanceTo(gazcue) > 5000,
    );
    final spare = backend.driver(far.driverId)!;
    backend
      ..setDriverOnline(spare.id, online: true)
      ..setLive(
        far.copyWith(
          lat: gazcue.latitude + 0.004,
          lng: gazcue.longitude + 0.004,
          isOnline: true,
          state: DriverLiveState.idle,
          updatedAt: clock.now().millisecondsSinceEpoch,
        ),
      );

    // Caught on its way down, between the check that found it and its
    // landing.
    var falling = false;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 200));
      if (trucksOn(homeMap(tester)).length > settled.length) {
        falling = trucksOn(homeMap(tester)).any((m) => m.arrival < 1);
        if (falling) break;
      }
    }
    expect(falling, isTrue, reason: 'the new truck dropped in');

    // And it lands.
    await advance(tester, const Duration(seconds: 1));
    expect(trucksOn(homeMap(tester)).every((m) => m.arrival == 1), isTrue);
  });

  testWidgets('the row counts down in a ring while it looks', (tester) async {
    await signIn(tester);

    final ring = find.byKey(const Key('nearby-countdown-ring'));
    expect(ring, findsOneWidget);
    final full = tester.widget<CircularProgressIndicator>(ring).value!;

    await advance(tester, const Duration(seconds: 6));
    expect(
      tester.widget<CircularProgressIndicator>(ring).value,
      lessThan(full),
    );

    // Not looking, nothing to count.
    await tester.tap(find.byKey(const Key('nearby-trucks-row')));
    await advance(tester, const Duration(seconds: 1));
    expect(find.byKey(const Key('nearby-countdown-ring')), findsNothing);
  });

  testWidgets('tapping stops the search, and tapping again starts it',
      (tester) async {
    await signIn(tester);
    final row = find.byKey(const Key('nearby-trucks-row'));

    await tester.tap(row);
    await advance(tester, const Duration(milliseconds: 500));
    expect(find.text('Buscar de nuevo'), findsOneWidget);
    // What was found stays on the map.
    expect(trucksOn(homeMap(tester)), isNotEmpty);

    await tester.tap(row);
    await advance(tester, const Duration(milliseconds: 500));
    expect(find.textContaining('Buscando…'), findsOneWidget);
  });

  testWidgets('the search ends on its own when its time is up', (tester) async {
    await signIn(tester);
    expect(find.textContaining('Buscando…'), findsOneWidget);

    // 30 s by default.
    await advance(tester, const Duration(seconds: 31));

    expect(find.text('Buscar de nuevo'), findsOneWidget);
  });

  testWidgets('tapping a truck shows it anonymously, and '
      '"Pedir esta grúa" opens the request with that truck first', (tester) async {
    await signIn(tester);

    final truck = trucksOn(homeMap(tester)).first;
    // Tappable, and labelled with nobody's name.
    expect(truck.onTap, isNotNull);
    expect(truck.label, isNull);

    truck.onTap!();
    await advance(tester, const Duration(seconds: 1));
    expect(find.text('Grúa disponible'), findsOneWidget);
    // Truck type and distance, e.g. "Plataforma · a 850 m de ti".
    expect(find.textContaining(' · a '), findsOneWidget);

    await tester.tap(find.byKey(const Key('truck-request')));
    await advance(tester, const Duration(seconds: 1));

    // The request form, carrying the choice.
    expect(find.text('Detalles del vehículo'), findsOneWidget);
    expect(find.byKey(const Key('preferred-truck-notice')), findsOneWidget);
  });

  testWidgets('"Chatear" asks that truck\'s chofer to talk, and the '
      'conversation opens when they accept', (tester) async {
    final backend = await signIn(tester);

    trucksOn(homeMap(tester)).first.onTap!();
    await advance(tester, const Duration(seconds: 1));

    await tester.tap(find.byKey(const Key('truck-chat')));
    await advance(tester, const Duration(seconds: 1));

    // A request went to that truck's chofer, and the customer waits for it.
    final request = backend.allChatRequests.single;
    expect(request.clientId, 'demo-client-1');
    expect(request.status, ChatRequestStatus.pending);
    expect(find.byKey(const Key('chat-request-waiting')), findsOneWidget);
    // Nobody's name until the chofer answers.
    expect(find.text('Chofer de la grúa'), findsOneWidget);

    backend.respondChatRequest(request.id, request.driverId, accept: true);
    await advance(tester, const Duration(seconds: 1));

    expect(find.byKey(const Key('chat-request-waiting')), findsNothing);
    expect(find.text('Escribe un mensaje…'), findsOneWidget);
    expect(find.text(backend.chatRequest(request.id)!.driverName), findsOneWidget);

    await tester.enterText(
      find.byType(TextField).last,
      '¿Cuánto cuesta el servicio?',
    );
    await tester.tap(find.byIcon(Icons.send));
    await advance(tester, const Duration(seconds: 1));
    final sent =
        (await tester.runAsync(() => backend.chatRequestMessagesFor(request.id).first))!;
    expect(sent.single.text, '¿Cuánto cuesta el servicio?');
    expect(sent.single.senderRole, UserRole.client);
  });

  testWidgets('the gear sets radius and duration, and searches again with them',
      (tester) async {
    await signIn(tester);

    await tester.tap(find.byTooltip('Ajustes de búsqueda'));
    await advance(tester, const Duration(seconds: 1));
    expect(find.text('Ajustes de búsqueda'), findsOneWidget);

    // Widest radius, shortest duration.
    await tester.drag(find.byKey(const Key('radius-slider')), const Offset(400, 0));
    await tester.drag(find.byKey(const Key('duration-slider')), const Offset(-400, 0));
    await tester.pump();
    expect(find.text('400 km'), findsOneWidget);
    expect(find.text('10 s'), findsOneWidget);

    await tester.tap(find.text('Guardar'));
    await advance(tester, const Duration(seconds: 1));

    expect(areaOn(homeMap(tester)).radiusMeters, 400000);
    expect(find.textContaining('Buscando…'), findsOneWidget);
    // …and the new, shorter duration ends it.
    await advance(tester, const Duration(seconds: 11));
    expect(find.text('Buscar de nuevo'), findsOneWidget);

    // Remembered on the device.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('nearby.radiusKm'), 400);
    expect(prefs.getInt('nearby.durationSeconds'), 10);
  });
}

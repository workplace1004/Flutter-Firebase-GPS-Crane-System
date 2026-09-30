import 'dart:async';

import 'package:client_app/app.dart';
import 'package:client_app/features/request/request_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:grua_core/grua_core.dart';
import 'package:grua_testing/grua_testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The pickup point on the request form.
///
/// The bug this pins down: the row waited for a fresh `getCurrentPosition`
/// plus a reverse geocode — ten seconds on a phone indoors, longer in a
/// browser — and said "Obteniendo tu ubicación…" for all of it, while the
/// home map behind it already had a fix in memory.
Future<void> main() async {
  setUpAll(() => initializeDateFormatting('es_DO'));
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const gazcue = LatLng(18.4795, -69.9420);

  Widget harness(DemoBackend backend, LocationService location) => ProviderScope(
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
      // The home map's stream, as it stands by the time anybody taps PEDIR
      // GRÚA.
      myPositionProvider.overrideWith(
        (ref) => Stream.value((position: gazcue, heading: 0)),
      ),
      // …and a phone whose own fix never comes back.
      locationServiceProvider.overrideWithValue(location),
    ],
    child: const ClientApp(),
  );

  Future<void> advance(WidgetTester tester, Duration by) async {
    final steps = by.inMilliseconds ~/ 250;
    for (var i = 0; i < steps; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  Future<void> signIn(WidgetTester tester, {LocationService? location}) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(430, 900);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      harness(DemoBackend()..seed(), location ?? _NeverAnswers()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Entrar con Teléfono'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, '8095551234');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enviar código'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await tester.enterText(find.byType(TextField).first, '123456');
    await advance(tester, const Duration(seconds: 2));
  }

  testWidgets('the pickup is taken from the fix the app already has', (
    tester,
  ) async {
    await signIn(tester);

    await tester.tap(find.text('PEDIR GRÚA 24/7'));
    await advance(tester, const Duration(seconds: 1));

    await tester.scrollUntilVisible(
      find.text('PUNTO DE RECOGIDA'),
      300,
      scrollable: find
          .descendant(
            of: find.byType(ListView).first,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await advance(tester, const Duration(seconds: 1));

    // No spinner, and the street the point names — not a placeholder, and
    // not the centre of Santo Domingo.
    expect(find.text('Ubicación en el mapa'), findsNothing);
    expect(find.text('Obteniendo tu ubicación…'), findsNothing);
    expect(find.text('Tu ubicación actual'), findsNothing);
    expect(find.text('C/ Santiago 15, Gazcue'), findsOneWidget);

    // And it is a real pickup: the form can be priced with it.
    final container = ProviderScope.containerOf(
      tester.element(find.text('C/ Santiago 15, Gazcue')),
    );
    final pickup = container.read(requestControllerProvider).pickup;
    expect(pickup, isNotNull);
    expect(pickup!.geo.latitude, closeTo(gazcue.latitude, 0.0001));
    expect(pickup.address, 'C/ Santiago 15, Gazcue');
  });
  testWidgets('a point nothing can name shows its own coordinates', (
    tester,
  ) async {
    await signIn(tester, location: _NeverAnswers(address: ''));

    await tester.tap(find.text('PEDIR GRÚA 24/7'));
    await advance(tester, const Duration(seconds: 1));

    await tester.scrollUntilVisible(
      find.text('PUNTO DE RECOGIDA'),
      300,
      scrollable: find
          .descendant(
            of: find.byType(ListView).first,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await advance(tester, const Duration(seconds: 1));

    // No geocoder anywhere, so the exact point is the answer — not a
    // placeholder, and not a spinner that never stops.
    expect(find.text('18.47950, -69.94200'), findsOneWidget);
    expect(find.text('Obteniendo tu ubicación…'), findsNothing);
  });

  testWidgets('heavy vehicles have their own section, and say the operator '
      'confirms', (tester) async {
    await signIn(tester);
    await tester.tap(find.text('PEDIR GRÚA 24/7'));
    await advance(tester, const Duration(seconds: 1));

    // The light vehicles the tariff names, then the heavy ones under their
    // own heading.
    for (final label in ['Carro', 'Jeepeta', 'Camioneta']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('VEHÍCULOS PESADOS'), findsOneWidget);
    expect(find.byKey(const Key('heavy-notice')), findsNothing);

    await tester.tap(find.text('Patana / Tráiler'));
    await advance(tester, const Duration(milliseconds: 500));

    expect(find.text(heavyServiceNotice), findsOneWidget);
    final container = ProviderScope.containerOf(
      tester.element(find.text('VEHÍCULOS PESADOS')),
    );
    final draft = container.read(requestControllerProvider);
    expect(draft.vehicle.type, VehicleType.patana);
    expect(draft.truckType, TruckType.pesada);

    // Back to a light vehicle, and the warning goes with it.
    await tester.tap(find.text('Jeepeta'));
    await advance(tester, const Duration(milliseconds: 500));
    expect(find.text(heavyServiceNotice), findsNothing);
  });
}

/// A phone that cannot say where it is: permission granted, no fix ever. The
/// live stream is overridden separately, so this only stands in for the slow
/// path the row used to wait on.
class _NeverAnswers extends LocationService {
  _NeverAnswers({this.address = 'C/ Santiago 15, Gazcue'});

  /// What its geocoder gives back for any point. Empty stands for the web
  /// without a Maps script, or a key without the Geocoding API.
  final String address;

  @override
  Future<LocationBlocker> check({bool requireAlways = false}) async =>
      LocationBlocker.none;

  @override
  Future<LocationBlocker> request({bool requireAlways = false}) async =>
      LocationBlocker.none;

  @override
  Future<Result<ResolvedPlace>> currentPlace({
    Duration timeout = const Duration(seconds: 10),
    bool geocode = true,
  }) => Completer<Result<ResolvedPlace>>().future;

  @override
  Future<Position?> currentPosition({
    Duration timeout = const Duration(seconds: 10),
  }) => Completer<Position?>().future;

  @override
  Stream<Position> watchPosition({
    int distanceFilter = 25,
    bool background = false,
  }) => const Stream.empty();

  @override
  Future<ResolvedPlace> describe(LatLng point) async => ResolvedPlace(
    position: point,
    address: address,
    locality: address.isEmpty ? '' : 'Santo Domingo',
  );
}

import 'package:client_app/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';
import 'package:grua_testing/grua_testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Marking a point on the map, from the request form.
///
/// The bug this pins down: the map sat in a Stack whose only unpositioned
/// child was the 44-pixel centre pin, so the Stack took the pin's width and
/// the map came out as a thin strip down the middle of the screen with grey
/// either side.
Future<void> main() async {
  setUpAll(() => initializeDateFormatting('es_DO'));
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const gazcue = LatLng(18.4795, -69.9420);
  const phone = Size(430, 900);

  Widget harness(DemoBackend backend, {LocationService? location}) =>
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
      myPositionProvider.overrideWith(
        (ref) => Stream.value((position: gazcue, heading: 0)),
      ),
      // No GPS and no geocoder in a widget test; the picker asks for both the
      // moment it opens.
      locationServiceProvider.overrideWithValue(location ?? _FakeLocation()),
      // No network either: the suggestions come from here.
      placesServiceProvider.overrideWithValue(_FakePlaces()),
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
      ..physicalSize = phone;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      harness(DemoBackend()..seed(), location: location),
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

  /// Opens the request form and taps one of its two location fields.
  Future<void> openPicker(WidgetTester tester, String label) async {
    await tester.tap(find.text('PEDIR GRÚA 24/7'));
    await advance(tester, const Duration(seconds: 1));

    // The two fields are near the bottom of a long form, and a list that
    // long has not built them yet.
    await tester.scrollUntilVisible(
      find.text(label),
      300,
      // The form's own list, not the chip rows scrolling inside it.
      scrollable: find
          .descendant(
            of: find.byType(ListView).first,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await advance(tester, const Duration(seconds: 1));
  }

  /// What the map actually occupies once the picker is open.
  void expectMapFillsWidth(WidgetTester tester) {
    final map = tester.getRect(find.byType(GruaMap));
    expect(map.left, 0);
    expect(map.width, phone.width);
    // And it is the map, not a sliver of one.
    expect(map.height, greaterThan(200));
  }

  testWidgets("the pickup is the phone's own position, and is not a button", (
    tester,
  ) async {
    await signIn(tester);

    // Reaching the field is the same journey; what it does when tapped is
    // what changed.
    await openPicker(tester, 'PUNTO DE RECOGIDA');

    // No picker opened: the form is still the form.
    expect(find.text('CONFIRMAR UBICACIÓN'), findsNothing);
    expect(find.text('PUNTO DE RECOGIDA'), findsOneWidget);

    // And it says where the phone is, geocoded — not a hardcoded avenue.
    expect(find.text('Av. 27 de Febrero, Santo Domingo'), findsOneWidget);

    // No landmark field: the pickup row is the whole of it now.
    expect(find.byKey(const Key('pickup-reference')), findsNothing);
    expect(find.text('Referencia del punto de recogida'), findsNothing);
  });

  testWidgets('the destination picker shows a full-width map', (tester) async {
    await signIn(tester);
    await openPicker(tester, 'DESTINO');

    expect(find.text('¿A dónde la llevamos?'), findsWidgets);
    expect(find.text('CONFIRMAR UBICACIÓN'), findsOneWidget);
    expectMapFillsWidth(tester);
  });


  testWidgets('the destination picker opens on the position already known', (
    tester,
  ) async {
    await signIn(tester);
    await openPicker(tester, 'DESTINO');

    // Not the centre of Santo Domingo, which is where it used to start before
    // a fresh fix arrived seconds later: the home map's position is already
    // paid for, so the map opens there.
    final map = tester.widget<GruaMap>(find.byType(GruaMap));
    expect(map.center.latitude, closeTo(gazcue.latitude, 0.0001));
    expect(map.center.longitude, closeTo(gazcue.longitude, 0.0001));
  });

  testWidgets('a phone that cannot locate itself stops the spinner', (
    tester,
  ) async {
    // The bug: the picker asks for a fix the moment it opens, and every path
    // that stopped its spinner was a happy one. On the web the fallback to a
    // last known position throws `UnsupportedError` — an `Error`, so the
    // service's `on Exception` never saw it — and the button span until the
    // screen was closed, over a map the customer could otherwise have used.
    await signIn(tester, location: _BrokenLocation());
    await openPicker(tester, 'DESTINO');
    await advance(tester, const Duration(seconds: 3));

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byIcon(Icons.pin_drop_outlined), findsOneWidget);

    // And it says so, rather than failing silently.
    expect(find.textContaining('Márcala en el mapa'), findsOneWidget);

    // The map still works: the point is confirmable by hand.
    expectMapFillsWidth(tester);
    expect(find.text('CONFIRMAR UBICACIÓN'), findsOneWidget);
  });

  testWidgets('moving the map costs nothing; the pin button names the point', (
    tester,
  ) async {
    // The bug: every pause of the camera reverse-geocoded, so dragging across
    // town billed a lookup per street it rested on and rewrote the field under
    // the customer — usually with a Plus Code, which is what Google answers
    // for a corner with no number. Naming a point is now one deliberate tap.
    final phone = _CountingLocation();
    await signIn(tester, location: phone);
    await openPicker(tester, 'DESTINO');

    // Opening the picker moves the map to where the phone is. That is a
    // camera move, not a question about an address, and the field stays as
    // the customer found it.
    expect(find.text('Escribe, elige un lugar o usa el pin del mapa'),
        findsOneWidget);

    // The form behind the picker names its own pickup; what this test is
    // about is what the picker asks for from here on.
    phone.described.clear();

    Future<void> panTo(LatLng point) async {
      tester.widget<GruaMap>(find.byType(GruaMap)).onCameraIdle!(point);
      await advance(tester, const Duration(seconds: 1));
    }

    // Three stops on the way somewhere, the way a real drag lands.
    await panTo(const LatLng(19.1180, -70.6320));
    await panTo(const LatLng(19.1200, -70.6340));
    await panTo(const LatLng(19.1221, -70.6367));

    expect(phone.described, isEmpty);
    expect(find.text(_CountingLocation.name), findsNothing);

    // The tap is what asks.
    await tester.tap(find.byKey(const Key('name-this-point')));
    await advance(tester, const Duration(seconds: 1));

    expect(phone.described, hasLength(1));
    expect(phone.described.single.latitude, closeTo(19.1221, 0.0001));
    expect(find.text(_CountingLocation.name), findsOneWidget);

    // Pan off it and the address on screen no longer describes the pin, so it
    // says so rather than letting the wrong one be confirmed.
    expect(find.textContaining('Moviste el mapa'), findsNothing);
    await panTo(const LatLng(19.1300, -70.6400));
    expect(find.textContaining('Moviste el mapa'), findsOneWidget);
    expect(phone.described, hasLength(1));
  });

  testWidgets('typing a destination offers matches above the field', (
    tester,
  ) async {
    await signIn(tester);
    await openPicker(tester, 'DESTINO');

    // Nothing is offered for a single letter: it would match half the country.
    await tester.enterText(find.byKey(const Key('address-field')), 'W');
    await advance(tester, const Duration(milliseconds: 400));
    expect(find.byKey(const Key('address-suggestions')), findsNothing);

    await tester.enterText(find.byKey(const Key('address-field')), 'Winston');
    await advance(tester, const Duration(milliseconds: 400));

    // The list is there, and it sits above the field it belongs to.
    expect(find.byKey(const Key('address-suggestions')), findsOneWidget);
    expect(find.text('Av. Winston Churchill'), findsOneWidget);
    expect(find.text('Plaza Central'), findsOneWidget);
    expect(
      tester.getRect(find.byKey(const Key('address-suggestions'))).bottom,
      lessThanOrEqualTo(
        tester.getRect(find.byKey(const Key('address-field'))).top,
      ),
    );

    // Choosing one names the place, moves the map to it, and closes the list.
    await tester.tap(find.text('Av. Winston Churchill'));
    await advance(tester, const Duration(seconds: 1));

    expect(find.byKey(const Key('address-suggestions')), findsNothing);
    expect(find.text('Av. Winston Churchill, Piantini'), findsOneWidget);
    final map = tester.widget<GruaMap>(find.byType(GruaMap));
    expect(map.center.latitude, closeTo(18.4861, 0.0001));

    // And that is what the form gets back.
    await tester.tap(find.text('CONFIRMAR UBICACIÓN'));
    await advance(tester, const Duration(seconds: 1));
    expect(find.text('Av. Winston Churchill, Piantini'), findsWidgets);
  });
}

/// A phone that counts the reverse geocodes asked of it.
///
/// [described] is cleared once the picker is open: the form behind it names
/// its own pickup, and counting that would say nothing about what moving the
/// map costs.
class _CountingLocation extends LocationService {
  static const name = 'C/ Duarte 42, Jarabacoa';

  final described = <LatLng>[];

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
  }) async => const Result.ok(
        ResolvedPlace(position: LatLng(18.4795, -69.9420), address: name),
      );

  @override
  Future<ResolvedPlace> describe(LatLng point) async {
    described.add(point);
    return const ResolvedPlace(
      position: LatLng(19.1221, -70.6367),
      address: name,
    );
  }
}

/// A phone whose platform throws an `Error` rather than answering — the web,
/// where `getLastKnownPosition` and the settings screens are all unsupported.
class _BrokenLocation extends LocationService {
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
  }) async =>
      throw UnsupportedError('getLastKnownPosition is not supported here');

  @override
  Future<ResolvedPlace> describe(LatLng point) async =>
      ResolvedPlace(position: point);
}

/// Suggestions without a network: the same two answers for anything typed.
class _FakePlaces extends PlacesService {
  _FakePlaces() : super(apiKey: 'test-key');

  @override
  Future<List<PlaceSuggestion>> suggest(
    String input, {
    LatLng? near,
    double radiusKm = 50,
  }) async {
    if (input.trim().length < 2) return const [];
    return const [
      PlaceSuggestion(
        placeId: 'place-1',
        title: 'Av. Winston Churchill',
        subtitle: 'Piantini, Santo Domingo',
      ),
      PlaceSuggestion(
        placeId: 'place-2',
        title: 'Plaza Central',
        subtitle: 'Av. 27 de Febrero, Santo Domingo',
      ),
    ];
  }

  @override
  Future<ResolvedPlace?> details(String placeId) async => const ResolvedPlace(
    position: LatLng(18.4861, -69.9312),
    address: 'Av. Winston Churchill, Piantini',
  );
}

/// A phone that knows where it is and can name the place, so the picker gets
/// past its first frame without a platform channel.
class _FakeLocation extends LocationService {
  static const _here = LatLng(18.4795, -69.9420);
  static const _place = ResolvedPlace(
    position: _here,
    address: 'Av. 27 de Febrero, Santo Domingo',
  );

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
  }) async => const Result.ok(_place);

  @override
  Future<ResolvedPlace> describe(LatLng point) async => _place;
}

import 'package:client_app/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';
import 'package:grua_testing/grua_testing.dart';
import 'package:intl/date_symbol_data_local.dart';

/// End-to-end smoke tests over the in-memory backend.
///
/// These run the real widget tree, the real router redirects and the real
/// state machine — only the transport is swapped. That is the point of the demo
/// backend: a test that stubs the controllers proves the stubs work.
Future<void> main() async {
  setUpAll(() => initializeDateFormatting('es_DO'));

  Widget harness(DemoBackend backend, {MyFix? position}) => ProviderScope(
        overrides: [
          if (position != null)
            myPositionProvider.overrideWith((ref) => Stream.value(position)),
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
        child: const ClientApp(),
      );

  testWidgets('an unauthenticated cold start lands on the welcome screen',
      (tester) async {
    await tester.pumpWidget(harness(DemoBackend()..seed()));
    await tester.pumpAndSettle();

    expect(find.text('Entrar con Teléfono'), findsOneWidget);
    expect(find.text('Registrarme'), findsOneWidget);
  });

  testWidgets('phone sign-in reaches the home screen', (tester) async {
    await tester.pumpWidget(harness(DemoBackend()..seed()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Entrar con Teléfono'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).first, '8095551234');
    await tester.pumpAndSettle();

    await tester.tap(find.text('Enviar código'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // Any six digits are accepted by the demo auth repository.
    await tester.enterText(find.byType(TextField).first, '123456');
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('PEDIR GRÚA 24/7'), findsOneWidget);
  });

  testWidgets('the home map puts the customer where their phone says, as the '
      'red drop', (tester) async {
    const here = LatLng(18.4712, -69.9061);
    await tester.pumpWidget(
      harness(DemoBackend()..seed(), position: (position: here, heading: 0)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Entrar con Teléfono'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, '8095551234');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enviar código'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await tester.enterText(find.byType(TextField).first, '123456');
    await tester.pumpAndSettle(const Duration(seconds: 1));

    final map = tester.widget<GruaMap>(find.byType(GruaMap));
    final mine = map.markers.where((m) => m.kind == MapMarkerKind.me);
    expect(mine, hasLength(1));
    expect(mine.single.position, here);
    // The camera is on them, not on the default centre.
    expect(map.center, here);
    expect(find.byTooltip('Centrar en mi ubicación'), findsOneWidget);
  });

  testWidgets('registering carries the form answers onto the new profile',
      (tester) async {
    await tester.pumpWidget(harness(DemoBackend()..seed()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Registrarme'));
    await tester.pumpAndSettle();
    expect(find.text('Crear tu cuenta'), findsOneWidget);

    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'Andrés Familia');
    await tester.enterText(fields.at(1), '8095551234');
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('Crear cuenta'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Crear cuenta'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.enterText(find.byType(TextField).first, '123456');
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // The name was typed before the account existed. Seeing it in the greeting
    // proves it survived the SMS step and was written afterwards.
    expect(find.text('Hola, Andrés'), findsOneWidget);
  });

  test('a short verification code is rejected with a specific message', () async {
    // A plain test, not testWidgets: the demo repository simulates latency with
    // a real Future.delayed, and testWidgets' fake async never advances it
    // unless the tester pumps — the await would hang forever.
    final container = ProviderContainer(
      overrides: demoOverrides(backend: DemoBackend()..seed()),
    );
    addTearDown(container.dispose);

    final auth = container.read(authRepositoryProvider);
    await auth.startPhoneVerification('+18095551234');

    final tooShort = await auth.confirmSmsCode(
      verificationId: 'demo-verification-id',
      smsCode: '12345',
    );
    expect(tooShort.isErr, isTrue);
    expect(tooShort.failureOrNull?.code, FailureCode.invalidInput);
    expect(tooShort.failureOrNull?.userMessage, contains('6 dígitos'));

    final valid = await auth.confirmSmsCode(
      verificationId: 'demo-verification-id',
      smsCode: '123456',
    );
    expect(valid.isOk, isTrue);
    expect(auth.currentUserId, isNotNull);
  });

  test('a request is refused while the customer already has one in flight',
      () async {
    final container = ProviderContainer(
      overrides: demoOverrides(backend: DemoBackend()..seed()),
    );
    addTearDown(container.dispose);

    const pickup = ServiceLocation(
      geo: DoLocations.santoDomingo,
      address: 'Av. 27 de Febrero',
      reference: 'Frente al colmado',
    );
    const dropoff = ServiceLocation(
      geo: DoLocations.sanPedro,
      address: 'Taller Hermanos Pérez',
    );
    const vehicle = ServiceVehicle(
      make: 'Toyota',
      model: 'Corolla',
      condition: VehicleCondition.noArranca,
    );

    final gateway = container.read(functionsGatewayProvider);
    final quote = await gateway.quoteService(
      pickup: pickup,
      dropoff: dropoff,
      vehicle: vehicle,
    );
    expect(quote.isOk, isTrue);
    // A gancho tow of this distance must cost something.
    expect(quote.valueOrNull!.quote.totalCents, greaterThan(0));
    expect(quote.valueOrNull!.truckType, TruckType.gancho);

    final first = await gateway.requestService(
      pickup: pickup,
      dropoff: dropoff,
      vehicle: vehicle,
      truckType: TruckType.gancho,
      quoteSignature: quote.valueOrNull!.signature,
      quoteExpiresAt: quote.valueOrNull!.expiresAt,
      distance: TripDistance.of(quote.valueOrNull!.quote),
    );
    expect(first.isOk, isTrue);

    final second = await gateway.requestService(
      pickup: pickup,
      dropoff: dropoff,
      vehicle: vehicle,
      truckType: TruckType.gancho,
      quoteSignature: quote.valueOrNull!.signature,
      quoteExpiresAt: quote.valueOrNull!.expiresAt,
      distance: TripDistance.of(quote.valueOrNull!.quote),
    );
    expect(second.isErr, isTrue);
    expect(
      second.failureOrNull?.code,
      FailureCode.alreadyHasActiveService,
    );
    // The existing service id rides along so the app can deep-link to it
    // instead of stranding the customer on a dead end.
    expect(second.failureOrNull?.details, first.valueOrNull);
  });

  test('a flatbed is required when the vehicle cannot roll', () async {
    const rolled = ServiceVehicle(condition: VehicleCondition.volcado);
    const flat = ServiceVehicle(condition: VehicleCondition.gomaPinchada);
    const truck = ServiceVehicle(
      type: VehicleType.camion,
      condition: VehicleCondition.noArranca,
    );

    expect(rolled.inferredTruckType, TruckType.plataforma);
    expect(flat.inferredTruckType, TruckType.gancho);
    expect(truck.inferredTruckType, TruckType.pesada);
  });
}

import 'package:client_app/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';
import 'package:grua_testing/grua_testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The banner the customer gets when a chofer writes.
///
/// The chofer's app has announced arriving messages since the bell went in;
/// the customer had nothing, so a reply landed silently unless they happened
/// to be looking at the conversation.
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

  /// Frames without settling: the nearby search repaints its countdown.
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

  testWidgets("a chofer's message drops in as a banner that opens the "
      'conversation', (tester) async {
    final backend = await signIn(tester);

    // Ask a truck on the map to talk, and have its chofer accept.
    trucksOn(tester).first.onTap!();
    await advance(tester, const Duration(seconds: 1));
    await tester.tap(find.byKey(const Key('truck-chat')));
    await advance(tester, const Duration(seconds: 1));

    final request = backend.allChatRequests.single;
    backend.respondChatRequest(request.id, request.driverId, accept: true);
    await advance(tester, const Duration(seconds: 1));

    final driverName = backend.chatRequest(request.id)!.driverName;

    // Back to the map: the customer has put the phone down.
    await tester.tap(find.byType(BackButton));
    await advance(tester, const Duration(seconds: 1));
    expect(find.text('PEDIR GRÚA 24/7'), findsOneWidget);

    backend.addChatRequestMessage(
      request.id,
      ChatMessage(
        id: 'm-driver-1',
        senderId: request.driverId,
        senderRole: UserRole.driver,
        text: 'Voy saliendo para allá',
        sentAt: DateTime.now().toUtc(),
      ),
    );
    await advance(tester, const Duration(seconds: 1));

    expect(find.byKey(const Key('notification-toast')), findsOneWidget);
    expect(find.text('Mensaje de $driverName'), findsOneWidget);
    expect(find.text('Voy saliendo para allá'), findsOneWidget);

    // And it leads straight into the conversation.
    await tester.tap(find.byKey(const Key('notification-toast')));
    await advance(tester, const Duration(seconds: 1));
    expect(find.byKey(const Key('notification-toast')), findsNothing);
    expect(find.text('Escribe un mensaje…'), findsOneWidget);
    expect(find.text('Voy saliendo para allá'), findsOneWidget);
  });

  testWidgets('the customer is told when a chofer accepts their chat request', (
    tester,
  ) async {
    final backend = await signIn(tester);

    trucksOn(tester).first.onTap!();
    await advance(tester, const Duration(seconds: 1));
    await tester.tap(find.byKey(const Key('truck-chat')));
    await advance(tester, const Duration(seconds: 1));

    final request = backend.allChatRequests.single;

    // Waiting somewhere else in the app, as a customer would be.
    await tester.tap(find.byType(BackButton));
    await advance(tester, const Duration(seconds: 1));

    backend.respondChatRequest(request.id, request.driverId, accept: true);
    await advance(tester, const Duration(seconds: 1));

    expect(find.byKey(const Key('notification-toast')), findsOneWidget);
    expect(find.text('La grúa te respondió'), findsOneWidget);
  });
}

/// The trucks the home map is currently showing.
Iterable<MapMarker> trucksOn(WidgetTester tester) => tester
    .widget<GruaMap>(find.byType(GruaMap))
    .markers
    .where((m) => m.kind == MapMarkerKind.truckIdle);

import 'package:client_app/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';
import 'package:grua_testing/grua_testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The customer's list of conversations.
///
/// A chofer who has answered has a name and a face on their record; showing a
/// grey letter instead is worse than the photo the office already has.
Future<void> main() async {
  setUpAll(() => initializeDateFormatting('es_DO'));
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const gazcue = LatLng(18.4795, -69.9420);

  // A one-pixel JPEG is enough: what matters is that the tile asks for the
  // photo rather than drawing an initial.
  const photo = 'data:image/jpeg;base64,/9j/4AAQSkZJRgABAQAAAQABAAD//gAA';

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

  testWidgets('a chofer who answered is shown by their photo, not a letter', (
    tester,
  ) async {
    final backend = await signIn(tester);

    trucksOn(tester).first.onTap!();
    await advance(tester, const Duration(seconds: 1));
    await tester.tap(find.byKey(const Key('truck-chat')));
    await advance(tester, const Duration(seconds: 1));

    final request = backend.allChatRequests.single;

    // The office has the chofer's photo on file, as it does in production.
    final path = 'drivers/${request.driverId}/avatar/photo';
    backend
      ..storeUpload(path, photo)
      ..setDriverPhoto(request.driverId, path)
      ..respondChatRequest(request.id, request.driverId, accept: true);
    await advance(tester, const Duration(seconds: 1));

    // Back out of the conversation and into the list of them.
    await tester.tap(find.byType(BackButton));
    await advance(tester, const Duration(seconds: 1));
    // Icons only in the bar: a hidden label has no size to tap, so the tap
    // goes to the destination around it.
    await tester.tap(
      find.ancestor(
        of: find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('Chat'),
        ),
        matching: find.byType(NavigationDestination),
      ),
    );
    await advance(tester, const Duration(seconds: 1));

    final avatar = tester.widget<DriverAvatar>(find.byType(DriverAvatar));
    expect(avatar.photoUrl, photo);
    expect(avatar.name, backend.chatRequest(request.id)!.driverName);
  });

  testWidgets('a chofer who has not answered shows no face at all', (
    tester,
  ) async {
    final backend = await signIn(tester);

    trucksOn(tester).first.onTap!();
    await advance(tester, const Duration(seconds: 1));
    await tester.tap(find.byKey(const Key('truck-chat')));
    await advance(tester, const Duration(seconds: 1));

    await tester.tap(find.byType(BackButton));
    await advance(tester, const Duration(seconds: 1));
    // Icons only in the bar: a hidden label has no size to tap, so the tap
    // goes to the destination around it.
    await tester.tap(
      find.ancestor(
        of: find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('Chat'),
        ),
        matching: find.byType(NavigationDestination),
      ),
    );
    await advance(tester, const Duration(seconds: 1));

    // Waiting: a truck, and nothing that hints at who is driving it.
    expect(find.byType(DriverAvatar), findsNothing);
    expect(find.text('Grúa cercana'), findsOneWidget);
    expect(backend.allChatRequests.single.driverPhotoUrl, isEmpty);
  });
}

/// The trucks the home map is currently showing.
Iterable<MapMarker> trucksOn(WidgetTester tester) => tester
    .widget<GruaMap>(find.byType(GruaMap))
    .markers
    .where((m) => m.kind == MapMarkerKind.truckIdle);

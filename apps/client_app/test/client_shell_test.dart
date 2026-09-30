import 'package:client_app/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';
import 'package:grua_testing/grua_testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The customer's bottom bar and the four tabs behind it.
///
/// What these pin down is the customer's side of it: the map keeps the two
/// things a stranded customer needs fastest — the search for grúas nearby and
/// "PEDIR GRÚA 24/7" — while everything else moved into tabs.
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

  /// Frames without settling: the nearby search repaints its countdown for as
  /// long as it runs.
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

  Finder tab(String label) => find.descendant(
    of: find.byType(NavigationBar),
    matching: find.text(label),
  );

  // The labels are hidden, so the tap goes to the destination they name.
  Future<void> openTab(WidgetTester tester, String label) async {
    await tester.tap(
      find.ancestor(of: tab(label), matching: find.byType(NavigationDestination)),
    );
    await advance(tester, const Duration(seconds: 1));
  }

  testWidgets('the bottom bar splits the app into Inicio, Servicios, Chat and '
      'Perfil', (tester) async {
    await signIn(tester);

    for (final label in ['Inicio', 'Servicios', 'Chat', 'Perfil']) {
      expect(tab(label), findsOneWidget, reason: label);
    }

    // Inicio keeps both main actions over the map.
    expect(find.text('PEDIR GRÚA 24/7'), findsOneWidget);
    expect(find.byKey(const Key('nearby-trucks-row')), findsOneWidget);
    // What used to sit beside them moved into the tabs.
    expect(find.text('Métodos de pago'), findsNothing);
    expect(find.text('Soporte 24/7'), findsNothing);

    // Laid out, not just present: the map runs to the bar, and the request
    // button sits over its lower edge.
    final barTop = tester.getTopLeft(find.byType(NavigationBar)).dy;
    final map = tester.getRect(find.byType(GruaMap));
    expect(map.top, 0);
    expect(map.bottom, barTop);
    expect(
      tester.getRect(find.text('PEDIR GRÚA 24/7')).bottom,
      lessThanOrEqualTo(barTop),
    );

    await openTab(tester, 'Servicios');
    expect(find.text('Mis servicios y facturas'), findsOneWidget);
    expect(find.text('PEDIR GRÚA 24/7'), findsNothing);

    await openTab(tester, 'Chat');
    expect(find.text('Mensajes'), findsOneWidget);
    expect(find.text('Sin conversación activa'), findsOneWidget);

    await openTab(tester, 'Perfil');
    expect(find.text('Mi cuenta'), findsOneWidget);
    expect(find.text('Ramón Peña'), findsOneWidget);

    // Back to the map, as it was left.
    await openTab(tester, 'Inicio');
    expect(find.text('PEDIR GRÚA 24/7'), findsOneWidget);
    expect(find.text('Mi cuenta'), findsNothing);
  });
}

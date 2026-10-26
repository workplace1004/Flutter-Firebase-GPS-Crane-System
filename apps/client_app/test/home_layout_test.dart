import 'package:client_app/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';
import 'package:grua_testing/grua_testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The home screen's cards sit on the bottom bar, whatever the screen's
/// height.
///
/// The bug: a Flexible logo beside a Spacer split the free room in half, and
/// the half the logo did not use was left empty under "PEDIR GRÚA 24/7".
Future<void> main() async {
  setUpAll(() => initializeDateFormatting('es_DO'));
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const gazcue = LatLng(18.4795, -69.9420);

  Future<void> advance(WidgetTester tester, Duration by) async {
    for (var i = 0; i < by.inMilliseconds ~/ 250; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  Future<DemoBackend> home(WidgetTester tester, Size size) async {
    // Signed in on a tall screen, where the sign-in buttons are all in
    // view, then shown at the size under test.
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(430, 1400);
    addTearDown(tester.view.reset);

    final backend = DemoBackend()..seed();
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
          myPositionProvider.overrideWith(
            (ref) => Stream.value((position: gazcue, heading: 0)),
          ),
        ],
        child: const ClientApp(),
      ),
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
    tester.view.physicalSize = size;
    await advance(tester, const Duration(seconds: 1));
    return backend;
  }

  for (final size in const [Size(412, 915), Size(430, 1400), Size(360, 640)]) {
    testWidgets(
        'the request button sits on the bottom bar at '
        '${size.width.toInt()}×${size.height.toInt()}', (tester) async {
      final backend = await home(tester, size);

      final button = tester.getRect(find.text('PEDIR GRÚA 24/7'));
      final bar = tester.getRect(find.byType(NavigationBar));
      // The button's own padding and the gutter under it, nothing more.
      expect(bar.top - button.bottom, lessThan(48));
      // And no overflow on a short phone: the logo gives way instead.
      expect(tester.takeException(), isNull);

      await advance(tester, const Duration(seconds: 2));
      await tester.pumpWidget(const SizedBox.shrink());
      backend.dispose();
    });
  }
}

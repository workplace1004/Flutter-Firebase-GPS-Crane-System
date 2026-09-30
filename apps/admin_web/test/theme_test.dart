import 'package:admin_web/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';
import 'package:grua_testing/grua_testing.dart';
import 'package:intl/date_symbol_data_local.dart';

/// The panel's two skins: the control in the top bar, what it remembers, and
/// that the pages themselves follow it instead of staying white.
Future<void> main() async {
  setUpAll(() => initializeDateFormatting('es_DO'));

  const config = AppConfig(
    flavor: Flavor.dev,
    appKind: AppKind.admin,
    firebaseProjectId: 'grua-rd-test',
    googleMapsApiKey: '',
    useEmulators: false,
    emulatorHost: 'localhost',
    functionsRegion: 'us-east1',
  );

  Future<InMemoryThemeModeStore> open(
    WidgetTester tester, {
    ThemeMode? stored,
  }) async {
    tester.view
      ..devicePixelRatio = 1.0
      ..physicalSize = const Size(1440, 1200);
    addTearDown(tester.view.reset);

    final store = InMemoryThemeModeStore(stored);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appConfigProvider.overrideWithValue(config),
          themeModeStoreProvider.overrideWithValue(store),
          ...demoOverrides(
            backend: DemoBackend()..seed(),
            role: UserRole.admin,
            actingAs: 'admin-1',
          ),
        ],
        child: const AdminApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'ops@gruasrd.do');
    await tester.enterText(find.byType(TextFormField).last, 'secret123');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Entrar'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    return store;
  }

  Brightness showing(WidgetTester tester) => Theme.of(
        tester.element(find.byKey(const Key('theme-toggle'))),
      ).brightness;

  testWidgets('the panel opens light and the toggle takes it dark',
      (tester) async {
    final store = await open(tester);
    expect(showing(tester), Brightness.light);

    await tester.tap(find.byKey(const Key('theme-toggle')));
    await tester.pumpAndSettle();

    expect(showing(tester), Brightness.dark);
    // And the workstation remembers it for next time.
    expect(store.read(), ThemeMode.dark);
  });

  testWidgets('it opens in the skin this browser was left in', (tester) async {
    await open(tester, stored: ThemeMode.dark);
    expect(showing(tester), Brightness.dark);
  });

  testWidgets('the menu offers the three choices', (tester) async {
    final store = await open(tester);

    await tester.tap(find.byKey(const Key('theme-menu')));
    await tester.pumpAndSettle();
    expect(find.text('Claro'), findsOneWidget);
    expect(find.text('Oscuro'), findsOneWidget);
    expect(find.text('Como el sistema'), findsOneWidget);

    await tester.tap(find.byKey(const Key('theme-dark')));
    await tester.pumpAndSettle();
    expect(showing(tester), Brightness.dark);
    expect(store.read(), ThemeMode.dark);
  });

  testWidgets('the pages go dark with it, not just the chrome',
      (tester) async {
    await open(tester, stored: ThemeMode.dark);
    await tester.tap(find.text('Aseguradoras'));
    await tester.pumpAndSettle();

    final palette = BrandPalette.of(
      tester.element(find.text('Aseguradoras').last),
    );
    expect(palette.isDark, isTrue);

    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
    expect(
      scaffold.backgroundColor ??
          Theme.of(tester.element(find.byType(Scaffold).first))
              .scaffoldBackgroundColor,
      BrandPalette.dark.canvas,
    );
  });
}

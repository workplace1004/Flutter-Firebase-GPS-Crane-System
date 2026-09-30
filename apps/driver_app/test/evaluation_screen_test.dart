import 'package:driver_app/app.dart';
import 'package:driver_app/features/home/location_publisher.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';
import 'package:grua_testing/grua_testing.dart';
import 'package:intl/date_symbol_data_local.dart';

/// "Mi evaluación": the chofer reads what customers say about them — without
/// learning who said it — and what the office is watching.
Future<void> main() async {
  setUpAll(() => initializeDateFormatting('es_DO'));

  const config = AppConfig(
    flavor: Flavor.dev,
    appKind: AppKind.driver,
    firebaseProjectId: 'grua-rd-test',
    googleMapsApiKey: '',
    useEmulators: false,
    emulatorHost: 'localhost',
    functionsRegion: 'us-east1',
  );

  Widget harness(DemoBackend backend) => ProviderScope(
        overrides: [
          appConfigProvider.overrideWithValue(config),
          ...demoOverrides(backend: backend, role: UserRole.driver),
          locationPublisherProvider.overrideWith((ref) => null),
        ],
        child: const DriverApp(),
      );

  Future<void> frames(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('the chofer reads their evaluation', (tester) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(430, 1600);
    addTearDown(tester.view.reset);

    final backend = DemoBackend()..seed();
    // A customer's complaint, through the real rating path.
    expect(
      backend
          .rateService(
            'svc-history-0',
            'demo-client-1',
            stars: 2,
            tags: const [DriverRatingTag.late],
            comment: 'Tardó una hora',
          )
          .isOk,
      isTrue,
    );
    final driverId = backend.service('svc-history-0')!.driverId!;
    // Then a record that has slipped: 3.0 over ten ratings, and a chofer who
    // turns down most offers.
    backend.updateDriverForTest(
      driverId,
      (d) => d.copyWith(
        ratingSum: 30,
        ratingCount: 10,
        offersAccepted: 4,
        offersRejected: 6,
        offersMissed: 0,
        offersSent: 0,
      ),
    );

    await tester.pumpWidget(harness(backend));
    await tester.pump();
    await tester.enterText(
      find.byType(TextFormField).first,
      '$driverId@gruasrd.do'.replaceFirst('driver-', 'driver'),
    );
    await tester.enterText(find.byType(TextFormField).last, 'secret123');
    await tester.pump();
    await tester.tap(find.text('ENTRAR'));
    await frames(tester);

    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('Perfil'),
      ),
    );
    await frames(tester);

    final entry = find.byKey(const Key('profile-evaluation'));
    await tester.ensureVisible(entry);
    expect(
      find.descendant(of: entry, matching: find.text('★ 3.0 · Crítico')),
      findsOneWidget,
    );
    await tester.tap(entry);
    await frames(tester);

    expect(find.text('Mi evaluación'), findsOneWidget);
    expect(find.byKey(const Key('evaluation-average')), findsOneWidget);
    expect(find.text('3.0'), findsOneWidget);
    expect(find.text('Crítico'), findsOneWidget);
    // What the office is watching, in words.
    final warning = find.byKey(const Key('evaluation-warning'));
    expect(warning, findsOneWidget);
    expect(
      find.descendant(
        of: warning,
        matching: find.textContaining('acepta el 40% de las ofertas'),
      ),
      findsOneWidget,
    );
    expect(find.text('Qué mejorar'), findsOneWidget);
    expect(find.text('Llegó tarde'), findsWidgets);
    // The comment, and nothing that says who wrote it or on which job.
    expect(find.text('“Tardó una hora”'), findsOneWidget);
    expect(find.textContaining('Ramón'), findsNothing);
    expect(
      find.textContaining(backend.service('svc-history-0')!.code),
      findsNothing,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    backend.dispose();
  });
}

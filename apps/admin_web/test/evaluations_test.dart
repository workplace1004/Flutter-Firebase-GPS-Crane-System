import 'package:admin_web/app.dart';
import 'package:admin_web/features/drivers/driver_details_dialog.dart';
import 'package:admin_web/features/evaluations/evaluation_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';
import 'package:grua_testing/grua_testing.dart';
import 'package:intl/date_symbol_data_local.dart';

/// Evaluaciones: the office sees what customers said about each chofer,
/// works through the flagged reviews, and reads a chofer's scorecard.
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

  // Finished two days ago by driver-1, for the seeded customer.
  const rated = 'svc-history-0';

  /// A customer's complaint, filed before the office signs in.
  DemoBackend withComplaint() {
    final backend = DemoBackend()..seed();
    final result = backend.rateService(
      rated,
      'demo-client-1',
      stars: 2,
      tags: const [DriverRatingTag.vehicleDamage],
      comment: 'Le rayó la puerta',
    );
    expect(result.isOk, isTrue);
    return backend;
  }

  Future<void> signIn(WidgetTester tester, DemoBackend backend) async {
    tester.view
      ..devicePixelRatio = 1.0
      ..physicalSize = const Size(1440, 1800);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appConfigProvider.overrideWithValue(config),
          ...demoOverrides(
            backend: backend,
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
  }

  Future<void> go(WidgetTester tester, String path) async {
    GoRouter.of(tester.element(find.byType(Scaffold).first)).go(path);
    await tester.pumpAndSettle(const Duration(seconds: 1));
  }

  Future<void> finish(WidgetTester tester, DemoBackend backend) async {
    await tester.pumpWidget(const SizedBox.shrink());
    backend.dispose();
  }

  testWidgets('a flagged review is worked through and closed', (tester) async {
    final backend = withComplaint();
    await signIn(tester, backend);

    // The sidebar says there is one waiting.
    expect(find.text('Evaluaciones'), findsOneWidget);
    await go(tester, '/evaluaciones');

    expect(find.text('Por revisar (1)'), findsOneWidget);
    expect(find.text('“Le rayó la puerta”'), findsOneWidget);
    expect(find.text('Dañó mi vehículo'), findsOneWidget);

    await tester.tap(find.byKey(const Key('resolve-$rated')));
    await tester.pumpAndSettle();
    final confirm = find.byKey(const Key('resolve-confirm'));
    // Nothing to save until the office says what it did.
    expect(tester.widget<ElevatedButton>(confirm).onPressed, isNull);
    await tester.enterText(
      find.byKey(const Key('resolve-note')),
      'Se llamó al cliente; el chofer pagará el arreglo.',
    );
    await tester.pump();
    await tester.tap(confirm);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    final review = backend.review(rated)!;
    expect(review.status, DriverReviewStatus.resolved);
    expect(review.resolvedBy, 'admin-1');
    expect(find.text('Por revisar (0)'), findsOneWidget);
    expect(find.text('Nada por revisar'), findsOneWidget);

    // Still there under Todas, with what was done.
    await tester.tap(find.text('Todas'));
    await tester.pumpAndSettle();
    expect(
      find.text('Revisada: Se llamó al cliente; el chofer pagará el arreglo.'),
      findsOneWidget,
    );

    await finish(tester, backend);
  });

  testWidgets("a chofer's details show their evaluation", (tester) async {
    final backend = withComplaint();
    final driver = backend.driver(backend.service(rated)!.driverId!)!;
    await signIn(tester, backend);

    final context = tester.element(find.byType(Scaffold).first);
    // Not awaited: the dialog stays open while the test reads it.
    // ignore: unawaited_futures
    showDriverDetailsDialog(context, driver);
    await tester.pumpAndSettle();

    final scorecard = find.byKey(const Key('driver-scorecard'));
    await tester.ensureVisible(scorecard);
    expect(scorecard, findsOneWidget);
    final card = DriverScorecard.of(driver);
    expect(
      find.descendant(
        of: find.byKey(const Key('scorecard-average')),
        matching: find.text(card.averageLabel),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: scorecard, matching: find.text('Dañó mi vehículo · 1')),
      findsOneWidget,
    );
    // And the latest review, with who wrote it.
    expect(
      find.descendant(of: scorecard, matching: find.text('“Le rayó la puerta”')),
      findsOneWidget,
    );

    await finish(tester, backend);
  });

  testWidgets('a chofer whose record slipped is listed for the office',
      (tester) async {
    final backend = DemoBackend()..seed();
    final driverId = backend.service(rated)!.driverId!;
    // Ten more ratings of two stars pull the average under the line.
    backend.updateDriverForTest(
      driverId,
      (d) => d.copyWith(ratingSum: 20, ratingCount: 10),
    );
    await signIn(tester, backend);
    await go(tester, '/evaluaciones');

    expect(find.byKey(Key('attention-$driverId')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(Key('attention-$driverId')),
        matching: find.text('Crítico'),
      ),
      findsOneWidget,
    );

    await finish(tester, backend);
  });

  testWidgets("the roster shows each chofer's stars", (tester) async {
    final backend = DemoBackend()
      ..seed()
      ..updateDriverForTest(
        'driver-1',
        (d) => d.copyWith(ratingSum: 43, ratingCount: 10),
      )
      ..updateDriverForTest(
        'driver-2',
        (d) => d.copyWith(ratingSum: 0, ratingCount: 0),
      );
    await signIn(tester, backend);
    await go(tester, '/choferes');

    expect(find.text('CALIFICACIÓN'), findsOneWidget);
    final rated = find.byKey(const Key('rating-driver-1'));
    expect(
      find.descendant(of: rated, matching: find.text('4.3 · 10 calificaciones')),
      findsOneWidget,
    );
    // 4.3 draws four stars and a half.
    final stars = tester.widget<RatingStars>(
      find.descendant(of: rated, matching: find.byType(RatingStars)),
    );
    expect(stars.value, closeTo(4.3, 0.001));
    expect(
      find.descendant(of: rated, matching: find.byIcon(Icons.star_rounded)),
      findsNWidgets(4),
    );
    expect(
      find.descendant(of: rated, matching: find.byIcon(Icons.star_half_rounded)),
      findsOneWidget,
    );

    // Nobody has rated this one yet.
    expect(
      tester.widget<Text>(find.byKey(const Key('rating-driver-2'))).data,
      'Nuevo',
    );

    await finish(tester, backend);
  });
}

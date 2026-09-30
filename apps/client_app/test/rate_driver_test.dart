import 'package:client_app/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';
import 'package:grua_testing/grua_testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The customer rating the chofer after the tow: stars, what went well or
/// wrong, a comment — and then it is said and shown, not asked again.
Future<void> main() async {
  setUpAll(() => initializeDateFormatting('es_DO'));
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const gazcue = LatLng(18.4795, -69.9420);

  // Finished two days ago; the seeded customer's.
  const recent = 'svc-history-0';
  // Finished nine days ago: too late to rate.
  const old = 'svc-history-1';

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

  Future<DemoBackend> openDetail(WidgetTester tester, String serviceId) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(430, 1600);
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

    GoRouter.of(tester.element(find.byType(Scaffold).first))
        .go('/historial/$serviceId');
    await advance(tester, const Duration(seconds: 1));
    return backend;
  }

  Future<void> finish(WidgetTester tester, DemoBackend backend) async {
    await tester.pumpWidget(const SizedBox.shrink());
    backend.dispose();
  }

  testWidgets('a poor rating with a complaint and a comment', (tester) async {
    final backend = await openDetail(tester, recent);

    expect(find.byKey(const Key('rate-driver-card')), findsOneWidget);
    await tester.tap(find.byKey(const Key('rate-card-star-2')));
    await advance(tester, const Duration(seconds: 1));

    // The sheet opens on the star tapped, offering complaints, not praise.
    expect(find.byKey(const Key('rate-driver-sheet')), findsOneWidget);
    expect(find.text('Malo'), findsOneWidget);
    expect(find.byKey(const Key('rate-tag-punctual')), findsNothing);
    await tester.tap(find.byKey(const Key('rate-tag-vehicle_damage')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('rate-comment')),
      'Le rayó la puerta al subirlo',
    );
    await tester.tap(find.byKey(const Key('rate-send')));
    await advance(tester, const Duration(seconds: 1));

    expect(find.byKey(const Key('rate-driver-sheet')), findsNothing);
    expect(find.text('¡Gracias por tu calificación!'), findsOneWidget);

    final rating = backend.service(recent)!.ratings.clientToDriver!;
    expect(rating.stars, 2);
    expect(rating.ratingTags, [DriverRatingTag.vehicleDamage]);
    expect(rating.comment, 'Le rayó la puerta al subirlo');
    // Damage goes to the office.
    expect(backend.review(recent)!.status, DriverReviewStatus.open);

    // Said once, and shown rather than asked again.
    expect(find.byKey(const Key('rate-driver-card')), findsNothing);
    expect(find.byKey(const Key('given-rating')), findsOneWidget);
    expect(find.text('Dañó mi vehículo'), findsOneWidget);

    await finish(tester, backend);
  });

  testWidgets('changing from a complaint to praise swaps the tags',
      (tester) async {
    final backend = await openDetail(tester, recent);

    await tester.tap(find.byKey(const Key('rate-card-star-3')));
    await advance(tester, const Duration(seconds: 1));
    await tester.tap(find.byKey(const Key('rate-tag-late')));
    await tester.pump();

    await tester.tap(find.byKey(const Key('rate-star-5')));
    await tester.pump();
    expect(find.byKey(const Key('rate-tag-late')), findsNothing);
    await tester.tap(find.byKey(const Key('rate-tag-careful')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('rate-send')));
    await advance(tester, const Duration(seconds: 1));

    final rating = backend.service(recent)!.ratings.clientToDriver!;
    expect(rating.stars, 5);
    expect(rating.ratingTags, [DriverRatingTag.careful]);
    expect(backend.review(recent)!.status, DriverReviewStatus.ok);

    await finish(tester, backend);
  });

  testWidgets('a tow past the week is not offered for rating', (tester) async {
    final backend = await openDetail(tester, old);
    expect(find.text(backend.service(old)!.code), findsWidgets);
    expect(find.byKey(const Key('rate-driver-card')), findsNothing);
    await advance(tester, const Duration(seconds: 2));
    await finish(tester, backend);
  });
}

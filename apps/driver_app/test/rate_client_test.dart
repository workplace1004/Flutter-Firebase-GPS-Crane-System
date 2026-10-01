import 'package:driver_app/app.dart';
import 'package:driver_app/features/home/location_publisher.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';
import 'package:grua_testing/grua_testing.dart';
import 'package:intl/date_symbol_data_local.dart';

/// The chofer rating the customer once the job is over: asked as it ends,
/// with what a customer can be — there, on time, paying — rather than what a
/// chofer can.
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

  // driver-1's job for the seeded customer, finished two days ago.
  const job = 'svc-history-0';

  Widget harness(DemoBackend backend, {Set<String> finished = const {}}) =>
      ProviderScope(
        overrides: [
          appConfigProvider.overrideWithValue(config),
          ...demoOverrides(backend: backend, role: UserRole.driver),
          locationPublisherProvider.overrideWith((ref) => null),
          finishedDriverServicesProvider.overrideWith(() => _Ended(finished)),
        ],
        child: const DriverApp(),
      );

  Future<void> frames(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<DemoBackend> signIn(
    WidgetTester tester, {
    Set<String> finished = const {},
  }) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(430, 1400);
    addTearDown(tester.view.reset);

    final backend = DemoBackend()..seed();
    await tester.pumpWidget(harness(backend, finished: finished));
    await tester.pump();
    await tester.enterText(
      find.byType(TextFormField).first,
      'driver1@gruasrd.do',
    );
    await tester.enterText(find.byType(TextFormField).last, 'secret123');
    await tester.pump();
    await tester.tap(find.text('ENTRAR'));
    await frames(tester);
    return backend;
  }

  Future<void> finish(WidgetTester tester, DemoBackend backend) async {
    await frames(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    backend.dispose();
  }

  testWidgets('a job that just ended asks the chofer to rate the customer',
      (tester) async {
    final backend = await signIn(tester, finished: {job});
    expect(backend.service(job)!.driverId, 'driver-1');

    final sheet = find.byKey(const Key('rate-client-sheet'));
    expect(sheet, findsOneWidget);
    expect(
      find.descendant(of: sheet, matching: find.text('Califica a Ramón Peña')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('rate-star-2')));
    await tester.pump();
    // A customer's tags, not a chofer's.
    expect(find.byKey(const Key('rate-tag-not_there')), findsOneWidget);
    expect(find.byKey(const Key('rate-tag-late')), findsNothing);
    await tester.tap(find.byKey(const Key('rate-tag-not_there')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('rate-comment')),
      'No estaba, esperé media hora',
    );
    await tester.tap(find.byKey(const Key('rate-send')));
    await frames(tester);

    final rating = backend.service(job)!.ratings.driverToClient!;
    expect(rating.stars, 2);
    expect(rating.tags, ['not_there']);
    expect(rating.comment, 'No estaba, esperé media hora');

    final customer = backend.user('demo-client-1')!;
    expect(customer.ratingCount, 1);
    expect(customer.ratingTags, {'not_there': 1});

    expect(find.byKey(const Key('rate-client-sheet')), findsNothing);
    expect(find.byKey(const Key('rate-client-card')), findsNothing);

    await finish(tester, backend);
  });

  testWidgets('an older job waits on a card instead of interrupting',
      (tester) async {
    final backend = await signIn(tester);

    expect(find.byKey(const Key('rate-client-sheet')), findsNothing);
    expect(find.byKey(const Key('rate-client-card')), findsOneWidget);

    await tester.tap(find.byKey(const Key('rate-card-close')));
    await frames(tester);
    expect(find.byKey(const Key('rate-client-card')), findsNothing);

    await finish(tester, backend);
  });
}

/// [FinishedServices] that has already seen [ids] end.
class _Ended extends FinishedServices {
  _Ended(this.ids) : super(activeDriverServiceProvider);

  final Set<String> ids;

  @override
  Set<String> build() => ids;
}

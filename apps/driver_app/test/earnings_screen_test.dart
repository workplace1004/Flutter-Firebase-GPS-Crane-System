import 'dart:async';

import 'package:driver_app/app.dart';
import 'package:driver_app/features/home/location_publisher.dart';
import 'package:driver_app/router.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';
import 'package:grua_testing/grua_testing.dart';
import 'package:intl/date_symbol_data_local.dart';

/// "Mis ganancias" before the server has any earnings to show.
///
/// The rollup document only exists once a chofer completes a job, so a new
/// chofer has none. The screen read that as "still loading" and spun forever.
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

  Future<void> openEarnings(
    WidgetTester tester,
    Stream<EarningsSummary?> Function() earnings,
  ) async {
    final backend = DemoBackend()..seed();
    addTearDown(backend.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appConfigProvider.overrideWithValue(config),
          ...demoOverrides(backend: backend, role: UserRole.driver),
          locationPublisherProvider.overrideWith((ref) => null),
          driverEarningsProvider.overrideWith((ref) => earnings()),
        ],
        child: const DriverApp(),
      ),
    );
    await tester.pump();

    await tester.enterText(
      find.byType(TextFormField).first,
      'driver1@gruasrd.do',
    );
    await tester.enterText(find.byType(TextFormField).last, 'secret123');
    await tester.pump();
    await tester.tap(find.text('ENTRAR'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    unawaited(
      ProviderScope.containerOf(tester.element(find.byType(DriverApp)))
          .read(routerProvider)
          .push(Routes.earnings),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('a chofer with no earnings yet sees zeros, not a spinner',
      (tester) async {
    await openEarnings(tester, () => Stream.value(null));

    expect(find.byType(BrandLoader), findsNothing);
    expect(find.text('GANANCIA NETA'), findsOneWidget);
    expect(find.text(0.formatDOP), findsWidgets);
  });

  testWidgets('earnings that fail to load say so and offer a retry',
      (tester) async {
    await openEarnings(
      tester,
      () => Stream.error(const Failure(FailureCode.permissionDenied)),
    );

    expect(find.byType(BrandLoader), findsNothing);
    expect(find.text('No pudimos cargar tus ganancias'), findsOneWidget);
    expect(find.text('Reintentar'), findsOneWidget);
  });
}

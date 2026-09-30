import 'package:admin_web/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';
import 'package:grua_testing/grua_testing.dart';
import 'package:intl/date_symbol_data_local.dart';

/// Aseguradoras in the panel: opening a company, its people, its prices, and
/// the default price list.
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

  Future<void> open(
    WidgetTester tester,
    DemoBackend backend, {
    UserRole role = UserRole.admin,
  }) async {
    tester.view
      ..devicePixelRatio = 1.0
      ..physicalSize = const Size(1440, 1500);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appConfigProvider.overrideWithValue(config),
          ...demoOverrides(backend: backend, role: role, actingAs: 'admin-1'),
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
    await tester.tap(find.text('Aseguradoras'));
    await tester.pumpAndSettle();
  }

  Future<void> openSeeded(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('insurer-row-ins-demo')));
    await tester.pumpAndSettle();
  }

  Future<void> tab(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(Key(key)));
    await tester.pumpAndSettle();
  }

  testWidgets('the office opens a company, with its own chofer share', (tester) async {
    final backend = DemoBackend()..seed();
    await open(tester, backend);

    expect(find.text('Seguros Demo, S.A.'), findsOneWidget);
    expect(find.textContaining('Chofer 70%'), findsOneWidget);

    await tester.tap(find.byKey(const Key('create-insurer')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('insurer-name')), 'Universal de Prueba');
    await tester.enterText(find.byKey(const Key('insurer-rnc')), '130000002');
    await tester.enterText(find.byKey(const Key('insurer-billing-email')), 'facturas@universal.test');
    await tester.enterText(find.byKey(const Key('insurer-payout')), '65');
    await tester.tap(find.text('Crear aseguradora'));
    await tester.pumpAndSettle();
    // The check digit is wrong: refused before it is sent.
    expect(find.text('Ese RNC no es válido. Revísalo.'), findsOneWidget);
    expect(backend.allInsurers, hasLength(1));

    await tester.enterText(find.byKey(const Key('insurer-rnc')), '1-31-00000-2');
    await tester.enterText(find.byKey(const Key('insurer-payout')), '140');
    await tester.tap(find.text('Crear aseguradora'));
    await tester.pumpAndSettle();
    expect(find.text('Escribe un porcentaje entre 0 y 100.'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('insurer-payout')), '65');
    await tester.tap(find.text('Crear aseguradora'));
    await tester.pumpAndSettle();

    // Straight into the new company.
    expect(find.text('Universal de Prueba'), findsOneWidget);
    expect(find.text('65%'), findsOneWidget);
    final created = backend.allInsurers.firstWhere((i) => i.name == 'Universal de Prueba');
    expect(created.rnc, '131000002');
    expect(created.driverPayoutBps, 6500);
  });

  testWidgets('the form types the RNC, offers the usual shares and shows the '
      'split', (tester) async {
    final backend = DemoBackend()..seed();
    await open(tester, backend);

    await tester.tap(find.byKey(const Key('create-insurer')));
    await tester.pumpAndSettle();

    // Bare digits are grouped as the DGII prints them.
    await tester.enterText(find.byKey(const Key('insurer-rnc')), '131000002');
    await tester.pump();
    expect(
      tester.widget<TextFormField>(find.byKey(const Key('insurer-rnc'))).controller?.text,
      '1-31-00000-2',
    );

    // Blank means the default 70%, and the example says what that pays.
    expect(find.textContaining('el chofer recibe'), findsOneWidget);
    expect(find.textContaining(r'RD$1,750'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('payout-choice-80')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('payout-choice-80')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextFormField>(find.byKey(const Key('insurer-payout'))).controller?.text,
      '80',
    );
    expect(find.textContaining(r'RD$2,000'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a company is suspended with a reason, and reactivated', (tester) async {
    final backend = DemoBackend()..seed();
    await open(tester, backend);
    await openSeeded(tester);

    await tester.tap(find.byKey(const Key('toggle-insurer-status')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('suspend-reason')), 'Pago atrasado');
    await tester.tap(find.byKey(const Key('confirm-suspend')));
    await tester.pumpAndSettle();

    expect(backend.insurer('ins-demo')!.status, InsurerStatus.suspended);
    expect(find.text('Suspendida: Pago atrasado'), findsOneWidget);
    expect(find.text('Reactivar'), findsOneWidget);

    await tester.tap(find.byKey(const Key('toggle-insurer-status')));
    await tester.pumpAndSettle();
    expect(backend.insurer('ins-demo')!.status, InsurerStatus.active);
    expect(find.textContaining('Suspendida:'), findsNothing);
  });

  testWidgets('the office adds a user and sees the first password once', (tester) async {
    final backend = DemoBackend()..seed();
    await open(tester, backend);
    await openSeeded(tester);
    await tab(tester, 'tab-users');

    expect(find.text('Marta Díaz'), findsOneWidget);
    expect(find.text('Agente Restrepo'), findsOneWidget);

    await tester.tap(find.byKey(const Key('add-insurer-user')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('user-name')), 'Pedro Operador');
    await tester.enterText(find.byKey(const Key('user-email')), 'pedro@segurosdemo.do');
    await tester.tap(find.text('Crear usuario'));
    await tester.pumpAndSettle();

    expect(find.text('Usuario creado'), findsOneWidget);
    final password = tester.widget<SelectableText>(find.byKey(const Key('temporary-password')));
    expect(password.data, isNotEmpty);
    await tester.tap(find.byKey(const Key('password-done')));
    await tester.pumpAndSettle();

    expect(find.text('Pedro Operador'), findsOneWidget);

    // The same email twice is refused, with the reason.
    await tester.tap(find.byKey(const Key('add-insurer-user')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('user-name')), 'Otro Pedro');
    await tester.enterText(find.byKey(const Key('user-email')), 'pedro@segurosdemo.do');
    await tester.tap(find.text('Crear usuario'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('user-error')), findsOneWidget);
    // Leaving a form with something typed in it asks before it is thrown away.
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(find.text('¿Descartar el usuario?'), findsOneWidget);
    await tester.tap(find.text('Descartar'));
    await tester.pumpAndSettle();
    expect(find.text('Crear usuario'), findsNothing);

    // Switching someone off.
    await tester.tap(find.byKey(const Key('insurer-user-active-insurer-operator-1')));
    await tester.pumpAndSettle();
    final operator = backend
        .insurerMembers('ins-demo')
        .firstWhere((m) => m.uid == 'insurer-operator-1');
    expect(operator.active, isFalse);
    expect(find.textContaining('Desactivado'), findsOneWidget);
  });

  testWidgets('a tap outside the company form closes it, or asks first',
      (tester) async {
    final backend = DemoBackend()..seed();
    await open(tester, backend);

    // Nothing typed: it just goes.
    await tester.tap(find.byKey(const Key('create-insurer')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.text('Crear aseguradora'), findsNothing);

    // Something typed: the question first.
    await tester.tap(find.byKey(const Key('create-insurer')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('insurer-name')),
      'Seguros Prueba',
    );
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.text('¿Descartar la aseguradora?'), findsOneWidget);
    await tester.tap(find.text('Descartar'));
    await tester.pumpAndSettle();
    expect(find.text('Crear aseguradora'), findsNothing);
    expect(backend.allInsurers, hasLength(1));

    // An edit opens pre-filled, and that is not "something typed".
    await openSeeded(tester);
    await tester.tap(find.byKey(const Key('edit-insurer')));
    await tester.pumpAndSettle();
    expect(find.text('Guardar cambios'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.text('Guardar cambios'), findsNothing);
  });

  testWidgets('a tap outside the user form closes it, or asks first',
      (tester) async {
    final backend = DemoBackend()..seed();
    await open(tester, backend);
    await openSeeded(tester);
    await tab(tester, 'tab-users');

    // Nothing typed: it just goes.
    await tester.tap(find.byKey(const Key('add-insurer-user')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.text('Crear usuario'), findsNothing);

    // Something typed: the question first, and "Seguir editando" keeps it.
    await tester.tap(find.byKey(const Key('add-insurer-user')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('user-name')), 'Ana Pérez');
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(find.text('¿Descartar el usuario?'), findsOneWidget);
    await tester.tap(find.text('Seguir editando'));
    await tester.pumpAndSettle();
    expect(find.text('Crear usuario'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Ana Pérez'), findsOneWidget);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Descartar'));
    await tester.pumpAndSettle();
    expect(find.text('Crear usuario'), findsNothing);
    expect(backend.insurerMembers('ins-demo'), hasLength(2));
  });

  testWidgets('a company gets its own price, and goes back to the base one', (tester) async {
    final backend = DemoBackend()..seed();
    await open(tester, backend);
    await openSeeded(tester);
    await tab(tester, 'tab-tariff');

    expect(find.textContaining('usa la tarifa base'), findsOneWidget);
    expect(find.byKey(const Key('zone-row-3')), findsOneWidget);
    expect(find.textContaining('62 km = ${694000.formatDOP}'), findsOneWidget);

    // RD$2,000 flat to 10 km instead of RD$2,500.
    await tester.enterText(find.byKey(const Key('zone-base-0')), '2000');
    await tester.pumpAndSettle();
    expect(find.textContaining('5 km = ${200000.formatDOP}'), findsOneWidget);
    await tester.tap(find.byKey(const Key('tariff-save')));
    await tester.pumpAndSettle();

    final (rows, source) = backend.zoneTableFor('ins-demo', VehicleClass.light);
    expect(source, ZoneTariffSource.insurer);
    expect(rows.first.baseCents, 200000);
    expect(find.textContaining('Precio negociado'), findsOneWidget);

    // A limit that leaves a gap is refused before it is sent.
    await tester.enterText(find.byKey(const Key('zone-max-1')), '5');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tariff-save')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tariff-error')), findsOneWidget);
    expect(backend.pricingRules(insurerId: 'ins-demo').any((r) => r.zoneMaxKm == 5), isFalse);

    await tester.tap(find.byKey(const Key('tariff-reset')));
    await tester.pumpAndSettle();
    expect(backend.pricingRules(insurerId: 'ins-demo'), isEmpty);
    expect(find.textContaining('usa la tarifa base'), findsOneWidget);

    String base(int zone) => tester
        .widget<EditableText>(
          find.descendant(of: find.byKey(Key('zone-base-$zone')), matching: find.byType(EditableText)),
        )
        .controller
        .text;

    // The fields went back to the base list too, not the old own price.
    expect(base(0), '2500');

    // Another admin saves while this page is open, and nothing was typed
    // here: the editor follows.
    backend.savePricingTable(
      insurerId: 'ins-demo',
      vehicleClass: VehicleClass.light,
      rows: [
        for (final r in ZonePricing.defaultRulesFor(VehicleClass.light))
          PricingRule(
            vehicleClass: r.vehicleClass,
            zoneMinKm: r.zoneMinKm,
            zoneMaxKm: r.zoneMaxKm,
            baseCents: r.zoneMinKm == 0 ? 180000 : r.baseCents,
            extraKmCents: r.extraKmCents,
            insurerId: 'ins-demo',
          ),
      ],
    );
    await tester.pumpAndSettle();
    expect(base(0), '1800');

    // Something typed and not saved survives a look at another tab, and is
    // not overwritten by the stored table.
    await tester.enterText(find.byKey(const Key('zone-base-0')), '1900');
    await tester.pumpAndSettle();
    await tab(tester, 'tab-details');
    await tab(tester, 'tab-tariff');
    expect(base(0), '1900');
  });

  testWidgets('the default list is edited for every company without its own', (tester) async {
    final backend = DemoBackend()..seed();
    await open(tester, backend);
    await tester.tap(find.byKey(const Key('open-default-tariff')));
    await tester.pumpAndSettle();

    expect(find.textContaining('Lista de precios incluida'), findsOneWidget);

    // SUVs: one more zone, then save.
    await tester.tap(find.text(VehicleClass.suv.label));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('zone-add')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('zone-row-4')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('zone-max-3')), '80');
    await tester.enterText(find.byKey(const Key('zone-base-3')), '9000');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tariff-save')));
    await tester.pumpAndSettle();

    final stored = backend.pricingRules();
    expect(stored.where((r) => r.vehicleClass == VehicleClass.suv), hasLength(5));
    expect(stored.every((r) => r.insurerId == null), isTrue);
    expect(find.textContaining('Tarifa base guardada'), findsOneWidget);

    final (rows, source) = backend.zoneTableFor('ins-demo', VehicleClass.suv);
    expect(source, ZoneTariffSource.standard);
    expect(rows.firstWhere((r) => r.zoneMinKm == 50).baseCents, 900000);
  });

  testWidgets('a dispatcher reads companies and prices but changes nothing', (tester) async {
    final backend = DemoBackend()..seed();
    await open(tester, backend, role: UserRole.ops);

    expect(find.byKey(const Key('create-insurer')), findsNothing);
    await openSeeded(tester);
    expect(find.byKey(const Key('edit-insurer')), findsNothing);
    expect(find.byKey(const Key('toggle-insurer-status')), findsNothing);

    await tab(tester, 'tab-users');
    expect(find.byKey(const Key('add-insurer-user')), findsNothing);
    expect(find.byKey(const Key('insurer-user-active-insurer-operator-1')), findsNothing);

    await tab(tester, 'tab-tariff');
    expect(find.byKey(const Key('tariff-save')), findsNothing);
    expect(find.byKey(const Key('zone-add')), findsNothing);
    expect(
      tester.widget<TextField>(find.byKey(const Key('zone-base-0'))).enabled,
      isFalse,
    );
  });
}

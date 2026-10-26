import 'package:admin_web/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';
import 'package:grua_testing/grua_testing.dart';
import 'package:intl/date_symbol_data_local.dart';

/// Clientes, as on Choferes: look at a customer, correct them, block or
/// unblock them, delete them — and see how choferes rated them.
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

  const ramon = 'demo-client-1';

  Future<DemoBackend> openClients(WidgetTester tester) async {
    tester.view
      ..devicePixelRatio = 1.0
      ..physicalSize = const Size(1366, 1000);
    addTearDown(tester.view.reset);

    final backend = DemoBackend()..seed();
    // A chofer's rating of Ramón, so the details have one to show.
    final job = backend.service('svc-history-0')!;
    expect(
      backend
          .rateService(
            job.id,
            job.driverId!,
            stars: 4,
            tags: const [ClientRatingTag.ready],
          )
          .isOk,
      isTrue,
    );

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
    GoRouter.of(tester.element(find.byType(Scaffold).first)).go('/clientes');
    await tester.pumpAndSettle(const Duration(seconds: 1));
    return backend;
  }

  Future<void> finish(WidgetTester tester, DemoBackend backend) async {
    await tester.pumpWidget(const SizedBox.shrink());
    backend.dispose();
  }

  testWidgets('each row has the same actions as a chofer', (tester) async {
    final backend = await openClients(tester);
    expect(find.text('ACCIONES'), findsOneWidget);
    for (final action in ['view', 'edit', 'block', 'delete']) {
      expect(find.byKey(Key('client-$action-$ramon')), findsOneWidget);
    }
    await finish(tester, backend);
  });

  testWidgets('the details show the rating and the latest tows',
      (tester) async {
    final backend = await openClients(tester);

    await tester.ensureVisible(find.byKey(const Key('client-view-$ramon')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('client-view-$ramon')));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    final details = find.byKey(const Key('client-details'));
    expect(details, findsOneWidget);
    expect(
      find.descendant(of: details, matching: find.text('Ramón Peña')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: details,
        matching: find.text('4.0 · 1 calificación'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: details, matching: find.text('Estaba en el lugar · 1')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: details,
        matching: find.textContaining(backend.service('svc-history-0')!.code),
      ),
      findsOneWidget,
    );
    await finish(tester, backend);
  });

  testWidgets('editing corrects the record, and a bad RNC is refused',
      (tester) async {
    final backend = await openClients(tester);

    await tester.ensureVisible(find.byKey(const Key('client-edit-$ramon')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('client-edit-$ramon')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('client-rnc')), '123');
    await tester.tap(find.byKey(const Key('client-save')));
    await tester.pumpAndSettle();
    expect(find.text('El RNC tiene 9 dígitos, o 11 si es una cédula.'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('client-name')), 'Ramón Peña Díaz');
    await tester.enterText(find.byKey(const Key('client-rnc')), '1-30-00000-2');
    await tester.enterText(find.byKey(const Key('client-email')), 'ramon@empresa.do');
    await tester.tap(find.byKey(const Key('client-save')));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    final saved = backend.user(ramon)!;
    expect(saved.name, 'Ramón Peña Díaz');
    expect(saved.rnc, '130000002');
    expect(saved.email, 'ramon@empresa.do');
    expect(find.text('Ramón Peña Díaz'), findsOneWidget);
    await finish(tester, backend);
  });

  testWidgets('blocking needs a reason; unblocking lets them back',
      (tester) async {
    final backend = await openClients(tester);
    // Another sample customer is blocked already.
    final blockedBefore = find.text('Bloqueado').evaluate().length;

    await tester.ensureVisible(find.byKey(const Key('client-block-$ramon')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('client-block-$ramon')));
    await tester.pumpAndSettle();
    final confirm = find.byKey(const Key('block-confirm'));
    expect(tester.widget<ElevatedButton>(confirm).onPressed, isNull);
    await tester.enterText(
      find.byKey(const Key('block-reason')),
      'No pagó dos servicios',
    );
    await tester.pump();
    await tester.tap(confirm);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(backend.user(ramon)!.blocked, isTrue);
    expect(backend.user(ramon)!.blockedReason, 'No pagó dos servicios');
    expect(find.text('Bloqueado'), findsNWidgets(blockedBefore + 1));

    await tester.ensureVisible(find.byKey(const Key('client-block-$ramon')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('client-block-$ramon')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('block-confirm')));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(backend.user(ramon)!.blocked, isFalse);
    await finish(tester, backend);
  });

  testWidgets('deleting removes the customer but keeps their tows',
      (tester) async {
    final backend = await openClients(tester);

    await tester.ensureVisible(find.byKey(const Key('client-delete-$ramon')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('client-delete-$ramon')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-delete-client')));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(backend.user(ramon), isNull);
    expect(find.byKey(const Key('client-view-$ramon')), findsNothing);
    // The history is the company's.
    expect(backend.service('svc-history-0'), isNotNull);
    await finish(tester, backend);
  });
}

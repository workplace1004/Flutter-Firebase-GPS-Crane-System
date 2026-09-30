import 'dart:convert';
import 'dart:typed_data';

import 'package:admin_web/app.dart';
import 'package:admin_web/features/invoices/file_saver.dart';
import 'package:admin_web/features/invoices/invoice_printer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';
import 'package:grua_testing/grua_testing.dart';
import 'package:intl/date_symbol_data_local.dart';

/// Facturación in the panel: the monthly invoice with its NCF, from making it
/// to printing, collecting or voiding it; the switch from test NCFs to the
/// DGII's; and the company's own copy in its portal.
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

  late _FakePrinter printer;
  late _FakeSaver saver;

  /// The text of every sheet of a downloaded workbook.
  String sheets(Uint8List bytes) => [
        for (final e in StoredZip.decode(bytes).entries)
          if (e.key.startsWith('xl/worksheets/')) utf8.decode(e.value),
      ].join();

  Future<void> signIn(
    WidgetTester tester,
    DemoBackend backend, {
    UserRole role = UserRole.admin,
    String email = 'ops@gruasrd.do',
    Size size = const Size(1440, 1800),
  }) async {
    tester.view
      ..devicePixelRatio = 1.0
      ..physicalSize = size;
    addTearDown(tester.view.reset);
    printer = _FakePrinter();
    saver = _FakeSaver();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appConfigProvider.overrideWithValue(config),
          ...demoOverrides(backend: backend, role: role, actingAs: 'admin-1'),
          invoicePrinterProvider.overrideWithValue(printer),
          fileSaverProvider.overrideWithValue(saver),
        ],
        child: const AdminApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, email);
    await tester.enterText(find.byType(TextFormField).last, 'secret123');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Entrar'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
  }

  Future<void> finish(WidgetTester tester, DemoBackend backend) async {
    backend.dispose();
    await tester.pump();
  }

  String location(WidgetTester tester) =>
      GoRouter.of(tester.element(find.byType(Scaffold).first)).state.matchedLocation;

  Future<void> go(WidgetTester tester, String path) async {
    GoRouter.of(tester.element(find.byType(Scaffold).first)).go(path);
    await tester.pumpAndSettle(const Duration(milliseconds: 500));
  }

  Future<void> tap(WidgetTester tester, String key) async {
    await tester.ensureVisible(find.byKey(Key(key)));
    await tester.tap(find.byKey(Key(key)));
    await tester.pumpAndSettle(const Duration(milliseconds: 500));
  }

  DemoBackend seeded() => DemoBackend()
    ..seed()
    ..seedInsurerHistory();

  /// What last month's invoice will hold: the seeded tows finished before
  /// this month began.
  List<Service> billableLastMonth(DemoBackend backend) {
    final start = InvoicePeriod.of(DateTime.now().toUtc()).start;
    return [
      for (final s in backend.servicesToInvoice(insurerId: 'ins-demo'))
        if (s.timeline.completedAt!.isBefore(start)) s,
    ];
  }

  Future<void> generateLastMonth(WidgetTester tester) async {
    await tap(tester, 'generate-invoices');
    // Last month is already chosen, and every company.
    await tap(tester, 'confirm-generate-invoices');
  }

  testWidgets('the office bills last month on a test NCF, prints it and collects it', (tester) async {
    final backend = seeded();
    final billable = billableLastMonth(backend);
    final subtotal = billable.fold<int>(0, (s, x) => s + x.billing!.subtotalCents);
    await signIn(tester, backend);

    await tester.tap(find.text('Facturación'));
    await tester.pumpAndSettle();
    expect(location(tester), '/facturas');
    expect(find.byKey(const Key('ncf-test-mode')), findsOneWidget);
    expect(
      find.descendant(of: find.byKey(const Key('kpi-next-ncf')), matching: find.text('B0100000001')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('to-invoice-ins-demo')), findsOneWidget);
    expect(find.byKey(const Key('invoices-empty')), findsOneWidget);

    await generateLastMonth(tester);
    expect(find.textContaining('B0100000001'), findsWidgets);
    expect(find.textContaining('Se emitió 1 factura con NCF de prueba'), findsOneWidget);

    final invoice = backend.insurerInvoices().single;
    expect(invoice.ncf, 'B0100000001');
    expect(invoice.isTestNcf, isTrue);
    expect(invoice.lines, hasLength(billable.length));
    expect(invoice.subtotalCents, subtotal);
    expect(invoice.totalCents, ZonePricing.withItbis(subtotal).totalCents);

    final row = find.byKey(Key('invoice-row-${invoice.id}'));
    expect(row, findsOneWidget);
    expect(find.descendant(of: row, matching: find.text('NCF DE PRUEBA')), findsOneWidget);
    expect(find.descendant(of: row, matching: find.text('Por cobrar')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('kpi-next-ncf')),
        matching: find.text('B0100000002'),
      ),
      findsOneWidget,
    );

    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(location(tester), '/facturas/${invoice.id}');
    expect(find.text('Factura B0100000001'), findsOneWidget);
    expect(find.byKey(const Key('invoice-test-notice')), findsOneWidget);
    expect(find.text('RNC: En trámite'), findsOneWidget);
    expect(find.text('RNC: 1-30-00000-1'), findsOneWidget);
    for (final s in billable) {
      expect(find.text(s.insurance!.claimNumber), findsOneWidget);
    }
    expect(
      find.descendant(
        of: find.byKey(const Key('invoice-total')),
        matching: find.text(invoice.totalCents.formatDOP),
      ),
      findsOneWidget,
    );

    await tap(tester, 'print-invoice');
    expect(printer.opened.single.id, invoice.id);

    // The same invoice, as a spreadsheet.
    await tap(tester, 'export-invoice-excel');
    final file = saver.saved.single;
    expect(file.name, 'Factura_B0100000001_Seguros-Demo-S-A_${invoice.periodKey}.xlsx');
    expect(file.mimeType, xlsxMimeType);
    expect(find.text('Se descargó ${file.name}.'), findsOneWidget);
    final content = sheets(file.bytes);
    for (final s in billable) {
      expect(content, contains(s.insurance!.claimNumber));
    }
    expect(content, contains('COMPROBANTE DE PRUEBA'));
    expect(content, contains('Tarifa por zonas'));

    // Collecting needs the transfer number.
    await tap(tester, 'pay-invoice');
    await tap(tester, 'confirm-invoice-action');
    expect(find.byKey(const Key('invoice-action-error')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('invoice-reference')), 'TRF-889231');
    await tap(tester, 'confirm-invoice-action');
    expect(find.text('Cobro registrado.'), findsOneWidget);
    expect(backend.insurerInvoice(invoice.id)!.status, InsurerInvoiceStatus.paid);
    expect(find.byKey(const Key('pay-invoice')), findsNothing);
    expect(find.byKey(const Key('void-invoice')), findsNothing);
    expect(find.textContaining('Ref. TRF-889231'), findsOneWidget);
    await finish(tester, backend);
  });

  testWidgets('voiding gives the tows back and the next invoice takes a new number', (tester) async {
    final backend = seeded();
    final billable = billableLastMonth(backend);
    await signIn(tester, backend);
    await go(tester, '/facturas');
    await generateLastMonth(tester);
    final first = backend.insurerInvoices().single;

    await go(tester, '/facturas/${first.id}');
    await tap(tester, 'void-invoice');
    expect(find.textContaining('vuelven a quedar por facturar'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('invoice-void-reason')), 'Precio equivocado');
    await tap(tester, 'confirm-invoice-action');
    expect(backend.insurerInvoice(first.id)!.status, InsurerInvoiceStatus.voided);
    expect(find.textContaining('Precio equivocado'), findsWidgets);
    expect(billableLastMonth(backend), hasLength(billable.length));

    await go(tester, '/facturas');
    await tap(tester, 'invoice-filter-voided');
    expect(find.byKey(Key('invoice-row-${first.id}')), findsOneWidget);
    await tap(tester, 'invoice-filter-issued');
    expect(find.byKey(const Key('invoices-empty')), findsOneWidget);

    await generateLastMonth(tester);
    final second = backend.insurerInvoices().first;
    expect(second.ncf, 'B0100000002');
    expect(second.lines, hasLength(billable.length));
    expect(find.byKey(Key('invoice-row-${second.id}')), findsOneWidget);
    await finish(tester, backend);
  });

  testWidgets('entering the DGII range is all it takes to leave the test NCFs', (tester) async {
    final backend = seeded();
    await signIn(tester, backend);
    await go(tester, '/facturas');
    await tap(tester, 'open-fiscal-settings');
    expect(location(tester), '/facturas/comprobantes');
    expect(
      find.descendant(of: find.byKey(const Key('sequence-next')), matching: find.text('B0100000001')),
      findsOneWidget,
    );
    expect(find.text('Prueba (sin valor fiscal)'), findsOneWidget);

    // The company's details, once the RNC arrives.
    await tester.enterText(find.byKey(const Key('issuer-name')), 'Titan Grúas, SRL');
    await tester.enterText(find.byKey(const Key('issuer-rnc')), '123456789');
    await tap(tester, 'save-issuer');
    expect(find.text('Ese RNC no es válido.'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('issuer-rnc')), '1-01-00157-7');
    await tester.enterText(find.byKey(const Key('issuer-terms')), '15');
    await tap(tester, 'save-issuer');
    expect(backend.fiscalIssuer.name, 'Titan Grúas, SRL');
    expect(backend.fiscalIssuer.rnc, '101001577');
    expect(backend.fiscalIssuer.paymentTermsDays, 15);

    // The range, typed wrong, then right.
    await tester.enterText(find.byKey(const Key('sequence-from')), '1');
    await tester.enterText(find.byKey(const Key('sequence-to')), '500');
    await tester.enterText(find.byKey(const Key('sequence-expires')), '31/12/2020');
    await tap(tester, 'save-real-sequence');
    expect(find.text('Esa fecha ya pasó.'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('sequence-expires')), '2099-12-31');
    await tap(tester, 'save-real-sequence');
    expect(find.text('Escribe la fecha como dd/mm/aaaa.'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('sequence-expires')), '31/12/2099');
    await tester.pumpAndSettle();
    expect(find.text('Primer NCF: B0100000001'), findsOneWidget);
    await tap(tester, 'save-real-sequence');
    expect(find.text('¿Usar la secuencia real?'), findsOneWidget);
    await tap(tester, 'confirm-real-sequence');
    expect(find.textContaining('La próxima factura será B0100000001'), findsOneWidget);

    final sequence = backend.ncfSequence('B01');
    expect(sequence.isTest, isFalse);
    expect(sequence.lastNumber, 500);
    expect(sequence.expiresOn, '2099-12-31');
    expect(find.text('Real, autorizada por la DGII'), findsOneWidget);
    expect(find.text('31/12/2099'), findsWidgets);

    await go(tester, '/facturas');
    expect(find.byKey(const Key('ncf-test-mode')), findsNothing);
    await generateLastMonth(tester);
    final invoice = backend.insurerInvoices().single;
    expect(invoice.ncf, 'B0100000001');
    expect(invoice.isTestNcf, isFalse);
    expect(invoice.ncfExpiresOn, '2099-12-31');
    expect(invoice.issuer.rnc, '101001577');
    expect(
      find.descendant(
        of: find.byKey(Key('invoice-row-${invoice.id}')),
        matching: find.text('NCF DE PRUEBA'),
      ),
      findsNothing,
    );
    await go(tester, '/facturas/${invoice.id}');
    expect(find.byKey(const Key('invoice-test-notice')), findsNothing);
    expect(find.text('Válido hasta: 31/12/2099'), findsOneWidget);
    expect(find.text('RNC: 1-01-00157-7'), findsOneWidget);
    await finish(tester, backend);
  });

  testWidgets('a used-up range stops the invoice and says what to do', (tester) async {
    final backend = seeded()
      ..saveNcfSequence(
        const NcfSequence(
          prefix: 'B01',
          nextNumber: 1,
          lastNumber: 1,
          expiresOn: '2099-12-31',
          isTest: false,
        ),
      )
      // Uses the only number, then more tows finish.
      ..generateInsurerInvoices(actorId: 'admin-1')
      ..seedInsurerHistory();
    await signIn(tester, backend);
    await go(tester, '/facturas');
    expect(find.byKey(const Key('ncf-blocked')), findsOneWidget);
    expect(find.textContaining('Se agotó la secuencia'), findsWidgets);

    await tap(tester, 'invoice-now-ins-demo');
    await tap(tester, 'confirm-generate-invoices');
    expect(find.byKey(const Key('generate-invoices-error')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('generate-invoices-error')),
        matching: find.textContaining('Se agotó'),
      ),
      findsOneWidget,
    );
    await finish(tester, backend);
  });

  testWidgets('a dispatcher reads invoices and settings but changes nothing', (tester) async {
    final backend = seeded()..generateInsurerInvoices(actorId: 'admin-1');
    final invoice = backend.insurerInvoices().single;
    await signIn(tester, backend, role: UserRole.ops);

    await go(tester, '/facturas');
    expect(find.byKey(Key('invoice-row-${invoice.id}')), findsOneWidget);
    expect(find.byKey(const Key('generate-invoices')), findsNothing);
    expect(find.byKey(const Key('invoice-now-ins-demo')), findsNothing);

    await go(tester, '/facturas/${invoice.id}');
    expect(find.byKey(const Key('print-invoice')), findsOneWidget);
    expect(find.byKey(const Key('pay-invoice')), findsNothing);
    expect(find.byKey(const Key('void-invoice')), findsNothing);
    // Reading includes taking a copy.
    await tap(tester, 'export-invoice-excel');
    expect(saver.saved, hasLength(1));

    await go(tester, '/facturas/comprobantes');
    expect(find.text('Solo un administrador puede cambiar estos datos.'), findsOneWidget);
    expect(find.byKey(const Key('save-issuer')), findsNothing);
    expect(find.byKey(const Key('save-real-sequence')), findsNothing);

    await go(tester, '/facturas/nope');
    expect(find.byKey(const Key('invoice-missing')), findsOneWidget);
    await finish(tester, backend);
  });

  testWidgets('a company manager reads and prints its own invoices', (tester) async {
    final backend = seeded()..generateInsurerInvoices(actorId: 'admin-1');
    final invoice = backend.insurerInvoices().single;
    await signIn(tester, backend, email: 'marta@segurosdemo.do');

    await tap(tester, 'portal-nav-/portal/facturas');
    expect(location(tester), '/portal/facturas');
    expect(
      find.descendant(
        of: find.byKey(const Key('portal-kpi-owed')),
        matching: find.text(invoice.totalCents.formatDOP),
      ),
      findsOneWidget,
    );
    await tap(tester, 'invoice-row-${invoice.id}');
    expect(location(tester), '/portal/facturas/${invoice.id}');
    expect(find.text('Factura B0100000001'), findsOneWidget);
    expect(find.byKey(const Key('invoice-test-notice')), findsOneWidget);
    expect(find.byKey(const Key('pay-invoice')), findsNothing);
    await tap(tester, 'print-invoice');
    expect(printer.opened.single.id, invoice.id);
    await tap(tester, 'export-invoice-excel');
    expect(sheets(saver.saved.single.bytes), contains('Seguros Demo, S.A.'));
    await finish(tester, backend);
  });

  testWidgets('the office exports the invoices it is looking at', (tester) async {
    final backend = seeded()..generateInsurerInvoices(actorId: 'admin-1');
    final first = backend.insurerInvoices().single;
    backend
      ..voidInsurerInvoice(first.id, reason: 'Precio equivocado')
      ..generateInsurerInvoices(actorId: 'admin-1');
    final second = backend.insurerInvoices().first;
    await signIn(tester, backend);
    await go(tester, '/facturas');

    await tap(tester, 'export-invoices-excel');
    final all = saver.saved.single;
    expect(all.name, InvoiceWorkbook.listFileName(DateTime.now().toUtc()));
    expect(find.textContaining('con 2 factura(s)'), findsOneWidget);
    final both = sheets(all.bytes);
    expect(both, contains(first.ncf));
    expect(both, contains(second.ncf));
    expect(both, contains('Anulada'));

    // Only what the filter shows.
    await tap(tester, 'invoice-filter-issued');
    await tap(tester, 'export-invoices-excel');
    final issued = sheets(saver.saved.last.bytes);
    expect(issued, contains('B0100000002'));
    expect(issued, isNot(contains('B0100000001')));
    expect(issued, contains('Por cobrar'));

    // Nothing to export, nothing to press.
    await tap(tester, 'invoice-filter-paid');
    final button = tester.widget<ButtonStyleButton>(
      find.byKey(const Key('export-invoices-excel')),
    );
    expect(button.onPressed, isNull);
    await finish(tester, backend);
  });

  testWidgets('an operator has no invoices page', (tester) async {
    final backend = seeded()..generateInsurerInvoices(actorId: 'admin-1');
    final invoice = backend.insurerInvoices().single;
    await signIn(tester, backend, email: 'restrepo@segurosdemo.do');

    expect(find.byKey(const Key('portal-nav-/portal/facturas')), findsNothing);
    await go(tester, '/portal/facturas');
    expect(location(tester), '/portal');
    await go(tester, '/portal/facturas/${invoice.id}');
    expect(location(tester), '/portal');
    // Nor the office's pages.
    await go(tester, '/facturas');
    expect(location(tester), '/portal');
    await finish(tester, backend);
  });

  testWidgets('every invoice page fits the narrowest screen', (tester) async {
    final backend = seeded()..generateInsurerInvoices(actorId: 'admin-1');
    final invoice = backend.insurerInvoices().single;
    await signIn(tester, backend, size: const Size(1024, 768));

    for (final path in ['/facturas', '/facturas/${invoice.id}', '/facturas/comprobantes']) {
      await go(tester, path);
      expect(location(tester), path);
      expect(tester.takeException(), isNull, reason: path);
    }
    await finish(tester, backend);
  });
}

class _FakeSaver implements FileSaver {
  final saved = <({Uint8List bytes, String name, String mimeType})>[];

  @override
  bool save(Uint8List bytes, {required String fileName, required String mimeType}) {
    saved.add((bytes: bytes, name: fileName, mimeType: mimeType));
    return true;
  }
}

class _FakePrinter implements InvoicePrinter {
  final opened = <InsurerInvoice>[];

  @override
  bool open(InsurerInvoice invoice) {
    opened.add(invoice);
    return true;
  }
}

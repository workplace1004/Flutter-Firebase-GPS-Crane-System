import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';
import 'package:grua_testing/grua_testing.dart';
import 'package:intl/date_symbol_data_local.dart';

/// Monthly invoices with NCF: the arithmetic the server also runs, the page
/// that gets printed, the demo backend the screens are built on, and the
/// chofer's balance.
void main() {
  setUpAll(() => initializeDateFormatting('es_DO'));

  final fixture = jsonDecode(
    File('test/fixtures/insurer_invoice_cases.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  List<Map<String, dynamic>> cases(String key) =>
      (fixture[key] as List<dynamic>).cast<Map<String, dynamic>>();
  DateTime at(Object? iso) => DateTime.parse(iso! as String);

  group('Ncf', () {
    for (final c in cases('ncf')) {
      test('${c['prefix']} + ${c['sequence']} is ${c['ncf']}', () {
        expect(Ncf.format(c['prefix'] as String, c['sequence'] as int), c['ncf']);
        final parsed = Ncf.parse(c['ncf'] as String)!;
        expect(parsed.prefix, c['prefix']);
        expect(parsed.sequence, c['sequence']);
      });
    }

    for (final bad in (fixture['badNcf'] as List<dynamic>).cast<String>()) {
      test('"$bad" is not an NCF', () => expect(Ncf.parse(bad), isNull));
    }

    test('refuses a number outside the eight digits', () {
      expect(() => Ncf.format('B01', 0), throwsRangeError);
      expect(() => Ncf.format('B01', 100000000), throwsRangeError);
    });

    for (final c in cases('sequences')) {
      test(c['name'] as String, () {
        final s = c['sequence'] as Map<String, dynamic>;
        final sequence = NcfSequence(
          prefix: 'B01',
          nextNumber: s['nextNumber'] as int,
          lastNumber: s['lastNumber'] as int,
          expiresOn: s['expiresOn'] as String?,
          isTest: false,
        );
        expect(Ncf.problem(sequence, at(c['now'])) != null, c['blocked']);
        expect(sequence.remaining, c['remaining']);
      });
    }

    test('starts on test numbers, B0100000001 first', () {
      final sequence = NcfSequence.fromJson('B01', null);
      expect(sequence.isTest, isTrue);
      expect(Ncf.next(sequence), 'B0100000001');
      // A stored range is a test one unless it says otherwise.
      expect(
        NcfSequence.fromJson('B01', const {'nextNumber': 5, 'lastNumber': 9}).isTest,
        isTrue,
      );
      expect(
        NcfSequence.fromJson('B01', const {'nextNumber': 5, 'lastNumber': 9, 'isTest': false})
            .isTest,
        isFalse,
      );
      expect(Ncf.registryKey('B0100000001', isTest: true), 'TEST-B0100000001');
      expect(Ncf.registryKey('B0100000001', isTest: false), 'B0100000001');
    });

    test('a hand-edited expiry that is not a date does not break the page', () {
      const odd = NcfSequence(
        prefix: 'B01',
        nextNumber: 1,
        lastNumber: 5,
        expiresOn: '31/12/2027',
        isTest: false,
      );
      expect(Ncf.expiryInstant('31/12/2027'), isNull);
      expect(Ncf.problem(odd, DateTime.utc(2030)), isNull);
    });

    test('bills the zone price, or the quote when the zone price is missing', () {
      Service tow({int? billed}) => Service(
            id: 'x',
            clientId: '',
            pickup: const ServiceLocation(geo: DoLocations.santoDomingo),
            quote: const Quote(subtotalCents: 300000),
            billing: billed == null ? null : InsurerBilling(subtotalCents: billed),
          );
      expect(tow(billed: 250000).billedSubtotalCents, 250000);
      expect(tow(billed: 0).billedSubtotalCents, 300000);
      expect(tow().billedSubtotalCents, 300000);
    });

    test('knows a real day', () {
      expect(Ncf.isIsoDay('2027-12-31'), isTrue);
      expect(Ncf.isIsoDay('2027-02-30'), isFalse);
      expect(Ncf.isIsoDay('31/12/2027'), isFalse);
    });
  });

  group('InvoicePeriod', () {
    for (final c in cases('periods')) {
      test('${c['key']} runs from ${c['start']}', () {
        final period = InvoicePeriod.parse(c['key'] as String);
        expect(period.start, at(c['start']));
        expect(period.end, at(c['end']));
        expect(period.label, c['label']);
        expect(period.key, c['key']);
      });
    }

    for (final c in cases('periodOf')) {
      test('${c['instant']} is in ${c['key']}', () {
        final period = InvoicePeriod.of(at(c['instant']));
        expect(period.key, c['key']);
        expect(period.previous.key, c['previous']);
      });
    }

    test('refuses what is not a month, and lists the recent ones', () {
      for (final bad in ['2026-13', '2026-00', '2026-9', '']) {
        expect(InvoicePeriod.isKey(bad), isFalse);
      }
      expect(() => InvoicePeriod.parse('2026-13'), throwsFormatException);
      expect(
        InvoicePeriod.recent(DateTime.utc(2026, 2, 10), count: 3).map((p) => p.key),
        ['2026-02', '2026-01', '2025-12'],
      );
      expect(const InvoicePeriod(2026, 9).title, 'Septiembre 2026');
    });

    for (final c in cases('due')) {
      test('issued ${c['issuedAt']} on ${c['termsDays']} days is due ${c['dueAt']}', () {
        expect(
          InsurerInvoiceMath.dueDate(at(c['issuedAt']), c['termsDays'] as int),
          at(c['dueAt']),
        );
      });
    }
  });

  group('InsurerInvoiceMath.draft', () {
    for (final c in cases('invoices')) {
      test(c['name'] as String, () {
        final services = [
          for (final s in (c['services'] as List<dynamic>).cast<Map<String, dynamic>>())
            InvoiceableService(
              serviceId: s['id'] as String,
              status: ServiceStatus.fromWire(s['status'] as String),
              finishedAt: s['finishedAt'] == null ? null : at(s['finishedAt']),
              subtotalCents: s['subtotalCents'] as int,
              feeCents: s['feeCents'] as int,
            ),
        ];
        final draft = InsurerInvoiceMath.draft(
          services,
          cutoff: at(c['cutoff']),
          maxLines: c['maxLines'] as int? ?? InsurerInvoiceMath.maxLines,
        );
        final want = c['expect'] as Map<String, dynamic>?;
        if (want == null) {
          expect(draft, isNull);
          return;
        }
        expect(draft!.serviceIds, want['lines']);
        expect(draft.kinds.map((k) => k.wire), want['kinds']);
        expect(draft.amounts, want['amounts']);
        expect(draft.towCount, want['towCount']);
        expect(draft.cancellationCount, want['cancellationCount']);
        expect(draft.totals.subtotalCents, want['subtotalCents']);
        expect(draft.totals.itbisCents, want['itbisCents']);
        expect(draft.totals.totalCents, want['totalCents']);
        expect(draft.leftover, want['leftover']);
      });
    }
  });

  group('InsurerInvoice', () {
    test('reads the document the callable writes', () {
      final invoice = InsurerInvoice.fromJson('fac-1', {
        'insurerId': 'ins-a',
        'insurerName': 'Seguros Universal',
        'insurerRnc': '101001577',
        'periodKey': '2026-09',
        'periodLabel': 'septiembre 2026',
        'ncf': 'B0100000001',
        'ncfType': '01',
        'isTestNcf': true,
        'ncfExpiresOn': null,
        'issuer': const {'name': 'GRÚAS RD, SRL (en constitución)', 'rnc': ''},
        'lines': [
          {
            'serviceId': 'a1',
            'kind': 'tow',
            'amountCents': 250000,
            'serviceCode': 'GR-a1',
            'finishedAt': DateTime.utc(2026, 9, 2, 15),
            'claimNumber': 'SIN-1',
            'zoneLabel': '0–10 km',
            'vehicleClass': 'Vehículo ligero',
          },
          const {'serviceId': 'a2', 'kind': 'cancellation', 'amountCents': 50000},
        ],
        'towCount': 1,
        'cancellationCount': 1,
        'subtotalCents': 300000,
        'itbisCents': 54000,
        'totalCents': 354000,
        'status': 'issued',
        'paymentTermsDays': 30,
        'dueAt': DateTime.utc(2026, 11, 1, 3, 59, 59),
      });

      expect(invoice.displayNcf, 'B01-00000001');
      expect(invoice.isTestNcf, isTrue);
      expect(invoice.ncfType, NcfType.creditoFiscal);
      expect(invoice.issuer.rncLabel, 'En trámite');
      expect(formatRnc(invoice.insurerRnc), '1-01-00157-7');
      expect(invoice.lines.first.description, 'Servicio de grúa · 0–10 km · Vehículo ligero');
      expect(invoice.lines.last.description, 'Cargo por cancelación');
      expect(invoice.isOverdueAt(DateTime.utc(2026, 10, 15)), isFalse);
      expect(invoice.isOverdueAt(DateTime.utc(2026, 11, 2)), isTrue);
      // A document that does not say is shown as a test one.
      expect(InsurerInvoice.fromJson('x', const {}).isTestNcf, isTrue);
    });
  });

  group('InvoiceDocument', () {
    InsurerInvoice sample({
      bool test = true,
      InsurerInvoiceStatus status = InsurerInvoiceStatus.issued,
      String insuredName = 'Juan Pérez',
    }) =>
        InsurerInvoice(
          id: 'fac-1',
          insurerId: 'ins-a',
          ncf: 'B0100000007',
          insurerName: 'Seguros <Universal> & Co.',
          insurerRnc: '101001577',
          periodKey: '2026-09',
          periodLabel: 'septiembre 2026',
          isTestNcf: test,
          ncfExpiresOn: test ? null : '2027-12-31',
          issuer: const InvoiceIssuer(name: 'Titan Grúas, SRL', rnc: '130000001'),
          lines: [
            InsurerInvoiceLine(
              serviceId: 'a1',
              kind: InsurerInvoiceLineKind.tow,
              amountCents: 250000,
              serviceCode: 'GR-260902-AB12',
              finishedAt: DateTime.utc(2026, 9, 2, 15),
              claimNumber: 'SIN-2024-001489',
              insuredName: insuredName,
              plate: 'G123456',
              vehicle: 'Toyota Corolla',
              zoneLabel: '0–10 km',
            ),
          ],
          towCount: 1,
          subtotalCents: 250000,
          itbisCents: 45000,
          totalCents: 295000,
          status: status,
          dueAt: DateTime.utc(2026, 11, 1, 3, 59),
          issuedAt: DateTime.utc(2026, 10, 1, 10),
          paidAt: status == InsurerInvoiceStatus.paid ? DateTime.utc(2026, 10, 20, 15) : null,
          paymentReference: status == InsurerInvoiceStatus.paid ? 'TRF-889231' : '',
          voidReason: status == InsurerInvoiceStatus.voided ? 'Precio equivocado' : '',
        );

    test('prints the NCF, both parties, every line and the foot', () {
      final html = InvoiceDocument.html(sample(test: false));
      expect(html, contains('NCF: B0100000007'));
      expect(html, contains('Válido hasta: 31/12/2027'));
      expect(html, contains('Titan Grúas, SRL'));
      expect(html, contains('RNC: 1-30-00000-1'));
      expect(html, contains('RNC: 1-01-00157-7'));
      expect(html, contains('SIN-2024-001489'));
      expect(html, contains('02/09/2026'));
      expect(html, contains('Fecha de emisión: 01/10/2026'));
      expect(html, contains('Fecha de vencimiento: 31/10/2026'));
      expect(html, contains(250000.formatDOP));
      expect(html, contains(45000.formatDOP));
      expect(html, contains(295000.formatDOP));
      expect(html, isNot(contains('PRUEBA')));
      expect(InvoiceDocument.fileTitle(sample()), 'Factura B0100000007 Seguros <Universal> & Co. 2026-09');
    });

    test('says loudly when the NCF is a test one', () {
      final html = InvoiceDocument.html(sample());
      expect(html, contains('COMPROBANTE DE PRUEBA — SIN VALOR FISCAL'));
      expect(html, contains('is_test_ncf'));
      expect(html, contains('Válido hasta: N/A (prueba)'));
    });

    test('marks a paid and a voided invoice', () {
      expect(
        InvoiceDocument.html(sample(status: InsurerInvoiceStatus.paid)),
        contains('PAGADA el 20/10/2026 · Ref. TRF-889231'),
      );
      expect(
        InvoiceDocument.html(sample(status: InsurerInvoiceStatus.voided)),
        contains('FACTURA ANULADA: Precio equivocado'),
      );
    });

    test('escapes everything it did not write itself', () {
      final html = InvoiceDocument.html(
        sample(insuredName: '<script>alert("x")</script>'),
      );
      expect(html, isNot(contains('<script>')));
      expect(html, contains('&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt;'));
      expect(html, contains('Seguros &lt;Universal&gt; &amp; Co.'));
    });
  });

  group('the demo backend', () {
    // 1 October 2026, 6:00 in Santo Domingo.
    var now = DateTime.utc(2026, 10, 1, 10);
    late DemoBackend backend;

    setUp(() {
      now = DateTime.utc(2026, 10, 1, 10);
      backend = DemoBackend(clock: () => now)
        ..seed()
        ..seedInsurerHistory();
    });
    tearDown(() => backend.dispose());

    test('invoices September on test NCFs and bills each tow once', () {
      final waiting = backend.servicesToInvoice(insurerId: 'ins-demo');
      expect(waiting, hasLength(5));

      final run = backend.generateInsurerInvoices(actorId: 'admin-1').valueOrNull!;
      expect(run.periodKey, '2026-09');
      expect(run.failed, isEmpty);
      expect(run.created.single.ncf, 'B0100000001');
      expect(run.created.single.isTestNcf, isTrue);

      final invoice = backend.insurerInvoice(run.created.single.invoiceId)!;
      // The tow finished five hours ago is October's.
      expect(invoice.lines, hasLength(4));
      expect(invoice.subtotalCents, 250000 + 450000 + 1100000 + 698000);
      expect(invoice.itbisCents, Money.itbis(invoice.subtotalCents));
      expect(invoice.totalCents, invoice.subtotalCents + invoice.itbisCents);
      expect(invoice.issuer.name, FiscalIssuer.defaultName);
      expect(invoice.insurerRnc, '130000001');
      expect(invoice.lines.first.claimNumber, 'SIN-2026-001201');
      expect(invoice.lines.first.vehicle, 'Toyota Corolla');
      expect(invoice.lines.first.tariffLabel, 'Base');
      expect(invoice.lines.first.baseCents, 250000);
      // The price list it was billed on, every class, for the spreadsheet.
      expect(invoice.tariffTable, hasLength(ZonePricing.defaultRules.length));
      expect(invoice.tariffTable.first.zoneLabel, '0–10 km');
      expect(invoice.tariffTable.last.extraKmCents, 25000);
      expect(invoice.dueAt, DateTime.utc(2026, 11, 1, 3, 59, 59, 999));
      for (final line in invoice.lines) {
        final s = backend.service(line.serviceId)!;
        expect(s.invoiceId, invoice.id);
        expect(s.payment.status, PaymentStatus.invoiced);
      }
      expect(backend.servicesToInvoice(insurerId: 'ins-demo'), hasLength(1));

      final again = backend.generateInsurerInvoices(actorId: 'admin-1').valueOrNull!;
      expect(again.created, isEmpty);
      expect(backend.ncfSequence('B01').nextNumber, 2);
    });

    test('numbers from the real range once it is entered, and stops at its end', () {
      backend.generateInsurerInvoices(actorId: 'admin-1');
      expect(
        backend
            .saveNcfSequence(
              const NcfSequence(
                prefix: 'B01',
                nextNumber: 1,
                lastNumber: 1,
                expiresOn: '2027-12-31',
                isTest: false,
              ),
            )
            .valueOrNull,
        'B0100000001',
      );

      final current = backend
          .generateInsurerInvoices(actorId: 'admin-1', periodKey: '2026-10')
          .valueOrNull!;
      expect(current.created.single.ncf, 'B0100000001');
      expect(current.created.single.isTestNcf, isFalse);
      expect(backend.insurerInvoice(current.created.single.invoiceId)!.ncfExpiresOn, '2027-12-31');

      // The real B0100000001 is used now.
      final reused = backend.saveNcfSequence(
        const NcfSequence(
          prefix: 'B01',
          nextNumber: 1,
          lastNumber: 5,
          expiresOn: '2027-12-31',
          isTest: false,
        ),
      );
      expect(reused.failureOrNull?.code, FailureCode.ncfUnavailable);

      // The range is used up: the next invoice is refused and says why.
      final voided = backend.voidInsurerInvoice(
        current.created.single.invoiceId,
        reason: 'Probar',
      );
      expect(voided.isOk, isTrue);
      final exhausted = backend.generateInsurerInvoices(
        actorId: 'admin-1',
        insurerId: 'ins-demo',
        periodKey: '2026-10',
      );
      expect(exhausted.failureOrNull?.code, FailureCode.ncfUnavailable);
      expect(exhausted.failureOrNull?.message, contains('Se agotó'));
    });

    test('refuses a real range without expiry, or already expired', () {
      NcfSequence real({String? expiresOn}) => NcfSequence(
            prefix: 'B01',
            nextNumber: 1,
            lastNumber: 5,
            expiresOn: expiresOn,
            isTest: false,
          );
      expect(backend.saveNcfSequence(real()).failureOrNull?.message, contains('vencimiento'));
      expect(
        backend.saveNcfSequence(real(expiresOn: '2026-09-30')).failureOrNull?.message,
        contains('ya pasó'),
      );
      expect(
        backend
            .saveNcfSequence(
              const NcfSequence(prefix: 'B01', nextNumber: 9, lastNumber: 3, isTest: true),
            )
            .failureOrNull
            ?.message,
        contains('mayor'),
      );
    });

    test('voids an unpaid invoice and bills its tows on a new number; a paid one stays', () {
      final first = backend.generateInsurerInvoices(actorId: 'admin-1').valueOrNull!;
      final id = first.created.single.invoiceId;
      expect(backend.voidInsurerInvoice(id, reason: '').failureOrNull?.code, FailureCode.invalidInput);
      expect(backend.voidInsurerInvoice(id, reason: 'Precio equivocado').isOk, isTrue);
      expect(backend.insurerInvoice(id)!.status, InsurerInvoiceStatus.voided);
      expect(backend.servicesToInvoice(insurerId: 'ins-demo'), hasLength(5));

      final second = backend.generateInsurerInvoices(actorId: 'admin-1').valueOrNull!;
      expect(second.created.single.ncf, 'B0100000002');
      final secondId = second.created.single.invoiceId;

      expect(backend.markInsurerInvoicePaid(secondId, reference: '').isErr, isTrue);
      expect(backend.markInsurerInvoicePaid(secondId, reference: 'TRF-1234').isOk, isTrue);
      final paid = backend.insurerInvoice(secondId)!;
      expect(paid.status, InsurerInvoiceStatus.paid);
      expect(paid.paymentReference, 'TRF-1234');
      expect(
        backend.voidInsurerInvoice(secondId, reason: 'error').failureOrNull?.message,
        contains('nota de crédito'),
      );
      expect(backend.markInsurerInvoicePaid(secondId, reference: 'TRF-9').isErr, isTrue);
    });

    test('prints the issuer the office entered, with its terms', () {
      expect(
        backend.saveFiscalIssuer(const FiscalIssuer(name: 'Titan', rnc: '123')).failureOrNull?.message,
        contains('RNC'),
      );
      expect(
        backend
            .saveFiscalIssuer(
              const FiscalIssuer(name: 'Titan Grúas, SRL', rnc: '1-01-00157-7', paymentTermsDays: 15),
            )
            .isOk,
        isTrue,
      );
      expect(backend.fiscalIssuer.rnc, '101001577');
      final run = backend.generateInsurerInvoices(actorId: 'admin-1').valueOrNull!;
      final invoice = backend.insurerInvoice(run.created.single.invoiceId)!;
      expect(invoice.issuer.name, 'Titan Grúas, SRL');
      expect(invoice.issuer.rnc, '101001577');
      expect(invoice.paymentTermsDays, 15);
      expect(invoice.dueAt, DateTime.utc(2026, 10, 17, 3, 59, 59, 999));
    });

    test('refuses a month that has not started, and a company that does not exist', () {
      expect(
        backend.generateInsurerInvoices(actorId: 'a', periodKey: '2026-11').failureOrNull?.message,
        contains('no ha empezado'),
      );
      expect(
        backend.generateInsurerInvoices(actorId: 'a', insurerId: 'nope').failureOrNull?.code,
        FailureCode.notFound,
      );
      expect(
        backend.generateInsurerInvoices(actorId: 'a', periodKey: '2026-9').failureOrNull?.code,
        FailureCode.invalidInput,
      );
    });

    test('bills a late cancellation by the company', () {
      final service = backend.createInsurerService(
        insurerId: 'ins-demo',
        insurerName: 'Seguros Demo, S.A.',
        requestedBy: 'insurer-operator-1',
        pickup: const ServiceLocation(geo: DoLocations.santoDomingo),
        dropoff: const ServiceLocation(geo: DoLocations.santoDomingo),
        vehicle: const ServiceVehicle(),
        insurance: const InsuranceClaim(claimNumber: 'SIN-LATE'),
      );
      final assigned = ['driver-1', 'driver-2', 'driver-3', 'driver-4', 'driver-5'].any(
        (d) => backend.assignServiceManually(serviceId: service.id, driverId: d) == null,
      );
      expect(assigned, isTrue, reason: 'a seeded chofer takes it');
      now = now.add(const Duration(minutes: 30));
      expect(backend.cancelByInsurer('insurer-operator-1', service.id).isOk, isTrue);
      final cancelled = backend.service(service.id)!;
      expect(cancelled.cancellation!.feeCents, const PricingConfig().cancellationFeeCents);
      expect(cancelled.payment.status, PaymentStatus.toInvoice);
      now = now.add(const Duration(minutes: 1));

      final run = backend
          .generateInsurerInvoices(actorId: 'admin-1', periodKey: '2026-10')
          .valueOrNull!;
      final invoice = backend.insurerInvoice(run.created.single.invoiceId)!;
      expect(
        invoice.lines.where((l) => l.isCancellation).single.amountCents,
        const PricingConfig().cancellationFeeCents,
      );
    });

    test('feeds the office and the company through the repositories', () async {
      final container = ProviderContainer(
        overrides: demoOverrides(backend: backend, role: UserRole.admin, actingAs: 'admin-1'),
      );
      addTearDown(container.dispose);
      final gateway = container.read(functionsGatewayProvider);
      final repo = container.read(insurerRepositoryProvider);

      expect(await repo.watchServicesToInvoice().first, hasLength(5));
      expect((await repo.watchNcfSequence('B01').first).isTest, isTrue);
      expect((await repo.watchFiscalIssuer().first).name, FiscalIssuer.defaultName);

      final run = (await gateway.generateInsurerInvoices()).valueOrNull!;
      final id = run.created.single.invoiceId;
      expect((await repo.watchInvoices().first).single.id, id);
      expect((await repo.watchInvoices(insurerId: 'ins-demo').first).single.id, id);
      expect(await repo.watchInvoices(insurerId: 'other').first, isEmpty);
      expect((await repo.watchInvoice(id).first)!.ncf, 'B0100000001');

      expect((await gateway.markInsurerInvoicePaid(invoiceId: id, reference: 'TRF-77')).isOk, isTrue);
      expect(
        (await gateway.saveNcfSequence(
          const NcfSequence(prefix: 'B01', nextNumber: 20, lastNumber: 30, isTest: true),
        ))
            .valueOrNull,
        'B0100000020',
      );
      expect(
        (await gateway.saveFiscalIssuer(const FiscalIssuer(name: 'Titan, SRL'))).isOk,
        isTrue,
      );
      expect((await repo.watchFiscalIssuer().first).name, 'Titan, SRL');
      expect((await gateway.voidInsurerInvoice(invoiceId: id, reason: 'x y z')).isErr, isTrue);
    });
  });

  group('DriverBalance', () {
    DriverSettlement corte(String id, int balance, SettlementStatus status, DateTime payBy) =>
        DriverSettlement(
          id: id,
          driverId: 'carlos',
          finalBalanceCents: balance,
          direction: SettlementDirection.ofBalance(balance),
          status: status,
          payBy: payBy,
        );

    test('adds the unpaid cortes to this week so far', () {
      final running = SettlementMath.draft(
        [
          EarningEntry(
            serviceId: 'ins',
            driverId: 'carlos',
            method: PaymentMethod.insurer,
            grossCents: 250000,
            netCents: 175000,
            completedAt: DateTime.utc(2026, 9, 14, 15),
          ),
          EarningEntry(
            serviceId: 'cash',
            driverId: 'carlos',
            grossCents: 400000,
            commissionCents: 80000,
            netCents: 320000,
            completedAt: DateTime.utc(2026, 9, 15, 15),
          ),
        ],
        cutoff: DateTime.utc(2026, 9, 16),
      );
      final balance = DriverBalance.of(
        settlements: [
          corte('paid', 999900, SettlementStatus.settled, DateTime.utc(2026, 9, 4, 21)),
          corte('late', 625000, SettlementStatus.pending, DateTime.utc(2026, 9, 11, 21)),
          corte('older', -180000, SettlementStatus.pending, DateTime.utc(2026, 9, 4, 21)),
          corte('void', 50000, SettlementStatus.voided, DateTime.utc(2026, 9, 4, 21)),
        ],
        running: running,
      );
      // Carlos's 6,250 − 1,800 still unpaid, plus 1,750 − 800 this week.
      expect(balance.pendingCents, 445000);
      expect(balance.runningCents, 95000);
      expect(balance.totalCents, 540000);
      expect(balance.direction, SettlementDirection.toDriver);
      expect(balance.pending.map((s) => s.id), ['late', 'older']);
      expect(balance.nextPayBy, DateTime.utc(2026, 9, 4, 21));
    });

    test('is nothing when nothing is owed', () {
      final balance = DriverBalance.of(settlements: const []);
      expect(balance.totalCents, 0);
      expect(balance.direction, SettlementDirection.none);
      expect(balance.nextPayBy, isNull);
    });
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';

/// The weekly corte, on the examples the server also runs.
void main() {
  final fixture = jsonDecode(
    File('test/fixtures/settlement_cases.json').readAsStringSync(),
  ) as Map<String, dynamic>;

  DateTime? time(Object? iso) => iso == null ? null : DateTime.parse(iso as String);

  group('SettlementMath.draft', () {
    for (final raw in fixture['cases'] as List<dynamic>) {
      final c = raw as Map<String, dynamic>;
      test(c['name'] as String, () {
        final entries = <EarningEntry>[];
        final counted = <String>{};
        for (final e in (c['entries'] as List<dynamic>).cast<Map<String, dynamic>>()) {
          entries.add(
            EarningEntry(
              serviceId: e['serviceId'] as String,
              driverId: 'carlos',
              method: PaymentMethod.fromWire(e['method'] as String),
              grossCents: e['grossCents'] as int,
              commissionCents: e['commissionCents'] as int,
              netCents: e['netCents'] as int,
              completedAt: time(e['completedAt']),
            ),
          );
          if (e['countedInCashCorte'] == true) counted.add(e['serviceId'] as String);
        }

        final draft = SettlementMath.draft(
          entries,
          cutoff: time(c['cutoff'])!,
          startAt: time(c['startAt']),
          countedInCashCorte: counted,
        );

        final expected = c['expected'] as Map<String, dynamic>?;
        if (expected == null) {
          expect(draft, isNull);
          return;
        }
        expect(draft, isNotNull);
        expect(draft!.insuranceOwedCents, expected['insuranceOwedCents']);
        expect(draft.commissionOwedCents, expected['commissionOwedCents']);
        expect(draft.finalBalanceCents, expected['finalBalanceCents']);
        expect(draft.direction.wire, expected['direction']);
        expect(draft.lines.map((l) => l.serviceId), expected['lineIds']);
        expect(draft.lines.map((l) => l.amountCents), expected['lineAmounts']);
        expect(draft.periodStart, time(expected['periodStart']));
        expect(draft.retiredServiceIds, expected['retired']);
        expect(draft.ignoredServiceIds, expected['ignored']);
      });
    }
  });

  group('SettlementMath.payBy', () {
    for (final raw in fixture['payBy'] as List<dynamic>) {
      final c = raw as Map<String, dynamic>;
      test('a corte made ${c['from']} is paid by ${c['payBy']}', () {
        expect(SettlementMath.payBy(time(c['from'])!), time(c['payBy']));
      });
    }
  });

  group('DriverSettlement.fromJson', () {
    DriverSettlement carlos() => DriverSettlement.fromJson('s-1', {
          'driverId': 'carlos',
          'driverName': 'Carlos',
          'truckPlate': 'Grúa 07',
          'periodStart': Timestamp.fromDate(DateTime.utc(2024, 9, 2, 13)),
          'periodEnd': Timestamp.fromDate(DateTime.utc(2024, 9, 6, 12)),
          'lines': const [
            {'serviceId': 'ins-1', 'serviceCode': 'GR-1', 'kind': 'insurer', 'grossCents': 350000, 'amountCents': 245000},
            {'serviceId': 'cash-1', 'serviceCode': 'GR-2', 'kind': 'cash', 'grossCents': 400000, 'amountCents': 80000},
            {'serviceId': 'x', 'kind': 'refund', 'amountCents': 1},
          ],
          'insuranceOwedCents': 805000,
          'commissionOwedCents': 180000,
          'finalBalanceCents': 625000,
          'direction': 'to_driver',
          'status': 'pending',
          'payBy': Timestamp.fromDate(DateTime.utc(2024, 9, 6, 21)),
        });

    test('reads a corte and splits its sections', () {
      final s = carlos();
      expect(s.driverName, 'Carlos');
      expect(s.insurerLines.single.amountCents, 245000);
      expect(s.cashLines.single.amountCents, 80000);
      expect(s.lines.last.kind, SettlementLineKind.unknown);
      expect(s.isPending, isTrue);
      expect(s.titanPays, isTrue);
      expect(s.driverPays, isFalse);
      expect(s.amountCents, 625000);
      expect(s.payBy, DateTime.utc(2024, 9, 6, 21));
      expect(s.balanceHeadline, contains('a favor del conductor'));
      expect(s.balanceHeadline, contains(625000.formatDOP));
    });

    test('a negative balance is the chofer paying, shown without a sign', () {
      final s = DriverSettlement.fromJson('s-2', const {
        'driverId': 'pedro',
        'finalBalanceCents': -180000,
        'direction': 'to_company',
        'status': 'pending',
      });
      expect(s.driverPays, isTrue);
      expect(s.amountCents, 180000);
      expect(s.balanceHeadline, contains('a favor de Drakegruas'));
      expect(s.balanceHeadline, isNot(contains('-')));
    });

    test('an empty or odd record reads without throwing', () {
      final s = DriverSettlement.fromJson('s-3', const {'status': 'archived'});
      expect(s.status, SettlementStatus.unknown);
      expect(s.direction, SettlementDirection.unknown);
      expect(s.lines, isEmpty);
      expect(s.isPending, isFalse);
    });
  });

  test('the collection name matches the backend', () {
    expect(Paths.driverSettlementsCollection, 'driverSettlements');
  });
}

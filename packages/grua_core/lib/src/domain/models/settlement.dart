import 'package:flutter/foundation.dart';

import '../../data/converters.dart';
import '../../utils/money.dart';
import '../enums.dart';

/// One job in a weekly corte.
@immutable
class SettlementLine {
  const SettlementLine({
    required this.serviceId,
    required this.kind,
    required this.amountCents,
    this.serviceCode = '',
    this.grossCents = 0,
    this.completedAt,
  });

  factory SettlementLine.fromJson(Map<String, dynamic> json) => SettlementLine(
        serviceId: json['serviceId'] as String? ?? '',
        serviceCode: json['serviceCode'] as String? ?? '',
        kind: json['kind'] == 'insurer'
            ? SettlementLineKind.insurer
            : json['kind'] == 'cash'
                ? SettlementLineKind.cash
                : SettlementLineKind.unknown,
        grossCents: (json['grossCents'] as num? ?? 0).round(),
        amountCents: (json['amountCents'] as num? ?? 0).round(),
        completedAt:
            const NullableTimestampConverter().fromJson(json['completedAt']),
      );

  final String serviceId;
  final String serviceCode;
  final SettlementLineKind kind;

  /// What the job was worth: "Monto servicio".
  final int grossCents;

  /// The chofer's share on an insurer's job, the company's on a cash job.
  final int amountCents;
  final DateTime? completedAt;
}

enum SettlementLineKind {
  /// Drakegruas owes the chofer.
  insurer,

  /// The chofer owes Drakegruas.
  cash,
  unknown,
}

/// A weekly corte, at `driverSettlements/{id}`: what Drakegruas and a chofer owe
/// each other for a week, netted.
///
/// Written only by the settlement callables. Mirrors
/// `functions/src/callables/settlements.ts`.
@immutable
class DriverSettlement {
  const DriverSettlement({
    required this.id,
    required this.driverId,
    this.driverName = '',
    this.truckPlate = '',
    this.periodStart,
    this.periodEnd,
    this.lines = const [],
    this.insuranceOwedCents = 0,
    this.commissionOwedCents = 0,
    this.finalBalanceCents = 0,
    this.direction = SettlementDirection.unknown,
    this.status = SettlementStatus.unknown,
    this.payBy,
    this.reference = '',
    this.note = '',
    this.voidReason = '',
    this.settledAt,
    this.createdAt,
  });

  factory DriverSettlement.fromJson(String id, Map<String, dynamic> json) {
    const ts = NullableTimestampConverter();
    return DriverSettlement(
      id: id,
      driverId: json['driverId'] as String? ?? '',
      driverName: json['driverName'] as String? ?? '',
      truckPlate: json['truckPlate'] as String? ?? '',
      periodStart: ts.fromJson(json['periodStart']),
      periodEnd: ts.fromJson(json['periodEnd']),
      lines: [
        for (final line in json['lines'] as List<dynamic>? ?? const [])
          SettlementLine.fromJson(Map<String, dynamic>.from(line as Map)),
      ],
      insuranceOwedCents: (json['insuranceOwedCents'] as num? ?? 0).round(),
      commissionOwedCents: (json['commissionOwedCents'] as num? ?? 0).round(),
      finalBalanceCents: (json['finalBalanceCents'] as num? ?? 0).round(),
      direction: SettlementDirection.fromWire(json['direction'] as String?),
      status: SettlementStatus.fromWire(json['status'] as String?),
      payBy: ts.fromJson(json['payBy']),
      reference: json['reference'] as String? ?? '',
      note: json['note'] as String? ?? '',
      voidReason: json['voidReason'] as String? ?? '',
      settledAt: ts.fromJson(json['settledAt']),
      createdAt: ts.fromJson(json['createdAt']),
    );
  }

  final String id;
  final String driverId;
  final String driverName;
  final String truckPlate;
  final DateTime? periodStart;
  final DateTime? periodEnd;
  final List<SettlementLine> lines;

  /// Section 1: what Drakegruas owes the chofer for insurer jobs.
  final int insuranceOwedCents;

  /// Section 2: what the chofer owes Drakegruas for cash jobs.
  final int commissionOwedCents;

  /// Section 3: positive, Drakegruas pays; negative, the chofer pays.
  final int finalBalanceCents;
  final SettlementDirection direction;
  final SettlementStatus status;

  /// Friday, 5 p.m.
  final DateTime? payBy;

  /// The transfer or deposit number, once paid.
  final String reference;
  final String note;
  final String voidReason;
  final DateTime? settledAt;
  final DateTime? createdAt;

  List<SettlementLine> get insurerLines =>
      [for (final l in lines) if (l.kind == SettlementLineKind.insurer) l];

  List<SettlementLine> get cashLines =>
      [for (final l in lines) if (l.kind == SettlementLineKind.cash) l];

  bool get isPending => status == SettlementStatus.pending;

  bool get titanPays => direction == SettlementDirection.toDriver;

  bool get driverPays => direction == SettlementDirection.toCompany;

  /// The balance without its sign: who pays is [direction].
  int get amountCents => finalBalanceCents.abs();

  /// "SALDO FINAL A FAVOR DEL CONDUCTOR", or the other way round.
  String get balanceHeadline => switch (direction) {
        SettlementDirection.toDriver =>
          'Saldo final a favor del conductor: ${amountCents.formatDOP}',
        SettlementDirection.toCompany =>
          'Saldo final a favor de Drakegruas: ${amountCents.formatDOP}',
        _ => 'Sin saldo pendiente',
      };
}

import 'package:flutter/foundation.dart';

import '../domain/enums.dart';
import '../domain/models/billing.dart';
import '../domain/models/settlement.dart';
import '../utils/date_time_do.dart';

/// A corte worked out, before it is written.
@immutable
class SettlementDraft {
  const SettlementDraft({
    required this.periodStart,
    required this.periodEnd,
    required this.lines,
    required this.retiredServiceIds,
    required this.ignoredServiceIds,
  });

  final DateTime periodStart;
  final DateTime periodEnd;
  final List<SettlementLine> lines;

  /// Cash already handed in at an office cash corte: settled, no line.
  final List<String> retiredServiceIds;

  /// Jobs this corte leaves alone, for a person to look at.
  final List<String> ignoredServiceIds;

  int _sum(SettlementLineKind kind) => lines
      .where((l) => l.kind == kind)
      .fold(0, (total, l) => total + l.amountCents);

  int get insuranceOwedCents => _sum(SettlementLineKind.insurer);

  int get commissionOwedCents => _sum(SettlementLineKind.cash);

  int get finalBalanceCents => insuranceOwedCents - commissionOwedCents;

  SettlementDirection get direction =>
      SettlementDirection.ofBalance(finalBalanceCents);
}

/// What a chofer and Titan owe each other right now.
///
/// Every corte still pending, plus what this week's corte says so far. A
/// positive balance is Titan's to pay; a negative one, the chofer's.
@immutable
class DriverBalance {
  const DriverBalance({
    required this.pending,
    required this.pendingCents,
    required this.running,
  });

  factory DriverBalance.of({
    required List<DriverSettlement> settlements,
    SettlementDraft? running,
  }) {
    final pending = [
      for (final s in settlements)
        if (s.isPending) s,
    ];
    return DriverBalance(
      pending: List.unmodifiable(pending),
      pendingCents: pending.fold(0, (sum, s) => sum + s.finalBalanceCents),
      running: running,
    );
  }

  /// Cortes made and not yet paid, newest first.
  final List<DriverSettlement> pending;

  /// Their balances added up, with sign.
  final int pendingCents;

  /// This week's corte so far.
  final SettlementDraft? running;

  int get runningCents => running?.finalBalanceCents ?? 0;

  int get totalCents => pendingCents + runningCents;

  SettlementDirection get direction => SettlementDirection.ofBalance(totalCents);

  /// The next Friday a pending corte is due, if any.
  DateTime? get nextPayBy {
    DateTime? soonest;
    for (final s in pending) {
      final at = s.payBy;
      if (at != null && (soonest == null || at.isBefore(soonest))) soonest = at;
    }
    return soonest;
  }
}

/// The weekly corte's arithmetic.
///
/// A port of `functions/src/lib/settlements.ts`; both run the cases in
/// `test/fixtures/settlement_cases.json`. The server writes the real corte —
/// this one draws what the next corte will say, and runs the test backend.
///
///     balance = (what Titan owes for insurer jobs) − (commission owed on cash jobs)
abstract final class SettlementMath {
  /// The corte for everything in [entries] finished by [cutoff], or `null`.
  ///
  /// [countedInCashCorte] names the cash jobs the office already received at a
  /// cash corte; they are retired without a line.
  static SettlementDraft? draft(
    List<EarningEntry> entries, {
    required DateTime cutoff,
    DateTime? startAt,
    Set<String> countedInCashCorte = const {},
  }) {
    final lines = <SettlementLine>[];
    final retired = <String>[];
    final ignored = <String>[];

    for (final entry in entries) {
      final at = entry.completedAt;
      if (at == null || at.isAfter(cutoff)) continue;
      if (startAt != null && at.isBefore(startAt)) continue;

      switch (entry.method) {
        case PaymentMethod.insurer:
          lines.add(
            SettlementLine(
              serviceId: entry.serviceId,
              serviceCode: entry.serviceCode,
              kind: SettlementLineKind.insurer,
              grossCents: entry.grossCents,
              amountCents: entry.netCents,
              completedAt: at,
            ),
          );
        case PaymentMethod.cash:
          if (countedInCashCorte.contains(entry.serviceId)) {
            retired.add(entry.serviceId);
            continue;
          }
          lines.add(
            SettlementLine(
              serviceId: entry.serviceId,
              serviceCode: entry.serviceCode,
              kind: SettlementLineKind.cash,
              grossCents: entry.grossCents,
              amountCents: entry.commissionCents,
              completedAt: at,
            ),
          );
        case _:
          ignored.add(entry.serviceId);
      }
    }

    if (lines.isEmpty && retired.isEmpty) return null;
    lines.sort((a, b) {
      final byTime = a.completedAt!.compareTo(b.completedAt!);
      return byTime != 0 ? byTime : a.serviceId.compareTo(b.serviceId);
    });

    return SettlementDraft(
      periodStart: lines.isEmpty ? cutoff : lines.first.completedAt!,
      periodEnd: cutoff,
      lines: List.unmodifiable(lines),
      retiredServiceIds: List.unmodifiable(retired),
      ignoredServiceIds: List.unmodifiable(ignored),
    );
  }

  /// Friday at 5 p.m. Dominican time: the Friday of [from] if it is Friday
  /// before 5 p.m., otherwise the next one. Returned in UTC.
  static DateTime payBy(DateTime from) {
    final local = DoTime.toLocal(from.toUtc());
    var ahead = (DateTime.friday - local.weekday + 7) % 7;
    if (ahead == 0 && local.hour >= 17) ahead = 7;
    return DoTime.fromLocal(
      DateTime.utc(local.year, local.month, local.day + ahead, 17),
    );
  }
}

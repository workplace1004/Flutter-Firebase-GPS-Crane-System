import 'package:flutter/foundation.dart';

import '../domain/enums.dart';
import '../domain/models/insurer_invoice.dart';
import '../utils/date_time_do.dart';
import '../utils/money.dart';
import 'zone_pricing.dart';

/// Números de Comprobante Fiscal. A port of `functions/src/lib/fiscal.ts`;
/// both run `test/fixtures/insurer_invoice_cases.json`.
abstract final class Ncf {
  static const prefixes = <String>{
    'B01', 'B02', 'B03', 'B04', 'B11', 'B12', 'B13', 'B14', 'B15', 'B16', 'B17',
  };

  /// Crédito fiscal: what an insurance company receives.
  static const creditoFiscal = 'B01';

  static const digits = 8;

  /// `B01` and 1 → `B0100000001`.
  static String format(String prefix, int sequence) {
    if (sequence < 1 || sequence > NcfSequence.maxNumber) {
      throw RangeError.range(sequence, 1, NcfSequence.maxNumber, 'sequence');
    }
    return '$prefix${sequence.toString().padLeft(digits, '0')}';
  }

  /// The parts of a B-series NCF, or null when it is not one.
  static ({String prefix, int sequence})? parse(String ncf) {
    final match = RegExp(r'^(B\d{2})(\d{8})$').firstMatch(ncf.trim().toUpperCase());
    if (match == null) return null;
    final prefix = match.group(1)!;
    if (!prefixes.contains(prefix)) return null;
    final sequence = int.parse(match.group(2)!);
    return sequence >= 1 ? (prefix: prefix, sequence: sequence) : null;
  }

  /// The end of [expiresOn] (`2027-12-31`) in Santo Domingo, or null when it
  /// is not a date — a hand-edited record should not break the office's page.
  static DateTime? expiryInstant(String expiresOn) {
    if (!isIsoDay(expiresOn)) return null;
    final parts = expiresOn.split('-').map(int.parse).toList();
    return DoTime.fromLocal(DateTime.utc(parts[0], parts[1], parts[2] + 1));
  }

  /// Why no receipt can be numbered from [sequence] at [now], or null.
  static String? problem(NcfSequence sequence, DateTime now) {
    if (sequence.nextNumber > sequence.lastNumber) {
      return 'Se agotó la secuencia de NCF ${sequence.prefix} (hasta '
          '${format(sequence.prefix, sequence.lastNumber)}). Registra la nueva '
          'secuencia autorizada por la DGII.';
    }
    final expiry = sequence.expiresOn == null ? null : expiryInstant(sequence.expiresOn!);
    final expiresOn = sequence.expiresOn;
    if (expiry != null && !now.isBefore(expiry)) {
      return 'La secuencia de NCF ${sequence.prefix} venció el $expiresOn. '
          'Registra la nueva secuencia autorizada por la DGII.';
    }
    return null;
  }

  /// The NCF the next receipt from [sequence] takes, or null when it cannot.
  static String? next(NcfSequence sequence) =>
      sequence.nextNumber >= 1 && sequence.nextNumber <= NcfSequence.maxNumber
          ? format(sequence.prefix, sequence.nextNumber)
          : null;

  /// Test numbers are registered apart from real ones.
  static String registryKey(String ncf, {required bool isTest}) =>
      isTest ? 'TEST-$ncf' : ncf;

  /// A valid `YYYY-MM-DD`.
  static bool isIsoDay(String value) {
    final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value);
    if (match == null) return false;
    final y = int.parse(match.group(1)!);
    final m = int.parse(match.group(2)!);
    final d = int.parse(match.group(3)!);
    final date = DateTime.utc(y, m, d);
    return date.year == y && date.month == m && date.day == d;
  }
}

/// A calendar month in Santo Domingo, the unit invoices are made for.
@immutable
class InvoicePeriod {
  const InvoicePeriod(this.year, this.month);

  factory InvoicePeriod.parse(String key) {
    if (!isKey(key)) throw FormatException('Not a period', key);
    return InvoicePeriod(int.parse(key.substring(0, 4)), int.parse(key.substring(5)));
  }

  /// The month [instant] falls in.
  factory InvoicePeriod.of(DateTime instant) {
    final local = DoTime.toLocal(instant);
    return InvoicePeriod(local.year, local.month);
  }

  static bool isKey(String value) => RegExp(r'^\d{4}-(0[1-9]|1[0-2])$').hasMatch(value);

  static const _months = [
    'enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio',
    'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre',
  ];

  final int year;
  final int month;

  /// `2026-09`.
  String get key => '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}';

  /// `septiembre 2026`.
  String get label => '${_months[month - 1]} $year';

  /// `Septiembre 2026`.
  String get title => '${label[0].toUpperCase()}${label.substring(1)}';

  DateTime get start => DoTime.fromLocal(DateTime.utc(year, month));

  DateTime get end => DoTime.fromLocal(DateTime.utc(year, month + 1));

  InvoicePeriod get previous => InvoicePeriod.of(start.subtract(const Duration(milliseconds: 1)));

  InvoicePeriod get next => InvoicePeriod.of(end);

  /// The months before and including [now]'s, newest first.
  static List<InvoicePeriod> recent(DateTime now, {int count = 12}) {
    final list = <InvoicePeriod>[InvoicePeriod.of(now)];
    while (list.length < count) {
      list.add(list.last.previous);
    }
    return list;
  }

  @override
  bool operator ==(Object other) =>
      other is InvoicePeriod && other.year == year && other.month == month;

  @override
  int get hashCode => Object.hash(year, month);

  @override
  String toString() => key;
}

/// What an invoice needs to know about one of the company's services.
@immutable
class InvoiceableService {
  const InvoiceableService({
    required this.serviceId,
    required this.status,
    required this.finishedAt,
    this.subtotalCents = 0,
    this.feeCents = 0,
  });

  final String serviceId;
  final ServiceStatus status;
  final DateTime? finishedAt;
  final int subtotalCents;
  final int feeCents;
}

/// An invoice worked out, before it is written.
@immutable
class InvoiceDraft {
  const InvoiceDraft({
    required this.serviceIds,
    required this.kinds,
    required this.amounts,
    required this.totals,
    required this.leftover,
  });

  final List<String> serviceIds;
  final List<InsurerInvoiceLineKind> kinds;
  final List<int> amounts;
  final ItbisTotals totals;

  /// Billable services beyond the invoice's line limit.
  final int leftover;

  int get towCount => kinds.where((k) => k == InsurerInvoiceLineKind.tow).length;

  int get cancellationCount =>
      kinds.where((k) => k == InsurerInvoiceLineKind.cancellation).length;
}

/// The monthly invoice's arithmetic. A port of
/// `functions/src/lib/insurerInvoice.ts`; the server writes the real invoice,
/// this one runs the test backend and previews what the next will say.
abstract final class InsurerInvoiceMath {
  static const maxLines = 400;

  /// What [service] adds to an invoice cut at [cutoff], or null.
  static (InsurerInvoiceLineKind, int)? lineFor(InvoiceableService service, DateTime cutoff) {
    final at = service.finishedAt;
    if (at == null || !at.isBefore(cutoff)) return null;
    final (kind, amount) = switch (service.status) {
      ServiceStatus.completed || ServiceStatus.closed => (
          InsurerInvoiceLineKind.tow,
          service.subtotalCents,
        ),
      ServiceStatus.cancelled when service.feeCents > 0 => (
          InsurerInvoiceLineKind.cancellation,
          service.feeCents,
        ),
      _ => (InsurerInvoiceLineKind.unknown, 0),
    };
    if (kind == InsurerInvoiceLineKind.unknown || amount <= 0) return null;
    return (kind, amount);
  }

  /// The invoice for every billable service finished before [cutoff], oldest
  /// first, or null when there is none.
  static InvoiceDraft? draft(
    List<InvoiceableService> services, {
    required DateTime cutoff,
    int maxLines = maxLines,
  }) {
    final billable = [
      for (final s in services)
        if (lineFor(s, cutoff) case (final kind, final amount)) (s, kind, amount),
    ]..sort((a, b) {
        final byTime = a.$1.finishedAt!.compareTo(b.$1.finishedAt!);
        return byTime != 0 ? byTime : a.$1.serviceId.compareTo(b.$1.serviceId);
      });
    if (billable.isEmpty) return null;

    final taken = billable.take(maxLines).toList();
    final subtotal = taken.fold<int>(0, (sum, l) => sum + l.$3);
    return InvoiceDraft(
      serviceIds: [for (final l in taken) l.$1.serviceId],
      kinds: [for (final l in taken) l.$2],
      amounts: [for (final l in taken) l.$3],
      totals: ZonePricing.withItbis(subtotal),
      leftover: billable.length - taken.length,
    );
  }

  /// The end of the day, in Santo Domingo, [termsDays] after [issuedAt].
  static DateTime dueDate(DateTime issuedAt, int termsDays) =>
      DoTime.startOfLocalDay(issuedAt)
          .add(Duration(days: termsDays + 1))
          .subtract(const Duration(milliseconds: 1));
}

/// An invoice as a printable page: what the office sends the company and the
/// company files.
///
/// Plain HTML with its own print styles, so the browser's "Guardar como PDF"
/// gives a clean A4 document without a PDF library in the app.
abstract final class InvoiceDocument {
  static String _escape(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&#39;');

  /// `16/09/2026`, in Santo Domingo.
  static String day(DateTime? instant) {
    if (instant == null) return '—';
    final l = DoTime.toLocal(instant);
    return '${l.day.toString().padLeft(2, '0')}/${l.month.toString().padLeft(2, '0')}/${l.year}';
  }

  /// `2027-12-31` as `31/12/2027`.
  static String isoDay(String? value) {
    if (value == null || !Ncf.isIsoDay(value)) return '—';
    final p = value.split('-');
    return '${p[2]}/${p[1]}/${p[0]}';
  }

  /// The title a browser tab and a saved PDF get.
  static String fileTitle(InsurerInvoice invoice) =>
      'Factura ${invoice.ncf} ${invoice.insurerName} ${invoice.periodKey}';

  static String html(InsurerInvoice invoice) {
    const e = _escape;
    final i = invoice;
    final rows = StringBuffer();
    for (final (n, line) in i.lines.indexed) {
      final vehicle = [line.plate, line.vehicle].where((p) => p.isNotEmpty).join(' · ');
      rows.write('''
<tr>
  <td class="num">${n + 1}</td>
  <td>${day(line.finishedAt)}</td>
  <td>${e(line.serviceCode)}</td>
  <td>${e(line.claimNumber)}${line.policyNumber.isEmpty ? '' : '<div class="muted">Póliza ${e(line.policyNumber)}</div>'}</td>
  <td>${e(line.insuredName)}</td>
  <td>${e(vehicle)}</td>
  <td>${e(line.description)}${line.pickupAddress.isEmpty ? '' : '<div class="muted">${e(line.pickupAddress)}${line.dropoffAddress.isEmpty ? '' : ' → ${e(line.dropoffAddress)}'}</div>'}</td>
  <td class="amount">${e(line.amountCents.formatDOP)}</td>
</tr>''');
    }

    final banners = StringBuffer();
    if (i.isTestNcf) {
      banners.write(
        '<div class="banner test">COMPROBANTE DE PRUEBA — SIN VALOR FISCAL. '
        'El NCF de esta factura es de prueba (is_test_ncf).</div>',
      );
    }
    if (i.isVoided) {
      banners.write(
        '<div class="banner void">FACTURA ANULADA${i.voidReason.isEmpty ? '' : ': ${e(i.voidReason)}'}</div>',
      );
    }
    if (i.isPaid) {
      banners.write(
        '<div class="banner paid">PAGADA el ${day(i.paidAt)}'
        '${i.paymentReference.isEmpty ? '' : ' · Ref. ${e(i.paymentReference)}'}</div>',
      );
    }

    final issuerContact = [
      i.issuer.address,
      i.issuer.phone,
      i.issuer.email,
    ].where((p) => p.isNotEmpty).map(e).join(' · ');

    return '''
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="utf-8">
<title>${e(fileTitle(i))}</title>
<style>
  @page { size: A4; margin: 14mm; }
  * { box-sizing: border-box; }
  body { font-family: Arial, Helvetica, sans-serif; color: #1d1a19; font-size: 11px; margin: 0; }
  .page { max-width: 190mm; margin: 0 auto; padding: 8px; }
  header { display: flex; justify-content: space-between; gap: 24px; border-bottom: 3px solid #c8102e; padding-bottom: 12px; }
  h1 { font-size: 20px; margin: 0 0 4px; }
  h2 { font-size: 14px; margin: 0 0 6px; color: #c8102e; text-transform: uppercase; letter-spacing: .5px; }
  .muted { color: #6b6564; font-size: 10px; }
  .box { text-align: right; }
  .ncf { font-size: 16px; font-weight: bold; letter-spacing: 1px; }
  .banner { margin: 10px 0; padding: 8px 10px; border-radius: 4px; font-weight: bold; text-align: center; }
  .banner.test { background: #fff3cd; border: 2px dashed #b7791f; color: #7a4f00; }
  .banner.void { background: #fde2e2; border: 2px solid #b42318; color: #b42318; }
  .banner.paid { background: #e3f4ea; border: 1px solid #1e8e4e; color: #1e6b3c; }
  .parties { display: flex; gap: 24px; margin: 14px 0; }
  .parties > div { flex: 1; border: 1px solid #e3dedd; border-radius: 4px; padding: 8px 10px; }
  table { width: 100%; border-collapse: collapse; }
  th { background: #f4f1f0; text-align: left; font-size: 10px; text-transform: uppercase; padding: 6px 5px; border-bottom: 1px solid #cfc9c8; }
  td { padding: 5px; border-bottom: 1px solid #eee9e8; vertical-align: top; }
  tr { page-break-inside: avoid; }
  .num { width: 22px; color: #6b6564; }
  .amount { text-align: right; white-space: nowrap; }
  .totals { margin-left: auto; margin-top: 12px; width: 260px; }
  .totals td { border: none; padding: 3px 5px; }
  .totals .grand td { font-size: 14px; font-weight: bold; border-top: 2px solid #1d1a19; padding-top: 6px; }
  footer { margin-top: 18px; border-top: 1px solid #e3dedd; padding-top: 8px; }
  .toolbar { text-align: right; margin-bottom: 8px; }
  .toolbar button { background: #c8102e; color: #fff; border: 0; border-radius: 4px; padding: 8px 14px; font-size: 13px; cursor: pointer; }
  @media print { .noprint { display: none; } }
</style>
</head>
<body>
<div class="page">
  <div class="noprint toolbar"><button type="button" onclick="window.print()">Imprimir / Guardar PDF</button></div>
  <header>
    <div>
      <h1>${e(i.issuer.name)}</h1>
      <div>RNC: ${e(i.issuer.rncLabel)}</div>
      <div class="muted">$issuerContact</div>
    </div>
    <div class="box">
      <h2>Factura de crédito fiscal</h2>
      <div class="ncf">NCF: ${e(i.ncf)}</div>
      <div>Válido hasta: ${i.isTestNcf ? 'N/A (prueba)' : isoDay(i.ncfExpiresOn)}</div>
      <div>Fecha de emisión: ${day(i.issuedAt ?? i.createdAt)}</div>
      <div>Fecha de vencimiento: ${day(i.dueAt)}</div>
    </div>
  </header>
  $banners
  <div class="parties">
    <div>
      <h2>Cliente</h2>
      <div><strong>${e(i.insurerName)}</strong></div>
      <div>RNC: ${e(formatRnc(i.insurerRnc))}</div>
      ${i.billingEmail.isEmpty ? '' : '<div class="muted">${e(i.billingEmail)}</div>'}
    </div>
    <div>
      <h2>Período</h2>
      <div><strong>${e(i.periodLabel.isEmpty ? i.periodKey : i.periodLabel)}</strong></div>
      <div class="muted">${i.towCount} servicio(s) de grúa · ${i.cancellationCount} cargo(s) por cancelación</div>
      <div class="muted">Condiciones: ${i.paymentTermsDays == 0 ? 'contado' : '${i.paymentTermsDays} días'}</div>
    </div>
  </div>
  <table>
    <thead>
      <tr><th>#</th><th>Fecha</th><th>Código</th><th>Siniestro</th><th>Asegurado</th><th>Vehículo</th><th>Descripción</th><th class="amount">Monto</th></tr>
    </thead>
    <tbody>
$rows
    </tbody>
  </table>
  <table class="totals">
    <tr><td>Subtotal</td><td class="amount">${e(i.subtotalCents.formatDOP)}</td></tr>
    <tr><td>ITBIS 18%</td><td class="amount">${e(i.itbisCents.formatDOP)}</td></tr>
    <tr class="grand"><td>Total</td><td class="amount">${e(i.totalCents.formatDOP)}</td></tr>
  </table>
  <footer class="muted">
    Montos en pesos dominicanos (DOP). Pagar por transferencia indicando el NCF ${e(i.ncf)}.
  </footer>
</div>
</body>
</html>
''';
  }
}

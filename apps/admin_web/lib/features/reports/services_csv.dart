import 'dart:convert';
import 'dart:typed_data';

import 'package:grua_core/grua_core.dart';

/// The services behind a report, one row each, as a CSV the office opens in
/// Excel.
///
/// UTF-8 with a byte-order mark: without it Excel reads "Grúa" as "GrÃºa".
/// Amounts are plain pesos with two decimals, not formatted money, so the
/// column sums.
Uint8List servicesCsv(List<Service> services) {
  final rows = <List<String>>[
    const [
      'Código',
      'Fecha',
      'Estado',
      'Cliente',
      'Chofer',
      'Aseguradora',
      'Método de pago',
      'Estado del pago',
      r'Total (RD$)',
      'Llegada (min)',
    ],
    for (final s in services)
      [
        s.code,
        switch (s.createdAt) {
          final at? => DoTime.dateAndTime(at),
          null => '',
        },
        s.status.label,
        s.clientName,
        s.driverName,
        s.insurerName,
        s.payment.method.label,
        s.payment.status.label,
        (s.totalCents / 100).toStringAsFixed(2),
        switch (s.timeline.timeToArrive) {
          final d? => '${d.inMinutes}',
          null => '',
        },
      ],
  ];

  final csv = rows.map((row) => row.map(_cell).join(',')).join('\r\n');
  return Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode(csv)]);
}

/// Named like the invoice export: `Servicios_2026-09-30.csv`.
String servicesCsvFileName(DateTime now) =>
    'Servicios_${DoTime.dateKey(now)}.csv';

const csvMimeType = 'text/csv';

/// Quoted when it has to be, per RFC 4180. A leading `=`, `+`, `-` or `@` is
/// defused as well: a customer named "=HYPERLINK(…)" must not become a formula
/// when the office opens the file.
String _cell(String value) {
  var v = value;
  if (v.isNotEmpty && '=+-@'.contains(v[0])) v = "'$v";
  if (v.contains(RegExp('[",\r\n]'))) return '"${v.replaceAll('"', '""')}"';
  return v;
}

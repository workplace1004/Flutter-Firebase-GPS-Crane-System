import 'dart:convert';
import 'dart:typed_data';

import 'package:admin_web/app.dart';
import 'package:admin_web/features/invoices/file_saver.dart';
import 'package:admin_web/features/reports/services_csv.dart';
import 'package:admin_web/features/shared/page_parts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';
import 'package:grua_testing/grua_testing.dart';
import 'package:intl/date_symbol_data_local.dart';

/// Reportes, over the services the repository returns for the range — not a
/// private copy of made-up ones.
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

  testWidgets('the figures and the export come from the services in range', (
    tester,
  ) async {
    tester.view
      ..devicePixelRatio = 1.0
      ..physicalSize = const Size(1440, 1800);
    addTearDown(tester.view.reset);

    final backend = DemoBackend()..seed();
    final saver = _FakeSaver();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appConfigProvider.overrideWithValue(config),
          ...demoOverrides(
            backend: backend,
            role: UserRole.admin,
            actingAs: 'admin-1',
          ),
          fileSaverProvider.overrideWithValue(saver),
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

    GoRouter.of(tester.element(find.byType(Scaffold).first)).go('/reportes');
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(find.byType(StatTile), findsWidgets);

    // What the repository holds for the last seven days, the default range.
    final from = DoTime.startOfLocalDay(
      DateTime.now().toUtc().subtract(const Duration(days: 6)),
    );
    final inRange = backend.allServices
        .where((s) => s.createdAt != null && !s.createdAt!.isBefore(from))
        .toList();
    expect(inRange, isNotEmpty, reason: 'the fixture needs recent services');
    final completed = inRange.where(
      (s) =>
          s.status == ServiceStatus.completed ||
          s.status == ServiceStatus.closed,
    );

    final tile = tester.widget<StatTile>(
      find.byWidgetPredicate(
        (w) => w is StatTile && w.label == 'Servicios completados',
      ),
    );
    expect(tile.value, '${completed.length}');
    expect(tile.detail, contains('${inRange.length}'));

    await tester.tap(find.byKey(const Key('reports-export')));
    await tester.pumpAndSettle();

    expect(saver.saved, hasLength(1));
    final file = saver.saved.single;
    expect(file.mimeType, csvMimeType);
    expect(file.name, endsWith('.csv'));
    // A byte-order mark, so Excel reads the accents.
    expect(file.bytes.take(3), [0xEF, 0xBB, 0xBF]);
    final lines = const LineSplitter().convert(
      utf8.decode(file.bytes.sublist(3)),
    );
    expect(lines.first, startsWith('Código,Fecha,Estado'));
    expect(lines, hasLength(inRange.length + 1));

    await tester.pumpWidget(const SizedBox.shrink());
    backend.dispose();
  });

  group('the CSV', () {
    Service service({String clientName = 'Ana Pérez'}) => Service(
      id: 's1',
      code: 'GR-260930-0001',
      clientId: 'c1',
      clientName: clientName,
      pickup: const ServiceLocation(
        geo: DoLocations.santoDomingo,
        address: 'Av. 27 de Febrero',
      ),
      vehicle: const ServiceVehicle(make: 'Toyota', model: 'Corolla'),
      quote: const Quote(totalCents: 250050),
    );

    List<String> row(Service s) => const LineSplitter()
        .convert(utf8.decode(servicesCsv([s]).sublist(3)))
        .last
        .split(',');

    test('amounts are plain pesos, so the column sums', () {
      expect(row(service()), contains('2500.50'));
    });

    test('a comma or a quote is escaped, not a new column', () {
      final csv = utf8.decode(
        servicesCsv([service(clientName: 'Pérez, "Ana"')]).sublist(3),
      );
      expect(csv, contains('"Pérez, ""Ana"""'));
    });

    test('a name that looks like a formula stays text', () {
      final csv = utf8.decode(
        servicesCsv([service(clientName: '=1+1')]).sublist(3),
      );
      expect(csv, contains("'=1+1"));
    });
  });
}

class _FakeSaver implements FileSaver {
  final saved = <({Uint8List bytes, String name, String mimeType})>[];

  @override
  bool save(
    Uint8List bytes, {
    required String fileName,
    required String mimeType,
  }) {
    saved.add((bytes: bytes, name: fileName, mimeType: mimeType));
    return true;
  }
}

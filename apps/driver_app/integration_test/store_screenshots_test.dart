import 'dart:async';

import 'package:driver_app/app.dart';
import 'package:driver_app/router.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';
import 'package:grua_testing/grua_testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:intl/date_symbol_data_local.dart';

/// Walks the chofer app over the in-memory demo backend and stops on each
/// screen the Play listing shows.
///
/// Not a test of anything: it prints `STORE_SHOT:<name>` and holds the screen
/// still, and `scripts/store_screenshots.ps1` captures the device when it sees
/// the line. Run through that script, not on its own.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('store screenshots', (tester) async {
    await initializeDateFormatting('es_DO');

    // An hour: the open requests stay in Pedidos instead of being assigned
    // by the demo cascade while the screen is being captured.
    final backend = DemoBackend(dispatchDelay: const Duration(hours: 1))
      ..seed()
      ..seedDriverWeek('driver-1');
    final truckType = backend.driver('driver-1')!.truckType;

    final requests = [
      (
        'Av. Winston Churchill #95, Piantini',
        'Taller Autocentro, Av. Charles de Gaulle',
        const ServiceVehicle(
          make: 'Toyota',
          model: 'Corolla',
          color: 'Gris',
          plate: 'G123456',
          condition: VehicleCondition.noArranca,
        ),
        const LatLng(18.4720, -69.9390),
        const LatLng(18.5010, -69.8600),
        295000,
        14200,
      ),
      (
        'Av. 27 de Febrero esq. Máximo Gómez',
        'Plaza Lama, Av. Duarte',
        const ServiceVehicle(
          make: 'Honda',
          model: 'Civic',
          color: 'Negro',
          plate: 'A234567',
        ),
        const LatLng(18.4795, -69.9180),
        const LatLng(18.4880, -69.8990),
        240000,
        6800,
      ),
      (
        'Autopista Duarte Km 12, Los Alcarrizos',
        'Residencial Las Praderas, Santo Domingo',
        const ServiceVehicle(
          make: 'Hyundai',
          model: 'Tucson',
          color: 'Blanco',
          plate: 'G456789',
        ),
        const LatLng(18.5130, -70.0180),
        const LatLng(18.4610, -69.9520),
        380000,
        11900,
      ),
    ];
    // Before the app starts, so no "nuevo pedido" toast covers the screens.
    final requestIds = <String>[];
    for (final (from, to, vehicle, a, b, cents, meters) in requests) {
      final created = backend.createService(
        clientId: 'demo-client-1',
        pickup: ServiceLocation(geo: a, address: from),
        dropoff: ServiceLocation(geo: b, address: to),
        vehicle: vehicle,
        truckType: truckType,
        quote: Quote(totalCents: cents),
        route: ServiceRoute(
          distanceMeters: meters,
          durationSeconds: (meters / 1000 / 28 * 3600).round(),
        ),
      );
      requestIds.add(created.id);
    }

    const config = AppConfig(
      flavor: Flavor.prod,
      appKind: AppKind.driver,
      firebaseProjectId: 'demo',
      // Passed by the script from android/local.properties: without it the
      // app draws its schematic fallback instead of Google Maps.
      googleMapsApiKey: String.fromEnvironment('GOOGLE_MAPS_API_KEY'),
      useEmulators: false,
      emulatorHost: 'localhost',
      functionsRegion: 'us-east1',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appConfigProvider.overrideWithValue(config),
          ...demoOverrides(
            backend: backend,
            role: UserRole.driver,
            actingAs: 'driver-1',
          ),
        ],
        child: const DriverApp(),
      ),
    );
    await _settle(tester);

    final router = ProviderScope.containerOf(
      tester.element(find.byType(DriverApp)),
    ).read(routerProvider);

    await tester.enterText(
      find.byType(TextFormField).first,
      'driver1@gruasrd.do',
    );
    await tester.enterText(find.byType(TextFormField).last, 'secret123');
    await tester.tap(find.text('ENTRAR'));
    await _settle(tester, seconds: 3);

    // The seeded history leaves a customer to rate; that banner would sit
    // over every map.
    final dismiss = find.byIcon(Icons.close);
    if (dismiss.evaluate().isNotEmpty) {
      await tester.tap(dismiss.first);
      await _settle(tester);
    }

    // Map tiles need real time to come in, more so on a cold start.
    await _shot(tester, '01_inicio', hold: 30);

    router.go(Routes.orders);
    await _settle(tester, seconds: 2);
    await _shot(tester, '02_pedidos');

    // The demo's accept only flips the status; hand the job over the way
    // the office does, which also attaches the chofer and starts tracking.
    final refused = backend.assignServiceManually(
      serviceId: requestIds.first,
      driverId: 'driver-1',
    );
    expect(refused, isNull);
    await _settle(tester, seconds: 2);
    router.go(Routes.activeService);
    await _settle(tester, seconds: 3);
    await _shot(tester, '03_servicio', hold: 10);

    final serviceId = backend.driver('driver-1')!.currentServiceId!;
    final now = DateTime.now();
    final lines = [
      ('demo-client-1', UserRole.client, 'Buenas, ¿cuánto le falta para llegar?', 6),
      ('driver-1', UserRole.driver, 'Buenas. Voy en camino, llego en unos 10 minutos.', 5),
      ('demo-client-1', UserRole.client, 'Perfecto. Estoy frente a la farmacia, el carro es un Corolla gris.', 4),
      ('driver-1', UserRole.driver, 'Entendido, ya lo veo en el mapa. 👍', 3),
      ('demo-client-1', UserRole.client, 'Gracias, aquí lo espero.', 1),
    ];
    for (var i = 0; i < lines.length; i++) {
      final (sender, role, text, minutesAgo) = lines[i];
      backend.addMessage(
        serviceId,
        ChatMessage(
          id: 'store-$i',
          senderId: sender,
          senderRole: role,
          text: text,
          sentAt: now.subtract(Duration(minutes: minutesAgo)),
        ),
      );
    }
    unawaited(router.push<void>(Routes.chatFor(serviceId)));
    await _settle(tester, seconds: 2);
    await _shot(tester, '04_chat');

    router.pop();
    unawaited(router.push<void>(Routes.earnings));
    await _settle(tester, seconds: 2);
    await _shot(tester, '05_ganancias');

    router
      ..pop()
      ..go(Routes.profile);
    await _settle(tester, seconds: 2);
    await _shot(tester, '06_perfil');

    debugPrint('STORE_SHOT:done');
  },timeout: const Timeout(Duration(minutes: 10)));
}

/// Pumps for [seconds] of real time. Not `pumpAndSettle`: the map and the
/// live streams never settle.
Future<void> _settle(WidgetTester tester, {int seconds = 1}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Lets the screen finish drawing, announces it, and holds it while the
/// device is captured from outside.
Future<void> _shot(WidgetTester tester, String name, {int hold = 3}) async {
  await _settle(tester, seconds: hold);
  debugPrint('STORE_SHOT:$name');
  await _settle(tester, seconds: 5);
}

import 'dart:async';

import 'package:client_app/app.dart';
import 'package:client_app/features/request/request_controller.dart';
import 'package:client_app/router.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';
import 'package:grua_testing/grua_testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:intl/date_symbol_data_local.dart';

/// Walks the customer app over the in-memory demo backend and stops on each
/// screen the Play listing shows.
///
/// Not a test of anything: it prints `STORE_SHOT:<name>` and holds the screen
/// still, and `scripts/store_screenshots.ps1 -App client` captures the device
/// when it sees the line.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('store screenshots', (tester) async {
    await initializeDateFormatting('es_DO');

    // Long enough for the quote and the "buscando grúa" moment, short enough
    // that the tracking screen has a truck on it.
    final backend = DemoBackend(dispatchDelay: const Duration(seconds: 4))
      ..seed();

    const config = AppConfig(
      flavor: Flavor.prod,
      appKind: AppKind.client,
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
          ...demoOverrides(backend: backend),
        ],
        child: const ClientApp(),
      ),
    );
    await _settle(tester, seconds: 2);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ClientApp)),
    );
    final router = container.read(routerProvider);

    await tester.tap(find.text('Entrar con Teléfono'));
    await _waitFor(tester, find.text('Enviar código'));
    await tester.enterText(find.byType(TextFormField).first, '8094212499');
    // On a device the real keyboard comes up and covers the button.
    await _hideKeyboard(tester);
    await tester.tap(find.text('Enviar código'));
    await _waitFor(tester, find.text('Enviar código'), gone: true);
    // The office's test login; the demo accepts it like any other.
    await tester.enterText(find.byType(TextField).first, '111111');
    await _hideKeyboard(tester);
    await _waitFor(tester, find.text('PEDIR GRÚA 24/7'));

    // The seeded history leaves a chofer to rate; that card would sit over
    // the map.
    final dismiss = find.byIcon(Icons.close);
    if (dismiss.evaluate().isNotEmpty) {
      await tester.tap(dismiss.first);
      await _settle(tester);
    }

    // The nearby search runs on its own; let it find the trucks and the
    // tiles come in.
    await _shot(tester, '01_inicio', hold: 30);

    // Before the new request, so the list is the customer's past tows only.
    router.go(Routes.history);
    await _settle(tester, seconds: 2);
    await _shot(tester, '06_historial');
    router.go(Routes.home);
    await _waitFor(tester, find.text('PEDIR GRÚA 24/7'));

    unawaited(router.push<void>(Routes.request));
    await _waitFor(tester, find.text('Marca'));
    await _settle(tester, seconds: 2);

    // The destination goes through the picker, as a customer's does: the form
    // takes its address from what the picker hands back, not from the draft.
    const destination = 'Taller Autocentro, Av. Charles de Gaulle';
    container.read(requestControllerProvider.notifier).setDropoff(
          const ServiceLocation(
            geo: LatLng(18.5010, -69.8600),
            address: destination,
          ),
        );
    await _settle(tester);
    await tester.scrollUntilVisible(
      find.text(destination),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await _settle(tester);
    await tester.tap(find.text(destination));
    await _waitFor(tester, find.text('CONFIRMAR UBICACIÓN'));
    await _settle(tester, seconds: 2);
    await _hideKeyboard(tester);
    await tester.tap(find.text('CONFIRMAR UBICACIÓN'));
    await _waitFor(tester, find.text('CONFIRMAR UBICACIÓN'), gone: true);
    await _settle(tester);
    await tester.scrollUntilVisible(
      find.text('Detalles del vehículo'),
      -400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Marca'),
      'Toyota',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Modelo'),
      'Corolla',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Placa (ej. A123456)'),
      'G123456',
    );
    // What tapping the chip does; it sits below the fold, not built yet.
    final draft = container.read(requestControllerProvider.notifier);
    draft.setVehicle(
      container
          .read(requestControllerProvider)
          .vehicle
          .copyWith(condition: VehicleCondition.noArranca),
    );
    await _hideKeyboard(tester);
    await _settle(tester, seconds: 2);
    await _shot(tester, '02_solicitud');

    // The emulator's reverse geocoder times out now and then and the pickup
    // falls back to bare coordinates; name the spot it reports instead.
    container.read(requestControllerProvider.notifier).setPickup(
          const ServiceLocation(
            geo: LatLng(18.4861, -69.9312),
            address: 'Av. Winston Churchill #95, Piantini',
          ),
        );
    await _settle(tester);

    // The form is a lazy list: scroll the button into being before tapping.
    await tester.scrollUntilVisible(
      find.text('VER PRECIO'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await _settle(tester);
    await tester.tap(find.text('VER PRECIO'));
    await _settle(tester, seconds: 3);
    await _shot(tester, '03_precio');

    await _waitFor(tester, find.text('CONFIRMAR Y PEDIR GRÚA'));
    await tester.tap(find.text('CONFIRMAR Y PEDIR GRÚA'));
    // The dispatch delay, then the truck starts moving.
    await _settle(tester, seconds: 10);
    await _shot(tester, '04_seguimiento', hold: 10);

    final service = backend.allServices.firstWhere(
      (s) => s.clientId == 'demo-client-1' && !s.status.isTerminal,
    );
    final driverId = service.driverId ?? 'driver-1';
    final now = DateTime.now();
    final lines = [
      ('demo-client-1', UserRole.client, 'Buenas, ¿cuánto le falta para llegar?', 6),
      (driverId, UserRole.driver, 'Buenas. Voy en camino, llego en unos 10 minutos.', 5),
      ('demo-client-1', UserRole.client, 'Perfecto. Estoy frente a la farmacia, el carro es un Corolla gris.', 4),
      (driverId, UserRole.driver, 'Entendido, ya lo veo en el mapa. 👍', 3),
      ('demo-client-1', UserRole.client, 'Gracias, aquí lo espero.', 1),
    ];
    for (var i = 0; i < lines.length; i++) {
      final (sender, role, text, minutesAgo) = lines[i];
      backend.addMessage(
        service.id,
        ChatMessage(
          id: 'store-$i',
          senderId: sender,
          senderRole: role,
          text: text,
          sentAt: now.subtract(Duration(minutes: minutesAgo)),
        ),
      );
    }
    unawaited(router.push<void>(Routes.chatFor(service.id)));
    await _settle(tester, seconds: 2);
    await _shot(tester, '05_chat');

    debugPrint('STORE_SHOT:done');
  }, timeout: const Timeout(Duration(minutes: 10)));
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

/// Pumps until [finder] shows up (or, with [gone], goes away), and fails
/// saying which, instead of a bare "No element" two steps later.
Future<void> _waitFor(
  WidgetTester tester,
  Finder finder, {
  bool gone = false,
  int seconds = 20,
}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (DateTime.now().isBefore(end)) {
    if (finder.evaluate().isEmpty == gone) return;
    await tester.pump(const Duration(milliseconds: 100));
  }
  fail('Timed out waiting for $finder${gone ? ' to go away' : ''}');
}

/// Closes the device keyboard, which a test's enterText does not do and which
/// covers the lower half of the screen.
Future<void> _hideKeyboard(WidgetTester tester) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
  await _settle(tester);
}

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:driver_app/app.dart';
import 'package:driver_app/features/home/driver_map.dart';
import 'package:driver_app/features/home/location_publisher.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';
import 'package:grua_testing/grua_testing.dart';
import 'package:intl/date_symbol_data_local.dart';

/// The bottom bar and the four tabs behind it.
///
/// The navigation itself is go_router's; what these pin down is the chofer's
/// side of it — that each tab shows what it says, that an offer and a new job
/// pull the chofer back to where the work is, and that the chat badge counts
/// what the customer wrote and clears once it has been read.
Future<void> main() async {
  setUpAll(() => initializeDateFormatting('es_DO'));

  const config = AppConfig(
    flavor: Flavor.dev,
    appKind: AppKind.driver,
    firebaseProjectId: 'grua-rd-test',
    googleMapsApiKey: '',
    useEmulators: false,
    emulatorHost: 'localhost',
    functionsRegion: 'us-east1',
  );

  Widget harness(
    DemoBackend backend, {
    Stream<Offer?>? offers,
  }) => ProviderScope(
    overrides: [
      appConfigProvider.overrideWithValue(config),
      ...demoOverrides(backend: backend, role: UserRole.driver),
      // A chofer on a job publishes their position, and a widget test has
      // no GPS plugin to publish from.
      locationPublisherProvider.overrideWith((ref) => null),
      if (offers != null) incomingOfferProvider.overrideWith((ref) => offers),
    ],
    child: const DriverApp(),
  );

  /// A few frames, without waiting to settle: a countdown or a moving truck
  /// repaints forever.
  Future<void> frames(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> signIn(WidgetTester tester) async {
    await tester.enterText(
      find.byType(TextFormField).first,
      'driver1@gruasrd.do',
    );
    await tester.enterText(find.byType(TextFormField).last, 'secret123');
    await tester.pump();
    await tester.tap(find.text('ENTRAR'));
    await frames(tester);
  }

  Finder tab(String label) => find.descendant(
    of: find.byType(NavigationBar),
    matching: find.text(label),
  );

  Future<void> openTab(WidgetTester tester, String label) async {
    await tester.tap(tab(label));
    await frames(tester);
  }

  testWidgets('the bottom bar splits the app into Inicio, Pedidos, Chat and '
      'Perfil', (tester) async {
    final backend = DemoBackend()
      ..seed()
      ..currentUserId = 'driver-1';
    await tester.pumpWidget(harness(backend));
    await tester.pump();
    await signIn(tester);

    for (final label in ['Inicio', 'Pedidos', 'Chat', 'Perfil']) {
      expect(tab(label), findsOneWidget, reason: label);
    }
    // Inicio: the map, nothing else.
    expect(find.byType(DriverMap), findsOneWidget);
    // The chofer's photo in the header, the mark large under it.
    expect(find.byType(DriverAvatar), findsOneWidget);
    expect(tester.widget<GruaLogo>(find.byType(GruaLogo)).size, 120);
    // No "En línea" card: online is the normal state and says nothing.
    expect(find.textContaining('línea'), findsNothing);
    expect(find.text('PEDIDOS DISPONIBLES'), findsNothing);

    // Laid out, not just present: the map runs from the top of the screen to
    // the bar, with nothing covering the bottom of it.
    final barTop = tester.getTopLeft(find.byType(NavigationBar)).dy;
    final map = tester.getRect(find.byType(DriverMap));
    expect(map.top, 0);
    expect(map.bottom, barTop);
    expect(find.byType(Switch), findsNothing);
    expect(find.byKey(const Key('online-blocked')), findsNothing);

    await openTab(tester, 'Pedidos');
    expect(find.text('Mis pedidos'), findsOneWidget);
    expect(find.text('PEDIDOS DISPONIBLES'), findsOneWidget);

    await openTab(tester, 'Chat');
    expect(find.text('Mensajes'), findsOneWidget);
    expect(find.text('Sin conversación activa'), findsOneWidget);

    await openTab(tester, 'Perfil');
    expect(find.text('Mi perfil'), findsOneWidget);
    expect(find.text('Luis Fernández'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const Key('sign-out')),
      200,
      scrollable: find.descendant(
        of: find.byKey(const Key('profile-list')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(find.text('Cerrar sesión'), findsOneWidget);

    // Back to the map, as it was left.
    await openTab(tester, 'Inicio');
    expect(find.byType(DriverMap), findsOneWidget);
    expect(find.text('Mi perfil'), findsNothing);
  });

  testWidgets('an offer that arrives on another tab brings the chofer back to '
      'the map', (tester) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(430, 1100);
    addTearDown(tester.view.reset);

    final offers = StreamController<Offer?>.broadcast();
    addTearDown(offers.close);

    final backend = DemoBackend()
      ..seed()
      ..currentUserId = 'driver-1';
    await tester.pumpWidget(harness(backend, offers: offers.stream));
    await tester.pump();
    await signIn(tester);

    await openTab(tester, 'Pedidos');
    expect(find.text('Mis pedidos'), findsOneWidget);

    offers.add(
      Offer(
        serviceId: 'svc-offer-1',
        driverId: 'driver-1',
        serviceCode: 'GR-260911-0512',
        pickupAddress: 'Av. Abraham Lincoln 1003',
        pickupGeo: const LatLng(18.4712, -69.9061),
        vehicleLabel: 'Toyota Corolla 2018',
        condition: VehicleCondition.noArranca,
        netEarningsCents: 187500,
        grossCents: 250000,
        distanceMeters: 4100,
        etaSeconds: 540,
        expiresAt: clock.now().toUtc().add(const Duration(seconds: 25)),
      ),
    );
    await frames(tester);

    expect(find.text('NUEVA SOLICITUD'), findsOneWidget);
    expect(find.text('ACEPTAR'), findsOneWidget);
    expect(find.text('Mis pedidos'), findsNothing);
  });

  testWidgets('the chofer chats with the customer, and the Chat badge counts '
      'unread messages until they are read', (tester) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(430, 1100);
    addTearDown(tester.view.reset);

    final backend = DemoBackend(dispatchDelay: const Duration(milliseconds: 20))
      ..seed();
    addTearDown(backend.dispose);

    // A job already assigned, the way the cascade leaves it; sign in as
    // whichever chofer it went to.
    final service = (await tester.runAsync(() => _dispatchedService(backend)))!;
    backend.currentUserId = service.driverId!;

    await tester.pumpWidget(harness(backend));
    await tester.pump();
    await signIn(tester);

    // The job wins: Inicio shows the service screen, with the bar under it.
    expect(find.text('EN SERVICIO'), findsOneWidget);
    expect(tab('Chat'), findsOneWidget);

    // From the customer card, straight into the conversation.
    await tester.tap(find.byKey(const Key('client-chat')));
    await frames(tester);
    expect(find.text('Escribe un mensaje…'), findsOneWidget);

    await tester.enterText(find.byType(TextField).last, 'Voy en camino');
    await tester.tap(find.byIcon(Icons.send));
    await frames(tester);
    // The bubble it sent.
    expect(find.text('Voy en camino'), findsOneWidget);

    final sent = (await tester.runAsync(
      () => backend.messagesFor(service.id).first,
    ))!;
    expect(sent.single.senderRole, UserRole.driver);
    expect(sent.single.senderId, service.driverId);

    // Not pageBack(): it looks for the English "Back" tooltip, and this app
    // speaks Spanish.
    await tester.tap(find.byType(BackButton));
    await frames(tester);

    // The customer answers while the chat is closed.
    backend.addMessage(
      service.id,
      ChatMessage(
        id: 'm-client-1',
        senderId: service.clientId,
        senderRole: UserRole.client,
        text: 'Estoy frente a la farmacia',
        sentAt: DateTime.now().toUtc(),
      ),
    );
    await frames(tester);

    Finder chatBadge(String count) => find.descendant(
      of: find.byKey(const Key('chat-badge')),
      matching: find.text(count),
    );
    expect(chatBadge('1'), findsOneWidget);

    await openTab(tester, 'Chat');
    expect(find.byKey(const Key('active-conversation')), findsOneWidget);
    // In the conversation's preview — the banner that announced it may
    // still be showing the same words over the tab.
    expect(
      find.descendant(
        of: find.byKey(const Key('active-conversation')),
        matching: find.text('Estoy frente a la farmacia'),
      ),
      findsOneWidget,
    );

    // Opening it reads it.
    await tester.tap(find.byKey(const Key('active-conversation')));
    await frames(tester);
    expect(find.text('Estoy frente a la farmacia'), findsOneWidget);

    // Not pageBack(): it looks for the English "Back" tooltip, and this app
    // speaks Spanish.
    await tester.tap(find.byType(BackButton));
    await frames(tester);
    expect(chatBadge('1'), findsNothing);
  });
}

/// Creates a service and waits for the simulated cascade to assign a chofer.
Future<Service> _dispatchedService(DemoBackend backend) async {
  final created = backend.createService(
    clientId: 'demo-client-1',
    pickup: const ServiceLocation(
      geo: DoLocations.santoDomingo,
      address: 'Av. 27 de Febrero',
    ),
    dropoff: const ServiceLocation(geo: DoLocations.sanPedro),
    vehicle: const ServiceVehicle(condition: VehicleCondition.noArranca),
    truckType: TruckType.gancho,
    quote: const Quote(totalCents: 250000),
    route: const ServiceRoute(distanceMeters: 12000),
  );

  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final current = backend.service(created.id);
    if (current != null && current.hasDriver) return current;
  }
  fail('the demo cascade never assigned a chofer');
}

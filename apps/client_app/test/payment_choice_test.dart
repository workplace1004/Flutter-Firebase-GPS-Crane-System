import 'package:client_app/features/payment/payment_choice_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';
import 'package:grua_testing/grua_testing.dart';
import 'package:intl/date_symbol_data_local.dart';

/// What the customer owes when the chofer arrives: cash, and how much, before
/// the vehicle is loaded rather than at the destination.
Future<void> main() async {
  setUpAll(() => initializeDateFormatting('es_DO'));

  late DemoBackend backend;
  late Service service;

  Future<void> pumpCard(WidgetTester tester) async {
    backend = DemoBackend(dispatchDelay: const Duration(hours: 1))..seed();
    service = backend.createService(
      clientId: 'demo-client-1',
      pickup: const ServiceLocation(geo: LatLng(18.4795, -69.9420), address: 'Gazcue'),
      dropoff: const ServiceLocation(geo: LatLng(18.5001, -69.8800)),
      vehicle: const ServiceVehicle(make: 'Toyota', model: 'Corolla'),
      truckType: TruckType.gancho,
      quote: const Quote(totalCents: 250000),
      route: const ServiceRoute(distanceMeters: 8000),
    );
    final driver = backend.allDrivers
        .firstWhere((d) => d.truckType == TruckType.gancho && d.status.canWork && !d.isBusy);
    expect(backend.assignServiceManually(serviceId: service.id, driverId: driver.id), isNull);
    backend.transition(service.id, ServiceStatus.arrived, ServiceEventName.markArrived,
        driver.id, UserRole.driver);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...demoOverrides(backend: backend),
          currentUserIdProvider.overrideWithValue('demo-client-1'),
        ],
        child: MaterialApp(
          theme: AppTheme.phone(),
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) {
                final live = ref.watch(serviceByIdProvider(service.id)).value;
                return live == null
                    ? const SizedBox.shrink()
                    : SingleChildScrollView(child: PaymentChoiceCard(service: live));
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    backend.dispose();
    await tester.pump();
  }

  testWidgets('says what to have ready, in cash, with the amount', (tester) async {
    await pumpCard(tester);

    expect(find.text('Pagarás en efectivo'), findsOneWidget);
    expect(
      find.text(r'Entrégale RD$ 2,500.00 al chofer al terminar.'),
      findsOneWidget,
    );
    // Nothing to choose: there is no other way to pay.
    expect(find.byKey(const Key('pay-card')), findsNothing);

    await finish(tester);
  });

  testWidgets('once the chofer has the money it says so instead', (tester) async {
    await pumpCard(tester);
    final driverId = backend.service(service.id)!.driverId!;

    backend
      ..transition(service.id, ServiceStatus.inProgress,
          ServiceEventName.startService, driverId, UserRole.driver)
      ..transition(service.id, ServiceStatus.completed,
          ServiceEventName.completeService, driverId, UserRole.driver)
      ..confirmCashCollected(service.id, driverId, 250000);
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Pagado'), findsOneWidget);
    expect(find.text('Pagado en efectivo'), findsOneWidget);

    await finish(tester);
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';
import 'package:grua_testing/grua_testing.dart';

/// Vehículos pesados: an estimate, and an operator who confirms before a grúa
/// goes. Over the demo backend, which mirrors `requestService` and
/// `confirmHeavyService`.
void main() {
  late DemoBackend backend;

  const pickup = ServiceLocation(geo: LatLng(18.4795, -69.9420), address: 'Gazcue');
  const dropoff = ServiceLocation(geo: LatLng(18.5001, -69.8800), address: 'Taller');

  setUp(() {
    backend = DemoBackend(dispatchDelay: const Duration(minutes: 5))..seed();
  });
  tearDown(() => backend.dispose());

  Service request(VehicleType type) {
    final quote = Pricing.quoteFor(
      config: backend.pricing,
      vehicleType: type,
      distance: TripDistance.city(10, includedKm: 5),
      at: DateTime.utc(2026, 6, 15, 16),
      chargeItbis: false,
    );
    return backend.createService(
      clientId: 'demo-client-1',
      pickup: pickup,
      dropoff: dropoff,
      vehicle: ServiceVehicle(type: type),
      truckType: ServiceVehicle(type: type).inferredTruckType,
      quote: quote,
      route: const ServiceRoute(distanceMeters: 10000),
    );
  }

  test('a heavy request waits for the operator instead of looking for a grúa', () {
    final service = request(VehicleType.patana);

    expect(service.status, ServiceStatus.needsManual);
    expect(service.awaitsOperator, isTrue);
    expect(service.truckTypeRequired, TruckType.pesada);
    expect(service.operatorReview!.estimatedTotalCents, 800000 + 5 * 40000);
    expect(service.dispatch.lastReason, contains('Vehículo pesado'));
  });

  test('a light request goes straight to dispatch', () {
    final service = request(VehicleType.suv);
    expect(service.status, ServiceStatus.pendingDispatch);
    expect(service.awaitsOperator, isFalse);
    expect(service.operatorReview, isNull);
  });

  test('nobody can be sent before the operator confirms', () {
    final service = request(VehicleType.camion);
    final driver = backend.allDrivers.firstWhere(
      (d) => d.truckType == TruckType.pesada && d.status.canWork && !d.isBusy,
      orElse: () => backend.allDrivers.first,
    );

    expect(
      backend.assignServiceManually(serviceId: service.id, driverId: driver.id),
      'Confirma primero la disponibilidad y el precio con el cliente.',
    );
    expect(backend.service(service.id)!.hasDriver, isFalse);
  });

  test("the operator's price becomes the price, and then it looks for a grúa", () {
    final service = request(VehicleType.equipoPesado);

    final refusal = backend.confirmHeavyService(
      serviceId: service.id,
      totalCents: 1500000,
      note: 'Acordado por teléfono',
    );

    expect(refusal, isNull);
    final confirmed = backend.service(service.id)!;
    expect(confirmed.status, ServiceStatus.pendingDispatch);
    expect(confirmed.awaitsOperator, isFalse);
    expect(confirmed.operatorReview!.isConfirmed, isTrue);
    expect(confirmed.operatorReview!.confirmedTotalCents, 1500000);
    expect(confirmed.totalCents, 1500000);
    expect(confirmed.dispatch.lastReason, isEmpty);
    // The receipt still shows where the price started.
    expect(confirmed.quote.baseCents, 1000000);
    expect(
      confirmed.quote.breakdown.map((l) => l.label),
      contains('Ajuste confirmado por el operador'),
    );

    // Confirmed once is confirmed.
    expect(
      backend.confirmHeavyService(serviceId: service.id, totalCents: 1400000),
      'Este servicio no tiene un precio por confirmar.',
    );
  });
}

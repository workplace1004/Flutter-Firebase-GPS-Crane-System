import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';
import 'package:grua_testing/grua_testing.dart';

/// Paying for a tow, on the in-memory backend that mirrors the callables.
///
/// Every tow is cash: the customer hands it to the chofer at the end, the
/// chofer marks it collected, and it stays with them until the office receives
/// it at a corte.
void main() {
  const client = 'demo-client-1';
  const staff = 'demo-admin';

  late DemoBackend backend;
  late String driverId;
  late Service service;

  /// A job with its chofer standing at the pickup.
  void arrived() {
    backend = DemoBackend(dispatchDelay: const Duration(hours: 1))..seed();
    service = backend.createService(
      clientId: client,
      pickup: const ServiceLocation(geo: LatLng(18.4795, -69.9420), address: 'Gazcue'),
      dropoff: const ServiceLocation(geo: LatLng(18.5001, -69.8800)),
      vehicle: const ServiceVehicle(condition: VehicleCondition.noArranca),
      truckType: TruckType.gancho,
      quote: const Quote(totalCents: 250000),
      route: const ServiceRoute(distanceMeters: 8000),
    );
    driverId = backend.allDrivers
        .firstWhere((d) => d.truckType == TruckType.gancho && d.status.canWork && !d.isBusy)
        .id;
    expect(backend.assignServiceManually(serviceId: service.id, driverId: driverId), isNull);
    backend.transition(
      service.id,
      ServiceStatus.arrived,
      ServiceEventName.markArrived,
      driverId,
      UserRole.driver,
    );
  }

  Service current() => backend.service(service.id)!;

  tearDown(() => backend.dispose());

  test('a job is cash from the moment it is requested', () {
    arrived();
    expect(current().payment.isCash, isTrue);
    expect(current().payment.isPaid, isFalse);
  });

  test('the chofer starts without waiting on anything', () {
    // There used to be a card hold to wait for here. Nothing stands between
    // arriving and loading any more.
    arrived();
    expect(
      backend.transition(service.id, ServiceStatus.inProgress,
          ServiceEventName.startService, driverId, UserRole.driver),
      isA<Ok<void>>(),
    );
    expect(current().status, ServiceStatus.inProgress);
  });

  group('cash and the corte', () {
    void collect() {
      backend
        ..transition(service.id, ServiceStatus.inProgress,
            ServiceEventName.startService, driverId, UserRole.driver)
        ..transition(service.id, ServiceStatus.completed,
            ServiceEventName.completeService, driverId, UserRole.driver);
      expect(backend.confirmCashCollected(service.id, driverId, 250000), isA<Ok<void>>());
    }

    /// Cash this chofer already held from seeded jobs, before this one.
    int heldBefore() => backend
        .uncountedCash(driverId)
        .fold(0, (sum, s) => sum + s.payment.capturedCents);

    test('a completed job waits on the chofer confirming they have the money', () {
      arrived();
      backend
        ..transition(service.id, ServiceStatus.inProgress,
            ServiceEventName.startService, driverId, UserRole.driver)
        ..transition(service.id, ServiceStatus.completed,
            ServiceEventName.completeService, driverId, UserRole.driver);

      expect(current().payment.status, PaymentStatus.cashPending);
      expect(current().payment.isPaid, isFalse);
    });

    test('"Cobrado en efectivo" marks the job paid and the chofer holding it', () {
      arrived();
      final before = backend.driver(driverId)!.cashOnHandCents;
      final uncountedBefore = backend.uncountedCash(driverId).length;

      collect();

      expect(current().status, ServiceStatus.closed);
      expect(current().payment.isPaid, isTrue);
      expect(current().payment.status.label, 'Pagado en efectivo');
      expect(backend.driver(driverId)!.cashOnHandCents, before + 250000);
      expect(backend.uncountedCash(driverId), hasLength(uncountedBefore + 1));
      expect(backend.uncountedCash(driverId).map((s) => s.id), contains(service.id));
    });

    test('a corte receives it all once, and never counts the same job again', () {
      arrived();
      final earlier = backend.uncountedCash(driverId).length;
      final earlierCents = heldBefore();
      collect();

      // The chofer's balance and the jobs behind it agree.
      expect(backend.driver(driverId)!.cashOnHandCents, earlierCents + 250000);

      final corte = backend.settleDriverCash(driverId, staff, note: 'Oficina');

      expect(corte, isA<Ok<int>>());
      // Every uncounted cash job, this one and any before it.
      expect(corte.valueOrNull, earlierCents + 250000);
      expect(backend.driver(driverId)!.cashOnHandCents, 0);
      expect(backend.uncountedCash(driverId), isEmpty);
      expect(current().payment.cashSettlementId, isNotNull);

      final history = backend.cashSettlements(driverId: driverId);
      expect(history, hasLength(1));
      expect(history.single.amountCents, earlierCents + 250000);
      expect(history.single.serviceCount, earlier + 1);
      expect(history.single.note, 'Oficina');

      // Nothing left to hand in.
      expect(backend.settleDriverCash(driverId, staff), isA<Err<int>>());
    });
  });
}

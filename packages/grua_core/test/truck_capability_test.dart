import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';
import 'package:grua_testing/grua_testing.dart';

/// Which truck can take which job.
///
/// The bug this pins down: both the cascade and the demo backend demanded an
/// exact truck-type match. A customer whose car will not start needs a
/// `gancho`, and a yard whose only idle truck is a `plataforma` — parked two
/// streets from the pickup, showing "Disponible" on the dispatcher's map —
/// never got the offer. The customer watched "Buscando grúa" until dispatch
/// gave up and filed it as `needs_manual`.
void main() {
  test('a flatbed can do a hook job, and a hook cannot do a flatbed one', () {
    expect(TruckType.plataforma.canServe(TruckType.gancho), isTrue);
    expect(TruckType.gancho.canServe(TruckType.plataforma), isFalse);
  });

  test('heavy recovery neither substitutes nor is substituted for', () {
    expect(TruckType.pesada.canServe(TruckType.gancho), isFalse);
    expect(TruckType.gancho.canServe(TruckType.pesada), isFalse);
    expect(TruckType.plataforma.canServe(TruckType.pesada), isFalse);
    expect(TruckType.pesada.canServe(TruckType.pesada), isTrue);
  });

  group('the demo cascade', () {
    late DemoBackend backend;

    const pickup = ServiceLocation(
      geo: LatLng(19.1221, -70.6367),
      address: 'Maria Auxiliadora, Jarabacoa',
      reference: 'Frente a la farmacia',
    );
    const dropoff = ServiceLocation(
      geo: LatLng(19.1300, -70.6400),
      address: 'Carr. Palo Blanco',
    );

    setUp(
      () => backend = DemoBackend(dispatchDelay: const Duration(milliseconds: 10))
        ..seed(),
    );
    tearDown(() => backend.dispose());

    /// Parks [driver] at [at] and puts them on the road.
    void putOnTheRoad(Driver driver, LatLng at) {
      backend
        ..setLive(
          DriverLivePosition(
            driverId: driver.id,
            lat: at.latitude,
            lng: at.longitude,
            isOnline: true,
            truckType: driver.truckType,
            updatedAt: DateTime.now().toUtc().millisecondsSinceEpoch,
          ),
        )
        ..setDriverOnline(driver.id, online: true);
    }

    /// Takes every seeded chofer off the road, so a test controls the yard.
    void emptyTheYard() {
      for (final driver in backend.allDrivers) {
        backend.setDriverOnline(driver.id, online: false);
      }
    }

    Driver idleTruck(TruckType type) => backend.allDrivers.firstWhere(
          (d) =>
              d.truckType == type &&
              d.status.canWork &&
              (d.currentServiceId ?? '').isEmpty,
        );

    Service requestGancho() => backend.createService(
          clientId: 'demo-client-1',
          pickup: pickup,
          dropoff: dropoff,
          // "No arranca" on a sedan: the everyday hook job.
          vehicle: const ServiceVehicle(
            make: 'Toyota',
            model: 'Corolla',
            condition: VehicleCondition.noArranca,
          ),
          truckType: TruckType.gancho,
          quote: const Quote(totalCents: 250000),
          route: const ServiceRoute(distanceMeters: 4200),
        );

    test('gives a hook job to the flatbed when no hook truck is online',
        () async {
      emptyTheYard();
      final flatbed = idleTruck(TruckType.plataforma);
      putOnTheRoad(flatbed, pickup.geo);

      final service = requestGancho();
      await Future<void>.delayed(const Duration(milliseconds: 60));

      final assigned = backend.service(service.id)!;
      expect(
        assigned.status,
        isNot(ServiceStatus.needsManual),
        reason: 'a capable truck was idle at the pickup',
      );
      expect(assigned.driverId, flatbed.id);
    });

    test('still prefers the hook truck when there is one', () async {
      emptyTheYard();
      final flatbed = idleTruck(TruckType.plataforma);
      final hook = idleTruck(TruckType.gancho);

      // The flatbed is the closer of the two: the right truck still wins.
      putOnTheRoad(flatbed, pickup.geo);
      putOnTheRoad(hook, const LatLng(19.1280, -70.6420));

      final service = requestGancho();
      await Future<void>.delayed(const Duration(milliseconds: 60));

      final assigned = backend.service(service.id)!;
      expect(assigned.driverId, hook.id);
    });

    test('a flatbed job is never handed to a hook truck', () async {
      emptyTheYard();
      final hook = idleTruck(TruckType.gancho);
      putOnTheRoad(hook, pickup.geo);

      final service = backend.createService(
        clientId: 'demo-client-1',
        pickup: pickup,
        dropoff: dropoff,
        // Rolled over: it cannot be towed on its own wheels at all.
        vehicle: const ServiceVehicle(
          make: 'Toyota',
          model: 'Corolla',
          condition: VehicleCondition.volcado,
        ),
        truckType: TruckType.plataforma,
        quote: const Quote(totalCents: 250000),
        route: const ServiceRoute(distanceMeters: 4200),
      );
      await Future<void>.delayed(const Duration(milliseconds: 60));

      final assigned = backend.service(service.id)!;
      expect(assigned.driverId, isNot(hook.id));
      expect(assigned.status, ServiceStatus.needsManual);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';
import 'package:grua_testing/grua_testing.dart';

/// A dispatcher handing a job to a chofer by hand.
///
/// The button for this existed for a while and did nothing at all: it showed
/// "Asignando a …" and never called anything, because no `assignServiceManually`
/// existed anywhere in the app. The chofer it named was never told. These pin
/// the whole path — the refusals as much as the success, since a dispatcher
/// acting on a list a few seconds stale has to be told no rather than quietly
/// given a chofer who is already towing something.
void main() {
  late DemoBackend backend;

  const pickup = ServiceLocation(
    geo: LatLng(18.4795, -69.9420),
    address: 'Gazcue',
    reference: 'Frente al colmado',
  );
  const dropoff = ServiceLocation(
    geo: LatLng(18.5001, -69.8800),
    address: 'Taller Hermanos Pérez',
  );

  setUp(() {
    // Long enough that the automatic cascade does not take the job first; the
    // dispatcher is the one assigning here.
    backend = DemoBackend(dispatchDelay: const Duration(minutes: 5))..seed();
  });
  tearDown(() => backend.dispose());

  Service request({TruckType truckType = TruckType.gancho}) =>
      backend.createService(
        clientId: 'demo-client-1',
        pickup: pickup,
        dropoff: dropoff,
        vehicle: const ServiceVehicle(condition: VehicleCondition.noArranca),
        truckType: truckType,
        quote: const Quote(totalCents: 250000),
        route: const ServiceRoute(distanceMeters: 8000),
      );

  Driver freeDriverWith(TruckType type) => backend.allDrivers.firstWhere(
        (d) => d.truckType == type && d.status.canWork && !d.isBusy,
      );

  test('the chofer ends up on the job, with the customer able to see them',
      () async {
    final service = request();
    final driver = freeDriverWith(TruckType.gancho);

    final refusal = backend.assignServiceManually(
      serviceId: service.id,
      driverId: driver.id,
    );

    expect(refusal, isNull);

    final assigned = backend.service(service.id)!;
    expect(assigned.status, ServiceStatus.accepted);
    expect(assigned.driverId, driver.id);
    expect(assigned.driverName, driver.name);
    expect(assigned.driverPhone, isNotEmpty);
    expect(assigned.assignmentMode, AssignmentMode.manual);
    // The customer's card shows the chofer's face, not a letter.
    expect(assigned.driverPhotoUrl, driver.photoUrl);

    // The chofer is committed, so the cascade cannot hand them a second job.
    expect(backend.driver(driver.id)!.currentServiceId, service.id);

    // And the customer's tracking map has somebody on it — the thing a second
    // copy of this logic would have been most likely to forget.
    expect(await backend.trackingFor(service.id).first, isNotNull);
  });

  test("the chofer's photo travels onto the service", () {
    final service = request();
    final driver = freeDriverWith(TruckType.gancho);
    const photo = 'data:image/png;base64,iVBORw0KGgo=';
    backend.storeUpload('drivers/${driver.id}/photo.png', photo);
    expect(backend.setDriverPhoto(driver.id, 'drivers/${driver.id}/photo.png'), photo);

    backend.assignServiceManually(serviceId: service.id, driverId: driver.id);

    expect(backend.service(service.id)!.driverPhotoUrl, photo);
  });

  test('the assignment is written as manual, not as an automatic accept', () {
    final service = request();
    final driver = freeDriverWith(TruckType.gancho);

    backend.assignServiceManually(serviceId: service.id, driverId: driver.id);

    final events = backend.eventsFor(service.id);
    expect(
      events.map((e) => e.event),
      contains(ServiceEventName.assignServiceManually),
    );
  });

  test('a chofer already on a job is refused', () {
    final first = request();
    final driver = freeDriverWith(TruckType.gancho);
    backend.assignServiceManually(serviceId: first.id, driverId: driver.id);

    final second = request();
    final refusal = backend.assignServiceManually(
      serviceId: second.id,
      driverId: driver.id,
    );

    expect(refusal, 'Ese chofer ya tiene un servicio.');
    expect(backend.service(second.id)!.hasDriver, isFalse);
  });

  test('a chofer whose grúa cannot do the job is refused', () {
    // A gancho tows on the vehicle's own wheels; a rolled car needs a flatbed,
    // and wanting to send the nearest truck does not change that.
    final service = request(truckType: TruckType.plataforma);
    final driver = freeDriverWith(TruckType.gancho);

    final refusal = backend.assignServiceManually(
      serviceId: service.id,
      driverId: driver.id,
    );

    expect(refusal, contains('Plataforma'));
    expect(backend.service(service.id)!.hasDriver, isFalse);
  });

  test('a flatbed may be sent to a hook job, as the cascade would', () {
    final service = request();
    final flatbed = freeDriverWith(TruckType.plataforma);

    final refusal = backend.assignServiceManually(
      serviceId: service.id,
      driverId: flatbed.id,
    );

    expect(refusal, isNull);
    expect(backend.service(service.id)!.driverId, flatbed.id);
  });

  test('a job somebody already took is refused', () {
    final service = request();
    final first = freeDriverWith(TruckType.gancho);
    backend.assignServiceManually(serviceId: service.id, driverId: first.id);

    final second = backend.allDrivers.firstWhere(
      (d) => d.id != first.id && d.status.canWork && !d.isBusy,
    );
    final refusal = backend.assignServiceManually(
      serviceId: service.id,
      driverId: second.id,
    );

    expect(refusal, 'Este servicio ya no está esperando chofer.');
    expect(backend.service(service.id)!.driverId, first.id);
  });

  test('an inactive chofer is refused', () {
    final service = request();
    final driver = freeDriverWith(TruckType.gancho);
    backend.setDriverStatus(driver.id, DriverStatus.suspended, reason: 'Papeles');

    final refusal = backend.assignServiceManually(
      serviceId: service.id,
      driverId: driver.id,
    );

    expect(refusal, 'Ese chofer no está activo.');
  });
}

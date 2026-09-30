import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';
import 'package:grua_testing/grua_testing.dart';

/// The demo backend's fleet operations must refuse and clean up the way
/// `callables/trucks.ts` does, or the panel is built against a server that does
/// not exist.
void main() {
  late DemoBackend backend;

  setUp(() => backend = DemoBackend()..seed());

  TruckDetails details({
    String plate = 'L777888',
    TruckType type = TruckType.plataforma,
    String make = 'Isuzu',
  }) =>
      TruckDetails(
        plate: plate,
        make: make,
        model: 'NQR',
        year: 2022,
        type: type,
        capacityKg: 5000,
        insuranceExpiry: DateTime.utc(2027, 3, 1),
        marbeteExpiry: DateTime.utc(2027, 6, 1),
      );

  test('a new grúa is stored with its plate normalised, unassigned', () {
    final id = backend.createTruck(details(plate: ' l-777 888 ')).valueOrNull!;

    final truck = backend.truck(id)!;
    expect(truck.plate, 'L777888');
    expect(truck.isAssigned, isFalse);
    expect(truck.active, isTrue);
    expect(truck.type, TruckType.plataforma);
  });

  test('a plate already in the fleet is refused, however it is typed', () {
    // A123456 is seeded on truck-1.
    final result = backend.createTruck(details(plate: 'a-123456'));

    expect(result.failureOrNull?.userMessage, 'Ya existe una grúa con esa placa.');
  });

  test('a malformed plate is refused', () {
    expect(backend.createTruck(details(plate: '12345')).isErr, isTrue);
  });

  test('a new plate on an assigned grúa reaches its chofer', () {
    // truck-1 is seeded on driver-1.
    final refusal = backend.updateTruck('truck-1', details(plate: 'L111222'));

    expect(refusal, isNull);
    expect(backend.truck('truck-1')!.plate, 'L111222');
    expect(backend.driver('driver-1')!.assignedTruckPlate, 'L111222');
  });

  test('the type cannot change while the chofer on the grúa is online', () {
    backend.setDriverOnline('driver-1', online: true);
    final original = backend.truck('truck-1')!.type;

    final refusal = backend.updateTruck(
      'truck-1',
      details(plate: 'A123456', type: TruckType.pesada),
    );

    expect(refusal?.code, FailureCode.driverBusy);
    expect(backend.truck('truck-1')!.type, original);
  });

  test('offline, a type change reaches the chofer too', () {
    backend.setDriverOnline('driver-1', online: false);

    final refusal = backend.updateTruck(
      'truck-1',
      details(plate: 'A123456', type: TruckType.pesada),
    );

    expect(refusal, isNull);
    expect(backend.driver('driver-1')!.truckType, TruckType.pesada);
  });

  test('deleting a grúa frees its plate and takes its chofer offline', () {
    backend.setDriverOnline('driver-1', online: true);

    expect(backend.archiveTruck('truck-1'), isNull);

    final truck = backend.truck('truck-1')!;
    expect(truck.archived, isTrue);
    expect(truck.isAssigned, isFalse);
    final driver = backend.driver('driver-1')!;
    expect(driver.assignedTruckId, isNull);
    expect(driver.isOnline, isFalse);
    // The plate can be registered again.
    expect(backend.createTruck(details(plate: 'A123456')).isOk, isTrue);
  });
}

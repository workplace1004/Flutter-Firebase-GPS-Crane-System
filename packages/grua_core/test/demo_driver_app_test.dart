import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';
import 'package:grua_testing/grua_testing.dart';

/// The driver app's demo, walked by hand: it signs in as a chofer, shows last
/// week's corte, and sends requests while the chofer is online.
void main() {
  late DemoBackend backend;

  setUp(() {
    backend = DemoBackend(dispatchDelay: const Duration(milliseconds: 10))..seed();
  });
  tearDown(() => backend.dispose());

  Future<Service?> assignedTo(String driverId) async {
    for (var i = 0; i < 200; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      for (final s in backend.allServices) {
        if (s.driverId == driverId && s.isActive) return s;
      }
    }
    return null;
  }

  test('signs in as the chofer with that email, or the first one', () async {
    final auth = DemoAuthRepository(backend, role: UserRole.driver);
    await auth.signInWithEmail('driver3@gruasrd.do', 'secret');
    expect(auth.currentUserId, 'driver-3');

    final other = DemoBackend()..seed();
    addTearDown(other.dispose);
    final fallback = DemoAuthRepository(other, role: UserRole.driver);
    await fallback.signInWithEmail('nadie@x.do', 'secret');
    expect(fallback.currentUserId, 'driver-1');
  });

  test('a test that chose the chofer keeps its choice', () async {
    backend.currentUserId = 'driver-2';
    final auth = DemoAuthRepository(backend, role: UserRole.driver);
    await auth.signInWithEmail('driver1@gruasrd.do', 'secret');
    expect(auth.currentUserId, 'driver-2');
  });

  test('with requests on, the chofer has last week’s corte waiting', () async {
    backend.startRequestSimulator(every: const Duration(hours: 1));
    await DemoAuthRepository(backend, role: UserRole.driver)
        .signInWithEmail('driver1@gruasrd.do', 'secret');
    final corte = backend.driverSettlements(driverId: 'driver-1').single;
    // Carlos's week: 8,050 − 1,800.
    expect(corte.insuranceOwedCents, 805000);
    expect(corte.commissionOwedCents, 180000);
    expect(corte.finalBalanceCents, 625000);
    expect(corte.isPending, isTrue);
    expect(corte.periodEnd!.isBefore(DateTime.now().toUtc()), isTrue);
  });

  test('an online chofer gets an insurer tow, then a customer tow', () async {
    backend
      ..currentUserId = 'driver-1'
      ..setDriverOnline('driver-1', online: true)
      ..startRequestSimulator(every: const Duration(milliseconds: 30));

    final first = await assignedTo('driver-1');
    expect(first, isNotNull);
    expect(first!.isInsurerJob, isTrue);
    expect(first.insurance?.claimNumber, 'SIN-DEMO-001');

    // Nothing more while busy; the next one after the job is done.
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(backend.allServices.where((s) => s.driverId == 'driver-1' && s.isActive), hasLength(1));
    for (final (to, event) in [
      (ServiceStatus.arrived, ServiceEventName.markArrived),
      (ServiceStatus.inProgress, ServiceEventName.startService),
      (ServiceStatus.completed, ServiceEventName.completeService),
      (ServiceStatus.closed, ServiceEventName.closeService),
    ]) {
      backend.transition(first.id, to, event, 'driver-1', UserRole.driver);
    }
    final second = await assignedTo('driver-1');
    expect(second, isNotNull);
    expect(second!.isInsurerJob, isFalse);
    expect(second.payment.isCash, isTrue);
  });

  test('an offline chofer gets nothing', () async {
    backend
      ..currentUserId = 'driver-1'
      ..setDriverOnline('driver-1', online: false)
      ..startRequestSimulator(every: const Duration(milliseconds: 20));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(backend.allServices.where((s) => s.driverId == 'driver-1' && s.isActive), isEmpty);
  });
}

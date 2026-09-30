import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';
import 'package:grua_testing/grua_testing.dart';

/// The demo backend's weekly cortes have to behave like the callables, or the
/// screens are built against a server that does not exist.
void main() {
  const pickup = ServiceLocation(
    geo: DoLocations.santoDomingo,
    address: 'Av. 27 de Febrero',
  );
  final dropoff = ServiceLocation(
    geo: LatLng(
      DoLocations.santoDomingo.latitude + 0.008,
      DoLocations.santoDomingo.longitude,
    ),
  );

  late DemoBackend backend;

  setUp(() {
    backend = DemoBackend(dispatchDelay: const Duration(milliseconds: 20))
      ..seed();
  });
  tearDown(() => backend.dispose());

  Future<Service> assigned(String id) async {
    for (var i = 0; i < 100; i++) {
      final s = backend.service(id);
      if (s?.driverId != null) return s!;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    throw StateError('Nobody took $id');
  }

  void finish(Service s) {
    for (final (to, event) in [
      (ServiceStatus.arrived, ServiceEventName.markArrived),
      (ServiceStatus.inProgress, ServiceEventName.startService),
      (ServiceStatus.completed, ServiceEventName.completeService),
    ]) {
      backend.transition(s.id, to, event, s.driverId!, UserRole.driver);
    }
  }

  /// One insurer job (RD$1,750 to the chofer) and one cash job of RD$4,000
  /// (RD$800 to Titan), both for the same chofer.
  Future<String> aWeek() async {
    final insurerJob = await assigned(
      backend
          .createInsurerService(
            insurerId: 'ins-demo',
            insurerName: 'Seguros Demo',
            requestedBy: 'op-demo',
            pickup: pickup,
            dropoff: dropoff,
            vehicle: const ServiceVehicle(),
            insurance: const InsuranceClaim(claimNumber: 'SIN-1'),
          )
          .id,
    );
    final driverId = insurerJob.driverId!;
    finish(insurerJob);

    final cashJob = await assigned(
      backend
          .createService(
            clientId: 'demo-client-1',
            pickup: pickup,
            dropoff: dropoff,
            vehicle: const ServiceVehicle(),
            truckType: TruckType.gancho,
            quote: const Quote(totalCents: 400000),
            route: const ServiceRoute(distanceMeters: 1000),
            preferredDriverId: driverId,
          )
          .id,
    );
    expect(cashJob.driverId, driverId);
    finish(cashJob);
    return driverId;
  }

  test('a week nets the insurer share against the cash commission', () async {
    final driverId = await aWeek();

    final result = backend.generateDriverSettlements(
      driverId: driverId,
      actorId: 'admin',
    );
    final id = result.valueOrNull!.single;
    final corte = backend.driverSettlement(id)!;

    expect(corte.insuranceOwedCents, 175000);
    expect(corte.commissionOwedCents, 80000);
    expect(corte.finalBalanceCents, 95000);
    expect(corte.direction, SettlementDirection.toDriver);
    expect(corte.isPending, isTrue);
    expect(corte.insurerLines, hasLength(1));
    expect(corte.cashLines, hasLength(1));
    expect(corte.payBy!.toUtc().hour, 21);

    expect(backend.earningEntries(driverId).every((e) => e.settled), isTrue);
    expect(
      backend.generateDriverSettlements(driverId: driverId, actorId: 'admin').valueOrNull,
      isEmpty,
    );
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('closing needs a reference, and happens once', () async {
    final driverId = await aWeek();
    final id = backend
        .generateDriverSettlements(driverId: driverId, actorId: 'admin')
        .valueOrNull!
        .single;

    final owedBefore = backend.earnings(driverId)?.cashOwedCents ?? 0;
    final missing = backend.settleDriverSettlement(id, reference: ' ');
    expect(missing.failureOrNull?.code, FailureCode.invalidInput);

    expect(backend.settleDriverSettlement(id, reference: 'BPD-1').isOk, isTrue);
    final closed = backend.driverSettlement(id)!;
    expect(closed.status, SettlementStatus.settled);
    expect(closed.reference, 'BPD-1');
    // The corte's RD$800 commission is paid; anything owed from before stays.
    expect(backend.earnings(driverId)?.cashOwedCents ?? 0, owedBefore - 80000);

    expect(
      backend.settleDriverSettlement(id, reference: 'BPD-2').failureOrNull?.code,
      FailureCode.invalidTransition,
    );
    expect(
      backend.voidDriverSettlement(id, reason: 'error').failureOrNull?.code,
      FailureCode.invalidTransition,
    );
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('cancelling gives the jobs back to the next corte', () async {
    final driverId = await aWeek();
    final first = backend
        .generateDriverSettlements(driverId: driverId, actorId: 'admin')
        .valueOrNull!
        .single;

    expect(backend.voidDriverSettlement(first, reason: 'x').isErr, isTrue);
    expect(backend.voidDriverSettlement(first, reason: 'Precio mal').isOk, isTrue);
    expect(backend.driverSettlement(first)!.status, SettlementStatus.voided);
    expect(backend.earningEntries(driverId).every((e) => !e.settled), isTrue);

    final second = backend
        .generateDriverSettlements(driverId: driverId, actorId: 'admin')
        .valueOrNull!
        .single;
    expect(second, isNot(first));
    expect(backend.driverSettlement(second)!.finalBalanceCents, 95000);

    // Newest first.
    expect(
      backend.driverSettlements(driverId: driverId).map((s) => s.id),
      [second, first],
    );
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('the chofer sees what Friday’s corte will say before it is made',
      () async {
    final driverId = await aWeek();
    backend.currentUserId = driverId;
    final container = ProviderContainer(
      overrides: [
        ...demoOverrides(backend: backend, role: UserRole.driver),
        // Signed in as that chofer, without walking through the login.
        currentUserIdProvider.overrideWithValue(driverId),
      ],
    );
    addTearDown(container.dispose);

    // Riverpod pauses a provider nobody listens to.
    final sub = container.listen(myRunningSettlementProvider, (_, _) {});
    addTearDown(sub.close);
    SettlementDraft? running;
    for (var i = 0; i < 100 && running == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      running = container.read(myRunningSettlementProvider).value;
    }
    expect(running?.finalBalanceCents, 95000);

    backend.generateDriverSettlements(driverId: driverId, actorId: 'admin');
    final mine = await container
        .read(earningsRepositoryProvider)
        .watchDriverSettlements(driverId: driverId)
        .first;
    expect(mine, hasLength(1));
    final after = await container
        .read(earningsRepositoryProvider)
        .watchUnsettledEntries(driverId)
        .first;
    expect(after, isEmpty);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('an unknown chofer is refused', () {
    expect(
      backend
          .generateDriverSettlements(driverId: 'nobody', actorId: 'admin')
          .failureOrNull
          ?.code,
      FailureCode.notFound,
    );
  });

  group('the office receiving cash, and the weekly corte', () {
    Future<(String, String)> collected() async {
      final driverId = await aWeek();
      final cash = backend.allServices.singleWhere(
        (s) => s.driverId == driverId && s.status == ServiceStatus.completed,
      );
      expect(backend.confirmCashCollected(cash.id, driverId, 400000).isOk, isTrue);
      return (driverId, cash.id);
    }

    test('cash a weekly corte charged is not collected again', () async {
      final (driverId, cashId) = await collected();
      final corte = backend
          .generateDriverSettlements(driverId: driverId, actorId: 'admin')
          .valueOrNull!
          .single;
      expect(backend.service(cashId)!.payment.weeklySettlementId, corte);
      // The chofer keeps that cash: it is not on the office's list.
      expect(backend.uncountedCash(driverId).map((s) => s.id), isNot(contains(cashId)));

      // Cancelled, the job is the office's to collect again.
      expect(backend.voidDriverSettlement(corte, reason: 'Precio mal').isOk, isTrue);
      expect(backend.service(cashId)!.payment.weeklySettlementId, isNull);
      expect(backend.uncountedCash(driverId).map((s) => s.id), contains(cashId));

      // Charged again, and the office's cash corte leaves it out.
      final again = backend
          .generateDriverSettlements(driverId: driverId, actorId: 'admin')
          .valueOrNull!
          .single;
      final others = backend.uncountedCash(driverId);
      final received = backend.settleDriverCash(driverId, 'ops-1');
      if (others.isEmpty) {
        expect(received.failureOrNull?.code, FailureCode.invalidTransition);
      } else {
        expect(received.valueOrNull, others.fold(0, (sum, j) => sum + j.payment.capturedCents));
      }
      expect(backend.service(cashId)!.payment.cashSettlementId, isNull);
      expect(backend.service(cashId)!.payment.weeklySettlementId, again);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('cash the office received leaves only the insurer share for Friday', () async {
      final (driverId, cashId) = await collected();
      final owedBefore = backend.driver(driverId)!.cashOwedCents;
      final waiting = backend.uncountedCash(driverId);
      expect(waiting.map((s) => s.id), contains(cashId));

      expect(
        backend.settleDriverCash(driverId, 'ops-1').valueOrNull,
        waiting.fold(0, (sum, j) => sum + j.payment.capturedCents),
      );
      expect(backend.service(cashId)!.payment.cashSettlementId, isNotNull);
      // At least this job's RD$800 commission is paid; never below zero.
      final owedAfter = backend.driver(driverId)!.cashOwedCents;
      expect(owedAfter, lessThanOrEqualTo(math.max(0, owedBefore - 80000)));
      expect(owedAfter, greaterThanOrEqualTo(0));
      expect(
        backend.earningEntries(driverId).singleWhere((e) => e.serviceId == cashId).settled,
        isTrue,
      );

      final corte = backend.driverSettlement(
        backend.generateDriverSettlements(driverId: driverId, actorId: 'admin').valueOrNull!.single,
      )!;
      expect(corte.commissionOwedCents, 0);
      expect(corte.finalBalanceCents, 175000);
    }, timeout: const Timeout(Duration(seconds: 30)));
  });

  test('the office can ask for the unpaid cortes alone', () async {
    final driverId = await aWeek();
    final paid = backend
        .generateDriverSettlements(driverId: driverId, actorId: 'admin')
        .valueOrNull!
        .single;
    backend.settleDriverSettlement(paid, reference: 'BPD-1');
    final repo = DemoEarningsRepository(backend);
    expect(await repo.watchDriverSettlements(status: SettlementStatus.pending).first, isEmpty);
    expect(
      (await repo.watchDriverSettlements(status: SettlementStatus.settled).first).single.id,
      paid,
    );
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('jobs from before cortes began are neither charged nor shown', () async {
    final driverId = await aWeek();
    backend
      ..currentUserId = driverId
      ..settlementsStartAt = DateTime.now().toUtc().add(const Duration(minutes: 1));
    expect(
      backend.generateDriverSettlements(driverId: driverId, actorId: 'admin').valueOrNull,
      isEmpty,
    );
    expect(backend.earningEntries(driverId).every((e) => !e.settled), isTrue);

    final container = ProviderContainer(
      overrides: [
        ...demoOverrides(backend: backend, role: UserRole.driver),
        currentUserIdProvider.overrideWithValue(driverId),
      ],
    );
    addTearDown(container.dispose);
    final sub = container.listen(myRunningSettlementProvider, (_, _) {});
    addTearDown(sub.close);
    AsyncValue<SettlementDraft?> running = const AsyncLoading();
    for (var i = 0; i < 100 && running.isLoading; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      running = container.read(myRunningSettlementProvider);
    }
    expect(running.hasValue, isTrue);
    expect(running.value, isNull);
  }, timeout: const Timeout(Duration(seconds: 30)));

}

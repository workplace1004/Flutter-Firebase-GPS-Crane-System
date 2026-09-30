import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';
import 'package:grua_testing/grua_testing.dart';

/// What the insurance company's own portal reads and does: this month's
/// numbers, the price before ordering, the order, and cancelling.
void main() {
  group('InsurerStats', () {
    // 15 September 2026, 10:00 in Santo Domingo.
    final now = DateTime.utc(2026, 9, 15, 14);
    final monthStart = DateTime.utc(2026, 9, 1, 4);

    Service tow(
      String id, {
      required DateTime createdAt,
      required ServiceStatus status,
      int subtotal = 250000,
      Duration? arrivedAfter,
      Duration? completedAfter,
      int feeCents = 0,
    }) =>
        Service(
          id: id,
          clientId: '',
          insurerId: 'ins-1',
          pickup: const ServiceLocation(geo: DoLocations.santoDomingo),
          status: status,
          billing: InsurerBilling(insurerId: 'ins-1', subtotalCents: subtotal),
          quote: Quote(subtotalCents: subtotal),
          createdAt: createdAt,
          cancellation: feeCents > 0 ? ServiceCancellation(feeCents: feeCents) : null,
          timeline: ServiceTimeline(
            createdAt: createdAt,
            arrivedAt: arrivedAfter == null ? null : createdAt.add(arrivedAfter),
            completedAt: completedAfter == null ? null : createdAt.add(completedAfter),
          ),
        );

    final services = [
      tow('a', createdAt: DateTime.utc(2026, 9, 2, 15), status: ServiceStatus.closed,
          arrivedAfter: const Duration(minutes: 30), completedAfter: const Duration(minutes: 90)),
      tow('b', createdAt: DateTime.utc(2026, 9, 10, 15), status: ServiceStatus.closed,
          subtotal: 350000,
          arrivedAfter: const Duration(minutes: 20), completedAfter: const Duration(minutes: 70)),
      tow('c', createdAt: DateTime.utc(2026, 9, 12, 15), status: ServiceStatus.cancelled,
          feeCents: 50000),
      tow('d', createdAt: DateTime.utc(2026, 9, 15, 13), status: ServiceStatus.accepted,
          arrivedAfter: const Duration(minutes: 40)),
      // Last month: out of this month's numbers.
      tow('e', createdAt: DateTime.utc(2026, 8, 31, 15), status: ServiceStatus.closed,
          subtotal: 999900, arrivedAfter: const Duration(hours: 5)),
    ];
    final stats = InsurerStats.of(services, now);

    test('counts this month, in Dominican time', () {
      expect(stats.monthStart, monthStart);
      expect(stats.requested, 4);
      expect(stats.completed, 2);
      expect(stats.cancelled, 1);
      expect(stats.active, 1);
    });

    test('costs the finished tows and the cancellation fee, with ITBIS', () {
      // 2,500 + 3,500 + 500 fee = 6,500, plus 18% = 7,670.
      expect(stats.cost.subtotalCents, 650000);
      expect(stats.cost.itbisCents, 117000);
      expect(stats.cost.totalCents, 767000);
    });

    test('averages the arrival and the whole tow', () {
      expect(stats.averageArrival, const Duration(minutes: 30));
      expect(stats.averageTotal, const Duration(minutes: 80));
      expect(InsurerStats.minutes(stats.averageArrival), '30 min');
      expect(InsurerStats.minutes(const Duration(minutes: 65)), '1 h 05 min');
      expect(InsurerStats.minutes(null), '—');
    });

    test('an empty month is zero, not an error', () {
      final empty = InsurerStats.of(const [], now);
      expect(empty.requested, 0);
      expect(empty.cost.totalCents, 0);
      expect(empty.averageArrival, isNull);
    });

    test('a tow ordered in August and finished in September costs September', () {
      final overnight = tow(
        'overnight',
        createdAt: DateTime.utc(2026, 9, 1, 3, 30),
        status: ServiceStatus.closed,
        completedAfter: const Duration(hours: 2),
      );
      final stats = InsurerStats.of([overnight], now);
      // Ordered in August: not one of September's requests...
      expect(stats.requested, 0);
      // ...but on September's invoice, as the invoice goes by the finish.
      expect(stats.cost.subtotalCents, 250000);
    });

    test('a tow ordered at 23:30 on the last night of August is August', () {
      final lateAugust = tow(
        'late',
        createdAt: DateTime.utc(2026, 9, 1, 3, 30),
        status: ServiceStatus.closed,
      );
      expect(InsurerStats.of([lateAugust], now).requested, 0);
    });
  });

  group('the portal on the demo backend', () {
    late DemoBackend backend;
    late ProviderContainer container;

    const pickup = ServiceLocation(
      geo: DoLocations.santoDomingo,
      address: 'Av. 27 de Febrero',
    );
    final dropoff = ServiceLocation(
      geo: LatLng(
        DoLocations.santoDomingo.latitude + 0.008,
        DoLocations.santoDomingo.longitude,
      ),
      address: 'Taller Autocentro',
    );
    InsurerServiceRequest order(String claim) => InsurerServiceRequest(
          claimNumber: claim,
          pickup: pickup,
          dropoff: dropoff,
          vehicleType: VehicleType.sedan,
          insuredName: 'Juan Carlos Pérez',
          insuredPhone: '+18095550123',
          plate: 'g123456',
        );

    setUp(() async {
      backend = DemoBackend(dispatchDelay: const Duration(milliseconds: 20))
        ..seed()
        ..currentUserId = 'insurer-operator-1';
      container = ProviderContainer(
        overrides: demoOverrides(
          backend: backend,
          role: UserRole.insurer,
          actingAs: 'insurer-operator-1',
        ),
      );
      await container.read(authRepositoryProvider).signInWithEmail('restrepo@segurosdemo.do', 'secret123');
    });
    tearDown(() {
      container.dispose();
      backend.dispose();
    });

    FunctionsGateway gateway() => container.read(functionsGatewayProvider);

    test('knows which company the person works for', () async {
      final auth = container.read(authRepositoryProvider);
      expect(await auth.currentInsurerId(), 'ins-demo');
      expect(
        await DemoAuthRepository(backend).currentInsurerId(),
        isNull,
        reason: 'a customer has no company',
      );
    });

    test(r'quotes RD$2,500 + ITBIS, then orders that tow', () async {
      final quote = (await gateway().quoteInsurerService(
        pickup: pickup,
        dropoff: dropoff,
        vehicleType: VehicleType.sedan,
      ))
          .valueOrNull!;
      expect(quote.subtotalCents, 250000);
      expect(quote.itbisCents, 45000);
      expect(quote.totalCents, 295000);
      expect(quote.zoneLabel, '0–10 km');
      expect(quote.negotiated, isFalse);

      final created = (await gateway().createInsurerService(order('SIN-1'), priced: quote))
          .valueOrNull!;
      expect(created.code, startsWith('GR-'));
      expect(created.totalCents, 295000);

      final service = backend.service(created.serviceId)!;
      expect(service.insurerId, 'ins-demo');
      expect(service.insurerName, 'Seguros Demo, S.A.');
      expect(service.vehicle.plate, 'G123456');
      expect(service.insurance!.claimKey, 'SIN1');
    });

    test('refuses a second live tow for the same claim, and a blank claim', () async {
      await gateway().createInsurerService(order('SIN-2024-01489'));
      final again = await gateway().createInsurerService(order('sin 2024 01489'));
      expect(again.failureOrNull?.code, FailureCode.alreadyHasActiveService);
      final blank = await gateway().createInsurerService(order('  '));
      expect(blank.failureOrNull?.message, contains('siniestro'));
    });

    test('refuses an expired price and a suspended company', () async {
      final quote = (await gateway().quoteInsurerService(
        pickup: pickup,
        dropoff: dropoff,
        vehicleType: VehicleType.sedan,
      ))
          .valueOrNull!;
      final stale = InsurerQuote(
        subtotalCents: quote.subtotalCents,
        itbisCents: quote.itbisCents,
        totalCents: quote.totalCents,
        distanceKm: quote.distanceKm,
        expiresAt: DateTime.utc(2020),
        signature: 'demo',
      );
      expect(
        (await gateway().createInsurerService(order('SIN-3'), priced: stale)).failureOrNull?.code,
        FailureCode.quoteExpired,
      );

      backend.updateInsurer('ins-demo', status: InsurerStatus.suspended);
      expect(
        (await gateway().createInsurerService(order('SIN-4'))).failureOrNull?.code,
        FailureCode.accountSuspended,
      );
    });

    test('lists the company’s tows and cancels one', () async {
      final created = (await gateway().createInsurerService(order('SIN-5'))).valueOrNull!;
      final mine = await container
          .read(serviceRepositoryProvider)
          .watchInsurerServices('ins-demo')
          .first;
      expect(mine.map((s) => s.id), contains(created.serviceId));
      expect(
        await container.read(serviceRepositoryProvider).watchInsurerServices('other').first,
        isEmpty,
      );

      final cancelled = await gateway().cancelService(
        serviceId: created.serviceId,
        reason: 'duplicado',
      );
      expect(cancelled.isOk, isTrue);
      final service = backend.service(created.serviceId)!;
      expect(service.status, ServiceStatus.cancelled);
      expect(service.cancellation?.by, CancelledBy.insurer);
    });

    test('clears the change-password flag', () async {
      backend.requirePasswordChange('insurer-operator-1');
      expect(backend.insurerMember('ins-demo', 'insurer-operator-1')!.mustChangePassword, isTrue);
      expect((await gateway().insurerPasswordChanged()).isOk, isTrue);
      expect(backend.insurerMember('ins-demo', 'insurer-operator-1')!.mustChangePassword, isFalse);
    });

    test('feeds the portal providers', () async {
      await gateway().createInsurerService(order('SIN-6'));
      final subs = [
        container.listen(myInsurerMemberProvider, (_, _) {}),
        container.listen(myInsurerProvider, (_, _) {}),
        container.listen(myInsurerServicesProvider, (_, _) {}),
        container.listen(myInsurerStatsProvider, (_, _) {}),
      ];
      addTearDown(() {
        for (final s in subs) {
          s.close();
        }
      });
      InsurerStats? stats;
      for (var i = 0; i < 100 && (stats?.requested ?? 0) == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        stats = container.read(myInsurerStatsProvider).value;
      }
      expect(stats?.requested, 1);
      expect(container.read(myInsurerMemberProvider).value?.role, InsurerRole.operator);
      expect(container.read(myInsurerProvider).value?.name, 'Seguros Demo, S.A.');
      expect(container.read(myInsurerServicesProvider).value, hasLength(1));
    });
  });
}

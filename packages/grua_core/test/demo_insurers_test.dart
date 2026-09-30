import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';
import 'package:grua_testing/grua_testing.dart';

/// The demo backend's insurance companies have to refuse and resolve the way
/// the callables do, or the panel is built against a server that does not
/// exist.
void main() {
  late DemoBackend backend;

  setUp(() {
    backend = DemoBackend(dispatchDelay: const Duration(milliseconds: 20))
      ..seed();
  });
  tearDown(() => backend.dispose());

  const details = InsurerDetails(
    name: 'Universal Seguros de Prueba',
    rnc: '1-31-00000-2',
    billingEmail: 'facturas@universal.test',
  );

  group('DoValidators.companyRnc', () {
    test('accepts a valid company RNC, with or without dashes', () {
      expect(DoValidators.companyRnc('130000001'), isNull);
      expect(DoValidators.companyRnc('1-30-00000-1'), isNull);
      expect(DoValidators.companyRnc('101010632'), isNull);
    });

    test('refuses a blank, short, personal or mistyped RNC', () {
      expect(DoValidators.companyRnc(''), contains('RNC'));
      expect(DoValidators.companyRnc('13000000'), contains('9 dígitos'));
      expect(DoValidators.companyRnc('00114272360'), contains('9 dígitos'));
      expect(DoValidators.companyRnc('130000002'), contains('no es válido'));
    });
  });

  test('the seed has one company with a manager and an operator', () {
    final seeded = backend.insurer('ins-demo')!;
    expect(seeded.isActive, isTrue);
    expect(seeded.driverPayoutLabel, '70%');
    expect(
      backend.insurerMembers('ins-demo').map((m) => m.role),
      containsAll([InsurerRole.manager, InsurerRole.operator]),
    );
  });

  group('companies', () {
    test('opens one, and refuses a bad or repeated RNC', () {
      final id = backend.createInsurer(details).valueOrNull!;
      final created = backend.insurer(id)!;
      expect(created.rnc, '131000002');
      expect(created.isActive, isTrue);

      expect(
        backend.createInsurer(details).failureOrNull?.message,
        contains('Ya existe'),
      );
      expect(
        backend
            .createInsurer(
              const InsurerDetails(name: 'X Y', rnc: '130000002', billingEmail: 'a@b.do'),
            )
            .failureOrNull
            ?.message,
        contains('RNC'),
      );
      expect(
        backend
            .createInsurer(
              const InsurerDetails(name: 'X Y', rnc: '131000002', billingEmail: 'no'),
            )
            .failureOrNull
            ?.message,
        contains('facturación'),
      );
    });

    test('suspends, reactivates and sets the chofer share', () {
      final id = backend.createInsurer(details, driverPayoutBps: 6550).valueOrNull!;
      expect(backend.insurer(id)!.driverPayoutLabel, '65.5%');

      backend.updateInsurer(id, status: InsurerStatus.suspended, statusReason: 'Pago pendiente');
      expect(backend.insurer(id)!.status, InsurerStatus.suspended);
      expect(backend.insurer(id)!.statusReason, 'Pago pendiente');

      backend.updateInsurer(id, status: InsurerStatus.active);
      expect(backend.insurer(id)!.statusReason, '');

      backend.updateInsurer(id, clearDriverPayout: true);
      expect(backend.insurer(id)!.driverPayoutBps, isNull);

      expect(
        backend.updateInsurer(id, driverPayoutBps: 12000).failureOrNull?.message,
        contains('porcentaje'),
      );
      expect(
        backend.updateInsurer('nope', status: InsurerStatus.active).failureOrNull?.code,
        FailureCode.notFound,
      );
    });
  });

  group('people', () {
    test('adds a person with a first password, and refuses a repeated email', () {
      final user = backend
          .createInsurerUser(
            insurerId: 'ins-demo',
            name: 'Nuevo Operador',
            email: 'Nuevo@SegurosDemo.do',
            role: InsurerRole.operator,
          )
          .valueOrNull!;
      expect(user.temporaryPassword, isNotEmpty);
      final member = backend.insurerMembers('ins-demo').firstWhere((m) => m.uid == user.uid);
      expect(member.email, 'nuevo@segurosdemo.do');
      expect(member.mustChangePassword, isTrue);

      expect(
        backend
            .createInsurerUser(
              insurerId: 'ins-demo',
              name: 'Otro',
              email: 'nuevo@segurosdemo.do',
              role: InsurerRole.operator,
            )
            .failureOrNull
            ?.message,
        contains('correo'),
      );
    });

    test('changes a role and deactivates, only inside the company', () {
      backend.updateInsurerUser(
        insurerId: 'ins-demo',
        uid: 'insurer-operator-1',
        role: InsurerRole.manager,
        active: false,
      );
      final member = backend
          .insurerMembers('ins-demo')
          .firstWhere((m) => m.uid == 'insurer-operator-1');
      expect(member.role, InsurerRole.manager);
      expect(member.active, isFalse);

      final other = backend.createInsurer(details).valueOrNull!;
      expect(
        backend
            .updateInsurerUser(insurerId: other, uid: 'insurer-operator-1', active: true)
            .failureOrNull
            ?.code,
        FailureCode.notFound,
      );
    });
  });

  group('zone prices', () {
    const negotiated = [
      PricingRule(vehicleClass: VehicleClass.light, zoneMinKm: 0, zoneMaxKm: 15, baseCents: 200000),
      PricingRule(
        vehicleClass: VehicleClass.light,
        zoneMinKm: 15,
        zoneMaxKm: null,
        baseCents: 200000,
        extraKmCents: 10000,
      ),
    ];

    test('refuses a table with a gap', () {
      final result = backend.savePricingTable(
        insurerId: 'ins-demo',
        vehicleClass: VehicleClass.light,
        rows: const [
          PricingRule(vehicleClass: VehicleClass.light, zoneMinKm: 0, zoneMaxKm: 10, baseCents: 1),
          PricingRule(vehicleClass: VehicleClass.light, zoneMinKm: 12, zoneMaxKm: null, baseCents: 1),
        ],
      );
      expect(result.failureOrNull?.message, contains('continuas'));
      expect(backend.pricingRules(insurerId: 'ins-demo'), isEmpty);
    });

    test('a saved table prices the company’s next tow, with its own share', () async {
      backend
        ..savePricingTable(
          insurerId: 'ins-demo',
          vehicleClass: VehicleClass.light,
          rows: negotiated,
        )
        ..updateInsurer('ins-demo', driverPayoutBps: 6500);

      final rows = backend.pricingRules(insurerId: 'ins-demo');
      expect(rows, hasLength(2));
      expect(rows.every((r) => r.insurerId == 'ins-demo'), isTrue);

      final (_, source) = backend.zoneTableFor('ins-demo', VehicleClass.light);
      expect(source, ZoneTariffSource.insurer);
      final (_, suvSource) = backend.zoneTableFor('ins-demo', VehicleClass.suv);
      expect(suvSource, ZoneTariffSource.standard);

      final service = backend.createInsurerService(
        insurerId: 'ins-demo',
        insurerName: 'Seguros Demo',
        requestedBy: 'insurer-operator-1',
        pickup: const ServiceLocation(geo: DoLocations.santoDomingo),
        dropoff: ServiceLocation(
          geo: LatLng(DoLocations.santoDomingo.latitude + 0.008, DoLocations.santoDomingo.longitude),
        ),
        vehicle: const ServiceVehicle(),
        insurance: const InsuranceClaim(claimNumber: 'SIN-9'),
      );
      expect(service.billing!.subtotalCents, 200000);
      expect(service.billing!.isNegotiated, isTrue);

      Service? assigned;
      for (var i = 0; i < 100 && assigned?.driverId == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        assigned = backend.service(service.id);
      }
      final offer = await DemoOfferRepository(backend)
          .watchOffer(service.id, assigned!.driverId!)
          .first;
      expect(offer?.netEarningsCents, 130000);
    });

    test('the default list, when edited, prices every company without its own', () {
      backend.savePricingTable(
        insurerId: null,
        vehicleClass: VehicleClass.suv,
        rows: const [
          PricingRule(vehicleClass: VehicleClass.suv, zoneMinKm: 0, zoneMaxKm: null, baseCents: 400000),
        ],
      );
      final (rows, source) = backend.zoneTableFor('ins-demo', VehicleClass.suv);
      expect(source, ZoneTariffSource.standard);
      expect(rows.single.baseCents, 400000);
      expect(rows.single.insurerId, isNull);
    });

    test('resetting goes back to the default list, then the built-in one', () {
      backend
        ..savePricingTable(
          insurerId: 'ins-demo',
          vehicleClass: VehicleClass.light,
          rows: negotiated,
        )
        ..resetPricingTable(insurerId: 'ins-demo', vehicleClass: VehicleClass.light);
      final (rows, source) = backend.zoneTableFor('ins-demo', VehicleClass.light);
      expect(source, ZoneTariffSource.standard);
      expect(rows, ZonePricing.defaultRulesFor(VehicleClass.light));
      expect(
        backend
            .resetPricingTable(insurerId: 'nope', vehicleClass: VehicleClass.light)
            .failureOrNull
            ?.code,
        FailureCode.notFound,
      );
    });
  });

  group('who may change a company’s people', () {
    test('a manager cannot lock themselves out; the office can change anyone', () {
      final demote = backend.updateInsurerUser(
        actorId: 'insurer-manager-1',
        insurerId: 'ins-demo',
        uid: 'insurer-manager-1',
        role: InsurerRole.operator,
      );
      expect(demote.failureOrNull?.message, contains('rol de administrador'));
      final deactivate = backend.updateInsurerUser(
        actorId: 'insurer-manager-1',
        insurerId: 'ins-demo',
        uid: 'insurer-manager-1',
        active: false,
      );
      expect(deactivate.failureOrNull?.message, contains('propio usuario'));
      expect(backend.insurerMember('ins-demo', 'insurer-manager-1')!.active, isTrue);

      // Their own colleague, yes.
      expect(
        backend
            .updateInsurerUser(
              actorId: 'insurer-manager-1',
              insurerId: 'ins-demo',
              uid: 'insurer-operator-1',
              active: false,
            )
            .isOk,
        isTrue,
      );
      // The office is not bound by the rule.
      expect(
        backend
            .updateInsurerUser(
              actorId: 'admin-1',
              insurerId: 'ins-demo',
              uid: 'insurer-manager-1',
              role: InsurerRole.operator,
            )
            .isOk,
        isTrue,
      );
    });

    test('an operator manages nobody, and a manager only their own company', () {
      final byOperator = backend.createInsurerUser(
        actorId: 'insurer-operator-1',
        insurerId: 'ins-demo',
        name: 'Nuevo Agente',
        email: 'nuevo@segurosdemo.do',
        role: InsurerRole.operator,
      );
      expect(byOperator.failureOrNull?.code, FailureCode.permissionDenied);

      final other = backend.createInsurer(details).valueOrNull!;
      final elsewhere = backend.createInsurerUser(
        actorId: 'insurer-manager-1',
        insurerId: other,
        name: 'Intruso',
        email: 'intruso@segurosdemo.do',
        role: InsurerRole.manager,
      );
      expect(elsewhere.failureOrNull?.code, FailureCode.permissionDenied);
    });
  });

  group('a company person who may not act', () {
    const pickup = ServiceLocation(geo: DoLocations.santoDomingo);
    const request = InsurerServiceRequest(
      claimNumber: 'SIN-1',
      pickup: pickup,
      dropoff: pickup,
      vehicleType: VehicleType.sedan,
    );

    test('is told why: company suspended, or user deactivated', () async {
      backend.currentUserId = 'insurer-operator-1';
      final gateway = DemoFunctionsGateway(backend);

      backend.updateInsurerUser(insurerId: 'ins-demo', uid: 'insurer-operator-1', active: false);
      final quote = await gateway.quoteInsurerService(
        pickup: pickup,
        dropoff: pickup,
        vehicleType: VehicleType.sedan,
      );
      expect(quote.failureOrNull?.message, contains('Tu usuario está desactivado'));
      expect(
        backend.orderInsurerService('insurer-operator-1', request).failureOrNull?.message,
        contains('Tu usuario está desactivado'),
      );

      backend
        ..updateInsurerUser(insurerId: 'ins-demo', uid: 'insurer-operator-1', active: true)
        ..updateInsurer('ins-demo', status: InsurerStatus.suspended);
      expect(
        (await gateway.createInsurerService(request)).failureOrNull?.message,
        contains('aseguradora está suspendida'),
      );
      expect(
        backend.cancelByInsurer('insurer-operator-1', 'any').failureOrNull?.code,
        FailureCode.accountSuspended,
      );
      expect(backend.insurerPasswordChanged('insurer-operator-1').isErr, isTrue);
    });

    test('cannot order a vehicle the tariff has no column for', () {
      final unknown = backend.orderInsurerService(
        'insurer-operator-1',
        const InsurerServiceRequest(
          claimNumber: 'SIN-2',
          pickup: pickup,
          dropoff: pickup,
          vehicleType: VehicleType.unknown,
        ),
      );
      expect(unknown.failureOrNull?.code, FailureCode.invalidInput);
    });
  });

  test('the chofer’s share is the one agreed when the tow was ordered', () {
    final service = backend.createInsurerService(
      insurerId: 'ins-demo',
      insurerName: 'Seguros Demo, S.A.',
      requestedBy: 'insurer-operator-1',
      pickup: const ServiceLocation(geo: DoLocations.santoDomingo),
      dropoff: const ServiceLocation(geo: DoLocations.santoDomingo),
      vehicle: const ServiceVehicle(),
      insurance: const InsuranceClaim(claimNumber: 'SIN-RATE'),
    );
    // The office changes the company's rate mid-tow.
    backend.updateInsurer('ins-demo', driverPayoutBps: 5000);
    expect(
      ['driver-1', 'driver-2', 'driver-3', 'driver-4', 'driver-5'].any(
        (d) => backend.assignServiceManually(serviceId: service.id, driverId: d) == null,
      ),
      isTrue,
    );
    final driverId = backend.service(service.id)!.driverId!;
    for (final (to, event) in [
      (ServiceStatus.arrived, ServiceEventName.markArrived),
      (ServiceStatus.inProgress, ServiceEventName.startService),
      (ServiceStatus.completed, ServiceEventName.completeService),
    ]) {
      backend.transition(service.id, to, event, driverId, UserRole.driver);
    }
    final entry = backend.earningEntries(driverId).singleWhere((e) => e.serviceId == service.id);
    // 70% of RD$2,500, not the new 50%.
    expect(entry.netCents, 175000);
  });

}

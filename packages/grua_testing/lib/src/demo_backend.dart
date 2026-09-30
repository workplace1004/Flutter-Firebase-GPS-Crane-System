import 'dart:async';
import 'dart:math' as math;

import 'package:grua_core/grua_core.dart';

/// An in-memory stand-in for the whole backend.
///
/// This exists so the three apps can be built, demonstrated and widget-tested
/// before a Firebase project is provisioned, and so a reviewer can walk the
/// full request → dispatch → tow → pay flow on a plane. It deliberately
/// implements the *same* state machine and the *same* pricing rules as the
/// server, because a demo that behaves differently from production teaches
/// everyone the wrong thing.
///
/// What it does not do is enforce anything. Authorisation, concurrency and
/// money are the server's job; nothing here should ever be pointed at a real
/// customer.
class DemoBackend {
  DemoBackend({
    math.Random? random,
    DateTime Function()? clock,
    this.dispatchDelay = const Duration(seconds: 6),
    this.driveStep = const Duration(milliseconds: 1500),
  })  : _random = random ?? math.Random(7),
        _clock = clock ?? DateTime.now;

  final math.Random _random;
  final DateTime Function() _clock;

  DateTime _now() => _nowOverride ?? _clock();

  /// How long the simulated cascade takes to assign a chofer. Six seconds in
  /// the app so a reviewer sees the "buscando grúa" state; near-zero in tests,
  /// which should not spend real time waiting on a fake dispatcher.
  final Duration dispatchDelay;

  /// Interval between simulated GPS fixes while a truck is moving.
  final Duration driveStep;

  final Map<String, AppUser> _users = {};
  final Map<String, Driver> _drivers = {};
  final Map<String, Truck> _trucks = {};
  final Map<String, Service> _services = {};
  final Map<String, List<ChatMessage>> _messages = {};
  final Map<String, ChatRequest> _chatRequests = {};
  final Map<String, List<ChatMessage>> _chatRequestMessages = {};
  var _chatRequestCounter = 0;
  final Map<String, List<ServiceEvent>> _events = {};
  final Map<String, ServiceTracking> _tracking = {};
  final Map<String, DriverLivePosition> _live = {};
  final Map<String, EarningsSummary> _earnings = {};
  final Map<String, List<EarningEntry>> _earningEntries = {};
  final Map<String, Invoice> _invoices = {};

  /// The offer each chofer accepted, by `serviceId/driverId`. The demo cascade
  /// assigns without ringing, but the chofer still reads what they earn from
  /// their offer, as on the real backend.
  final Map<String, Offer> _offers = {};

  /// Each insurance company's chofer share, when it is not the default.
  final Map<String, int> _insurerPayoutBps = {};

  final PricingConfig _pricing = const PricingConfig();
  final DispatchConfig _dispatch = const DispatchConfig();
  final AppSettings _settings = const AppSettings();

  final _servicesController = StreamController<Map<String, Service>>.broadcast();
  final _driversController = StreamController<Map<String, Driver>>.broadcast();
  final _trucksController = StreamController<Map<String, Truck>>.broadcast();
  final _liveController = StreamController<Map<String, DriverLivePosition>>.broadcast();
  final Set<String> _appOpen = {};
  final _appOpenController = StreamController<Set<String>>.broadcast();
  final _usersController = StreamController<Map<String, AppUser>>.broadcast();
  final _messagesController = StreamController<String>.broadcast();
  final _trackingController = StreamController<String>.broadcast();
  final _chatRequestsController = StreamController<void>.broadcast();
  final _reviews = <String, DriverReview>{};
  final _reviewsController = StreamController<void>.broadcast();
  final _chatRequestMessagesController = StreamController<String>.broadcast();

  /// Who is typing where: `threadKey` → uid → when the last keystroke landed.
  final Map<String, Map<String, DateTime>> _typing = {};
  final _typingController = StreamController<String>.broadcast();

  /// What each person did to their own conversations: uid → thread key → the
  /// clear and delete stamps. Nobody else's screen ever sees it.
  final Map<String, Map<String, ChatThreadPrefs>> _chatPrefs = {};

  /// Who each person blocked: uid → the uids they will not hear from.
  final Map<String, Set<String>> _blocked = {};
  final _chatPrefsController = StreamController<String>.broadcast();

  final List<Timer> _timers = [];
  var _seeded = false;
  var _serviceCounter = 430;

  /// The identity the demo signs in as. Swapped by the driver and admin apps.
  String currentUserId = 'demo-client-1';

  // -------------------------------------------------------------------------
  // Seed
  // -------------------------------------------------------------------------

  void seed() {
    if (_seeded) return;
    _seeded = true;
    _seedInsurers();

    // `demo-client-1` is the account the client app signs in as; the rest are
    // here so the customer roster in the panel has something to show.
    const clientSpecs =
        <(String, String, String, String, String, PaymentMethod, int, int)>[
      (
        'demo-client-1',
        'Ramón Peña',
        '+18095551234',
        'ramon@example.do',
        '',
        PaymentMethod.cash,
        4,
        210,
      ),
      (
        'demo-client-2',
        'Yokasta Almonte',
        '+18095552345',
        'yokasta@example.do',
        '',
        PaymentMethod.card,
        11,
        140,
      ),
      (
        'demo-client-3',
        'Autorepuestos del Este SRL',
        '+18092223456',
        'flota@autorepuestosdeleste.do',
        '131246789',
        PaymentMethod.card,
        26,
        95,
      ),
      (
        'demo-client-4',
        'Franklin Ureña',
        '+18293334567',
        '',
        '',
        PaymentMethod.cash,
        1,
        22,
      ),
      (
        'demo-client-5',
        'Deiby Mercedes',
        '+18494445678',
        'deiby@example.do',
        '',
        PaymentMethod.cash,
        0,
        3,
      ),
    ];

    for (final (id, name, phone, email, rnc, payment, completed, ageDays)
        in clientSpecs) {
      _users[id] = AppUser(
        id: id,
        phone: phone,
        name: name,
        email: email,
        rnc: rnc,
        preferredPaymentMethod: payment,
        completedServices: completed,
        createdAt: _now().subtract(Duration(days: ageDays)),
      );
    }

    // One blocked account, so the panel's blocked state is visible in demo
    // mode instead of only ever appearing in production.
    _users['demo-client-4'] = _users['demo-client-4']!.copyWith(
      blocked: true,
      blockedReason: r'Servicio sin pagar en efectivo (RD$3,200)',
    );

    const truckSpecs = <(String, String, String, String, TruckType, int)>[
      ('truck-1', 'A123456', 'Ford', 'F-450', TruckType.plataforma, 4500),
      ('truck-2', 'A234567', 'Isuzu', 'NPR', TruckType.plataforma, 5000),
      ('truck-3', 'A345678', 'Chevrolet', 'Silverado 3500', TruckType.gancho, 3200),
      ('truck-4', 'A456789', 'Dodge', 'Ram 3500', TruckType.gancho, 3400),
      ('truck-5', 'A567890', 'Freightliner', 'M2 106', TruckType.pesada, 12000),
    ];

    const driverSpecs = <(String, String, String, String, DriverStatus)>[
      ('driver-1', 'Luis Fernández', '00112345678', '+18095550111', DriverStatus.active),
      ('driver-2', 'Máximo Ureña', '00223456789', '+18095550112', DriverStatus.active),
      ('driver-3', 'Wilkin Rosario', '00334567890', '+18095550113', DriverStatus.active),
      ('driver-4', 'Elvin Santana', '00445678901', '+18095550114', DriverStatus.active),
      ('driver-5', 'Junior Castillo', '00556789012', '+18295550115', DriverStatus.active),
      ('driver-6', 'Pedro Aybar', '00667890123', '+18295550116', DriverStatus.inactive),
    ];

    final positions = <LatLng>[
      const LatLng(18.4795, -69.9420), // Gazcue
      const LatLng(18.4712, -69.9061), // Naco
      const LatLng(18.4930, -69.8790), // Villa Mella side
      const LatLng(18.4520, -69.9550), // Zona Colonial edge
      const LatLng(19.4517, -70.6970), // Santiago
      const LatLng(18.6157, -68.7075), // Higüey
    ];

    for (var i = 0; i < truckSpecs.length; i++) {
      final (id, plate, make, model, type, capacity) = truckSpecs[i];
      _trucks[id] = Truck(
        id: id,
        plate: plate,
        make: make,
        model: model,
        year: 2019 + (i % 4),
        color: 'Blanco',
        type: type,
        capacityKg: capacity,
        assignedDriverId: 'driver-${i + 1}',
        assignedDriverName: driverSpecs[i].$2,
        insuranceExpiry: _now().add(Duration(days: 60 + i * 30)),
        marbeteExpiry: _now().add(Duration(days: 20 + i * 45)),
        completedServices: 40 + i * 13,
        createdAt: _now().subtract(const Duration(days: 400)),
      );
    }

    for (var i = 0; i < driverSpecs.length; i++) {
      final (id, name, cedula, phone, status) = driverSpecs[i];
      final truckId = i < truckSpecs.length ? truckSpecs[i].$1 : null;
      final truck = truckId == null ? null : _trucks[truckId];

      _drivers[id] = Driver(
        id: id,
        name: name,
        cedula: cedula,
        phone: phone,
        email: '${id.replaceAll('-', '')}@gruasrd.do',
        licenseNumber: '${100000 + i * 137}',
        licenseExpiry: _now().add(Duration(days: 180 + i * 40)),
        status: status,
        assignedTruckId: truckId,
        assignedTruckPlate: truck?.plate ?? '',
        truckType: truck?.type ?? TruckType.unknown,
        isOnline: status == DriverStatus.active && i < 5,
        rating: 4.4 + (i % 5) * 0.12,
        ratingCount: 30 + i * 11,
        // What the average is read from, so it agrees with the score.
        ratingSum: ((4.4 + (i % 5) * 0.12) * (30 + i * 11)).round(),
        completedServices: 40 + i * 13,
        offersSent: 100 + i * 20,
        offersAccepted: 78 + i * 16,
        cashOwedCents: i == 2 ? 420000 : (i * 35000),
        createdAt: _now().subtract(const Duration(days: 380)),
        lastOnlineAt: _now().subtract(Duration(minutes: i * 3)),
      );

      _live[id] = DriverLivePosition(
        driverId: id,
        lat: positions[i].latitude,
        lng: positions[i].longitude,
        heading: (i * 47) % 360,
        speedKmh: i.isEven ? 34 : 0,
        isOnline: status == DriverStatus.active && i < 5,
        truckType: truck?.type ?? TruckType.unknown,
        updatedAt: _now().millisecondsSinceEpoch,
      );

      _earnings[id] = EarningsSummary(
        driverId: id,
        todayGrossCents: 340000 + i * 45000,
        todayNetCents: 272000 + i * 36000,
        todayServices: 3 + (i % 3),
        weekGrossCents: 1850000 + i * 210000,
        weekNetCents: 1480000 + i * 168000,
        weekServices: 17 + i * 2,
        monthGrossCents: 7400000 + i * 640000,
        monthNetCents: 5920000 + i * 512000,
        monthServices: 62 + i * 5,
        lifetimeNetCents: 48000000 + i * 3200000,
        cashOwedCents: i == 2 ? 420000 : (i * 35000),
        last7DaysNetCents: [
          for (var d = 0; d < 7; d++) 180000 + _random.nextInt(220000),
        ],
        updatedAt: _now(),
      );
    }

    _seedHistoricalServices();
    // What each chofer holds agrees with the cash jobs seeded for them, so the
    // office's Efectivo screen and its corte add up from the first launch.
    for (final entry in _drivers.entries.toList()) {
      final held = uncountedCash(entry.key)
          .fold(0, (sum, s) => sum + s.payment.capturedCents);
      _drivers[entry.key] = entry.value.copyWith(cashOnHandCents: held);
    }
    _emitServices();
    _emitDrivers();
    _emitLive();
  }

  void _seedHistoricalServices() {
    const routes = <(String, String, String, String, VehicleCondition)>[
      (
        'Av. 27 de Febrero, esq. Winston Churchill',
        'Taller Auto Récord, Av. Máximo Gómez',
        'Toyota Corolla',
        'Gris',
        VehicleCondition.noArranca,
      ),
      (
        'Autopista Duarte km 14',
        'Bonao, Av. Aniana Vargas',
        'Honda CR-V',
        'Negro',
        VehicleCondition.accidentado,
      ),
      (
        'Av. España, Boca Chica',
        'Santo Domingo Este, Av. San Vicente',
        'Hyundai Accent',
        'Blanco',
        VehicleCondition.gomaPinchada,
      ),
      (
        'Malecón, Av. George Washington',
        'Taller Hermanos Pérez, Villa Consuelo',
        'Nissan Frontier',
        'Azul',
        VehicleCondition.ruedasBloqueadas,
      ),
    ];

    for (var i = 0; i < routes.length; i++) {
      final (from, to, vehicle, color, condition) = routes[i];
      // Spaced a week apart, so the oldest is 23 days old whatever the hour.
      // The office's "últimos 30 días" starts at the beginning of today minus
      // 29 days, so a fixture built from `now` alone fell outside that window
      // in the small hours and the Servicios list quietly lost a row.
      final completedAt = _now().subtract(Duration(days: i * 7 + 2, hours: i * 3));
      final id = 'svc-history-$i';
      final parts = vehicle.split(' ');
      final serviceVehicle = ServiceVehicle(
        make: parts.first,
        model: parts.skip(1).join(' '),
        plate: 'A${234567 + i * 1111}',
        color: color,
        year: 2015 + i,
        condition: condition,
      );
      final quote = Pricing.quoteFor(
        config: _pricing,
        vehicleType: serviceVehicle.type,
        distance: TripDistance.city(8.5 + i * 4.2, includedKm: _pricing.includedKm),
        at: completedAt,
        chargeItbis: false,
      );

      _services[id] = Service(
        id: id,
        clientId: 'demo-client-1',
        clientName: 'Ramón Peña',
        clientPhone: '+18095551234',
        code: 'GR-${_dateCode(completedAt)}-0${400 + i}',
        status: ServiceStatus.closed,
        vehicle: serviceVehicle,
        truckTypeRequired: serviceVehicle.inferredTruckType,
        pickup: ServiceLocation(
          geo: LatLng(18.47 + i * 0.01, -69.93 - i * 0.01),
          address: from,
          reference: 'Frente al colmado',
        ),
        dropoff: ServiceLocation(
          geo: LatLng(18.50 + i * 0.01, -69.88 - i * 0.01),
          address: to,
        ),
        route: ServiceRoute(
          distanceMeters: ((8.5 + i * 4.2) * 1000).round(),
          durationSeconds: (18 + i * 7) * 60,
        ),
        quote: quote,
        finalQuote: quote,
        payment: ServicePayment(
          status: PaymentStatus.cashCollected,
          capturedCents: quote.totalCents,
        ),
        driverId: 'driver-${(i % 4) + 1}',
        driverName: _drivers['driver-${(i % 4) + 1}']?.name ?? '',
        driverPhone: _drivers['driver-${(i % 4) + 1}']?.phone ?? '',
        driverRating: 4.7,
        truckId: 'truck-${(i % 4) + 1}',
        truckPlate: _trucks['truck-${(i % 4) + 1}']?.plate ?? '',
        assignedAt: completedAt.subtract(const Duration(minutes: 42)),
        timeline: ServiceTimeline(
          createdAt: completedAt.subtract(const Duration(minutes: 45)),
          acceptedAt: completedAt.subtract(const Duration(minutes: 42)),
          arrivedAt: completedAt.subtract(const Duration(minutes: 28)),
          startedAt: completedAt.subtract(const Duration(minutes: 24)),
          completedAt: completedAt,
          closedAt: completedAt.add(const Duration(minutes: 1)),
        ),
        invoiceId: 'inv-$i',
        createdAt: completedAt.subtract(const Duration(minutes: 45)),
      );

      _invoices['inv-$i'] = Invoice(
        id: 'inv-$i',
        serviceId: id,
        clientId: 'demo-client-1',
        serviceCode: _services[id]!.code,
        ncf: 'B02${(120 + i).toString().padLeft(8, '0')}',
        clientName: 'Ramón Peña',
        lines: [
          for (final line in quote.breakdown)
            InvoiceLine(
              code: line.label.toLowerCase().replaceAll(' ', '_'),
              label: line.label,
              totalCents: line.cents,
            ),
        ],
        subtotalCents: quote.subtotalCents,
        itbisCents: quote.itbisCents,
        totalCents: quote.totalCents,
        paymentMethod: PaymentMethod.cash,
        issuedAt: completedAt,
      );
    }
  }

  /// Finished tows for the seeded company, last month and this one, waiting
  /// for their invoice — so the demo's Facturación page has something to
  /// bill. Not part of [seed]: tests count the company's tows.
  void seedInsurerHistory() {
    final insurer = _insurers['ins-demo'];
    if (insurer == null) return;
    final now = _now().toUtc();
    final lastMonth = InvoicePeriod.of(now).previous;
    final rows = <(String, DateTime, VehicleType, int, int?, double, int, String)>[
      ('SIN-2026-001201', lastMonth.start.add(const Duration(days: 2, hours: 14)),
          VehicleType.sedan, 0, 10, 6.4, 250000, 'Toyota Corolla'),
      ('SIN-2026-001233', lastMonth.start.add(const Duration(days: 6, hours: 20)),
          VehicleType.suv, 10, 25, 18.2, 450000, 'Hyundai Tucson'),
      ('SIN-2026-001240', lastMonth.start.add(const Duration(days: 11, hours: 9)),
          VehicleType.camion, 25, 50, 31.5, 1100000, 'Isuzu NPR'),
      ('SIN-2026-001275', lastMonth.start.add(const Duration(days: 19, hours: 16)),
          VehicleType.sedan, 50, null, 62.3, 698000, 'Honda Civic'),
      ('SIN-2026-001302', now.subtract(const Duration(hours: 5)),
          VehicleType.sedan, 0, 10, 4.1, 250000, 'Kia Picanto'),
    ];
    for (final (i, row) in rows.indexed) {
      final (claim, at, type, minKm, maxKm, km, subtotal, vehicle) = row;
      final id = 'svc-insurer-$i';
      final parts = vehicle.split(' ');
      final driverId = 'driver-${(i % 4) + 1}';
      _services[id] = Service(
        id: id,
        clientId: '',
        clientName: 'Asegurado ${i + 1}',
        code: 'GR-${_dateCode(at)}-A${i + 1}',
        status: ServiceStatus.closed,
        insurerId: insurer.id,
        insurerName: insurer.name,
        insurance: InsuranceClaim(
          claimNumber: claim,
          claimKey: claim.replaceAll('-', ''),
          policyNumber: 'POL-57890${i + 1}',
          insuredName: const ['Juan Pérez', 'Ana Rosario', 'Luis Batista', 'Carmen Núñez', 'Pedro Gil'][i],
        ),
        vehicle: ServiceVehicle(
          type: type,
          make: parts.first,
          model: parts.skip(1).join(' '),
          plate: 'G${100200 + i * 311}',
        ),
        pickup: ServiceLocation(
          geo: LatLng(18.47 + i * 0.01, -69.93 + i * 0.01),
          address: 'Av. 27 de Febrero #${100 + i * 20}, Santo Domingo',
        ),
        dropoff: ServiceLocation(
          geo: LatLng(18.49 + i * 0.01, -69.90 + i * 0.01),
          address: 'Taller Autocentro, Santo Domingo',
        ),
        billing: InsurerBilling(
          insurerId: insurer.id,
          vehicleClass: VehicleClass.of(type),
          zoneMinKm: minKm,
          zoneMaxKm: maxKm,
          distanceKm: km,
          baseCents: subtotal,
          subtotalCents: subtotal,
        ),
        quote: Quote(vehicleType: type, subtotalCents: subtotal, distanceKm: km),
        payment: const ServicePayment(
          method: PaymentMethod.insurer,
          status: PaymentStatus.toInvoice,
        ),
        driverId: driverId,
        driverName: _drivers[driverId]?.name ?? '',
        timeline: ServiceTimeline(
          createdAt: at.subtract(const Duration(minutes: 70)),
          acceptedAt: at.subtract(const Duration(minutes: 66)),
          arrivedAt: at.subtract(const Duration(minutes: 40)),
          startedAt: at.subtract(const Duration(minutes: 35)),
          completedAt: at,
          closedAt: at,
        ),
        createdAt: at.subtract(const Duration(minutes: 70)),
      );
    }
    _emitServices();
  }

  /// One insurance company with a manager and an operator, so the panel's
  /// Aseguradoras page and the insurer's own view have something to show.
  void _seedInsurers() {
    final now = _now().toUtc();
    _insurers['ins-demo'] = Insurer(
      id: 'ins-demo',
      name: 'Seguros Demo, S.A.',
      rnc: '130000001',
      contactName: 'Marta Díaz',
      contactEmail: 'marta@segurosdemo.do',
      contactPhone: '+18095550150',
      billingEmail: 'facturas@segurosdemo.do',
      status: InsurerStatus.active,
      createdAt: now,
    );
    _insurerMembers['ins-demo'] = {
      'insurer-manager-1': InsurerMember(
        insurerId: 'ins-demo',
        uid: 'insurer-manager-1',
        name: 'Marta Díaz',
        email: 'marta@segurosdemo.do',
        role: InsurerRole.manager,
        active: true,
        createdAt: now,
      ),
      'insurer-operator-1': InsurerMember(
        insurerId: 'ins-demo',
        uid: 'insurer-operator-1',
        name: 'Agente Restrepo',
        email: 'restrepo@segurosdemo.do',
        role: InsurerRole.operator,
        active: true,
        createdAt: now,
      ),
    };
  }

  String _dateCode(DateTime at) {
    final yy = (at.year % 100).toString().padLeft(2, '0');
    final mm = at.month.toString().padLeft(2, '0');
    final dd = at.day.toString().padLeft(2, '0');
    return '$yy$mm$dd';
  }

  // -------------------------------------------------------------------------
  // Reads
  // -------------------------------------------------------------------------

  PricingConfig get pricing => _pricing;

  DispatchConfig get dispatch => _dispatch;

  AppSettings get settings => _settings;

  AppUser? user(String uid) => _users[uid];

  Driver? driver(String uid) => _drivers[uid];

  /// The chofer who signs in with [email], if any.
  Driver? driverByEmail(String email) {
    final wanted = email.trim().toLowerCase();
    for (final d in _drivers.values) {
      if (d.email.toLowerCase() == wanted) return d;
    }
    return null;
  }

  // -------------------------------------------------------------------------
  // Demo app only: somebody on the other end
  // -------------------------------------------------------------------------

  Timer? _requestSimulator;
  var _simulated = 0;
  final Set<String> _seededWeeks = {};

  /// Whether requests arrive on their own. Only the demo app turns it on;
  /// tests never do.
  bool get simulatesRequests => _requestSimulator != null;

  /// While the signed-in chofer is online and free, a new request arrives for
  /// them every [every] — an insurance company's tow, then a customer's cash
  /// tow, and so on — so the driver app can be walked through by hand with
  /// nobody on the other end.
  void startRequestSimulator({Duration every = const Duration(seconds: 12)}) {
    if (_requestSimulator != null) return;
    final timer = Timer.periodic(every, (_) => _simulateRequest());
    _requestSimulator = timer;
    _timers.add(timer);
  }

  void _simulateRequest() {
    final driver = _drivers[currentUserId];
    if (driver == null || !driver.isOnline || driver.isBusy) return;
    final waiting = _services.values.any(
      (s) => s.status == ServiceStatus.pendingDispatch || s.status == ServiceStatus.offered,
    );
    if (waiting) return;

    final here = _live[driver.id]?.position ?? DoLocations.defaultCenter;
    final pickup = ServiceLocation(
      geo: LatLng(here.latitude + 0.012, here.longitude + 0.006),
      address: 'Av. Winston Churchill #95, Santo Domingo',
      reference: 'Frente a la farmacia',
    );
    final dropoff = ServiceLocation(
      geo: LatLng(here.latitude + 0.045, here.longitude - 0.012),
      address: 'Taller Autocentro, Av. Charles de Gaulle',
    );
    final n = ++_simulated;
    if (n.isOdd) {
      createInsurerService(
        insurerId: 'ins-demo',
        insurerName: _insurers['ins-demo']?.name ?? 'Seguros Demo, S.A.',
        requestedBy: 'insurer-operator-1',
        pickup: pickup,
        dropoff: dropoff,
        vehicle: ServiceVehicle(
          make: 'Toyota',
          model: 'Corolla',
          color: 'Gris',
          plate: 'G${123450 + n}',
        ),
        insurance: InsuranceClaim(
          claimNumber: 'SIN-DEMO-${n.toString().padLeft(3, '0')}',
          policyNumber: 'POL-5789023',
          insuredName: 'Juan Carlos Pérez',
          insuredPhone: '+18095550123',
        ),
        notes: 'El vehículo está en el parqueo del edificio.',
        preferredDriverId: driver.id,
      );
      return;
    }
    const vehicle = ServiceVehicle(make: 'Honda', model: 'Civic', color: 'Negro', plate: 'A234567');
    final km = pickup.geo.distanceKmTo(dropoff.geo) * 1.3;
    createService(
      clientId: 'demo-client-1',
      pickup: pickup,
      dropoff: dropoff,
      vehicle: vehicle,
      truckType: vehicle.inferredTruckType,
      quote: Pricing.quoteFor(
        config: _pricing,
        vehicleType: vehicle.type,
        distance: TripDistance.city(km, includedKm: _pricing.includedKm),
        at: _now(),
        chargeItbis: false,
      ),
      route: ServiceRoute(
        distanceMeters: (km * 1000).round(),
        durationSeconds: (km / 28 * 3600).round(),
      ),
      preferredDriverId: driver.id,
    );
  }

  /// Last week for [driverId], as the demo app shows it: three insurer tows
  /// and two cash tows — the office's own example, Carlos's week — made into
  /// a corte that is waiting to be paid.
  /// Rewrites a chofer's record, for a test that needs a history the seed
  /// does not have.
  void updateDriverForTest(String driverId, Driver Function(Driver) change) {
    final driver = _drivers[driverId];
    if (driver == null) return;
    _drivers[driverId] = change(driver);
    _emitDrivers();
  }

  void seedDriverWeek(String driverId) {
    if (!_seededWeeks.add(driverId) || !_drivers.containsKey(driverId)) return;
    final now = _now().toUtc();
    final friday = SettlementMath.payBy(now).subtract(const Duration(days: 7));
    EarningEntry entry(String id, PaymentMethod method, int gross, int net, int daysBefore) =>
        EarningEntry(
          serviceId: 'demo-week-$driverId-$id',
          driverId: driverId,
          serviceCode: 'GR-DEMO-$id',
          method: method,
          grossCents: gross,
          netCents: net,
          commissionCents: gross - net,
          completedAt: friday.subtract(Duration(days: daysBefore, hours: 3)),
        );
    (_earningEntries[driverId] ??= []).addAll([
      entry('ins1', PaymentMethod.insurer, 350000, 245000, 4),
      entry('ins2', PaymentMethod.insurer, 550000, 385000, 3),
      entry('ins3', PaymentMethod.insurer, 250000, 175000, 2),
      entry('cash1', PaymentMethod.cash, 400000, 320000, 2),
      entry('cash2', PaymentMethod.cash, 500000, 400000, 1),
    ]);
    // Made on that Friday: only what finished before it.
    try {
      _nowOverride = friday.subtract(const Duration(hours: 9));
      generateDriverSettlements(actorId: 'system', driverId: driverId);
    } finally {
      _nowOverride = null;
    }
  }

  DateTime? _nowOverride;

  Truck? truck(String id) => _trucks[id];

  Service? service(String id) => _services[id];

  Invoice? invoice(String id) => _invoices[id];

  EarningsSummary? earnings(String driverId) => _earnings[driverId];

  List<EarningEntry> earningEntries(String driverId) =>
      List.unmodifiable(_earningEntries[driverId] ?? const []);

  List<Driver> get allDrivers => List.unmodifiable(_drivers.values);

  List<Truck> get allTrucks => List.unmodifiable(_trucks.values);

  List<DriverLivePosition> get allLive => List.unmodifiable(_live.values);

  List<Service> get allServices => List.unmodifiable(_services.values);

  Stream<Map<String, Service>> get serviceUpdates async* {
    yield Map.unmodifiable(_services);
    yield* _servicesController.stream;
  }

  Stream<Map<String, AppUser>> get userUpdates async* {
    yield Map.unmodifiable(_users);
    yield* _usersController.stream;
  }

  Stream<Map<String, Driver>> get driverUpdates async* {
    yield Map.unmodifiable(_drivers);
    yield* _driversController.stream;
  }

  Stream<Map<String, Truck>> get truckUpdates async* {
    yield Map.unmodifiable(_trucks);
    yield* _trucksController.stream;
  }

  Stream<Map<String, DriverLivePosition>> get liveUpdates async* {
    yield Map.unmodifiable(_live);
    yield* _liveController.stream;
  }

  /// Customers' reviews of choferes, newest first, as `watchReviews` reads
  /// them.
  Stream<List<DriverReview>> reviewUpdates({
    String? driverId,
    bool openOnly = false,
    int limit = 50,
  }) async* {
    List<DriverReview> current() => (_reviews.values
            .where((r) => driverId == null || r.driverId == driverId)
            .where((r) => !openOnly || r.isOpen)
            .toList()
          ..sort((a, b) => (b.ratedAt ?? DateTime(0))
              .compareTo(a.ratedAt ?? DateTime(0))))
        .take(limit)
        .toList();
    yield current();
    yield* _reviewsController.stream.map((_) => current());
  }

  DriverReview? review(String serviceId) => _reviews[serviceId];

  /// Rates a finished service the way `rateService` does: once per side, a
  /// week at most after the tow, and a customer's rating folded into the
  /// chofer's summary and filed as a review.
  Result<void> rateService(
    String serviceId,
    String raterId, {
    required int stars,
    List<DriverRatingTag> tags = const [],
    String comment = '',
  }) {
    final service = _services[serviceId];
    if (service == null) return const Err(Failure(FailureCode.notFound));
    final isClient = service.clientId == raterId;
    if (!isClient && service.driverId != raterId) {
      return const Err(
        Failure(FailureCode.permissionDenied, message: 'Este servicio no es tuyo.'),
      );
    }
    if (service.status != ServiceStatus.completed &&
        service.status != ServiceStatus.closed) {
      return const Err(
        Failure(
          FailureCode.invalidTransition,
          message: 'Puedes calificar cuando termine el servicio.',
        ),
      );
    }
    final finished = service.timeline.completedAt;
    if (finished != null && _now().difference(finished) > const Duration(days: 7)) {
      return const Err(
        Failure(
          FailureCode.invalidTransition,
          message: 'Solo puedes calificar durante 7 días después del servicio.',
        ),
      );
    }
    final existing =
        isClient ? service.ratings.clientToDriver : service.ratings.driverToClient;
    if (existing != null && existing.isRated) {
      return const Err(
        Failure(FailureCode.invalidInput, message: 'Ya calificaste este servicio.'),
      );
    }

    final kept = [
      for (final tag in {...tags})
        if (tag != DriverRatingTag.unknown && tag.positive == (stars >= 4)) tag,
    ];
    final text = comment.trim();
    final rating = ServiceRating(
      stars: stars,
      comment: text,
      tags: isClient ? [for (final tag in kept) tag.wire] : const [],
      ratedAt: _now(),
    );
    _services[serviceId] = service.copyWith(
      ratings: isClient
          ? service.ratings.copyWith(clientToDriver: rating)
          : service.ratings.copyWith(driverToClient: rating),
    );

    final driverId = service.driverId;
    final driver = driverId == null ? null : _drivers[driverId];
    if (isClient && driver != null) {
      final sum = driver.ratingSum + stars;
      final count = driver.ratingCount + 1;
      final starCounts = {...driver.ratingStars};
      starCounts['$stars'] = (starCounts['$stars'] ?? 0) + 1;
      final tagCounts = {...driver.ratingTags};
      for (final tag in kept) {
        tagCounts[tag.wire] = (tagCounts[tag.wire] ?? 0) + 1;
      }
      _drivers[driver.id] = driver.copyWith(
        ratingSum: sum,
        ratingCount: count,
        rating: ((sum + 4.8 * 5) / (count + 5) * 100).round() / 100,
        ratingStars: starCounts,
        ratingTags: tagCounts,
        recentFeedback: [
          DriverFeedback(
            stars: stars,
            tags: [for (final tag in kept) tag.wire],
            comment: text,
          ),
          ...driver.recentFeedback,
        ].take(10).toList(),
      );

      final flagged = stars <= 2 || kept.any((t) => t.serious);
      _reviews[serviceId] = DriverReview(
        serviceId: serviceId,
        serviceCode: service.code,
        driverId: driver.id,
        driverName: service.driverName.isEmpty ? driver.name : service.driverName,
        clientId: service.clientId,
        clientName: service.clientName,
        stars: stars,
        tags: [for (final tag in kept) tag.wire],
        comment: text,
        status: flagged ? DriverReviewStatus.open : DriverReviewStatus.ok,
        ratedAt: _now(),
      );
      _reviewsController.add(null);
      _emitDrivers();
    }
    _emitServices();
    return const Ok(null);
  }

  /// Closes a flagged review, as `resolveDriverReview` does.
  Result<void> resolveReview(String serviceId, String actorId, String note) {
    final review = _reviews[serviceId];
    if (review == null) return const Err(Failure(FailureCode.notFound));
    if (!review.isOpen) {
      return const Err(
        Failure(
          FailureCode.invalidTransition,
          message: 'Esa evaluación no está pendiente.',
        ),
      );
    }
    if (note.trim().length < 3) {
      return const Err(
        Failure(
          FailureCode.invalidInput,
          message: 'Escribe qué se hizo con esta evaluación.',
        ),
      );
    }
    _reviews[serviceId] = review.copyWith(
      status: DriverReviewStatus.resolved,
      resolutionNote: note.trim(),
      resolvedBy: actorId,
      resolvedAt: _now(),
    );
    _reviewsController.add(null);
    return const Ok(null);
  }

  /// Stands in for `/presence`: the choferes with the app open right now.
  Stream<Set<String>> get appOpenUpdates async* {
    yield Set.unmodifiable(_appOpen);
    yield* _appOpenController.stream;
  }

  bool isAppOpen(String driverId) => _appOpen.contains(driverId);

  void setAppOpen(String driverId, {required bool open}) {
    final changed = open ? _appOpen.add(driverId) : _appOpen.remove(driverId);
    if (changed) _appOpenController.add(Set.unmodifiable(_appOpen));

    // Mirrors `followAppPresence`: closing the app takes the chofer offline,
    // unless they are holding a job the customer is watching.
    if (!open && changed) {
      final driver = _drivers[driverId];
      if (driver != null && driver.isOnline && !driver.isBusy) {
        setDriverOnline(driverId, online: false);
      }
    }
  }

  Stream<List<ChatMessage>> messagesFor(String serviceId) async* {
    yield List.unmodifiable(_messages[serviceId] ?? const []);
    yield* _messagesController.stream
        .where((id) => id == serviceId)
        .map((_) => List<ChatMessage>.unmodifiable(_messages[serviceId] ?? const []));
  }

  Stream<ServiceTracking?> trackingFor(String serviceId) async* {
    yield _tracking[serviceId];
    yield* _trackingController.stream
        .where((id) => id == serviceId)
        .map((_) => _tracking[serviceId]);
  }

  List<ServiceEvent> eventsFor(String serviceId) =>
      List.unmodifiable(_events[serviceId] ?? const []);

  // -------------------------------------------------------------------------
  // Writes
  // -------------------------------------------------------------------------

  void upsertUser(AppUser user) {
    _users[user.id] = user;
    _emitUsers();
  }

  /// Opens a chofer account the way `createDriver` does server-side, minus the
  /// Auth user there is no such thing as here.
  ///
  /// Returns null when the cédula is already on file: the real callable refuses
  /// a duplicate rather than creating a second account for the same person, and
  /// the panel is built against that refusal.
  ///
  /// [selfRegistered] is the driver app's sign-up: the same inactive account,
  /// but opened by the chofer rather than by whoever the demo is acting as.
  Driver? createDriver({
    required String name,
    required String cedula,
    required String phone,
    required String email,
    required String licenseNumber,
    required DateTime licenseExpiry,
    String? truckId,
    List<String> zones = const [],
    String companyName = '',
    String rnc = '',
    bool selfRegistered = false,
  }) {
    final digits = cedula.replaceAll(RegExp(r'\D'), '');
    if (_drivers.values.any((d) => d.cedula == digits)) return null;

    final id = 'driver-${_drivers.length + 1}-${_now().millisecondsSinceEpoch}';
    final truck = truckId == null ? null : _trucks[truckId];

    final driver = Driver(
      id: id,
      name: name,
      cedula: digits,
      phone: phone,
      email: email,
      licenseNumber: licenseNumber,
      licenseExpiry: licenseExpiry,
      // Inactive until the documents are looked at, exactly as the server does.
      status: DriverStatus.inactive,
      statusReason: selfRegistered
          ? 'Registro desde la app: documentos pendientes de verificación'
          : 'Documentos pendientes de verificación',
      assignedTruckId: truckId,
      assignedTruckPlate: truck?.plate ?? '',
      truckType: truck?.type ?? TruckType.unknown,
      zones: zones,
      companyName: companyName,
      rnc: rnc,
      ratingCount: 0,
      completedServices: 0,
      // A chofer who signed up chose their own password and opened the
      // account themselves; one the office opened carries a temporary one.
      mustChangePassword: !selfRegistered,
      // Only a chofer who signed up goes through the licence check.
      licenseVerification:
          selfRegistered ? const LicenseVerification() : null,
      createdBy: selfRegistered ? id : currentUserId,
      createdAt: _now(),
      updatedAt: _now(),
    );

    _drivers[id] = driver;
    if (truck != null) {
      _trucks[truckId!] = truck.copyWith(
        assignedDriverId: id,
        assignedDriverName: name,
        updatedAt: _now(),
      );
      _emitTrucks();
    }
    _emitDrivers();
    return driver;
  }

  /// Mirrors the `updateDriver` callable. Returns the refusal, or null.
  String? updateDriver(
    String driverId, {
    required String name,
    required String phone,
    required String email,
    required String licenseNumber,
    required DateTime licenseExpiry,
    String? truckId,
    List<String> zones = const [],
    String companyName = '',
    String rnc = '',
  }) {
    final driver = _drivers[driverId];
    if (driver == null || driver.archived) return 'Chofer no encontrado.';

    final truckChanged = driver.assignedTruckId != truckId;
    if (truckChanged && driver.isBusy) {
      return 'Este chofer tiene un servicio en curso. '
          'Cambia la grúa cuando termine.';
    }
    final next = truckId == null ? null : _trucks[truckId];
    if (truckId != null && next == null) return 'Grúa no encontrada.';
    if (truckChanged &&
        next?.assignedDriverId != null &&
        next!.assignedDriverId != driverId) {
      return 'Esa grúa ya está asignada a otro chofer.';
    }
    // Auth refuses a second account on the same email; so does this.
    if (_drivers.values.any(
      (d) => d.id != driverId && d.email.toLowerCase() == email.toLowerCase(),
    )) {
      return 'Ya existe una cuenta con ese correo.';
    }

    final previousId = driver.assignedTruckId;
    if (truckChanged && previousId != null) {
      final previous = _trucks[previousId];
      if (previous != null) {
        _trucks[previousId] = previous.copyWith(
          assignedDriverId: null,
          assignedDriverName: '',
          updatedAt: _now(),
        );
      }
    }
    if (next != null) {
      _trucks[truckId!] = next.copyWith(
        assignedDriverId: driverId,
        assignedDriverName: name,
        updatedAt: _now(),
      );
    }

    _drivers[driverId] = driver.copyWith(
      name: name,
      phone: phone,
      email: email,
      licenseNumber: licenseNumber,
      licenseExpiry: licenseExpiry,
      zones: zones,
      companyName: companyName,
      rnc: rnc,
      assignedTruckId: truckId,
      assignedTruckPlate: next?.plate ?? '',
      truckType: next?.type ?? TruckType.unknown,
      isOnline: truckId != null && driver.isOnline,
      updatedAt: _now(),
    );
    _emitDrivers();
    _emitTrucks();
    return null;
  }

  /// Mirrors the `deleteDriver` callable. Returns the refusal, or null.
  String? deleteDriver(String driverId) {
    final driver = _drivers[driverId];
    if (driver == null) return null;
    if (driver.isBusy) {
      return 'Este chofer tiene un servicio en curso. Elimínalo cuando termine.';
    }
    if (driver.cashOnHandCents > 0) {
      return 'Este chofer tiene efectivo pendiente. Haz el corte antes de '
          'eliminarlo.';
    }

    final truckId = driver.assignedTruckId;
    final truck = truckId == null ? null : _trucks[truckId];
    if (truck != null && truck.assignedDriverId == driverId) {
      _trucks[truckId!] = truck.copyWith(
        assignedDriverId: null,
        assignedDriverName: '',
        updatedAt: _now(),
      );
    }

    _drivers.remove(driverId);
    _documents.remove(driverId);
    _live.remove(driverId);
    _uploads.removeWhere((path, _) => path.startsWith('drivers/$driverId/'));
    _emitDrivers();
    _emitTrucks();
    _emitLive();
    return null;
  }

  // -------------------------------------------------------------------------
  // Fleet — mirrors callables/trucks.ts
  // -------------------------------------------------------------------------

  var _truckCounter = 100;

  /// The live truck the plate [key] belongs to, if any. Archived trucks free
  /// their plate, exactly as `trucks_by_plate` does.
  Truck? _truckWithPlate(String key) => _trucks.values
      .where((t) => !t.archived && DoValidators.plateKey(t.plate) == key)
      .firstOrNull;

  /// Mirrors the `createTruck` callable. Returns the new truck's id, or the
  /// refusal as a [Failure].
  Result<String> createTruck(TruckDetails details) {
    final refusal = _truckRefusal(details);
    if (refusal != null) return Result.err(refusal);

    final key = DoValidators.plateKey(details.plate);
    if (_truckWithPlate(key) != null) {
      return const Result.err(
        Failure(
          FailureCode.invalidInput,
          message: 'Ya existe una grúa con esa placa.',
        ),
      );
    }

    final id = 'truck-${_truckCounter++}';
    _trucks[id] = Truck(
      id: id,
      plate: key,
      make: details.make,
      model: details.model,
      year: details.year,
      color: details.color,
      type: details.type,
      capacityKg: details.capacityKg,
      registrationNumber: details.registrationNumber,
      insurancePolicy: details.insurancePolicy,
      insuranceExpiry: details.insuranceExpiry,
      marbeteExpiry: details.marbeteExpiry,
      createdBy: currentUserId,
      createdAt: _now(),
      updatedAt: _now(),
    );
    _emitTrucks();
    return Result.ok(id);
  }

  /// Mirrors the `updateTruck` callable. Returns the refusal, or null.
  Failure? updateTruck(String truckId, TruckDetails details) {
    final truck = _trucks[truckId];
    if (truck == null || truck.archived) {
      return const Failure(FailureCode.notFound, message: 'Grúa no encontrada.');
    }
    final refusal = _truckRefusal(details);
    if (refusal != null) return refusal;

    final key = DoValidators.plateKey(details.plate);
    final plateChanged = DoValidators.plateKey(truck.plate) != key;
    final typeChanged = truck.type != details.type;
    final holder = _truckWithPlate(key);
    if (plateChanged && holder != null && holder.id != truckId) {
      return const Failure(
        FailureCode.invalidInput,
        message: 'Ya existe una grúa con esa placa.',
      );
    }

    final driverId = truck.assignedDriverId;
    final driver = driverId == null ? null : _drivers[driverId];
    if (driver != null && (plateChanged || typeChanged) && driver.isBusy) {
      return const Failure(
        FailureCode.driverBusy,
        message: 'El chofer de esta grúa tiene un servicio en curso. '
            'Cambia la placa o el tipo cuando termine.',
      );
    }
    if (driver != null && typeChanged && driver.isOnline) {
      return const Failure(
        FailureCode.driverBusy,
        message: 'El chofer de esta grúa está en línea. '
            'Cambia el tipo cuando se desconecte.',
      );
    }

    _trucks[truckId] = truck.copyWith(
      plate: key,
      make: details.make,
      model: details.model,
      year: details.year,
      color: details.color,
      type: details.type,
      capacityKg: details.capacityKg,
      registrationNumber: details.registrationNumber,
      insurancePolicy: details.insurancePolicy,
      insuranceExpiry: details.insuranceExpiry,
      marbeteExpiry: details.marbeteExpiry,
      updatedAt: _now(),
    );
    if (driver != null && (plateChanged || typeChanged)) {
      _drivers[driverId!] = driver.copyWith(
        assignedTruckPlate: key,
        truckType: details.type,
        updatedAt: _now(),
      );
      _emitDrivers();
    }
    _emitTrucks();
    return null;
  }

  /// Mirrors the `archiveTruck` callable. Returns the refusal, or null.
  Failure? archiveTruck(String truckId) {
    final truck = _trucks[truckId];
    if (truck == null) {
      return const Failure(FailureCode.notFound, message: 'Grúa no encontrada.');
    }
    if (truck.archived) return null;

    final driverId = truck.assignedDriverId;
    final driver = driverId == null ? null : _drivers[driverId];
    if (driver != null && driver.isBusy) {
      return const Failure(
        FailureCode.driverBusy,
        message: 'El chofer de esta grúa tiene un servicio en curso. '
            'Elimínala cuando termine.',
      );
    }

    _trucks[truckId] = truck.copyWith(
      archived: true,
      active: false,
      inactiveReason: 'Eliminada por la oficina',
      assignedDriverId: null,
      assignedDriverName: '',
      updatedAt: _now(),
    );
    if (driver != null && driver.assignedTruckId == truckId) {
      _drivers[driverId!] = driver.copyWith(
        assignedTruckId: null,
        assignedTruckPlate: '',
        truckType: TruckType.unknown,
        isOnline: false,
        updatedAt: _now(),
      );
      final live = _live[driverId];
      if (live != null) {
        _live[driverId] = live.copyWith(
          isOnline: false,
          updatedAt: _now().millisecondsSinceEpoch,
        );
        _emitLive();
      }
      _emitDrivers();
    }
    _emitTrucks();
    return null;
  }

  /// The field checks `truckFields` applies on the server.
  Failure? _truckRefusal(TruckDetails details) {
    final plateError = DoValidators.plate(details.plate);
    if (plateError != null) {
      return Failure(FailureCode.invalidInput, message: plateError);
    }
    if (!details.type.isDispatchable ||
        details.capacityKg <= 0 ||
        details.make.trim().isEmpty ||
        details.model.trim().isEmpty) {
      return const Failure(
        FailureCode.invalidInput,
        message: 'Revisa los datos de la grúa.',
      );
    }
    return null;
  }

  /// Mirrors the `setDriverStatus` callable. Returns the refusal, or null.
  String? setDriverStatus(
    String driverId,
    DriverStatus status, {
    String reason = '',
  }) {
    final driver = _drivers[driverId];
    if (driver == null) return 'Chofer no encontrado.';
    if (driver.archived) return 'Este chofer fue eliminado.';
    if (status == DriverStatus.unknown) return 'Datos inválidos.';

    final stopping = !status.canWork;
    if (stopping && driver.isBusy) {
      return 'Este chofer tiene un servicio en curso. Reasígnalo primero.';
    }

    _drivers[driverId] = driver.copyWith(
      status: status,
      statusReason: reason,
      isOnline: !stopping && driver.isOnline,
      updatedAt: _now(),
    );
    if (stopping) {
      final live = _live[driverId];
      if (live != null) {
        _live[driverId] = live.copyWith(
          isOnline: false,
          updatedAt: _now().millisecondsSinceEpoch,
        );
      }
      _emitLive();
    }
    _emitDrivers();
    return null;
  }

  void setLive(DriverLivePosition position) {
    _live[position.driverId] = position;
    _emitLive();
  }

  void setDriverOnline(String driverId, {required bool online}) {
    final driver = _drivers[driverId];
    if (driver == null) return;
    _drivers[driverId] = driver.copyWith(isOnline: online, lastOnlineAt: _now());
    final live = _live[driverId];
    if (live != null) {
      _live[driverId] = live.copyWith(
        isOnline: online,
        updatedAt: _now().millisecondsSinceEpoch,
      );
    }
    _emitDrivers();
    _emitLive();
  }

  /// There is no bucket, so an uploaded photo is kept here as a data URI and
  /// handed back as its "download URL".
  final _uploads = <String, String>{};

  void storeUpload(String path, String dataUri) => _uploads[path] = dataUri;

  /// The data URI kept for [path], standing in for a download URL.
  String? uploadUrl(String path) => _uploads[path];

  final _documents = <String, Map<DriverDocumentType, DriverDocument>>{};

  /// What `watchDocuments` shows for [uid].
  List<DriverDocument> documents(String uid) =>
      (_documents[uid] ?? const {}).values.toList();

  /// Mirrors the `attachDriverDocument` callable.
  void attachDocument(String driverId, DriverDocument document) {
    (_documents[driverId] ??= {})[document.type] = document;
    // The document stream rides on the driver one; see `watchDocuments`.
    _emitDrivers();
  }

  /// Mirrors `verifyDriverLicense`, with a model that reads every licence
  /// as exactly what the chofer typed. Returns the new state, or the refusal.
  (LicenseVerificationState?, String?) verifyLicense(String driverId) {
    final driver = _drivers[driverId];
    final current = driver?.licenseVerification;
    if (driver == null) return (null, 'Chofer no encontrado.');
    if (current == null) {
      return (
        null,
        'Tu cuenta la abrió la oficina y no necesita esta verificación.',
      );
    }
    if (!current.state.acceptsPhotos) return (current.state, null);

    final docs = _documents[driverId] ?? const {};
    if (!docs.containsKey(DriverDocumentType.licencia) ||
        !docs.containsKey(DriverDocumentType.licenciaReverso)) {
      return (null, 'Faltan fotos: sube el frente y el reverso de tu licencia.');
    }

    const labels = [
      ('document', 'Es una licencia de conducir (frente y reverso)'),
      ('dominican', 'Emitida en la República Dominicana'),
      ('legible', 'Las fotos se leen con claridad'),
      ('integrity', 'Sin señales de alteración'),
      ('name', 'El nombre coincide'),
      ('cedula', 'La cédula coincide'),
      ('licenseNumber', 'El número de licencia coincide'),
      ('expiryMatches', 'La fecha de vencimiento coincide'),
      ('notExpired', 'La licencia está vigente'),
      ('face', 'La cara coincide con la foto de perfil'),
    ];
    final expiry = driver.licenseExpiry;
    _drivers[driverId] = driver.copyWith(
      licenseVerification: current.copyWith(
        state: LicenseVerificationState.verified,
        reason: '',
        attempts: current.attempts + 1,
        checks: [
          for (final (key, label) in labels)
            LicenseCheck(key: key, label: label, result: 'pass'),
        ],
        extracted: LicenseReading(
          fullName: driver.name.toUpperCase(),
          cedula: driver.displayCedula,
          licenseNumber: driver.licenseNumber,
          expiryDate: expiry == null
              ? ''
              : expiry.toIso8601String().substring(0, 10),
        ),
        notes: 'Modo demo: la verificación siempre pasa.',
        startedAt: _now(),
        completedAt: _now(),
        updatedAt: _now(),
      ),
    );
    _emitDrivers();
    return (LicenseVerificationState.verified, null);
  }

  /// Mirrors `correctDriverRegistration`. Returns the refusal, or null.
  String? correctRegistration(
    String driverId, {
    required String name,
    required String cedula,
    required String licenseNumber,
    required DateTime licenseExpiry,
  }) {
    final driver = _drivers[driverId];
    final check = driver?.licenseVerification;
    if (driver == null) return 'Chofer no encontrado.';
    if (check == null ||
        !check.state.acceptsPhotos ||
        driver.status != DriverStatus.inactive) {
      return 'Ya no puedes cambiar tus datos. Comunícate con la oficina.';
    }
    final digits = cedula.replaceAll(RegExp(r'\D'), '');
    if (_drivers.values.any((d) => d.id != driverId && d.cedula == digits)) {
      return 'Ya existe un chofer con esa cédula. Comunícate con la oficina.';
    }
    _drivers[driverId] = driver.copyWith(
      name: name,
      cedula: digits,
      licenseNumber: licenseNumber,
      licenseExpiry: licenseExpiry,
      updatedAt: _now(),
    );
    _emitDrivers();
    return null;
  }

  /// Mirrors `reviewLicenseVerification`. Returns the refusal, or null.
  String? reviewLicense(
    String driverId, {
    required bool approve,
    String reason = '',
  }) {
    final driver = _drivers[driverId];
    final current = driver?.licenseVerification;
    if (driver == null) return 'Chofer no encontrado.';
    if (current == null) return 'Este chofer no tiene verificación de licencia.';
    if (!approve && reason.trim().length < 3) {
      return 'Escribe el motivo del rechazo.';
    }
    _drivers[driverId] = driver.copyWith(
      licenseVerification: current.copyWith(
        state: approve
            ? LicenseVerificationState.verified
            : LicenseVerificationState.rejected,
        reason: approve ? '' : reason.trim(),
        attempts: approve ? current.attempts : 0,
        reviewedBy: currentUserId,
        reviewedAt: _now(),
        updatedAt: _now(),
      ),
    );
    _emitDrivers();
    return null;
  }

  /// Mirrors the `setDriverPhoto` callable. Returns the URL, or null when
  /// nothing was uploaded at [path] or the chofer does not exist.
  String? setDriverPhoto(String driverId, String path) {
    final driver = _drivers[driverId];
    final url = _uploads[path];
    if (driver == null || url == null) return null;
    _drivers[driverId] = driver.copyWith(photoUrl: url, updatedAt: _now());
    _emitDrivers();
    return url;
  }

  void addMessage(String serviceId, ChatMessage message) {
    (_messages[serviceId] ??= []).add(message);
    _messagesController.add(serviceId);
  }

  /// Mirrors `ChatRepository.markRead`: stamps every message the other party
  /// sent that [readerId] had not seen yet. Their own are left alone.
  void markMessagesRead(String serviceId, String readerId) {
    final messages = _messages[serviceId];
    if (messages == null) return;

    var changed = false;
    for (var i = 0; i < messages.length; i++) {
      final message = messages[i];
      if (message.senderId == readerId || message.isRead) continue;
      messages[i] = message.copyWith(readAt: _now());
      changed = true;
    }
    if (changed) _messagesController.add(serviceId);
  }

  // -------------------------------------------------------------------------
  // Chat requests — mirrors requestChat / respondChatRequest / closeChatRequest
  // -------------------------------------------------------------------------

  /// How long a chofer has to answer, and how long an accepted conversation
  /// stays open — the values the callables use.
  static const chatRequestTtl = Duration(minutes: 5);
  static const chatRequestOpenFor = Duration(hours: 2);

  List<ChatRequest> get allChatRequests => _chatRequestsWhere((_) => true);

  ChatRequest? chatRequest(String id) => _chatRequests[id];

  List<ChatRequest> _chatRequestsWhere(bool Function(ChatRequest) test) =>
      List.unmodifiable(
        _chatRequests.values.where(test).toList()
          ..sort(
            (a, b) => (b.createdAt ?? DateTime(0))
                .compareTo(a.createdAt ?? DateTime(0)),
          ),
      );

  Stream<List<ChatRequest>> chatRequestsWhere(
    bool Function(ChatRequest) test,
  ) async* {
    yield _chatRequestsWhere(test);
    yield* _chatRequestsController.stream.map((_) => _chatRequestsWhere(test));
  }

  Stream<ChatRequest?> chatRequestUpdates(String id) async* {
    yield _chatRequests[id];
    yield* _chatRequestsController.stream.map((_) => _chatRequests[id]);
  }

  Stream<List<ChatMessage>> chatRequestMessagesFor(String id) async* {
    yield List.unmodifiable(_chatRequestMessages[id] ?? const []);
    yield* _chatRequestMessagesController.stream
        .where((changed) => changed == id)
        .map((_) => List<ChatMessage>.unmodifiable(
              _chatRequestMessages[id] ?? const [],
            ));
  }

  /// Opens a request from [clientId] to [driverId], or returns the one already
  /// waiting or open between them. Refused when the chofer cannot take work.
  Result<String> createChatRequest({
    required String clientId,
    required String driverId,
  }) {
    final driver = _drivers[driverId];
    final online =
        (driver?.isOnline ?? false) || (_live[driverId]?.isOnline ?? false);
    if (driver == null || !driver.status.canWork || driver.isBusy || !online) {
      return const Result.err(Failure(FailureCode.chatRequestUnavailable));
    }

    final now = _now();
    for (final existing in _chatRequests.values) {
      if (existing.clientId == clientId &&
          existing.driverId == driverId &&
          existing.phaseAt(now) != ChatRequestPhase.over) {
        return Result.ok(existing.id);
      }
    }

    final id = 'chat-req-${++_chatRequestCounter}';
    _chatRequests[id] = ChatRequest(
      id: id,
      clientId: clientId,
      clientName: _users[clientId]?.shortName ?? 'Cliente',
      driverId: driverId,
      createdAt: now,
      expiresAt: now.add(chatRequestTtl),
    );
    _chatRequestsController.add(null);
    return Result.ok(id);
  }

  Result<void> respondChatRequest(
    String id,
    String driverId, {
    required bool accept,
  }) {
    final request = _chatRequests[id];
    if (request == null || request.driverId != driverId) {
      return const Result.err(Failure(FailureCode.notFound));
    }
    final now = _now();
    if (request.phaseAt(now) != ChatRequestPhase.waiting) {
      return const Result.err(Failure(FailureCode.chatRequestExpired));
    }

    _chatRequests[id] = accept
        ? request.copyWith(
            status: ChatRequestStatus.accepted,
            driverName: _drivers[driverId]?.shortName ?? 'Chofer',
            driverPhotoUrl: _drivers[driverId]?.photoUrl ?? '',
            respondedAt: now,
            closesAt: now.add(chatRequestOpenFor),
          )
        : request.copyWith(status: ChatRequestStatus.declined, respondedAt: now);
    _chatRequestsController.add(null);
    return const Result.ok(null);
  }

  // -------------------------------------------------------------------------
  // Voice calls — mirrors functions/src/callables/calls.ts
  // -------------------------------------------------------------------------

  final Map<String, VoiceCall> _calls = {};
  final _callsController = StreamController<void>.broadcast();
  var _callCounter = 0;

  List<VoiceCall> get allCalls => List.unmodifiable(_calls.values);

  VoiceCall? call(String id) => _calls[id];

  Stream<VoiceCall?> incomingCallFor(String uid) async* {
    VoiceCall? ringing() => _calls.values
        .where((c) => c.calleeId == uid && c.state == CallState.ringing)
        .fold<VoiceCall?>(null, (latest, c) => latest ?? c);
    yield ringing();
    yield* _callsController.stream.map((_) => ringing());
  }

  Stream<VoiceCall?> callUpdates(String id) async* {
    yield _calls[id];
    yield* _callsController.stream.map((_) => _calls[id]);
  }

  void _emitCalls() => _callsController.add(null);

  /// Rings the other party on a service. Refused the same ways the callable is.
  Result<CallJoin> startCall(
    String serviceId,
    String callerId, {
    bool video = false,
  }) {
    final service = _services[serviceId];
    if (service == null) {
      return const Err(Failure(FailureCode.notFound));
    }
    final isClient = callerId == service.clientId;
    if (!isClient && callerId != service.driverId) {
      return const Err(Failure(FailureCode.permissionDenied));
    }
    if (!service.canCall) {
      return const Err(
        Failure(
          FailureCode.invalidTransition,
          message: 'Solo puedes llamar mientras el servicio está en curso.',
        ),
      );
    }
    final busy = _calls.values.any(
      (c) =>
          c.serviceId == serviceId &&
          (c.state == CallState.ringing || c.state == CallState.accepted),
    );
    if (busy) {
      return const Err(
        Failure(
          FailureCode.invalidTransition,
          message: 'Ya hay una llamada en curso.',
        ),
      );
    }

    final id = 'call-${++_callCounter}';
    final clientName = service.clientName.isEmpty ? 'Cliente' : service.clientName;
    final driverName = service.driverName.isEmpty ? 'Chofer' : service.driverName;
    _calls[id] = VoiceCall(
      id: id,
      serviceId: serviceId,
      state: CallState.ringing,
      callerId: callerId,
      callerName: isClient ? clientName : driverName,
      calleeId: isClient ? service.driverId! : service.clientId,
      calleeName: isClient ? driverName : clientName,
      video: video,
      createdAt: _now(),
    );
    _emitCalls();
    return Ok(
      CallJoin(
        callId: id,
        peerName: isClient ? driverName : clientName,
        url: '',
        token: '',
        video: video,
      ),
    );
  }

  /// Rings the other side of an open pre-job conversation. Refused the same
  /// ways the callable is.
  Result<CallJoin> startChatRequestCall(
    String requestId,
    String callerId, {
    bool video = false,
  }) {
    final request = _chatRequests[requestId];
    if (request == null) return const Err(Failure(FailureCode.notFound));
    final isClient = callerId == request.clientId;
    if (!isClient && callerId != request.driverId) {
      return const Err(Failure(FailureCode.permissionDenied));
    }
    if (request.phaseAt(_now()) != ChatRequestPhase.open) {
      return const Err(
        Failure(
          FailureCode.invalidTransition,
          message: 'Solo puedes llamar mientras la conversación está abierta.',
        ),
      );
    }
    final busy = _calls.values.any(
      (c) =>
          c.chatRequestId == requestId &&
          (c.state == CallState.ringing || c.state == CallState.accepted),
    );
    if (busy) {
      return const Err(
        Failure(
          FailureCode.invalidTransition,
          message: 'Ya hay una llamada en curso.',
        ),
      );
    }

    final id = 'call-${++_callCounter}';
    final clientName = request.clientName.isEmpty ? 'Cliente' : request.clientName;
    final driverName = request.driverName.isEmpty ? 'Chofer' : request.driverName;
    _calls[id] = VoiceCall(
      id: id,
      serviceId: '',
      chatRequestId: requestId,
      state: CallState.ringing,
      callerId: callerId,
      callerName: isClient ? clientName : driverName,
      calleeId: isClient ? request.driverId : request.clientId,
      calleeName: isClient ? driverName : clientName,
      video: video,
      createdAt: _now(),
    );
    _emitCalls();
    return Ok(
      CallJoin(
        callId: id,
        peerName: isClient ? driverName : clientName,
        url: '',
        token: '',
        video: video,
      ),
    );
  }

  Result<CallJoin> answerCall(String callId, String uid) {
    final call = _calls[callId];
    if (call == null) return const Err(Failure(FailureCode.notFound));
    if (uid != call.calleeId) {
      return const Err(
        Failure(FailureCode.permissionDenied, message: 'Esta llamada no es para ti.'),
      );
    }
    if (call.state != CallState.ringing) {
      return const Err(
        Failure(FailureCode.invalidTransition, message: 'La llamada ya terminó.'),
      );
    }
    _calls[callId] = call.copyWith(state: CallState.accepted, answeredAt: _now());
    _emitCalls();
    return Ok(
      CallJoin(
        callId: callId,
        peerName: call.callerName,
        url: '',
        token: '',
        video: call.video,
      ),
    );
  }

  Result<void> endCall(String callId, String uid, EndCallReason reason) {
    final call = _calls[callId];
    if (call == null) return const Err(Failure(FailureCode.notFound));
    if (uid != call.callerId && uid != call.calleeId) {
      return const Err(Failure(FailureCode.permissionDenied));
    }
    // Idempotent, like the callable.
    if (call.state.isOver) return const Ok(null);

    final next = call.state == CallState.accepted
        ? CallState.ended
        : uid == call.calleeId
            ? CallState.declined
            : reason == EndCallReason.missed
                ? CallState.missed
                : CallState.cancelled;
    _calls[callId] = call.copyWith(state: next);
    _emitCalls();
    return const Ok(null);
  }

  Result<void> closeChatRequest(String id, String callerId) {
    final request = _chatRequests[id];
    final byClient = request?.clientId == callerId;
    if (request == null || (!byClient && request.driverId != callerId)) {
      return const Result.err(Failure(FailureCode.notFound));
    }

    final next = switch (request.phaseAt(_now())) {
      ChatRequestPhase.waiting =>
        byClient ? ChatRequestStatus.cancelled : ChatRequestStatus.declined,
      ChatRequestPhase.open => ChatRequestStatus.closed,
      ChatRequestPhase.over => null,
    };
    if (next != null) {
      _chatRequests[id] = request.copyWith(status: next);
      _chatRequestsController.add(null);
    }
    return const Result.ok(null);
  }

  void addChatRequestMessage(String id, ChatMessage message) {
    (_chatRequestMessages[id] ??= []).add(message);
    _chatRequestMessagesController.add(id);
  }

  void markChatRequestMessagesRead(String id, String readerId) {
    final messages = _chatRequestMessages[id];
    if (messages == null) return;

    var changed = false;
    for (var i = 0; i < messages.length; i++) {
      final message = messages[i];
      if (message.senderId == readerId || message.isRead) continue;
      messages[i] = message.copyWith(readAt: _now());
      changed = true;
    }
    if (changed) _chatRequestMessagesController.add(id);
  }

  /// Retracts messages in a job's chat, the way the rules let either party:
  /// the words and the photo go, a tombstone stays.
  void retractMessages(String serviceId, List<String> ids) {
    if (_retract(_messages[serviceId], ids)) {
      _messagesController.add(serviceId);
    }
  }

  /// The same, in a conversation opened from the map.
  void retractChatRequestMessages(String requestId, List<String> ids) {
    if (_retract(_chatRequestMessages[requestId], ids)) {
      _chatRequestMessagesController.add(requestId);
    }
  }

  bool _retract(List<ChatMessage>? messages, List<String> ids) {
    if (messages == null) return false;
    final wanted = ids.toSet();
    var changed = false;
    for (var i = 0; i < messages.length; i++) {
      final message = messages[i];
      // Only once: a tombstone has nothing left to clear.
      if (!wanted.contains(message.id) || message.isDeleted) continue;
      messages[i] = message.copyWith(
        text: '',
        imageUrl: '',
        deletedAt: _now(),
      );
      changed = true;
    }
    return changed;
  }

  /// How long one keystroke keeps the indicator alive, as in the real one.
  static const _typingFreshness = Duration(seconds: 8);

  /// Who is typing in one conversation. A flag nobody refreshed ages out, so a
  /// phone that died mid-word does not say "escribiendo…" forever.
  Stream<Set<String>> typingFor(String threadKey) async* {
    yield _typingNow(threadKey);
    yield* _typingController.stream
        .where((changed) => changed == threadKey)
        .map((_) => _typingNow(threadKey));
  }

  Set<String> _typingNow(String threadKey) {
    final entries = _typing[threadKey];
    if (entries == null) return const {};
    final now = _now();
    return {
      for (final entry in entries.entries)
        if (now.difference(entry.value) < _typingFreshness) entry.key,
    };
  }

  void setTyping({
    required String threadKey,
    required String uid,
    required bool typing,
  }) {
    final entries = _typing.putIfAbsent(threadKey, () => {});
    if (typing) {
      entries[uid] = _now();
    } else {
      entries.remove(uid);
    }
    _typingController.add(threadKey);
  }

  // -------------------------------------------------------------------------
  // Each person's own view of their conversations
  // -------------------------------------------------------------------------

  Stream<Map<String, ChatThreadPrefs>> chatPrefsFor(String uid) async* {
    yield _prefsOf(uid);
    yield* _chatPrefsController.stream
        .where((changed) => changed == uid)
        .map((_) => _prefsOf(uid));
  }

  Stream<Set<String>> blockedFor(String uid) async* {
    yield {...?_blocked[uid]};
    yield* _chatPrefsController.stream
        .where((changed) => changed == uid)
        .map((_) => {...?_blocked[uid]});
  }

  Map<String, ChatThreadPrefs> _prefsOf(String uid) => {...?_chatPrefs[uid]};

  /// Hides what has been said so far, and the conversation itself when
  /// [alsoFromList] — the difference between "vaciar" and "eliminar".
  void clearChatThread(
    String uid,
    String threadKey, {
    bool alsoFromList = false,
  }) {
    final now = _now();
    _chatPrefs.putIfAbsent(uid, () => {})[threadKey] = ChatThreadPrefs(
      clearedAt: now,
      deletedAt: alsoFromList ? now : _chatPrefs[uid]?[threadKey]?.deletedAt,
    );
    _chatPrefsController.add(uid);
  }

  void setBlocked(String uid, String otherUid, {required bool blocked}) {
    final list = _blocked.putIfAbsent(uid, () => {});
    if (blocked) {
      list.add(otherUid);
    } else {
      list.remove(otherUid);
    }
    _chatPrefsController.add(uid);
  }

  /// Sets [insurerId]'s chofer share, as the office would on the company.
  void setInsurerPayoutBps(String insurerId, int bps) =>
      _insurerPayoutBps[insurerId] = bps;

  // -------------------------------------------------------------------------
  // Insurance companies — mirrors functions/src/callables/insurers.ts and
  // pricing.ts
  // -------------------------------------------------------------------------

  final Map<String, Insurer> _insurers = {};
  final Map<String, Map<String, InsurerMember>> _insurerMembers = {};
  final List<PricingRule> _pricingRules = [];
  var _insurerCounter = 0;
  var _insurerUserCounter = 0;

  List<Insurer> get allInsurers => List.unmodifiable(
        _insurers.values.toList()..sort((a, b) => a.name.compareTo(b.name)),
      );

  Insurer? insurer(String id) => _insurers[id];

  /// The company [uid] works for, or null.
  String? insurerIdOf(String uid) {
    for (final entry in _insurerMembers.entries) {
      if (entry.value.containsKey(uid)) return entry.key;
    }
    return null;
  }

  InsurerMember? insurerMember(String insurerId, String uid) =>
      _insurerMembers[insurerId]?[uid];

  /// The backend's clock, which tests may set.
  DateTime now() => _now();

  /// `config/settlements.startAt`: jobs finished before it stay out of cortes.
  DateTime? settlementsStartAt;

  /// Mirrors `requireActiveInsurer`: why [uid] may not act for a company
  /// right now, or null when they may.
  Failure? insurerRefusal(String uid) {
    final insurerId = insurerIdOf(uid);
    final company = insurerId == null ? null : _insurers[insurerId];
    final member = insurerId == null ? null : _insurerMembers[insurerId]?[uid];
    if (company == null || member == null) {
      return const Failure(
        FailureCode.permissionDenied,
        message: 'Esta cuenta no pertenece a una aseguradora.',
      );
    }
    if (!company.isActive) {
      return const Failure(
        FailureCode.accountSuspended,
        message: 'La cuenta de tu aseguradora está suspendida. Comunícate con la oficina.',
      );
    }
    if (!member.active) {
      return const Failure(
        FailureCode.accountSuspended,
        message: 'Tu usuario está desactivado. Pide acceso al administrador de tu empresa.',
      );
    }
    return null;
  }

  /// Mirrors `canManageMembers` and `memberChangeRefusal`: the office may
  /// change anyone; a company's manager, their own company's people, but not
  /// demote or deactivate themselves. Null when the change may go ahead.
  Failure? _memberChangeRefusal(
    String? actorId,
    String insurerId, {
    String? targetUid,
    InsurerRole? role,
    bool? active,
  }) {
    if (actorId == null) return null;
    final actorCompany = insurerIdOf(actorId);
    // Not a company's person: the office.
    if (actorCompany == null) return null;
    final refused = insurerRefusal(actorId);
    if (refused != null) return refused;
    final actor = _insurerMembers[actorCompany]![actorId]!;
    if (actorCompany != insurerId || actor.role != InsurerRole.manager) {
      return const Failure(FailureCode.permissionDenied);
    }
    if (targetUid != actorId) return null;
    if (active == false) {
      return const Failure(_invalid, message: 'No puedes desactivar tu propio usuario.');
    }
    if (role != null && role != InsurerRole.manager) {
      return const Failure(
        _invalid,
        message: 'No puedes quitarte el rol de administrador de tu empresa.',
      );
    }
    return null;
  }

  /// The company person who signs in with [email], if any.
  InsurerMember? insurerMemberByEmail(String email) {
    final wanted = email.trim().toLowerCase();
    if (wanted.isEmpty) return null;
    for (final members in _insurerMembers.values) {
      for (final member in members.values) {
        if (member.email.toLowerCase() == wanted) return member;
      }
    }
    return null;
  }

  /// Every tow [insurerId] ordered, newest first.
  List<Service> insurerServices(String insurerId, {DateTime? since}) {
    final list = [
      for (final s in _services.values)
        if (s.insurerId == insurerId &&
            (since == null || !(s.createdAt ?? _now()).isBefore(since)))
          s,
    ]..sort((a, b) => (b.createdAt ?? _now()).compareTo(a.createdAt ?? _now()));
    return List.unmodifiable(list);
  }

  /// Mirrors `quoteInsurerService`: priced on the company's table, with the
  /// straight-line distance the demo uses everywhere.
  Result<InsurerQuote> quoteInsurerService({
    required String insurerId,
    required ServiceLocation pickup,
    required ServiceLocation dropoff,
    required VehicleType vehicleType,
  }) {
    final vehicleClass = VehicleClass.of(vehicleType);
    if (!VehicleClass.priced.contains(vehicleClass)) {
      return const Err(Failure(FailureCode.invalidInput, message: 'Elige el tipo de vehículo.'));
    }
    final (rules, tariff) = zoneTableFor(insurerId, vehicleClass);
    final zone = ZonePricing.quote(
      rules: rules,
      distanceKm: pickup.geo.distanceKmTo(dropoff.geo) * 1.3,
      tariff: tariff,
    );
    final totals = ZonePricing.withItbis(zone.subtotalCents);
    return Ok(
      InsurerQuote(
        subtotalCents: totals.subtotalCents,
        itbisCents: totals.itbisCents,
        totalCents: totals.totalCents,
        vehicleClass: zone.vehicleClass,
        zoneMinKm: zone.zoneMinKm,
        zoneMaxKm: zone.zoneMaxKm,
        baseCents: zone.baseCents,
        extraKm: zone.extraKm,
        extraCents: zone.extraCents,
        negotiated: tariff == ZoneTariffSource.insurer,
        distanceKm: zone.distanceKm,
        durationSeconds: (zone.distanceKm / 28 * 3600).round(),
        expiresAt: _now().toUtc().add(const Duration(minutes: 15)),
        signature: 'demo',
      ),
    );
  }

  /// A person of a company ordering, with the refusals the callable gives.
  Result<CreatedInsurerService> orderInsurerService(
    String uid,
    InsurerServiceRequest request,
  ) {
    final refused = insurerRefusal(uid);
    if (refused != null) return Err(refused);
    final insurerId = insurerIdOf(uid);
    final company = _insurers[insurerId]!;
    if (!VehicleClass.priced.contains(VehicleClass.of(request.vehicleType))) {
      return const Err(Failure(_invalid, message: 'Elige el tipo de vehículo.'));
    }
    final key = request.claimNumber.toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), '');
    if (key.isEmpty) {
      return const Err(Failure(FailureCode.invalidInput, message: 'Escribe el número de siniestro.'));
    }
    final duplicate = _services.values.any(
      (s) =>
          s.insurerId == insurerId &&
          s.isActive &&
          s.insurance?.claimKey == key,
    );
    if (duplicate) {
      return const Err(
        Failure(
          FailureCode.alreadyHasActiveService,
          message: 'Ya hay un servicio en curso para ese número de siniestro.',
        ),
      );
    }
    final service = createInsurerService(
      insurerId: insurerId!,
      insurerName: company.name,
      requestedBy: uid,
      pickup: request.pickup,
      dropoff: request.dropoff,
      vehicle: ServiceVehicle(
        type: request.vehicleType,
        plate: request.plate.trim().toUpperCase(),
        make: request.make.trim(),
        model: request.model.trim(),
        color: request.color.trim(),
      ),
      insurance: InsuranceClaim(
        claimNumber: request.claimNumber.trim(),
        policyNumber: request.policyNumber.trim(),
        insuredName: request.insuredName.trim(),
        insuredPhone: request.insuredPhone.trim(),
      ),
      notes: request.notes.trim(),
    );
    return Ok(
      CreatedInsurerService(
        serviceId: service.id,
        code: service.code,
        totalCents: service.quote.totalCents,
      ),
    );
  }

  /// The company that ordered a tow cancels it.
  Result<void> cancelByInsurer(String uid, String serviceId) {
    final refused = insurerRefusal(uid);
    if (refused != null) return Err(refused);
    final service = _services[serviceId];
    if (service == null) return const Err(Failure(FailureCode.notFound));
    if (service.insurerId.isEmpty || service.insurerId != insurerIdOf(uid)) {
      return const Err(
        Failure(FailureCode.invalidTransition, message: 'Este servicio no es tuyo.'),
      );
    }
    if (!service.status.isCancellableByClient) {
      return const Err(Failure(FailureCode.invalidTransition));
    }
    // Late, and the company pays the fee on its next invoice.
    final fee = Pricing.cancellationFeeCents(
      config: _pricing,
      acceptedAt: service.timeline.acceptedAt,
      now: _now(),
    );
    _services[serviceId] = service.copyWith(
      cancellation: ServiceCancellation(
        by: CancelledBy.insurer,
        actorId: uid,
        feeCents: fee,
      ),
      payment: fee > 0
          ? service.payment.copyWith(status: PaymentStatus.toInvoice)
          : service.payment,
    );
    _transition(serviceId, ServiceStatus.cancelled, ServiceEventName.cancelService,
        uid, UserRole.insurer);
    return const Ok(null);
  }

  Result<void> insurerPasswordChanged(String uid) {
    final refused = insurerRefusal(uid);
    if (refused != null) return Err(refused);
    final insurerId = insurerIdOf(uid);
    final member = insurerId == null ? null : _insurerMembers[insurerId]![uid];
    if (member == null) return const Err(Failure(FailureCode.permissionDenied));
    _insurerMembers[insurerId]![uid] = InsurerMember(
      insurerId: member.insurerId,
      uid: member.uid,
      name: member.name,
      email: member.email,
      phone: member.phone,
      role: member.role,
      active: member.active,
      createdBy: member.createdBy,
      createdAt: member.createdAt,
    );
    _emitServices();
    return const Ok(null);
  }

  /// Marks [uid] as needing a new password, the state a first sign-in is in.
  void requirePasswordChange(String uid) {
    final insurerId = insurerIdOf(uid);
    final member = insurerId == null ? null : _insurerMembers[insurerId]![uid];
    if (member == null) return;
    _insurerMembers[insurerId]![uid] = InsurerMember(
      insurerId: member.insurerId,
      uid: member.uid,
      name: member.name,
      email: member.email,
      phone: member.phone,
      role: member.role,
      active: member.active,
      mustChangePassword: true,
      createdBy: member.createdBy,
      createdAt: member.createdAt,
    );
    _emitServices();
  }

  List<InsurerMember> insurerMembers(String insurerId) => List.unmodifiable(
        (_insurerMembers[insurerId]?.values.toList() ?? <InsurerMember>[])
          ..sort((a, b) => a.name.compareTo(b.name)),
      );

  /// The stored rows of one table owner; [insurerId] null is the default list.
  List<PricingRule> pricingRules({String? insurerId}) => List.unmodifiable(
        _pricingRules.where((r) => r.insurerId == insurerId),
      );

  /// The table [insurerId]'s [vehicleClass] is billed on, as `zoneTableFor`
  /// resolves it.
  (List<PricingRule>, ZoneTariffSource) zoneTableFor(
    String insurerId,
    VehicleClass vehicleClass,
  ) {
    List<PricingRule> rowsOf(String? owner) => [
          for (final r in _pricingRules)
            if (r.insurerId == owner && r.vehicleClass == vehicleClass) r,
        ];
    final own = rowsOf(insurerId);
    if (own.isNotEmpty) return (own, ZoneTariffSource.insurer);
    final stored = rowsOf(null);
    if (stored.isNotEmpty) return (stored, ZoneTariffSource.standard);
    return (ZonePricing.defaultRulesFor(vehicleClass), ZoneTariffSource.standard);
  }

  int _payoutBpsFor(String insurerId) =>
      _insurers[insurerId]?.driverPayoutBps ??
      _insurerPayoutBps[insurerId] ??
      ZonePricing.defaultDriverPayoutBps;

  static const FailureCode _invalid = FailureCode.invalidInput;

  String? _detailsProblem(InsurerDetails d, {String? exceptId}) {
    if (d.name.trim().length < 2) return 'Escribe el nombre completo.';
    final rnc = DoValidators.companyRnc(d.rnc);
    if (rnc != null) return rnc;
    if (DoValidators.email(d.billingEmail) != null) {
      return 'El correo de facturación no es válido.';
    }
    if (d.contactEmail.trim().isNotEmpty &&
        DoValidators.email(d.contactEmail) != null) {
      return 'El correo de contacto no es válido.';
    }
    final digits = DoValidators.digits(d.rnc);
    if (_insurers.values.any((i) => i.rnc == digits && i.id != exceptId)) {
      return 'Ya existe una aseguradora con ese RNC.';
    }
    return null;
  }

  Result<String> createInsurer(InsurerDetails details, {int? driverPayoutBps}) {
    final problem = _detailsProblem(details);
    if (problem != null) return Err(Failure(_invalid, message: problem));
    if (driverPayoutBps != null && (driverPayoutBps < 0 || driverPayoutBps > 10000)) {
      return const Err(
        Failure(_invalid, message: 'El porcentaje del chofer debe estar entre 0% y 100%.'),
      );
    }
    _insurerCounter++;
    final id = 'ins-$_insurerCounter';
    _insurers[id] = Insurer(
      id: id,
      name: details.name.trim(),
      rnc: DoValidators.digits(details.rnc),
      contactName: details.contactName.trim(),
      contactEmail: details.contactEmail.trim(),
      contactPhone: details.contactPhone.trim(),
      billingEmail: details.billingEmail.trim(),
      status: InsurerStatus.active,
      driverPayoutBps: driverPayoutBps,
      createdAt: _now().toUtc(),
    );
    _insurerMembers[id] = {};
    _emitServices();
    return Ok(id);
  }

  Result<void> updateInsurer(
    String insurerId, {
    InsurerDetails? details,
    InsurerStatus? status,
    String? statusReason,
    int? driverPayoutBps,
    bool clearDriverPayout = false,
  }) {
    final current = _insurers[insurerId];
    if (current == null) return const Err(Failure(FailureCode.notFound));
    if (details != null) {
      final problem = _detailsProblem(details, exceptId: insurerId);
      if (problem != null) return Err(Failure(_invalid, message: problem));
    }
    if (driverPayoutBps != null && (driverPayoutBps < 0 || driverPayoutBps > 10000)) {
      return const Err(
        Failure(_invalid, message: 'El porcentaje del chofer debe estar entre 0% y 100%.'),
      );
    }
    final nextStatus = status ?? current.status;
    _insurers[insurerId] = Insurer(
      id: insurerId,
      name: details?.name.trim() ?? current.name,
      rnc: details == null ? current.rnc : DoValidators.digits(details.rnc),
      contactName: details?.contactName.trim() ?? current.contactName,
      contactEmail: details?.contactEmail.trim() ?? current.contactEmail,
      contactPhone: details?.contactPhone.trim() ?? current.contactPhone,
      billingEmail: details?.billingEmail.trim() ?? current.billingEmail,
      status: nextStatus,
      statusReason: statusReason ??
          (nextStatus == InsurerStatus.active ? '' : current.statusReason),
      driverPayoutBps:
          clearDriverPayout ? null : driverPayoutBps ?? current.driverPayoutBps,
      createdAt: current.createdAt,
      updatedAt: _now().toUtc(),
    );
    _emitServices();
    return const Ok(null);
  }

  Result<NewInsurerUser> createInsurerUser({
    required String insurerId,
    required String name,
    required String email,
    required InsurerRole role,
    String phone = '',
    String? actorId,
  }) {
    final refused = _memberChangeRefusal(actorId, insurerId);
    if (refused != null) return Err(refused);
    if (!_insurers.containsKey(insurerId)) {
      return const Err(Failure(FailureCode.notFound, message: 'No encontramos esa aseguradora.'));
    }
    if (name.trim().length < 2) {
      return const Err(Failure(_invalid, message: 'Escribe el nombre completo.'));
    }
    final address = email.trim().toLowerCase();
    if (DoValidators.email(address) != null) {
      return const Err(Failure(_invalid, message: 'El correo no es válido.'));
    }
    final taken = _insurerMembers.values
        .expand((members) => members.values)
        .any((m) => m.email == address);
    if (taken) {
      return const Err(Failure(_invalid, message: 'Ya existe una cuenta con ese correo.'));
    }
    _insurerUserCounter++;
    final uid = 'insurer-user-$_insurerUserCounter';
    (_insurerMembers[insurerId] ??= {})[uid] = InsurerMember(
      insurerId: insurerId,
      uid: uid,
      name: name.trim(),
      email: address,
      phone: phone.trim(),
      role: role,
      active: true,
      mustChangePassword: true,
      createdBy: currentUserId,
      createdAt: _now().toUtc(),
    );
    _emitServices();
    return Ok(
      NewInsurerUser(uid: uid, temporaryPassword: 'Demo-$_insurerUserCounter-Clave!'),
    );
  }

  Result<void> updateInsurerUser({
    required String insurerId,
    required String uid,
    String? name,
    String? phone,
    InsurerRole? role,
    bool? active,
    String? actorId,
  }) {
    final refused = _memberChangeRefusal(
      actorId,
      insurerId,
      targetUid: uid,
      role: role,
      active: active,
    );
    if (refused != null) return Err(refused);
    final member = _insurerMembers[insurerId]?[uid];
    if (member == null) {
      return const Err(
        Failure(FailureCode.notFound, message: 'Ese usuario no pertenece a esta aseguradora.'),
      );
    }
    _insurerMembers[insurerId]![uid] = InsurerMember(
      insurerId: insurerId,
      uid: uid,
      name: name?.trim() ?? member.name,
      email: member.email,
      phone: phone?.trim() ?? member.phone,
      role: role ?? member.role,
      active: active ?? member.active,
      mustChangePassword: member.mustChangePassword,
      createdBy: member.createdBy,
      createdAt: member.createdAt,
    );
    _emitServices();
    return const Ok(null);
  }

  Result<void> savePricingTable({
    required String? insurerId,
    required VehicleClass vehicleClass,
    required List<PricingRule> rows,
  }) {
    if (insurerId != null && !_insurers.containsKey(insurerId)) {
      return const Err(Failure(FailureCode.notFound, message: 'No encontramos esa aseguradora.'));
    }
    final rules = [
      for (final r in rows)
        PricingRule(
          vehicleClass: vehicleClass,
          zoneMinKm: r.zoneMinKm,
          zoneMaxKm: r.zoneMaxKm,
          baseCents: r.baseCents,
          extraKmCents: r.extraKmCents,
          insurerId: insurerId,
        ),
    ];
    if (rules.any((r) => r.baseCents < 0 || r.extraKmCents < 0)) {
      return const Err(
        Failure(_invalid, message: 'Revisa los precios: deben ser montos enteros y positivos.'),
      );
    }
    final problem = ZonePricing.tableProblem(rules);
    if (problem != null) return Err(Failure(_invalid, message: problem));
    _pricingRules
      ..removeWhere((r) => r.insurerId == insurerId && r.vehicleClass == vehicleClass)
      ..addAll(rules);
    _emitServices();
    return const Ok(null);
  }

  Result<void> resetPricingTable({
    required String? insurerId,
    required VehicleClass vehicleClass,
  }) {
    if (insurerId != null && !_insurers.containsKey(insurerId)) {
      return const Err(Failure(FailureCode.notFound, message: 'No encontramos esa aseguradora.'));
    }
    _pricingRules.removeWhere(
      (r) => r.insurerId == insurerId && r.vehicleClass == vehicleClass,
    );
    _emitServices();
    return const Ok(null);
  }

  /// The chofer's share of each insurer tow, fixed when it was ordered, as
  /// `services/{id}/internal/billing` keeps it.
  final Map<String, int> _payoutBpsByService = {};

  /// What the chofer takes home on [service], and what the company keeps.
  ({int gross, int net, int commission}) _takeHome(Service service) {
    if (service.isInsurerJob) {
      final subtotal = service.billedSubtotalCents;
      final bps = _payoutBpsByService[service.id] ?? _payoutBpsFor(service.insurerId);
      final net = ZonePricing.driverPayoutCents(subtotal, bps);
      return (gross: subtotal, net: net, commission: subtotal - net);
    }
    final gross = service.effectiveQuote.totalCents;
    final commission = Money.bps(gross, _pricing.commissionBps);
    return (gross: gross, net: gross - commission, commission: commission);
  }

  /// The offer [driverId] holds on [serviceId], as it changes.
  Stream<Offer?> offerUpdates(String serviceId, String driverId) async* {
    final key = '$serviceId/$driverId';
    yield _offers[key];
    await for (final _ in _servicesController.stream) {
      yield _offers[key];
    }
  }

  /// Mirrors `createInsurerService`: priced on the zone tariff, nobody to
  /// charge at the roadside, and no operator hold for a heavy vehicle.
  Service createInsurerService({
    required String insurerId,
    required String insurerName,
    required String requestedBy,
    required ServiceLocation pickup,
    required ServiceLocation dropoff,
    required ServiceVehicle vehicle,
    required InsuranceClaim insurance,
    String notes = '',
    String? preferredDriverId,
  }) {
    final now = _now();
    final id = 'svc-ins-${now.microsecondsSinceEpoch}';
    _serviceCounter++;

    // The straight line with the same detour allowance the server uses when
    // the Routes API does not answer.
    final distanceKm = pickup.geo.distanceKmTo(dropoff.geo) * 1.3;
    final (rules, tariff) = zoneTableFor(insurerId, VehicleClass.of(vehicle.type));
    final zone = ZonePricing.quote(
      rules: rules,
      distanceKm: distanceKm,
      tariff: tariff,
    );
    final totals = ZonePricing.withItbis(zone.subtotalCents);
    final claimKey =
        insurance.claimNumber.toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), '');

    _payoutBpsByService[id] = _payoutBpsFor(insurerId);
    final service = Service(
      id: id,
      clientId: '',
      clientName: insurance.insuredName,
      clientPhone: insurance.insuredPhone,
      code: 'GR-${_dateCode(now)}-0$_serviceCounter',
      insurerId: insurerId,
      insurerName: insurerName,
      insurance: insurance.copyWith(claimKey: claimKey),
      billing: InsurerBilling(
        insurerId: insurerId,
        tariff: zone.tariff.wire,
        vehicleClass: zone.vehicleClass,
        zoneMinKm: zone.zoneMinKm,
        zoneMaxKm: zone.zoneMaxKm,
        distanceKm: zone.distanceKm,
        baseCents: zone.baseCents,
        extraKm: zone.extraKm,
        extraKmCents: zone.extraKmCents,
        extraCents: zone.extraCents,
        subtotalCents: zone.subtotalCents,
      ),
      vehicle: vehicle,
      truckTypeRequired: vehicle.type.isHeavy ? TruckType.pesada : TruckType.gancho,
      pickup: pickup,
      dropoff: dropoff,
      route: ServiceRoute(
        distanceMeters: (zone.distanceKm * 1000).round(),
        provider: 'estimate',
      ),
      quote: Quote(
        pricingVersion: 0,
        vehicleType: vehicle.type,
        heavy: vehicle.type.isHeavy,
        baseCents: zone.baseCents,
        distanceKm: zone.distanceKm,
        perKmCents: zone.extraKmCents,
        distanceCents: zone.extraCents,
        subtotalCents: totals.subtotalCents,
        itbisCents: totals.itbisCents,
        totalCents: totals.totalCents,
      ),
      payment: const ServicePayment(method: PaymentMethod.insurer),
      driverNotes: notes,
      timeline: ServiceTimeline(createdAt: now),
      createdAt: now,
    );

    _services[id] = service;
    _appendEvent(id, ServiceEventName.requestService, ServiceStatus.unknown,
        ServiceStatus.pendingDispatch, requestedBy, UserRole.insurer);
    _emitServices();
    _scheduleDispatch(id, preferredDriverId: preferredDriverId);
    return service;
  }

  /// Creates a service and starts the simulated dispatch cascade.
  Service createService({
    required String clientId,
    required ServiceLocation pickup,
    required ServiceLocation dropoff,
    required ServiceVehicle vehicle,
    required TruckType truckType,
    required Quote quote,
    required ServiceRoute route,
    String? preferredDriverId,
  }) {
    final user = _users[clientId];
    final now = _now();
    final id = 'svc-${now.millisecondsSinceEpoch}';
    _serviceCounter++;

    // A heavy job waits for the operator, exactly as `requestService` does it.
    final heavy = vehicle.type.isHeavy;
    final status = heavy ? ServiceStatus.needsManual : ServiceStatus.pendingDispatch;

    final service = Service(
      id: id,
      clientId: clientId,
      clientName: user?.name ?? 'Cliente',
      clientPhone: user?.phone ?? '',
      code: 'GR-${_dateCode(now)}-0$_serviceCounter',
      status: status,
      operatorReview: heavy
          ? OperatorReview(isRequired: true, estimatedTotalCents: quote.totalCents)
          : null,
      dispatch: heavy
          ? const DispatchState(
              lastReason: 'Vehículo pesado: confirma disponibilidad y precio '
                  'final con el cliente.',
            )
          : const DispatchState(),
      vehicle: vehicle,
      truckTypeRequired: truckType,
      pickup: pickup,
      dropoff: dropoff,
      route: route,
      quote: quote,
      payment: const ServicePayment(),
      timeline: ServiceTimeline(createdAt: now),
      createdAt: now,
    );

    _services[id] = service;
    _appendEvent(id, ServiceEventName.requestService, ServiceStatus.unknown,
        status, clientId, UserRole.client);
    if (user != null) _users[clientId] = user.copyWith(activeServiceId: id);
    _emitServices();

    if (!heavy) _scheduleDispatch(id, preferredDriverId: preferredDriverId);
    return service;
  }

  /// Mirrors `confirmHeavyService`: the operator's price goes on the quote,
  /// and only then does the job look for a grúa. Returns the refusal, or null.
  String? confirmHeavyService({
    required String serviceId,
    required int totalCents,
    String note = '',
  }) {
    final service = _services[serviceId];
    if (service == null) return 'Este servicio ya no existe.';
    final review = service.operatorReview;
    if (review == null ||
        !review.isPending ||
        service.status != ServiceStatus.needsManual) {
      return 'Este servicio no tiene un precio por confirmar.';
    }
    if (totalCents < 10000) return 'Revisa el precio e intenta de nuevo.';

    final now = _now();
    _services[serviceId] = service.copyWith(
      status: ServiceStatus.pendingDispatch,
      quote: Pricing.confirmed(service.quote, totalCents),
      operatorReview: review.copyWith(
        state: OperatorReviewState.confirmed,
        confirmedTotalCents: totalCents,
        confirmedBy: currentUserId,
        confirmedAt: now,
        note: note,
      ),
      dispatch: service.dispatch.copyWith(lastReason: ''),
      updatedAt: now,
    );
    _appendEvent(serviceId, ServiceEventName.confirmHeavyService,
        ServiceStatus.needsManual, ServiceStatus.pendingDispatch, currentUserId,
        UserRole.admin);
    _emitServices();
    _scheduleDispatch(serviceId);
    return null;
  }

  /// Walks the service through the real state machine on a compressed clock, so
  /// a reviewer sees the whole flow in about a minute instead of forty.
  ///
  /// [preferredDriverId] — the truck picked on the map — goes first when it
  /// can take the job, exactly as `dispatchNext` does it.
  void _scheduleDispatch(String serviceId, {String? preferredDriverId}) {
    _after(dispatchDelay, () {
      final service = _services[serviceId];
      if (service == null || service.status != ServiceStatus.pendingDispatch) return;

      final candidate = _availableDriver(
            preferredDriverId,
            service.truckTypeRequired,
          ) ??
          _nearestIdleDriver(
            service.pickup.geo,
            service.truckTypeRequired,
          );
      if (candidate == null) {
        _transition(serviceId, ServiceStatus.needsManual,
            ServiceEventName.noDriversFound, 'system', UserRole.unknown);
        return;
      }

      _commitAssignment(
        serviceId: serviceId,
        driver: candidate,
        event: ServiceEventName.acceptService,
        actorRole: UserRole.driver,
        actorId: candidate.id,
      );
    });
  }

  /// Puts [driver] on the job and starts them moving, the one way it happens.
  ///
  /// Shared by the cascade and by a dispatcher assigning by hand: two copies of
  /// this drifted apart is how a manually assigned job ends up without a
  /// tracking document and a customer watches an empty map.
  void _commitAssignment({
    required String serviceId,
    required Driver driver,
    required ServiceEventName event,
    required UserRole actorRole,
    required String actorId,
  }) {
    final service = _services[serviceId];
    if (service == null) return;

    final truck = _trucks[driver.assignedTruckId ?? ''];
    final live = _live[driver.id];
    final etaSeconds = live == null
        ? 600
        : (live.position.distanceKmTo(service.pickup.geo) / 28 * 3600).round();

    _services[serviceId] = service.copyWith(
      status: ServiceStatus.accepted,
      driverId: driver.id,
      driverName: driver.name,
      driverPhone: driver.phone,
      driverPhotoUrl: driver.photoUrl,
      driverRating: driver.rating,
      truckId: truck?.id,
      truckPlate: truck?.displayPlate ?? '',
      truckLabel: truck?.displayName ?? '',
      assignedAt: _now(),
      assignmentMode: actorRole == UserRole.driver
          ? AssignmentMode.auto
          : AssignmentMode.manual,
      timeline: service.timeline.copyWith(
        dispatchedAt: _now(),
        acceptedAt: _now(),
      ),
    );
    _drivers[driver.id] = driver.copyWith(currentServiceId: serviceId);
    // The cascade's offer, accepted. A job the office assigns by hand has no
    // offer, on the real backend as here.
    if (actorRole == UserRole.driver) {
      final earnings = _takeHome(service);
      _offers['$serviceId/${driver.id}'] = Offer(
        serviceId: serviceId,
        driverId: driver.id,
        state: OfferState.accepted,
        serviceCode: service.code,
        pickupAddress: service.pickup.address,
        dropoffAddress: service.dropoff?.address ?? '',
        pickupGeo: service.pickup.geo,
        dropoffGeo: service.dropoff?.geo,
        truckType: service.truckTypeRequired,
        paymentMethod: service.payment.method,
        grossCents: earnings.gross,
        netEarningsCents: earnings.net,
        sentAt: _now(),
        respondedAt: _now(),
      );
    }
    if (live != null) {
      _live[driver.id] = live.copyWith(
        state: DriverLiveState.onService,
        serviceId: serviceId,
      );
    }
    _tracking[serviceId] = ServiceTracking(
      serviceId: serviceId,
      position: live?.position ?? service.pickup.geo,
      driverId: driver.id,
      etaSeconds: etaSeconds,
      updatedAt: _now(),
    );

    _appendEvent(serviceId, event, service.status, ServiceStatus.accepted,
        actorId, actorRole);
    _emitServices();
    _emitDrivers();
    _emitLive();
    _trackingController.add(serviceId);

    _driveToward(serviceId, service.pickup.geo, onArrive: () {
      _transition(serviceId, ServiceStatus.arrived,
          ServiceEventName.markArrived, driver.id, UserRole.driver);
    });
  }

  /// A dispatcher hands the job to a chofer. Returns the refusal, or null.
  ///
  /// Mirrors `assignServiceManually`: the chofer has to be able to take it, and
  /// the service has to still be waiting for one. A dispatcher acting on a list
  /// that is a few seconds stale must be told no, not quietly given a chofer
  /// who is already towing something else.
  String? assignServiceManually({
    required String serviceId,
    required String driverId,
  }) {
    final service = _services[serviceId];
    if (service == null) return 'Este servicio ya no existe.';
    if (!service.status.isAwaitingDriver) {
      return 'Este servicio ya no está esperando chofer.';
    }
    if (service.awaitsOperator) {
      return 'Confirma primero la disponibilidad y el precio con el cliente.';
    }

    final driver = _drivers[driverId];
    if (driver == null) return 'Chofer no encontrado.';
    if (!driver.status.canWork) return 'Ese chofer no está activo.';
    if (driver.isBusy) return 'Ese chofer ya tiene un servicio.';
    if (!driver.truckType.canServe(service.truckTypeRequired)) {
      return 'Ese chofer no tiene una grúa de '
          '${service.truckTypeRequired.label}.';
    }

    _commitAssignment(
      serviceId: serviceId,
      driver: driver,
      event: ServiceEventName.assignServiceManually,
      actorRole: UserRole.admin,
      actorId: currentUserId,
    );
    return null;
  }

  /// Glides the tracked position toward a target, emitting updates the way the
  /// RTDB mirror would.
  void _driveToward(String serviceId, LatLng target, {required VoidCallback onArrive}) {
    const steps = 12;
    var step = 0;
    final start = _tracking[serviceId]?.position ?? target;

    final timer = Timer.periodic(driveStep, (t) {
      step++;
      final service = _services[serviceId];
      if (service == null || service.isTerminal) {
        t.cancel();
        return;
      }
      final progress = step / steps;
      final position = start.lerp(target, progress.clamp(0.0, 1.0));
      final remainingMeters = position.distanceTo(target).round();

      _tracking[serviceId] = (_tracking[serviceId] ??
              ServiceTracking(serviceId: serviceId, position: position))
          .copyWith(
        position: position,
        heading: start.bearingTo(target),
        speedKmh: 34,
        remainingMeters: remainingMeters,
        etaSeconds: (remainingMeters / 1000 / 28 * 3600).round(),
        updatedAt: _now(),
      );
      final driverId = service.driverId;
      if (driverId != null) {
        final live = _live[driverId];
        if (live != null) {
          _live[driverId] = live.copyWith(
            lat: position.latitude,
            lng: position.longitude,
            heading: start.bearingTo(target),
            updatedAt: _now().millisecondsSinceEpoch,
          );
        }
      }
      _trackingController.add(serviceId);
      _emitLive();

      if (step >= steps) {
        t.cancel();
        onArrive();
      }
    });
    _timers.add(timer);
  }

  bool _canTake(Driver d, TruckType type) {
    final live = _live[d.id];
    return d.status.canWork &&
        d.isOnline &&
        !d.isBusy &&
        // Capable, not identical — the same rule the real cascade uses.
        d.truckType.canServe(type) &&
        live != null &&
        live.isOnline;
  }

  /// [driverId], if that chofer can take a job of [type] right now.
  Driver? _availableDriver(String? driverId, TruckType type) {
    final driver = driverId == null ? null : _drivers[driverId];
    return driver != null && _canTake(driver, type) ? driver : null;
  }

  Driver? _nearestIdleDriver(LatLng pickup, TruckType type) {
    final candidates = _drivers.values.where((d) => _canTake(d, type)).toList();

    if (candidates.isEmpty) return null;
    candidates.sort((a, b) {
      // The right truck before the bigger one, the same tie-break the real
      // cascade applies as a score penalty.
      final exact = (a.truckType == type ? 0 : 1) - (b.truckType == type ? 0 : 1);
      if (exact != 0) return exact;
      final da = _live[a.id]!.position.distanceTo(pickup);
      final db = _live[b.id]!.position.distanceTo(pickup);
      return da.compareTo(db);
    });
    return candidates.first;
  }

  /// Files the chofer's proof photos on the service, as `startService` and
  /// `completeService` patch `pickupPhotoPaths` / `dropoffPhotoPaths`.
  void recordProofPhotos(
    String serviceId,
    ServicePhotoStage stage,
    List<String> paths,
  ) {
    final service = _services[serviceId];
    if (service == null) return;
    _services[serviceId] = switch (stage) {
      ServicePhotoStage.pickup => service.copyWith(pickupPhotoPaths: paths),
      ServicePhotoStage.dropoff => service.copyWith(dropoffPhotoPaths: paths),
    };
  }

  /// Applies a status change the way `applyTransition` does server-side.
  Result<void> transition(
    String serviceId,
    ServiceStatus to,
    ServiceEventName event,
    String actorId,
    UserRole actorRole,
  ) {
    final service = _services[serviceId];
    if (service == null) {
      return const Err(Failure(FailureCode.notFound));
    }
    _transition(serviceId, to, event, actorId, actorRole);
    return const Ok(null);
  }

  void _transition(
    String serviceId,
    ServiceStatus to,
    ServiceEventName event,
    String actorId,
    UserRole actorRole,
  ) {
    final service = _services[serviceId];
    if (service == null) return;
    final now = _now();
    final from = service.status;

    var timeline = service.timeline;
    timeline = switch (to) {
      ServiceStatus.arrived => timeline.copyWith(arrivedAt: now),
      ServiceStatus.inProgress => timeline.copyWith(startedAt: now),
      ServiceStatus.completed => timeline.copyWith(completedAt: now),
      ServiceStatus.closed => timeline.copyWith(closedAt: now),
      ServiceStatus.cancelled => timeline.copyWith(cancelledAt: now),
      _ => timeline,
    };

    var updated = service.copyWith(status: to, timeline: timeline, updatedAt: now);

    if (to == ServiceStatus.completed) {
      updated = updated.copyWith(
        finalQuote: service.quote,
        payment: service.payment.copyWith(
          status: service.isInsurerJob
              ? PaymentStatus.toInvoice
              : PaymentStatus.cashPending,
        ),
      );
      _recordEarnings(updated);
    }

    if (to.isTerminal) {
      final driverId = service.driverId;
      if (driverId != null) {
        final driver = _drivers[driverId];
        if (driver != null) {
          _drivers[driverId] = driver.copyWith(currentServiceId: null);
        }
        final live = _live[driverId];
        if (live != null) {
          _live[driverId] =
              live.copyWith(state: DriverLiveState.idle, serviceId: null);
        }
      }
      final client = _users[service.clientId];
      if (client != null) {
        _users[service.clientId] = client.copyWith(activeServiceId: null);
      }
    }

    _services[serviceId] = updated;
    _appendEvent(serviceId, event, from, to, actorId, actorRole);
    _emitServices();
    _emitDrivers();
    _emitLive();

    // Nothing to collect on an insurer's tow: it closes as soon as it is done.
    if (to == ServiceStatus.completed && updated.isInsurerJob) {
      _transition(serviceId, ServiceStatus.closed, ServiceEventName.closeService,
          'system', UserRole.unknown);
      return;
    }

    // On start, run the second leg to the destination so the client's map keeps
    // moving all the way through the tow.
    if (to == ServiceStatus.inProgress) {
      final dropoff = updated.dropoff?.geo;
      if (dropoff != null) {
        _driveToward(serviceId, dropoff, onArrive: () {});
      }
    }
  }

  // -------------------------------------------------------------------------
  // Payments — mirrors functions/src/callables/payments.ts
  // -------------------------------------------------------------------------

  final List<CashSettlement> _settlements = [];
  var _settlementCounter = 0;

  /// Newest first.
  List<CashSettlement> cashSettlements({String? driverId}) => List.unmodifiable(
        _settlements.reversed.where((s) => driverId == null || s.driverId == driverId),
      );

  /// The cash jobs [driverId] collected that no corte counted yet.
  List<Service> uncountedCash(String driverId) => [
        for (final s in _services.values)
          if (s.driverId == driverId &&
              s.payment.isCash &&
              s.payment.status == PaymentStatus.cashCollected &&
              s.payment.cashSettlementId == null &&
              s.payment.weeklySettlementId == null)
            s,
      ];

  /// "Cobrado en efectivo": the job is paid, and the chofer now holds the cash.
  Result<void> confirmCashCollected(String serviceId, String driverId, int amountCents) {
    final service = _services[serviceId];
    if (service == null) return const Err(Failure(FailureCode.notFound));
    final now = _now();
    _services[serviceId] = service.copyWith(
      payment: service.payment.copyWith(
        status: PaymentStatus.cashCollected,
        capturedCents: amountCents,
        cashCollectedAt: now,
      ),
    );
    final driver = _drivers[driverId];
    if (driver != null) {
      _drivers[driverId] =
          driver.copyWith(cashOnHandCents: driver.cashOnHandCents + amountCents);
    }
    _transition(serviceId, ServiceStatus.closed,
        ServiceEventName.confirmCashCollected, driverId, UserRole.driver);
    return const Ok(null);
  }

  // -------------------------------------------------------------------------
  // Monthly insurer invoices — mirrors functions/src/callables/insurerInvoices.ts
  // -------------------------------------------------------------------------

  final Map<String, InsurerInvoice> _insurerInvoices = {};
  var _insurerInvoiceCounter = 0;
  FiscalIssuer _fiscalIssuer = const FiscalIssuer();
  final Map<String, NcfSequence> _ncfSequences = {};

  /// Every NCF issued, by registry key, with the invoice that took it.
  final Map<String, String> _ncfRegistry = {};

  FiscalIssuer get fiscalIssuer => _fiscalIssuer;

  NcfSequence ncfSequence(String prefix) =>
      _ncfSequences[prefix] ?? NcfSequence.test(prefix);

  /// Newest first.
  List<InsurerInvoice> insurerInvoices({String? insurerId}) {
    final all = _insurerInvoices.values
        .where((i) => insurerId == null || i.insurerId == insurerId)
        .toList()
      ..sort((a, b) => b.createdAt!.compareTo(a.createdAt!));
    return List.unmodifiable(all);
  }

  InsurerInvoice? insurerInvoice(String id) => _insurerInvoices[id];

  static DateTime? _finishedAt(Service s) => s.status == ServiceStatus.cancelled
      ? s.timeline.cancelledAt
      : s.timeline.completedAt ?? s.timeline.closedAt;

  /// Insurer services waiting for an invoice, oldest first.
  List<Service> servicesToInvoice({String? insurerId}) {
    final list = [
      for (final s in _services.values)
        if (s.isInsurerJob &&
            s.payment.status == PaymentStatus.toInvoice &&
            (insurerId == null || s.insurerId == insurerId))
          s,
    ]..sort((a, b) {
        final at = _finishedAt(a) ?? _now();
        final bt = _finishedAt(b) ?? _now();
        return at.compareTo(bt);
      });
    return List.unmodifiable(list);
  }

  static const FailureCode _invalidInvoiceInput = FailureCode.invalidInput;

  Result<InvoiceRun> generateInsurerInvoices({
    required String actorId,
    String? insurerId,
    String? periodKey,
  }) {
    final now = _now().toUtc();
    if (periodKey != null && !InvoicePeriod.isKey(periodKey)) {
      return const Err(Failure(_invalidInvoiceInput, message: 'Mes inválido.'));
    }
    final period =
        periodKey == null ? InvoicePeriod.of(now).previous : InvoicePeriod.parse(periodKey);
    if (period.start.isAfter(now)) {
      return const Err(
        Failure(_invalidInvoiceInput, message: 'No se puede facturar un mes que no ha empezado.'),
      );
    }
    if (insurerId != null && !_insurers.containsKey(insurerId)) {
      return const Err(Failure(FailureCode.notFound, message: 'No encontramos esa aseguradora.'));
    }
    final cutoff = period.end.isBefore(now) ? period.end : now;
    final companies = insurerId == null ? (_insurers.keys.toList()..sort()) : [insurerId];

    final created = <IssuedInvoiceRef>[];
    final failed = <({String insurerId, String message})>[];
    outer:
    for (final id in companies) {
      for (var round = 0; round < 20; round++) {
        switch (_issueInvoice(id, period, cutoff, actorId, now)) {
          case Err(:final failure):
            if (insurerId != null) {
              _emitServices();
              return Err(failure);
            }
            failed.add((insurerId: id, message: failure.userMessage));
            if (failure.code == FailureCode.ncfUnavailable) break outer;
          case Ok(:final value?):
            created.add(value.$1);
            if (value.$2 > 0) continue;
          case Ok():
        }
        break;
      }
    }
    _emitServices();
    return Ok(InvoiceRun(periodKey: period.key, created: created, failed: failed));
  }

  /// One invoice for [insurerId], with how many services it left over; null
  /// when nothing was waiting.
  Result<(IssuedInvoiceRef, int)?> _issueInvoice(
    String insurerId,
    InvoicePeriod period,
    DateTime cutoff,
    String actorId,
    DateTime now,
  ) {
    final insurer = _insurers[insurerId]!;
    final waiting = servicesToInvoice(insurerId: insurerId);
    final byId = {for (final s in waiting) s.id: s};
    final draft = InsurerInvoiceMath.draft(
      [
        for (final s in waiting)
          InvoiceableService(
            serviceId: s.id,
            status: s.status,
            finishedAt: _finishedAt(s),
            subtotalCents: s.billedSubtotalCents,
            feeCents: s.cancellation?.feeCents ?? 0,
          ),
      ],
      cutoff: cutoff,
    );
    if (draft == null) return const Ok(null);

    final sequence = ncfSequence(Ncf.creditoFiscal);
    final problem = Ncf.problem(sequence, now);
    if (problem != null) {
      return Err(Failure(FailureCode.ncfUnavailable, message: problem));
    }
    final ncf = Ncf.format(sequence.prefix, sequence.nextNumber);
    final key = Ncf.registryKey(ncf, isTest: sequence.isTest);
    if (_ncfRegistry.containsKey(key)) {
      return Err(
        Failure(
          FailureCode.ncfUnavailable,
          message: 'El NCF $ncf ya fue emitido. Revisa el número siguiente de la secuencia.',
        ),
      );
    }

    final id = 'fac-${++_insurerInvoiceCounter}';
    final lines = [
      for (final (i, serviceId) in draft.serviceIds.indexed)
        _invoiceLine(byId[serviceId]!, draft.kinds[i], draft.amounts[i]),
    ];
    _insurerInvoices[id] = InsurerInvoice(
      id: id,
      insurerId: insurerId,
      insurerName: insurer.name,
      insurerRnc: insurer.rnc,
      billingEmail: insurer.billingEmail,
      periodKey: period.key,
      periodLabel: period.label,
      periodStart: period.start,
      periodEnd: period.end,
      cutoff: cutoff,
      ncf: ncf,
      isTestNcf: sequence.isTest,
      ncfExpiresOn: sequence.expiresOn,
      issuer: InvoiceIssuer(
        name: _fiscalIssuer.name,
        rnc: _fiscalIssuer.rnc,
        address: _fiscalIssuer.address,
        phone: _fiscalIssuer.phone,
        email: _fiscalIssuer.email,
      ),
      lines: List.unmodifiable(lines),
      tariffTable: _tariffSnapshot(insurerId),
      towCount: draft.towCount,
      cancellationCount: draft.cancellationCount,
      subtotalCents: draft.totals.subtotalCents,
      itbisCents: draft.totals.itbisCents,
      totalCents: draft.totals.totalCents,
      status: InsurerInvoiceStatus.issued,
      paymentTermsDays: _fiscalIssuer.paymentTermsDays,
      dueAt: InsurerInvoiceMath.dueDate(now, _fiscalIssuer.paymentTermsDays),
      issuedAt: now,
      createdAt: now.add(Duration(microseconds: _insurerInvoiceCounter)),
    );
    _ncfRegistry[key] = id;
    _ncfSequences[sequence.prefix] = NcfSequence(
      prefix: sequence.prefix,
      nextNumber: sequence.nextNumber + 1,
      lastNumber: sequence.lastNumber,
      expiresOn: sequence.expiresOn,
      isTest: sequence.isTest,
      lastIssued: ncf,
      lastIssuedAt: now,
      updatedAt: now,
    );
    for (final serviceId in draft.serviceIds) {
      final s = _services[serviceId]!;
      _services[serviceId] = s.copyWith(
        invoiceId: id,
        payment: s.payment.copyWith(status: PaymentStatus.invoiced),
      );
    }
    return Ok((
      IssuedInvoiceRef(
        invoiceId: id,
        insurerId: insurerId,
        ncf: ncf,
        isTestNcf: sequence.isTest,
        totalCents: draft.totals.totalCents,
        lineCount: lines.length,
      ),
      draft.leftover,
    ));
  }

  /// Every class's zone prices for [insurerId], as `tariffSnapshot` keeps them.
  List<InvoiceTariffRow> _tariffSnapshot(String insurerId) => [
        for (final vehicleClass in VehicleClass.priced)
          if (zoneTableFor(insurerId, vehicleClass) case (final rules, final tariff))
            for (final rule in [...rules]..sort((a, b) => a.zoneMinKm.compareTo(b.zoneMinKm)))
              InvoiceTariffRow(
                vehicleClass: vehicleClass,
                zoneMinKm: rule.zoneMinKm,
                zoneMaxKm: rule.zoneMaxKm,
                baseCents: rule.baseCents,
                extraKmCents: rule.extraKmCents,
                source: tariff.wire,
              ),
      ];

  InsurerInvoiceLine _invoiceLine(Service s, InsurerInvoiceLineKind kind, int amount) {
    final billing = s.billing;
    final makeModel =
        [s.vehicle.make, s.vehicle.model].where((p) => p.isNotEmpty).join(' ');
    return InsurerInvoiceLine(
      serviceId: s.id,
      kind: kind,
      amountCents: amount,
      serviceCode: s.code,
      finishedAt: _finishedAt(s),
      claimNumber: s.insurance?.claimNumber ?? '',
      policyNumber: s.insurance?.policyNumber ?? '',
      insuredName: s.insurance?.insuredName ?? '',
      plate: s.vehicle.plate,
      vehicle: makeModel.isEmpty ? s.vehicle.type.label : makeModel,
      pickupAddress: s.pickup.address,
      dropoffAddress: s.dropoff?.address ?? '',
      distanceKm: billing?.distanceKm ?? s.quote.distanceKm,
      zoneLabel: billing?.zoneLabel ?? '',
      vehicleClass: billing == null || billing.vehicleClass == VehicleClass.unknown
          ? ''
          : billing.vehicleClass.label,
      tariff: billing?.tariff ?? '',
      baseCents: kind == InsurerInvoiceLineKind.tow ? billing?.baseCents ?? 0 : 0,
      extraKm: kind == InsurerInvoiceLineKind.tow ? billing?.extraKm ?? 0 : 0,
      extraCents: kind == InsurerInvoiceLineKind.tow ? billing?.extraCents ?? 0 : 0,
    );
  }

  InsurerInvoice _withStatus(
    InsurerInvoice i, {
    required InsurerInvoiceStatus status,
    String? paymentReference,
    String? note,
    String? voidReason,
    DateTime? paidAt,
    DateTime? voidedAt,
  }) =>
      InsurerInvoice(
        id: i.id,
        insurerId: i.insurerId,
        ncf: i.ncf,
        insurerName: i.insurerName,
        insurerRnc: i.insurerRnc,
        billingEmail: i.billingEmail,
        periodKey: i.periodKey,
        periodLabel: i.periodLabel,
        periodStart: i.periodStart,
        periodEnd: i.periodEnd,
        cutoff: i.cutoff,
        ncfType: i.ncfType,
        isTestNcf: i.isTestNcf,
        ncfExpiresOn: i.ncfExpiresOn,
        issuer: i.issuer,
        lines: i.lines,
        tariffTable: i.tariffTable,
        towCount: i.towCount,
        cancellationCount: i.cancellationCount,
        subtotalCents: i.subtotalCents,
        itbisCents: i.itbisCents,
        totalCents: i.totalCents,
        status: status,
        paymentTermsDays: i.paymentTermsDays,
        dueAt: i.dueAt,
        paymentReference: paymentReference ?? i.paymentReference,
        note: note ?? i.note,
        voidReason: voidReason ?? i.voidReason,
        issuedAt: i.issuedAt,
        paidAt: paidAt ?? i.paidAt,
        voidedAt: voidedAt ?? i.voidedAt,
        createdAt: i.createdAt,
      );

  Result<void> markInsurerInvoicePaid(
    String invoiceId, {
    required String reference,
    String note = '',
  }) {
    if (reference.trim().length < 3) {
      return const Err(
        Failure(_invalidInvoiceInput, message: 'Escribe el número de la transferencia.'),
      );
    }
    final invoice = _insurerInvoices[invoiceId];
    if (invoice == null) {
      return const Err(Failure(FailureCode.notFound, message: 'No encontramos esa factura.'));
    }
    if (!invoice.isIssued) {
      return const Err(
        Failure(
          FailureCode.invalidTransition,
          message: 'Solo se puede cobrar una factura pendiente.',
        ),
      );
    }
    _insurerInvoices[invoiceId] = _withStatus(
      invoice,
      status: InsurerInvoiceStatus.paid,
      paymentReference: reference.trim(),
      note: note.trim(),
      paidAt: _now().toUtc(),
    );
    _emitServices();
    return const Ok(null);
  }

  Result<void> voidInsurerInvoice(String invoiceId, {required String reason}) {
    if (reason.trim().length < 3) {
      return const Err(
        Failure(_invalidInvoiceInput, message: 'Escribe por qué se anula la factura.'),
      );
    }
    final invoice = _insurerInvoices[invoiceId];
    if (invoice == null) {
      return const Err(Failure(FailureCode.notFound, message: 'No encontramos esa factura.'));
    }
    if (!invoice.isIssued) {
      return Err(
        Failure(
          FailureCode.invalidTransition,
          message: invoice.isPaid
              ? 'Una factura cobrada no se anula: emite una nota de crédito.'
              : 'Esta factura ya está anulada.',
        ),
      );
    }
    _insurerInvoices[invoiceId] = _withStatus(
      invoice,
      status: InsurerInvoiceStatus.voided,
      voidReason: reason.trim(),
      voidedAt: _now().toUtc(),
    );
    for (final entry in _services.entries.toList()) {
      final s = entry.value;
      if (s.invoiceId != invoiceId) continue;
      _services[entry.key] = s.copyWith(
        invoiceId: null,
        payment: s.payment.copyWith(status: PaymentStatus.toInvoice),
      );
    }
    _emitServices();
    return const Ok(null);
  }

  Result<void> saveFiscalIssuer(FiscalIssuer issuer) {
    if (issuer.name.trim().length < 2) {
      return const Err(Failure(_invalidInvoiceInput, message: 'Escribe la razón social.'));
    }
    final rnc = DoValidators.digits(issuer.rnc);
    if (rnc.isNotEmpty && DoValidators.companyRnc(rnc) != null) {
      return const Err(Failure(_invalidInvoiceInput, message: 'Ese RNC no es válido.'));
    }
    if (issuer.paymentTermsDays < 0 || issuer.paymentTermsDays > 180) {
      return const Err(
        Failure(_invalidInvoiceInput, message: 'Los días de crédito van de 0 a 180.'),
      );
    }
    _fiscalIssuer = FiscalIssuer(
      name: issuer.name.trim(),
      rnc: rnc,
      address: issuer.address.trim(),
      phone: issuer.phone.trim(),
      email: issuer.email.trim(),
      paymentTermsDays: issuer.paymentTermsDays,
      updatedAt: _now().toUtc(),
    );
    _emitServices();
    return const Ok(null);
  }

  Result<String> saveNcfSequence(NcfSequence sequence) {
    Err<String> invalid(String message) =>
        Err(Failure(_invalidInvoiceInput, message: message));
    if (!Ncf.prefixes.contains(sequence.prefix)) return invalid('Tipo de comprobante inválido.');
    if (sequence.nextNumber < 1 || sequence.lastNumber > NcfSequence.maxNumber) {
      return invalid('Los números van de 1 a 99,999,999.');
    }
    if (sequence.lastNumber < sequence.nextNumber) {
      return invalid('El número final debe ser mayor o igual al inicial.');
    }
    final expiresOn = sequence.expiresOn;
    if (expiresOn != null && !Ncf.isIsoDay(expiresOn)) return invalid('Fecha inválida');
    if (!sequence.isTest && expiresOn == null) {
      return invalid('Una secuencia real necesita su fecha de vencimiento.');
    }
    if (expiresOn != null && !Ncf.expiryInstant(expiresOn)!.isAfter(_now().toUtc())) {
      return invalid('Esa fecha de vencimiento ya pasó.');
    }
    final first = Ncf.format(sequence.prefix, sequence.nextNumber);
    if (_ncfRegistry.containsKey(Ncf.registryKey(first, isTest: sequence.isTest))) {
      return Err(
        Failure(
          FailureCode.ncfUnavailable,
          message: 'El NCF $first ya fue emitido${sequence.isTest ? ' como prueba' : ''}. '
              'La secuencia debe empezar en un número sin usar.',
        ),
      );
    }
    final current = ncfSequence(sequence.prefix);
    _ncfSequences[sequence.prefix] = NcfSequence(
      prefix: sequence.prefix,
      nextNumber: sequence.nextNumber,
      lastNumber: sequence.lastNumber,
      expiresOn: expiresOn,
      isTest: sequence.isTest,
      lastIssued: current.lastIssued,
      lastIssuedAt: current.lastIssuedAt,
      updatedAt: _now().toUtc(),
    );
    _emitServices();
    return Ok(first);
  }

  // -------------------------------------------------------------------------
  // Weekly cortes — mirrors functions/src/callables/settlements.ts
  // -------------------------------------------------------------------------

  final Map<String, DriverSettlement> _driverSettlements = {};
  final Map<String, List<String>> _settlementEntryIds = {};
  var _driverSettlementCounter = 0;

  /// Newest first.
  List<DriverSettlement> driverSettlements({String? driverId}) {
    final all = _driverSettlements.values
        .where((s) => driverId == null || s.driverId == driverId)
        .toList()
      ..sort((a, b) => b.createdAt!.compareTo(a.createdAt!));
    return List.unmodifiable(all);
  }

  DriverSettlement? driverSettlement(String id) => _driverSettlements[id];

  /// Cortes for everything finished so far, for [driverId] or every chofer.
  Result<List<String>> generateDriverSettlements({
    required String actorId,
    String? driverId,
  }) {
    final now = _now().toUtc();
    final ids = <String>[];
    final drivers = driverId == null
        ? _drivers.keys.toList()
        : [if (_drivers.containsKey(driverId)) driverId];
    if (driverId != null && drivers.isEmpty) {
      return const Err(Failure(FailureCode.notFound));
    }

    for (final id in drivers) {
      final startAt = settlementsStartAt;
      final entries = [
        for (final e in _earningEntries[id] ?? const <EarningEntry>[])
          if (!e.settled &&
              e.completedAt != null &&
              (startAt == null || !e.completedAt!.isBefore(startAt)))
            e,
      ];
      final counted = {
        for (final e in entries)
          if (_services[e.serviceId]?.payment.cashSettlementId != null)
            e.serviceId,
      };
      final draft = SettlementMath.draft(
        entries,
        cutoff: now,
        startAt: startAt,
        countedInCashCorte: counted,
      );
      // Card jobs have nothing to settle: retired, so they stop coming back.
      final ignored = draft?.ignoredServiceIds ??
          [
            for (final e in entries)
              if (e.method != PaymentMethod.insurer &&
                  e.method != PaymentMethod.cash &&
                  !e.completedAt!.isAfter(now))
                e.serviceId,
          ];
      _markEntries(id, ignored, null);
      if (draft == null ||
          (draft.lines.isEmpty && draft.retiredServiceIds.isEmpty)) {
        continue;
      }

      _driverSettlementCounter++;
      final settlementId = 'corte-$_driverSettlementCounter';
      final driver = _drivers[id]!;
      final nothingToPay = draft.direction == SettlementDirection.none;
      _driverSettlements[settlementId] = DriverSettlement(
        id: settlementId,
        driverId: id,
        driverName: driver.name,
        truckPlate: _trucks[driver.assignedTruckId ?? '']?.displayPlate ?? '',
        periodStart: draft.periodStart,
        periodEnd: draft.periodEnd,
        lines: draft.lines,
        insuranceOwedCents: draft.insuranceOwedCents,
        commissionOwedCents: draft.commissionOwedCents,
        finalBalanceCents: draft.finalBalanceCents,
        direction: draft.direction,
        status: nothingToPay ? SettlementStatus.settled : SettlementStatus.pending,
        payBy: SettlementMath.payBy(now),
        settledAt: nothingToPay ? now : null,
        createdAt: now.add(Duration(microseconds: _driverSettlementCounter)),
      );

      final taken = [
        ...draft.lines.map((l) => l.serviceId),
        ...draft.retiredServiceIds,
      ];
      _settlementEntryIds[settlementId] = taken;
      _markEntries(id, taken, settlementId);
      for (final line in draft.lines) {
        final s = _services[line.serviceId];
        if (line.kind != SettlementLineKind.cash || s == null) continue;
        _services[line.serviceId] = s.copyWith(
          payment: s.payment.copyWith(weeklySettlementId: settlementId),
        );
      }
      if (nothingToPay) _clearCommission(id, draft.commissionOwedCents);
      ids.add(settlementId);
    }

    _emitServices();
    _emitDrivers();
    return Ok(ids);
  }

  /// Closes a pending corte, clearing the commission it netted.
  Result<void> settleDriverSettlement(
    String settlementId, {
    required String reference,
    String note = '',
  }) {
    final corte = _driverSettlements[settlementId];
    if (corte == null) return const Err(Failure(FailureCode.notFound));
    if (!corte.isPending) {
      return const Err(
        Failure(FailureCode.invalidTransition, message: 'Este corte ya no está pendiente.'),
      );
    }
    if (corte.finalBalanceCents != 0 && reference.trim().length < 3) {
      return const Err(
        Failure(
          FailureCode.invalidInput,
          message: 'Escribe el número de la transferencia o del depósito.',
        ),
      );
    }
    _driverSettlements[settlementId] = DriverSettlement(
      id: corte.id,
      driverId: corte.driverId,
      driverName: corte.driverName,
      truckPlate: corte.truckPlate,
      periodStart: corte.periodStart,
      periodEnd: corte.periodEnd,
      lines: corte.lines,
      insuranceOwedCents: corte.insuranceOwedCents,
      commissionOwedCents: corte.commissionOwedCents,
      finalBalanceCents: corte.finalBalanceCents,
      direction: corte.direction,
      status: SettlementStatus.settled,
      payBy: corte.payBy,
      reference: reference.trim(),
      note: note.trim(),
      settledAt: _now().toUtc(),
      createdAt: corte.createdAt,
    );
    _clearCommission(corte.driverId, corte.commissionOwedCents);
    _emitServices();
    _emitDrivers();
    return const Ok(null);
  }

  /// Cancels a pending corte and gives its jobs back.
  Result<void> voidDriverSettlement(String settlementId, {required String reason}) {
    final corte = _driverSettlements[settlementId];
    if (corte == null) return const Err(Failure(FailureCode.notFound));
    if (!corte.isPending) {
      return const Err(
        Failure(
          FailureCode.invalidTransition,
          message: 'Solo se puede anular un corte pendiente.',
        ),
      );
    }
    if (reason.trim().length < 3) {
      return const Err(
        Failure(FailureCode.invalidInput, message: 'Escribe por qué se anula el corte.'),
      );
    }
    _driverSettlements[settlementId] = DriverSettlement(
      id: corte.id,
      driverId: corte.driverId,
      driverName: corte.driverName,
      truckPlate: corte.truckPlate,
      periodStart: corte.periodStart,
      periodEnd: corte.periodEnd,
      lines: corte.lines,
      insuranceOwedCents: corte.insuranceOwedCents,
      commissionOwedCents: corte.commissionOwedCents,
      finalBalanceCents: corte.finalBalanceCents,
      direction: corte.direction,
      status: SettlementStatus.voided,
      payBy: corte.payBy,
      voidReason: reason.trim(),
      createdAt: corte.createdAt,
    );
    final ids = _settlementEntryIds[settlementId] ?? const [];
    for (final line in corte.cashLines) {
      final s = _services[line.serviceId];
      if (s == null || s.payment.weeklySettlementId != settlementId) continue;
      _services[line.serviceId] = s.copyWith(
        payment: s.payment.copyWith(weeklySettlementId: null),
      );
    }
    final entries = _earningEntries[corte.driverId];
    if (entries != null) {
      for (var i = 0; i < entries.length; i++) {
        final e = entries[i];
        if (ids.contains(e.serviceId) && e.settlementId == settlementId) {
          entries[i] = e.copyWith(settled: false, settlementId: null, settledAt: null);
        }
      }
    }
    _emitServices();
    return const Ok(null);
  }

  void _markEntries(String driverId, List<String> serviceIds, String? settlementId) {
    final entries = _earningEntries[driverId];
    if (entries == null) return;
    for (var i = 0; i < entries.length; i++) {
      if (serviceIds.contains(entries[i].serviceId)) {
        entries[i] = entries[i].copyWith(
          settled: true,
          settlementId: settlementId,
          settledAt: _now().toUtc(),
        );
      }
    }
  }

  void _clearCommission(String driverId, int commissionCents) {
    if (commissionCents <= 0) return;
    final driver = _drivers[driverId];
    if (driver != null) {
      _drivers[driverId] = driver.copyWith(
        cashOwedCents: math.max(0, driver.cashOwedCents - commissionCents),
      );
    }
    final summary = _earnings[driverId];
    if (summary != null) {
      _earnings[driverId] = summary.copyWith(
        cashOwedCents: math.max(0, summary.cashOwedCents - commissionCents),
      );
    }
  }

  /// The corte: the office receives the cash [driverId] holds.
  Result<int> settleDriverCash(String driverId, String staffId, {String note = ''}) {
    final driver = _drivers[driverId];
    if (driver == null) return const Err(Failure(FailureCode.notFound));
    final jobs = uncountedCash(driverId);
    if (jobs.isEmpty) {
      return const Err(
        Failure(
          FailureCode.invalidTransition,
          message: 'Este chofer no tiene efectivo por entregar.',
        ),
      );
    }
    final total = jobs.fold(0, (sum, s) => sum + s.payment.capturedCents);
    final id = 'corte-${++_settlementCounter}';
    final now = _now();
    // Their commission is paid with the cash: settled, so Friday's corte does
    // not charge it again.
    final jobIds = {for (final j in jobs) j.id};
    var commission = 0;
    final driverEntries = _earningEntries[driverId];
    if (driverEntries != null) {
      for (var i = 0; i < driverEntries.length; i++) {
        final e = driverEntries[i];
        if (!jobIds.contains(e.serviceId) || e.settled) continue;
        commission += e.commissionCents;
        driverEntries[i] = e.copyWith(settled: true, settledAt: now.toUtc());
      }
    }
    final owedLeft = math.max(0, driver.cashOwedCents - commission);
    for (final job in jobs) {
      _services[job.id] = job.copyWith(
        payment: job.payment.copyWith(cashSettlementId: id, cashSettledAt: now),
      );
    }
    _settlements.add(
      CashSettlement(
        id: id,
        driverId: driverId,
        driverName: driver.name,
        amountCents: total,
        serviceCount: jobs.length,
        note: note,
        settledBy: staffId,
        createdAt: now,
      ),
    );
    _drivers[driverId] = driver.copyWith(
      cashOnHandCents: math.max(0, driver.cashOnHandCents - total),
      cashOwedCents: owedLeft,
      lastCashSettlementAt: now,
    );
    final summary = _earnings[driverId];
    if (summary != null) _earnings[driverId] = summary.copyWith(cashOwedCents: owedLeft);
    _emitServices();
    _emitDrivers();
    return Ok(total);
  }

  void _recordEarnings(Service service) {
    final driverId = service.driverId;
    if (driverId == null) return;
    final (:gross, :net, :commission) = _takeHome(service);

    final entry = EarningEntry(
      serviceId: service.id,
      driverId: driverId,
      serviceCode: service.code,
      grossCents: gross,
      commissionCents: commission,
      netCents: net,
      method: service.payment.method,
      pickupAddress: service.pickup.address,
      dropoffAddress: service.dropoff?.address ?? '',
      completedAt: _now(),
    );

    (_earningEntries[driverId] ??= [])
      ..removeWhere((e) => e.serviceId == service.id)
      ..insert(0, entry);

    final summary = _earnings[driverId];
    if (summary != null) {
      _earnings[driverId] = summary.copyWith(
        todayGrossCents: summary.todayGrossCents + gross,
        todayNetCents: summary.todayNetCents + entry.netCents,
        todayServices: summary.todayServices + 1,
        weekGrossCents: summary.weekGrossCents + gross,
        weekNetCents: summary.weekNetCents + entry.netCents,
        weekServices: summary.weekServices + 1,
        monthGrossCents: summary.monthGrossCents + gross,
        monthNetCents: summary.monthNetCents + entry.netCents,
        monthServices: summary.monthServices + 1,
        cashOwedCents: entry.driverOwesCompany
            ? summary.cashOwedCents + commission
            : summary.cashOwedCents,
        updatedAt: _now(),
      );
    }
  }

  void _appendEvent(
    String serviceId,
    ServiceEventName event,
    ServiceStatus from,
    ServiceStatus to,
    String actorId,
    UserRole actorRole,
  ) {
    (_events[serviceId] ??= []).add(
      ServiceEvent(
        id: 'evt-${_events[serviceId]?.length ?? 0}',
        event: event,
        from: from,
        to: to,
        actorId: actorId,
        actorRole: actorRole,
        at: _now(),
      ),
    );
  }

  void _after(Duration delay, void Function() action) {
    _timers.add(Timer(delay, action));
  }

  void _emitServices() => _servicesController.add(Map.unmodifiable(_services));

  void _emitDrivers() => _driversController.add(Map.unmodifiable(_drivers));

  void _emitTrucks() => _trucksController.add(Map.unmodifiable(_trucks));

  void _emitLive() => _liveController.add(Map.unmodifiable(_live));

  void _emitUsers() => _usersController.add(Map.unmodifiable(_users));

  void dispose() {
    unawaited(_callsController.close());
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
    unawaited(_servicesController.close());
    unawaited(_driversController.close());
    unawaited(_liveController.close());
    unawaited(_trucksController.close());
    unawaited(_appOpenController.close());
    unawaited(_messagesController.close());
    unawaited(_trackingController.close());
    unawaited(_chatRequestsController.close());
    unawaited(_reviewsController.close());
    unawaited(_chatRequestMessagesController.close());
    unawaited(_typingController.close());
  }
}

typedef VoidCallback = void Function();

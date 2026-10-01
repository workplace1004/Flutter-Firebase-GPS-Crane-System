/// Domain enumerations shared by the three apps and mirrored in
/// `functions/src/lib/enums.ts`.
///
/// Every enum here follows the same contract: a `wire` string that is the only
/// thing ever written to Firestore, and a tolerant `fromWire` that resolves an
/// unrecognised value to an `unknown` member instead of throwing. That matters
/// because an app on a customer's phone can be months behind the backend, and a
/// chofer whose app crashes on a new status is a chofer who cannot work.
library;

import 'package:json_annotation/json_annotation.dart';

/// Resolves [wire] against [values], falling back to [fallback].
T _resolve<T>(List<T> values, String? wire, String Function(T) key, T fallback) {
  if (wire == null) return fallback;
  for (final value in values) {
    if (key(value) == wire) return value;
  }
  return fallback;
}

// ---------------------------------------------------------------------------
// Identity
// ---------------------------------------------------------------------------

enum UserRole {
  @JsonValue('client')
  client('client'),
  @JsonValue('driver')
  driver('driver'),
  @JsonValue('admin')
  admin('admin'),
  @JsonValue('ops')
  ops('ops'),

  /// A person of an insurance company. Uses the web panel, fenced to their
  /// own company's tows.
  @JsonValue('insurer')
  insurer('insurer'),
  @JsonValue('unknown')
  unknown('unknown');

  const UserRole(this.wire);

  final String wire;

  static UserRole fromWire(String? wire) =>
      _resolve(UserRole.values, wire, (v) => v.wire, UserRole.unknown);

  bool get isStaff => this == UserRole.admin || this == UserRole.ops;

  bool get isInsurer => this == UserRole.insurer;

  /// Whether this account may sign in to the web panel at all. What it sees
  /// there is a separate question.
  bool get canUsePanel => isStaff || isInsurer;
}

/// What a person can do inside their insurance company.
enum InsurerRole {
  /// Adds and removes the company's people, and sees its invoices.
  @JsonValue('manager')
  manager('manager', 'Administrador'),

  /// Creates and follows the company's tows.
  @JsonValue('operator')
  operator('operator', 'Operador'),

  @JsonValue('unknown')
  unknown('unknown', 'Desconocido');

  const InsurerRole(this.wire, this.label);

  final String wire;
  final String label;

  static InsurerRole fromWire(String? wire) =>
      _resolve(InsurerRole.values, wire, (v) => v.wire, InsurerRole.unknown);

  bool get canManageMembers => this == InsurerRole.manager;
}

/// Whether an insurance company may use the platform.
enum InsurerStatus {
  @JsonValue('active')
  active('active', 'Activa'),

  /// Switched off by the office. Its people cannot sign in or read anything.
  @JsonValue('suspended')
  suspended('suspended', 'Suspendida'),

  @JsonValue('unknown')
  unknown('unknown', 'Desconocido');

  const InsurerStatus(this.wire, this.label);

  final String wire;
  final String label;

  static InsurerStatus fromWire(String? wire) =>
      _resolve(InsurerStatus.values, wire, (v) => v.wire, InsurerStatus.unknown);

  bool get isActive => this == InsurerStatus.active;
}

/// Lifecycle of a chofer's account, controlled entirely from the admin panel.
enum DriverStatus {
  /// Created but not yet cleared to work — usually missing documents.
  @JsonValue('inactive')
  inactive('inactive'),

  /// Cleared to go online and receive offers.
  @JsonValue('active')
  active('active'),

  /// Blocked by an admin. Cannot log in to work.
  @JsonValue('suspended')
  suspended('suspended'),

  @JsonValue('unknown')
  unknown('unknown');

  const DriverStatus(this.wire);

  final String wire;

  static DriverStatus fromWire(String? wire) =>
      _resolve(DriverStatus.values, wire, (v) => v.wire, DriverStatus.unknown);

  bool get canWork => this == DriverStatus.active;
}

/// What the chofer is doing right now, as published to `/live/{driverId}`.
enum DriverLiveState {
  /// Online and dispatchable.
  @JsonValue('idle')
  idle('idle'),

  /// Online but already committed to a service.
  @JsonValue('on_service')
  onService('on_service'),

  @JsonValue('unknown')
  unknown('unknown');

  const DriverLiveState(this.wire);

  final String wire;

  static DriverLiveState fromWire(String? wire) =>
      _resolve(DriverLiveState.values, wire, (v) => v.wire, DriverLiveState.unknown);
}

// ---------------------------------------------------------------------------
// Fleet
// ---------------------------------------------------------------------------

/// The kind of grúa required. This is the field dispatch filters on, so an
/// unknown value must never be dispatchable.
enum TruckType {
  /// Flatbed. Required for anything that cannot roll or must not be towed on
  /// its own wheels.
  @JsonValue('plataforma')
  plataforma('plataforma', 'Plataforma'),

  /// Hook and chain / wheel-lift. The everyday tow.
  @JsonValue('gancho')
  gancho('gancho', 'Gancho'),

  /// Heavy recovery for trucks and buses.
  @JsonValue('pesada')
  pesada('pesada', 'Grúa pesada'),

  @JsonValue('unknown')
  unknown('unknown', 'Desconocido');

  const TruckType(this.wire, this.label);

  final String wire;

  /// Spanish label shown to users in the Dominican Republic.
  final String label;

  static TruckType fromWire(String? wire) =>
      _resolve(TruckType.values, wire, (v) => v.wire, TruckType.unknown);

  bool get isDispatchable => this != TruckType.unknown;

  /// Whether this truck can do a job that asks for [required].
  ///
  /// A plataforma carries the whole vehicle, so it can do anything a gancho
  /// can. Not the reverse: a gancho tows on the vehicle's own wheels, which is
  /// exactly what a flipped or wheel-locked car cannot do. A pesada is for
  /// trucks and buses — nothing substitutes for it and it substitutes for
  /// nothing, because sending a heavy wrecker to a sedan is the wrong truck at
  /// the wrong price.
  ///
  /// Mirrors `trucksThatCanServe` in `functions/src/lib/enums.ts`. Dispatch
  /// used to demand an exact match on both sides, which left a customer
  /// watching "Buscando grúa" while an idle flatbed sat two streets away.
  bool canServe(TruckType required) =>
      this == required ||
      (required == TruckType.gancho && this == TruckType.plataforma);
}

/// The customer's vehicle class. It sets the tarifa and the [TruckType].
enum VehicleType {
  @JsonValue('sedan')
  sedan('sedan', 'Carro'),
  @JsonValue('suv')
  suv('suv', 'Jeepeta'),
  @JsonValue('camioneta')
  camioneta('camioneta', 'Camioneta'),

  /// Vehículos pesados from here: a special grúa, and a price the operator
  /// confirms before anybody goes.
  @JsonValue('camion')
  camion('camion', 'Camión 2 ejes'),
  @JsonValue('patana')
  patana('patana', 'Patana / Tráiler'),
  @JsonValue('equipo_pesado')
  equipoPesado('equipo_pesado', 'Equipo pesado'),
  @JsonValue('motor')
  motor('motor', 'Motor'),
  @JsonValue('unknown')
  unknown('unknown', 'Otro');

  const VehicleType(this.wire, this.label);

  final String wire;
  final String label;

  static VehicleType fromWire(String? wire) =>
      _resolve(VehicleType.values, wire, (v) => v.wire, VehicleType.unknown);

  /// The ones the request form offers under "Vehículos livianos".
  static const List<VehicleType> light = [
    VehicleType.sedan,
    VehicleType.suv,
    VehicleType.camioneta,
  ];

  /// The ones under "Vehículos pesados". Mirrors `HEAVY_VEHICLE_TYPES` in
  /// `functions/src/lib/enums.ts`.
  static const List<VehicleType> heavy = [
    VehicleType.camion,
    VehicleType.patana,
    VehicleType.equipoPesado,
  ];

  /// Needs the heavy grúa, and its price is only an estimate until the
  /// operator confirms it.
  bool get isHeavy => heavy.contains(this);
}

/// The column of the insurer zone tariff a vehicle is priced in. Mirrors
/// `VehicleClass` in `functions/src/lib/zonePricing.ts`.
enum VehicleClass {
  /// Carro, motor.
  @JsonValue('light')
  light('light', 'Vehículo ligero'),

  /// SUV / jeepeta, camioneta.
  @JsonValue('suv')
  suv('suv', 'SUV / Jeepeta'),

  /// Camión, patana, autobús, equipo pesado.
  @JsonValue('heavy')
  heavy('heavy', 'Vehículo pesado'),

  @JsonValue('unknown')
  unknown('unknown', 'Desconocido');

  const VehicleClass(this.wire, this.label);

  final String wire;
  final String label;

  static VehicleClass fromWire(String? wire) =>
      _resolve(VehicleClass.values, wire, (v) => v.wire, VehicleClass.unknown);

  /// The classes the tariff has a column for.
  static const List<VehicleClass> priced = [
    VehicleClass.light,
    VehicleClass.suv,
    VehicleClass.heavy,
  ];

  static VehicleClass of(VehicleType type) => switch (type) {
        VehicleType.sedan || VehicleType.motor => VehicleClass.light,
        VehicleType.suv || VehicleType.camioneta => VehicleClass.suv,
        VehicleType.camion ||
        VehicleType.patana ||
        VehicleType.equipoPesado =>
          VehicleClass.heavy,
        VehicleType.unknown => VehicleClass.unknown,
      };
}

/// What the customer is told about a heavy vehicle, on the form, on the price
/// and while they wait. Written by the owner; kept word for word.
const String heavyServiceNotice =
    'Este servicio requiere grúa especial. Se confirmará disponibilidad y '
    'precio final con el operador';

/// Where a heavy request stands with the operator.
enum OperatorReviewState {
  @JsonValue('pending')
  pending('pending'),
  @JsonValue('confirmed')
  confirmed('confirmed'),
  @JsonValue('unknown')
  unknown('unknown');

  const OperatorReviewState(this.wire);

  final String wire;
}

/// Why the vehicle needs a grúa. Drives both pricing and truck-type inference.
enum VehicleCondition {
  @JsonValue('no_arranca')
  noArranca('no_arranca', 'No arranca'),
  @JsonValue('accidentado')
  accidentado('accidentado', 'Accidentado'),
  @JsonValue('ruedas_bloqueadas')
  ruedasBloqueadas('ruedas_bloqueadas', 'Ruedas bloqueadas'),
  @JsonValue('volcado')
  volcado('volcado', 'Volcado'),
  @JsonValue('sin_combustible')
  sinCombustible('sin_combustible', 'Sin combustible'),
  @JsonValue('goma_pinchada')
  gomaPinchada('goma_pinchada', 'Goma pinchada'),
  @JsonValue('unknown')
  unknown('unknown', 'Otro problema');

  const VehicleCondition(this.wire, this.label);

  final String wire;
  final String label;

  static VehicleCondition fromWire(String? wire) =>
      _resolve(VehicleCondition.values, wire, (v) => v.wire, VehicleCondition.unknown);

  /// A vehicle that cannot roll on its own wheels needs a flatbed.
  bool get requiresFlatbed =>
      this == VehicleCondition.volcado ||
      this == VehicleCondition.accidentado ||
      this == VehicleCondition.ruedasBloqueadas;
}

/// Documents a chofer must keep current to stay `active`.
enum DriverDocumentType {
  @JsonValue('licencia')
  licencia('licencia', 'Licencia de conducir', required: true),
  /// The back of the same card, kept as its own record so a reviewer sees
  /// both sides and a missing one is obvious.
  @JsonValue('licencia_reverso')
  licenciaReverso('licencia_reverso', 'Licencia de conducir (reverso)', required: true),
  @JsonValue('cedula')
  cedula('cedula', 'Cédula', required: true),
  @JsonValue('seguro')
  seguro('seguro', 'Seguro del vehículo', required: true),
  @JsonValue('marbete')
  marbete('marbete', 'Marbete', required: true),
  @JsonValue('matricula')
  matricula('matricula', 'Matrícula', required: true),
  @JsonValue('certificado_medico')
  certificadoMedico('certificado_medico', 'Certificado médico', required: false),
  @JsonValue('unknown')
  unknown('unknown', 'Documento', required: false);

  const DriverDocumentType(this.wire, this.label, {required this.required});

  final String wire;
  final String label;

  /// When a required document expires, the chofer is forced offline.
  final bool required;

  static DriverDocumentType fromWire(String? wire) =>
      _resolve(DriverDocumentType.values, wire, (v) => v.wire, DriverDocumentType.unknown);
}

/// Where a self-registered chofer's automatic licence check stands. Mirrors
/// `LicenseVerificationState` in `functions/src/lib/enums.ts`.
enum LicenseVerificationState {
  @JsonValue('awaiting_documents')
  awaitingDocuments('awaiting_documents', 'Esperando fotos'),
  @JsonValue('processing')
  processing('processing', 'Verificando'),

  /// Passed every check. The account still waits for the office to activate it.
  @JsonValue('verified')
  verified('verified', 'Verificada'),

  /// Failed a check the chofer can fix by sending new photos.
  @JsonValue('rejected')
  rejected('rejected', 'Rechazada'),

  /// Needs a person: an unclear result, a suspected edit, or too many tries.
  @JsonValue('manual_review')
  manualReview('manual_review', 'Revisión manual'),
  @JsonValue('unknown')
  unknown('unknown', 'Desconocido');

  const LicenseVerificationState(this.wire, this.label);

  final String wire;
  final String label;

  /// The chofer may send new photos.
  bool get acceptsPhotos =>
      this == LicenseVerificationState.awaitingDocuments ||
      this == LicenseVerificationState.rejected;

  static LicenseVerificationState fromWire(String? wire) => _resolve(
        LicenseVerificationState.values,
        wire,
        (v) => v.wire,
        LicenseVerificationState.unknown,
      );
}

enum DocumentReviewState {
  @JsonValue('pending')
  pending('pending', 'Pendiente'),
  @JsonValue('verified')
  verified('verified', 'Verificado'),
  @JsonValue('rejected')
  rejected('rejected', 'Rechazado'),
  @JsonValue('expired')
  expired('expired', 'Vencido'),
  @JsonValue('unknown')
  unknown('unknown', 'Desconocido');

  const DocumentReviewState(this.wire, this.label);

  final String wire;
  final String label;

  static DocumentReviewState fromWire(String? wire) =>
      _resolve(DocumentReviewState.values, wire, (v) => v.wire, DocumentReviewState.unknown);
}

// ---------------------------------------------------------------------------
// Service lifecycle
// ---------------------------------------------------------------------------

/// The eleven service states. Transitions are enforced server-side; this enum
/// exists so the apps can render the right screen, never to decide a change.
enum ServiceStatus {
  /// Created and looking for a chofer.
  @JsonValue('pending_dispatch')
  pendingDispatch('pending_dispatch', 'Buscando grúa'),

  /// One chofer is holding an exclusive offer, a minute long.
  @JsonValue('offered')
  offered('offered', 'Buscando grúa'),

  /// A chofer took it and is on the way.
  @JsonValue('accepted')
  accepted('accepted', 'Grúa en camino'),

  /// The chofer pressed "Llegué".
  @JsonValue('arrived')
  arrived('arrived', 'Tu grúa llegó'),

  /// Vehicle loaded, heading to the destination.
  @JsonValue('in_progress')
  inProgress('in_progress', 'En camino al destino'),

  /// The chofer pressed "Finalizar". Payment may still be settling.
  @JsonValue('completed')
  completed('completed', 'Servicio completado'),

  /// Paid and invoiced. Terminal.
  @JsonValue('closed')
  closed('closed', 'Servicio cerrado'),

  /// The cascade gave up; a dispatcher must assign by hand.
  @JsonValue('needs_manual')
  needsManual('needs_manual', 'Asignando grúa'),

  /// Cancelled by client, chofer, admin or the system. Terminal.
  @JsonValue('cancelled')
  cancelled('cancelled', 'Servicio cancelado'),

  /// Nobody was ever assigned within the dispatch window. Terminal.
  @JsonValue('expired')
  expired('expired', 'Servicio expirado'),

  /// Something went wrong that needs a human. Terminal.
  @JsonValue('failed')
  failed('failed', 'Servicio con problema'),

  @JsonValue('unknown')
  unknown('unknown', 'Estado desconocido');

  const ServiceStatus(this.wire, this.label);

  final String wire;

  /// Customer-facing es-DO label. Note that `offered` deliberately reads the
  /// same as `pending_dispatch`: the client should not see the cascade churn.
  final String label;

  static ServiceStatus fromWire(String? wire) =>
      _resolve(ServiceStatus.values, wire, (v) => v.wire, ServiceStatus.unknown);

  static const Set<ServiceStatus> terminal = {
    ServiceStatus.closed,
    ServiceStatus.cancelled,
    ServiceStatus.expired,
    ServiceStatus.failed,
  };

  /// States in which a client is considered to have a service in flight and
  /// may not request another.
  static const Set<ServiceStatus> active = {
    ServiceStatus.pendingDispatch,
    ServiceStatus.offered,
    ServiceStatus.accepted,
    ServiceStatus.arrived,
    ServiceStatus.inProgress,
    ServiceStatus.completed,
    ServiceStatus.needsManual,
  };

  /// Requested and still nobody's job: the dispatcher's queue.
  ///
  /// `offered` is in here because an offer is a minute long and can come
  /// straight back — a service is not somebody's until a chofer accepts it.
  static const Set<ServiceStatus> awaitingDriver = {
    ServiceStatus.pendingDispatch,
    ServiceStatus.offered,
    ServiceStatus.needsManual,
  };

  /// States where chat and calling between the two parties are open.
  static const Set<ServiceStatus> contactOpen = {
    ServiceStatus.accepted,
    ServiceStatus.arrived,
    ServiceStatus.inProgress,
  };

  bool get isTerminal => terminal.contains(this);

  bool get isActive => active.contains(this);

  bool get isAwaitingDriver => awaitingDriver.contains(this);

  /// The office's name for the state. [label] is written for the customer —
  /// "Tu grúa llegó", and `offered` hidden behind "Buscando grúa" — which is
  /// the wrong voice for a dispatcher reading a list of every job.
  String get officeLabel => switch (this) {
        ServiceStatus.pendingDispatch => 'Buscando chofer',
        ServiceStatus.offered => 'Ofrecido a chofer',
        ServiceStatus.accepted => 'Chofer en camino',
        ServiceStatus.arrived => 'Chofer en el punto',
        ServiceStatus.inProgress => 'Remolcando',
        ServiceStatus.completed => 'Completado',
        ServiceStatus.closed => 'Cerrado',
        ServiceStatus.needsManual => 'Requiere asignación',
        ServiceStatus.cancelled => 'Cancelado',
        ServiceStatus.expired => 'Expirado',
        ServiceStatus.failed => 'Con problema',
        ServiceStatus.unknown => 'Desconocido',
      };

  /// True once a specific chofer owns the job.
  bool get hasDriver => const {
        ServiceStatus.accepted,
        ServiceStatus.arrived,
        ServiceStatus.inProgress,
        ServiceStatus.completed,
        ServiceStatus.closed,
      }.contains(this);

  /// The client may cancel right up until the vehicle is loaded.
  bool get isCancellableByClient => const {
        ServiceStatus.pendingDispatch,
        ServiceStatus.offered,
        ServiceStatus.needsManual,
        ServiceStatus.accepted,
        ServiceStatus.arrived,
      }.contains(this);

  bool get allowsContact => contactOpen.contains(this);
}

/// Names of the server callables that move a service between states. Keeping
/// them here means the apps and the tests cannot drift from the function names.
enum ServiceEventName {
  @JsonValue('requestService')
  requestService('requestService'),
  @JsonValue('dispatchNext')
  dispatchNext('dispatchNext'),
  @JsonValue('acceptService')
  acceptService('acceptService'),
  @JsonValue('rejectService')
  rejectService('rejectService'),
  @JsonValue('expireOffer')
  expireOffer('expireOffer'),
  @JsonValue('noDriversFound')
  noDriversFound('noDriversFound'),
  @JsonValue('assignServiceManually')
  assignServiceManually('assignServiceManually'),
  @JsonValue('confirmHeavyService')
  confirmHeavyService('confirmHeavyService'),
  @JsonValue('markArrived')
  markArrived('markArrived'),
  @JsonValue('startService')
  startService('startService'),
  @JsonValue('completeService')
  completeService('completeService'),
  @JsonValue('confirmCashCollected')
  confirmCashCollected('confirmCashCollected'),
  @JsonValue('closeService')
  closeService('closeService'),
  @JsonValue('cancelService')
  cancelService('cancelService'),
  @JsonValue('cancelByDriver')
  cancelByDriver('cancelByDriver'),
  @JsonValue('failService')
  failService('failService'),

  // Money, logged beside the transitions without moving the status.
  @JsonValue('choosePaymentMethod')
  choosePaymentMethod('choosePaymentMethod'),
  @JsonValue('paymentAuthorized')
  paymentAuthorized('paymentAuthorized'),
  @JsonValue('paymentCaptured')
  paymentCaptured('paymentCaptured'),
  @JsonValue('paymentFailed')
  paymentFailed('paymentFailed'),
  @JsonValue('paymentVoided')
  paymentVoided('paymentVoided'),

  @JsonValue('unknown')
  unknown('unknown');

  const ServiceEventName(this.wire);

  final String wire;

  static ServiceEventName fromWire(String? wire) =>
      _resolve(ServiceEventName.values, wire, (v) => v.wire, ServiceEventName.unknown);
}

/// State of a single dispatch offer to one chofer.
enum OfferState {
  @JsonValue('sent')
  sent('sent'),
  @JsonValue('accepted')
  accepted('accepted'),
  @JsonValue('rejected')
  rejected('rejected'),
  @JsonValue('expired')
  expired('expired'),
  @JsonValue('cancelled')
  cancelled('cancelled'),
  @JsonValue('unknown')
  unknown('unknown');

  const OfferState(this.wire);

  final String wire;

  static OfferState fromWire(String? wire) =>
      _resolve(OfferState.values, wire, (v) => v.wire, OfferState.unknown);

  bool get isOpen => this == OfferState.sent;
}

enum AssignmentMode {
  @JsonValue('auto')
  auto('auto', 'Automático'),
  @JsonValue('manual')
  manual('manual', 'Manual'),
  @JsonValue('unknown')
  unknown('unknown', 'Desconocido');

  const AssignmentMode(this.wire, this.label);

  final String wire;
  final String label;

  static AssignmentMode fromWire(String? wire) =>
      _resolve(AssignmentMode.values, wire, (v) => v.wire, AssignmentMode.unknown);
}

enum CancelledBy {
  @JsonValue('client')
  client('client', 'Cliente'),

  /// A person of the insurance company that ordered the tow.
  @JsonValue('insurer')
  insurer('insurer', 'Aseguradora'),
  @JsonValue('driver')
  driver('driver', 'Chofer'),
  @JsonValue('admin')
  admin('admin', 'Administración'),
  @JsonValue('system')
  system('system', 'Sistema'),
  @JsonValue('unknown')
  unknown('unknown', 'Desconocido');

  const CancelledBy(this.wire, this.label);

  final String wire;
  final String label;

  static CancelledBy fromWire(String? wire) =>
      _resolve(CancelledBy.values, wire, (v) => v.wire, CancelledBy.unknown);
}

/// A tag given beside the stars, whichever side is rating.
abstract interface class RatingTag {
  String get wire;
  String get label;

  /// Praise, offered with four or five stars; otherwise a complaint.
  bool get positive;

  /// Sends the rating to the office whatever the stars.
  bool get serious;
}

/// What a customer can say about the chofer beside the stars. Praise goes with
/// four or five stars, complaints with three or fewer; the server drops a tag
/// given with the wrong kind of rating.
///
/// Mirrored in `functions/src/lib/driverRating.ts`.
enum DriverRatingTag implements RatingTag {
  @JsonValue('punctual')
  punctual('punctual', 'Llegó a tiempo', positive: true),
  @JsonValue('courteous')
  courteous('courteous', 'Amable', positive: true),
  @JsonValue('careful')
  careful('careful', 'Cuidó mi vehículo', positive: true),
  @JsonValue('professional')
  professional('professional', 'Profesional', positive: true),
  @JsonValue('good_truck')
  goodTruck('good_truck', 'Grúa en buen estado', positive: true),
  @JsonValue('late')
  late('late', 'Llegó tarde'),
  @JsonValue('rude')
  rude('rude', 'Mal trato', serious: true),
  @JsonValue('vehicle_damage')
  vehicleDamage('vehicle_damage', 'Dañó mi vehículo', serious: true),
  @JsonValue('overcharge')
  overcharge('overcharge', 'Quiso cobrar de más', serious: true),
  @JsonValue('unsafe_driving')
  unsafeDriving('unsafe_driving', 'Manejo peligroso', serious: true),
  @JsonValue('unknown')
  unknown('unknown', 'Otro');

  const DriverRatingTag(
    this.wire,
    this.label, {
    this.positive = false,
    this.serious = false,
  });

  @override
  final String wire;
  @override
  final String label;
  @override
  final bool positive;
  @override
  final bool serious;

  /// The tags a customer is offered for [stars].
  static List<DriverRatingTag> forStars(int stars) => [
        for (final tag in values)
          if (tag != unknown && tag.positive == (stars >= 4)) tag,
      ];

  static DriverRatingTag fromWire(String? wire) => _resolve(
        DriverRatingTag.values,
        wire,
        (v) => v.wire,
        DriverRatingTag.unknown,
      );
}

/// What a chofer can say about the customer beside the stars.
///
/// Mirrored in `functions/src/lib/driverRating.ts`.
enum ClientRatingTag implements RatingTag {
  @JsonValue('ready')
  ready('ready', 'Estaba en el lugar', positive: true),
  @JsonValue('courteous')
  courteous('courteous', 'Amable', positive: true),
  @JsonValue('accurate_info')
  accurateInfo('accurate_info', 'Información correcta', positive: true),
  @JsonValue('not_there')
  notThere('not_there', 'No estaba en el lugar'),
  @JsonValue('wrong_info')
  wrongInfo('wrong_info', 'Datos del vehículo incorrectos'),
  @JsonValue('rude')
  rude('rude', 'Mal trato', serious: true),
  @JsonValue('payment_problem')
  paymentProblem('payment_problem', 'Problema con el pago', serious: true),
  @JsonValue('unknown')
  unknown('unknown', 'Otro');

  const ClientRatingTag(
    this.wire,
    this.label, {
    this.positive = false,
    this.serious = false,
  });

  @override
  final String wire;
  @override
  final String label;
  @override
  final bool positive;
  @override
  final bool serious;

  /// The tags a chofer is offered for [stars].
  static List<ClientRatingTag> forStars(int stars) => [
        for (final tag in values)
          if (tag != unknown && tag.positive == (stars >= 4)) tag,
      ];

  static ClientRatingTag fromWire(String? wire) => _resolve(
        ClientRatingTag.values,
        wire,
        (v) => v.wire,
        ClientRatingTag.unknown,
      );
}

/// Where a customer's review of a chofer stands with the office.
enum DriverReviewStatus {
  /// Nothing to look at.
  @JsonValue('ok')
  ok('ok', 'Sin novedad'),

  /// Low stars or a serious complaint, waiting for the office.
  @JsonValue('open')
  open('open', 'Por revisar'),

  /// The office looked into it and wrote down what it found.
  @JsonValue('resolved')
  resolved('resolved', 'Revisada'),
  @JsonValue('unknown')
  unknown('unknown', 'Desconocido');

  const DriverReviewStatus(this.wire, this.label);

  final String wire;
  final String label;

  static DriverReviewStatus fromWire(String? wire) => _resolve(
        DriverReviewStatus.values,
        wire,
        (v) => v.wire,
        DriverReviewStatus.unknown,
      );
}

/// When the chofer photographed the vehicle: as they loaded it, or as they
/// handed it over. Only ever part of a file name in the bucket, never a field.
enum ServicePhotoStage {
  pickup('pickup', 'Al recoger'),
  dropoff('dropoff', 'Al entregar');

  const ServicePhotoStage(this.wire, this.label);

  final String wire;
  final String label;
}

/// Fixed reasons a chofer may give for dropping a job. Free text is not
/// accepted because these feed the admin's abuse flags.
enum DriverCancelReason {
  @JsonValue('vehicle_breakdown')
  vehicleBreakdown('vehicle_breakdown', 'Avería de la grúa'),
  @JsonValue('wrong_truck_type')
  wrongTruckType('wrong_truck_type', 'Tipo de grúa incorrecto'),
  @JsonValue('client_not_present')
  clientNotPresent('client_not_present', 'El cliente no está en el lugar'),
  @JsonValue('client_refused')
  clientRefused('client_refused', 'El cliente rechazó el servicio'),
  @JsonValue('inaccessible_location')
  inaccessibleLocation('inaccessible_location', 'No puedo llegar al lugar'),
  @JsonValue('unsafe_location')
  unsafeLocation('unsafe_location', 'Lugar inseguro'),
  @JsonValue('emergency')
  emergency('emergency', 'Emergencia personal'),
  @JsonValue('other')
  other('other', 'Otro motivo'),
  @JsonValue('unknown')
  unknown('unknown', 'Desconocido');

  const DriverCancelReason(this.wire, this.label);

  final String wire;
  final String label;

  static DriverCancelReason fromWire(String? wire) =>
      _resolve(DriverCancelReason.values, wire, (v) => v.wire, DriverCancelReason.unknown);
}

// ---------------------------------------------------------------------------
// Money
// ---------------------------------------------------------------------------

enum PaymentMethod {
  @JsonValue('cash')
  cash('cash', 'Efectivo'),

  /// Only on jobs from when there was a card rail. Kept so an old service
  /// still reads correctly in the history.
  @JsonValue('card')
  card('card', 'Tarjeta'),
  @JsonValue('pending')
  pending('pending', 'Por elegir'),

  /// Nobody pays at the roadside: the insurance company is billed monthly.
  @JsonValue('insurer')
  insurer('insurer', 'Aseguradora'),
  @JsonValue('unknown')
  unknown('unknown', 'Desconocido');

  const PaymentMethod(this.wire, this.label);

  final String wire;
  final String label;

  static PaymentMethod fromWire(String? wire) =>
      _resolve(PaymentMethod.values, wire, (v) => v.wire, PaymentMethod.unknown);
}

enum PaymentStatus {
  /// Nothing collected yet.
  @JsonValue('none')
  none('none', 'Sin procesar'),

  /// Completed job, chofer has not confirmed collection yet.
  @JsonValue('cash_pending')
  cashPending('cash_pending', 'Cobro en efectivo pendiente'),

  /// The chofer confirmed "Cobrado en efectivo": the job is paid.
  @JsonValue('cash_collected')
  cashCollected('cash_collected', 'Pagado en efectivo'),

  /// An insurer's tow, done, waiting for the month's invoice.
  @JsonValue('to_invoice')
  toInvoice('to_invoice', 'Por facturar a la aseguradora'),

  /// An insurer's tow on a monthly invoice, whose id is in `invoiceId`.
  @JsonValue('invoiced')
  invoiced('invoiced', 'Facturado a la aseguradora'),

  // The four below only appear on jobs from when there was a card rail. Kept
  // so an old service still reads correctly in the history.
  @JsonValue('authorized')
  authorized('authorized', 'Tarjeta retenida'),
  @JsonValue('captured')
  captured('captured', 'Pagado con tarjeta'),
  @JsonValue('failed')
  failed('failed', 'Pago rechazado'),
  @JsonValue('refunded')
  refunded('refunded', 'Reembolsado'),
  @JsonValue('voided')
  voided('voided', 'Retención liberada'),

  @JsonValue('unknown')
  unknown('unknown', 'Desconocido');

  const PaymentStatus(this.wire, this.label);

  final String wire;
  final String label;

  static PaymentStatus fromWire(String? wire) =>
      _resolve(PaymentStatus.values, wire, (v) => v.wire, PaymentStatus.unknown);

  bool get isSettled =>
      this == PaymentStatus.captured || this == PaymentStatus.cashCollected;
}

/// Where a weekly corte stands. Mirrors `SettlementStatus` in
/// `functions/src/lib/settlements.ts`.
enum SettlementStatus {
  @JsonValue('pending')
  pending('pending', 'Pendiente de pago'),

  /// The transfer went out, or the chofer's payment came in.
  @JsonValue('settled')
  settled('settled', 'Pagado'),

  /// Cancelled by the office; its jobs went back into the next corte.
  @JsonValue('voided')
  voided('voided', 'Anulado'),

  @JsonValue('unknown')
  unknown('unknown', 'Desconocido');

  const SettlementStatus(this.wire, this.label);

  final String wire;
  final String label;

  static SettlementStatus fromWire(String? wire) => _resolve(
        SettlementStatus.values,
        wire,
        (v) => v.wire,
        SettlementStatus.unknown,
      );
}

/// Where a monthly invoice to an insurance company stands. Mirrors
/// `InsurerInvoiceStatus` in `functions/src/lib/insurerInvoice.ts`.
enum InsurerInvoiceStatus {
  /// Sent; waiting for the company's transfer.
  @JsonValue('issued')
  issued('issued', 'Por cobrar'),

  @JsonValue('paid')
  paid('paid', 'Cobrada'),

  /// Cancelled by the office; its services went back to be invoiced again.
  @JsonValue('voided')
  voided('voided', 'Anulada'),

  @JsonValue('unknown')
  unknown('unknown', 'Desconocido');

  const InsurerInvoiceStatus(this.wire, this.label);

  final String wire;
  final String label;

  static InsurerInvoiceStatus fromWire(String? wire) => _resolve(
        InsurerInvoiceStatus.values,
        wire,
        (v) => v.wire,
        InsurerInvoiceStatus.unknown,
      );
}

/// What a line on a monthly invoice is for.
enum InsurerInvoiceLineKind {
  /// A tow, at its zone price.
  tow('tow'),

  /// The fee for a tow the company cancelled after the chofer set off.
  cancellation('cancellation'),
  unknown('unknown');

  const InsurerInvoiceLineKind(this.wire);

  final String wire;

  static InsurerInvoiceLineKind fromWire(String? wire) => _resolve(
        InsurerInvoiceLineKind.values,
        wire,
        (v) => v.wire,
        InsurerInvoiceLineKind.unknown,
      );
}

/// Who pays whom at a weekly corte.
enum SettlementDirection {
  /// Titan transfers the balance to the chofer.
  @JsonValue('to_driver')
  toDriver('to_driver'),

  /// The chofer transfers or deposits the balance to Titan.
  @JsonValue('to_company')
  toCompany('to_company'),

  /// Nothing moves.
  @JsonValue('none')
  none('none'),

  @JsonValue('unknown')
  unknown('unknown');

  const SettlementDirection(this.wire);

  final String wire;

  static SettlementDirection fromWire(String? wire) => _resolve(
        SettlementDirection.values,
        wire,
        (v) => v.wire,
        SettlementDirection.unknown,
      );

  static SettlementDirection ofBalance(int balanceCents) => balanceCents > 0
      ? SettlementDirection.toDriver
      : balanceCents < 0
          ? SettlementDirection.toCompany
          : SettlementDirection.none;
}

/// Dominican tax receipt types (Números de Comprobante Fiscal).
enum NcfType {
  /// Crédito fiscal — for a customer with an RNC who will deduct the ITBIS.
  @JsonValue('01')
  creditoFiscal('01', 'Crédito fiscal'),

  /// Consumo — the default for individuals.
  @JsonValue('02')
  consumo('02', 'Consumo'),

  @JsonValue('unknown')
  unknown('unknown', 'Desconocido');

  const NcfType(this.wire, this.label);

  final String wire;
  final String label;

  static NcfType fromWire(String? wire) =>
      _resolve(NcfType.values, wire, (v) => v.wire, NcfType.unknown);
}

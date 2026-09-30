import 'package:freezed_annotation/freezed_annotation.dart';

import '../../data/converters.dart';
import '../../location/polyline.dart';
import '../../utils/money.dart';
import '../enums.dart';
import '../value_objects.dart';

part 'service.freezed.dart';
part 'service.g.dart';

/// The customer's vehicle, as described at request time.
@freezed
abstract class ServiceVehicle with _$ServiceVehicle {
  const factory ServiceVehicle({
    @Default('') String make,
    @Default('') String model,
    @Default('') String plate,
    @Default('') String color,
    int? year,
    @JsonKey(unknownEnumValue: VehicleType.unknown)
    @Default(VehicleType.sedan) VehicleType type,
    @JsonKey(unknownEnumValue: VehicleCondition.unknown)
    @Default(VehicleCondition.noArranca) VehicleCondition condition,
    @Default(<String>[]) List<String> photoPaths,
    @Default('') String notes,
  }) = _ServiceVehicle;

  const ServiceVehicle._();

  factory ServiceVehicle.fromJson(Map<String, dynamic> json) =>
      _$ServiceVehicleFromJson(json);

  /// "Toyota Corolla 2018 · Gris" — what the chofer reads on the offer card.
  String get displayName {
    final parts = [
      if (make.isNotEmpty) make,
      if (model.isNotEmpty) model,
      if (year != null) '$year',
    ].join(' ');
    final base = parts.isEmpty ? type.label : parts;
    return color.isEmpty ? base : '$base · $color';
  }

  /// The truck type this vehicle needs.
  ///
  /// This same rule runs server-side in `quoteService`; the app computes it
  /// only to show the customer a price before they commit. If the two ever
  /// disagree, the server wins. A heavy vehicle comes first: a flatbed cannot
  /// lift a camión, rolled over or not.
  TruckType get inferredTruckType {
    if (type.isHeavy) return TruckType.pesada;
    if (condition.requiresFlatbed) return TruckType.plataforma;
    return TruckType.gancho;
  }
}

/// A pickup or dropoff point.
@freezed
abstract class ServiceLocation with _$ServiceLocation {
  const factory ServiceLocation({
    @GeoPointConverter() required LatLng geo,
    @Default('') String geohash,
    @Default('') String address,
    @Default('') String placeId,

    /// Dominican street addressing is unreliable, so a landmark reference is
    /// mandatory at pickup: "frente al colmado, km 12 Autopista Duarte".
    @Default('') String reference,
    @Default('') String notes,
  }) = _ServiceLocation;

  const ServiceLocation._();

  factory ServiceLocation.fromJson(Map<String, dynamic> json) =>
      _$ServiceLocationFromJson(json);

  String get displayAddress => address.isNotEmpty ? address : 'Ubicación en el mapa';

  /// Address plus landmark, which is what a chofer actually navigates by.
  String get fullDescription =>
      reference.isEmpty ? displayAddress : '$displayAddress ($reference)';
}

/// The route the server computed between pickup and dropoff.
@freezed
abstract class ServiceRoute with _$ServiceRoute {
  const factory ServiceRoute({
    @Default(0) int distanceMeters,
    @Default(0) int durationSeconds,

    /// Encoded polyline from the Routes API. Decoded on device for drawing.
    @Default('') String polyline,
    @Default('routes_api') String provider,
    @NullableTimestampConverter() DateTime? fetchedAt,
  }) = _ServiceRoute;

  const ServiceRoute._();

  factory ServiceRoute.fromJson(Map<String, dynamic> json) =>
      _$ServiceRouteFromJson(json);

  /// The drawn path, decoded once from what the server stored.
  ///
  /// Empty for a service quoted before the server routed, or when the Routes
  /// API was unreachable at the time — the screen then falls back to fetching
  /// its own, and to a straight line under that.
  ///
  /// Unchecked: [Service.towPath] is the one that knows the two ends and can
  /// tell a road from a line across the Atlantic.
  List<LatLng> get path => polyline.isEmpty ? const [] : decodePolyline(polyline);

  double get distanceKm => distanceMeters / 1000;

  int get durationMinutes => (durationSeconds / 60).ceil();

  String get distanceLabel => distanceKm < 1
      ? '$distanceMeters m'
      : '${distanceKm.toStringAsFixed(1)} km';

  String get durationLabel => durationMinutes < 60
      ? '$durationMinutes min'
      : '${durationMinutes ~/ 60} h ${durationMinutes % 60} min';
}

/// One run of a route that is all city or all carretera.
typedef RoadStretch = ({int meters, bool highway});

/// The trip as the tariff sees it: its length, and how many of the charged
/// kilometres — those past the included ones — are city and how many carretera.
///
/// Mirrors `TripDistance` in `functions/src/lib/pricing.ts`, and travels back to
/// the server with the request: the price was signed on it.
class TripDistance {
  const TripDistance({
    required this.distanceKm,
    required this.cityKm,
    required this.highwayKm,
  });

  /// Which kilometres are charged, and on what kind of road.
  ///
  /// Literally "the first 5 km are included": the included distance is taken
  /// from the start of the trip, in driving order. Worked in tenths of a
  /// kilometre so the parts always add up to the whole.
  factory TripDistance.fromStretches(
    List<RoadStretch> stretches, {
    required double includedKm,
  }) {
    var skip = includedKm * 1000;
    var totalMeters = 0;
    var highwayMeters = 0.0;
    for (final stretch in stretches) {
      totalMeters += stretch.meters;
      final charged = (stretch.meters - skip).clamp(0, double.infinity);
      skip = (skip - stretch.meters).clamp(0, double.infinity).toDouble();
      if (stretch.highway) highwayMeters += charged;
    }

    final totalTenths = _roundHalfUp(totalMeters / 100);
    final chargedTenths =
        (totalTenths - _roundHalfUp(includedKm * 10)).clamp(0, 1 << 30);
    final highwayTenths =
        _roundHalfUp(highwayMeters / 100).clamp(0, chargedTenths);

    return TripDistance(
      distanceKm: totalTenths / 10,
      cityKm: (chargedTenths - highwayTenths) / 10,
      highwayKm: highwayTenths / 10,
    );
  }

  /// A trip with no road information: all of it priced as city.
  factory TripDistance.city(double distanceKm, {required double includedKm}) =>
      TripDistance.fromStretches(
        [(meters: (distanceKm * 1000).round(), highway: false)],
        includedKm: includedKm,
      );

  /// Read back off a quote, to send with the request it was signed for.
  factory TripDistance.of(Quote quote) => TripDistance(
        distanceKm: quote.distanceKm,
        cityKm: quote.cityKm,
        highwayKm: quote.highwayKm,
      );

  final double distanceKm;
  final double cityKm;
  final double highwayKm;

  Map<String, Object> toJson() => {
        'distanceKm': distanceKm,
        'cityKm': cityKm,
        'highwayKm': highwayKm,
      };

  /// `Math.round` in JavaScript rounds halves up; Dart's `round` rounds them
  /// away from zero. The same for the positive numbers here, but said once.
  static int _roundHalfUp(double value) => (value + 0.5).floor();

  @override
  String toString() =>
      'TripDistance($distanceKm km: $cityKm city, $highwayKm carretera)';
}

/// One line on the price breakdown beyond the base and distance charges.
@freezed
abstract class QuoteSurcharge with _$QuoteSurcharge {
  const factory QuoteSurcharge({
    required String code,
    required String label,
    @CentsConverter() @Default(0) int cents,
  }) = _QuoteSurcharge;

  const QuoteSurcharge._();

  factory QuoteSurcharge.fromJson(Map<String, dynamic> json) =>
      _$QuoteSurchargeFromJson(json);
}

/// A priced quote. Always produced by the server, never by the app.
@freezed
abstract class Quote with _$Quote {
  const factory Quote({
    @Default(1) int pricingVersion,
    @JsonKey(unknownEnumValue: VehicleType.unknown)
    @Default(VehicleType.unknown) VehicleType vehicleType,

    /// A heavy vehicle: the total is an estimate until the operator confirms.
    @Default(false) bool heavy,
    @CentsConverter() @Default(0) int baseCents,
    @Default(0) double includedKm,

    /// The city rate. Quotes from before the city/carretera split carry only
    /// this one.
    @CentsConverter() @Default(0) int perKmCents,
    @CentsConverter() @Default(0) int cityPerKmCents,
    @CentsConverter() @Default(0) int highwayPerKmCents,

    /// The whole trip.
    @Default(0) double distanceKm,

    /// Charged kilometres, past the included ones, by kind of road.
    @Default(0) double cityKm,
    @Default(0) double highwayKm,
    @CentsConverter() @Default(0) int distanceCents,
    @CentsConverter() @Default(0) int minimumAdjustmentCents,
    @Default(<QuoteSurcharge>[]) List<QuoteSurcharge> surcharges,
    @CentsConverter() @Default(0) int subtotalCents,
    @CentsConverter() @Default(0) int itbisCents,
    @CentsConverter() @Default(0) int totalCents,
    @Default('DOP') String currency,
  }) = _Quote;

  const Quote._();

  factory Quote.fromJson(Map<String, dynamic> json) => _$QuoteFromJson(json);

  bool get hasItbis => itbisCents > 0;

  int get surchargeTotalCents =>
      surcharges.fold(0, (sum, s) => sum + s.cents);

  String get totalLabel => totalCents.formatDOP;

  /// The trip's length as the price summary says it: `8 km`, `12.4 km`.
  String get distanceLabel => '${formatKm(distanceKm)} km';

  /// Every line the customer sees, in the order the receipt prints them.
  List<({String label, int cents})> get breakdown {
    final split = cityKm > 0 || highwayKm > 0;
    // A heavy vehicle has one rate for every road: one line says it better.
    final oneRate = cityPerKmCents == highwayPerKmCents;
    return [
      (
        label: includedKm > 0
            ? 'Tarifa base (incluye ${formatKm(includedKm)} km)'
            : 'Tarifa base',
        cents: baseCents,
      ),
      if (split && oneRate)
        (
          label: 'Recorrido ${formatKm(cityKm + highwayKm)} km × '
              '${cityPerKmCents.formatDOPShort}',
          cents: distanceCents,
        )
      else if (split) ...[
        if (cityKm > 0)
          (
            label: 'Ciudad ${formatKm(cityKm)} km × ${cityPerKmCents.formatDOPShort}',
            cents: (cityKm * cityPerKmCents).round(),
          ),
        if (highwayKm > 0)
          (
            label: 'Carretera ${formatKm(highwayKm)} km × '
                '${highwayPerKmCents.formatDOPShort}',
            cents: (highwayKm * highwayPerKmCents).round(),
          ),
      ] else if (distanceCents > 0)
        (
          label: 'Recorrido ${distanceKm.toStringAsFixed(1)} km',
          cents: distanceCents,
        ),
      if (minimumAdjustmentCents > 0)
        (label: 'Ajuste a tarifa mínima', cents: minimumAdjustmentCents),
      for (final s in surcharges) (label: s.label, cents: s.cents),
      if (itbisCents > 0) (label: 'ITBIS (18%)', cents: itbisCents),
    ];
  }

  /// `8` for a whole number of kilometres, `8.4` otherwise.
  static String formatKm(double km) {
    final tenths = (km * 10).round();
    return tenths % 10 == 0 ? '${tenths ~/ 10}' : (tenths / 10).toStringAsFixed(1);
  }
}

/// Payment state for one service.
@freezed
abstract class ServicePayment with _$ServicePayment {
  const factory ServicePayment({
    @JsonKey(unknownEnumValue: PaymentMethod.unknown)
    @Default(PaymentMethod.cash) PaymentMethod method,
    @JsonKey(unknownEnumValue: PaymentStatus.unknown)
    @Default(PaymentStatus.none) PaymentStatus status,

    /// What the chofer collected, once they confirmed having it.
    @CentsConverter() @Default(0) int capturedCents,
    @Default('') String failureMessage,

    /// The corte that counted this job's cash, once the office received it.
    String? cashSettlementId,

    /// The weekly corte that charged this job's commission instead: the
    /// chofer kept the cash, and the office does not collect it again.
    String? weeklySettlementId,
    @NullableTimestampConverter() DateTime? capturedAt,
    @NullableTimestampConverter() DateTime? cashCollectedAt,
    @NullableTimestampConverter() DateTime? cashSettledAt,
  }) = _ServicePayment;

  const ServicePayment._();

  factory ServicePayment.fromJson(Map<String, dynamic> json) =>
      _$ServicePaymentFromJson(json);

  bool get isCash => method == PaymentMethod.cash;

  /// Money in hand: "Pagado".
  bool get isPaid => status.isSettled;
}

/// Dispatch bookkeeping. Read-only to the apps; the cascade owns every field.
@freezed
abstract class DispatchState with _$DispatchState {
  const factory DispatchState({
    @Default(0) int round,
    @Default(5) double radiusKm,
    @Default(<String>[]) List<String> offeredTo,
    @Default(<String>[]) List<String> rejectedBy,
    @NullableTimestampConverter() DateTime? lastOfferAt,
    @NullableTimestampConverter() DateTime? offerExpiresAt,

    /// Why the last scan found nobody, in words, for the dispatcher.
    ///
    /// "Nobody" covers three different problems — no truck online, no truck of
    /// the right kind, every truck already on a job — and only one of them is
    /// dispatch's to solve. The panel used to show a request sitting there
    /// with no explanation at all.
    @Default('') String lastReason,
    @NullableTimestampConverter() DateTime? lastCheckedAt,

    /// Cloud Tasks name for the pending expiry, so accept can cancel it.
    String? taskName,
  }) = _DispatchState;

  const DispatchState._();

  factory DispatchState.fromJson(Map<String, dynamic> json) =>
      _$DispatchStateFromJson(json);

  /// Seconds left on the current offer, from the server's expiry stamp rather
  /// than a local countdown — a phone with a drifting clock must not lose work.
  int secondsRemaining(DateTime now) {
    final expiry = offerExpiresAt;
    if (expiry == null) return 0;
    final remaining = expiry.difference(now).inSeconds;
    return remaining < 0 ? 0 : remaining;
  }
}

/// When each milestone happened.
@freezed
abstract class ServiceTimeline with _$ServiceTimeline {
  const factory ServiceTimeline({
    @NullableTimestampConverter() DateTime? createdAt,
    @NullableTimestampConverter() DateTime? dispatchedAt,
    @NullableTimestampConverter() DateTime? acceptedAt,
    @NullableTimestampConverter() DateTime? arrivedAt,
    @NullableTimestampConverter() DateTime? startedAt,
    @NullableTimestampConverter() DateTime? completedAt,
    @NullableTimestampConverter() DateTime? closedAt,
    @NullableTimestampConverter() DateTime? cancelledAt,
  }) = _ServiceTimeline;

  const ServiceTimeline._();

  factory ServiceTimeline.fromJson(Map<String, dynamic> json) =>
      _$ServiceTimelineFromJson(json);

  /// How long the customer waited from request to a chofer accepting.
  Duration? get timeToAccept => (createdAt != null && acceptedAt != null)
      ? acceptedAt!.difference(createdAt!)
      : null;

  /// How long from accept to the chofer reaching the vehicle.
  Duration? get timeToArrive => (acceptedAt != null && arrivedAt != null)
      ? arrivedAt!.difference(acceptedAt!)
      : null;

  Duration? get serviceDuration => (startedAt != null && completedAt != null)
      ? completedAt!.difference(startedAt!)
      : null;

  /// Free waiting starts when the chofer arrives and stops when work begins.
  Duration? waitingElapsed(DateTime now) {
    if (arrivedAt == null) return null;
    final end = startedAt ?? now;
    return end.difference(arrivedAt!);
  }
}

/// The operator's check on a heavy job, at `services/{id}.operatorReview`.
///
/// A camión, patana or equipo pesado is only ever quoted an estimate: nobody is
/// sent until an operator has confirmed a heavy grúa can do it and the price.
@freezed
abstract class OperatorReview with _$OperatorReview {
  const factory OperatorReview({
    @JsonKey(name: 'required') @Default(false) bool isRequired,
    @JsonKey(unknownEnumValue: OperatorReviewState.unknown)
    @Default(OperatorReviewState.pending) OperatorReviewState state,
    @CentsConverter() @Default(0) int estimatedTotalCents,
    @CentsConverter() int? confirmedTotalCents,
    String? confirmedBy,
    @NullableTimestampConverter() DateTime? confirmedAt,
    @Default('') String note,
  }) = _OperatorReview;

  const OperatorReview._();

  factory OperatorReview.fromJson(Map<String, dynamic> json) =>
      _$OperatorReviewFromJson(json);

  bool get isPending => isRequired && state == OperatorReviewState.pending;

  bool get isConfirmed => state == OperatorReviewState.confirmed;
}

@freezed
abstract class ServiceCancellation with _$ServiceCancellation {
  const factory ServiceCancellation({
    @JsonKey(unknownEnumValue: CancelledBy.unknown)
    @Default(CancelledBy.unknown) CancelledBy by,
    @Default('') String reason,
    @Default('') String reasonCode,
    @CentsConverter() @Default(0) int feeCents,
    String? actorId,
  }) = _ServiceCancellation;

  const ServiceCancellation._();

  factory ServiceCancellation.fromJson(Map<String, dynamic> json) =>
      _$ServiceCancellationFromJson(json);

  bool get hasFee => feeCents > 0;
}

@freezed
abstract class ServiceRating with _$ServiceRating {
  const factory ServiceRating({
    @Default(0) int stars,
    @Default('') String comment,

    /// [DriverRatingTag] wires, on a customer's rating of the chofer. Kept as
    /// strings so a tag this app does not know yet still reads.
    @Default(<String>[]) List<String> tags,
    @NullableTimestampConverter() DateTime? ratedAt,
  }) = _ServiceRating;

  const ServiceRating._();

  factory ServiceRating.fromJson(Map<String, dynamic> json) =>
      _$ServiceRatingFromJson(json);

  bool get isRated => stars > 0;

  List<DriverRatingTag> get ratingTags => [
        for (final wire in tags)
          if (DriverRatingTag.fromWire(wire) case final tag
              when tag != DriverRatingTag.unknown)
            tag,
      ];
}

@freezed
abstract class ServiceRatings with _$ServiceRatings {
  const factory ServiceRatings({
    ServiceRating? clientToDriver,
    ServiceRating? driverToClient,
  }) = _ServiceRatings;

  const ServiceRatings._();

  factory ServiceRatings.fromJson(Map<String, dynamic> json) =>
      _$ServiceRatingsFromJson(json);
}

/// The insurance file behind a tow an insurance company ordered.
@freezed
abstract class InsuranceClaim with _$InsuranceClaim {
  const factory InsuranceClaim({
    /// Número de siniestro. What the company files the invoice line under.
    @Default('') String claimNumber,

    /// [claimNumber] with case and punctuation removed; duplicates are
    /// compared on this.
    @Default('') String claimKey,
    @Default('') String policyNumber,
    @Default('') String insuredName,
    @Default('') String insuredPhone,
  }) = _InsuranceClaim;

  const InsuranceClaim._();

  factory InsuranceClaim.fromJson(Map<String, dynamic> json) =>
      _$InsuranceClaimFromJson(json);
}

/// How an insurer's tow was priced, at `services/{id}.billing`: the zone and
/// the price before ITBIS.
///
/// Readable by the insurance company, so it carries no split — what the chofer
/// is paid lives where only the office can read it.
@freezed
abstract class InsurerBilling with _$InsurerBilling {
  const factory InsurerBilling({
    @Default('') String insurerId,

    /// `insurer` for the company's negotiated prices, `default` for the list.
    @Default('default') String tariff,
    @JsonKey(unknownEnumValue: VehicleClass.unknown)
    @Default(VehicleClass.unknown) VehicleClass vehicleClass,
    @Default(0) int zoneMinKm,
    int? zoneMaxKm,
    @Default(0) double distanceKm,
    @CentsConverter() @Default(0) int baseCents,
    @Default(0) double extraKm,
    @CentsConverter() @Default(0) int extraKmCents,
    @CentsConverter() @Default(0) int extraCents,
    @CentsConverter() @Default(0) int subtotalCents,
  }) = _InsurerBilling;

  const InsurerBilling._();

  factory InsurerBilling.fromJson(Map<String, dynamic> json) =>
      _$InsurerBillingFromJson(json);

  /// `0–10 km`, or `+50 km`.
  String get zoneLabel =>
      zoneMaxKm == null ? '+$zoneMinKm km' : '$zoneMinKm–$zoneMaxKm km';

  bool get isNegotiated => tariff == 'insurer';
}

/// A tow service — the central document of the whole system.
///
/// Everything except the chat subcollection is written by Cloud Functions. The
/// apps read this document, render it, and ask the server to move it.
@freezed
abstract class Service with _$Service {
  const factory Service({
    required String id,
    required String clientId,
    required ServiceLocation pickup,

    /// Human-readable code both parties quote on the phone: `GR-260908-0431`.
    @Default('') String code,
    @JsonKey(unknownEnumValue: ServiceStatus.unknown)
    @Default(ServiceStatus.pendingDispatch) ServiceStatus status,
    @Default('') String clientName,
    @Default('') String clientPhone,
    @Default(ServiceVehicle()) ServiceVehicle vehicle,
    @JsonKey(unknownEnumValue: TruckType.unknown)
    @Default(TruckType.gancho) TruckType truckTypeRequired,
    ServiceLocation? dropoff,
    @Default(ServiceRoute()) ServiceRoute route,
    @Default(Quote()) Quote quote,

    /// Written at completion. Differs from [quote] when waiting time or a
    /// reroute changed the price.
    ///
    /// `final` on the wire — `completeService` writes it under that name. Read
    /// as `finalQuote` it was never there, so the chofer was shown the estimate
    /// and "Cobrar" sent it, and the server refused it as not matching.
    @JsonKey(name: 'final') Quote? finalQuote,
    @Default(ServicePayment()) ServicePayment payment,

    /// The insurance company that ordered this tow. Empty on a customer's.
    @Default('') String insurerId,
    @Default('') String insurerName,
    InsuranceClaim? insurance,
    InsurerBilling? billing,
    String? driverId,
    @Default('') String driverName,
    @Default('') String driverPhone,
    @Default('') String driverPhotoUrl,
    @Default(0) double driverRating,
    String? truckId,
    @Default('') String truckPlate,
    @Default('') String truckLabel,
    @NullableTimestampConverter() DateTime? assignedAt,
    @JsonKey(unknownEnumValue: AssignmentMode.unknown)
    @Default(AssignmentMode.auto) AssignmentMode assignmentMode,
    @Default(DispatchState()) DispatchState dispatch,

    /// Present on a heavy job: the operator's confirmation of price and grúa.
    OperatorReview? operatorReview,
    @Default(ServiceTimeline()) ServiceTimeline timeline,
    ServiceCancellation? cancellation,
    @Default(ServiceRatings()) ServiceRatings ratings,
    String? invoiceId,
    @Default(0) int unreadForClient,
    @Default(0) int unreadForDriver,
    @Default(<String>[]) List<String> pickupPhotoPaths,
    @Default(<String>[]) List<String> dropoffPhotoPaths,
    @Default('') String driverNotes,
    @NullableTimestampConverter() DateTime? createdAt,
    @NullableTimestampConverter() DateTime? updatedAt,
  }) = _Service;

  const Service._();

  factory Service.fromJson(Map<String, dynamic> json) => _$ServiceFromJson(json);

  bool get isActive => status.isActive;

  bool get isTerminal => status.isTerminal;

  bool get hasDriver => driverId != null && driverId!.isNotEmpty;

  /// Ordered by an insurance company: nothing is collected at the roadside,
  /// the company is billed at the end of the month.
  bool get isInsurerJob =>
      insurerId.isNotEmpty || payment.method == PaymentMethod.insurer;

  /// What an insurer's tow is billed before ITBIS: the zone price, or the
  /// quote when the zone price is missing — as the invoice reads it.
  int get billedSubtotalCents {
    final billed = billing?.subtotalCents ?? 0;
    return billed > 0 ? billed : quote.subtotalCents;
  }

  /// A heavy job still waiting for the operator to confirm price and grúa.
  bool get awaitsOperator => operatorReview?.isPending ?? false;

  /// The tow drawn on a map: the road the server routed, checked against the
  /// two ends it is supposed to join.
  ///
  /// Empty when there is no stored path, or when the stored one does not
  /// describe this trip — both cases leave the screen to fetch its own, and a
  /// straight line under that. A wrong path is worse than no path: one bad
  /// point draws a band across the country.
  List<LatLng> get towPath {
    final end = dropoff?.geo;
    if (end == null) return const [];
    return sanePath(route.path, from: pickup.geo, to: end);
  }

  /// Chat and in-app calls reach the customer's app. An insurer's tow has no
  /// customer app on the other end — the chofer phones the insured instead.
  bool get canChat => status.allowsContact && hasDriver && clientId.isNotEmpty;

  bool get canCall => status.allowsContact && hasDriver && clientId.isNotEmpty;

  bool get isCancellableByClient => status.isCancellableByClient;

  /// The price to show. Before completion that is the estimate; after, the
  /// amount actually charged.
  Quote get effectiveQuote => finalQuote ?? quote;

  int get totalCents => effectiveQuote.totalCents;

  /// Customer-facing status line, with the driver's ETA folded in where it
  /// helps. Deliberately hides the dispatch cascade: a client watching
  /// `offered` flick back to `pending_dispatch` five times loses confidence.
  String statusLabelFor(UserRole role) {
    if (role == UserRole.driver) {
      return switch (status) {
        ServiceStatus.accepted => 'Ve al punto de recogida',
        ServiceStatus.arrived => 'Esperando para cargar',
        ServiceStatus.inProgress => 'En camino al destino',
        ServiceStatus.completed => payment.isCash
            ? 'Cobra ${totalCents.formatDOP}'
            : 'Servicio completado',
        _ => status.label,
      };
    }
    return status.label;
  }

  /// Whether a cancellation now would cost the client money. The server
  /// recomputes this; the app shows it so nobody is surprised.
  bool cancellationIncursFee(DateTime now, {Duration grace = const Duration(minutes: 3)}) {
    final acceptedAt = timeline.acceptedAt;
    if (acceptedAt == null) return false;
    return now.difference(acceptedAt) > grace;
  }

  /// Short one-line summary for lists: `GR-260908-0431 · Toyota Corolla`.
  String get listSummary {
    final vehicleLabel = vehicle.displayName;
    return code.isEmpty ? vehicleLabel : '$code · $vehicleLabel';
  }
}

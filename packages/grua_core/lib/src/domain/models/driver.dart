import 'package:freezed_annotation/freezed_annotation.dart';

import '../../data/converters.dart';
import '../enums.dart';
import '../value_objects.dart';

part 'driver.freezed.dart';
part 'driver.g.dart';

/// A chofer at `drivers/{uid}`.
///
/// An admin opens the account, or the chofer asks for one from the driver app;
/// either way it starts `inactive`, and every field here is written by a Cloud
/// Function. The driver app reads its own document and nothing else.
@freezed
abstract class Driver with _$Driver {
  const factory Driver({
    required String id,
    required String name,
    @Default('') String cedula,
    @Default('') String phone,
    @Default('') String email,
    @Default('') String photoUrl,
    @Default('') String licenseNumber,
    @NullableTimestampConverter() DateTime? licenseExpiry,
    @JsonKey(unknownEnumValue: DriverStatus.unknown)
    @Default(DriverStatus.inactive) DriverStatus status,
    @Default('') String statusReason,
    String? assignedTruckId,
    @Default('') String assignedTruckPlate,
    @JsonKey(unknownEnumValue: TruckType.unknown)
    @Default(TruckType.unknown) TruckType truckType,

    /// Set while the chofer owns a job. Its presence is what blocks a second
    /// offer, going offline, and being deactivated.
    String? currentServiceId,
    @Default(false) bool isOnline,
    /// The score dispatch ranks on: the average smoothed toward 4.8, so one
    /// rating does not decide a new chofer's place. Not for display — see
    /// [averageRating].
    @Default(4.8) double rating,
    @Default(0) int ratingCount,
    @Default(0) int ratingSum,

    /// Ratings per star, keyed `'1'`…`'5'`.
    @Default(<String, int>{}) Map<String, int> ratingStars,

    /// How often customers gave each [DriverRatingTag], by wire.
    @Default(<String, int>{}) Map<String, int> ratingTags,

    /// The latest reviews, newest first, with nothing that names the service
    /// or the customer: what the chofer reads about themselves.
    @Default(<DriverFeedback>[]) List<DriverFeedback> recentFeedback,
    @Default(0) int completedServices,

    /// How the chofer answers offers, counted by dispatch.
    @Default(0) int offersSent,
    @Default(0) int offersAccepted,
    @Default(0) int offersRejected,

    /// Offers that ran out with no answer.
    @Default(0) int offersMissed,

    /// Jobs the chofer dropped after accepting.
    @Default(0) int cancellations,

    /// Cash the chofer has collected but not yet handed in. When this passes
    /// the configured limit they stop receiving cash jobs.
    @Default(0) int cashOwedCents,

    /// Cash collected from customers and not yet handed to the office in a
    /// corte. The whole amount, not the commission: the customer paid the
    /// company, and the chofer is holding it.
    @Default(0) int cashOnHandCents,
    @NullableTimestampConverter() DateTime? lastCashSettlementAt,
    @Default(<String>[]) List<String> zones,

    /// Set when the chofer works under his own company rather than for the
    /// office directly. The RNC is what the invoice carries, so it is kept on
    /// the chofer and not inferred from the truck.
    @Default('') String companyName,
    @Default('') String rnc,
    @Default('') String createdBy,
    @NullableTimestampConverter() DateTime? createdAt,
    @NullableTimestampConverter() DateTime? updatedAt,
    @NullableTimestampConverter() DateTime? lastOnlineAt,
    @Default(false) bool mustChangePassword,
    @Default(false) bool archived,

    /// The automatic licence check. Only choferes who registered from the app
    /// have one; the office saw the papers of those it opened itself.
    LicenseVerification? licenseVerification,
  }) = _Driver;

  const Driver._();

  factory Driver.fromJson(Map<String, dynamic> json) => _$DriverFromJson(json);

  bool get isBusy => currentServiceId != null && currentServiceId!.isNotEmpty;

  bool get canGoOnline => status.canWork && assignedTruckId != null;

  bool get isDispatchable => status.canWork && isOnline && !isBusy;

  /// What the office sees at a glance.
  ///
  /// A job outranks the online switch: a chofer holding one is not
  /// dispatchable, whatever the switch says. The switch outranks [appOpen],
  /// which only says the chofer is signed in with the app running right now —
  /// reachable, but not taking offers. It comes from `/presence` in RTDB, not
  /// from this document, which is why the caller passes it in.
  DriverPresence presence({bool appOpen = false}) => isBusy
      ? DriverPresence.busy
      : isOnline
          ? DriverPresence.online
          : appOpen
              ? DriverPresence.connected
              : DriverPresence.offline;

  /// What customers gave on average, 0 before the first rating.
  double get averageRating => ratingCount == 0 ? 0 : ratingSum / ratingCount;

  /// Offers the chofer was sent and either answered or let run out.
  int get offersReceived {
    final answered = offersAccepted + offersRejected + offersMissed;
    return offersSent > answered ? offersSent : answered;
  }

  /// Share of offers this chofer actually took. Low numbers mean either a
  /// notification problem or a chofer cherry-picking; both need looking at.
  ///
  /// Counted over accepted, rejected and missed offers: dispatch never kept
  /// `offersSent`, so dividing by it alone showed everyone at 100%.
  double get acceptanceRate =>
      offersReceived == 0 ? 1 : offersAccepted / offersReceived;

  String get acceptanceLabel =>
      offersReceived == 0 ? '—' : '${(acceptanceRate * 100).round()}%';

  String get shortName {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length <= 1) return name.trim();
    return '${parts.first} ${parts[1]}';
  }

  /// Cédula formatted the way it appears on the card: `001-1234567-8`.
  String get displayCedula {
    final digits = cedula.replaceAll(RegExp(r'\D'), '');
    if (digits.length != 11) return cedula;
    return '${digits.substring(0, 3)}-${digits.substring(3, 10)}-${digits.substring(10)}';
  }
}

/// One review as the chofer reads it: no service, no customer, no date.
@freezed
abstract class DriverFeedback with _$DriverFeedback {
  const factory DriverFeedback({
    @Default(0) int stars,
    @Default(<String>[]) List<String> tags,
    @Default('') String comment,
  }) = _DriverFeedback;

  const DriverFeedback._();

  factory DriverFeedback.fromJson(Map<String, dynamic> json) =>
      _$DriverFeedbackFromJson(json);

  List<DriverRatingTag> get ratingTags => [
        for (final wire in tags)
          if (DriverRatingTag.fromWire(wire) case final tag
              when tag != DriverRatingTag.unknown)
            tag,
      ];
}

/// `drivers/{uid}.licenseVerification`, written by `verifyDriverLicense` and
/// by the office through `reviewLicenseVerification`.
@freezed
abstract class LicenseVerification with _$LicenseVerification {
  const factory LicenseVerification({
    @JsonKey(unknownEnumValue: LicenseVerificationState.unknown)
    @Default(LicenseVerificationState.awaitingDocuments)
    LicenseVerificationState state,

    /// Why it was rejected or sent to a person, in words for the chofer.
    @Default('') String reason,
    @Default(0) int attempts,
    @Default(<LicenseCheck>[]) List<LicenseCheck> checks,

    /// What the model read off the card, for the office to compare.
    LicenseReading? extracted,

    /// The model's note for a reviewer.
    @Default('') String notes,
    @Default('') String reviewedBy,
    @NullableTimestampConverter() DateTime? startedAt,
    @NullableTimestampConverter() DateTime? completedAt,
    @NullableTimestampConverter() DateTime? reviewedAt,
    @NullableTimestampConverter() DateTime? updatedAt,
  }) = _LicenseVerification;

  factory LicenseVerification.fromJson(Map<String, dynamic> json) =>
      _$LicenseVerificationFromJson(json);
}

/// One line of a licence check: `pass`, `fail` or `unclear`.
@freezed
abstract class LicenseCheck with _$LicenseCheck {
  const factory LicenseCheck({
    @Default('') String key,
    @Default('') String label,
    @Default('unclear') String result,
    @Default('') String detail,
  }) = _LicenseCheck;

  const LicenseCheck._();

  factory LicenseCheck.fromJson(Map<String, dynamic> json) =>
      _$LicenseCheckFromJson(json);

  bool get passed => result == 'pass';
  bool get failed => result == 'fail';
}

/// The text printed on the licence, as the model read it.
@freezed
abstract class LicenseReading with _$LicenseReading {
  const factory LicenseReading({
    @Default('') String fullName,
    @Default('') String cedula,
    @Default('') String licenseNumber,
    @Default('') String expiryDate,
  }) = _LicenseReading;

  factory LicenseReading.fromJson(Map<String, dynamic> json) =>
      _$LicenseReadingFromJson(json);
}

/// A chofer's availability as the roster shows it. Derived, never stored.
enum DriverPresence {
  /// Switched on and receiving offers.
  online('En línea'),

  /// On a job.
  busy('Ocupado'),

  /// Signed in with the app open, but not receiving offers.
  connected('Conectado'),

  /// App closed, signed out, or out of signal.
  offline('Desconectado');

  const DriverPresence(this.label);

  final String label;
}

/// One uploaded document at `drivers/{uid}/documents/{docType}`.
@freezed
abstract class DriverDocument with _$DriverDocument {
  const factory DriverDocument({
    @JsonKey(unknownEnumValue: DriverDocumentType.unknown)
    required DriverDocumentType type,
    @Default('') String storagePath,
    @Default('') String fileName,
    @Default(0) int sizeBytes,
    @Default('') String contentType,
    @JsonKey(unknownEnumValue: DocumentReviewState.unknown)
    @Default(DocumentReviewState.pending) DocumentReviewState state,
    @Default('') String rejectionReason,
    @Default('') String uploadedBy,
    @Default('') String reviewedBy,
    @NullableTimestampConverter() DateTime? uploadedAt,
    @NullableTimestampConverter() DateTime? reviewedAt,
    @NullableTimestampConverter() DateTime? issuedAt,
    @NullableTimestampConverter() DateTime? expiresAt,
  }) = _DriverDocument;

  const DriverDocument._();

  factory DriverDocument.fromJson(Map<String, dynamic> json) =>
      _$DriverDocumentFromJson(json);

  bool get isVerified => state == DocumentReviewState.verified;

  /// Days until expiry; negative once expired. Null when no expiry applies.
  int? daysUntilExpiry(DateTime now) {
    final expiry = expiresAt;
    if (expiry == null) return null;
    return expiry.difference(DateTime.utc(now.year, now.month, now.day)).inDays;
  }

  bool isExpired(DateTime now) => (daysUntilExpiry(now) ?? 1) < 0;

  /// The 30-day warning window the scheduled sweeper notifies on.
  bool isExpiringSoon(DateTime now) {
    final days = daysUntilExpiry(now);
    return days != null && days >= 0 && days <= 30;
  }

  /// An expired required document takes the chofer offline automatically —
  /// a grúa on the road with lapsed seguro is a liability, not a reminder.
  bool blocksWork(DateTime now) => type.required && (isExpired(now) || !isVerified);
}

/// A chofer's live position, mirrored from Realtime Database `/live/{driverId}`.
///
/// This is not a Firestore document. It is written at up to 0.2 Hz per chofer,
/// which is why it lives in RTDB: the same traffic in Firestore would dominate
/// the bill for a fleet of any size.
@freezed
abstract class DriverLivePosition with _$DriverLivePosition {
  const factory DriverLivePosition({
    required String driverId,
    required double lat,
    required double lng,
    @Default('') String geohash,
    @Default(0) double heading,
    @Default(0) double speedKmh,
    @Default(0) double accuracy,
    @Default(false) bool isOnline,
    @JsonKey(unknownEnumValue: DriverLiveState.unknown)
    @Default(DriverLiveState.idle) DriverLiveState state,
    @JsonKey(unknownEnumValue: TruckType.unknown)
    @Default(TruckType.unknown) TruckType truckType,
    String? serviceId,

    /// Epoch milliseconds. RTDB has no Timestamp type.
    @Default(0) int updatedAt,
  }) = _DriverLivePosition;

  const DriverLivePosition._();

  factory DriverLivePosition.fromJson(Map<String, dynamic> json) =>
      _$DriverLivePositionFromJson(json);

  LatLng get position => LatLng(lat, lng);

  DateTime get updatedAtUtc =>
      DateTime.fromMillisecondsSinceEpoch(updatedAt, isUtc: true);

  /// A phone that lost signal is not dispatchable, whatever `isOnline` says.
  /// The dispatcher applies the same 90-second rule server-side.
  bool isStale(DateTime now, {Duration threshold = const Duration(seconds: 90)}) =>
      now.difference(updatedAtUtc) > threshold;

  bool isDispatchable(DateTime now) =>
      isOnline && state == DriverLiveState.idle && !isStale(now);
}

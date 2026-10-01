import 'dart:async';

// cloud_functions exports its own `Result`, which would shadow the domain one
// this whole layer returns.
import 'package:cloud_functions/cloud_functions.dart' hide Result;
import 'package:flutter/foundation.dart';

import '../../calls/voice_call.dart';
import '../../domain/enums.dart';
import '../../domain/failures.dart';
import '../../domain/models/insurer.dart';
import '../../domain/models/insurer_invoice.dart';
import '../../domain/models/insurer_service.dart';
import '../../domain/models/pricing_rule.dart';
import '../../domain/models/service.dart';
import '../../domain/repositories.dart';
import '../../domain/value_objects.dart';
import '../converters.dart';

/// Calls the Cloud Functions that move a service between states.
///
/// Every method here is a state transition, and every one can be refused. The
/// refusals matter as much as the successes: `failed-precondition` with
/// `ALREADY_TAKEN` and the same status with `OFFER_EXPIRED` are the same HTTP
/// response and completely different news for a chofer, so the server's code
/// is carried through to a [FailureCode] rather than flattened into "error".
class FirebaseFunctionsGateway implements FunctionsGateway {
  FirebaseFunctionsGateway({required String region, FirebaseFunctions? functions})
      : _functions =
            functions ?? FirebaseFunctions.instanceFor(region: region);

  final FirebaseFunctions _functions;

  /// Long enough for a cold start on a function that calls the Routes API,
  /// short enough that a stranded customer is not left watching a spinner.
  static const _timeout = Duration(seconds: 30);

  Future<Result<T>> _call<T>(
    String name,
    Map<String, dynamic> payload,
    T Function(Map<String, dynamic> data) parse, {
    Duration timeout = _timeout,
  }) async {
    try {
      final result = await _functions
          .httpsCallable(name, options: HttpsCallableOptions(timeout: timeout))
          // Firestore's dialect does not travel: see [callablePayload].
          .call<Object?>(callablePayload(payload));

      // Deep, not `Map<String, dynamic>.from`: that fixes the top level only,
      // and the generated parsers cast every nested object.
      final data = plainJson(result.data);
      return Result.ok(parse(data is Map<String, dynamic> ? data : {}));
    } on FirebaseFunctionsException catch (error) {
      return Result.err(_mapCallableError(error, name));
    } on TimeoutException {
      return const Result.err(Failure(FailureCode.timeout));
    } on Object catch (error, stack) {
      // Never silently: a bare `unknown` reaches the customer as "Algo salió
      // mal" and tells whoever has to fix it nothing at all.
      _log(name, error, stack);
      return Result.err(Failure(FailureCode.unknown, cause: error));
    }
  }

  /// Prints what the customer's generic error was actually about.
  static void _log(String name, Object error, [StackTrace? stack]) {
    if (!kDebugMode) return;
    debugPrint('[grua] $name failed: ${error.runtimeType}: $error');
    if (stack != null) debugPrintStack(stackTrace: stack, maxFrames: 8);
  }

  Future<Result<void>> _callVoid(String name, Map<String, dynamic> payload) =>
      _call<void>(name, payload, (_) {});

  /// A coordinate the way every callable's `point` schema wants it.
  ///
  /// One helper rather than two hand-written maps: `markArrived` and
  /// `completeService` each spelled it out, and both spelled it wrong — a flat
  /// `lat`/`lng` pair where the server expects a nested `position`. Zod refused
  /// the payload, the callable answered `invalid-argument`, and a chofer who
  /// had driven to the customer could not press LLEGUÉ.
  static Map<String, double> _point(LatLng position) => {
        'latitude': position.latitude,
        'longitude': position.longitude,
      };

  /// Turns a callable's status and details into a domain failure.
  ///
  /// The server puts a machine-readable code in `details.code`; the message it
  /// sends alongside is already written for a Dominican user, so it is used
  /// verbatim when present rather than replaced with a generic one.
  Failure _mapCallableError(FirebaseFunctionsException error, String name) {
    _log(name, error);
    final details = error.details;
    final code = details is Map ? details['code'] as String? : null;
    final serverMessage = error.message;

    // A recognised business code always wins: it is more specific than the
    // transport status that carried it.
    final mapped = FailureCode.fromWire(code);
    if (mapped != FailureCode.unknown) {
      return Failure(
        mapped,
        // Only override the built-in copy when the server actually said
        // something more specific, such as the distance in an OUT_OF_RANGE.
        message: (serverMessage != null && serverMessage.contains(' '))
            ? serverMessage
            : null,
        // Normalised like any other reply: whatever reads this should not
        // have to know which platform decoded it.
        details: details is Map ? plainJson(details['data']) : null,
      );
    }

    return switch (error.code) {
      'unauthenticated' => const Failure(FailureCode.unauthenticated),
      'permission-denied' => const Failure(FailureCode.permissionDenied),
      'not-found' => const Failure(FailureCode.notFound),
      'invalid-argument' => Failure(
          FailureCode.invalidInput,
          message: serverMessage,
        ),
      'failed-precondition' => Failure(
          FailureCode.invalidTransition,
          message: serverMessage,
        ),
      'resource-exhausted' => const Failure(
          FailureCode.unknown,
          message: 'Demasiadas solicitudes. Espera un momento.',
        ),
      'deadline-exceeded' => const Failure(FailureCode.timeout),
      'unavailable' => const Failure(FailureCode.network),
      // A callable this build knows about and this project does not deploy.
      'unimplemented' => const Failure(
          FailureCode.unknown,
          message: 'Este servicio no está disponible ahora mismo. '
              'Intenta de nuevo o llámanos.',
        ),
      _ => Failure(
          FailureCode.unknown,
          // The server writes for a Dominican customer, so when it said
          // something, that beats the generic line.
          message: (serverMessage != null &&
                  serverMessage.contains(' ') &&
                  serverMessage != 'INTERNAL')
              ? serverMessage
              : null,
          cause: error,
        ),
    };
  }

  // -------------------------------------------------------------------------
  // Client
  // -------------------------------------------------------------------------

  @override
  Future<Result<void>> ensureProfile({String locale = 'es_DO'}) =>
      _callVoid('ensureProfile', {'locale': locale});

  @override
  Future<Result<void>> bootstrapFirstAdmin() =>
      _callVoid('bootstrapFirstAdmin', {});

  @override
  Future<Result<List<NearbyTruck>>> nearbyTrucks({
    required LatLng center,
    required double radiusKm,
  }) =>
      _call('nearbyTrucks', {
        'latitude': center.latitude,
        'longitude': center.longitude,
        'radiusKm': radiusKm,
      }, (data) {
        final trucks = data['trucks'] as List<dynamic>? ?? const [];
        return [
          for (final raw in trucks.whereType<Map<Object?, Object?>>())
            NearbyTruck(
              position: LatLng(
                (raw['latitude'] as num? ?? 0).toDouble(),
                (raw['longitude'] as num? ?? 0).toDouble(),
              ),
              truckType: TruckType.fromWire(raw['truckType'] as String?),
              distanceMeters: (raw['distanceMeters'] as num? ?? 0).round(),
              heading: (raw['heading'] as num? ?? 0).toDouble(),
              ref: raw['ref'] as String? ?? '',
            ),
        ];
      });

  @override
  Future<Result<String>> requestChat(String truckRef) => _call(
        'requestChat',
        {'truckRef': truckRef},
        (data) => data['requestId'] as String? ?? '',
      );

  @override
  Future<Result<void>> respondChatRequest(
    String requestId, {
    required bool accept,
  }) =>
      _callVoid('respondChatRequest', {
        'requestId': requestId,
        'accept': accept,
      });

  @override
  Future<Result<void>> closeChatRequest(String requestId) =>
      _callVoid('closeChatRequest', {'requestId': requestId});

  static CallJoin _join(Map<String, dynamic> data) => CallJoin(
        callId: data['callId'] as String? ?? '',
        peerName: data['peerName'] as String? ?? '',
        url: data['url'] as String? ?? '',
        token: data['token'] as String? ?? '',
        video: data['video'] == true,
      );

  @override
  Future<Result<CallJoin>> startCall(String serviceId, {bool video = false}) =>
      _call('startCall', {'serviceId': serviceId, 'video': video}, _join);

  @override
  Future<Result<CallJoin>> startChatRequestCall(
    String requestId, {
    bool video = false,
  }) =>
      _call('startCall', {'chatRequestId': requestId, 'video': video}, _join);

  @override
  Future<Result<CallJoin>> answerCall(String callId) =>
      _call('answerCall', {'callId': callId}, _join);

  @override
  Future<Result<void>> endCall(String callId, EndCallReason reason) =>
      _callVoid('endCall', {'callId': callId, 'reason': reason.wire});

  @override
  Future<Result<QuoteResult>> quoteService({
    required ServiceLocation pickup,
    required ServiceLocation dropoff,
    required ServiceVehicle vehicle,
    TruckType? truckTypeOverride,
  }) =>
      _call('quoteService', {
        'pickup': pickup.toJson(),
        'dropoff': dropoff.toJson(),
        'vehicle': vehicle.toJson(),
        if (truckTypeOverride != null)
          'truckTypeOverride': truckTypeOverride.wire,
      }, (data) {
        return QuoteResult(
          quote: Quote.fromJson(
            Map<String, dynamic>.from(data['quote'] as Map? ?? {}),
          ),
          route: ServiceRoute.fromJson(
            Map<String, dynamic>.from(data['route'] as Map? ?? {}),
          ),
          expiresAt: DateTime.tryParse(data['expiresAt'] as String? ?? '')
                  ?.toUtc() ??
              DateTime.now().toUtc(),
          // The HMAC the server recomputes on requestService. Opaque here on
          // purpose — the app must not be able to construct one.
          signature: data['signature'] as String? ?? '',
          truckType: TruckType.fromWire(data['truckType'] as String?),
        );
      });

  @override
  Future<Result<String>> requestService({
    required ServiceLocation pickup,
    required ServiceLocation dropoff,
    required ServiceVehicle vehicle,
    required TruckType truckType,
    required String quoteSignature,
    required DateTime quoteExpiresAt,
    required TripDistance distance,
    String? notes,
    String? preferredTruckRef,
  }) =>
      _call('requestService', {
        'distance': distance.toJson(),
        'preferredTruckRef': ?preferredTruckRef,
        'pickup': pickup.toJson(),
        'dropoff': dropoff.toJson(),
        'vehicle': vehicle.toJson(),
        'truckType': truckType.wire,
        'quoteSignature': quoteSignature,
        'quoteExpiresAtMs': quoteExpiresAt.millisecondsSinceEpoch,
        'notes': ?notes,
      }, (data) => data['serviceId'] as String? ?? '');

  @override
  Future<Result<void>> cancelService({
    required String serviceId,
    required String reason,
  }) =>
      _callVoid('cancelService', {'serviceId': serviceId, 'reason': reason});

  @override
  Future<Result<void>> rateService({
    required String serviceId,
    required int stars,
    List<RatingTag> tags = const [],
    String? comment,
  }) =>
      _callVoid('rateService', {
        'serviceId': serviceId,
        'stars': stars,
        'tags': [for (final tag in tags) tag.wire],
        'comment': ?comment,
      });

  @override
  Future<Result<void>> resolveDriverReview({
    required String serviceId,
    required String note,
  }) =>
      _callVoid('resolveDriverReview', {'serviceId': serviceId, 'note': note});

  // -------------------------------------------------------------------------
  // Driver
  // -------------------------------------------------------------------------

  @override
  Future<Result<void>> setOnline({required bool online}) =>
      _callVoid('setOnline', {'online': online});

  @override
  Future<Result<void>> acceptService(String serviceId) =>
      _callVoid('acceptService', {'serviceId': serviceId});

  @override
  Future<Result<void>> rejectService(
    String serviceId, {
    DriverCancelReason? reason,
  }) =>
      _callVoid('rejectService', {
        'serviceId': serviceId,
        if (reason != null) 'reason': reason.wire,
      });

  @override
  Future<Result<void>> markArrived({
    required String serviceId,
    required LatLng position,
  }) =>
      _callVoid('markArrived', {
        'serviceId': serviceId,
        'position': _point(position),
      });

  @override
  Future<Result<void>> startService({
    required String serviceId,
    required List<String> photoPaths,
  }) =>
      _callVoid('startService', {
        'serviceId': serviceId,
        'photoPaths': photoPaths,
      });

  @override
  Future<Result<void>> completeService({
    required String serviceId,
    required LatLng position,
    required List<String> photoPaths,
    String? notes,
  }) =>
      _callVoid('completeService', {
        'serviceId': serviceId,
        'position': _point(position),
        'photoPaths': photoPaths,
        'notes': ?notes,
      });

  @override
  Future<Result<void>> confirmCashCollected({
    required String serviceId,
    required int amountCents,
    String? discrepancyReason,
  }) =>
      _callVoid('confirmCashCollected', {
        'serviceId': serviceId,
        'amountCents': amountCents,
        'discrepancyReason': ?discrepancyReason,
      });

  @override
  Future<Result<int>> settleDriverCash({
    required String driverId,
    String note = '',
  }) =>
      _call(
        'settleDriverCash',
        {'driverId': driverId, 'note': note},
        (data) => (data['totalCents'] as num? ?? 0).round(),
      );

  @override
  Future<Result<InsurerQuote>> quoteInsurerService({
    required ServiceLocation pickup,
    required ServiceLocation dropoff,
    required VehicleType vehicleType,
  }) =>
      _call(
        'quoteInsurerService',
        {
          'pickup': pickup.toJson(),
          'dropoff': dropoff.toJson(),
          'vehicleType': vehicleType.wire,
        },
        InsurerQuote.fromJson,
      );

  @override
  Future<Result<CreatedInsurerService>> createInsurerService(
    InsurerServiceRequest request, {
    InsurerQuote? priced,
  }) =>
      _call(
        'createInsurerService',
        request.toJson(priced: priced),
        (data) => CreatedInsurerService(
          serviceId: data['serviceId'] as String,
          code: data['code'] as String? ?? '',
          totalCents: ((data['price'] as Map?)?['totalCents'] as num? ?? 0).round(),
        ),
      );

  @override
  Future<Result<void>> insurerPasswordChanged() =>
      _callVoid('insurerPasswordChanged', const {});

  @override
  Future<Result<String>> createInsurer({
    required InsurerDetails details,
    int? driverPayoutBps,
  }) =>
      _call(
        'createInsurer',
        {
          ...details.toJson(),
          'driverPayoutBps': ?driverPayoutBps,
        },
        (data) => data['insurerId'] as String,
      );

  @override
  Future<Result<void>> updateInsurer({
    required String insurerId,
    InsurerDetails? details,
    InsurerStatus? status,
    String? statusReason,
    int? driverPayoutBps,
    bool clearDriverPayout = false,
  }) =>
      _callVoid('updateInsurer', {
        'insurerId': insurerId,
        ...?details?.toJson(),
        if (status != null) 'status': status.wire,
        'statusReason': ?statusReason,
        if (clearDriverPayout)
          'driverPayoutBps': null
        else 'driverPayoutBps': ?driverPayoutBps,
      });

  @override
  Future<Result<NewInsurerUser>> createInsurerUser({
    required String insurerId,
    required String name,
    required String email,
    required InsurerRole role,
    String phone = '',
  }) =>
      _call(
        'createInsurerUser',
        {
          'insurerId': insurerId,
          'name': name,
          'email': email,
          'phone': phone,
          'insurerRole': role.wire,
        },
        (data) => NewInsurerUser(
          uid: data['uid'] as String,
          temporaryPassword: data['temporaryPassword'] as String,
        ),
      );

  @override
  Future<Result<void>> updateInsurerUser({
    required String insurerId,
    required String uid,
    String? name,
    String? phone,
    InsurerRole? role,
    bool? active,
  }) =>
      _callVoid('updateInsurerUser', {
        'insurerId': insurerId,
        'uid': uid,
        'name': ?name,
        'phone': ?phone,
        if (role != null) 'insurerRole': role.wire,
        'active': ?active,
      });

  @override
  Future<Result<void>> savePricingTable({
    required String? insurerId,
    required VehicleClass vehicleClass,
    required List<PricingRule> rows,
  }) =>
      _callVoid('savePricingTable', {
        'insurerId': insurerId,
        'vehicleClass': vehicleClass.wire,
        'rows': [
          for (final row in rows)
            {
              'zoneMinKm': row.zoneMinKm,
              'zoneMaxKm': row.zoneMaxKm,
              'baseCents': row.baseCents,
              'extraKmCents': row.extraKmCents,
            },
        ],
      });

  @override
  Future<Result<void>> resetPricingTable({
    required String? insurerId,
    required VehicleClass vehicleClass,
  }) =>
      _callVoid('resetPricingTable', {
        'insurerId': insurerId,
        'vehicleClass': vehicleClass.wire,
      });

  @override
  Future<Result<List<String>>> generateDriverSettlements({String? driverId}) =>
      _call(
        'generateDriverSettlements',
        {'driverId': driverId},
        (data) => [
          for (final created in data['created'] as List<dynamic>? ?? const [])
            (created as Map<String, dynamic>)['settlementId'] as String,
        ],
      );

  @override
  Future<Result<void>> settleDriverSettlement({
    required String settlementId,
    required String reference,
    String note = '',
  }) =>
      _callVoid('settleDriverSettlement', {
        'settlementId': settlementId,
        'reference': reference,
        'note': note,
      });

  @override
  Future<Result<void>> voidDriverSettlement({
    required String settlementId,
    required String reason,
  }) =>
      _callVoid('voidDriverSettlement', {
        'settlementId': settlementId,
        'reason': reason,
      });

  @override
  Future<Result<InvoiceRun>> generateInsurerInvoices({
    String? insurerId,
    String? periodKey,
  }) =>
      _call(
        'generateInsurerInvoices',
        {'insurerId': insurerId, 'periodKey': periodKey},
        InvoiceRun.fromJson,
      );

  @override
  Future<Result<void>> markInsurerInvoicePaid({
    required String invoiceId,
    required String reference,
    String note = '',
  }) =>
      _callVoid('markInsurerInvoicePaid', {
        'invoiceId': invoiceId,
        'reference': reference,
        'note': note,
      });

  @override
  Future<Result<void>> voidInsurerInvoice({
    required String invoiceId,
    required String reason,
  }) =>
      _callVoid('voidInsurerInvoice', {'invoiceId': invoiceId, 'reason': reason});

  @override
  Future<Result<void>> saveFiscalIssuer(FiscalIssuer issuer) =>
      _callVoid('saveFiscalIssuer', issuer.toJson());

  @override
  Future<Result<String>> saveNcfSequence(NcfSequence sequence) => _call(
        'saveNcfSequence',
        sequence.toJson(),
        (data) => data['next'] as String? ?? '',
      );

  @override
  Future<Result<void>> cancelByDriver({
    required String serviceId,
    required DriverCancelReason reason,
  }) =>
      _callVoid('cancelByDriver', {
        'serviceId': serviceId,
        'reason': reason.wire,
      });

  @override
  Future<Result<void>> publishEta({
    required String serviceId,
    required int etaSeconds,
    required int remainingMeters,
  }) =>
      _callVoid('publishEta', {
        'serviceId': serviceId,
        'etaSeconds': etaSeconds,
        'remainingMeters': remainingMeters,
      });

  // -------------------------------------------------------------------------
  // Admin
  // -------------------------------------------------------------------------

  @override
  Future<Result<CreatedDriver>> createDriver(NewDriver driver) =>
      _call('createDriver', driver.toJson(), (data) {
        return CreatedDriver(
          driverId: data['driverId'] as String? ?? '',
          temporaryPassword: data['temporaryPassword'] as String? ?? '',
        );
      });

  @override
  Future<Result<String>> registerDriver(DriverSignUp signUp) => _call(
        'registerDriver',
        signUp.toJson(),
        (data) => data['driverId'] as String? ?? '',
      );

  @override
  Future<Result<void>> updateDriver(String driverId, DriverUpdate update) =>
      _callVoid('updateDriver', {'driverId': driverId, ...update.toJson()});

  @override
  Future<Result<void>> deleteDriver(String driverId) =>
      _callVoid('deleteDriver', {'driverId': driverId});

  @override
  Future<Result<void>> confirmHeavyService({
    required String serviceId,
    required int totalCents,
    String note = '',
  }) =>
      _callVoid('confirmHeavyService', {
        'serviceId': serviceId,
        'totalCents': totalCents,
        'note': note,
      });

  @override
  Future<Result<void>> assignServiceManually({
    required String serviceId,
    required String driverId,
    String note = '',
  }) =>
      _callVoid('assignServiceManually', {
        'serviceId': serviceId,
        'driverId': driverId,
        if (note.isNotEmpty) 'note': note,
      });

  @override
  Future<Result<String>> createTruck(TruckDetails details) => _call(
        'createTruck',
        details.toJson(),
        (data) => data['truckId'] as String? ?? '',
      );

  @override
  Future<Result<void>> updateTruck(String truckId, TruckDetails details) =>
      _callVoid('updateTruck', {'truckId': truckId, ...details.toJson()});

  @override
  Future<Result<void>> archiveTruck(String truckId) =>
      _callVoid('archiveTruck', {'truckId': truckId});

  @override
  Future<Result<void>> setDriverStatus({
    required String driverId,
    required DriverStatus status,
    String reason = '',
  }) =>
      _callVoid('setDriverStatus', {
        'driverId': driverId,
        'status': status.wire,
        'reason': reason,
      });

  @override
  Future<Result<void>> attachDriverDocument({
    required String driverId,
    required DriverDocumentType type,
    required String storagePath,
    required String fileName,
    required String contentType,
    required int sizeBytes,
    DateTime? expiresAt,
  }) =>
      _callVoid('attachDriverDocument', {
        'driverId': driverId,
        'type': type.wire,
        'storagePath': storagePath,
        'fileName': fileName,
        'contentType': contentType,
        'sizeBytes': sizeBytes,
        'expiresAt': ?expiresAt?.toUtc().toIso8601String(),
      });

  @override
  Future<Result<String>> setDriverPhoto({
    required String driverId,
    required String storagePath,
  }) =>
      _call(
        'setDriverPhoto',
        {'driverId': driverId, 'storagePath': storagePath},
        (data) => data['photoUrl'] as String? ?? '',
      );

  @override
  Future<Result<LicenseVerificationState>> verifyDriverLicense() => _call(
        'verifyDriverLicense',
        {},
        (data) => LicenseVerificationState.fromWire(data['state'] as String?),
        // The model reads three photos; the function itself allows two minutes.
        timeout: const Duration(seconds: 120),
      );

  @override
  Future<Result<void>> correctDriverRegistration({
    required String name,
    required String cedula,
    required String licenseNumber,
    required DateTime licenseExpiry,
  }) =>
      _callVoid('correctDriverRegistration', {
        'name': name,
        'cedula': cedula,
        'licenseNumber': licenseNumber,
        'licenseExpiry': licenseExpiry.toUtc().toIso8601String(),
      });

  @override
  Future<Result<void>> reviewLicenseVerification({
    required String driverId,
    required bool approve,
    String reason = '',
  }) =>
      _callVoid('reviewLicenseVerification', {
        'driverId': driverId,
        'decision': approve ? 'approve' : 'reject',
        'reason': reason,
      });

  @override
  Future<Result<String>> invoiceDownloadUrl(String invoiceId) =>
      _call('invoiceDownloadUrl', {'invoiceId': invoiceId},
          (data) => data['url'] as String? ?? '');
}

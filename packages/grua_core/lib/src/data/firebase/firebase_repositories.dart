import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as fb;
// Firestore's `Query` is the one named in this file; RTDB's is only chained.
import 'package:firebase_database/firebase_database.dart' hide Query;
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';

import '../../calls/voice_call.dart';
import '../../domain/enums.dart';
import '../../domain/failures.dart';
import '../../domain/models/app_user.dart';
import '../../domain/models/billing.dart';
import '../../domain/models/chat_prefs.dart';
import '../../domain/models/chat_request.dart';
import '../../domain/models/dispatch_models.dart';
import '../../domain/models/driver.dart';
import '../../domain/models/driver_review.dart';
import '../../domain/models/insurer.dart';
import '../../domain/models/insurer_invoice.dart';
import '../../domain/models/payments.dart';
import '../../domain/models/pricing_rule.dart';
import '../../domain/models/remote_config_models.dart';
import '../../domain/models/service.dart';
import '../../domain/models/settlement.dart';
import '../../domain/models/truck.dart';
import '../../domain/repositories.dart';
import '../converters.dart';
import '../paths.dart';

/// Firestore-backed repositories.
///
/// Every one satisfies the same contract as its counterpart in `grua_testing`,
/// so switching between them is a provider override and no screen changes.
/// Two habits run through all of them:
///
/// * **Nothing writes a governed field.** There is no method here that sets a
///   service's status, a driver's assignment or a quote. Those go through
///   `FirebaseFunctionsGateway`, where being a remote call that can fail is
///   visible at the call site.
/// * **Every query is bounded.** No `snapshots()` without a `limit` or an
///   equality filter that keeps the result set small. An unbounded listener on
///   `services` is a bill that grows with the business.

/// Maps a thrown Firebase error onto a [Failure] the UI already knows how to
/// render, so no screen ever has to interpret a plugin exception.
Failure _mapError(Object error, {String? source}) {
  // Anything that lands on FailureCode.unknown reaches the user as a generic
  // "Algo salió mal", which is right for them and useless for us. Log the raw
  // plugin error in debug so the actual code is one glance away — and *where*
  // it came from: a bare "permission-denied" from one of dozens of listeners
  // and calls says a rule refused something without saying which.
  if (kDebugMode) {
    final code = switch (error) {
      fb.FirebaseAuthException(:final code) => code,
      FirebaseException(:final code) => code,
      _ => null,
    };
    final from = source == null ? '' : ' [$source]';
    debugPrint('[grua] Firebase error ${code ?? error.runtimeType}$from: $error');
  }

  if (error is fb.FirebaseAuthException) {
    return switch (error.code) {
      'invalid-verification-code' => const Failure(
          FailureCode.invalidInput,
          message: 'El código no es correcto. Revísalo e intenta de nuevo.',
        ),
      'session-expired' => const Failure(
          FailureCode.timeout,
          message: 'El código expiró. Pide uno nuevo.',
        ),
      'too-many-requests' => const Failure(
          FailureCode.invalidInput,
          message: 'Demasiados intentos. Espera unos minutos.',
        ),
      'quota-exceeded' => const Failure(
          FailureCode.unknown,
          message: 'No pudimos enviar el código. Intenta más tarde.',
        ),
      'invalid-phone-number' => const Failure(
          FailureCode.invalidInput,
          message: 'Ese número no parece válido.',
        ),
      'user-disabled' => const Failure(FailureCode.accountBlocked),
      'wrong-password' ||
      'invalid-credential' ||
      'user-not-found' =>
        const Failure(
          FailureCode.invalidInput,
          message: 'Usuario o contraseña incorrectos.',
        ),
      'network-request-failed' => const Failure(FailureCode.network),
      _ => Failure(FailureCode.unknown, cause: error),
    };
  }

  if (error is FirebaseException) {
    return switch (error.code) {
      'permission-denied' => const Failure(FailureCode.permissionDenied),
      // Storage's word for the same refusal. Every storage.rules match needs
      // an App Check token as well as a sign-in, so in a debug build this is
      // almost always an unregistered debug token.
      'unauthorized' => const Failure(
          FailureCode.permissionDenied,
          message: 'El almacenamiento rechazó el archivo (permiso denegado).',
        ),
      'unauthenticated' => const Failure(FailureCode.unauthenticated),
      'not-found' => const Failure(FailureCode.notFound),
      'unavailable' || 'deadline-exceeded' => const Failure(FailureCode.network),
      // Firestore's answer when a query needs a composite index that is not
      // published. That is a deployment problem, not the user's, and saying so
      // beats "algo salió mal" — the debug log above carries Google's own
      // message, which includes the link that creates the index.
      'failed-precondition' => const Failure(
          FailureCode.unknown,
          message: 'Falta un índice de la base de datos para esta consulta. '
              'Publica los índices con: firebase deploy --only '
              'firestore:indexes',
        ),
      _ => Failure(FailureCode.unknown, cause: error),
    };
  }

  if (error is TimeoutException) return const Failure(FailureCode.timeout);
  return Failure(FailureCode.unknown, cause: error);
}

/// Runs [action], turning any thrown Firebase error into a [Failure].
Future<Result<T>> _guard<T>(Future<T> Function() action) async {
  // Taken before the first await, while the repository method that called
  // this is still on the stack: after it, the trace is the SDK's, not ours.
  final origin = kDebugMode ? _callerOf(StackTrace.current) : null;
  try {
    return Result.ok(await action());
  } on Object catch (error) {
    return Result.err(_mapError(error, source: origin));
  }
}

/// The frame that called [_guard], trimmed to something readable in a log.
String? _callerOf(StackTrace trace) {
  final frames = trace.toString().split('\n').map((l) => l.trim());
  for (final frame in frames) {
    if (frame.isEmpty || frame.contains('_guard') || frame.contains('_callerOf')) {
      continue;
    }
    return frame.length > 160 ? frame.substring(0, 160) : frame;
  }
  return null;
}

extension _GuardedStream<T> on Stream<T> {
  /// Re-raises snapshot errors as [Failure]s.
  ///
  /// A listener that gets refused emits a raw `FirebaseException`, which no
  /// screen knows how to render — so a denied read arrived at the UI as an
  /// opaque object and every screen treated it as "no data yet". Mapping it
  /// here means a stream fails in the same vocabulary as a one-shot call.
  ///
  /// [source] names the listener in the debug log.
  Stream<T> guarded([String? source]) => handleError(
        (Object error) => throw _mapError(error, source: source),
        // Already a Failure: a second pass would bury the original code under
        // FailureCode.unknown.
        test: (error) => error is! Failure,
      );
}

// ---------------------------------------------------------------------------
// Auth
// ---------------------------------------------------------------------------

class FirebaseAuthRepository implements AuthRepository {
  FirebaseAuthRepository({fb.FirebaseAuth? auth})
      : _auth = auth ?? fb.FirebaseAuth.instance;

  final fb.FirebaseAuth _auth;

  /// Android can verify an SMS without the user typing anything. When that
  /// happens there is no code to confirm, so the credential is parked here and
  /// [confirmSmsCode] uses it instead of the digits.
  fb.PhoneAuthCredential? _autoRetrieved;

  @override
  String? get currentUserId => _auth.currentUser?.uid;

  @override
  Stream<String?> watchUserId() =>
      _auth.authStateChanges().map((user) => user?.uid);

  @override
  Future<UserRole> currentRole({bool forceRefresh = false}) async {
    final user = _auth.currentUser;
    if (user == null) return UserRole.unknown;
    final token = await user.getIdTokenResult(forceRefresh);
    return UserRole.fromWire(token.claims?['role'] as String?);
  }

  @override
  Future<String?> currentInsurerId({bool forceRefresh = false}) async {
    final user = _auth.currentUser;
    if (user == null) return null;
    final token = await user.getIdTokenResult(forceRefresh);
    final id = token.claims?['insurerId'];
    return id is String && id.isNotEmpty ? id : null;
  }

  @override
  Future<Result<String>> startPhoneVerification(String e164Phone) {
    final completer = Completer<Result<String>>();

    void finish(Result<String> result) {
      if (!completer.isCompleted) completer.complete(result);
    }

    unawaited(
      _auth.verifyPhoneNumber(
        phoneNumber: e164Phone,
        verificationCompleted: (credential) => _autoRetrieved = credential,
        verificationFailed: (error) => finish(Result.err(_mapError(error))),
        codeSent: (verificationId, _) => finish(Result.ok(verificationId)),
        codeAutoRetrievalTimeout: (verificationId) =>
            finish(Result.ok(verificationId)),
        timeout: const Duration(seconds: 60),
      ),
    );

    return completer.future;
  }

  @override
  Future<Result<void>> confirmSmsCode({
    required String verificationId,
    required String smsCode,
  }) =>
      _guard(() async {
        final credential = _autoRetrieved ??
            fb.PhoneAuthProvider.credential(
              verificationId: verificationId,
              smsCode: smsCode,
            );
        _autoRetrieved = null;
        await _auth.signInWithCredential(credential);
      });

  @override
  Future<Result<void>> signInWithEmail(String email, String password) =>
      _guard(() => _auth.signInWithEmailAndPassword(
            email: email,
            password: password,
          ));

  @override
  Future<Result<void>> sendPasswordReset(String email) =>
      _guard(() => _auth.sendPasswordResetEmail(email: email));

  @override
  Future<Result<void>> changePassword(String newPassword) => _guard(() async {
        final user = _auth.currentUser;
        if (user == null) throw const Failure(FailureCode.unauthenticated);
        await user.updatePassword(newPassword);
      });

  @override
  Future<void> signOut() => _auth.signOut();
}

// ---------------------------------------------------------------------------
// Users
// ---------------------------------------------------------------------------

class FirestoreUserRepository implements UserRepository {
  const FirestoreUserRepository();

  @override
  Stream<AppUser?> watchUser(String uid) =>
      Paths.user(uid).snapshots().map((snap) => snap.data()).guarded('watchUser');

  @override
  Stream<List<AppUser>> watchAllClients({int limit = 500}) => Paths.users()
      .orderBy('createdAt', descending: true)
      .limit(limit)
      .snapshots()
      // The role is filtered here rather than in the query on purpose. Adding
      // `where('role', ...)` would turn this into a composite index that has to
      // be deployed before the screen works at all, and it would buy nothing:
      // `ensureProfile` is the only writer of `users/`, choferes live in
      // `drivers/`, and an admin promoted from a customer account keeps
      // `role: client` on the document because `setAdminRole` only moves the
      // custom claim. The stored field is a hint, not the authority.
      .map(
        (snap) => snap.docs
            .map((d) => d.data())
            .where((user) => user.role == UserRole.client)
            .toList(),
      )
      .guarded('watchAllClients');

  @override
  Future<Result<AppUser>> fetchUser(String uid) => _guard(() async {
        final snap = await Paths.user(uid).get();
        final user = snap.data();
        if (user == null) throw const Failure(FailureCode.notFound);
        return user;
      });

  @override
  Future<Result<void>> updateProfile(
    String uid, {
    String? name,
    String? email,
    String? rnc,
    String? address,
    PaymentMethod? preferredPaymentMethod,
  }) =>
      // A map rather than the model: writing the whole document would touch
      // fields the security rules refuse, and the write would be rejected in
      // full rather than partially applied.
      _guard(() => Paths.user(uid).update({
            'name': ?name,
            'email': ?email,
            'rnc': ?rnc,
            'address': ?address,
            if (preferredPaymentMethod != null)
              'preferredPaymentMethod': preferredPaymentMethod.wire,
            'updatedAt': FieldValue.serverTimestamp(),
          }));

  @override
  Stream<List<ServiceVehicle>> watchVehicles(String uid) => Paths.userVehicles(uid)
      .orderBy('updatedAt', descending: true)
      .limit(20)
      .snapshots()
      .map(
        (snap) => snap.docs
            .map((doc) => ServiceVehicle.fromJson(doc.data()))
            .toList(),
      );

  @override
  Future<Result<void>> saveVehicle(
    String uid,
    ServiceVehicle vehicle, {
    String id = UserRepository.primaryVehicleId,
  }) =>
      // set, not update: the document may not exist yet, and the rules let a
      // customer own this subcollection outright.
      _guard(
        () => Paths.userVehicles(uid).doc(id).set({
          ...vehicle.toJson(),
          'updatedAt': FieldValue.serverTimestamp(),
        }),
      );

  @override
  Future<Result<void>> registerFcmToken(
    String uid,
    String token,
    String platform,
  ) =>
      // Keyed by the token itself, so re-registering the same device is an
      // overwrite rather than a duplicate.
      _guard(() => Paths.userTokens(uid).doc(token).set({
            'platform': platform,
            'updatedAt': FieldValue.serverTimestamp(),
          }));

  @override
  Future<Result<void>> removeFcmToken(String uid, String token) =>
      _guard(() => Paths.userTokens(uid).doc(token).delete());
}

// ---------------------------------------------------------------------------
// Drivers and live positions
// ---------------------------------------------------------------------------

class FirebaseDriverRepository implements DriverRepository {
  FirebaseDriverRepository({FirebaseDatabase? database})
      : _database = database ?? FirebaseDatabase.instance;

  final FirebaseDatabase _database;

  @override
  Stream<Driver?> watchDriver(String uid) =>
      Paths.driver(uid).snapshots().map((snap) => snap.data()).guarded('watchDriver');

  @override
  Stream<List<Driver>> watchAllDrivers({DriverStatus? status}) {
    var query = Paths.drivers().orderBy('name');
    if (status != null) query = query.where('status', isEqualTo: status.wire);
    // A tow company's fleet is tens of trucks, not thousands; the cap is here
    // so a data-entry accident cannot turn the roster into an unbounded read.
    return query
        .limit(500)
        .snapshots()
        .map((snap) => snap.docs.map((d) => d.data()).toList())
        .guarded('watchAllDrivers');
  }

  @override
  Stream<List<DriverReview>> watchReviews({
    String? driverId,
    bool openOnly = false,
    int limit = 50,
  }) {
    Query<DriverReview> query = Paths.driverReviews();
    // Each filter has its composite index with ratedAt in
    // firestore.indexes.json.
    if (driverId != null) query = query.where('driverId', isEqualTo: driverId);
    if (openOnly) {
      query = query.where('status', isEqualTo: DriverReviewStatus.open.wire);
    }
    return query
        .orderBy('ratedAt', descending: true)
        .limit(limit)
        .snapshots()
        .map((snap) => snap.docs.map((d) => d.data()).toList())
        .guarded('watchReviews');
  }

  @override
  Future<Result<Driver>> fetchDriver(String uid) => _guard(() async {
        final snap = await Paths.driver(uid).get();
        final driver = snap.data();
        if (driver == null) throw const Failure(FailureCode.notFound);
        return driver;
      });

  @override
  Stream<List<DriverDocument>> watchDocuments(String uid) =>
      Paths.driverDocuments(uid).snapshots().map(
            (snap) => snap.docs.map((d) => d.data()).toList(),
          );

  @override
  Future<void> publishLivePosition(DriverLivePosition position) {
    final json = position.toJson()..remove('driverId');

    // A stationary phone may report heading and speed as NaN, and the SDK
    // refuses the whole write over one non-finite number.
    for (final key in const ['heading', 'speedKmh', 'accuracy']) {
      final value = json[key];
      if (value is double && !value.isFinite) json[key] = 0;
    }

    // The server's clock, not the phone's. Every staleness rule — dispatch,
    // the customer's nearby search, the sweep — compares this with server
    // time, and a phone two minutes slow would otherwise read as a truck that
    // stopped reporting.
    json['updatedAt'] = ServerValue.timestamp;

    return Paths.live(position.driverId).set(json);
  }

  @override
  Stream<List<DriverLivePosition>> watchLivePositions() =>
      // Only the online subtree: an admin panel does not need to stream the
      // whole fleet's history of last-known positions.
      _database
          .ref('live')
          .orderByChild('isOnline')
          .equalTo(true)
          .onValue
          .map((event) {
        final raw = event.snapshot.value;
        if (raw is! Map) return const <DriverLivePosition>[];

        return raw.entries
            .map((entry) {
              final value = entry.value;
              if (value is! Map) return null;
              return DriverLivePosition.fromJson({
                ...Map<String, dynamic>.from(value),
                'driverId': entry.key.toString(),
              });
            })
            .whereType<DriverLivePosition>()
            .toList();
      });

  /// How long a presence write may wait for the server. RTDB queues writes
  /// while offline and only completes them on reconnect, so an unbounded await
  /// here would hold a sign-out hostage to the signal.
  static const _presenceTimeout = Duration(seconds: 3);

  static Map<String, Object> _presenceValue({required bool connected}) => {
        'connected': connected,
        'lastChanged': ServerValue.timestamp,
      };

  @override
  Stream<void> holdAppPresence(String uid) {
    final ref = Paths.presence(uid);
    StreamSubscription<DatabaseEvent>? connection;
    late final StreamController<void> controller;

    controller = StreamController<void>(
      onListen: () {
        // `.info/connected` turns true again on every reconnect, and the
        // server forgets an onDisconnect once it has fired, so both writes are
        // redone each time rather than once at start-up.
        connection = Paths.connectionState().onValue.listen(
          (event) async {
            if (event.snapshot.value != true) return;
            try {
              // Queued before the write: if the connection dies between the
              // two, the node is never left saying connected.
              await ref.onDisconnect().set(_presenceValue(connected: false));
              await ref.set(_presenceValue(connected: true));
            } on Object catch (error, stack) {
              if (!controller.isClosed) controller.addError(error, stack);
            }
          },
          onError: controller.addError,
        );
      },
      onCancel: () async {
        await connection?.cancel();
        await clearAppPresence(uid);
      },
    );
    return controller.stream;
  }

  @override
  Future<void> clearAppPresence(String uid) async {
    try {
      // The queued onDisconnect is left in place: it writes the same value,
      // and it still fires if this write never reaches the server.
      await Paths.presence(uid)
          .set(_presenceValue(connected: false))
          .timeout(_presenceTimeout);
    } on Object catch (error) {
      // Already signed out, or no signal. Either way the onDisconnect queued
      // by [holdAppPresence] clears the node when the connection closes.
      debugPrint('Presence not cleared: $error');
    }
  }

  @override
  Stream<Set<String>> watchConnectedDriverIds() => Paths.presenceRoot()
          .orderByChild('connected')
          .equalTo(true)
          .onValue
          .map((event) {
        final raw = event.snapshot.value;
        if (raw is! Map) return const <String>{};
        return raw.keys.map((key) => key.toString()).toSet();
      });

  @override
  Future<Result<String>> uploadDocument({
    required String driverId,
    required DriverDocumentType type,
    required Uint8List bytes,
    required String fileName,
    required String contentType,
  }) =>
      _guard(() async {
        final dot = fileName.lastIndexOf('.');
        final ext = dot == -1 ? 'jpg' : fileName.substring(dot + 1).toLowerCase();
        final path = Paths.driverDocPath(driverId, type, ext);

        await FirebaseStorage.instance.ref(path).putData(
              bytes,
              SettableMetadata(
                contentType: contentType,
                // Kept so a reviewer downloading the file gets the name the
                // office uploaded rather than the timestamped object key.
                customMetadata: {'originalName': fileName},
              ),
            );
        return path;
      });

  @override
  Future<Result<String>> documentUrl(String storagePath) =>
      _guard(() => FirebaseStorage.instance.ref(storagePath).getDownloadURL());

  @override
  Future<Result<String>> uploadDriverPhoto({
    required String driverId,
    required Uint8List bytes,
    required String contentType,
  }) =>
      _guard(() async {
        final ext = switch (contentType) {
          'image/png' => 'png',
          'image/webp' => 'webp',
          _ => 'jpg',
        };
        final path = Paths.driverPhotoPath(driverId, ext);

        await FirebaseStorage.instance.ref(path).putData(
              bytes,
              SettableMetadata(
                contentType: contentType,
                // Every upload is a new timestamped object, so a long cache
                // can never serve a replaced face.
                cacheControl: 'private, max-age=604800',
              ),
            );
        return path;
      });
}

// ---------------------------------------------------------------------------
// Trucks
// ---------------------------------------------------------------------------

class FirestoreTruckRepository implements TruckRepository {
  const FirestoreTruckRepository();

  @override
  Stream<List<Truck>> watchTrucks({bool activeOnly = false}) {
    var query = Paths.trucks().orderBy('plate');
    if (activeOnly) query = query.where('active', isEqualTo: true);
    return query.limit(500).snapshots().map(
          (snap) => snap.docs.map((d) => d.data()).toList(),
        );
  }

  @override
  Stream<Truck?> watchTruck(String id) =>
      Paths.truck(id).snapshots().map((snap) => snap.data());

  @override
  Future<Result<Truck>> fetchTruck(String id) => _guard(() async {
        final snap = await Paths.truck(id).get();
        final truck = snap.data();
        if (truck == null) throw const Failure(FailureCode.notFound);
        return truck;
      });
}

// ---------------------------------------------------------------------------
// Services
// ---------------------------------------------------------------------------

class FirestoreServiceRepository implements ServiceRepository {
  const FirestoreServiceRepository();

  static final List<String> _activeWire =
      ServiceStatus.active.map((s) => s.wire).toList(growable: false);

  @override
  Stream<Service?> watchService(String id) =>
      Paths.service(id).snapshots().map((snap) => snap.data());

  @override
  Future<Result<String>> uploadVehiclePhoto({
    required String clientId,
    required Uint8List bytes,
    required String contentType,
  }) =>
      _guard(() async {
        final ext = switch (contentType) {
          'image/png' => 'png',
          'image/webp' => 'webp',
          'image/heic' => 'heic',
          _ => 'jpg',
        };
        final ref = FirebaseStorage.instance.ref(
          'requests/$clientId/${DateTime.now().microsecondsSinceEpoch}.$ext',
        );
        await ref.putData(
          bytes,
          SettableMetadata(
            contentType: contentType,
            cacheControl: 'private, max-age=604800',
          ),
        );
        // The URL, not the path: the chofer's app shows it as-is, and its
        // token is what lets them read a file in another person's folder.
        return await ref.getDownloadURL();
      });

  @override
  Future<Result<String>> uploadServicePhoto({
    required String serviceId,
    required ServicePhotoStage stage,
    required Uint8List bytes,
    required String contentType,
  }) =>
      _guard(() async {
        final ext = switch (contentType) {
          'image/png' => 'png',
          'image/webp' => 'webp',
          'image/heic' => 'heic',
          _ => 'jpg',
        };
        final ref = FirebaseStorage.instance.ref(
          Paths.servicePhotoPath(
            serviceId,
            '${stage.wire}_${DateTime.now().microsecondsSinceEpoch}.$ext',
          ),
        );
        await ref.putData(
          bytes,
          SettableMetadata(
            contentType: contentType,
            cacheControl: 'private, max-age=604800',
          ),
        );
        // The path, not a download URL: a URL's token would let anyone who
        // saw the service record open the photo, and only the office may.
        return ref.fullPath;
      });

  @override
  Future<Result<String>> servicePhotoUrl(String path) => _guard(
        () => FirebaseStorage.instance.ref(path).getDownloadURL(),
      );

  @override
  Stream<Service?> watchActiveForClient(String clientId) => Paths.services()
      .where('clientId', isEqualTo: clientId)
      .where('status', whereIn: _activeWire)
      .orderBy('createdAt', descending: true)
      .limit(1)
      .snapshots()
      .map((snap) => snap.docs.isEmpty ? null : snap.docs.first.data());

  @override
  Stream<Service?> watchActiveForDriver(String driverId) => Paths.services()
      .where('driverId', isEqualTo: driverId)
      .where('status', whereIn: _activeWire)
      .orderBy('createdAt', descending: true)
      .limit(1)
      .snapshots()
      .map((snap) => snap.docs.isEmpty ? null : snap.docs.first.data());

  @override
  Stream<List<Service>> watchActiveServices() => Paths.services()
      .where('status', whereIn: _activeWire)
      // Newest first, because that is the *deployed* index — `status ASC,
      // createdAt DESC`, the same one the customer's own "do I have a job in
      // flight" query uses. Ascending needs a second composite index nobody
      // published, so this listener failed on every project: the dispatcher's
      // panel drew an empty roster while a customer sat on the shoulder
      // watching "Buscando grúa". The order here only decides which jobs the
      // limit keeps; the panel sorts what it gets, needs_manual first and then
      // oldest.
      .orderBy('createdAt', descending: true)
      // A dispatcher who genuinely has 200 open jobs has a staffing problem,
      // not a pagination problem — but the cap keeps the listener bounded.
      .limit(200)
      .snapshots()
      .map((snap) => snap.docs.map((d) => d.data()).toList())
      .guarded('watchActiveServices');

  @override
  Stream<List<Service>> watchInsurerServices(
    String insurerId, {
    DateTime? since,
    int limit = 200,
  }) {
    // Filtered on the company: the rules refuse the query otherwise.
    var query =
        Paths.services().where('insurerId', isEqualTo: insurerId);
    if (since != null) {
      query = query.where(
        'createdAt',
        isGreaterThanOrEqualTo: Timestamp.fromDate(since),
      );
    }
    return query
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .snapshots()
        .map((snap) => snap.docs.map((d) => d.data()).toList())
        .guarded('watchInsurerServices');
  }

  @override
  Future<Result<List<Service>>> findInsurerServicesByClaim(
    String insurerId,
    String claimKey,
  ) =>
      _guard(() async {
        final snap = await Paths.services()
            .where('insurerId', isEqualTo: insurerId)
            .where('insurance.claimKey', isEqualTo: claimKey)
            .limit(20)
            .get();
        return snap.docs.map((d) => d.data()).toList();
      });

  @override
  Stream<List<ServiceEvent>> watchEvents(String serviceId) =>
      Paths.events(serviceId).orderBy('at').limit(100).snapshots().map(
            (snap) => snap.docs.map((d) => d.data()).toList(),
          );

  @override
  Stream<ServiceTracking?> watchTracking(String serviceId) =>
      Paths.trackingFor(serviceId).snapshots().map((snap) => snap.data());

  @override
  Future<Result<PagedServices>> fetchServices({
    Set<ServiceStatus>? statuses,
    DateTime? from,
    DateTime? to,
    int limit = 50,
    Object? cursor,
  }) =>
      _guard(() async {
        Query<Service> query = Paths.services();
        if (statuses != null && statuses.isNotEmpty) {
          query = query.where(
            'status',
            whereIn: statuses.map((s) => s.wire).toList(),
          );
        }
        if (from != null) {
          query = query.where(
            'createdAt',
            isGreaterThanOrEqualTo: Timestamp.fromDate(from),
          );
        }
        if (to != null) {
          query = query.where('createdAt', isLessThan: Timestamp.fromDate(to));
        }
        query = query.orderBy('createdAt', descending: true).limit(limit);
        if (cursor is DocumentSnapshot) {
          query = query.startAfterDocument(cursor);
        }

        final snap = await query.get();
        return PagedServices(
          items: snap.docs.map((d) => d.data()).toList(),
          cursor: snap.docs.isEmpty ? null : snap.docs.last,
          hasMore: snap.docs.length == limit,
        );
      });

  @override
  Future<Result<Service?>> fetchServiceByCode(String code) => _guard(() async {
        final snap = await Paths.services()
            .where('code', isEqualTo: code.trim().toUpperCase())
            .limit(1)
            .get();
        return snap.docs.isEmpty ? null : snap.docs.first.data();
      });

  @override
  Future<Result<PagedServices>> fetchHistory({
    required String userId,
    required UserRole role,
    int limit = 20,
    Object? cursor,
  }) =>
      _guard(() async {
        var query = Paths.services()
            .where(
              role == UserRole.driver ? 'driverId' : 'clientId',
              isEqualTo: userId,
            )
            .orderBy('createdAt', descending: true)
            .limit(limit);

        // The cursor is the previous page's last snapshot. Callers treat it as
        // opaque, which is what lets the test implementation use an int.
        if (cursor is DocumentSnapshot) {
          query = query.startAfterDocument(cursor);
        }

        final snap = await query.get();
        return PagedServices(
          items: snap.docs.map((d) => d.data()).toList(),
          cursor: snap.docs.isEmpty ? null : snap.docs.last,
          hasMore: snap.docs.length == limit,
        );
      });
}

class FirestoreOfferRepository implements OfferRepository {
  const FirestoreOfferRepository();

  @override
  Stream<Offer?> watchIncomingOffer(String driverId) =>
      // A collection-group query because an offer lives under the service it
      // belongs to, and the chofer does not know which service that is until
      // it arrives.
      FirebaseFirestore.instance
          .collectionGroup(Paths.offersSubcollection)
          .where('driverId', isEqualTo: driverId)
          .where('state', isEqualTo: OfferState.sent.wire)
          .limit(1)
          .snapshots()
          .map((snap) {
        if (snap.docs.isEmpty) return null;
        final doc = snap.docs.first;
        return Offer.fromJson({
          ...doc.data(),
          'driverId': doc.id,
          // services/{serviceId}/offers/{driverId}
          'serviceId': doc.reference.parent.parent?.id ?? '',
        });
      })
          // A chofer who believes they are online and is quietly receiving
          // nothing is the worst state this app has. A refused or unindexed
          // collection-group query used to arrive here as an opaque error and
          // read as "no offers" — indistinguishable from a quiet night.
          .guarded('watchIncomingOffer');

  @override
  Stream<Offer?> watchOffer(String serviceId, String driverId) => Paths
      .offer(serviceId, driverId)
      .snapshots()
      .map((snap) => snap.data())
      .guarded('watchOffer');
}

class FirestoreCallRepository implements CallRepository {
  const FirestoreCallRepository();

  static CollectionReference<Map<String, dynamic>> get _calls =>
      FirebaseFirestore.instance.collection('calls');

  @override
  Stream<VoiceCall?> watchIncomingCall(String uid) => _calls
      .where('calleeId', isEqualTo: uid)
      .where('state', isEqualTo: CallState.ringing.wire)
      .limit(5)
      .snapshots()
      .map((snap) {
        final calls = snap.docs
            .map((d) => VoiceCall.fromJson(d.id, d.data()))
            // A caller who vanished mid-ring leaves the document ringing until
            // the server hears otherwise; nobody is on the other end of it.
            .where((c) => !c.isStale(DateTime.now().toUtc()))
            .toList();
        return calls.isEmpty ? null : calls.first;
      })
      .guarded('watchIncomingCall');

  @override
  Stream<VoiceCall?> watchCall(String callId) => _calls
      .doc(callId)
      .snapshots()
      .map((snap) {
        final data = snap.data();
        return data == null ? null : VoiceCall.fromJson(snap.id, data);
      })
      .guarded('watchCall');
}

class FirestoreChatRepository implements ChatRepository {
  const FirestoreChatRepository();

  @override
  Stream<List<ChatMessage>> watchMessages(String serviceId, {int limit = 100}) =>
      Paths.messages(serviceId)
          .orderBy('sentAt')
          .limit(limit)
          .snapshots()
          .map((snap) => snap.docs.map((d) => d.data()).toList());

  @override
  Future<Result<void>> sendMessage({
    required String serviceId,
    required String senderId,
    required UserRole senderRole,
    required String text,
    required String clientMsgId,
    String imageUrl = '',
  }) =>
      // Keyed by clientMsgId so a retry on bad signal overwrites rather than
      // duplicating. The field set matches the security rule exactly; anything
      // extra is rejected.
      _guard(() => Paths.messageWrites(serviceId).doc(clientMsgId).set({
            'senderId': senderId,
            'senderRole': senderRole.wire,
            'text': text.trim(),
            'clientMsgId': clientMsgId,
            'sentAt': FieldValue.serverTimestamp(),
            // Written as null rather than left out: a field that is absent is
            // not matched by a query for it, and "mark this read" would pass
            // the message by.
            'readAt': null,
            if (imageUrl.isNotEmpty) 'imageUrl': imageUrl,
          }));

  @override
  Future<Result<void>> deleteMessages({
    required String serviceId,
    required String senderId,
    required List<String> messageIds,
  }) =>
      _retractMessages(Paths.messageWrites(serviceId), messageIds);

  @override
  Future<Result<String>> uploadImage({
    required String serviceId,
    required Uint8List bytes,
    required String contentType,
  }) =>
      _uploadChatImage(
        threadId: serviceId,
        bytes: bytes,
        contentType: contentType,
      );

  @override
  Future<Result<void>> markRead(String serviceId, String readerId) =>
      _guard(() async {
        // The last page of the conversation, rather than a query for unread
        // ones. `where('readAt', isNull: true)` only matches documents that
        // carry the field, and every message sent before this shipped has no
        // `readAt` at all — so the query came back empty and the badge never
        // cleared, however many times the chofer opened the chat.
        final recent = await Paths.messages(serviceId)
            .orderBy('sentAt', descending: true)
            .limit(50)
            .get();

        final batch = FirebaseFirestore.instance.batch();
        var pending = 0;
        for (final doc in recent.docs) {
          final message = doc.data();
          if (message.senderId == readerId || message.isRead) continue;
          batch.update(doc.reference, {'readAt': FieldValue.serverTimestamp()});
          pending++;
        }
        if (pending == 0) return;
        await batch.commit();
      });
}

// ---------------------------------------------------------------------------
// Money
// ---------------------------------------------------------------------------


/// The write a retraction is: blank the content, stamp the time. Kept in one
/// place because `firestore.rules` matches on exactly these three fields.
Future<Result<void>> _retractMessages(
  CollectionReference<Map<String, dynamic>> messages,
  List<String> messageIds,
) =>
    _guard(() async {
      if (messageIds.isEmpty) return;
      final batch = FirebaseFirestore.instance.batch();
      for (final id in messageIds.take(50)) {
        batch.update(messages.doc(id), {
          'text': '',
          'imageUrl': '',
          'deletedAt': FieldValue.serverTimestamp(),
        });
      }
      await batch.commit();
    });

/// One photo into `chat/{threadId}/`, shared by both conversations.
///
/// The download URL is what travels in the message: Storage lets any signed-in
/// user read these objects, and the token in the URL is what keeps a photo to
/// the conversation it was sent in.
Future<Result<String>> _uploadChatImage({
  required String threadId,
  required Uint8List bytes,
  required String contentType,
}) =>
    _guard(() async {
      final ext = switch (contentType) {
        'image/png' => 'png',
        'image/webp' => 'webp',
        'image/heic' => 'heic',
        _ => 'jpg',
      };
      final ref = FirebaseStorage.instance
          .ref('chat/$threadId/${DateTime.now().millisecondsSinceEpoch}.$ext');

      await ref.putData(
        bytes,
        SettableMetadata(
          contentType: contentType,
          cacheControl: 'private, max-age=604800',
        ),
      );
      final url = await ref.getDownloadURL();
      return url;
    });

class FirestoreChatRequestRepository implements ChatRequestRepository {
  const FirestoreChatRequestRepository();

  @override
  Stream<List<ChatRequest>> watchForDriver(String driverId, {int limit = 20}) =>
      Paths.chatRequests()
          .where('driverId', isEqualTo: driverId)
          .orderBy('createdAt', descending: true)
          .limit(limit)
          .snapshots()
          .map((snap) => snap.docs.map((d) => d.data()).toList());

  @override
  Stream<List<ChatRequest>> watchForClient(String clientId, {int limit = 10}) =>
      Paths.chatRequests()
          .where('clientId', isEqualTo: clientId)
          .orderBy('createdAt', descending: true)
          .limit(limit)
          .snapshots()
          .map((snap) => snap.docs.map((d) => d.data()).toList());

  @override
  Stream<ChatRequest?> watchRequest(String requestId) =>
      Paths.chatRequest(requestId).snapshots().map((snap) => snap.data());

  @override
  Stream<List<ChatMessage>> watchMessages(String requestId, {int limit = 100}) =>
      Paths.chatRequestMessages(requestId)
          .orderBy('sentAt')
          .limit(limit)
          .snapshots()
          .map((snap) => snap.docs.map((d) => d.data()).toList());

  @override
  Future<Result<void>> sendMessage({
    required String requestId,
    required String senderId,
    required UserRole senderRole,
    required String text,
    required String clientMsgId,
    String imageUrl = '',
  }) =>
      // Keyed by clientMsgId, as on a job's chat, so a retry overwrites.
      _guard(
        () => Paths.chatRequestMessageWrites(requestId).doc(clientMsgId).set({
          'senderId': senderId,
          'senderRole': senderRole.wire,
          'text': text.trim(),
          'clientMsgId': clientMsgId,
          'sentAt': FieldValue.serverTimestamp(),
          // See the job chat's sender: absent is not the same as null.
          'readAt': null,
          if (imageUrl.isNotEmpty) 'imageUrl': imageUrl,
        }),
      );

  @override
  Future<Result<void>> deleteMessages({
    required String requestId,
    required String senderId,
    required List<String> messageIds,
  }) =>
      _retractMessages(Paths.chatRequestMessageWrites(requestId), messageIds);

  @override
  Future<Result<String>> uploadImage({
    required String requestId,
    required Uint8List bytes,
    required String contentType,
  }) =>
      _uploadChatImage(
        threadId: requestId,
        bytes: bytes,
        contentType: contentType,
      );

  @override
  Future<Result<void>> markRead(String requestId, String readerId) =>
      _guard(() async {
        // As on a job's chat: read the last page and stamp what this reader
        // has not seen, rather than querying a field older messages lack.
        final recent = await Paths.chatRequestMessages(requestId)
            .orderBy('sentAt', descending: true)
            .limit(50)
            .get();

        final batch = FirebaseFirestore.instance.batch();
        var pending = 0;
        for (final doc in recent.docs) {
          final message = doc.data();
          if (message.senderId == readerId || message.isRead) continue;
          batch.update(doc.reference, {'readAt': FieldValue.serverTimestamp()});
          pending++;
        }
        if (pending == 0) return;
        await batch.commit();
      });
}

/// Each person's own view of their conversations, under their user document.
///
/// Nothing here is readable by the other side: the rules give the whole
/// subtree to its owner and to nobody else.
class FirestoreChatPrefsRepository implements ChatPrefsRepository {
  const FirestoreChatPrefsRepository();

  @override
  Stream<ChatThreadPrefs> watchThread({
    required String uid,
    required String threadKey,
  }) =>
      Paths.userChatStateDoc(uid, threadKey).snapshots().map((snap) {
        final data = snap.data();
        return data == null ? ChatThreadPrefs.none : ChatThreadPrefs.fromJson(data);
      });

  @override
  Stream<Map<String, ChatThreadPrefs>> watchThreads(String uid) =>
      Paths.userChatState(uid).snapshots().map((snap) => {
            for (final doc in snap.docs) doc.id: ChatThreadPrefs.fromJson(doc.data()),
          });

  @override
  Stream<Set<String>> watchBlocked(String uid) => Paths.userBlocked(uid)
      .snapshots()
      .map((snap) => {for (final doc in snap.docs) doc.id});

  @override
  Stream<bool> watchBlockedBy({
    required String uid,
    required String otherUid,
  }) =>
      Paths.userBlockedDoc(otherUid, uid).snapshots().map((snap) => snap.exists);

  @override
  Future<Result<void>> clearThread({
    required String uid,
    required String threadKey,
  }) =>
      _guard(() => Paths.userChatStateDoc(uid, threadKey).set(
            {'clearedAt': FieldValue.serverTimestamp()},
            SetOptions(merge: true),
          ));

  @override
  Future<Result<void>> deleteThread({
    required String uid,
    required String threadKey,
  }) =>
      _guard(() => Paths.userChatStateDoc(uid, threadKey).set(
            {
              // Deleting hides what was said as well as the conversation, so
              // reopening it on a new message does not bring the old back.
              'clearedAt': FieldValue.serverTimestamp(),
              'deletedAt': FieldValue.serverTimestamp(),
            },
            SetOptions(merge: true),
          ));

  @override
  Future<Result<void>> setBlocked({
    required String uid,
    required String otherUid,
    required bool blocked,
  }) =>
      _guard(() async {
        final doc = Paths.userBlockedDoc(uid, otherUid);
        if (!blocked) {
          await doc.delete();
          return;
        }
        await doc.set({'blockedAt': FieldValue.serverTimestamp()});
      });
}

/// The typing indicator, in the Realtime Database.
///
/// A keystroke writes a timestamp and the server clears it if the phone drops
/// off. Readers ignore anything older than [_freshness], so a flag left behind
/// by a lost connection stops claiming somebody is still typing.
class FirebaseTypingRepository implements TypingRepository {
  const FirebaseTypingRepository();

  static const _freshness = Duration(seconds: 8);

  @override
  Stream<Set<String>> watchTyping(String threadKey) =>
      Paths.typing(threadKey).onValue.map((event) {
        final value = event.snapshot.value;
        if (value is! Map) return const <String>{};

        final now = DateTime.now().millisecondsSinceEpoch;
        return {
          for (final entry in value.entries)
            if (entry.value is num &&
                now - (entry.value! as num).toInt() < _freshness.inMilliseconds)
              '${entry.key}',
        };
      });

  @override
  Future<void> setTyping({
    required String threadKey,
    required String uid,
    required bool typing,
  }) async {
    final ref = Paths.typingBy(threadKey, uid);
    try {
      if (!typing) {
        await ref.remove();
        return;
      }
      // Set before the write, so a phone that dies mid-sentence is cleared by
      // the server rather than leaving the other side waiting.
      await ref.onDisconnect().remove();
      await ref.set(DateTime.now().millisecondsSinceEpoch);
    } on Object catch (error) {
      // An indicator nobody can see is not worth an error on screen.
      debugPrint('Typing flag not published: $error');
    }
  }
}

class FirestoreInsurerRepository implements InsurerRepository {
  const FirestoreInsurerRepository();

  @override
  Stream<List<Insurer>> watchInsurers() => Paths.insurers()
      .orderBy('name')
      .snapshots()
      .map((snap) => snap.docs.map((d) => d.data()).toList())
      .guarded('watchInsurers');

  @override
  Stream<Insurer?> watchInsurer(String id) => Paths.insurer(id)
      .snapshots()
      .map((snap) => snap.data())
      .guarded('watchInsurer');

  @override
  Stream<InsurerMember?> watchMember(String insurerId, String uid) => Paths
      .insurerMember(insurerId, uid)
      .snapshots()
      .map((snap) => snap.data())
      .guarded('watchInsurerMember');

  @override
  Stream<List<InsurerMember>> watchMembers(String insurerId) => Paths
      .insurerMembers(insurerId)
      .orderBy('name')
      .snapshots()
      .map((snap) => snap.docs.map((d) => d.data()).toList())
      .guarded('watchInsurerMembers');

  @override
  Stream<List<PricingRule>> watchPricingRules({String? insurerId}) {
    final rules = Paths.pricingRules();
    // The default list is the rows with no company; the rules only admit a
    // query that says which it wants.
    final query = insurerId == null
        ? rules.where('insurerId', isNull: true)
        : rules.where('insurerId', isEqualTo: insurerId);
    return query
        .snapshots()
        .map((snap) => snap.docs.map((d) => d.data()).toList())
        .guarded('watchPricingRules');
  }

  @override
  Stream<List<InsurerInvoice>> watchInvoices({String? insurerId, int limit = 200}) {
    Query<InsurerInvoice> query = Paths.insurerInvoices();
    if (insurerId != null) query = query.where('insurerId', isEqualTo: insurerId);
    return query
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .snapshots()
        .map((snap) => snap.docs.map((d) => d.data()).toList())
        .guarded('watchInsurerInvoices');
  }

  @override
  Stream<InsurerInvoice?> watchInvoice(String id) => Paths.insurerInvoice(id)
      .snapshots()
      .map((snap) => snap.data())
      .guarded('watchInsurerInvoice');

  @override
  Stream<FiscalIssuer> watchFiscalIssuer() => Paths.fiscalIssuer()
      .snapshots()
      .map((snap) => FiscalIssuer.fromJson(snap.data()))
      .guarded('watchFiscalIssuer');

  @override
  Stream<NcfSequence> watchNcfSequence(String prefix) => Paths.ncfSequence(prefix)
      .snapshots()
      .map((snap) => NcfSequence.fromJson(prefix, snap.data()))
      .guarded('watchNcfSequence');

  @override
  Stream<List<Service>> watchServicesToInvoice({String? insurerId}) {
    var query = Paths.services()
        .where('payment.status', isEqualTo: PaymentStatus.toInvoice.wire);
    if (insurerId != null) query = query.where('insurerId', isEqualTo: insurerId);
    return query
        .limit(2000)
        .snapshots()
        .map((snap) => snap.docs.map((d) => d.data()).toList())
        .guarded('watchServicesToInvoice');
  }
}

class FirestoreEarningsRepository implements EarningsRepository {
  const FirestoreEarningsRepository();

  @override
  Stream<EarningsSummary?> watchSummary(String driverId) =>
      Paths.earningsSummary(driverId).snapshots().map((snap) => snap.data());

  @override
  Future<Result<List<EarningEntry>>> fetchEntries({
    required String driverId,
    required DateTime from,
    required DateTime to,
  }) =>
      _guard(() async {
        final snap = await Paths.earningEntries(driverId)
            .where('completedAt',
                isGreaterThanOrEqualTo: Timestamp.fromDate(from))
            .where('completedAt', isLessThan: Timestamp.fromDate(to))
            .orderBy('completedAt', descending: true)
            .limit(500)
            .get();
        return snap.docs.map((d) => d.data()).toList();
      });

  @override
  Stream<List<CashSettlement>> watchCashSettlements({
    String? driverId,
    int limit = 50,
  }) {
    Query<CashSettlement> query = Paths.cashSettlements();
    if (driverId != null) query = query.where('driverId', isEqualTo: driverId);
    return query
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .snapshots()
        .map((snap) => snap.docs.map((d) => d.data()).toList())
        .guarded('watchCashSettlements');
  }

  @override
  Stream<List<DriverSettlement>> watchDriverSettlements({
    String? driverId,
    SettlementStatus? status,
    int limit = 50,
  }) {
    Query<DriverSettlement> query = Paths.driverSettlements();
    if (driverId != null) query = query.where('driverId', isEqualTo: driverId);
    if (status != null) query = query.where('status', isEqualTo: status.wire);
    return query
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .snapshots()
        .map((snap) => snap.docs.map((d) => d.data()).toList())
        .guarded('watchDriverSettlements');
  }

  @override
  Stream<DriverSettlement?> watchDriverSettlement(String id) => Paths
      .driverSettlement(id)
      .snapshots()
      .map((snap) => snap.data())
      .guarded('watchDriverSettlement');

  @override
  Stream<List<EarningEntry>> watchUnsettledEntries(String driverId, {DateTime? since}) {
    var query = Paths.earningEntries(driverId).where('settled', isEqualTo: false);
    if (since != null) {
      query = query.where('completedAt', isGreaterThanOrEqualTo: Timestamp.fromDate(since));
    }
    return query
          .orderBy('completedAt')
          .limit(400)
          .snapshots()
          .map((snap) => snap.docs.map((d) => d.data()).toList())
          .guarded('watchUnsettledEntries');
  }

  @override
  Stream<List<Service>> watchUncountedCash(String driverId) => Paths.services()
      // Equality on both: served by the single-field indexes, no composite.
      .where('driverId', isEqualTo: driverId)
      .where('payment.status', isEqualTo: PaymentStatus.cashCollected.wire)
      .limit(400)
      .snapshots()
      .map(
        (snap) => snap.docs
            .map((d) => d.data())
            .where(
              (s) =>
                  s.payment.isCash &&
                  s.payment.cashSettlementId == null &&
                  s.payment.weeklySettlementId == null,
            )
            .toList(),
      )
      .guarded('watchUncountedCash');
}

class FirestoreInvoiceRepository implements InvoiceRepository {
  const FirestoreInvoiceRepository({required this.gateway});

  /// The signed URL comes from a callable, not from Storage directly — the
  /// bucket refuses client reads on purpose.
  final FunctionsGateway gateway;

  @override
  Future<Result<Invoice>> fetchInvoice(String invoiceId) => _guard(() async {
        final snap = await Paths.invoice(invoiceId).get();
        final invoice = snap.data();
        if (invoice == null) throw const Failure(FailureCode.notFound);
        return invoice;
      });

  @override
  Future<Result<String>> downloadUrl(String invoiceId) =>
      gateway.invoiceDownloadUrl(invoiceId);
}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

class FirestoreConfigRepository implements ConfigRepository {
  const FirestoreConfigRepository();

  @override
  Stream<PricingConfig> watchPricing() => Paths.pricingConfig()
      .snapshots()
      .map((snap) => snap.data() ?? const PricingConfig());

  @override
  Stream<DispatchConfig> watchDispatch() => Paths.dispatchConfig()
      .snapshots()
      .map((snap) => snap.data() ?? const DispatchConfig());

  @override
  Stream<AppSettings> watchAppSettings() => Paths.appSettings()
      .snapshots()
      .map((snap) => snap.data() ?? const AppSettings());

  @override
  Stream<DateTime?> watchSettlementsStartAt() => Paths.settlementsConfig()
      .snapshots()
      .map((snap) => const NullableTimestampConverter().fromJson(snap.data()?['startAt']))
      .guarded('watchSettlementsStartAt');

  @override
  Future<AppSettings> currentAppSettings() async {
    // Defaults rather than a throw: a config document that has not been seeded
    // yet should not stop a customer requesting a tow.
    try {
      final snap = await Paths.appSettings().get();
      return snap.data() ?? const AppSettings();
    } on Object {
      return const AppSettings();
    }
  }
}

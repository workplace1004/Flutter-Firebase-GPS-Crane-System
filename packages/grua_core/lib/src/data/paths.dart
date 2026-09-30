import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_database/firebase_database.dart';

import '../domain/enums.dart';
import '../domain/models/app_user.dart';
import '../domain/models/billing.dart';
import '../domain/models/chat_request.dart';
import '../domain/models/dispatch_models.dart';
import '../domain/models/driver.dart';
import '../domain/models/driver_review.dart';
import '../domain/models/insurer.dart';
import '../domain/models/insurer_invoice.dart';
import '../domain/models/payments.dart';
import '../domain/models/pricing_rule.dart';
import '../domain/models/remote_config_models.dart';
import '../domain/models/service.dart';
import '../domain/models/settlement.dart';
import '../domain/models/truck.dart';

/// Every Firestore and Realtime Database path in the system, typed.
///
/// This is the only file allowed to contain a collection-name string literal.
/// A typo in `'sevices'` elsewhere is a silent empty stream that looks like a
/// permissions problem for an afternoon; here it is one place to check, and the
/// converters mean a read hands back a model rather than a `Map`.
abstract final class Paths {
  static FirebaseFirestore get _db => FirebaseFirestore.instance;

  static FirebaseDatabase get _rtdb => FirebaseDatabase.instance;

  // -------------------------------------------------------------------------
  // Collection names — referenced by security rules and the seed script too.
  // -------------------------------------------------------------------------

  static const String usersCollection = 'users';
  static const String driversCollection = 'drivers';
  static const String driverReviewsCollection = 'driverReviews';
  static const String trucksCollection = 'trucks';
  static const String servicesCollection = 'services';
  static const String trackingCollection = 'tracking';
  static const String invoicesCollection = 'invoices';
  static const String earningsCollection = 'earnings';
  static const String configCollection = 'config';
  static const String reportsCollection = 'reports';
  static const String auditCollection = 'audit';
  static const String chatRequestsCollection = 'chatRequests';
  static const String cashSettlementsCollection = 'cashSettlements';
  static const String insurersCollection = 'insurers';
  static const String pricingRulesCollection = 'pricingRules';
  static const String driverSettlementsCollection = 'driverSettlements';
  static const String insurerInvoicesCollection = 'insurerInvoices';
  static const String fiscalCollection = 'fiscal';

  static const String offersSubcollection = 'offers';
  static const String messagesSubcollection = 'messages';
  static const String eventsSubcollection = 'events';
  static const String documentsSubcollection = 'documents';
  static const String entriesSubcollection = 'entries';
  static const String tokensSubcollection = 'tokens';
  static const String vehiclesSubcollection = 'vehicles';
  static const String placesSubcollection = 'places';
  static const String notificationsSubcollection = 'notifications';
  static const String chatStateSubcollection = 'chatState';
  static const String blockedSubcollection = 'blocked';
  static const String membersSubcollection = 'members';

  // -------------------------------------------------------------------------
  // Users
  // -------------------------------------------------------------------------

  static CollectionReference<AppUser> users() =>
      _db.collection(usersCollection).withConverter<AppUser>(
            fromFirestore: (snap, _) =>
                AppUser.fromJson({...?snap.data(), 'id': snap.id}),
            toFirestore: (value, _) => _strip(value.toJson(), const ['id']),
          );

  static DocumentReference<AppUser> user(String uid) => users().doc(uid);

  /// Per-device FCM tokens. Kept as documents rather than an array so a stale
  /// token can be deleted by id when FCM reports it unregistered.
  static CollectionReference<Map<String, dynamic>> userTokens(String uid) =>
      _db.collection(usersCollection).doc(uid).collection(tokensSubcollection);

  static CollectionReference<Map<String, dynamic>> userVehicles(String uid) =>
      _db.collection(usersCollection).doc(uid).collection(vehiclesSubcollection);

  static CollectionReference<Map<String, dynamic>> userPlaces(String uid) =>
      _db.collection(usersCollection).doc(uid).collection(placesSubcollection);

  /// What this person did to their own conversations, by thread key — see
  /// `jobThreadKey` and `requestThreadKey`. Private to them.
  static CollectionReference<Map<String, dynamic>> userChatState(String uid) =>
      _db.collection(usersCollection).doc(uid).collection(chatStateSubcollection);

  static DocumentReference<Map<String, dynamic>> userChatStateDoc(
    String uid,
    String threadKey,
  ) =>
      userChatState(uid).doc(threadKey);

  /// Who this person blocked, one document per blocked uid.
  static CollectionReference<Map<String, dynamic>> userBlocked(String uid) =>
      _db.collection(usersCollection).doc(uid).collection(blockedSubcollection);

  static DocumentReference<Map<String, dynamic>> userBlockedDoc(
    String uid,
    String otherUid,
  ) =>
      userBlocked(uid).doc(otherUid);

  static CollectionReference<Map<String, dynamic>> userNotifications(String uid) =>
      _db
          .collection(usersCollection)
          .doc(uid)
          .collection(notificationsSubcollection);

  // -------------------------------------------------------------------------
  // Drivers
  // -------------------------------------------------------------------------

  static CollectionReference<Driver> drivers() =>
      _db.collection(driversCollection).withConverter<Driver>(
            fromFirestore: (snap, _) =>
                Driver.fromJson({...?snap.data(), 'id': snap.id}),
            toFirestore: (value, _) => _strip(value.toJson(), const ['id']),
          );

  static DocumentReference<Driver> driver(String uid) => drivers().doc(uid);

  /// Customers' reviews of choferes, one per rated service. Staff only.
  static CollectionReference<DriverReview> driverReviews() =>
      _db.collection(driverReviewsCollection).withConverter<DriverReview>(
            fromFirestore: (snap, _) =>
                DriverReview.fromJson({...?snap.data(), 'serviceId': snap.id}),
            // Server-written: the app never writes a review.
            toFirestore: (value, _) => throw UnsupportedError('read-only'),
          );

  static CollectionReference<DriverDocument> driverDocuments(String uid) => _db
      .collection(driversCollection)
      .doc(uid)
      .collection(documentsSubcollection)
      .withConverter<DriverDocument>(
        fromFirestore: (snap, _) =>
            DriverDocument.fromJson({...?snap.data(), 'type': snap.id}),
        toFirestore: (value, _) => _strip(value.toJson(), const ['type']),
      );

  static DocumentReference<DriverDocument> driverDocument(
    String uid,
    DriverDocumentType type,
  ) =>
      driverDocuments(uid).doc(type.wire);

  static CollectionReference<Map<String, dynamic>> driverTokens(String uid) =>
      _db.collection(driversCollection).doc(uid).collection(tokensSubcollection);

  // -------------------------------------------------------------------------
  // Trucks
  // -------------------------------------------------------------------------

  static CollectionReference<Truck> trucks() =>
      _db.collection(trucksCollection).withConverter<Truck>(
            fromFirestore: (snap, _) =>
                Truck.fromJson({...?snap.data(), 'id': snap.id}),
            toFirestore: (value, _) => _strip(value.toJson(), const ['id']),
          );

  static DocumentReference<Truck> truck(String id) => trucks().doc(id);

  // -------------------------------------------------------------------------
  // Services
  // -------------------------------------------------------------------------

  static CollectionReference<Service> services() =>
      _db.collection(servicesCollection).withConverter<Service>(
            fromFirestore: (snap, _) =>
                Service.fromJson({...?snap.data(), 'id': snap.id}),
            toFirestore: (value, _) => _strip(value.toJson(), const ['id']),
          );

  static DocumentReference<Service> service(String id) => services().doc(id);

  static CollectionReference<Offer> offers(String serviceId) => _db
      .collection(servicesCollection)
      .doc(serviceId)
      .collection(offersSubcollection)
      .withConverter<Offer>(
        fromFirestore: (snap, _) => Offer.fromJson({
          ...?snap.data(),
          'driverId': snap.id,
          'serviceId': serviceId,
        }),
        toFirestore: (value, _) => _strip(value.toJson(), const ['driverId', 'serviceId']),
      );

  static DocumentReference<Offer> offer(String serviceId, String driverId) =>
      offers(serviceId).doc(driverId);

  static CollectionReference<ChatMessage> messages(String serviceId) => _db
      .collection(servicesCollection)
      .doc(serviceId)
      .collection(messagesSubcollection)
      .withConverter<ChatMessage>(
        fromFirestore: (snap, _) =>
            ChatMessage.fromJson({...?snap.data(), 'id': snap.id}),
        toFirestore: (value, _) => _strip(value.toJson(), const ['id']),
      );

  // -------------------------------------------------------------------------
  // Chat requests — talking to a nearby chofer before any job
  // -------------------------------------------------------------------------

  static CollectionReference<ChatRequest> chatRequests() =>
      _db.collection(chatRequestsCollection).withConverter<ChatRequest>(
            fromFirestore: (snap, _) =>
                ChatRequest.fromJson({...?snap.data(), 'id': snap.id}),
            toFirestore: (value, _) => _strip(value.toJson(), const ['id']),
          );

  static DocumentReference<ChatRequest> chatRequest(String id) =>
      chatRequests().doc(id);

  /// Untyped, for writing a message. See [messageWrites].
  static CollectionReference<Map<String, dynamic>> chatRequestMessageWrites(
    String requestId,
  ) =>
      _db
          .collection(chatRequestsCollection)
          .doc(requestId)
          .collection(messagesSubcollection);

  static CollectionReference<ChatMessage> chatRequestMessages(
    String requestId,
  ) =>
      _db
          .collection(chatRequestsCollection)
          .doc(requestId)
          .collection(messagesSubcollection)
          .withConverter<ChatMessage>(
            fromFirestore: (snap, _) =>
                ChatMessage.fromJson({...?snap.data(), 'id': snap.id}),
            toFirestore: (value, _) => _strip(value.toJson(), const ['id']),
          );

  /// Untyped, for writing a message.
  ///
  /// `sentAt` has to be `FieldValue.serverTimestamp()`: the phone's clock does
  /// not order a conversation, and a `ChatMessage` cannot carry a sentinel.
  /// It also has to be *present* — the model's JSON drops null fields, and a
  /// document with no `sentAt` is invisible to the `orderBy('sentAt')` the
  /// readers use, so the message would be saved and never seen.
  static CollectionReference<Map<String, dynamic>> messageWrites(
    String serviceId,
  ) =>
      _db
          .collection(servicesCollection)
          .doc(serviceId)
          .collection(messagesSubcollection);

  static CollectionReference<ServiceEvent> events(String serviceId) => _db
      .collection(servicesCollection)
      .doc(serviceId)
      .collection(eventsSubcollection)
      .withConverter<ServiceEvent>(
        fromFirestore: (snap, _) =>
            ServiceEvent.fromJson({...?snap.data(), 'id': snap.id}),
        toFirestore: (value, _) => _strip(value.toJson(), const ['id']),
      );

  static CollectionReference<ServiceTracking> tracking() =>
      _db.collection(trackingCollection).withConverter<ServiceTracking>(
            fromFirestore: (snap, _) =>
                ServiceTracking.fromJson({...?snap.data(), 'serviceId': snap.id}),
            toFirestore: (value, _) => _strip(value.toJson(), const ['serviceId']),
          );

  static DocumentReference<ServiceTracking> trackingFor(String serviceId) =>
      tracking().doc(serviceId);

  // -------------------------------------------------------------------------
  // Money
  // -------------------------------------------------------------------------

  static CollectionReference<Invoice> invoices() =>
      _db.collection(invoicesCollection).withConverter<Invoice>(
            fromFirestore: (snap, _) =>
                Invoice.fromJson({...?snap.data(), 'id': snap.id}),
            toFirestore: (value, _) => _strip(value.toJson(), const ['id']),
          );

  static DocumentReference<Invoice> invoice(String id) => invoices().doc(id);

  static DocumentReference<EarningsSummary> earningsSummary(String driverId) =>
      _db
          .collection(earningsCollection)
          .doc(driverId)
          .withConverter<EarningsSummary>(
            fromFirestore: (snap, _) => EarningsSummary.fromJson(
              {...?snap.data(), 'driverId': snap.id},
            ),
            toFirestore: (value, _) => _strip(value.toJson(), const ['driverId']),
          );

  static CollectionReference<EarningEntry> earningEntries(String driverId) => _db
      .collection(earningsCollection)
      .doc(driverId)
      .collection(entriesSubcollection)
      .withConverter<EarningEntry>(
        fromFirestore: (snap, _) => EarningEntry.fromJson({
          ...?snap.data(),
          'serviceId': snap.id,
          'driverId': driverId,
        }),
        toFirestore: (value, _) => _strip(value.toJson(), const ['serviceId', 'driverId']),
      );

  /// Cortes. Server-written; read-only here, so there is nothing to convert
  /// back.
  static CollectionReference<CashSettlement> cashSettlements() => _db
      .collection(cashSettlementsCollection)
      .withConverter<CashSettlement>(
        fromFirestore: (snap, _) =>
            CashSettlement.fromJson(snap.id, snap.data() ?? const {}),
        toFirestore: (_, _) =>
            throw UnsupportedError('Cortes are written by settleDriverCash.'),
      );

  // -------------------------------------------------------------------------
  // Insurance companies — server-written, read-only here
  // -------------------------------------------------------------------------

  /// Zone prices. Queries must filter on `insurerId` (null for the default
  /// list), or the security rules refuse them.
  static CollectionReference<PricingRule> pricingRules() => _db
      .collection(pricingRulesCollection)
      .withConverter<PricingRule>(
        fromFirestore: (snap, _) => PricingRule.fromJson(snap.data() ?? const {}),
        toFirestore: (_, _) => throw UnsupportedError(
          'Zone prices are written by the pricing callables.',
        ),
      );

  static CollectionReference<Insurer> insurers() => _db
      .collection(insurersCollection)
      .withConverter<Insurer>(
        fromFirestore: (snap, _) =>
            Insurer.fromJson(snap.id, snap.data() ?? const {}),
        toFirestore: (_, _) =>
            throw UnsupportedError('Insurers are written by the insurer callables.'),
      );

  static DocumentReference<Insurer> insurer(String id) => insurers().doc(id);

  /// The company's people, keyed by their Auth uid.
  static CollectionReference<InsurerMember> insurerMembers(String insurerId) =>
      _db
          .collection(insurersCollection)
          .doc(insurerId)
          .collection(membersSubcollection)
          .withConverter<InsurerMember>(
            fromFirestore: (snap, _) => InsurerMember.fromJson(
              insurerId,
              snap.id,
              snap.data() ?? const {},
            ),
            toFirestore: (_, _) => throw UnsupportedError(
              'Insurer members are written by the insurer callables.',
            ),
          );

  static DocumentReference<InsurerMember> insurerMember(
    String insurerId,
    String uid,
  ) =>
      insurerMembers(insurerId).doc(uid);

  /// Weekly cortes. Server-written; a chofer's queries must filter on their
  /// own `driverId`.
  static CollectionReference<DriverSettlement> driverSettlements() => _db
      .collection(driverSettlementsCollection)
      .withConverter<DriverSettlement>(
        fromFirestore: (snap, _) =>
            DriverSettlement.fromJson(snap.id, snap.data() ?? const {}),
        toFirestore: (_, _) => throw UnsupportedError(
          'Cortes are written by the settlement callables.',
        ),
      );

  static DocumentReference<DriverSettlement> driverSettlement(String id) =>
      driverSettlements().doc(id);

  /// Monthly invoices to insurance companies. Server-written; a company's
  /// queries must filter on its own `insurerId`.
  static CollectionReference<InsurerInvoice> insurerInvoices() => _db
      .collection(insurerInvoicesCollection)
      .withConverter<InsurerInvoice>(
        fromFirestore: (snap, _) =>
            InsurerInvoice.fromJson(snap.id, snap.data() ?? const {}),
        toFirestore: (_, _) => throw UnsupportedError(
          'Invoices are written by the invoicing callables.',
        ),
      );

  static DocumentReference<InsurerInvoice> insurerInvoice(String id) =>
      insurerInvoices().doc(id);

  /// The company that issues receipts. Office-readable, server-written.
  static DocumentReference<Map<String, dynamic>> fiscalIssuer() =>
      _db.collection(fiscalCollection).doc('issuer');

  /// The NCF range receipts of [prefix] are numbered from.
  static DocumentReference<Map<String, dynamic>> ncfSequence(String prefix) =>
      _db.collection(fiscalCollection).doc('ncf_$prefix');

  // -------------------------------------------------------------------------
  // Configuration
  // -------------------------------------------------------------------------

  static DocumentReference<PricingConfig> pricingConfig() => _db
      .collection(configCollection)
      .doc('pricing')
      .withConverter<PricingConfig>(
        fromFirestore: (snap, _) => PricingConfig.fromJson(snap.data() ?? {}),
        toFirestore: (value, _) => value.toJson(),
      );

  static DocumentReference<DispatchConfig> dispatchConfig() => _db
      .collection(configCollection)
      .doc('dispatch')
      .withConverter<DispatchConfig>(
        fromFirestore: (snap, _) => DispatchConfig.fromJson(snap.data() ?? {}),
        toFirestore: (value, _) => value.toJson(),
      );

  /// `startAt`: jobs finished before it are left out of weekly cortes.
  static DocumentReference<Map<String, dynamic>> settlementsConfig() =>
      _db.collection(configCollection).doc('settlements');

  static DocumentReference<AppSettings> appSettings() =>
      _db.collection(configCollection).doc('app').withConverter<AppSettings>(
            fromFirestore: (snap, _) => AppSettings.fromJson(snap.data() ?? {}),
            toFirestore: (value, _) => value.toJson(),
          );

  // -------------------------------------------------------------------------
  // Reports
  // -------------------------------------------------------------------------

  static DocumentReference<Map<String, dynamic>> dailyReport(String yyyyMMdd) =>
      _db.collection(reportsCollection).doc('daily').collection('days').doc(yyyyMMdd);

  static DocumentReference<Map<String, dynamic>> todayReport() =>
      _db.collection(reportsCollection).doc('today');

  // -------------------------------------------------------------------------
  // Realtime Database — live positions and app presence
  // -------------------------------------------------------------------------

  static DatabaseReference liveRoot() => _rtdb.ref('live');

  static DatabaseReference live(String driverId) => _rtdb.ref('live/$driverId');

  static DatabaseReference presenceRoot() => _rtdb.ref('presence');

  static DatabaseReference presence(String driverId) =>
      _rtdb.ref('presence/$driverId');

  /// Who is typing in one conversation, at `typing/{threadKey}/{uid}`.
  ///
  /// The value is the epoch millisecond of the last keystroke, so a flag left
  /// behind by a phone that lost signal ages out instead of saying somebody is
  /// typing forever.
  static DatabaseReference typing(String threadKey) =>
      _rtdb.ref('typing/$threadKey');

  static DatabaseReference typingBy(String threadKey, String uid) =>
      _rtdb.ref('typing/$threadKey/$uid');

  /// True while this client holds a connection to RTDB.
  static DatabaseReference connectionState() => _rtdb.ref('.info/connected');

  // -------------------------------------------------------------------------
  // Storage object paths (strings, not references — Storage is addressed by path)
  // -------------------------------------------------------------------------

  static String driverDocPath(String uid, DriverDocumentType type, String ext) =>
      'drivers/$uid/docs/${type.wire}_${DateTime.now().millisecondsSinceEpoch}.$ext';

  /// Timestamped so a replaced photo is a new URL no cache has seen.
  static String driverPhotoPath(String uid, String ext) =>
      'drivers/$uid/avatar/photo_${DateTime.now().millisecondsSinceEpoch}.$ext';

  static String servicePhotoPath(String serviceId, String name) =>
      'service_photos/$serviceId/$name';

  static String truckPhotoPath(String truckId, String name) =>
      'trucks/$truckId/$name';

  static String invoicePdfPath(String invoiceId) => 'invoices/$invoiceId.pdf';

  /// Removes the synthetic key fields a converter injected on read.
  ///
  /// A document should not carry its own key as a field: it is redundant, it
  /// can drift from the real id after a copy, and it wastes an index. Each
  /// converter names its own keys because the same field name is synthetic in
  /// one collection and real data in another — `driverId` is the document key
  /// under `earnings/`, but a genuine field on a service.
  static Map<String, Object?> _strip(
    Map<String, dynamic> json,
    List<String> syntheticKeys,
  ) {
    final copy = Map<String, Object?>.from(json);
    syntheticKeys.forEach(copy.remove);
    return copy;
  }
}

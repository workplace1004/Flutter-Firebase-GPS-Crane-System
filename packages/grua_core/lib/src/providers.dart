import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
// Riverpod 3 keeps the family types out of the default export surface.
import 'package:flutter_riverpod/misc.dart'
    show FutureProviderFamily, ProviderFamily, StreamProviderFamily;

import 'calls/voice_call.dart';
import 'config/app_config.dart';
import 'config/maps_script.dart';
import 'data/insurer_invoicing.dart';
import 'data/insurer_stats.dart';
import 'data/settlements.dart';
import 'domain/enums.dart';
import 'domain/failures.dart';
import 'domain/models/app_user.dart';
import 'domain/models/billing.dart';
import 'domain/models/chat_prefs.dart';
import 'domain/models/chat_request.dart';
import 'domain/models/dispatch_models.dart';
import 'domain/models/driver.dart';
import 'domain/models/insurer.dart';
import 'domain/models/insurer_invoice.dart';
import 'domain/models/payments.dart';
import 'domain/models/pricing_rule.dart';
import 'domain/models/remote_config_models.dart';
import 'domain/models/service.dart';
import 'domain/models/settlement.dart';
import 'domain/models/truck.dart';
import 'domain/repositories.dart';
import 'domain/value_objects.dart';
import 'location/location_service.dart';
import 'location/places_service.dart';
import 'location/route_service.dart';
import 'utils/date_time_do.dart';

/// Dependency wiring for all three apps.
///
/// Repositories are declared here as unimplemented providers and bound at
/// startup by `runGruaApp` to the Firebase implementation. Screens depend on
/// the interface only, so the same widget tree runs against the in-memory
/// backend in `grua_testing` in a widget test, the emulator in development,
/// and production — with no conditionals inside the UI.

/// Build configuration. Overridden in `main()` with the app's own [AppKind].
final appConfigProvider = Provider<AppConfig>(
  (ref) => throw UnimplementedError('appConfigProvider must be overridden'),
);

// ---------------------------------------------------------------------------
// Repositories
// ---------------------------------------------------------------------------

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => throw UnimplementedError('authRepositoryProvider must be overridden'),
);

final userRepositoryProvider = Provider<UserRepository>(
  (ref) => throw UnimplementedError('userRepositoryProvider must be overridden'),
);

final driverRepositoryProvider = Provider<DriverRepository>(
  (ref) => throw UnimplementedError('driverRepositoryProvider must be overridden'),
);

final truckRepositoryProvider = Provider<TruckRepository>(
  (ref) => throw UnimplementedError('truckRepositoryProvider must be overridden'),
);

final serviceRepositoryProvider = Provider<ServiceRepository>(
  (ref) =>
      throw UnimplementedError('serviceRepositoryProvider must be overridden'),
);

final callRepositoryProvider = Provider<CallRepository>(
  (ref) => throw UnimplementedError('callRepositoryProvider must be overridden'),
);

final offerRepositoryProvider = Provider<OfferRepository>(
  (ref) => throw UnimplementedError('offerRepositoryProvider must be overridden'),
);

final chatRepositoryProvider = Provider<ChatRepository>(
  (ref) => throw UnimplementedError('chatRepositoryProvider must be overridden'),
);

final chatRequestRepositoryProvider = Provider<ChatRequestRepository>(
  (ref) => throw UnimplementedError(
    'chatRequestRepositoryProvider must be overridden',
  ),
);

final typingRepositoryProvider = Provider<TypingRepository>(
  (ref) =>
      throw UnimplementedError('typingRepositoryProvider must be overridden'),
);

final chatPrefsRepositoryProvider = Provider<ChatPrefsRepository>(
  (ref) =>
      throw UnimplementedError('chatPrefsRepositoryProvider must be overridden'),
);

final earningsRepositoryProvider = Provider<EarningsRepository>(
  (ref) =>
      throw UnimplementedError('earningsRepositoryProvider must be overridden'),
);

final insurerRepositoryProvider = Provider<InsurerRepository>(
  (ref) =>
      throw UnimplementedError('insurerRepositoryProvider must be overridden'),
);

final invoiceRepositoryProvider = Provider<InvoiceRepository>(
  (ref) =>
      throw UnimplementedError('invoiceRepositoryProvider must be overridden'),
);

final configRepositoryProvider = Provider<ConfigRepository>(
  (ref) =>
      throw UnimplementedError('configRepositoryProvider must be overridden'),
);

final functionsGatewayProvider = Provider<FunctionsGateway>(
  (ref) => throw UnimplementedError('functionsGatewayProvider must be overridden'),
);

// ---------------------------------------------------------------------------
// Device
// ---------------------------------------------------------------------------

/// Device location and geocoding. Overridable in tests with a fake geolocator.
final locationServiceProvider = Provider<LocationService>(
  (ref) => LocationService(),
);

/// Whether Google Maps is available: a key supplied at build time, or — on the
/// web — the Maps script already loaded by `index.html`.
///
/// Screens pass this to `GruaMap`, which renders a real Google map when it is
/// true and the drawn fallback when it is false. Keeping the decision in one
/// provider means no screen has to know how the map is sourced.
final hasMapsKeyProvider = Provider<bool>(
  (ref) =>
      ref.watch(appConfigProvider).googleMapsApiKey.isNotEmpty ||
      googleMapsScriptLoaded,
);

/// Address suggestions. Uses the build-time key, or — on the web, where the
/// key lives in `index.html` — the one the page's Maps script was loaded with.
final placesServiceProvider = Provider<PlacesService>((ref) {
  final configured = ref.watch(appConfigProvider).googleMapsApiKey;
  return PlacesService(
    apiKey: configured.isNotEmpty ? configured : googleMapsScriptKey,
  );
});

final routeServiceProvider = Provider<RouteService>(
  (ref) => RouteService(apiKey: ref.watch(appConfigProvider).googleMapsApiKey),
);

/// The road route between two points. Cached by the service, so a screen that
/// rebuilds with the same ends does not pay for a second call.
final FutureProviderFamily<RoadRoute, (LatLng, LatLng)> roadRouteProvider =
    FutureProvider.family<RoadRoute, (LatLng, LatLng)>(
  (ref, ends) => ref.watch(routeServiceProvider).route(ends.$1, ends.$2),
);

/// The customer's current position, resolved once per screen entry.
final currentPlaceProvider = FutureProvider<ResolvedPlace?>((ref) async {
  final result = await ref.watch(locationServiceProvider).currentPlace();
  return result.valueOrNull;
});

/// What is blocking location right now, if anything. Watched by the screens
/// that need to explain it.
final locationBlockerProvider = FutureProvider<LocationBlocker>(
  (ref) => ref.watch(locationServiceProvider).check(),
);

// ---------------------------------------------------------------------------
// Session
// ---------------------------------------------------------------------------

/// The signed-in uid, or null. The router redirects on this.
final authStateProvider = StreamProvider<String?>(
  (ref) => ref.watch(authRepositoryProvider).watchUserId(),
);

/// Convenience: the uid, or null while loading.
final currentUserIdProvider = Provider<String?>(
  (ref) => ref.watch(authStateProvider).value,
);

final isSignedInProvider = Provider<bool>(
  (ref) => ref.watch(currentUserIdProvider) != null,
);

/// The signed-in account's role, read from the token's custom claim.
///
/// `forceRefresh` is deliberate: a claim granted moments ago is not in the
/// cached token, and a panel that trusted the stale copy would keep refusing
/// somebody who does now have access.
final currentRoleProvider = FutureProvider<UserRole>((ref) async {
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return UserRole.unknown;
  return await ref.read(authRepositoryProvider).currentRole(forceRefresh: true);
});

/// The signed-in customer's profile.
final currentUserProvider = StreamProvider<AppUser?>((ref) {
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return Stream.value(null);
  return ref.watch(userRepositoryProvider).watchUser(uid);
});

/// Creates the signed-in customer's `users/` document if it is missing.
///
/// The security rules forbid a client from creating its own user document,
/// because `role` and `blocked` are not the client's to decide, so the document
/// only exists once the server has made one. Until then [currentUserProvider]
/// streams null and every screen waiting on a profile waits forever.
///
/// Watch it once near the root of the app. It re-runs whenever the uid changes,
/// which covers both a fresh sign-in and a cold start on an existing session,
/// and the callable is idempotent so the repeat costs one read.
final ensureProfileProvider = FutureProvider<void>((ref) async {
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return;
  await ref.read(functionsGatewayProvider).ensureProfile();
});

/// The signed-in chofer's record.
final currentDriverProvider = StreamProvider<Driver?>((ref) {
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return Stream.value(null);
  return ref.watch(driverRepositoryProvider).watchDriver(uid);
});

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

final appSettingsProvider = StreamProvider<AppSettings>(
  (ref) => ref.watch(configRepositoryProvider).watchAppSettings(),
);

final pricingConfigProvider = StreamProvider<PricingConfig>(
  (ref) => ref.watch(configRepositoryProvider).watchPricing(),
);

final dispatchConfigProvider = StreamProvider<DispatchConfig>(
  (ref) => ref.watch(configRepositoryProvider).watchDispatch(),
);

// ---------------------------------------------------------------------------
// Services
// ---------------------------------------------------------------------------

/// The client's single in-flight service. Drives the client app's home screen:
/// null means "show the request button", non-null means "show tracking".
final activeClientServiceProvider = StreamProvider<Service?>((ref) {
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return Stream.value(null);
  return ref.watch(serviceRepositoryProvider).watchActiveForClient(uid);
});

/// The chofer's current job, restored on cold start so a force-quit mid-tow
/// reopens on the right screen.
final activeDriverServiceProvider = StreamProvider<Service?>((ref) {
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return Stream.value(null);
  return ref.watch(serviceRepositoryProvider).watchActiveForDriver(uid);
});

/// The signed-in chofer's own offer on one job: what they take home from it.
///
/// Read after accepting too. The service document cannot carry the chofer's
/// share of an insurer's tow — the insurance company reads that document —
/// but the offer is the chofer's alone.
final StreamProviderFamily<Offer?, String> myOfferProvider =
    StreamProvider.family<Offer?, String>((ref, serviceId) {
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return Stream.value(null);
  return ref.watch(offerRepositoryProvider).watchOffer(serviceId, uid);
});

final StreamProviderFamily<Service?, String> serviceByIdProvider =
    StreamProvider.family<Service?, String>(
  (ref, id) => ref.watch(serviceRepositoryProvider).watchService(id),
);

/// Live position of the chofer on one service. Null until a chofer is assigned
/// and has published a fix.
final StreamProviderFamily<ServiceTracking?, String> serviceTrackingProvider =
    StreamProvider.family<ServiceTracking?, String>(
  (ref, id) => ref.watch(serviceRepositoryProvider).watchTracking(id),
);

/// A viewable URL for one of the chofer's proof photos, by storage path.
/// Null when it cannot be read — deleted, or the viewer is not staff.
final FutureProviderFamily<String?, String> servicePhotoUrlProvider =
    FutureProvider.family<String?, String>(
  (ref, path) async => switch (
      await ref.watch(serviceRepositoryProvider).servicePhotoUrl(path)) {
    Ok(:final value) => value,
    Err() => null,
  },
);

final StreamProviderFamily<List<ServiceEvent>, String> serviceEventsProvider =
    StreamProvider.family<List<ServiceEvent>, String>(
  (ref, id) => ref.watch(serviceRepositoryProvider).watchEvents(id),
);

final StreamProviderFamily<List<ChatMessage>, String> serviceMessagesProvider =
    StreamProvider.family<List<ChatMessage>, String>(
  (ref, id) => ref.watch(chatRepositoryProvider).watchMessages(id),
);

/// Messages on one service the signed-in user has not read yet — only the
/// other party's, never their own. Drives the chat badges.
final ProviderFamily<int, String> unreadMessageCountProvider =
    Provider.family<int, String>((ref, id) {
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return 0;
  final messages = ref.watch(serviceMessagesProvider(id)).value ?? const [];
  return messages.where((m) => !m.isMine(uid) && !m.isRead).length;
});

// ---------------------------------------------------------------------------
// Chat requests — talking to a nearby chofer before any job
// ---------------------------------------------------------------------------

/// Chat requests addressed to the signed-in chofer, newest first.
final driverChatRequestsProvider = StreamProvider<List<ChatRequest>>((ref) {
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return Stream.value(const []);
  return ref.watch(chatRequestRepositoryProvider).watchForDriver(uid);
});

/// Chat requests the signed-in customer has sent, newest first.
final clientChatRequestsProvider = StreamProvider<List<ChatRequest>>((ref) {
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return Stream.value(const []);
  return ref.watch(chatRequestRepositoryProvider).watchForClient(uid);
});

final StreamProviderFamily<ChatRequest?, String> chatRequestProvider =
    StreamProvider.family<ChatRequest?, String>(
  (ref, id) => ref.watch(chatRequestRepositoryProvider).watchRequest(id),
);

final StreamProviderFamily<List<ChatMessage>, String>
    chatRequestMessagesProvider = StreamProvider.family<List<ChatMessage>, String>(
  (ref, id) => ref.watch(chatRequestRepositoryProvider).watchMessages(id),
);

/// The other side's unread messages in one chat request's conversation.
final ProviderFamily<int, String> unreadChatRequestMessageCountProvider =
    Provider.family<int, String>((ref, id) {
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return 0;
  final messages = ref.watch(chatRequestMessagesProvider(id)).value ?? const [];
  return messages.where((m) => !m.isMine(uid) && !m.isRead).length;
});

/// Whether the *other* side is typing in one conversation, keyed by
/// [jobThreadKey] or [requestThreadKey]. Your own keystrokes never count.
final StreamProviderFamily<bool, String> otherTypingProvider =
    StreamProvider.family<bool, String>((ref, threadKey) {
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return Stream.value(false);
  return ref
      .watch(typingRepositoryProvider)
      .watchTyping(threadKey)
      .map((uids) => uids.any((typist) => typist != uid));
});

// ---------------------------------------------------------------------------
// Each person's own view of their conversations
// ---------------------------------------------------------------------------

/// What the signed-in person did to one conversation: cleared it, deleted it,
/// or neither.
final StreamProviderFamily<ChatThreadPrefs, String> chatThreadPrefsProvider =
    StreamProvider.family<ChatThreadPrefs, String>((ref, threadKey) {
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return Stream.value(ChatThreadPrefs.none);
  return ref
      .watch(chatPrefsRepositoryProvider)
      .watchThread(uid: uid, threadKey: threadKey);
});

/// The uids the signed-in person blocked.
final blockedUsersProvider = StreamProvider<Set<String>>((ref) {
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return Stream.value(const <String>{});
  return ref.watch(chatPrefsRepositoryProvider).watchBlocked(uid);
});

/// Whether the other person blocked the signed-in one, so their messages
/// would not arrive. Reads the one document that names them, never the list.
final StreamProviderFamily<bool, String> blockedByProvider =
    StreamProvider.family<bool, String>((ref, otherUid) {
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null || otherUid.isEmpty) return Stream.value(false);
  return ref
      .watch(chatPrefsRepositoryProvider)
      .watchBlockedBy(uid: uid, otherUid: otherUid);
});

/// Whether a conversation stays off this person's list: they deleted it, and
/// nothing has been said in it since.
///
/// Only a deleted conversation looks at its messages, so an untouched list
/// costs nothing extra to draw.
final ProviderFamily<bool, String> chatThreadHiddenProvider =
    Provider.family<bool, String>((ref, threadKey) {
  final prefs =
      ref.watch(chatThreadPrefsProvider(threadKey)).value ?? ChatThreadPrefs.none;
  if (!prefs.isDeleted) return false;

  const jobPrefix = 'job:';
  final messages = threadKey.startsWith(jobPrefix)
      ? ref.watch(serviceMessagesProvider(threadKey.substring(jobPrefix.length)))
            .value
      : ref
            .watch(
              chatRequestMessagesProvider(
                threadKey.substring('request:'.length),
              ),
            )
            .value;

  DateTime? lastAt;
  for (final message in messages ?? const <ChatMessage>[]) {
    final sentAt = message.sentAt;
    if (sentAt == null) continue;
    if (lastAt == null || sentAt.isAfter(lastAt)) lastAt = sentAt;
  }
  return !prefs.showsAgain(lastAt);
});

// ---------------------------------------------------------------------------
// Fleet — admin panel
// ---------------------------------------------------------------------------

final allDriversProvider = StreamProvider<List<Driver>>(
  (ref) => ref.watch(driverRepositoryProvider).watchAllDrivers(),
);

/// The customer roster. Staff-only — the rules refuse this query to a client.
final allClientsProvider = StreamProvider<List<AppUser>>(
  (ref) => ref.watch(userRepositoryProvider).watchAllClients(),
);

final liveDriverPositionsProvider = StreamProvider<List<DriverLivePosition>>(
  (ref) => ref.watch(driverRepositoryProvider).watchLivePositions(),
);

/// Ids of the choferes with the app open right now, for the roster's dot.
final connectedDriverIdsProvider = StreamProvider<Set<String>>(
  (ref) => ref.watch(driverRepositoryProvider).watchConnectedDriverIds(),
);

final activeServicesProvider = StreamProvider<List<Service>>(
  (ref) => ref.watch(serviceRepositoryProvider).watchActiveServices(),
);

final allTrucksProvider = StreamProvider<List<Truck>>(
  (ref) => ref.watch(truckRepositoryProvider).watchTrucks(),
);

// ---------------------------------------------------------------------------
// Earnings — driver app
// ---------------------------------------------------------------------------

final driverEarningsProvider = StreamProvider<EarningsSummary?>((ref) {
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return Stream.value(null);
  return ref.watch(earningsRepositoryProvider).watchSummary(uid);
});

/// The company the signed-in person works for, or null for anyone else.
final currentInsurerIdProvider = FutureProvider<String?>((ref) async {
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return null;
  return await ref.read(authRepositoryProvider).currentInsurerId(forceRefresh: true);
});

// The providers below wait for the company id rather than reading null
// while its token refresh is on the way: a null there reads as "no company",
// and the portal would briefly tell a valid person they have been
// deactivated.

/// The signed-in person's own record at their company: their role, whether
/// they may act, whether they still have to choose a password.
final myInsurerMemberProvider = StreamProvider<InsurerMember?>((ref) async* {
  final uid = ref.watch(currentUserIdProvider);
  final insurerId = await ref.watch(currentInsurerIdProvider.future);
  if (uid == null || insurerId == null) {
    yield null;
    return;
  }
  yield* ref.watch(insurerRepositoryProvider).watchMember(insurerId, uid);
});

/// The signed-in person's company.
final myInsurerProvider = StreamProvider<Insurer?>((ref) async* {
  final insurerId = await ref.watch(currentInsurerIdProvider.future);
  if (insurerId == null) {
    yield null;
    return;
  }
  yield* ref.watch(insurerRepositoryProvider).watchInsurer(insurerId);
});

/// The signed-in company's latest tows, newest first.
final myInsurerServicesProvider = StreamProvider<List<Service>>((ref) async* {
  final insurerId = await ref.watch(currentInsurerIdProvider.future);
  if (insurerId == null) {
    yield const [];
    return;
  }
  yield* ref.watch(serviceRepositoryProvider).watchInsurerServices(insurerId);
});

/// This month's numbers for the signed-in company.
final myInsurerStatsProvider = StreamProvider<InsurerStats>((ref) async* {
  final now = DateTime.now().toUtc();
  // Starts over when the month turns, so the numbers move to the new month
  // on a screen left open overnight.
  final nextMonth = InvoicePeriod.of(now).end.difference(now) + const Duration(seconds: 1);
  final turn = Timer(nextMonth, ref.invalidateSelf);
  ref.onDispose(turn.cancel);

  final insurerId = await ref.watch(currentInsurerIdProvider.future);
  if (insurerId == null) {
    yield InsurerStats.of(const [], now);
    return;
  }
  final monthStart = DoTime.startOfLocalMonth(now);
  // The month's tows, plus anything still in flight from before it.
  yield* ref
      .watch(serviceRepositoryProvider)
      .watchInsurerServices(insurerId, since: monthStart.subtract(const Duration(days: 3)), limit: 1000)
      .map((services) => InsurerStats.of(services, DateTime.now().toUtc()));
});

/// The day weekly cortes began, or null when the office has not set one.
final settlementsStartAtProvider = StreamProvider<DateTime?>(
  (ref) => ref.watch(configRepositoryProvider).watchSettlementsStartAt(),
);

/// Every insurance company, by name.
final allInsurersProvider = StreamProvider<List<Insurer>>(
  (ref) => ref.watch(insurerRepositoryProvider).watchInsurers(),
);

final StreamProviderFamily<Insurer?, String> insurerProvider =
    StreamProvider.family<Insurer?, String>(
  (ref, id) => ref.watch(insurerRepositoryProvider).watchInsurer(id),
);

final StreamProviderFamily<List<InsurerMember>, String> insurerMembersProvider =
    StreamProvider.family<List<InsurerMember>, String>(
  (ref, id) => ref.watch(insurerRepositoryProvider).watchMembers(id),
);

/// One table owner's stored zone prices. Keyed by company id; the empty
/// string is the default list.
final StreamProviderFamily<List<PricingRule>, String> pricingRulesProvider =
    StreamProvider.family<List<PricingRule>, String>(
  (ref, owner) => ref
      .watch(insurerRepositoryProvider)
      .watchPricingRules(insurerId: owner.isEmpty ? null : owner),
);

/// The signed-in chofer's weekly cortes, newest first.
final myDriverSettlementsProvider = StreamProvider<List<DriverSettlement>>((ref) {
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return Stream.value(const []);
  return ref
      .watch(earningsRepositoryProvider)
      .watchDriverSettlements(driverId: uid);
});

/// Every chofer's weekly cortes, newest first. The office's cortes screen.
final allDriverSettlementsProvider = StreamProvider<List<DriverSettlement>>(
  (ref) => ref.watch(earningsRepositoryProvider).watchDriverSettlements(limit: 200),
);

/// Every corte still waiting to be paid, however old: what the office owes
/// and is owed. Queried on its own so the newest 200 never hide one.
final pendingDriverSettlementsProvider = StreamProvider<List<DriverSettlement>>(
  (ref) => ref.watch(earningsRepositoryProvider).watchDriverSettlements(
        status: SettlementStatus.pending,
        limit: 1000,
      ),
);

final StreamProviderFamily<DriverSettlement?, String> driverSettlementProvider =
    StreamProvider.family<DriverSettlement?, String>(
  (ref, id) => ref.watch(earningsRepositoryProvider).watchDriverSettlement(id),
);

/// What Friday's corte will say so far, for the signed-in chofer: their
/// unsettled jobs, worked out the way the server will.
final myRunningSettlementProvider = StreamProvider<SettlementDraft?>((ref) async* {
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) {
    yield null;
    return;
  }
  // Jobs from before cortes began are never charged, so they are not shown.
  final startAt = await ref.watch(settlementsStartAtProvider.future);
  yield* ref
      .watch(earningsRepositoryProvider)
      .watchUnsettledEntries(uid, since: startAt)
      .map(
        (entries) => SettlementMath.draft(
          entries,
          cutoff: DateTime.now().toUtc(),
          startAt: startAt,
        ),
      );
});

/// What the signed-in chofer and Titan owe each other right now: every corte
/// not yet paid, plus this week's so far. Null until the cortes load.
final myDriverBalanceProvider = Provider<DriverBalance?>((ref) {
  final cortes = ref.watch(myDriverSettlementsProvider);
  if (!cortes.hasValue) return null;
  return DriverBalance.of(
    settlements: cortes.value ?? const [],
    running: ref.watch(myRunningSettlementProvider).value,
  );
});

/// Monthly invoices, newest first. Keyed by company id; the empty string is
/// every company, the office's list.
final StreamProviderFamily<List<InsurerInvoice>, String> insurerInvoicesProvider =
    StreamProvider.family<List<InsurerInvoice>, String>(
  (ref, insurerId) => ref
      .watch(insurerRepositoryProvider)
      .watchInvoices(insurerId: insurerId.isEmpty ? null : insurerId),
);

final StreamProviderFamily<InsurerInvoice?, String> insurerInvoiceProvider =
    StreamProvider.family<InsurerInvoice?, String>(
  (ref, id) => ref.watch(insurerRepositoryProvider).watchInvoice(id),
);

/// The signed-in company's invoices, for its managers.
final myInsurerInvoicesProvider = StreamProvider<List<InsurerInvoice>>((ref) async* {
  final insurerId = await ref.watch(currentInsurerIdProvider.future);
  if (insurerId == null) {
    yield const [];
    return;
  }
  yield* ref.watch(insurerRepositoryProvider).watchInvoices(insurerId: insurerId);
});

/// The razón social, RNC and terms printed on invoices.
final fiscalIssuerProvider = StreamProvider<FiscalIssuer>(
  (ref) => ref.watch(insurerRepositoryProvider).watchFiscalIssuer(),
);

/// The NCF range insurers' invoices are numbered from.
final creditNcfSequenceProvider = StreamProvider<NcfSequence>(
  (ref) => ref.watch(insurerRepositoryProvider).watchNcfSequence(Ncf.creditoFiscal),
);

/// Every finished insurer service waiting for an invoice. The office's.
final servicesToInvoiceProvider = StreamProvider<List<Service>>(
  (ref) => ref.watch(insurerRepositoryProvider).watchServicesToInvoice(),
);

/// Every chofer's cortes, newest first. The office's cash screen.
final cashSettlementsProvider = StreamProvider<List<CashSettlement>>(
  (ref) => ref.watch(earningsRepositoryProvider).watchCashSettlements(),
);

/// The cash jobs a chofer collected and no corte counted yet.
final StreamProviderFamily<List<Service>, String> uncountedCashProvider =
    StreamProvider.family<List<Service>, String>(
  (ref, driverId) =>
      ref.watch(earningsRepositoryProvider).watchUncountedCash(driverId),
);

/// The one open offer addressed to this chofer. Drives the ringing screen.
final incomingOfferProvider = StreamProvider<Offer?>((ref) {
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return Stream.value(null);
  return ref.watch(offerRepositoryProvider).watchIncomingOffer(uid);
});

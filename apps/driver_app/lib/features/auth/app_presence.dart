import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

/// Tells the office this chofer has the app open, for as long as they are
/// signed in and it is running.
///
/// Watched from the app root rather than a screen, so it holds on the blocked
/// screen and the service screen alike: "the chofer can be reached" does not
/// depend on which page they are looking at. It is not the online switch —
/// a chofer with no grúa, or one on a break, is still connected.
final appPresenceProvider = Provider<void>((ref) {
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return;

  final subscription =
      ref.watch(driverRepositoryProvider).holdAppPresence(uid).listen(
            null,
            // Rules not deployed yet, or no signal: the office sees the chofer
            // as disconnected, which is wrong but harmless. Not worth a crash.
            onError: (Object error) => debugPrint('App presence: $error'),
          );
  ref.onDispose(() => unawaited(subscription.cancel()));
});

/// Whether the app could put this chofer online, and why not if it could not.
///
/// There is no switch. Opening the app is being at work: the chofer goes
/// online by themselves, and closing it takes them offline again — the server
/// does that half, from the presence connection dropping (see
/// `followAppPresence`), because a phone that is being force-quit runs no code
/// to say goodbye.
@immutable
class AutoOnlineState {
  const AutoOnlineState({this.connecting = false, this.failure});

  /// A call to go online is in flight.
  final bool connecting;

  /// The server's last refusal — no grúa, account inactive — shown on the home
  /// card instead of a switch that would only fail the same way.
  final Failure? failure;
}

/// Puts the chofer online whenever the app is open and they are not.
///
/// "Whenever", not "once at start-up": a dropped signal takes them offline
/// server-side, and when the app reconnects this is what brings them back —
/// without it a chofer who drove through a tunnel would stay invisible to
/// dispatch with the app open in front of them.
class AutoOnlineNotifier extends Notifier<AutoOnlineState> {
  /// After a failure, how long before trying again. A change to the record —
  /// an admin assigning a grúa, say — retries at once; this covers the
  /// failures nothing on the record will ever announce, a dropped signal among
  /// them, without turning a standing refusal into a loop of billed calls.
  static const retryAfter = Duration(seconds: 30);

  Timer? _retry;
  var _inFlight = false;

  @override
  AutoOnlineState build() {
    final driver = ref.watch(
      currentDriverProvider.select(
        (async) => switch (async.value) {
          final d? => (
              id: d.id,
              online: d.isOnline,
              canGoOnline: d.canGoOnline,
              truck: d.assignedTruckId,
              status: d.status,
            ),
          null => null,
        },
      ),
    );

    // Anything the chofer could fix changes this record, so a change starts
    // over rather than waiting out a retry meant for the old one.
    _retry?.cancel();
    ref.onDispose(() => _retry?.cancel());

    if (driver != null && !driver.online && driver.canGoOnline) {
      // Not inside build: a provider cannot change its own state while it is
      // being built.
      unawaited(Future.microtask(_goOnline));
    }
    return const AutoOnlineState();
  }

  Future<void> _goOnline() async {
    if (_inFlight) return;
    // Still wanted? The retry timer and the rebuild both land here, and by
    // then the chofer may be online, signed out, or suspended.
    final driver = ref.read(currentDriverProvider).value;
    if (driver == null || driver.isOnline || !driver.canGoOnline) return;

    _inFlight = true;
    state = const AutoOnlineState(connecting: true);

    final result =
        await ref.read(functionsGatewayProvider).setOnline(online: true);

    _inFlight = false;
    switch (result) {
      case Ok():
        state = const AutoOnlineState();
      case Err(:final failure):
        state = AutoOnlineState(failure: failure);
        debugPrint('Auto online refused: ${failure.userMessage}');
        _retry?.cancel();
        _retry = Timer(retryAfter, () => unawaited(_goOnline()));
    }
  }
}

final autoOnlineProvider =
    NotifierProvider<AutoOnlineNotifier, AutoOnlineState>(
  AutoOnlineNotifier.new,
);

/// Signs the chofer out, taking them offline and clearing their presence first.
///
/// The order matters: once the session is gone the rules refuse both writes,
/// and the office would see a signed-out chofer as online until the stale
/// sweep caught up with them.
Future<void> signOutDriver(WidgetRef ref) async {
  final uid = ref.read(currentUserIdProvider);
  if (uid != null) {
    // Refused mid-tow, and rightly: signing out does not end the job.
    await ref.read(functionsGatewayProvider).setOnline(online: false);
    await ref.read(driverRepositoryProvider).clearAppPresence(uid);
    // While the session still exists: the rules refuse it afterwards, and the
    // next chofer on this phone would get this one's offers.
    await ref
        .read(pushServiceProvider)
        .unregister(uid: uid, audience: PushAudience.driver);
  }
  await ref.read(authRepositoryProvider).signOut();
}

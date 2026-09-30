import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';

/// Whose tokens a device registers under — the server looks for a chofer's in
/// `drivers/{uid}/tokens` and a customer's in `users/{uid}/tokens`.
enum PushAudience { client, driver }

/// Push notifications on this device.
///
/// The server decides what is sent and to whom (`functions/src/lib/push.ts`);
/// the app's part is to be reachable — a token saved under the signed-in
/// account and removed again at sign-out — to show what arrives while it is
/// open, and to open the right screen when a notification is tapped.
abstract interface class PushService {
  /// Asks permission, then saves this device's token for [uid] and keeps it
  /// current. Safe to call again for the same user.
  Future<void> register({required String uid, required PushAudience audience});

  /// Removes this device's token from [uid]. Call before signing out: once the
  /// session is gone the rules refuse the delete, and the next person to use
  /// the phone would receive the previous one's notifications.
  Future<void> unregister({required String uid, required PushAudience audience});

  /// The `data` of every notification the user taps, including the one that
  /// launched the app.
  Stream<Map<String, String>> get opened;
}

/// Web and tests: nothing to register, nothing arrives.
class NoopPushService implements PushService {
  const NoopPushService();

  @override
  Future<void> register({
    required String uid,
    required PushAudience audience,
  }) async {}

  @override
  Future<void> unregister({
    required String uid,
    required PushAudience audience,
  }) async {}

  @override
  Stream<Map<String, String>> get opened => const Stream.empty();
}

final pushServiceProvider = Provider<PushService>(
  (_) => const NoopPushService(),
);

/// Keeps the signed-in user reachable by push, and hands tapped notifications
/// to [onOpen].
///
/// Sits once near the top of an app, under the router so [onOpen] can
/// navigate. Registration follows the session: a sign-in registers this
/// device, and the token is removed by whoever signs the user out (see
/// [PushService.unregister]).
class PushBinding extends ConsumerStatefulWidget {
  const PushBinding({
    required this.audience,
    required this.onOpen,
    required this.child,
    super.key,
  });

  final PushAudience audience;

  /// Called with a tapped notification's data once somebody is signed in.
  final void Function(Map<String, String> data) onOpen;
  final Widget child;

  @override
  ConsumerState<PushBinding> createState() => _PushBindingState();
}

class _PushBindingState extends ConsumerState<PushBinding> {
  StreamSubscription<Map<String, String>>? _taps;

  /// A tap that arrived before sign-in finished — usually the notification
  /// that launched the app — waits here until there is somebody to show it to.
  Map<String, String>? _pending;

  @override
  void initState() {
    super.initState();
    _taps = ref.read(pushServiceProvider).opened.listen(_open);
    final uid = ref.read(currentUserIdProvider);
    if (uid != null) _register(uid);
  }

  @override
  void dispose() {
    unawaited(_taps?.cancel());
    super.dispose();
  }

  void _register(String uid) => unawaited(
        ref
            .read(pushServiceProvider)
            .register(uid: uid, audience: widget.audience)
            .catchError((Object error) {
          debugPrint('[grua] push registration failed: $error');
        }),
      );

  void _open(Map<String, String> data) {
    if (ref.read(currentUserIdProvider) == null) {
      _pending = data;
      return;
    }
    widget.onOpen(data);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<String?>(currentUserIdProvider, (previous, uid) {
      if (uid == null || uid == previous) return;
      _register(uid);
      final pending = _pending;
      if (pending != null) {
        _pending = null;
        // After this frame, so the router has moved past the sign-in page.
        WidgetsBinding.instance.addPostFrameCallback((_) => widget.onOpen(pending));
      }
    });
    return widget.child;
  }
}

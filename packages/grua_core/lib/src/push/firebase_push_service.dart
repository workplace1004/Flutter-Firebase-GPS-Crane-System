import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../data/paths.dart';
import 'push_service.dart';

/// Push on Android and iOS, through Firebase Cloud Messaging.
///
/// Three kinds of message arrive, and each needs something different:
///
/// * **Notification messages** (service updates, chat, calls, cortes). The
///   system draws them when the app is in the background. In the foreground
///   Android draws nothing, so they are shown here; iOS is told to show them
///   itself.
/// * **The ringing offer**, which is data-only on Android so the open app can
///   show its own ringing screen. With the app in the background or closed,
///   nothing would appear at all, so [gruaPushBackgroundHandler] draws a
///   full-screen, high-priority notification for it. iOS gets an alert in the
///   APNs payload and needs no help.
/// * **`offer_cancelled`**, which takes that notification down again.
class FirebasePushService implements PushService {
  FirebasePushService({FirebaseMessaging? messaging})
      : _messaging = messaging ?? FirebaseMessaging.instance {
    unawaited(_listen());
  }

  final FirebaseMessaging _messaging;
  final _opened = StreamController<Map<String, String>>.broadcast();
  StreamSubscription<String>? _refresh;

  /// A tap from before anybody listened — the notification that launched the
  /// app — replayed to the first listener.
  Map<String, String>? _launchTap;

  @override
  Stream<Map<String, String>> get opened async* {
    final launch = _launchTap;
    if (launch != null) {
      _launchTap = null;
      yield launch;
    }
    yield* _opened.stream;
  }

  void _emitTap(Map<String, String> data) {
    if (_opened.hasListener) {
      _opened.add(data);
    } else {
      _launchTap = data;
    }
  }

  Future<void> _listen() async {
    await PushNotifications.initialize(onTap: _emitTap);

    // iOS shows a notification that arrives in the foreground only when asked.
    await _messaging.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );

    FirebaseMessaging.onMessage.listen(_onForeground);
    FirebaseMessaging.onMessageOpenedApp
        .listen((message) => _emitTap(_data(message)));

    final initial = await _messaging.getInitialMessage();
    if (initial != null) _emitTap(_data(initial));

    final launch = await PushNotifications.launchPayload();
    if (launch != null) _emitTap(launch);
  }

  Future<void> _onForeground(RemoteMessage message) async {
    final data = _data(message);
    switch (data['type']) {
      // The open app is already ringing with its own screen.
      case 'offer':
        return;
      case 'offer_cancelled':
        await PushNotifications.cancelOffer();
        return;
    }

    // iOS draws it (see setForegroundNotificationPresentationOptions);
    // Android would draw nothing.
    final notification = message.notification;
    if (notification == null || defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    await PushNotifications.show(
      title: notification.title ?? '',
      body: notification.body ?? '',
      channelId: notification.android?.channelId ?? PushChannels.serviceUpdates,
      data: data,
    );
  }

  @override
  Future<void> register({
    required String uid,
    required PushAudience audience,
  }) async {
    final settings = await _messaging.requestPermission();
    if (settings.authorizationStatus == AuthorizationStatus.denied) {
      debugPrint('[grua] push: notifications are turned off for this app');
      return;
    }

    // iOS hands out an FCM token only once APNs has given the device one.
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      for (var i = 0; i < 10 && await _messaging.getAPNSToken() == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }

    final token = await _messaging.getToken();
    if (token != null) await _save(uid, audience, token);

    await _refresh?.cancel();
    _refresh = _messaging.onTokenRefresh.listen(
      (token) => unawaited(_save(uid, audience, token)),
    );
  }

  @override
  Future<void> unregister({
    required String uid,
    required PushAudience audience,
  }) async {
    await _refresh?.cancel();
    _refresh = null;
    try {
      final token = await _messaging.getToken();
      if (token != null) await _tokens(uid, audience).doc(token).delete();
      // A fresh token for whoever signs in next.
      await _messaging.deleteToken();
    } on Object catch (error) {
      // Never blocks the sign-out; the server prunes tokens that stop working.
      debugPrint('[grua] push: could not remove the token ($error)');
    }
  }

  CollectionReference<Map<String, dynamic>> _tokens(
    String uid,
    PushAudience audience,
  ) =>
      audience == PushAudience.driver
          ? Paths.driverTokens(uid)
          : Paths.userTokens(uid);

  Future<void> _save(String uid, PushAudience audience, String token) =>
      // Keyed by the token, so registering the same phone again overwrites.
      _tokens(uid, audience).doc(token).set({
        'platform': defaultTargetPlatform.name,
        'updatedAt': FieldValue.serverTimestamp(),
      });

  static Map<String, String> _data(RemoteMessage message) =>
      message.data.map((key, value) => MapEntry(key, '$value'));
}

/// Runs in its own isolate when a message arrives with the app in the
/// background or closed. Only data-only messages need anything done: the
/// system has already drawn every message that carries a notification.
@pragma('vm:entry-point')
Future<void> gruaPushBackgroundHandler(RemoteMessage message) async {
  if (message.notification != null) return;
  if (Firebase.apps.isEmpty) await Firebase.initializeApp();

  final data = message.data.map((key, value) => MapEntry(key, '$value'));
  await PushNotifications.initialize();
  switch (data['type']) {
    case 'offer':
      await PushNotifications.showOffer(data);
    case 'offer_cancelled':
      await PushNotifications.cancelOffer();
  }
}

/// The Android channels. Their ids are the ones the server names in
/// `channelId`, so a notification sent to a channel lands in it.
abstract final class PushChannels {
  static const serviceUpdates = 'service_updates';
  static const chat = 'chat';
  static const offers = 'offers';

  static const _all = [
    AndroidNotificationChannel(
      serviceUpdates,
      'Estado del servicio',
      description: 'Tu grúa va en camino, llegó, terminó el servicio…',
      importance: Importance.high,
    ),
    AndroidNotificationChannel(
      chat,
      'Mensajes',
      description: 'Mensajes y solicitudes de chat.',
      importance: Importance.high,
    ),
  ];

  static const _offers = AndroidNotificationChannel(
    offers,
    'Nuevos servicios',
    description: 'Solicitudes de grúa para aceptar.',
    importance: Importance.max,
  );
}

/// Local notifications: what this app draws itself.
abstract final class PushNotifications {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static var _ready = false;

  /// One offer at a time; a newer one replaces it and a cancel removes it.
  static const _offerId = 7001;

  static Future<void> initialize({
    void Function(Map<String, String> data)? onTap,
  }) async {
    if (_ready && onTap == null) return;
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@drawable/ic_notification'),
        // Firebase asks for permission, at sign-in rather than at launch.
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
      onDidReceiveNotificationResponse: onTap == null
          ? null
          : (response) {
              final data = decodePayload(response.payload);
              if (data != null) onTap(data);
            },
    );
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    for (final channel in PushChannels._all) {
      await android?.createNotificationChannel(channel);
    }
    _ready = true;
  }

  /// The data of the local notification that launched the app, if one did.
  static Future<Map<String, String>?> launchPayload() async {
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details?.didNotificationLaunchApp != true) return null;
    return decodePayload(details?.notificationResponse?.payload);
  }

  static Future<void> show({
    required String title,
    required String body,
    required String channelId,
    required Map<String, String> data,
  }) async {
    final channel = PushChannels._all.firstWhere(
      (c) => c.id == channelId,
      orElse: () => PushChannels._all.first,
    );
    // Keyed on the service or chat, so a tow's steps replace each other
    // rather than stacking up.
    final key = data['serviceId'] ?? data['requestId'] ?? data['callId'];
    await _plugin.show(
      id: (key ?? '$title$body${DateTime.now()}').hashCode & 0x7fffffff,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          channel.id,
          channel.name,
          channelDescription: channel.description,
          importance: channel.importance,
          priority: Priority.high,
          icon: '@drawable/ic_notification',
          tag: key,
        ),
      ),
      payload: jsonEncode(data),
    );
  }

  /// The ringing offer, drawn when the app is not open to ring itself.
  static Future<void> showOffer(Map<String, String> data) async {
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(PushChannels._offers);

    final ttl = int.tryParse(data['ttlSeconds'] ?? '');
    await _plugin.show(
      id: _offerId,
      title: 'Nuevo servicio',
      body: offerSummary(data),
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          PushChannels._offers.id,
          PushChannels._offers.name,
          channelDescription: PushChannels._offers.description,
          importance: Importance.max,
          priority: Priority.max,
          icon: '@drawable/ic_notification',
          category: AndroidNotificationCategory.call,
          visibility: NotificationVisibility.public,
          // Rings over the lock screen like a call: a chofer on the road is
          // not looking at the phone.
          fullScreenIntent: true,
          // Gone once the offer has expired anyway.
          timeoutAfter: ttl == null ? 60000 : ttl * 1000,
        ),
      ),
      payload: jsonEncode(data),
    );
  }

  static Future<void> cancelOffer() => _plugin.cancel(id: _offerId);

  /// `A 3.2 km · Ganas RD$ 1,450` from the offer's data, as far as it goes.
  @visibleForTesting
  static String offerSummary(Map<String, String> data) {
    final parts = <String>[];
    final meters = int.tryParse(data['distanceM'] ?? '');
    if (meters != null) {
      parts.add(
        meters < 1000
            ? 'A $meters m'
            : 'A ${(meters / 1000).toStringAsFixed(1)} km',
      );
    }
    final cents = int.tryParse(data['netCents'] ?? '');
    if (cents != null && cents > 0) {
      final pesos = (cents / 100).round().toString().replaceAllMapped(
            RegExp(r'\B(?=(\d{3})+(?!\d))'),
            (_) => ',',
          );
      parts.add('Ganas RD\$ $pesos');
    }
    return parts.isEmpty ? 'Tienes una solicitud de grúa' : parts.join(' · ');
  }

  @visibleForTesting
  static Map<String, String>? decodePayload(String? payload) {
    if (payload == null || payload.isEmpty) return null;
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map) return null;
      return decoded.map((key, value) => MapEntry('$key', '$value'));
    } on FormatException {
      return null;
    }
  }
}

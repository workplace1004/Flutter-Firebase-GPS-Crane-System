import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

import '../../config/app_config.dart';
import '../../providers.dart';
import '../../push/firebase_push_service.dart';
import '../../push/push_service.dart';
import 'firebase_repositories.dart';
import 'functions_gateway.dart';

/// Brings Firebase up and binds the real repositories.
///
/// Kept separate from `runGruaApp` so a failure to connect is reported rather
/// than thrown: [initialize] says whether it succeeded, and the caller shows
/// an error screen instead of a crash.
abstract final class FirebaseBootstrap {
  /// True once [initialize] has connected successfully.
  static bool get isReady => _ready;
  static bool _ready = false;

  /// Why the last [initialize] gave up, for the screen that reports it.
  static Object? get initializationError => _error;
  static Object? _error;

  /// Initializes Firebase and, in a dev build, points the SDKs at the local
  /// emulator suite.
  ///
  /// Returns false rather than throwing when Firebase cannot be brought up,
  /// and keeps the reason in [initializationError].
  static Future<bool> initialize({
    required AppConfig config,
    FirebaseOptions? options,
  }) async {
    if (_ready) return true;

    try {
      await Firebase.initializeApp(options: options);
    } on Object catch (error) {
      _error = error;
      debugPrint(
        'Firebase could not be initialized ($error). '
        'Run `flutterfire configure` to connect a project.',
      );
      return false;
    }

    await _activateAppCheck(config);

    // Registered before anything else runs, so a push that wakes a closed app
    // finds its handler. Phones only: the panel and the web builds have no
    // background isolate to wake.
    if (_hasPush) {
      FirebaseMessaging.onBackgroundMessage(gruaPushBackgroundHandler);
    }

    if (config.useEmulators) await _useEmulators(config);

    // Lets the console's test phone numbers through with their fixed code and
    // no reCAPTCHA (web) or Play Integrity (Android) round trip. Debug builds
    // only - see AppConfig.disableAppVerification.
    if (config.disableAppVerification) {
      await FirebaseAuth.instance.setSettings(
        appVerificationDisabledForTesting: true,
      );
    }
    // Said out loud either way: "I passed the define" and "the define reached
    // the build" are different claims, and only this line settles it.
    if (kDebugMode) {
      debugPrint(
        '[grua] SMS app verification: '
        '${config.disableAppVerification ? "DISABLED (test numbers)" : "enabled"}',
      );
    }

    // Offline persistence is not a nicety here. A customer requesting a tow is
    // frequently on a highway with one bar, and a chofer's app must keep
    // rendering the job it already has when the signal drops.
    if (!kIsWeb) {
      FirebaseFirestore.instance.settings = const Settings(
        persistenceEnabled: true,
        cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED,
      );
    } else {
      // On the web, Firestore's default transport is WebChannel: one long-lived
      // streaming connection per listener. Plenty of networks between here and
      // Google — corporate proxies, some antivirus TLS inspectors, a few
      // Dominican ISPs, and anything doing IPv6 badly — accept the handshake
      // and then never deliver the stream, which the browser eventually reports
      // as ERR_CONNECTION_TIMED_OUT. The snapshot listener simply never fires,
      // so every screen sits on its spinner with nothing in the logs but a
      // timeout.
      //
      // Auto-detect gives the SDK one attempt at WebChannel and falls back to
      // long polling — ordinary XHR round trips, which those middleboxes pass —
      // when it does not come up. Forcing it outright would cost the office a
      // slower, chattier connection on networks where streaming works fine.
      FirebaseFirestore.instance.settings = const Settings(
        webExperimentalAutoDetectLongPolling: true,
      );
    }

    _ready = true;
    return true;
  }

  /// Mints the App Check token that every security rule requires.
  ///
  /// `firestore.rules` gates every read and write behind `ok()`, which is
  /// `isSignedIn() && request.app != null`. That second half is an App Check
  /// token, and a client that never calls `activate` does not have one — so
  /// being correctly signed in was never enough and every read came back
  /// permission-denied. It fails that way whether or not enforcement is
  /// switched on in the console, because it is the rules asking, not the
  /// enforcement setting.
  ///
  /// Debug builds use the debug providers, which print a token on first launch
  /// that has to be registered once per machine under App Check > Apps > Manage
  /// debug tokens. Until that is done the rules keep refusing, so the log line
  /// below says so rather than leaving somebody to infer it from a blank
  /// screen.
  static Future<void> _activateAppCheck(AppConfig config) async {
    // The emulator suite does not verify App Check tokens, and asking a debug
    // provider for one it cannot mint only adds a failing round trip.
    if (config.useEmulators) return;

    const debug = kDebugMode;
    final siteKey = config.recaptchaSiteKey;

    // `flutter run -d chrome` starts a fresh browser profile every launch, so
    // the debug token the JS SDK would generate and remember is a new one each
    // run: registered once, refused the next time. A fixed token passed as
    // APP_CHECK_DEBUG_TOKEN is registered once and keeps working.
    final debugToken =
        config.appCheckDebugToken.isEmpty ? null : config.appCheckDebugToken;

    if (kIsWeb && !debug && siteKey.isEmpty) {
      debugPrint(
        '[grua] App Check: no RECAPTCHA_SITE_KEY, so no token can be minted '
        'and Firestore will refuse every read. Pass '
        '--dart-define-from-file=config/prod.json.',
      );
      return;
    }

    try {
      await FirebaseAppCheck.instance.activate(
        // Enterprise, not v3: the console has deprecated plain reCAPTCHA for
        // App Check, and the web apps are registered with Enterprise keys.
        // A v3 provider against an Enterprise registration is refused.
        providerWeb: debug
            ? WebDebugProvider(debugToken: debugToken)
            : ReCaptchaEnterpriseProvider(siteKey),
        providerAndroid: debug
            ? AndroidDebugProvider(debugToken: debugToken)
            : const AndroidPlayIntegrityProvider(),
        // App Attest where the device supports it, DeviceCheck on the older
        // iPhones still in service around here.
        providerApple: debug
            ? AppleDebugProvider(debugToken: debugToken)
            : const AppleAppAttestWithDeviceCheckFallbackProvider(),
      );

      if (debug) {
        debugPrint(
          debugToken != null
              ? '[grua] App Check: debug provider active with the fixed '
                  'APP_CHECK_DEBUG_TOKEN. It must be registered under App Check '
                  '> Apps > Manage debug tokens, or Firestore refuses every read.'
              : '[grua] App Check: debug provider active with a generated token. '
                  'Register the token logged just above under App Check > Apps '
                  '> Manage debug tokens, or Firestore will refuse every read. '
                  'On web it changes every `flutter run`; pass '
                  '--dart-define=APP_CHECK_DEBUG_TOKEN=<uuid> to fix it.',
        );
      }
    } on Object catch (error) {
      // Never fatal. A failure here means reads get denied, which the screens
      // now report on their own; crashing at launch would say less, not more.
      debugPrint('[grua] App Check activation failed ($error).');
    }
  }

  static Future<void> _useEmulators(AppConfig config) async {
    final host = config.emulatorHost;
    debugPrint('Using Firebase emulators at $host');

    await FirebaseAuth.instance
        .useAuthEmulator(host, AppConfig.authEmulatorPort);

    FirebaseFirestore.instance
        .useFirestoreEmulator(host, AppConfig.firestoreEmulatorPort);

    FirebaseDatabase.instance
        .useDatabaseEmulator(host, AppConfig.databaseEmulatorPort);

    FirebaseFunctions.instanceFor(region: config.functionsRegion)
        .useFunctionsEmulator(host, AppConfig.functionsEmulatorPort);

    await FirebaseStorage.instance
        .useStorageEmulator(host, AppConfig.storageEmulatorPort);
  }

  /// Binds every repository to Firebase.
  ///
  /// The shape mirrors `demoOverrides` in `grua_testing` exactly, which is the
  /// point: a widget test swaps one for the other and no screen can tell.
  /// Android and iOS builds, the only ones that receive push here.
  static bool get _hasPush =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  static List<Override> overrides(AppConfig config) {
    final gateway = FirebaseFunctionsGateway(region: config.functionsRegion);

    return [
      if (_hasPush) pushServiceProvider.overrideWithValue(FirebasePushService()),
      authRepositoryProvider.overrideWithValue(FirebaseAuthRepository()),
      userRepositoryProvider
          .overrideWithValue(const FirestoreUserRepository()),
      driverRepositoryProvider.overrideWithValue(FirebaseDriverRepository()),
      truckRepositoryProvider
          .overrideWithValue(const FirestoreTruckRepository()),
      serviceRepositoryProvider
          .overrideWithValue(const FirestoreServiceRepository()),
      offerRepositoryProvider
          .overrideWithValue(const FirestoreOfferRepository()),
      callRepositoryProvider
          .overrideWithValue(const FirestoreCallRepository()),
      chatRepositoryProvider.overrideWithValue(const FirestoreChatRepository()),
      chatRequestRepositoryProvider
          .overrideWithValue(const FirestoreChatRequestRepository()),
      typingRepositoryProvider
          .overrideWithValue(const FirebaseTypingRepository()),
      chatPrefsRepositoryProvider
          .overrideWithValue(const FirestoreChatPrefsRepository()),
      earningsRepositoryProvider
          .overrideWithValue(const FirestoreEarningsRepository()),
      insurerRepositoryProvider
          .overrideWithValue(const FirestoreInsurerRepository()),
      invoiceRepositoryProvider
          .overrideWithValue(FirestoreInvoiceRepository(gateway: gateway)),
      configRepositoryProvider
          .overrideWithValue(const FirestoreConfigRepository()),
      functionsGatewayProvider.overrideWithValue(gateway),
    ];
  }
}

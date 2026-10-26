import 'package:driver_app/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';
import 'package:grua_testing/grua_testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:intl/date_symbol_data_local.dart';

/// The walkthrough behind the Play foreground-service (location) video.
///
/// The chofer signs in and is online, the location service's notification
/// comes up, and it stays while the app is in the background. Each `VIDEO:`
/// line is a cue for `scripts/location_video.ps1`, which records the screen
/// and does the system-side steps (notification shade, Home, back to the app).
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('location foreground service video', (tester) async {
    await initializeDateFormatting('es_DO');
    final backend = DemoBackend()..seed();

    const config = AppConfig(
      flavor: Flavor.prod,
      appKind: AppKind.driver,
      firebaseProjectId: 'demo',
      googleMapsApiKey: String.fromEnvironment('GOOGLE_MAPS_API_KEY'),
      useEmulators: false,
      emulatorHost: 'localhost',
      functionsRegion: 'us-east1',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appConfigProvider.overrideWithValue(config),
          ...demoOverrides(
            backend: backend,
            role: UserRole.driver,
            actingAs: 'driver-1',
          ),
        ],
        child: const DriverApp(),
      ),
    );
    await _wait(tester, 2);

    // Recording starts on the sign-in screen: going online is the user's own
    // action, and the video should show that it is.
    await _cue(tester, 'start', 2);
    await tester.enterText(
      find.byType(TextFormField).first,
      'driver1@gruasrd.do',
    );
    await tester.enterText(find.byType(TextFormField).last, 'secret123');
    await _wait(tester, 1);
    await tester.tap(find.text('ENTRAR'));
    // Signed in, online, the map comes in and the service starts.
    await _wait(tester, 10);

    await _cue(tester, 'shade', 6);
    await _cue(tester, 'collapse', 2);
    // In the background the engine draws no frames, and a pump would wait
    // for one forever: plain waits until the app is back in front.
    await _cue(tester, 'home', 6, background: true);
    await _cue(tester, 'shade', 6, background: true);
    await _cue(tester, 'collapse', 2, background: true);
    await _cue(tester, 'back', 5, background: true);
    await _cue(tester, 'stop', 3);
  }, timeout: const Timeout(Duration(minutes: 5)));
}

/// Pumps for [seconds] of real time; the map never settles.
Future<void> _wait(WidgetTester tester, int seconds) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Tells the script to do [name], then keeps the app running for [seconds].
Future<void> _cue(
  WidgetTester tester,
  String name,
  int seconds, {
  bool background = false,
}) async {
  debugPrint('VIDEO:$name');
  if (background) {
    await Future<void>.delayed(Duration(seconds: seconds));
  } else {
    await _wait(tester, seconds);
  }
}

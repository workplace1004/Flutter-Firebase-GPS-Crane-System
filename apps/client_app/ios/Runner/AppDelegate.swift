import Flutter
import GoogleMaps
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Read from the build environment so no key is committed. Empty is fine:
    // the app falls back to the drawn map.
    if let key = Bundle.main.object(forInfoDictionaryKey: "MapsApiKey") as? String,
       !key.isEmpty {
      GMSServices.provideAPIKey(key)
    }

    // Lets a notification that arrives with the app open show as a banner, and
    // hands taps on it to Flutter (firebase_messaging and
    // flutter_local_notifications both listen through this delegate).
    UNUserNotificationCenter.current().delegate = self

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}

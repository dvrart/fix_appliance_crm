import Flutter
import UIKit
import UserNotifications
#if canImport(GoogleMaps)
import GoogleMaps
#endif

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    #if canImport(GoogleMaps)
    if let rawKey = Bundle.main.object(forInfoDictionaryKey: "GMSApiKey") as? String {
      let trimmed = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty && !trimmed.hasPrefix("$(") && trimmed != "YOUR_GOOGLE_MAPS_API_KEY" {
        GMSServices.provideAPIKey(trimmed)
      }
    }
    #endif
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}

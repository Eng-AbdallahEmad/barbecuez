import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    UNUserNotificationCenter.current().requestAuthorization(
      options: [.alert, .badge, .sound]
    ) { _, _ in }
    application.registerForRemoteNotifications()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }

  // Fallback for iOS 12 and below (no SceneDelegate).
  override func application(
    _ application: UIApplication,
    continue userActivity: NSUserActivity,
    restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
  ) -> Bool {
    if userActivity.activityType == NSUserActivityTypeBrowsingWeb,
       let url = userActivity.webpageURL {
      SceneDelegate.storePendingLink(url)
    }
    return super.application(application, continue: userActivity, restorationHandler: restorationHandler)
  }

  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    SceneDelegate.storePendingLink(url)
    return super.application(app, open: url, options: options)
  }
}

// ---------------------------------------------------------------------------
// SceneDelegate — defined here so it is always compiled as part of AppDelegate.swift.
// Info.plist UISceneDelegateClassName = "SceneDelegate"
// ---------------------------------------------------------------------------

@objc(SceneDelegate)
class SceneDelegate: FlutterSceneDelegate {

  // MARK: - Cold start

  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    // ⚠️ Store the URL BEFORE calling super.
    // super.scene() starts the Flutter engine, which may immediately read
    // SharedPreferences on the Dart thread. If we call storePendingLink AFTER
    // super, there is a race condition where Flutter reads UserDefaults before
    // the URL has been written — causing _handlePendingDeepLink to find nothing.
    if let activity = connectionOptions.userActivities.first(where: {
      $0.activityType == NSUserActivityTypeBrowsingWeb
    }), let url = activity.webpageURL {
      NSLog("[SceneDelegate] Cold-start Universal Link: %@", url.absoluteString)
      SceneDelegate.storePendingLink(url)
    } else if let urlContext = connectionOptions.urlContexts.first {
      NSLog("[SceneDelegate] Cold-start URL context: %@", urlContext.url.absoluteString)
      SceneDelegate.storePendingLink(urlContext.url)
    } else {
      NSLog("[SceneDelegate] willConnectTo — no Universal Link or URL context")
    }

    super.scene(scene, willConnectTo: session, options: connectionOptions)
  }

  // MARK: - Warm start

  override func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    // Store before super for the same race-condition reason.
    if userActivity.activityType == NSUserActivityTypeBrowsingWeb,
       let url = userActivity.webpageURL {
      NSLog("[SceneDelegate] Warm-start Universal Link: %@", url.absoluteString)
      SceneDelegate.storePendingLink(url)
    }
    super.scene(scene, continue: userActivity)
  }

  override func scene(_ scene: UIScene, openURLContexts urlContexts: Set<UIOpenURLContext>) {
    if let urlContext = urlContexts.first {
      NSLog("[SceneDelegate] Warm-start URL context: %@", urlContext.url.absoluteString)
      SceneDelegate.storePendingLink(urlContext.url)
    }
    super.scene(scene, openURLContexts: urlContexts)
  }

  // MARK: - Storage

  /// Writes the URL to UserDefaults under the key shared_preferences uses on iOS.
  /// shared_preferences_foundation prefixes all keys with "flutter." so
  /// prefs.getString('pending_deep_link') reads from "flutter.pending_deep_link".
  static func storePendingLink(_ url: URL) {
    UserDefaults.standard.set(url.absoluteString, forKey: "flutter.pending_deep_link")
    NSLog("[SceneDelegate] Stored pending_deep_link = %@", url.absoluteString)
  }
}

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
// SceneDelegate — defined here so it is always compiled as part of AppDelegate.swift
// (no separate file needs to be added to the Xcode target).
// Info.plist UISceneDelegateClassName = "Runner.SceneDelegate"
// ---------------------------------------------------------------------------

/// Subclass of FlutterSceneDelegate that explicitly captures Universal Links
/// and custom-scheme URLs, writing them to UserDefaults so Flutter can read
/// them via shared_preferences (_handlePendingDeepLink).
///
/// FlutterSceneDelegate does not consistently forward scene:continue: to the
/// app_links plugin, causing iOS to wait ~1 s and then fall back to Safari.
@objc(SceneDelegate)
class SceneDelegate: FlutterSceneDelegate {

  // MARK: - Cold start

  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)

    // Universal Link delivered at launch
    if let activity = connectionOptions.userActivities.first(where: {
      $0.activityType == NSUserActivityTypeBrowsingWeb
    }), let url = activity.webpageURL {
      SceneDelegate.storePendingLink(url)
      return
    }

    // Custom URL scheme (barbecuez://) delivered at launch
    if let urlContext = connectionOptions.urlContexts.first {
      SceneDelegate.storePendingLink(urlContext.url)
    }
  }

  // MARK: - Warm start

  override func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    super.scene(scene, continue: userActivity)
    if userActivity.activityType == NSUserActivityTypeBrowsingWeb,
       let url = userActivity.webpageURL {
      SceneDelegate.storePendingLink(url)
    }
  }

  override func scene(_ scene: UIScene, openURLContexts urlContexts: Set<UIOpenURLContext>) {
    super.scene(scene, openURLContexts: urlContexts)
    if let urlContext = urlContexts.first {
      SceneDelegate.storePendingLink(urlContext.url)
    }
  }

  // MARK: - Storage

  /// Writes the URL to UserDefaults under the key shared_preferences uses on iOS.
  /// Flutter reads it via: prefs.getString('pending_deep_link')
  static func storePendingLink(_ url: URL) {
    UserDefaults.standard.set(url.absoluteString, forKey: "flutter.pending_deep_link")
  }
}

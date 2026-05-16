import Flutter
import UIKit

/// Custom scene delegate that explicitly captures Universal Links and custom
/// URL scheme launches, storing them in UserDefaults so Flutter can reliably
/// read them via shared_preferences (_handlePendingDeepLink).
///
/// FlutterSceneDelegate does not consistently forward scene:continue: to the
/// app_links plugin, causing the 1-second iOS Universal Link fallback to
/// Safari. This subclass intercepts all three entry points and writes the URL
/// under the "flutter." key prefix that shared_preferences uses on iOS.
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
      storePendingLink(url)
      return
    }

    // Custom URL scheme (barbecuez://) delivered at launch
    if let urlContext = connectionOptions.urlContexts.first {
      storePendingLink(urlContext.url)
    }
  }

  // MARK: - Warm start

  override func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    super.scene(scene, continue: userActivity)
    if userActivity.activityType == NSUserActivityTypeBrowsingWeb,
       let url = userActivity.webpageURL {
      storePendingLink(url)
    }
  }

  override func scene(_ scene: UIScene, openURLContexts urlContexts: Set<UIOpenURLContext>) {
    super.scene(scene, openURLContexts: urlContexts)
    if let urlContext = urlContexts.first {
      storePendingLink(urlContext.url)
    }
  }

  // MARK: - Storage

  private func storePendingLink(_ url: URL) {
    // shared_preferences_foundation stores keys with the "flutter." prefix in
    // NSUserDefaults, so prefs.getString('pending_deep_link') maps to this key.
    UserDefaults.standard.set(url.absoluteString, forKey: "flutter.pending_deep_link")
  }
}

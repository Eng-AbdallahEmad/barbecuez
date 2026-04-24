import 'dart:io';
import 'package:app_tracking_transparency/app_tracking_transparency.dart';
import 'package:flutter/material.dart';

class TrackingService {
  static bool _resolved = false;

  /// Call this once before loading any WebView.
  /// On Android → does nothing, returns immediately.
  /// On iOS → shows ATT dialog if not asked before.
  static Future<void> requestPermissionIfNeeded(BuildContext context) async {
    if (!Platform.isIOS) return; // Android: no ATT needed
    if (_resolved) return;

    // Small delay so the app's first frame renders before the system dialog
    await Future.delayed(const Duration(milliseconds: 500));

    final status = await AppTrackingTransparency.trackingAuthorizationStatus;

    // Already decided before (allow or deny) — nothing to show
    if (status == TrackingStatus.authorized ||
        status == TrackingStatus.denied ||
        status == TrackingStatus.restricted) {
      _resolved = true;
      return;
    }

    // Show the native ATT dialog
    if (context.mounted) {
      await AppTrackingTransparency.requestTrackingAuthorization();
    }

    _resolved = true;
  }

  /// Returns true if tracking is allowed (or we're on Android).
  /// Use this if you want to conditionally load analytics.
  static Future<bool> isTrackingAllowed() async {
    if (!Platform.isIOS) return true;
    final status = await AppTrackingTransparency.trackingAuthorizationStatus;
    return status == TrackingStatus.authorized;
  }
}
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// Flutter bridge to iOS Live Activities + Dynamic Island.
/// Only active on iOS 16.1+; all methods are no-ops on Android / older iOS.
class LiveActivityService {
  static const _method = MethodChannel('com.barbecuez.app/live_activity');
  static const _event  = EventChannel('com.barbecuez.app/live_activity_token');

  static StreamSubscription<dynamic>? _tokenSub;

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Starts a Live Activity for the given order.
  /// Returns the activityId, or null if unsupported / failed.
  static Future<String?> start({
    required String orderNumber,
    required String orderType,
    required String totalAmount,
    required String status,
    required String statusLabel,
    required int    etaMinutes,
    double progress       = 0.1,
    String? driverName,
    String? driverPhone,
  }) async {
    if (!Platform.isIOS) return null;
    try {
      final res = await _method.invokeMapMethod<String, dynamic>('start', {
        'orderNumber': orderNumber,
        'orderType':   orderType,
        'totalAmount': totalAmount,
        'status':      status,
        'statusLabel': statusLabel,
        'etaMinutes':  etaMinutes,
        'progress':    progress,
        if (driverName  != null) 'driverName':  driverName,
        if (driverPhone != null) 'driverPhone': driverPhone,
      });
      return res?['activityId'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// Updates the running Live Activity.
  static Future<void> update({
    required String status,
    required String statusLabel,
    required int    etaMinutes,
    double progress      = 0.5,
    String? driverName,
    String? driverPhone,
  }) async {
    if (!Platform.isIOS) return;
    try {
      await _method.invokeMethod<void>('update', {
        'status':      status,
        'statusLabel': statusLabel,
        'etaMinutes':  etaMinutes,
        'progress':    progress,
        if (driverName  != null) 'driverName':  driverName,
        if (driverPhone != null) 'driverPhone': driverPhone,
      });
    } catch (_) {}
  }

  /// Ends the Live Activity (shows "delivered" state for 60 s, then dismisses).
  static Future<void> end({String statusLabel = 'Order delivered!'}) async {
    if (!Platform.isIOS) return;
    try {
      await _method.invokeMethod<void>('end', {'statusLabel': statusLabel});
    } catch (_) {}
  }

  /// Returns the current APNs push token for the active Live Activity, or null.
  static Future<String?> getPushToken() async {
    if (!Platform.isIOS) return null;
    try {
      final res = await _method.invokeMapMethod<String, dynamic>('getPushToken');
      return res?['token'] as String?;
    } catch (_) {
      return null;
    }
  }

  // ── Push token stream ───────────────────────────────────────────────────────

  /// Listens for push token updates from the native side.
  /// [onToken] receives {token, activityId} whenever the token changes.
  static StreamSubscription<dynamic> listenForPushToken(
    void Function(String token, String activityId) onToken,
  ) {
    _tokenSub?.cancel();
    _tokenSub = _event.receiveBroadcastStream().listen((dynamic event) {
      if (event is Map) {
        final token      = event['token']      as String? ?? '';
        final activityId = event['activityId'] as String? ?? '';
        if (token.isNotEmpty) onToken(token, activityId);
      }
    });
    return _tokenSub!;
  }

  static void cancelTokenListener() => _tokenSub?.cancel();
}

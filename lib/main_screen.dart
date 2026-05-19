import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../main.dart';
import '../services/tracking_token_store.dart';

// ─── Tab config ───────────────────────────────────────────────────────────────

class _TabConfig {
  final String label;
  final IconData icon;
  final String url;

  const _TabConfig({
    required this.label,
    required this.icon,
    required this.url,
  });
}

const List<_TabConfig> _tabs = [
  _TabConfig(label: 'Home',    icon: Icons.home_outlined,            url: 'https://barbecuez.no'),
  _TabConfig(label: 'Menu',    icon: Icons.restaurant_menu_outlined,  url: 'https://barbecuez.no/menu'),
  _TabConfig(label: 'Contact', icon: Icons.info_outline,              url: 'https://barbecuez.no/contact'),
];

// ─── Trusted origins ──────────────────────────────────────────────────────────

const Set<String> _trustedHosts = {
  'barbecuez.no',
  'www.barbecuez.no',
  'barbecuez.lovable.app',
};

// ─── MainScreen ───────────────────────────────────────────────────────────────

class MainScreen extends StatefulWidget {
  final String? initialUrl;
  const MainScreen({super.key, this.initialUrl});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {

  @override
  bool get wantKeepAlive => true;

  int _currentIndex = 0;

  final List<InAppWebViewController?> _webControllers =
      List.filled(_tabs.length, null);
  final List<String?> _currentUrls = List.filled(_tabs.length, null);

  final List<GlobalKey> _tabKeys =
      List.generate(_tabs.length, (_) => GlobalKey());

  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _appLinksSub;

  // ── OneSignal bridge ─────────────────────────────────────────────────────
  String? _cachedPlayerId;
  Timer? _playerIdRetryTimer;
  Timer? _heartbeatTimer;
  final Set<int> _injectingControllers = {};
  final Map<int, DateTime> _lastSuccessfulInjection = {};
  bool _disposed = false;
  static const int _kMaxWebReadinessRetries = 4;
  static const Duration _kHeartbeatInterval = Duration(seconds: 45);
  // ─────────────────────────────────────────────────────────────────────────

  // ── localStorage consent cache ────────────────────────────────────────────
  // Snapshot of barbecuez.no localStorage, kept in sync with every onLoadStop
  // and persisted to SharedPreferences so consent survives app restarts.
  //
  // On each fresh WebView load a UserScript fires at AT_DOCUMENT_START to
  // pre-populate localStorage before any page JS runs — this prevents the
  // cookie-consent banner from appearing on tabs that haven't set it yet.
  Map<String, String> _lsCache = {};
  static const String _kLsCachePrefsKey = 'webview_localstorage_snapshot';
  late final Future<void> _lsCacheReady;
  // ─────────────────────────────────────────────────────────────────────────

  // Player-ID UUID pattern — OneSignal always issues UUIDs.
  static final _playerIdRe = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    caseSensitive: false,
  );

  final String allowedDomain = 'barbecuez.no';
  DateTime? _lastBackPressed;
  String? _lastHandledUrl;
  DateTime? _lastHandledTime;

  // ─── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Start loading the localStorage cache immediately so it is ready when
    // the first WebView is created.
    _lsCacheReady = _loadLsCache();

    _handlePendingDeepLink();
    _initFirebaseNotifications();
    _initOneSignal();
    _initDeepLinks();

    onNotificationDeepLink = _handleIncomingLink;

    _playerIdRetryTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _tryFetchAndInjectPlayerId(),
    );

    _heartbeatTimer = Timer.periodic(
      _kHeartbeatInterval,
      (_) => _heartbeatTick(),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    if (onNotificationDeepLink == _handleIncomingLink) {
      onNotificationDeepLink = null;
    }
    WidgetsBinding.instance.removeObserver(this);
    _playerIdRetryTimer?.cancel();
    _heartbeatTimer?.cancel();
    _appLinksSub?.cancel();
    _injectingControllers.clear();
    _lastSuccessfulInjection.clear();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      _handlePendingDeepLink();
      for (final controller in _webControllers) {
        if (controller != null) {
          _injectTrackingTokens(controller);
          _injectPlayerIdIntoWebView(controller);
        }
      }
    }
  }

  // ─── Controller cleanup ──────────────────────────────────────────────────────

  void _cleanupControllerState(int hashCode) {
    _injectingControllers.remove(hashCode);
    _lastSuccessfulInjection.remove(hashCode);
  }

  // ─── localStorage consent cache ──────────────────────────────────────────────

  // Keys that contain auth credentials — never pre-inject these into other tabs.
  // Supabase stores sessions under "sb-*-auth-token"; we block all sb-* and
  // any key containing common auth-token substrings.
  static bool _isAuthKey(String key) {
    final k = key.toLowerCase();
    return k.startsWith('sb-') ||
        k.contains('supabase') ||
        k.contains('access_token') ||
        k.contains('refresh_token') ||
        k.contains('auth.token') ||
        k.contains('.session');
  }

  Future<void> _loadLsCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kLsCachePrefsKey);
      if (raw != null && raw.isNotEmpty) {
        final m = jsonDecode(raw);
        if (m is Map) {
          _lsCache = Map.fromEntries(
            m.entries.map((e) => MapEntry(e.key.toString(), e.value.toString())),
          );
        }
      }
    } catch (_) {}
  }

  Future<void> _saveLsCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kLsCachePrefsKey, jsonEncode(_lsCache));
    } catch (_) {}
  }

  /// Reads all localStorage from [controller], merges new/changed keys into
  /// [_lsCache], persists to SharedPreferences, and refreshes the preload
  /// UserScript on every controller so future page loads see the consent key
  /// before any page JS runs.
  Future<void> _captureAndSyncLs(InAppWebViewController controller) async {
    if (_disposed) return;

    // Only capture from trusted origin pages.
    final currentUrl = await controller.getUrl();
    if (currentUrl == null || !_trustedHosts.contains(currentUrl.host)) return;

    try {
      final raw = await controller.evaluateJavascript(source: '''
        (function() {
          try {
            var d = {};
            for (var i = 0; i < localStorage.length; i++) {
              var k = localStorage.key(i);
              if (k) d[k] = localStorage.getItem(k) || '';
            }
            return JSON.stringify(d);
          } catch(e) { return null; }
        })();
      ''');
      if (raw == null || raw == 'null' || raw.isEmpty) return;

      final map = jsonDecode(raw.toString()) as Map<String, dynamic>;
      bool changed = false;
      for (final e in map.entries) {
        final v = e.value?.toString() ?? '';
        if (_lsCache[e.key] != v) {
          _lsCache[e.key] = v;
          changed = true;
        }
      }
      if (changed) {
        await _saveLsCache();
        await _refreshAllPreloadScripts();
      }
    } catch (_) {}
  }

  /// Builds a JS IIFE that, at AT_DOCUMENT_START, pre-populates localStorage
  /// with cached values — but ONLY for keys that are absent, so it never
  /// overwrites fresh values the website has already set.
  ///
  /// Auth tokens are excluded: they must come from the website's own auth flow.
  String _buildPreloadScript() {
    final safe = Map.fromEntries(
      _lsCache.entries.where((e) => !_isAuthKey(e.key)),
    );
    if (safe.isEmpty) return '';

    final jsonStr = jsonEncode(safe);
    return '''
      (function(c){
        try{
          Object.keys(c).forEach(function(k){
            if(localStorage.getItem(k)===null){
              localStorage.setItem(k,c[k]);
            }
          });
        }catch(e){}
      })(${jsonStr});
    ''';
  }

  Future<void> _refreshPreloadScript(InAppWebViewController controller) async {
    if (_disposed) return;
    final script = _buildPreloadScript();
    try {
      // Remove old preload scripts and add the freshly-built one.
      // AT_DOCUMENT_START fires before any page JS — the consent key will be
      // present when the website's React/Vue bundle reads it.
      await controller.removeAllUserScripts();
      if (script.isNotEmpty) {
        await controller.addUserScript(
          userScript: UserScript(
            source: script,
            injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
            allowedOriginRules: const {
              'https://barbecuez.no',
              'https://www.barbecuez.no',
              'https://barbecuez.lovable.app',
            },
          ),
        );
      }
    } catch (_) {}
  }

  Future<void> _refreshAllPreloadScripts() async {
    if (_disposed) return;
    for (final c in _webControllers) {
      if (c != null) await _refreshPreloadScript(c);
    }
  }

  // ─── Heartbeat ───────────────────────────────────────────────────────────────

  Future<void> _heartbeatTick() async {
    if (_disposed || _cachedPlayerId == null) return;

    for (int i = 0; i < _webControllers.length; i++) {
      final controller = _webControllers[i];
      if (controller == null) continue;
      final cid = controller.hashCode;

      try {
        final raw = await controller.evaluateJavascript(
          source: _buildHeartbeatScript(),
        );
        if (raw == null || raw == 'null' || raw.isEmpty) continue;

        final data = jsonDecode(raw.toString()) as Map<String, dynamic>;
        final ssValue = data['sessionStorage'] as String?;
        final ssOk = ssValue == _cachedPlayerId;
        final lastInj = _lastSuccessfulInjection[cid];
        final ageSecs =
            lastInj != null ? DateTime.now().difference(lastInj).inSeconds : null;

        if (kDebugMode) {
          debugPrint(
            '[OneSignalBridge] 💓 tab=$i cid=$cid '
            'ss=${ssOk ? "✅" : "❌($ssValue)"} '
            'lastInj=${ageSecs != null ? "${ageSecs}s ago" : "never"}',
          );
        }

        if (!ssOk) await _injectPlayerIdIntoWebView(controller);
      } catch (_) {}
    }
  }

  // ─── Pending deep link ───────────────────────────────────────────────────────

  Future<void> _handlePendingDeepLink() async {
    final prefs = await SharedPreferences.getInstance();
    final pendingUrl = prefs.getString('pending_deep_link');
    if (kDebugMode) {
      debugPrint('[DeepLink] pending="${pendingUrl ?? 'null'}"');
    }
    if (pendingUrl != null && pendingUrl.isNotEmpty) {
      await prefs.remove('pending_deep_link');
      await _handleIncomingLink(Uri.parse(pendingUrl));
    }
  }

  // ─── Tracking tokens ─────────────────────────────────────────────────────────

  Future<void> _injectTrackingTokens(InAppWebViewController controller) async {
    try {
      final tokens = await TrackingTokenStore.readAll();
      if (tokens.isEmpty) return;
      final json = jsonEncode(tokens);
      await controller.evaluateJavascript(source: '''
        (function() {
          if (window.__setTrackingTokens) {
            window.__setTrackingTokens($json);
          } else {
            setTimeout(function() {
              if (window.__setTrackingTokens) window.__setTrackingTokens($json);
            }, 500);
          }
        })();
      ''');
    } catch (_) {}
  }

  // ─── Deep links ──────────────────────────────────────────────────────────────

  Future<void> _initDeepLinks() async {
    try {
      final Uri? initialUri = await _appLinks.getInitialLink();
      if (initialUri != null) await _handleIncomingLink(initialUri);
    } catch (e) {
      if (kDebugMode) debugPrint('Deep link getInitialLink error: $e');
    }

    _appLinksSub = _appLinks.uriLinkStream.listen(
      (Uri uri) async {
        try {
          await _handleIncomingLink(uri);
        } catch (e) {
          if (kDebugMode) debugPrint('Deep link handle error: $e');
        }
      },
      onError: (e) {
        if (kDebugMode) debugPrint('Deep link stream error: $e');
      },
    );
  }

  Future<void> _handleIncomingLink(Uri uri) async {
    if (kDebugMode) debugPrint('Incoming deep link: $uri');

    final isRootUrl = (uri.path.isEmpty || uri.path == '/') &&
        _trustedHosts.contains(uri.host);
    final urlForDedup =
        isRootUrl ? '${uri.scheme}://${uri.host}/' : uri.toString();

    final now = DateTime.now();
    if (_lastHandledUrl == urlForDedup &&
        _lastHandledTime != null &&
        now.difference(_lastHandledTime!) < const Duration(seconds: 30)) {
      if (kDebugMode) {
        debugPrint('[DeepLink] Ignoring duplicate within 30 s: $urlForDedup');
      }
      return;
    }
    _lastHandledUrl = urlForDedup;
    _lastHandledTime = now;

    if (uri.scheme == 'barbecuez') {
      final path = uri.host.isNotEmpty ? '/${uri.host}${uri.path}' : uri.path;
      final converted = Uri(
        scheme: 'https',
        host: allowedDomain,
        path: path.isEmpty ? '/' : path,
        queryParameters:
            uri.queryParameters.isEmpty ? null : uri.queryParameters,
      );
      if (kDebugMode) debugPrint('Custom scheme converted → $converted');
      await _handleIncomingLink(converted);
      return;
    }

    if (!_trustedHosts.contains(uri.host)) return;

    if (uri.path == '/order-tracking') {
      final orderNumber = uri.queryParameters['order'];
      final token = uri.queryParameters['tt'];

      if (orderNumber != null && token != null && token.isNotEmpty) {
        await TrackingTokenStore.set(orderNumber, token);
      }

      String targetUrl = 'https://$allowedDomain/order-tracking';
      if (orderNumber != null && orderNumber.isNotEmpty) {
        final savedToken = await TrackingTokenStore.get(orderNumber);
        if (savedToken != null && savedToken.isNotEmpty) {
          targetUrl =
              'https://$allowedDomain/order-tracking?order=$orderNumber&tt=$savedToken';
        } else {
          targetUrl =
              'https://$allowedDomain/order-tracking?order=$orderNumber';
        }
      }

      _switchToTab(0);
      await _loadUrlInTab(0, targetUrl);
      return;
    }

    if (uri.path.startsWith('/menu')) {
      _switchToTab(1);
      await _loadUrlInTab(1, uri.toString());
      return;
    }

    _switchToTab(0);
    if (!isRootUrl) {
      await _loadUrlInTab(0, uri.toString());
    }
  }

  void _switchToTab(int index) {
    if (mounted) setState(() => _currentIndex = index);
  }

  Future<void> _resetTab(int index) async {
    final controller = _webControllers[index];
    if (controller != null) {
      await controller.loadUrl(
        urlRequest: URLRequest(url: WebUri(_tabs[index].url)),
      );
    } else {
      _currentUrls[index] = null;
    }
  }

  Future<void> _syncLocalStorageToController(
      InAppWebViewController controller) async {
    final homeController = _webControllers[0];
    if (homeController == null) return;

    final storageJson = await homeController.evaluateJavascript(source: '''
      (function() {
        var d = {};
        for (var i = 0; i < localStorage.length; i++) {
          var k = localStorage.key(i);
          d[k] = localStorage.getItem(k);
        }
        return JSON.stringify(d);
      })()
    ''');

    if (storageJson == null || storageJson == 'null') return;

    await controller.evaluateJavascript(source: '''
      (function(json) {
        try {
          var d = JSON.parse(json);
          if (!d || Object.keys(d).length === 0) return;
          Object.keys(d).forEach(function(k) {
            var oldVal = localStorage.getItem(k);
            var newVal = d[k];
            localStorage.setItem(k, newVal);
            if (oldVal !== newVal) {
              try {
                window.dispatchEvent(new StorageEvent('storage', {
                  key: k, oldValue: oldVal, newValue: newVal,
                  url: window.location.href, storageArea: window.localStorage
                }));
              } catch(e) {}
            }
          });
          window.dispatchEvent(new StorageEvent('storage', {
            key: null, url: window.location.href,
            storageArea: window.localStorage
          }));
        } catch(e) {}
      })($storageJson);
    ''');
  }

  Future<void> _loadUrlInTab(int tabIndex, String url) async {
    final controller = _webControllers[tabIndex];
    if (controller != null) {
      final escaped = url.replaceAll("'", r"\'");
      try {
        await controller.evaluateJavascript(
          source: "window.location.href = '$escaped';",
        );
      } catch (_) {
        await controller.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
      }
    } else {
      _currentUrls[tabIndex] = url;
    }
  }

  // ─── OneSignal bridge ────────────────────────────────────────────────────────

  Future<void> _tryFetchAndInjectPlayerId() async {
    if (_disposed) return;
    final id = OneSignal.User.pushSubscription.id;
    if (id != null && id.isNotEmpty) {
      if (_cachedPlayerId == id) {
        _playerIdRetryTimer?.cancel();
        return;
      }
      // Validate UUID format before accepting.
      if (!_playerIdRe.hasMatch(id)) {
        if (kDebugMode) debugPrint('[OneSignalBridge] ⚠️ Rejected malformed player_id');
        return;
      }
      _cachedPlayerId = id;
      _playerIdRetryTimer?.cancel();
      if (kDebugMode) debugPrint('[OneSignalBridge] ✅ Player ID: $_cachedPlayerId');
      await _injectPlayerIdIntoAllWebViews();
    }
  }

  Future<void> _injectPlayerIdIntoAllWebViews() async {
    if (_disposed) return;
    for (final controller in _webControllers) {
      if (controller != null) {
        await _injectPlayerIdIntoWebView(controller);
      }
    }
  }

  Future<void> _injectPlayerIdIntoWebView(
      InAppWebViewController controller) async {
    if (_disposed) return;

    final playerId = _cachedPlayerId;
    if (playerId == null || playerId.isEmpty) return;

    final cid = controller.hashCode;
    if (_injectingControllers.contains(cid)) return;
    _injectingControllers.add(cid);

    final sw = Stopwatch()..start();
    int retries = 0;
    bool success = false;

    try {
      final escaped =
          playerId.replaceAll(r'\', r'\\').replaceAll("'", r"\'");

      for (int attempt = 0; attempt <= _kMaxWebReadinessRetries; attempt++) {
        if (_disposed) return;

        if (attempt > 0) {
          final ms = 200 * (1 << (attempt - 1));
          await Future.delayed(Duration(milliseconds: ms));
          if (_disposed) return;
          retries++;
        }

        Map<String, dynamic>? res;
        try {
          final raw = await controller.evaluateJavascript(
            source: _buildInjectionJs(escaped),
          );
          if (raw != null && raw != 'null' && raw.isNotEmpty) {
            res = jsonDecode(raw.toString()) as Map<String, dynamic>?;
          }
        } catch (_) {
          if (attempt < _kMaxWebReadinessRetries) continue;
          break;
        }

        if (res == null) {
          if (attempt < _kMaxWebReadinessRetries) continue;
          break;
        }

        final notReady = res['notReady'] as bool? ?? false;
        final jsOk    = res['success']  as bool? ?? false;

        if (notReady) {
          if (attempt < _kMaxWebReadinessRetries) continue;
          break;
        }
        if (jsOk) {
          success = true;
          _lastSuccessfulInjection[cid] = DateTime.now();
          break;
        }
        if (attempt < _kMaxWebReadinessRetries) continue;
      }
    } finally {
      _injectingControllers.remove(cid);
      sw.stop();
      if (kDebugMode) {
        debugPrint(
          '[OneSignalBridge] ${success ? "✅" : "❌"} '
          'cid=$cid ${sw.elapsedMilliseconds}ms retries=$retries',
        );
      }
    }
  }

  Future<void> _installSpaNavigationHook(
      InAppWebViewController controller) async {
    if (_disposed) return;
    final escaped = (_cachedPlayerId ?? '')
        .replaceAll(r'\', r'\\')
        .replaceAll("'", r"\'");
    try {
      await controller.evaluateJavascript(
        source: _buildSpaHookScript(escaped),
      );
    } catch (_) {}
  }

  // ─── JS builders ─────────────────────────────────────────────────────────────

  String _buildInjectionJs(String escapedId) => """
    (function() {
      var r = {
        success: false, sessionStorage: false, localStorage: false,
        playerId: null, notReady: false, error: null, url: window.location.href
      };
      try {
        var pid = '$escapedId';
        if (window.__BARBECUEZ_WEB_READY === false) {
          r.notReady = true;
          return JSON.stringify(r);
        }
        sessionStorage.setItem('customer_onesignal_player_id', pid);
        localStorage.setItem('customer_onesignal_player_id', pid);
        window.oneSignalPlayerId = pid;
        window.__BARBECUEZ_PLAYER_ID = pid;
        window.dispatchEvent(new CustomEvent('pushTokenReady',       { detail: { playerId: pid, player_id: pid } }));
        window.dispatchEvent(new CustomEvent('nativePushTokenReady', { detail: { playerId: pid, player_id: pid, source: 'native' } }));
        var ssVal = sessionStorage.getItem('customer_onesignal_player_id');
        r.success = true;
        r.sessionStorage = ssVal === pid;
        r.localStorage   = localStorage.getItem('customer_onesignal_player_id') === pid;
        r.playerId = pid;
      } catch (e) {
        r.error = String(e);
      }
      return JSON.stringify(r);
    })();
  """;

  String _buildHeartbeatScript() => """
    (function() {
      try {
        var ss = sessionStorage.getItem('customer_onesignal_player_id');
        var ls = localStorage.getItem('customer_onesignal_player_id');
        return JSON.stringify({ sessionStorage: ss, localStorage: ls });
      } catch(e) {
        return JSON.stringify({ sessionStorage: null, localStorage: null });
      }
    })();
  """;

  String _buildSpaHookScript(String escapedId) => """
    (function(pid) {
      window.__BARBECUEZ_PLAYER_ID = pid;
      if (window.__BARBECUEZ_SPA_HOOK_INSTALLED) return;
      window.__BARBECUEZ_SPA_HOOK_INSTALLED = true;
      function onSpaNav() {
        try {
          var id = window.__BARBECUEZ_PLAYER_ID;
          if (id) sessionStorage.setItem('customer_onesignal_player_id', id);
          if (window.flutter_inappwebview) {
            window.flutter_inappwebview
              .callHandler('onSpaNavigation', window.location.href, id || '')
              .catch(function(){});
          }
        } catch(e) {}
      }
      var origPush    = history.pushState;
      var origReplace = history.replaceState;
      history.pushState    = function() { origPush.apply(this, arguments);    try { onSpaNav(); } catch(e) {} };
      history.replaceState = function() { origReplace.apply(this, arguments); try { onSpaNav(); } catch(e) {} };
      window.addEventListener('popstate', function() { try { onSpaNav(); } catch(e) {} });
    })('$escapedId');
  """;

  // ─── OneSignal (notifications + observer) ────────────────────────────────────

  Future<void> _initOneSignal() async {
    OneSignal.User.pushSubscription.addObserver((state) {
      final newId = state.current.id;
      if (newId != null &&
          newId.isNotEmpty &&
          newId != _cachedPlayerId &&
          _playerIdRe.hasMatch(newId)) {
        _cachedPlayerId = newId;
        _playerIdRetryTimer?.cancel();
        _injectPlayerIdIntoAllWebViews();
      }
    });

    OneSignal.Notifications.addForegroundWillDisplayListener((event) async {
      try {
        event.preventDefault();
        final n = event.notification;
        final url = (n.additionalData?['url'] as String?) ?? n.launchUrl;
        await localNotifications.show(
          id: n.notificationId.hashCode,
          title: n.title ?? 'Barbecuez',
          body: n.body ?? '',
          notificationDetails: NotificationDetails(
            android: AndroidNotificationDetails(
              androidChannel.id,
              androidChannel.name,
              channelDescription: androidChannel.description,
              importance: Importance.high,
              priority: Priority.high,
              icon: '@mipmap/launcher_icon',
              autoCancel: true,
              ongoing: false,
              onlyAlertOnce: false,
              fullScreenIntent: false,
            ),
            iOS: const DarwinNotificationDetails(
              presentAlert: true,
              presentBadge: true,
              presentSound: true,
            ),
          ),
          payload: url,
        );
      } catch (_) {}
    });

    OneSignal.Notifications.addClickListener((event) async {
      final n = event.notification;
      final url = (n.additionalData?['url'] as String?) ?? n.launchUrl;
      if (url != null && url.isNotEmpty) {
        await _handleIncomingLink(Uri.parse(url));
      }
    });
  }

  // ─── Firebase ────────────────────────────────────────────────────────────────

  String? _stringDataValue(Map<String, dynamic> data, String key) {
    final value = data[key];
    if (value == null) return null;
    final s = value.toString();
    return s.isEmpty ? null : s;
  }

  Future<void> _initFirebaseNotifications() async {
    final messaging = FirebaseMessaging.instance;
    await messaging.requestPermission(alert: true, badge: true, sound: true);

    FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
      final notification = message.notification;
      final title =
          notification?.title ?? _stringDataValue(message.data, 'title');
      final body = notification?.body ?? _stringDataValue(message.data, 'body');
      if (notification != null || title != null || body != null) {
        await localNotifications.show(
          id: message.messageId?.hashCode ?? message.hashCode,
          title: title ?? 'Barbecuez',
          body: body ?? '',
          notificationDetails: NotificationDetails(
            android: AndroidNotificationDetails(
              androidChannel.id,
              androidChannel.name,
              channelDescription: androidChannel.description,
              importance: Importance.high,
              priority: Priority.high,
              icon: '@mipmap/launcher_icon',
              autoCancel: true,
              ongoing: false,
              onlyAlertOnce: false,
              fullScreenIntent: false,
            ),
            iOS: const DarwinNotificationDetails(
              presentAlert: true,
              presentBadge: true,
              presentSound: true,
            ),
          ),
          payload: _stringDataValue(message.data, 'url'),
        );
      }
    });

    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) async {
      final url = _stringDataValue(message.data, 'url');
      if (url != null) await _handleIncomingLink(Uri.parse(url));
    });

    final initial = await messaging.getInitialMessage();
    if (initial != null) {
      final url = _stringDataValue(initial.data, 'url');
      if (url != null) await _handleIncomingLink(Uri.parse(url));
    }
  }

  // ─── Back handling ───────────────────────────────────────────────────────────

  Future<void> _handleBackPressed() async {
    final controller = _webControllers[_currentIndex];
    if (controller != null && await controller.canGoBack()) {
      await controller.goBack();
      return;
    }

    if (_currentIndex != 0) {
      setState(() => _currentIndex = 0);
      return;
    }

    final now = DateTime.now();
    if (_lastBackPressed == null ||
        now.difference(_lastBackPressed!) > const Duration(seconds: 2)) {
      _lastBackPressed = now;
      Fluttertoast.showToast(
        msg: 'اضغط مرة أخرى للخروج',
        toastLength: Toast.LENGTH_SHORT,
        gravity: ToastGravity.BOTTOM,
      );
      return;
    }

    SystemNavigator.pop();
  }

  // ─── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    super.build(context);
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.black,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
    ));

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop) await _handleBackPressed();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: IndexedStack(
            index: _currentIndex,
            children: List.generate(_tabs.length, (i) => _buildTab(i)),
          ),
        ),
        bottomNavigationBar: BottomNavigationBar(
          backgroundColor: Colors.black,
          currentIndex: _currentIndex,
          onTap: (index) async {
            if (_currentIndex == index) {
              // Tapping the active tab resets it to its root URL.
              await _resetTab(index);
              return;
            }
            // Switch first so the previous tab is hidden, THEN reset it.
            // This removes the visible flash that occurred when we reset
            // the current tab while it was still on-screen.
            final prevIndex = _currentIndex;
            setState(() => _currentIndex = index);
            _resetTab(prevIndex); // fire-and-forget; tab is now invisible

            if (index != 0) {
              final controller = _webControllers[index];
              if (controller != null) {
                await _syncLocalStorageToController(controller);
              }
            }
          },
          selectedItemColor: Colors.red[700],
          unselectedItemColor: Colors.grey[600],
          type: BottomNavigationBarType.fixed,
          items: [
            for (int i = 0; i < _tabs.length; i++)
              BottomNavigationBarItem(
                icon: Icon(_tabs[i].icon),
                label: _tabs[i].label,
              ),
          ],
        ),
      ),
    );
  }

  // ─── Individual tab WebView ──────────────────────────────────────────────────

  Widget _buildTab(int index) {
    final config = _tabs[index];
    final initialUrl = _currentUrls[index] ?? config.url;

    return Stack(
      key: _tabKeys[index],
      children: [
        InAppWebView(
          initialUrlRequest: URLRequest(url: WebUri(initialUrl)),
          initialSettings: InAppWebViewSettings(
            javaScriptEnabled: true,
            mediaPlaybackRequiresUserGesture: false,
            allowsInlineMediaPlayback: true,
            useHybridComposition: true,
            mixedContentMode: MixedContentMode.MIXED_CONTENT_NEVER_ALLOW,
            geolocationEnabled: true,
            domStorageEnabled: true,
            databaseEnabled: true,
            cacheEnabled: true,
            thirdPartyCookiesEnabled: true,
            // Share the WKHTTPCookieStorage across all WKWebView instances on
            // iOS so cookie-based consent (CookieBot, OneTrust, custom) is
            // visible in every tab without extra sync.
            sharedCookiesEnabled: true,
            incognito: false,
            cacheMode: CacheMode.LOAD_DEFAULT,
            // Block drive-by malware on Android (API 27+).
            safeBrowsingEnabled: true,
          ),
          onWebViewCreated: (controller) async {
            // Clean up stale bridge state before claiming this slot.
            final old = _webControllers[index];
            if (old != null) _cleanupControllerState(old.hashCode);
            _webControllers[index] = controller;

            // Wait for the localStorage cache to finish loading from
            // SharedPreferences before installing the preload UserScript,
            // so the script carries the persisted consent data.
            await _lsCacheReady;
            await _refreshPreloadScript(controller);

            // ── JS → Dart handlers ────────────────────────────────────
            //
            // Security: all handlers below respond to any page loaded in
            // this controller.  External URLs are kept out of the WebView
            // by shouldOverrideUrlLoading + onCreateWindow, so the only
            // pages that can call these handlers are trusted barbecuez.no
            // pages.

            controller.addJavaScriptHandler(
              handlerName: 'getOneSignalPlayerId',
              callback: (_) => _cachedPlayerId ?? '',
            );

            controller.addJavaScriptHandler(
              handlerName: 'getTrackingToken',
              callback: (args) async {
                if (args.isEmpty) return null;
                final order = args[0]?.toString() ?? '';
                if (order.isEmpty) return null;
                return TrackingTokenStore.get(order);
              },
            );

            controller.addJavaScriptHandler(
              handlerName: 'persistTrackingToken',
              callback: (args) async {
                if (args.length < 2) return {'success': false};
                final order = args[0]?.toString() ?? '';
                final token = args[1]?.toString() ?? '';
                await TrackingTokenStore.set(order, token);
                return {'success': true};
              },
            );

            controller.addJavaScriptHandler(
              handlerName: 'onSpaNavigation',
              callback: (args) {
                // JS hook already re-wrote sessionStorage synchronously;
                // trigger Dart-side injection for localStorage + events.
                _injectPlayerIdIntoWebView(controller);
                return null;
              },
            );

            _injectTrackingTokens(controller);
            _injectPlayerIdIntoWebView(controller);
          },
          onLoadStart: (controller, url) async {
            await _injectTrackingTokens(controller);
          },
          onLoadStop: (controller, url) async {
            // Sync all localStorage keys from Home → this tab so auth state
            // and cookie-consent are consistent (belt-and-suspenders alongside
            // the AT_DOCUMENT_START preload script).
            if (index != 0) {
              await _syncLocalStorageToController(controller);
            }

            // Full player-ID injection.
            await _injectPlayerIdIntoWebView(controller);

            // Patch history API for SPA route changes.
            await _installSpaNavigationHook(controller);

            // Fetch player-ID if we don't have it yet.
            if (_cachedPlayerId == null) {
              await _tryFetchAndInjectPlayerId();
            }

            await _injectTrackingTokens(controller);

            // Capture localStorage (including consent keys) into the Flutter
            // cache and refresh the AT_DOCUMENT_START preload script so the
            // NEXT load of any tab has consent pre-injected.
            await _captureAndSyncLs(controller);
          },
          onCreateWindow: (controller, createWindowAction) async {
            final url = createWindowAction.request.url;
            if (url == null) return false;

            final host = url.host.toLowerCase();

            // Internal domains → load inside WebView to share cookie jar
            // and avoid the SFSafariViewController → Universal Link loop.
            if (_trustedHosts.contains(host)) {
              await controller.loadUrl(
                  urlRequest: URLRequest(url: WebUri.uri(url)));
              return false;
            }

            // External domains (payment providers, OAuth, etc.) that open as
            // popups also need the WebView's cookie jar for the auth/payment
            // redirect to land back on barbecuez.no correctly.
            // Opening in SFSafariViewController would trigger a new Universal
            // Link delivery and break the flow.
            await controller.loadUrl(
                urlRequest: URLRequest(url: WebUri.uri(url)));
            return false;
          },
          onGeolocationPermissionsShowPrompt: (controller, origin) async {
            return GeolocationPermissionShowPromptResponse(
              origin: origin,
              allow: true,
              retain: true,
            );
          },
          shouldOverrideUrlLoading: (controller, navigationAction) async {
            final uri = navigationAction.request.url;
            if (uri == null) return NavigationActionPolicy.ALLOW;
            if (!navigationAction.isForMainFrame) {
              return NavigationActionPolicy.ALLOW;
            }

            final host   = uri.host.toLowerCase();
            final scheme = uri.scheme.toLowerCase();

            if (kDebugMode) {
              debugPrint('[NavPolicy] tab=$index url=$uri host=$host scheme=$scheme');
            }

            // Contact tab: root internal URL → switch to Home tab.
            if (index == 2) {
              final path = uri.path;
              if ((path == '/' || path.isEmpty) && _trustedHosts.contains(host)) {
                _switchToTab(0);
                return NavigationActionPolicy.CANCEL;
              }
            }

            // Native app schemes.
            if (['tel', 'mailto', 'whatsapp', 'sms', 'vipps', 'vippsmt']
                .contains(scheme)) {
              await launchUrl(uri,
                  mode: LaunchMode.externalNonBrowserApplication);
              return NavigationActionPolicy.CANCEL;
            }

            // Internal domains → always inside the WebView.
            if (_trustedHosts.contains(host)) {
              return NavigationActionPolicy.ALLOW;
            }

            // External http/https: open in in-app browser only for explicit
            // user taps.  Programmatic redirects (OAuth, payment callbacks)
            // stay in the WebView to share cookies.
            if (['http', 'https'].contains(scheme)) {
              if (navigationAction.navigationType ==
                  NavigationType.LINK_ACTIVATED) {
                await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
                return NavigationActionPolicy.CANCEL;
              }
              return NavigationActionPolicy.ALLOW;
            }

            return NavigationActionPolicy.ALLOW;
          },
        ),
      ],
    );
  }
}
import 'dart:async';
import 'dart:convert';

import 'package:app_links/app_links.dart';
import 'package:barbecuez/services/tracking_token_store.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../main.dart';

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
  _TabConfig(label: 'Home',   icon: Icons.home_outlined,           url: 'https://barbecuez.no'),
  _TabConfig(label: 'Menu',   icon: Icons.restaurant_menu_outlined, url: 'https://barbecuez.no/menu'),
  _TabConfig(label: 'Contact', icon: Icons.info_outline,   url: 'https://barbecuez.no/contact'),
];

// ─── MainScreen (Native Tab Shell) ────────────────────────────────────────────

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

  // One controller slot per tab — filled lazily on first visit
  final List<InAppWebViewController?> _webControllers = List.filled(_tabs.length, null);
  final List<String?> _currentUrls = List.filled(_tabs.length, null);

  // Keep all tab WebViews alive with IndexedStack
  final List<GlobalKey> _tabKeys = List.generate(_tabs.length, (_) => GlobalKey());

  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _appLinksSub;

  String? _oneSignalPlayerId;
  Timer? _playerIdRetryTimer;

  final String allowedDomain = "barbecuez.no";
  DateTime? _lastBackPressed;

  static const String _lastUrlKey = 'last_url';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Handle pending deep link from cold start
    _handlePendingDeepLink();

    _initFirebaseNotifications();
    _initOneSignal();
    _initDeepLinks();

    _playerIdRetryTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      _tryFetchAndInjectPlayerId();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _playerIdRetryTimer?.cancel();
    _appLinksSub?.cancel();
    super.dispose();
  }

  // ← NEW: Re-inject tokens when app resumes
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      for (final controller in _webControllers) {
        if (controller != null) {
          _injectTrackingTokens(controller);
        }
      }
    }
  }

  // ← NEW: Handle pending deep link from SharedPreferences
  Future<void> _handlePendingDeepLink() async {
    final prefs = await SharedPreferences.getInstance();
    final pendingUrl = prefs.getString('pending_deep_link');
    if (pendingUrl != null && pendingUrl.isNotEmpty) {
      await prefs.remove('pending_deep_link');
      // Parse and handle immediately
      await _handleIncomingLink(Uri.parse(pendingUrl));
    }
  }

  // ─── Tracking tokens ────────────────────────────────────────────────────────

  Future<void> _injectTrackingTokens(InAppWebViewController controller) async {
    try {
      final tokens = await TrackingTokenStore.readAll();
      if (tokens.isEmpty) {
        debugPrint('📭 No tracking tokens to inject');
        return;
      }
      final json = jsonEncode(tokens);
      await controller.evaluateJavascript(source: '''
        (function() {
          if (window.__setTrackingTokens) {
            window.__setTrackingTokens($json);
            console.log('✅ Restored ' + Object.keys($json).length + ' tracking tokens from native');
          } else {
            setTimeout(function() {
              if (window.__setTrackingTokens) window.__setTrackingTokens($json);
            }, 500);
          }
        })();
      ''');
      debugPrint('📤 Injected ${tokens.length} tokens');
    } catch (e) {
      debugPrint('❌ Token injection error: $e');
    }
  }

  // ─── Deep Links ─────────────────────────────────────────────────────────────

  Future<void> _initDeepLinks() async {
    try {
      final Uri? initialUri = await _appLinks.getInitialLink();
      if (initialUri != null) await _handleIncomingLink(initialUri);

      _appLinksSub = _appLinks.uriLinkStream.listen((Uri uri) async {
        await _handleIncomingLink(uri);
      });
    } catch (e) {
      debugPrint("Deep link init error: $e");
    }
  }

  Future<void> _handleIncomingLink(Uri uri) async {
    debugPrint("Incoming deep link: $uri");

    final isBarbecuezDomain =
        uri.host == allowedDomain || uri.host == 'www.$allowedDomain';
    if (!isBarbecuezDomain) return;

    // Order tracking → open in Home tab with token
    if (uri.path == '/order-tracking') {
      final orderNumber = uri.queryParameters['order'];
      final token = uri.queryParameters['tt'];

      // Save token if present
      if (orderNumber != null && token != null && token.isNotEmpty) {
        await TrackingTokenStore.set(orderNumber, token);
        debugPrint("💾 Token saved from deep link: $orderNumber");
      }

      // Build URL with token for instant loading
      String targetUrl = 'https://$allowedDomain/order-tracking';
      if (orderNumber != null && orderNumber.isNotEmpty) {
        final savedToken = await TrackingTokenStore.get(orderNumber);
        if (savedToken != null && savedToken.isNotEmpty) {
          targetUrl = 'https://$allowedDomain/order-tracking?order=$orderNumber&tt=$savedToken';
          debugPrint("🚀 FAST: Opening tracking with token: $targetUrl");
        } else {
          targetUrl = 'https://$allowedDomain/order-tracking?order=$orderNumber';
          debugPrint("⚠️ No token found for: $orderNumber");
        }
      }

      _switchToTab(0);
      await _loadUrlInTab(0, targetUrl);
      return;
    }

    // For menu links
    if (uri.path.startsWith('/menu')) {
      _switchToTab(1);
      await _loadUrlInTab(1, uri.toString());
      return;
    }

    // Default → Home tab
    _switchToTab(0);
    await _loadUrlInTab(0, uri.toString());
  }

  void _switchToTab(int index) {
    if (mounted) setState(() => _currentIndex = index);
  }

  // ← NEW: Reset any tab to its original URL
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

  // Sync localStorage from Home WebView to another WebView
  Future<void> _syncLocalStorageToController(InAppWebViewController controller) async {
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
                  key: k,
                  oldValue: oldVal,
                  newValue: newVal,
                  url: window.location.href,
                  storageArea: window.localStorage
                }));
              } catch(e) {}
            }
          });
          window.dispatchEvent(new StorageEvent('storage', {
            key: null,
            url: window.location.href,
            storageArea: window.localStorage
          }));
        } catch(e) {}
      })($storageJson);
    ''');
  }

  Future<void> _loadUrlInTab(int tabIndex, String url) async {
    final controller = _webControllers[tabIndex];
    if (controller != null) {
      await controller.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
    } else {
      _currentUrls[tabIndex] = url;
    }
  }

  // ─── OneSignal ──────────────────────────────────────────────────────────────

  Future<void> _tryFetchAndInjectPlayerId() async {
    if (_oneSignalPlayerId != null) {
      _playerIdRetryTimer?.cancel();
      return;
    }
    final id = OneSignal.User.pushSubscription.id;
    if (id != null && id.isNotEmpty) {
      _oneSignalPlayerId = id;
      _playerIdRetryTimer?.cancel();
      debugPrint("✅ OneSignal Player ID: $_oneSignalPlayerId");
      await _injectPlayerIdToAllTabs();
    }
  }

  Future<void> _injectPlayerIdToAllTabs() async {
    for (final controller in _webControllers) {
      if (controller != null && _oneSignalPlayerId != null) {
        await _injectPlayerIdToController(controller);
      }
    }
  }

  Future<void> _injectPlayerIdToController(InAppWebViewController c) async {
    if (_oneSignalPlayerId == null) return;
    final script = """
      (function() {
        window.oneSignalPlayerId = '$_oneSignalPlayerId';
        localStorage.setItem('customer_onesignal_player_id', '$_oneSignalPlayerId');
        window.dispatchEvent(new CustomEvent('pushTokenReady', {
          detail: { playerId: '$_oneSignalPlayerId', player_id: '$_oneSignalPlayerId' }
        }));
      })();
    """;
    await c.evaluateJavascript(source: script);
  }

  Future<void> _initOneSignal() async {
    OneSignal.User.pushSubscription.addObserver((state) {
      final newId = state.current.id;
      if (newId != null && newId.isNotEmpty && newId != _oneSignalPlayerId) {
        _oneSignalPlayerId = newId;
        _playerIdRetryTimer?.cancel();
        _injectPlayerIdToAllTabs();
      }
    });

    OneSignal.Notifications.addClickListener((event) async {
      final url = event.notification.additionalData?['url'] as String?;
      if (url != null && url.isNotEmpty) {
        await _handleIncomingLink(Uri.parse(url));
      }
    });
  }

  // ─── Firebase ───────────────────────────────────────────────────────────────

  Future<void> _initFirebaseNotifications() async {
    final messaging = FirebaseMessaging.instance;
    await messaging.requestPermission(alert: true, badge: true, sound: true);

    FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
      final notification = message.notification;
      if (notification != null) {
        await localNotifications.show(
          id: notification.hashCode,
          title: notification.title ?? 'Barbecuez',
          body: notification.body ?? '',
          notificationDetails: NotificationDetails(
            android: AndroidNotificationDetails(
              androidChannel.id,
              androidChannel.name,
              channelDescription: androidChannel.description,
              importance: Importance.high,
              priority: Priority.high,
              icon: '@mipmap/launcher_icon',
            ),
            iOS: const DarwinNotificationDetails(
              presentAlert: true,
              presentBadge: true,
              presentSound: true,
            ),
          ),
          payload: message.data['url'],
        );
      }
    });

    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) async {
      final url = message.data['url'];
      if (url != null && url.toString().isNotEmpty) {
        await _handleIncomingLink(Uri.parse(url));
      }
    });

    final initialMessage = await messaging.getInitialMessage();
    if (initialMessage != null) {
      final url = initialMessage.data['url'];
      if (url != null && url.toString().isNotEmpty) {
        await _handleIncomingLink(Uri.parse(url));
      }
    }
  }

  // ─── Back handling ──────────────────────────────────────────────────────────

  Future<void> _handleBackPressed() async {
    final controller = _webControllers[_currentIndex];
    if (controller != null && await controller.canGoBack()) {
      await controller.goBack();
      return;
    }

    if (_currentIndex != 0) {
      _resetTab(_currentIndex); // ← Reset current tab before leaving
      setState(() => _currentIndex = 0);
      return;
    }

    final now = DateTime.now();
    if (_lastBackPressed == null ||
        now.difference(_lastBackPressed!) > const Duration(seconds: 2)) {
      _lastBackPressed = now;
      Fluttertoast.showToast(
        msg: "اضغط مرة أخرى للخروج",
        toastLength: Toast.LENGTH_SHORT,
        gravity: ToastGravity.BOTTOM,
      );
      return;
    }

    SystemNavigator.pop();
  }

  bool _isExternalUrl(Uri uri) {
    final host = uri.host.toLowerCase();
    return host.isNotEmpty &&
        host != allowedDomain &&
        host != 'www.$allowedDomain';
  }

  // ─── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.white,
      statusBarIconBrightness: Brightness.dark,
      statusBarBrightness: Brightness.light,
    ));

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop) await _handleBackPressed();
      },
      child: Scaffold(
        backgroundColor: Colors.white,
        body: SafeArea(
          child: IndexedStack(
            index: _currentIndex,
            children: List.generate(_tabs.length, (i) => _buildTab(i)),
          ),
        ),
        bottomNavigationBar: BottomNavigationBar(
          currentIndex: _currentIndex,
          onTap: (index) async {
            // ← NEW: If tapping same tab again, reset to original URL
            if (_currentIndex == index) {
              await _resetTab(index);
              return;
            }

            // ← NEW: Reset current tab before switching to new tab
            await _resetTab(_currentIndex);

            setState(() => _currentIndex = index);

            if (index != 0) {
              final controller = _webControllers[index];
              if (controller != null) {
                await _syncLocalStorageToController(controller);
              }
            }
          },
          selectedItemColor: Colors.red[900],
          unselectedItemColor: Colors.grey,
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
            incognito: false,
            cacheMode: CacheMode.LOAD_DEFAULT,
          ),
          onWebViewCreated: (controller) {
            _webControllers[index] = controller;

            // Handler 1: OneSignal Player ID
            controller.addJavaScriptHandler(
              handlerName: 'getOneSignalPlayerId',
              callback: (_) => _oneSignalPlayerId ?? '',
            );

            // Handler 2: Site requests token
            controller.addJavaScriptHandler(
              handlerName: 'getTrackingToken',
              callback: (args) async {
                if (args.isEmpty) return null;
                final orderNumber = args[0]?.toString() ?? '';
                if (orderNumber.isEmpty) return null;
                final token = await TrackingTokenStore.get(orderNumber);
                debugPrint('🔑 getTrackingToken($orderNumber) -> ${token != null ? "FOUND" : "MISSING"}');
                return token;
              },
            );

            // Handler 3: Site saves new token
            controller.addJavaScriptHandler(
              handlerName: 'persistTrackingToken',
              callback: (args) async {
                if (args.length < 2) return {'success': false};
                final orderNumber = args[0]?.toString() ?? '';
                final token = args[1]?.toString() ?? '';
                await TrackingTokenStore.set(orderNumber, token);
                debugPrint('💾 persistTrackingToken($orderNumber) saved');
                return {'success': true};
              },
            );

            // Preload tokens immediately
            _injectTrackingTokens(controller);
          },
          onLoadStart: (controller, url) async {
            // Early injection
            if (controller != null) {
              await _injectTrackingTokens(controller);
            }
          },
          onLoadStop: (controller, url) async {
            // Sync localStorage from Home tab
            if (index != 0) {
              await _syncLocalStorageToController(controller);
            }
            await _injectPlayerIdToController(controller);
            await _tryFetchAndInjectPlayerId();
            await _injectTrackingTokens(controller);
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
            if (!navigationAction.isForMainFrame) return NavigationActionPolicy.ALLOW;

            // If Orders tab tries to navigate to home → switch to Home tab
            if (index == 2) {
              final path = uri.path;
              final isHomePage = (path == '/' || path.isEmpty) &&
                  !_isExternalUrl(uri);
              if (isHomePage) {
                _switchToTab(0);
                return NavigationActionPolicy.CANCEL;
              }
            }

            final scheme = uri.scheme.toLowerCase();
            if (['tel', 'mailto', 'whatsapp', 'sms'].contains(scheme)) {
              await launchUrl(uri, mode: LaunchMode.externalApplication);
              return NavigationActionPolicy.CANCEL;
            }

            if (_isExternalUrl(uri)) {
              await launchUrl(uri, mode: LaunchMode.externalApplication);
              return NavigationActionPolicy.CANCEL;
            }

            return NavigationActionPolicy.ALLOW;
          },
        ),
      ],
    );
  }
}
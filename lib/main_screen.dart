import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../main.dart'; // for localNotifications & androidChannel
import 'about_screen.dart';
import 'tracking_service.dart';

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
  _TabConfig(label: 'Orders', icon: Icons.receipt_long_outlined,   url: 'https://barbecuez.no/order-tracking'),
  _TabConfig(label: 'About',  icon: Icons.info_outline,            url: ''),  // Native screen — no URL
];

// ─── MainScreen (Native Tab Shell) ────────────────────────────────────────────

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
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

  // Orders badge count (Native feature — Apple loves this)
  int _ordersBadge = 0;

  @override
  void initState() {
    super.initState();
    _initFirebaseNotifications();
    _initOneSignal();
    _initDeepLinks();
    // Request ATT permission on iOS before WebViews load
    WidgetsBinding.instance.addPostFrameCallback((_) {
      TrackingService.requestPermissionIfNeeded(context);
    });

    _playerIdRetryTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      _tryFetchAndInjectPlayerId();
    });
  }

  @override
  void dispose() {
    _playerIdRetryTimer?.cancel();
    _appLinksSub?.cancel();
    super.dispose();
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

    // Switch to Orders tab if it's an order-tracking link
    if (uri.path == '/order-tracking') {
      final orderNumber = uri.queryParameters['order'];
      final targetUrl = (orderNumber != null && orderNumber.isNotEmpty)
          ? 'https://$allowedDomain/order-tracking?order=$orderNumber'
          : 'https://$allowedDomain/order-tracking';

      _switchToTab(2); // Orders tab index
      await _loadUrlInTab(2, targetUrl);
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

  // Reset Orders tab back to its default URL (called when leaving the tab)
  Future<void> _resetOrdersTab() async {
    final controller = _webControllers[2];
    if (controller != null) {
      await controller.loadUrl(
        urlRequest: URLRequest(url: WebUri(_tabs[2].url)),
      );
    } else {
      _currentUrls[2] = null; // will use default URL on next mount
    }
  }

  Future<void> _loadUrlInTab(int tabIndex, String url) async {
    final controller = _webControllers[tabIndex];
    if (controller != null) {
      await controller.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
    } else {
      // Tab not mounted yet — store URL so it loads when tab opens
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
        // Bump badge on Orders tab if it's an order notification
        if (message.data['type'] == 'order') {
          if (mounted) setState(() => _ordersBadge++);
        }

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

    // If not on Home tab → go to Home tab + reset Orders if leaving it
    if (_currentIndex != 0) {
      if (_currentIndex == 2) await _resetOrdersTab();
      // About tab (3) → just go Home, no reset needed
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
    // White status bar + dark icons on all screens
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.white,
      statusBarIconBrightness: Brightness.dark,  // Android
      statusBarBrightness: Brightness.light,      // iOS
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
            children: [
              ...List.generate(_tabs.length - 1, (i) => _buildTab(i)),
              const AboutScreen(), // Tab 3 — fully native, no WebView
            ],
          ),
        ),

        // ── Native Bottom Navigation Bar ──────────────────────────────────
        bottomNavigationBar: BottomNavigationBar(
          currentIndex: _currentIndex,
          onTap: (index) {
            // When leaving Orders tab → reset it to default URL
            if (_currentIndex == 2 && index != 2) {
              _resetOrdersTab();
            }
            // Clear badge when user taps Orders tab
            if (index == 2 && _ordersBadge > 0) {
              setState(() => _ordersBadge = 0);
            }
            setState(() => _currentIndex = index);
          },
          selectedItemColor: Colors.red[900],
          unselectedItemColor: Colors.grey,
          type: BottomNavigationBarType.fixed,
          items: [
            for (int i = 0; i < _tabs.length; i++)
              BottomNavigationBarItem(
                icon: _buildTabIcon(i),
                label: _tabs[i].label,
              ),
          ],
        ),
      ),
    );
  }

  // Badge icon for Orders tab — native feature Apple looks for
  Widget _buildTabIcon(int index) {
    final icon = Icon(_tabs[index].icon);
    if (index == 2 && _ordersBadge > 0) {
      return Badge(
        label: Text('$_ordersBadge'),
        child: icon,
      );
    }
    return icon;
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
          ),
          onWebViewCreated: (controller) {
            _webControllers[index] = controller;
            controller.addJavaScriptHandler(
              handlerName: 'getOneSignalPlayerId',
              callback: (_) => _oneSignalPlayerId ?? '',
            );
          },
          onLoadStop: (controller, url) async {
            await _injectPlayerIdToController(controller);
            await _tryFetchAndInjectPlayerId();
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

            // If Orders tab tries to navigate to home → switch to Home tab instead
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
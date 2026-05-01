import 'dart:async';
import 'dart:convert';

import 'package:app_links/app_links.dart';
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
import '../tracking_token_store.dart';

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

  InAppWebViewController? _controller;
  InAppWebViewController? get _currentController => _controller;

  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _appLinksSub;

  bool isLoading = true;
  bool canGoBack = false;
  bool canGoForward = false;

  final String allowedDomain = "barbecuez.no";
  DateTime? _lastBackPressed;

  String? _oneSignalPlayerId;
  Timer? _playerIdRetryTimer;

  static const String _lastUrlKey = 'last_url';
  String _initialUrl = "https://barbecuez.no";

  bool _urlRestored = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    if (widget.initialUrl != null && widget.initialUrl!.isNotEmpty) {
      _initialUrl = widget.initialUrl!;
    }

    _restoreLastUrl();
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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed && _currentController != null) {
      _injectTrackingTokens(_currentController!);
    }
  }

  Future<void> _restoreLastUrl() async {
    // Check pending deep link first
    final prefs = await SharedPreferences.getInstance();
    final pendingUrl = prefs.getString('pending_deep_link');

    if (pendingUrl != null && pendingUrl.isNotEmpty) {
      await prefs.remove('pending_deep_link');
      setState(() {
        _initialUrl = pendingUrl;
        _urlRestored = true;
      });
      return;
    }

    if (widget.initialUrl != null && widget.initialUrl!.isNotEmpty) {
      setState(() => _urlRestored = true);
      return;
    }

    final savedUrl = prefs.getString(_lastUrlKey);
    setState(() {
      if (savedUrl != null && savedUrl.isNotEmpty) {
        _initialUrl = savedUrl;
      }
      _urlRestored = true;
    });
  }

  Future<void> _saveCurrentUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();

    // Don't save order-tracking pages (go home on next open)
    final uri = Uri.parse(url);
    if (uri.path == '/order-tracking') {
      await prefs.setString(_lastUrlKey, 'https://$allowedDomain');
      return;
    }

    await prefs.setString(_lastUrlKey, url);
  }

  Future<void> _initDeepLinks() async {
    try {
      final Uri? initialUri = await _appLinks.getInitialLink();
      if (initialUri != null) {
        await _handleIncomingLink(initialUri);
      }

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

    final bool isOrderTracking = uri.path == '/order-tracking';

    if (isOrderTracking) {
      final String? orderNumber = uri.queryParameters['order'];
      final String? token = uri.queryParameters['tt'];

      // Save token if present
      if (orderNumber != null && token != null && token.isNotEmpty) {
        await TrackingTokenStore.set(orderNumber, token);
        debugPrint("💾 Token saved: $orderNumber");
      }

      // ← FAST: Build URL with token immediately (no JS delay)
      String targetUrl = 'https://$allowedDomain/order-tracking';

      if (orderNumber != null && orderNumber.isNotEmpty) {
        final savedToken = await TrackingTokenStore.get(orderNumber);

        if (savedToken != null && savedToken.isNotEmpty) {
          targetUrl = 'https://$allowedDomain/order-tracking?order=$orderNumber&tt=$savedToken';
          debugPrint("🚀 FAST: Opening with token: $targetUrl");
        } else {
          targetUrl = 'https://$allowedDomain/order-tracking?order=$orderNumber';
          debugPrint("⚠️ No token found for: $orderNumber");
        }
      }

      await _loadUrlInsideApp(targetUrl);
      return;
    }

    await _loadUrlInsideApp(uri.toString());
  }

  Future<void> _loadUrlInsideApp(String url) async {
    if (_controller != null) {
      await _controller!.loadUrl(
        urlRequest: URLRequest(url: WebUri(url)),
      );
      await _updateNavigationState();
    } else {
      setState(() => _initialUrl = url);
    }
  }

  Future<void> _tryFetchAndInjectPlayerId() async {
    if (_oneSignalPlayerId != null) {
      _playerIdRetryTimer?.cancel();
      return;
    }

    final id = OneSignal.User.pushSubscription.id;
    if (id != null && id.isNotEmpty) {
      _oneSignalPlayerId = id;
      debugPrint("✅ OneSignal Player ID registered");
      _playerIdRetryTimer?.cancel();
      await _injectPlayerIdToWebView();
    }
  }

  Future<void> _injectPlayerIdToWebView() async {
    if (_controller == null || _oneSignalPlayerId == null) return;

    final script = """
      (function() {
        window.oneSignalPlayerId = '$_oneSignalPlayerId';
        localStorage.setItem('customer_onesignal_player_id', '$_oneSignalPlayerId');
        window.dispatchEvent(new CustomEvent('pushTokenReady', {
          detail: { playerId: '$_oneSignalPlayerId', player_id: '$_oneSignalPlayerId' }
        }));
        console.log('[Flutter] OneSignal Player ID injected');
      })();
    """;

    await _controller!.evaluateJavascript(source: script);
  }

  Future<void> _injectTrackingTokens(InAppWebViewController controller) async {
    try {
      final tokens = await TrackingTokenStore.readAll();
      if (tokens.isEmpty) return;

      final json = jsonEncode(tokens);
      await controller.evaluateJavascript(source: '''
        (function() {
          if (window.__setTrackingTokens) {
            window.__setTrackingTokens($json);
            console.log('✅ Restored ' + Object.keys($json).length + ' tokens');
          } else {
            setTimeout(function() {
              if (window.__setTrackingTokens) window.__setTrackingTokens($json);
            }, 300);
          }
        })();
      ''');

      debugPrint('📤 Injected ${tokens.length} tokens');
    } catch (e) {
      debugPrint('❌ Token injection error: $e');
    }
  }

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

  Future<void> _initOneSignal() async {
    OneSignal.User.pushSubscription.addObserver((state) {
      final newId = state.current.id;
      if (newId != null && newId.isNotEmpty && newId != _oneSignalPlayerId) {
        _oneSignalPlayerId = newId;
        debugPrint("✅ OneSignal ID registered");
        _playerIdRetryTimer?.cancel();
        _injectPlayerIdToWebView();
      }
    });

    OneSignal.Notifications.addClickListener((event) async {
      final url = event.notification.additionalData?['url'] as String?;
      if (url != null && url.isNotEmpty) {
        await _handleIncomingLink(Uri.parse(url));
      }
    });
  }

  Future<void> _updateNavigationState() async {
    if (_controller == null) return;
    canGoBack = await _controller!.canGoBack();
    canGoForward = await _controller!.canGoForward();
    if (mounted) setState(() {});
  }

  Future<void> _handleBackPressed() async {
    if (_controller != null && await _controller!.canGoBack()) {
      await _controller!.goBack();
      await _updateNavigationState();
      return;
    }

    final now = DateTime.now();
    if (_lastBackPressed == null ||
        now.difference(_lastBackPressed!) > const Duration(seconds: 2)) {
      _lastBackPressed = now;
      Fluttertoast.cancel();
      Fluttertoast.showToast(
        msg: "اضغط مرة أخرى للخروج",
        toastLength: Toast.LENGTH_SHORT,
        gravity: ToastGravity.BOTTOM,
      );
      return;
    }

    moveTaskToBack();
  }

  void moveTaskToBack() {
    SystemChannels.platform.invokeMethod('SystemNavigator.pop');
  }

  bool _isExternalUrl(Uri uri) {
    final host = uri.host.toLowerCase();
    return host.isNotEmpty &&
        host != allowedDomain &&
        host != 'www.$allowedDomain';
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    if (!_urlRestored) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(color: Colors.red),
        ),
      );
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        await _handleBackPressed();
      },
      child: Scaffold(
        body: SafeArea(
          child: Stack(
            children: [
              InAppWebView(
                initialUrlRequest: URLRequest(
                  url: WebUri(_initialUrl),
                ),
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
                  _controller = controller;

                  // Handler 1: Site requests token
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

                  // Handler 2: Site saves new token
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

                  controller.addJavaScriptHandler(
                    handlerName: 'getOneSignalPlayerId',
                    callback: (args) => _oneSignalPlayerId ?? '',
                  );

                  // Preload tokens immediately
                  _injectTrackingTokens(controller);
                },
                onLoadStart: (controller, url) async {
                  if (mounted) setState(() => isLoading = true);
                },
                onLoadStop: (controller, url) async {
                  if (mounted) setState(() => isLoading = false);

                  if (url != null) {
                    await _saveCurrentUrl(url.toString());
                  }

                  await _updateNavigationState();
                  await _injectPlayerIdToWebView();
                  await _tryFetchAndInjectPlayerId();
                  await _injectTrackingTokens(controller);
                },
                onConsoleMessage: (controller, consoleMessage) {
                  debugPrint(
                    "WebView [${consoleMessage.messageLevel}]: ${consoleMessage.message}",
                  );
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

                  final scheme = uri.scheme.toLowerCase();
                  if (scheme == 'tel' ||
                      scheme == 'mailto' ||
                      scheme == 'whatsapp' ||
                      scheme == 'sms') {
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
              if (isLoading)
                Center(
                  child: CircularProgressIndicator(color: Colors.red[900]),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
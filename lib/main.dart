import 'dart:async';
import 'dart:io';
import 'package:app_links/app_links.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

import 'firebase_options.dart';

const String oneSignalAppId = "0b6800a4-7b08-406d-b32c-6051c1472844";

final FlutterLocalNotificationsPlugin localNotifications =
FlutterLocalNotificationsPlugin();

const AndroidNotificationChannel androidChannel = AndroidNotificationChannel(
  'barbecuez_push',
  'Barbecuez Notifications',
  description: 'Notifications for Barbecuez app',
  importance: Importance.high,
);

Future<void> _requestLocationPermission() async {
  final current = await Permission.locationWhenInUse.status;
  if (current.isGranted || current.isPermanentlyDenied) return;

  await Permission.locationWhenInUse.request();
}

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

  if (Platform.isAndroid && kDebugMode) {
    await InAppWebViewController.setWebContentsDebuggingEnabled(true);
  }

  const androidInit = AndroidInitializationSettings('@mipmap/launcher_icon');
  const initSettings = InitializationSettings(android: androidInit);
  await localNotifications.initialize(settings: initSettings);
  await localNotifications
      .resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(androidChannel);

  OneSignal.initialize(oneSignalAppId);
  OneSignal.Notifications.requestPermission(true);

  await _requestLocationPermission();

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Barbecuez',
      debugShowCheckedModeBanner: false,
      home: WebViewScreen(),
    );
  }
}

class WebViewScreen extends StatefulWidget {
  const WebViewScreen({super.key});

  @override
  State<WebViewScreen> createState() => _WebViewScreenState();
}

class _WebViewScreenState extends State<WebViewScreen> {
  InAppWebViewController? _controller;

  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _appLinksSub;

  bool isLoading = true;
  bool canGoBack = false;
  bool canGoForward = false;

  final String allowedDomain = "barbecuez.no";
  DateTime? _lastBackPressed;

  String? _oneSignalPlayerId;
  Timer? _playerIdRetryTimer;

  String _initialUrl = "https://barbecuez.no";

  @override
  void initState() {
    super.initState();
    _initFirebaseNotifications();
    _initOneSignal();
    _initDeepLinks();

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

      final String targetUrl = (orderNumber != null && orderNumber.isNotEmpty)
          ? 'https://$allowedDomain/order-tracking?order=$orderNumber'
          : 'https://$allowedDomain/order-tracking';

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
      setState(() {
        _initialUrl = url;
      });
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
        debugPrint("✅ OneSignal ID registered (observer)");
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

    SystemNavigator.pop();
  }

  bool _isExternalUrl(Uri uri) {
    final host = uri.host.toLowerCase();
    return host.isNotEmpty &&
        host != allowedDomain &&
        host != 'www.$allowedDomain';
  }

  @override
  Widget build(BuildContext context) {
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
                ),
                onWebViewCreated: (controller) {
                  _controller = controller;

                  controller.addJavaScriptHandler(
                    handlerName: 'getOneSignalPlayerId',
                    callback: (args) => _oneSignalPlayerId ?? '',
                  );
                },
                onLoadStart: (_, __) {
                  if (mounted) {
                    setState(() => isLoading = true);
                  }
                },
                onLoadStop: (controller, url) async {
                  if (mounted) {
                    setState(() => isLoading = false);
                  }
                  await _updateNavigationState();
                  await _injectPlayerIdToWebView();
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

                  if (uri == null) {
                    return NavigationActionPolicy.ALLOW;
                  }

                  final scheme = uri.scheme.toLowerCase();

                  if (scheme == 'tel' ||
                      scheme == 'mailto' ||
                      scheme == 'whatsapp' ||
                      scheme == 'sms') {
                    await launchUrl(
                      uri,
                      mode: LaunchMode.externalApplication,
                    );
                    return NavigationActionPolicy.CANCEL;
                  }

                  if (_isExternalUrl(uri)) {
                    await launchUrl(
                      uri,
                      mode: LaunchMode.externalApplication,
                    );
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
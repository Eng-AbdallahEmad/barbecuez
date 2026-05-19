import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_options.dart';
import 'splash_screen.dart';

const String oneSignalAppId = "9ed07efc-3ef8-4198-940a-0b985286be27";

final FlutterLocalNotificationsPlugin localNotifications =
FlutterLocalNotificationsPlugin();

const AndroidNotificationChannel androidChannel = AndroidNotificationChannel(
  'barbecuez_push',
  'Barbecuez Notifications',
  description: 'Notifications for Barbecuez app',
  importance: Importance.high,
);

// Set by MainScreen so notification taps can deep-link into the active controller.
Future<void> Function(Uri uri)? onNotificationDeepLink;

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
}

Future<void> _requestLocationPermission() async {
  final current = await Permission.locationWhenInUse.status;
  if (current.isGranted || current.isPermanentlyDenied) return;
  await Permission.locationWhenInUse.request();
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

  if (Platform.isAndroid && kDebugMode) {
    await InAppWebViewController.setWebContentsDebuggingEnabled(true);
  }

  const androidInit = AndroidInitializationSettings('@mipmap/launcher_icon');
  const darwinInit = DarwinInitializationSettings(
    requestAlertPermission: true,
    requestBadgePermission: true,
    requestSoundPermission: true,
  );
  const initSettings = InitializationSettings(
    android: androidInit,
    iOS: darwinInit,
  );

  await localNotifications.initialize(
    settings: initSettings,
    onDidReceiveNotificationResponse: (NotificationResponse response) async {
      final payload = response.payload;
      if (payload != null && payload.isNotEmpty) {
        final handler = onNotificationDeepLink;
        if (handler != null) {
          try {
            await handler(Uri.parse(payload));
          } catch (_) {}
        }
      }
    },
  );

  await localNotifications
      .resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(androidChannel);

  OneSignal.initialize(oneSignalAppId);
  OneSignal.Notifications.requestPermission(true);

  await _requestLocationPermission();

  final prefs = await SharedPreferences.getInstance();
  final onboardingDone = prefs.getBool('onboarding_done') ?? false;

  runApp(MyApp(onboardingDone: onboardingDone));
}

class MyApp extends StatelessWidget {
  final bool onboardingDone;
  const MyApp({super.key, required this.onboardingDone});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Barbecuez',
      debugShowCheckedModeBanner: false,
      home: SplashScreen(onboardingDone: onboardingDone),
    );
  }
}
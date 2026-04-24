import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';
import 'package:permission_handler/permission_handler.dart';

import 'firebase_options.dart';
import 'splash_screen.dart';

const String oneSignalAppId = "0b6800a4-7b08-406d-b32c-6051c1472844";

final FlutterLocalNotificationsPlugin localNotifications =
FlutterLocalNotificationsPlugin();

const AndroidNotificationChannel androidChannel = AndroidNotificationChannel(
  'barbecuez_push',
  'Barbecuez Notifications',
  description: 'Notifications for Barbecuez app',
  importance: Importance.high,
);

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
        // handle navigation
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

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Barbecuez',
      debugShowCheckedModeBanner: false,
      home: SplashScreen(),
    );
  }
}
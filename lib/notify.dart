import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

final _plugin = FlutterLocalNotificationsPlugin();
bool _ready = false;
int _id = 0;

/// Payloads of notifications the user tapped while the app runs.
final notificationTaps = StreamController<String>.broadcast();

/// Payload of the notification that started the app, if one did.
Future<String?> launchPayload() async {
  if (!_ready) return null;
  try {
    final d = await _plugin.getNotificationAppLaunchDetails();
    return d?.didNotificationLaunchApp == true
        ? d?.notificationResponse?.payload
        : null;
  } catch (_) {
    return null;
  }
}

/// Sets up system notifications (Android, Linux). Any failure just leaves
/// them off: the tile badge still shows the alert.
Future<void> initNotifications() async {
  if (!Platform.isAndroid && !Platform.isLinux) return;
  try {
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        linux: LinuxInitializationSettings(defaultActionName: 'Open'),
      ),
      onDidReceiveNotificationResponse: (r) {
        final p = r.payload;
        if (p != null) notificationTaps.add(p);
      },
    );
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
    _ready = true;
  } catch (e) {
    debugPrint('notifications unavailable: $e');
  }
}

/// [payload] comes back through [notificationTaps] when it is tapped.
Future<void> showAlert(String title, String body, String payload) async {
  if (!_ready) return;
  try {
    await _plugin.show(
      id: _id++,
      title: title,
      body: body,
      payload: payload,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'alerts',
          'Camera alerts',
          importance: Importance.high,
          priority: Priority.high,
        ),
        linux: LinuxNotificationDetails(),
      ),
    );
  } catch (e) {
    debugPrint('cannot show notification: $e');
  }
}

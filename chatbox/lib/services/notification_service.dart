import 'dart:async';
import 'package:chatbox/core/config/app_environment.dart';
import 'package:chatbox/models/notification_settings.dart';
import 'package:firebase_messaging/firebase_messaging.dart' hide NotificationSettings;
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // Silent data-only push wake-up signal: the background message triggers
  // local reconciliation when the user returns and an OS-level notification tray alert.
  try {
    final localNotifications = FlutterLocalNotificationsPlugin();

    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwinSettings = DarwinInitializationSettings();
    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: darwinSettings,
      macOS: darwinSettings,
    );

    await localNotifications.initialize(settings: initSettings);

    final androidPlugin = localNotifications
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin != null) {
      const channel = AndroidNotificationChannel(
        'nest_messages',
        'Private Messages',
        description: 'End-to-end encrypted private message notifications',
        importance: Importance.high,
      );
      await androidPlugin.createNotificationChannel(channel);
    }

    String title = 'Nest';
    String body = 'New private message received';

    if (message.notification != null) {
      title = message.notification!.title ?? title;
      body = message.notification!.body ?? body;
    } else if (message.data.isNotEmpty) {
      if (message.data['type'] == 'wakeup') {
        final sender = message.data['senderId'] as String?;
        title = 'Nest';
        body = (sender != null && sender.isNotEmpty)
            ? 'New message from $sender'
            : 'New private message received';
      } else if (message.data['title'] != null) {
        title = message.data['title'] as String;
        body = message.data['body'] as String? ?? body;
      }
    }

    final payload = message.data['conversationId'] as String? ??
        message.data['senderId'] as String?;

    const androidDetails = AndroidNotificationDetails(
      'nest_messages',
      'Private Messages',
      channelDescription: 'End-to-end encrypted private message notifications',
      importance: Importance.high,
      priority: Priority.high,
      icon: '@mipmap/ic_launcher',
    );

    const darwinDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    const details = NotificationDetails(
      android: androidDetails,
      iOS: darwinDetails,
      macOS: darwinDetails,
    );

    final notificationId = message.messageId != null
        ? message.messageId.hashCode
        : DateTime.now().millisecondsSinceEpoch ~/ 1000;

    await localNotifications.show(
      id: notificationId,
      title: title,
      body: body,
      notificationDetails: details,
      payload: payload,
    );
  } catch (e) {
    debugPrint('Background notification tray alert error: $e');
  }
}

/// Public alias for [_firebaseMessagingBackgroundHandler] to support direct testing
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await _firebaseMessagingBackgroundHandler(message);
}

/// Abstract contract for privacy-first push notifications and wake-up signals (Phase 14)
abstract class NotificationService {
  Future<void> initialize();
  Future<String?> getDeviceToken();
  
  NotificationSettings get settings;
  Future<void> updateSettings(NotificationSettings newSettings);

  /// Backwards-compatible raw notification display
  Future<void> showNotification({
    required String title,
    required String body,
    String? payload,
  });

  /// Displays a privacy-preserving local notification banner after local decryption.
  /// When Discreet Mode is active, content and sender are replaced with generic text.
  Future<void> showLocalAlert({
    required String title,
    required String body,
    String? conversationId,
    bool? isDiscreet,
  });

  /// Processes a silent wake-up signal from FCM/APNs and triggers message synchronization.
  Future<void> handleSilentWakeup(
    PushWakeupSignal signal, {
    required Future<void> Function() onSync,
  });

  /// Buffers a conversation ID when the user taps a notification while the app is locked.
  void bufferPendingRoute(String conversationId);

  /// Consumes and clears any buffered pending conversation route after authentication.
  String? consumePendingRoute();

  /// Stream of conversation IDs emitted when notifications are tapped.
  Stream<String> get onNotificationTapped;

  /// Stream of local alerts emitted when notifications are displayed.
  Stream<Map<String, dynamic>> get onNotificationDisplayed;

  /// Simulates or dispatches a notification tap event.
  void simulateNotificationTap(String conversationId);
}

/// Default implementation of [NotificationService] enforcing Discreet Mode and zero telemetry.
class DefaultNotificationService implements NotificationService {
  static final DefaultNotificationService _instance =
      DefaultNotificationService._internal();
  factory DefaultNotificationService() => _instance;
  DefaultNotificationService._internal();

  NotificationSettings _settings = const NotificationSettings();
  String? _deviceToken = 'mock_fcm_token_nest';
  String? _pendingRoute;
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();
  final StreamController<String> _tappedController =
      StreamController<String>.broadcast();
  final StreamController<Map<String, dynamic>> _displayedController =
      StreamController<Map<String, dynamic>>.broadcast();

  /// Log of displayed alerts (useful for automated testing and verification)
  final List<Map<String, dynamic>> displayedAlerts = [];

  @override
  Stream<Map<String, dynamic>> get onNotificationDisplayed =>
      _displayedController.stream;

  @override
  NotificationSettings get settings => _settings;

  @override
  Future<void> initialize() async {
    try {
      const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
      const darwinSettings = DarwinInitializationSettings();
      const initSettings = InitializationSettings(
        android: androidSettings,
        iOS: darwinSettings,
        macOS: darwinSettings,
      );

      await _localNotifications.initialize(
        settings: initSettings,
        onDidReceiveNotificationResponse: (NotificationResponse response) {
          final payload = response.payload;
          if (payload != null && payload.isNotEmpty) {
            simulateNotificationTap(payload);
          }
        },
      );

      // Create Android Notification Channel before any alerts are shown
      final androidPlugin = _localNotifications
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      if (androidPlugin != null) {
        const channel = AndroidNotificationChannel(
          'nest_messages',
          'Private Messages',
          description: 'End-to-end encrypted private message notifications',
          importance: Importance.high,
        );
        await androidPlugin.createNotificationChannel(channel);

        // Request POST_NOTIFICATIONS permission on Android 13+ (API 33+)
        await androidPlugin.requestNotificationsPermission();
      }
    } catch (e) {
      debugPrint('DefaultNotificationService: local notifications init error: $e');
    }

    if (AppEnvironment.isProduction) {
      try {
        final messaging = FirebaseMessaging.instance;
        await messaging.requestPermission(
          alert: true,
          badge: true,
          sound: true,
        );
        final token = await messaging.getToken();
        if (token != null) {
          _deviceToken = token;
        }
        FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
        FirebaseMessaging.onMessage.listen((RemoteMessage message) {
          try {
            if (message.data['type'] == 'wakeup') {
              final sender = message.data['senderId'] as String? ?? 'Partner';
              showLocalAlert(
                title: 'New Message',
                body: 'Encrypted message from $sender',
                conversationId: sender,
              );
            }
          } catch (e) {
            debugPrint('FirebaseMessaging onMessage error: $e');
          }
        });
      } catch (e) {
        debugPrint('DefaultNotificationService: Firebase messaging init error: $e');
      }
    }
  }

  @override
  Future<String?> getDeviceToken() async => _deviceToken;

  /// Sets a custom mock token (useful for multi-device simulation and testing)
  void setMockDeviceToken(String? token) {
    _deviceToken = token;
  }

  @override
  Future<void> updateSettings(NotificationSettings newSettings) async {
    _settings = newSettings;
  }

  @override
  Future<void> showNotification({
    required String title,
    required String body,
    String? payload,
  }) async {
    try {
      await showLocalAlert(
        title: title,
        body: body,
        conversationId: payload,
      );
    } catch (e) {
      debugPrint('DefaultNotificationService: showNotification error (handled safely): $e');
    }
  }

  @override
  Future<void> showLocalAlert({
    required String title,
    required String body,
    String? conversationId,
    bool? isDiscreet,
  }) async {
    try {
      if (!_settings.enabled) return;

      final discreet = isDiscreet ?? _settings.hidePreviewOnLockScreen;
      // In Discreet Mode, never expose plaintext message content or sender identities
      final displayTitle = (discreet || _settings.hideSenderIdentity) ? 'Nest' : title;
      final displayBody = discreet ? 'New private message received' : body;

      final alertData = {
        'title': displayTitle,
        'body': displayBody,
        'conversationId': conversationId,
        'isDiscreet': discreet,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };

      displayedAlerts.add(alertData);
      if (!_displayedController.isClosed) {
        _displayedController.add(alertData);
      }

      if (AppEnvironment.isProduction) {
        try {
          const androidDetails = AndroidNotificationDetails(
            'nest_messages',
            'Private Messages',
            channelDescription: 'End-to-end encrypted private message notifications',
            importance: Importance.high,
            priority: Priority.high,
            icon: '@mipmap/ic_launcher',
          );
          const darwinDetails = DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
          );
          const details = NotificationDetails(
            android: androidDetails,
            iOS: darwinDetails,
            macOS: darwinDetails,
          );

          final notifId = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          await _localNotifications.show(
            id: notifId,
            title: displayTitle,
            body: displayBody,
            notificationDetails: details,
            payload: conversationId,
          );
        } catch (e) {
          debugPrint('DefaultNotificationService: local notification show error (handled safely): $e');
        }
      }
    } catch (e) {
      debugPrint('DefaultNotificationService: showLocalAlert outer error (handled safely): $e');
    }
  }

  @override
  Future<void> handleSilentWakeup(
    PushWakeupSignal signal, {
    required Future<void> Function() onSync,
  }) async {
    if (!_settings.enabled) return;
    await onSync();
  }

  @override
  void bufferPendingRoute(String conversationId) {
    _pendingRoute = conversationId;
  }

  @override
  String? consumePendingRoute() {
    final route = _pendingRoute;
    _pendingRoute = null;
    return route;
  }

  @override
  Stream<String> get onNotificationTapped => _tappedController.stream;

  /// Simulates a user tapping a notification banner
  @override
  void simulateNotificationTap(String conversationId) {
    bufferPendingRoute(conversationId);
    _tappedController.add(conversationId);
  }

  /// Clears in-memory test logs and resets default settings
  void clearLogs() {
    displayedAlerts.clear();
    _pendingRoute = null;
    _settings = const NotificationSettings();
  }

  void dispose() {
    _tappedController.close();
    _displayedController.close();
  }
}

/// Backwards-compatible alias for existing service usage
class LocalNotificationService extends DefaultNotificationService {
  static final LocalNotificationService _subInstance =
      LocalNotificationService._();
  factory LocalNotificationService() => _subInstance;
  LocalNotificationService._() : super._internal();
}

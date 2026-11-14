import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:chatbox/core/config/app_environment.dart';
import 'package:chatbox/core/constants/app_constants.dart';
import 'package:chatbox/core/theme/app_theme.dart';
import 'package:chatbox/database/local_database.dart';
import 'package:chatbox/repositories/auth_repository.dart';
import 'package:chatbox/repositories/chat_repository.dart';
import 'package:chatbox/screens/auth/auth_gate.dart';
import 'package:chatbox/services/app_lock_service.dart';
import 'package:chatbox/services/notification_service.dart';
import 'package:chatbox/widgets/top_notification_banner.dart';

/// Top-level InheritedWidget providing application-wide dependency injection
/// for repositories and services. Sits above MaterialApp to guarantee
/// dependencies remain active throughout all route transitions and lifecycle changes,
/// preventing InheritedElement deactivation crashes ('_dependents.isEmpty').
class AppScope extends InheritedWidget {
  final AuthRepository authRepository;
  final ChatRepository chatRepository;
  final AppLockService appLockService;
  final NotificationService notificationService;

  const AppScope({
    super.key,
    required this.authRepository,
    required this.chatRepository,
    required this.appLockService,
    required this.notificationService,
    required super.child,
  });

  static AppScope of(BuildContext context) {
    final AppScope? result =
        context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(result != null, 'No AppScope found in context');
    return result!;
  }

  static AppScope? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<AppScope>();
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) => false;
}

void main() async {
  // 1. Framework Initialization
  // Ensure Flutter engine bindings, binary messengers, and native channels
  // are fully established before asynchronous service initializations.
  WidgetsFlutterBinding.ensureInitialized();

  // 2. Set Environment Mode
  // Default to production environment to ensure release builds point to
  // live Firebase Realtime Database and Cloud Messaging endpoints.
  AppEnvironment.setEnvironment(EnvironmentType.production);

  // 3. Database Pre-flight Warmup
  // Pre-initialize SQLite database schema, indices, and encryption keys
  // to prevent race conditions or stale locks during app bootstrap.
  try {
    await LocalDatabase().initialize();
  } catch (dbError) {
    debugPrint('LocalDatabase warmup notice: $dbError');
  }

  // 4. Firebase Pre-flight, App Check & RTDB Offline Persistence
  // Initialize Firebase and activate Play Integrity App Check to ensure only
  // verified Nest binaries interact with the Realtime Database and Cloud Functions.
  try {
    await Firebase.initializeApp();

    // Enable offline disk persistence on Realtime Database (100MB cache)
    try {
      final rtdb = FirebaseDatabase.instanceFor(
        app: Firebase.app(),
        databaseURL: AppConstants.firebaseDatabaseUrl,
      );
      rtdb.setPersistenceEnabled(true);
      rtdb.setPersistenceCacheSizeBytes(100 * 1024 * 1024);
    } catch (_) {
      try {
        FirebaseDatabase.instance.setPersistenceEnabled(true);
      } catch (_) {}
    }

    // Activate Firebase App Check (Play Integrity in release, Debug provider in debug)
    try {
      await FirebaseAppCheck.instance.activate(
        androidProvider: kReleaseMode
            ? AndroidProvider.playIntegrity
            : AndroidProvider.debug,
        appleProvider: kReleaseMode
            ? AppleProvider.deviceCheck
            : AppleProvider.debug,
      );
    } catch (appCheckError) {
      debugPrint('FirebaseAppCheck activation notice: $appCheckError');
    }
  } catch (e) {
    debugPrint('Firebase initialization notice: $e');
  }

  // 5. Notification Service Initialization
  final notificationService = DefaultNotificationService();
  await notificationService.initialize();

  // 6. Singleton Dependency Injection
  final authRepository = DefaultAuthRepository();
  final chatRepository = LocalChatRepository(
    notificationService: notificationService,
  );
  final appLockService = DefaultAppLockService();

  runApp(MyApp(
    authRepository: authRepository,
    chatRepository: chatRepository,
    appLockService: appLockService,
    notificationService: notificationService,
  ));
}

class MyApp extends StatelessWidget {
  final String partnerName;
  final AuthRepository? authRepository;
  final ChatRepository? chatRepository;
  final AppLockService? appLockService;
  final NotificationService? notificationService;
  final Widget? home;

  const MyApp({
    super.key,
    this.partnerName = AppConstants.defaultPartnerName,
    this.authRepository,
    this.chatRepository,
    this.appLockService,
    this.notificationService,
    this.home,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveAuthRepo = authRepository ?? DefaultAuthRepository();
    final effectiveNotificationService =
        notificationService ?? DefaultNotificationService();
    final effectiveChatRepo = chatRepository ??
        LocalChatRepository(notificationService: effectiveNotificationService);
    final effectiveLockService = appLockService ?? DefaultAppLockService();

    return AppScope(
      authRepository: effectiveAuthRepo,
      chatRepository: effectiveChatRepo,
      appLockService: effectiveLockService,
      notificationService: effectiveNotificationService,
      child: MaterialApp(
        title: '${AppConstants.appName} - Private Chat',
        theme: AppTheme.darkTheme,
        builder: (context, child) {
          return InAppNotificationOverlay(
            notificationService: effectiveNotificationService,
            child: child ?? const SizedBox.shrink(),
          );
        },
        home: home ??
            AuthGate(
              authRepository: effectiveAuthRepo,
              chatRepository: effectiveChatRepo,
              appLockService: effectiveLockService,
            ),
        debugShowCheckedModeBanner: false,
      ),
    );
  }
}

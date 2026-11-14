import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
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

  // 4. Firebase Pre-flight Authentication
  // Initialize Firebase and ensure anonymous authentication is established
  // immediately so Realtime Database security rules (auth != null) are satisfied
  // for early user directory lookups and relay listeners.
  try {
    await Firebase.initializeApp();
    try {
      if (FirebaseAuth.instance.currentUser == null) {
        await FirebaseAuth.instance.signInAnonymously();
      }
    } catch (authError) {
      debugPrint('FirebaseAuth anonymous sign-in notice: $authError');
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

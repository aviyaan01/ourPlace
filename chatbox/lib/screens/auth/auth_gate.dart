import 'dart:async';
import 'package:flutter/material.dart';
import 'package:chatbox/main.dart';
import 'package:chatbox/models/user.dart';
import 'package:chatbox/repositories/auth_repository.dart';
import 'package:chatbox/repositories/chat_repository.dart';
import 'package:chatbox/services/app_lock_service.dart';
import 'package:chatbox/screens/auth/app_lock_screen.dart';
import 'package:chatbox/screens/auth/auth_screen.dart';
import 'package:chatbox/screens/auth/passcode_setup_screen.dart';
import 'package:chatbox/screens/home_screen.dart';

/// Entryway gate that coordinates account session and local device lock state.
/// Employs explicit ValueKeys and route unmounting guards to prevent
/// Flutter InheritedElement deactivation assertions ('_dependents.isEmpty').
class AuthGate extends StatefulWidget {
  final AuthRepository? authRepository;
  final ChatRepository? chatRepository;
  final AppLockService? appLockService;

  const AuthGate({
    super.key,
    this.authRepository,
    this.chatRepository,
    this.appLockService,
  });

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> with WidgetsBindingObserver {
  late AuthRepository _authRepository;
  late AppLockService _appLockService;
  late ChatRepository _chatRepository;
  StreamSubscription<bool>? _lockStateSub;
  bool? _isPasscodeConfigured;
  String? _lastUserId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _resolveDependencies();
    _refreshPasscodeStatus();
    _subscribeLockState();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final appScope = AppScope.maybeOf(context);
    if (appScope != null) {
      if (widget.authRepository == null) _authRepository = appScope.authRepository;
      if (widget.chatRepository == null) _chatRepository = appScope.chatRepository;
      if (widget.appLockService == null) {
        if (_appLockService != appScope.appLockService) {
          _appLockService = appScope.appLockService;
          _subscribeLockState();
        }
      }
    }
  }

  @override
  void didUpdateWidget(AuthGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.authRepository != oldWidget.authRepository ||
        widget.chatRepository != oldWidget.chatRepository ||
        widget.appLockService != oldWidget.appLockService) {
      _resolveDependencies();
      _subscribeLockState();
    }
  }

  void _resolveDependencies() {
    _authRepository = widget.authRepository ?? DefaultAuthRepository();
    _appLockService = widget.appLockService ?? DefaultAppLockService();
    _chatRepository = widget.chatRepository ?? LocalChatRepository();
  }

  void _subscribeLockState() {
    _lockStateSub?.cancel();
    _lockStateSub = _appLockService.lockStateChanges.listen((_) {
      if (mounted) {
        setState(() {});
        _refreshPasscodeStatus();
      }
    });
  }

  Future<void> _refreshPasscodeStatus() async {
    final configured = await _appLockService.isPasscodeConfigured();
    if (mounted) {
      setState(() {
        _isPasscodeConfigured = configured;
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      // Guard against infinite auto-lock loops when native OS biometric dialogs
      // transition the app lifecycle to paused or hidden.
      if (_appLockService.isAppUnlocked &&
          !_appLockService.isAuthenticatingBiometrics) {
        _appLockService.lockApp();
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _lockStateSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: _authRepository.authStateChanges,
      builder: (context, authSnapshot) {
        if (authSnapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            key: ValueKey('gate_loading_scaffold'),
            backgroundColor: Colors.black,
            body: Center(
              child: CircularProgressIndicator(
                color: Colors.white38,
              ),
            ),
          );
        }

        final user = authSnapshot.data;

        // Clean up pushed routes upon user sign out or transition to unauthenticated
        if (_lastUserId != null && user == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && Navigator.of(context).canPop()) {
              Navigator.of(context).popUntil((route) => route.isFirst);
            }
          });
        }

        if (user?.id != _lastUserId) {
          _lastUserId = user?.id;
          if (user != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _refreshPasscodeStatus();
            });
          }
        }

        /// 1. Unauthenticated -> Show login / account creation screen
        if (user == null) {
          return AuthScreen(
            key: const ValueKey('gate_auth_screen'),
            authRepository: _authRepository,
          );
        }

        /// 2. Authenticated user -> Check device lock state
        if (_isPasscodeConfigured == null) {
          return const Scaffold(
            key: ValueKey('gate_passcode_checking_scaffold'),
            backgroundColor: Colors.black,
            body: Center(
              child: CircularProgressIndicator(
                color: Colors.white38,
              ),
            ),
          );
        }

        /// 2A. No local passcode configured -> Force first-time passcode setup
        if (!_isPasscodeConfigured!) {
          return PasscodeSetupScreen(
            key: const ValueKey('gate_passcode_setup_screen'),
            appLockService: _appLockService,
            onSetupComplete: _refreshPasscodeStatus,
          );
        }

        /// 2B. Passcode configured but app is locked -> Show dedicated AppLockScreen
        if (!_appLockService.isAppUnlocked) {
          return AppLockScreen(
            key: const ValueKey('gate_app_lock_screen'),
            appLockService: _appLockService,
            onUnlocked: () {
              if (mounted) setState(() {});
            },
            onSignOutRequested: () async {
              _chatRepository.stopRelayListener();
              _appLockService.lockApp();
              if (mounted && Navigator.of(context).canPop()) {
                Navigator.of(context).popUntil((route) => route.isFirst);
              }
              await _authRepository.signOut();
            },
          );
        }

        /// 2C. Unlocked and authenticated -> Show primary HomeScreen (Inbox)
        return HomeScreen(
          key: ValueKey('gate_home_screen_${user.id}'),
          currentUser: user,
          authRepository: _authRepository,
          chatRepository: _chatRepository,
          appLockService: _appLockService,
        );
      },
    );
  }
}

import 'package:flutter/material.dart';
import 'package:chatbox/main.dart';
import 'package:chatbox/models/user.dart';
import 'package:chatbox/repositories/auth_repository.dart';
import 'package:chatbox/repositories/chat_repository.dart';
import 'package:chatbox/repositories/conversation_repository.dart';
import 'package:chatbox/screens/inbox/inbox_screen.dart';
import 'package:chatbox/screens/profile/profile_screen.dart';

import 'package:chatbox/services/app_lock_service.dart';

/// Top-level Home Screen hosting the primary Inbox and profile navigation
class HomeScreen extends StatelessWidget {
  final User? currentUser;
  final AuthRepository? authRepository;
  final ChatRepository? chatRepository;
  final ConversationRepository? conversationRepository;
  final AppLockService? appLockService;

  const HomeScreen({
    super.key,
    this.currentUser,
    this.authRepository,
    this.chatRepository,
    this.conversationRepository,
    this.appLockService,
  });

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.maybeOf(context);
    final effectiveChatRepo = chatRepository ?? scope?.chatRepository ?? LocalChatRepository();
    final effectiveAuthRepo = authRepository ?? scope?.authRepository ?? DefaultAuthRepository();
    final effectiveLockService = appLockService ?? scope?.appLockService ?? DefaultAppLockService();

    final activeUser = currentUser?.username;
    if (activeUser != null && activeUser.isNotEmpty) {
      effectiveChatRepo.startRelayListener(activeUser);
      effectiveChatRepo.syncService.reconcile(currentUserId: activeUser);
    }

    return InboxScreen(
      currentUser: currentUser,
      authRepository: effectiveAuthRepo,
      chatRepository: effectiveChatRepo,
      conversationRepository: conversationRepository,
      onOpenProfile: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => ProfileScreen(
              currentUser: currentUser,
              authRepository: effectiveAuthRepo,
              appLockService: effectiveLockService,
              realtimeService: effectiveChatRepo.realtimeService,
              notificationService: effectiveChatRepo.notificationService,
              loveConnectionService: effectiveChatRepo.loveConnectionService,
              conversationSharingService:
                  effectiveChatRepo.conversationSharingService,
              chatRepository: effectiveChatRepo,
            ),
            settings: const RouteSettings(name: '/profile'),
          ),
        );
      },
    );
  }
}

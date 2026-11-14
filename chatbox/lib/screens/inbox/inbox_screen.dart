import 'dart:async';
import 'package:flutter/material.dart';
import 'package:chatbox/main.dart';
import 'package:chatbox/core/constants/app_constants.dart';
import 'package:chatbox/core/theme/app_theme.dart';
import 'package:chatbox/models/conversation.dart';
import 'package:chatbox/models/user.dart';
import 'package:chatbox/repositories/auth_repository.dart';
import 'package:chatbox/repositories/chat_repository.dart';
import 'package:chatbox/repositories/conversation_repository.dart';
import 'package:chatbox/screens/chat_screen.dart';
import 'package:chatbox/widgets/conversation_tile.dart';
import 'package:chatbox/services/user_directory_service.dart';

/// Primary Inbox Screen displaying Love Connection and multi-user conversations
class InboxScreen extends StatefulWidget {
  final User? currentUser;
  final AuthRepository? authRepository;
  final ChatRepository? chatRepository;
  final ConversationRepository? conversationRepository;
  final VoidCallback? onOpenProfile;

  const InboxScreen({
    super.key,
    this.currentUser,
    this.authRepository,
    this.chatRepository,
    this.conversationRepository,
    this.onOpenProfile,
  });

  @override
  State<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends State<InboxScreen> {
  late ConversationRepository _conversationRepo;
  late ChatRepository _chatRepository;
  late AuthRepository _authRepository;
  final TextEditingController _searchController = TextEditingController();
  StreamSubscription<List<Conversation>>? _conversationsSub;
  StreamSubscription<dynamic>? _notificationSub;

  List<Conversation> _allConversations = [];
  List<Conversation> _filteredConversations = [];
  List<DirectoryProfile> _remoteSearchResults = [];
  Timer? _searchDebounceTimer;
  bool _isLoading = true;
  String _searchQuery = '';
  User? _resolvedCurrentUser;

  String get _activeUserId =>
      widget.currentUser?.username ??
      widget.currentUser?.id ??
      _resolvedCurrentUser?.username ??
      _resolvedCurrentUser?.id ??
      _chatRepository.database.activeUsername ??
      AppConstants.currentUserId;

  @override
  void initState() {
    super.initState();
    _resolvedCurrentUser = widget.currentUser;
    _conversationRepo =
        widget.conversationRepository ?? LocalConversationRepository();
    _chatRepository = widget.chatRepository ?? LocalChatRepository();
    _authRepository = widget.authRepository ?? DefaultAuthRepository();
    _searchController.addListener(_onSearchChanged);
    _loadConversations();
    _ensureRelayListener();

    _conversationsSub = _conversationRepo
        .watchConversations(currentUserId: _activeUserId)
        .listen((conversations) {
      if (mounted) {
        setState(() {
          _allConversations = conversations;
          _applySearchFilter();
          _isLoading = false;
        });
      }
    });
    _notificationSub = _chatRepository.notificationService.onNotificationDisplayed
        .listen((_) => _loadConversations());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = AppScope.maybeOf(context);
    if (scope != null) {
      if (widget.chatRepository == null && _chatRepository != scope.chatRepository) {
        _chatRepository = scope.chatRepository;
      }
      if (widget.authRepository == null && _authRepository != scope.authRepository) {
        _authRepository = scope.authRepository;
      }
    }
    _ensureRelayListener();
  }

  @override
  void didUpdateWidget(covariant InboxScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentUser != widget.currentUser ||
        oldWidget.chatRepository != widget.chatRepository) {
      if (widget.currentUser != null) {
        _resolvedCurrentUser = widget.currentUser;
      }
      if (widget.chatRepository != null) {
        _chatRepository = widget.chatRepository!;
      }
      _ensureRelayListener();
      _loadConversations();
    }
  }

  Future<void> _ensureRelayListener() async {
    try {
      String? resolvedId = widget.currentUser?.username ?? widget.currentUser?.id;
      if (resolvedId == null || resolvedId.isEmpty || resolvedId == AppConstants.currentUserId) {
        if (_resolvedCurrentUser != null && _resolvedCurrentUser!.username.isNotEmpty) {
          resolvedId = _resolvedCurrentUser!.username;
        } else {
          try {
            final user = await _authRepository.getCurrentUser();
            if (user != null && user.username.isNotEmpty) {
              _resolvedCurrentUser = user;
              resolvedId = user.username;
            }
          } catch (_) {}
        }
      }

      resolvedId ??= _chatRepository.database.activeUsername;
      if (resolvedId != null && resolvedId.isNotEmpty && resolvedId != AppConstants.currentUserId) {
        _chatRepository.startRelayListener(resolvedId);
        try {
          await _chatRepository.syncService.reconcile(currentUserId: resolvedId);
        } catch (_) {}
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _searchDebounceTimer?.cancel();
    _conversationsSub?.cancel();
    _notificationSub?.cancel();
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _applySearchFilter() {
    final query = _searchQuery;
    if (query.isEmpty) {
      _filteredConversations = _allConversations;
    } else {
      _filteredConversations = _allConversations.where((c) {
        final nameMatch = c.partner.displayName.toLowerCase().contains(query);
        final usernameMatch = c.partner.username.toLowerCase().contains(query);
        final messageMatch = c.lastMessage?.text.toLowerCase().contains(query) ?? false;
        return nameMatch || usernameMatch || messageMatch;
      }).toList();
    }
  }

  void _onSearchChanged() {
    final query = _searchController.text.trim().toLowerCase();
    setState(() {
      _searchQuery = query;
      _applySearchFilter();
    });

    _searchDebounceTimer?.cancel();
    if (query.isNotEmpty) {
      _searchDebounceTimer = Timer(const Duration(milliseconds: 300), () async {
        try {
          final results = await DefaultUserDirectoryService().searchUsers(query);
          if (mounted && _searchQuery == query) {
            setState(() {
              _remoteSearchResults = results;
            });
          }
        } catch (_) {}
      });
    } else {
      setState(() {
        _remoteSearchResults = [];
      });
    }
  }

  Future<void> _loadConversations() async {
    final conversations = await _conversationRepo.getConversations(
      currentUserId: _activeUserId,
    );
    if (mounted) {
      setState(() {
        _allConversations = conversations;
        _applySearchFilter();
        _isLoading = false;
      });
    }
  }

  void _openConversation(Conversation conversation) {
    _conversationRepo.markAsRead(conversation.id);
    final partnerId = conversation.partner.username.isNotEmpty
        ? conversation.partner.username
        : conversation.partner.id;
    final effectiveUser = widget.currentUser ?? _resolvedCurrentUser;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => ChatScreen(
          partnerName: conversation.partner.displayName,
          partnerId: partnerId,
          currentUser: effectiveUser,
          repository: _chatRepository,
          authRepository: _authRepository,
          isLoveConnection: conversation.isLoveConnection,
        ),
        settings: const RouteSettings(name: '/chat'),
      ),
    ).then((_) => _loadConversations());
  }

  void _showNewConversationDialog() {
    showDialog(
      context: context,
      builder: (ctx) {
        return _NewConversationDialog(
          onStartChat: (raw) async {
            final trimmed = raw.trim();
            if (trimmed.isEmpty) return;
            final clean = trimmed.replaceAll('@', '').trim();
            if (clean.isEmpty) return;
            final normalized = '@$clean';

            // Look up profile if available in directory to resolve public key
            String? publicKey;
            try {
              final profile =
                  await DefaultUserDirectoryService().lookupProfile(normalized);
              publicKey = profile?.publicIdentityKey;
            } catch (_) {}

            final displayName = clean.length > 1
                ? clean[0].toUpperCase() + clean.substring(1)
                : clean.toUpperCase();
            final partnerUser = User(
              id: 'user_$clean',
              username: normalized,
              displayName: displayName,
              publicIdentityKey: publicKey,
              isCurrentUser: false,
            );

            if (ctx.mounted) {
              Navigator.of(ctx).pop();
            }
            final newConv = await _conversationRepo.startOrGetConversation(
              partner: partnerUser,
            );
            _openConversation(newConv);
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final loveConversations =
        _filteredConversations.where((c) => c.isLoveConnection).toList();
    final otherConversations =
        _filteredConversations.where((c) => !c.isLoveConnection).toList();

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            /// Floating Pill App Header
            _buildInboxHeader(),

            /// Search Bar
            _buildSearchBar(),

            const SizedBox(height: 8),

            /// Conversation List Content
            Expanded(
              child: _isLoading
                  ? const Center(
                      child: CircularProgressIndicator(color: Colors.white38),
                    )
                  : RefreshIndicator(
                      color: Colors.white,
                      backgroundColor: const Color(0xFF383838),
                      onRefresh: _loadConversations,
                      child: _searchQuery.isNotEmpty &&
                              _filteredConversations.isEmpty &&
                              _remoteSearchResults.isEmpty
                          ? _buildEmptyState()
                          : ListView(
                              padding: const EdgeInsets.only(bottom: 24),
                              children: [
                                if (_searchQuery.isNotEmpty) ...[
                                  /// Local conversation search matches
                                  if (_filteredConversations.isNotEmpty) ...[
                                    _buildSectionHeader(
                                      'SEARCH RESULTS (${_filteredConversations.length})',
                                    ),
                                    ..._filteredConversations.map(
                                      (conv) => ConversationTile(
                                        conversation: conv,
                                        currentUserId: _activeUserId,
                                        onTap: () => _openConversation(conv),
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                  ],
                                  /// Discovered directory users from Firebase / registry
                                  if (_remoteSearchResults.isNotEmpty) ...[
                                    _buildSectionHeader(
                                      'DISCOVERED USERS (${_remoteSearchResults.length})',
                                      hasAccent: true,
                                    ),
                                    ..._remoteSearchResults.map((profile) {
                                      final clean = profile.username.replaceAll('@', '');
                                      final displayName = clean.isNotEmpty
                                          ? clean[0].toUpperCase() + clean.substring(1)
                                          : profile.username;
                                      final partnerUser = User(
                                        id: 'user_$clean',
                                        username: profile.username,
                                        displayName: displayName,
                                        publicIdentityKey: profile.publicIdentityKey,
                                        isCurrentUser: false,
                                      );
                                      return ListTile(
                                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                                        leading: CircleAvatar(
                                          backgroundColor: const Color(0xFF383838),
                                          child: Text(
                                            displayName.isNotEmpty ? displayName[0] : '?',
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                        title: Text(
                                          displayName,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        subtitle: Text(
                                          profile.username,
                                          style: const TextStyle(
                                            color: Colors.white54,
                                            fontSize: 13,
                                          ),
                                        ),
                                        trailing: const Icon(
                                          Icons.chat_bubble_outline,
                                          color: Colors.white70,
                                          size: 20,
                                        ),
                                        onTap: () async {
                                          final newConv = await _conversationRepo
                                              .startOrGetConversation(partner: partnerUser);
                                          _openConversation(newConv);
                                        },
                                      );
                                    }),
                                  ],
                                ] else ...[
                                  /// Love Connection Section (Always pinned at top when not searching)
                                  _buildSectionHeader(
                                    loveConversations.isNotEmpty
                                        ? '❤️ LOVE CONNECTION'
                                        : '❤️ LOVE CONNECTION (0/1)',
                                    hasAccent: true,
                                  ),
                                  if (loveConversations.isNotEmpty)
                                    ...loveConversations.map(
                                      (conv) => ConversationTile(
                                        conversation: conv,
                                        currentUserId: _activeUserId,
                                        onTap: () => _openConversation(conv),
                                      ),
                                    )
                                  else
                                    _buildEmptyLoveCard(),
                                  const SizedBox(height: 14),

                                  /// Regular Conversations Section
                                  if (otherConversations.isNotEmpty) ...[
                                    _buildSectionHeader(
                                      'CONVERSATIONS (${otherConversations.length})',
                                    ),
                                    ...otherConversations.map(
                                      (conv) => ConversationTile(
                                        conversation: conv,
                                        currentUserId: _activeUserId,
                                        onTap: () => _openConversation(conv),
                                      ),
                                    ),
                                  ] else if (loveConversations.isEmpty) ...[
                                    const SizedBox(height: 32),
                                    _buildNoConversationsPlaceholder(),
                                  ],
                                ],
                              ],
                            ),
                    ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showNewConversationDialog,
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 3,
        shape: const CircleBorder(),
        tooltip: 'New conversation',
        child: const Icon(Icons.add, size: 28),
      ),
    );
  }

  Widget _buildInboxHeader() {
    final currentUsername = widget.currentUser?.username ?? '@alex';
    final cleanUsername = currentUsername.replaceFirst(RegExp(r'^@+'), '').trim();
    final avatarChar = cleanUsername.isNotEmpty
        ? cleanUsername[0].toUpperCase()
        : (currentUsername.isNotEmpty ? currentUsername[0].toUpperCase() : '?');

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF383838),
          borderRadius: BorderRadius.circular(24),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        child: Row(
          children: [
            /// App Logo / Name
            Row(
              children: [
                Container(
                  width: 26,
                  height: 26,
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                  ),
                  padding: const EdgeInsets.all(3.5),
                  child: Image.asset(
                    'assets/images/logo_icon.png',
                    fit: BoxFit.contain,
                  ),
                ),
                const SizedBox(width: 8),
                const Text(
                  'Nest',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.8,
                  ),
                ),
              ],
            ),
            const Spacer(),

            /// Current User Pill with Avatar & Tap for Profile
            GestureDetector(
              onTap: widget.onOpenProfile,
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF222222),
                  borderRadius: BorderRadius.circular(16),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 11,
                      backgroundColor: Colors.white,
                      child: Text(
                        avatarChar,
                        style: const TextStyle(
                          color: Colors.black,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      currentUsername,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF222222),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: const Color(0xFF333333)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 2.0),
        child: Row(
          children: [
            const Icon(Icons.search, color: Colors.white54, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _searchController,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                cursorColor: Colors.white,
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  hintText: 'Search conversations or @username...',
                  hintStyle: TextStyle(color: Colors.white38, fontSize: 14),
                ),
              ),
            ),
            if (_searchQuery.isNotEmpty)
              GestureDetector(
                onTap: () => _searchController.clear(),
                child: const Icon(Icons.close, color: Colors.white54, size: 18),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title, {bool hasAccent = false}) {
    return Padding(
      padding: const EdgeInsets.only(left: 22.0, right: 22.0, top: 12.0, bottom: 6.0),
      child: Text(
        title,
        style: TextStyle(
          color: hasAccent ? const Color(0xFFFF6B81) : AppTheme.textSecondary,
          fontSize: 12,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.1,
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              _searchQuery.isNotEmpty ? Icons.search_off : Icons.chat_bubble_outline,
              color: Colors.white30,
              size: 48,
            ),
            const SizedBox(height: 16),
            Text(
              _searchQuery.isNotEmpty
                  ? 'No conversations matching "$_searchQuery"'
                  : 'Your inbox is clear',
              style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              _searchQuery.isNotEmpty
                  ? 'Try searching with a different username or keyword.'
                  : 'Tap the + button below to start a private conversation.',
              style: const TextStyle(color: Colors.white54, fontSize: 13),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyLoveCard() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            const Color(0xFFFF4D6D).withValues(alpha: 0.15),
            const Color(0xFF383838),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: const Color(0xFFFF6B81).withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFFF4D6D).withValues(alpha: 0.2),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.favorite,
              color: Color(0xFFFF6B81),
              size: 24,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Connect your Love Partner (0/1)',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 3),
                const Text(
                  'Establish a private couple connection for your shared world.',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: widget.onOpenProfile,
            style: TextButton.styleFrom(
              backgroundColor: const Color(0xFFFF4D6D),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            child: const Text(
              'Connect',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNoConversationsPlaceholder() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32.0),
        child: Column(
          children: const [
            Icon(Icons.chat_bubble_outline, color: Colors.white30, size: 40),
            SizedBox(height: 12),
            Text(
              'No individual chats yet',
              style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 4),
            Text(
              'Tap the + button below to start a private conversation.',
              style: TextStyle(color: Colors.white54, fontSize: 13),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/// Dedicated dialog widget with managed controller lifecycle to prevent
/// 'TextEditingController used after being disposed' assertions during pop animations.
class _NewConversationDialog extends StatefulWidget {
  final Future<void> Function(String username) onStartChat;

  const _NewConversationDialog({required this.onStartChat});

  @override
  State<_NewConversationDialog> createState() => _NewConversationDialogState();
}

class _NewConversationDialogState extends State<_NewConversationDialog> {
  late final TextEditingController _usernameController;

  @override
  void initState() {
    super.initState();
    _usernameController = TextEditingController();
  }

  @override
  void dispose() {
    _usernameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF242424),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: const Text(
        'Start a Conversation',
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Enter username to start a private one-on-one chat:',
            style: TextStyle(color: Colors.white70, fontSize: 13),
          ),
          const SizedBox(height: 14),
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFF383838),
              borderRadius: BorderRadius.circular(16),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
            child: TextField(
              controller: _usernameController,
              style: const TextStyle(color: Colors.white),
              cursorColor: Colors.white,
              decoration: const InputDecoration(
                border: InputBorder.none,
                prefixText: '@',
                prefixStyle: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
                hintText: 'username',
                hintStyle: TextStyle(color: Colors.white38),
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.white,
            foregroundColor: Colors.black,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          ),
          onPressed: () => widget.onStartChat(_usernameController.text),
          child: const Text('Start Chat', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
      ],
    );
  }
}

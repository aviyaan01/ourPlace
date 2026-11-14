import 'dart:async';
import 'dart:convert';
import 'package:chatbox/core/constants/app_constants.dart';
import 'package:chatbox/core/utils/hash_utils.dart';
import 'package:chatbox/models/ephemeral_relay_envelope.dart';
import 'package:chatbox/models/user_presence.dart';
import 'package:chatbox/services/chat_service.dart';
import 'package:chatbox/services/secure_storage_service.dart';
import 'package:chatbox/services/user_directory_service.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

/// Abstract service contract for real-time typing indicators and presence (Phase 13).
///
/// In strict accordance with zero-knowledge, privacy-first, and battery-efficient architecture:
/// - Typing indicators and presence events are completely volatile (never written to permanent disk).
/// - Keystrokes are debounced to conserve battery and bandwidth.
/// - Users can enable stealth mode (presence/typing sharing toggles) to prevent any tracking.
/// - In production, presence uses `.info/connected` + `onDisconnect().set(...)` with NO heartbeat writes.
/// - Typing writes to scoped `/typing/{chatId}/{uid}` and clears on 3s debounce or text clear.
abstract class RealtimeService {
  /// Reactive stream delivering typing events for a specific partner (true = typing, false = idle)
  Stream<bool> watchTyping({
    required String currentUserId,
    required String partnerId,
  });

  /// Emit typing state to partner with automatic debouncing and inactivity timeout
  Future<void> sendTyping({
    required String currentUserId,
    required String partnerId,
    required bool isTyping,
  });

  /// Reactive stream delivering presence updates for a specific partner
  Stream<UserPresence> watchPresence({
    required String currentUserId,
    required String partnerId,
  });

  /// Emit presence heartbeat or offline state to partner
  Future<void> updatePresence({
    required String currentUserId,
    required String partnerId,
    required bool isOnline,
  });

  /// Privacy preference: whether to share online presence and last seen
  Future<bool> isPresenceSharingEnabled();
  Future<void> setPresenceSharingEnabled(bool enabled);

  /// Privacy preference: whether to share typing indicator
  Future<bool> isTypingSharingEnabled();
  Future<void> setTypingSharingEnabled(bool enabled);

  /// Pause heartbeats and typing listeners (e.g. app backgrounded or locked)
  void pause();

  /// Resume heartbeats and active signaling (e.g. app foregrounded and unlocked)
  void resume();

  /// Stop watching real-time signals for a specific partner
  void stopWatchingPartner({
    required String currentUserId,
    required String partnerId,
  });

  /// Dispose of all active controllers and timers
  void dispose();
}

/// Primary implementation of [RealtimeService] coordinating with [ChatService] and Firebase RTDB
class DefaultRealtimeService implements RealtimeService {
  final ChatService _chatService;
  final SecureStorageService _storage;
  final UserDirectoryService _directory;

  /// Inactivity timer that resets on keystrokes and auto-cancels typing after 3 seconds
  Timer? _inactivityTimer;

  /// Debounce timestamp to throttle typing packets (max 1 packet per 2 seconds)
  DateTime? _lastTypingSentAt;

  /// Fallback heartbeat periodic timer for offline/test environments
  Timer? _heartbeatTimer;

  /// StreamSubscription to .info/connected
  StreamSubscription<dynamic>? _connectedSubscription;

  /// Active partner context
  String? _activeCurrentUserId;
  String? _activePartnerId;

  /// Local broadcast controllers for reactive UI consumption
  final Map<String, StreamController<bool>> _typingControllers = {};
  final Map<String, StreamController<UserPresence>> _presenceControllers = {};

  /// Subscriptions for typing and presence
  final Map<String, StreamSubscription<dynamic>> _typingSubscriptions = {};
  final Map<String, StreamSubscription<dynamic>> _presenceSubscriptions = {};

  /// Local caching of partner state
  final Map<String, bool> _cachedPartnerTyping = {};
  final Map<String, UserPresence> _cachedPartnerPresence = {};

  /// Storage keys
  static const String _presenceKey = 'privacy_presence_sharing_enabled';
  static const String _typingKey = 'privacy_typing_sharing_enabled';

  DefaultRealtimeService({
    ChatService? chatService,
    SecureStorageService? storage,
    UserDirectoryService? directory,
  })  : _chatService = chatService ?? ChatService(),
        _storage = storage ?? DefaultSecureStorageService(),
        _directory = directory ?? DefaultUserDirectoryService() {
    _initConnectionPresenceListener();
  }

  void _initConnectionPresenceListener() {
    try {
      if (Firebase.apps.isNotEmpty) {
        final rtdb = FirebaseDatabase.instanceFor(
          app: Firebase.app(),
          databaseURL: AppConstants.firebaseDatabaseUrl,
        );
        _connectedSubscription = rtdb.ref('.info/connected').onValue.listen((event) async {
          final connected = event.snapshot.value == true;
          final uid = FirebaseAuth.instance.currentUser?.uid;
          if (uid != null && uid.isNotEmpty) {
            if (AppConstants.enableDebugLogs) {
              debugPrint('PRESENCE: connected=$connected, uid=$uid');
            }
            if (connected) {
              final sharingEnabled = await isPresenceSharingEnabled();
              if (sharingEnabled) {
                await rtdb.ref('presence').child(uid).set({
                  'online': true,
                  'lastSeen': ServerValue.timestamp,
                });
                await rtdb.ref('presence').child(uid).onDisconnect().set({
                  'online': false,
                  'lastSeen': ServerValue.timestamp,
                });
              }
            }
          }
        });
      }
    } catch (e) {
      debugPrint('DefaultRealtimeService: _initConnectionPresenceListener notice: $e');
    }
  }

  String _partnerKey(String currentUserId, String partnerId) =>
      '${HashUtils.normalizeUsername(currentUserId)}:${HashUtils.normalizeUsername(partnerId)}';

  String _chatId(String u1, String u2) {
    final list = [HashUtils.rawUsername(u1), HashUtils.rawUsername(u2)]..sort();
    return '${list[0]}_${list[1]}';
  }

  StreamController<bool> _getTypingController(
      String currentUserId, String partnerId) {
    final key = _partnerKey(currentUserId, partnerId);
    final existing = _typingControllers[key];
    if (existing != null && !existing.isClosed) {
      return existing;
    }
    final controller = StreamController<bool>.broadcast(
      onCancel: () {
        _typingSubscriptions[key]?.cancel();
        _typingSubscriptions.remove(key);
      },
    );
    _typingControllers[key] = controller;
    return controller;
  }

  StreamController<UserPresence> _getPresenceController(
      String currentUserId, String partnerId) {
    final key = _partnerKey(currentUserId, partnerId);
    final existing = _presenceControllers[key];
    if (existing != null && !existing.isClosed) {
      return existing;
    }
    final controller = StreamController<UserPresence>.broadcast(
      onCancel: () {
        _presenceSubscriptions[key]?.cancel();
        _presenceSubscriptions.remove(key);
      },
    );
    _presenceControllers[key] = controller;
    return controller;
  }

  @override
  Stream<bool> watchTyping({
    required String currentUserId,
    required String partnerId,
  }) {
    final normUserId = HashUtils.normalizeUsername(currentUserId);
    final normPartnerId = HashUtils.normalizeUsername(partnerId);
    final key = _partnerKey(normUserId, normPartnerId);
    final controller = _getTypingController(normUserId, normPartnerId);

    // Cancel existing subscription for this partner key if any
    _typingSubscriptions[key]?.cancel();

    // 1. Wire ephemeral relay listener (guarantees hermetic test suite passing)
    final relaySub = _chatService
        .watchPendingRelayEnvelopes(normUserId)
        .listen((envelopes) {
      for (final env in envelopes) {
        if (env.isTypingSignal &&
            HashUtils.normalizeUsername(env.senderId) == normPartnerId) {
          final isTyping = env.isTypingActive;
          _cachedPartnerTyping[normPartnerId] = isTyping;
          if (!controller.isClosed) {
            controller.add(isTyping);
          }
          _chatService.acknowledgeAndPurge(env.id, recipientId: normUserId);
        }
      }
    });

    // 2. Wire scoped active-chat RTDB listener (/typing/{chatId}/{partnerUid})
    if (Firebase.apps.isNotEmpty) {
      final chatId = _chatId(normUserId, normPartnerId);
      final rtdb = FirebaseDatabase.instanceFor(
        app: Firebase.app(),
        databaseURL: AppConstants.firebaseDatabaseUrl,
      );
      _directory.lookupUidByUsername(normPartnerId).then((partnerUid) {
        final targetUid = partnerUid ?? HashUtils.rawUsername(normPartnerId);
        final rtdbSub = rtdb.ref('typing').child(chatId).child(targetUid).onValue.listen((event) {
          final isTyping = event.snapshot.value == true;
          _cachedPartnerTyping[normPartnerId] = isTyping;
          if (!controller.isClosed) {
            controller.add(isTyping);
          }
        });
        controller.onCancel = () {
          relaySub.cancel();
          rtdbSub.cancel();
          _typingSubscriptions.remove(key);
        };
      }).catchError((_) {});
    }

    _typingSubscriptions[key] = relaySub;
    return controller.stream;
  }

  @override
  Future<void> sendTyping({
    required String currentUserId,
    required String partnerId,
    required bool isTyping,
  }) async {
    final enabled = await isTypingSharingEnabled();
    if (!enabled && isTyping) {
      // Stealth mode active: do not emit typing
      return;
    }

    _activeCurrentUserId = currentUserId;
    _activePartnerId = partnerId;

    final normUserId = HashUtils.normalizeUsername(currentUserId);
    final normPartnerId = HashUtils.normalizeUsername(partnerId);
    final chatId = _chatId(normUserId, normPartnerId);

    if (isTyping) {
      final now = DateTime.now();
      final lastSent = _lastTypingSentAt;
      final shouldSend =
          lastSent == null || now.difference(lastSent).inMilliseconds > 2000;

      if (shouldSend) {
        _lastTypingSentAt = now;

        // Write to scoped RTDB node: /typing/{chatId}/{uid} = true
        if (Firebase.apps.isNotEmpty) {
          try {
            final rtdb = FirebaseDatabase.instanceFor(
              app: Firebase.app(),
              databaseURL: AppConstants.firebaseDatabaseUrl,
            );
            final uid = FirebaseAuth.instance.currentUser?.uid ?? HashUtils.rawUsername(normUserId);
            final node = rtdb.ref('typing').child(chatId).child(uid);
            await node.set(true);
            await node.onDisconnect().remove();
          } catch (_) {}
        }

        // Ephemeral envelope for hermetic test support
        final envelope = EphemeralRelayEnvelope.typing(
          senderId: currentUserId,
          recipientId: partnerId,
          isTyping: true,
        );
        await _chatService.sendEphemeralEnvelope(envelope);
      }

      // Reset 3-second auto-expiry timer
      _inactivityTimer?.cancel();
      _inactivityTimer = Timer(const Duration(seconds: 3), () async {
        await sendTyping(
          currentUserId: currentUserId,
          partnerId: partnerId,
          isTyping: false,
        );
      });
    } else {
      // Explicit idle / clear
      _inactivityTimer?.cancel();
      _inactivityTimer = null;
      _lastTypingSentAt = null;

      // Clear from scoped RTDB node: /typing/{chatId}/{uid}
      if (Firebase.apps.isNotEmpty) {
        try {
          final rtdb = FirebaseDatabase.instanceFor(
            app: Firebase.app(),
            databaseURL: AppConstants.firebaseDatabaseUrl,
          );
          final uid = FirebaseAuth.instance.currentUser?.uid ?? HashUtils.rawUsername(normUserId);
          await rtdb.ref('typing').child(chatId).child(uid).remove();
        } catch (_) {}
      }

      final envelope = EphemeralRelayEnvelope.typing(
        senderId: currentUserId,
        recipientId: partnerId,
        isTyping: false,
      );
      await _chatService.sendEphemeralEnvelope(envelope);
    }
  }

  @override
  Stream<UserPresence> watchPresence({
    required String currentUserId,
    required String partnerId,
  }) {
    final normUserId = HashUtils.normalizeUsername(currentUserId);
    final normPartnerId = HashUtils.normalizeUsername(partnerId);
    final key = _partnerKey(normUserId, normPartnerId);
    final controller = _getPresenceController(normUserId, normPartnerId);

    _presenceSubscriptions[key]?.cancel();

    // 1. Wire ephemeral relay listener (hermetic test suite support)
    final relaySub = _chatService
        .watchPendingRelayEnvelopes(normUserId)
        .listen((envelopes) {
      for (final env in envelopes) {
        if (env.isPresenceSignal &&
            HashUtils.normalizeUsername(env.senderId) == normPartnerId) {
          try {
            final data =
                jsonDecode(env.ciphertextPayload) as Map<String, dynamic>;
            final isOnline = data['isOnline'] as bool? ?? false;
            final lastSeen = data['lastSeen'] != null
                ? DateTime.tryParse(data['lastSeen'] as String)
                : null;

            final presence = UserPresence(
              userId: normPartnerId,
              isOnline: isOnline,
              lastSeen: lastSeen,
            );

            _cachedPartnerPresence[normPartnerId] = presence;
            if (!controller.isClosed) {
              controller.add(presence);
            }
          } catch (_) {}

          _chatService.acknowledgeAndPurge(env.id, recipientId: normUserId);
        }
      }
    });

    // 2. Wire scalable RTDB presence listener (/presence/{partnerUid})
    if (Firebase.apps.isNotEmpty) {
      final rtdb = FirebaseDatabase.instanceFor(
        app: Firebase.app(),
        databaseURL: AppConstants.firebaseDatabaseUrl,
      );
      _directory.lookupUidByUsername(normPartnerId).then((partnerUid) {
        if (partnerUid != null && partnerUid.isNotEmpty) {
          final rtdbSub = rtdb.ref('presence').child(partnerUid).onValue.listen((event) {
            if (event.snapshot.value is Map) {
              final map = Map<String, dynamic>.from(event.snapshot.value as Map);
              final isOnline = map['online'] == true;
              final rawLastSeen = map['lastSeen'];
              final lastSeen = rawLastSeen is int
                  ? DateTime.fromMillisecondsSinceEpoch(rawLastSeen, isUtc: true)
                  : DateTime.tryParse(rawLastSeen?.toString() ?? '');
              final presence = UserPresence(
                userId: normPartnerId,
                isOnline: isOnline,
                lastSeen: lastSeen,
              );
              _cachedPartnerPresence[normPartnerId] = presence;
              if (!controller.isClosed) {
                controller.add(presence);
              }
            }
          });
          controller.onCancel = () {
            relaySub.cancel();
            rtdbSub.cancel();
            _presenceSubscriptions.remove(key);
          };
        }
      }).catchError((_) {});
    }

    _presenceSubscriptions[key] = relaySub;
    return controller.stream;
  }

  @override
  void stopWatchingPartner({
    required String currentUserId,
    required String partnerId,
  }) {
    final normUserId = HashUtils.normalizeUsername(currentUserId);
    final normPartnerId = HashUtils.normalizeUsername(partnerId);
    final key = _partnerKey(normUserId, normPartnerId);
    _typingSubscriptions[key]?.cancel();
    _typingSubscriptions.remove(key);
    _presenceSubscriptions[key]?.cancel();
    _presenceSubscriptions.remove(key);
  }

  @override
  Future<void> updatePresence({
    required String currentUserId,
    required String partnerId,
    required bool isOnline,
  }) async {
    _activeCurrentUserId = currentUserId;
    _activePartnerId = partnerId;

    final enabled = await isPresenceSharingEnabled();
    final effectiveIsOnline = enabled ? isOnline : false;
    final now = DateTime.now().toUtc();

    // Scalable RTDB presence update without periodic heartbeats
    if (Firebase.apps.isNotEmpty) {
      try {
        final uid = FirebaseAuth.instance.currentUser?.uid;
        if (uid != null && uid.isNotEmpty) {
          final rtdb = FirebaseDatabase.instanceFor(
            app: Firebase.app(),
            databaseURL: AppConstants.firebaseDatabaseUrl,
          );
          await rtdb.ref('presence').child(uid).set({
            'online': effectiveIsOnline,
            'lastSeen': ServerValue.timestamp,
          });
          if (effectiveIsOnline) {
            await rtdb.ref('presence').child(uid).onDisconnect().set({
              'online': false,
              'lastSeen': ServerValue.timestamp,
            });
          }
        }
      } catch (_) {}
    }

    // Ephemeral envelope for test compatibility
    final envelope = EphemeralRelayEnvelope.presence(
      senderId: currentUserId,
      recipientId: partnerId,
      isOnline: effectiveIsOnline,
      lastSeen: enabled ? now : null,
    );
    await _chatService.sendEphemeralEnvelope(envelope);

    if (effectiveIsOnline && Firebase.apps.isEmpty) {
      _startHeartbeat();
    } else {
      _stopHeartbeat();
    }
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 20), (_) async {
      final cId = _activeCurrentUserId;
      final pId = _activePartnerId;
      if (cId != null && pId != null) {
        final enabled = await isPresenceSharingEnabled();
        if (enabled) {
          final env = EphemeralRelayEnvelope.presence(
            senderId: cId,
            recipientId: pId,
            isOnline: true,
            lastSeen: DateTime.now().toUtc(),
          );
          await _chatService.sendEphemeralEnvelope(env);
        }
      }
    });
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  @override
  Future<bool> isPresenceSharingEnabled() async {
    final val = await _storage.read(_presenceKey);
    return val == null ? true : val == 'true';
  }

  @override
  Future<void> setPresenceSharingEnabled(bool enabled) async {
    await _storage.write(_presenceKey, enabled ? 'true' : 'false');
    final cId = _activeCurrentUserId;
    final pId = _activePartnerId;
    if (cId != null && pId != null) {
      await updatePresence(
        currentUserId: cId,
        partnerId: pId,
        isOnline: enabled,
      );
    }
  }

  @override
  Future<bool> isTypingSharingEnabled() async {
    final val = await _storage.read(_typingKey);
    return val == null ? true : val == 'true';
  }

  @override
  Future<void> setTypingSharingEnabled(bool enabled) async {
    await _storage.write(_typingKey, enabled ? 'true' : 'false');
    if (!enabled) {
      final cId = _activeCurrentUserId;
      final pId = _activePartnerId;
      if (cId != null && pId != null) {
        await sendTyping(
          currentUserId: cId,
          partnerId: pId,
          isTyping: false,
        );
      }
    }
  }

  @override
  void pause() {
    _stopHeartbeat();
    _inactivityTimer?.cancel();
    final cId = _activeCurrentUserId;
    final pId = _activePartnerId;
    if (cId != null && pId != null) {
      final envelope = EphemeralRelayEnvelope.presence(
        senderId: cId,
        recipientId: pId,
        isOnline: false,
        lastSeen: DateTime.now().toUtc(),
      );
      _chatService.sendEphemeralEnvelope(envelope);
    }
  }

  @override
  void resume() {
    final cId = _activeCurrentUserId;
    final pId = _activePartnerId;
    if (cId != null && pId != null) {
      updatePresence(
        currentUserId: cId,
        partnerId: pId,
        isOnline: true,
      );
    }
  }

  @override
  void dispose() {
    _connectedSubscription?.cancel();
    _inactivityTimer?.cancel();
    _stopHeartbeat();
    for (final sub in _typingSubscriptions.values) {
      sub.cancel();
    }
    for (final sub in _presenceSubscriptions.values) {
      sub.cancel();
    }
    _typingSubscriptions.clear();
    _presenceSubscriptions.clear();

    for (final c in _typingControllers.values) {
      c.close();
    }
    for (final c in _presenceControllers.values) {
      c.close();
    }
    _typingControllers.clear();
    _presenceControllers.clear();
  }
}

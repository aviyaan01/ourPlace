import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:chatbox/core/constants/app_constants.dart';
import 'package:chatbox/core/utils/hash_utils.dart';
import 'package:chatbox/database/local_database.dart';
import 'package:chatbox/models/encrypted_payload.dart';
import 'package:chatbox/models/ephemeral_relay_envelope.dart';
import 'package:chatbox/models/love_note.dart';
import 'package:chatbox/models/media_attachment.dart';
import 'package:chatbox/models/message.dart';
import 'package:chatbox/repositories/conversation_repository.dart';
import 'package:chatbox/services/chat_service.dart';
import 'package:chatbox/services/conversation_sharing_service.dart';
import 'package:chatbox/services/couple_features_service.dart';
import 'package:chatbox/services/encryption_service.dart';
import 'package:chatbox/services/love_connection_service.dart';
import 'package:chatbox/services/media_encryption_service.dart';
import 'package:chatbox/services/media_relay_service.dart';
import 'package:chatbox/services/media_storage_service.dart';
import 'package:chatbox/services/notification_service.dart';
import 'package:chatbox/services/user_directory_service.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';

/// Abstract service contract for message synchronization and offline queueing (Phase 12)
abstract class SyncService {
  /// Whether the network connectivity is active
  bool get isOnline;

  /// Update online state (supports live connectivity monitoring and test simulation)
  void setOnline(bool online);

  /// Drain and flush all unsent / failed messages queued offline
  Future<int> flushOutboundQueue({required String currentUserId});

  /// Pull and process incoming messages and delivery/read receipts from the ephemeral relay
  Future<List<ChatMessage>> processInboundEnvelopes({required String currentUserId});

  /// Dispatch an ephemeral delivery receipt back to the original sender
  Future<void> sendDeliveryReceipt({
    required String messageId,
    required String recipientId,
    required String senderId,
  });

  /// Dispatch an ephemeral read receipt back to the original sender
  Future<void> sendReadReceipt({
    required String messageId,
    required String recipientId,
    required String senderId,
  });

  /// Perform bidirectional synchronization: drain inbound queue then flush outbound queue
  Future<void> reconcile({required String currentUserId});

  /// Manually retry sending an individual failed message
  Future<bool> retryMessage(String messageId, {required String currentUserId});

  /// Mark all incoming messages from partner as read and dispatch read receipts
  Future<int> markConversationAsRead(String partnerId, {required String currentUserId});

  /// Begin continuous reactive listening to incoming relay envelopes
  void startRelayListener({required String currentUserId});

  /// Stop reactive listening to incoming relay envelopes
  void stopRelayListener();
}

/// Primary implementation of [SyncService] coordinating SQLite and the ephemeral relay
class DefaultSyncService implements SyncService {
  final LocalDatabase _database;
  final ChatService _chatService;
  final EncryptionService? _encryptionService;
  final NotificationService? _notificationService;
  final MediaRelayService? _mediaRelayService;
  final MediaStorageService? _mediaStorageService;
  final MediaEncryptionService? _mediaEncryptionService;
  final LoveConnectionService? _loveConnectionService;
  final ConversationSharingService? _conversationSharingService;
  final CoupleFeaturesService? _coupleFeaturesService;

  bool _isOnline = true;
  final Map<String, int> _decryptFailures = {};

  DefaultSyncService({
    LocalDatabase? database,
    ChatService? chatService,
    EncryptionService? encryptionService,
    NotificationService? notificationService,
    MediaRelayService? mediaRelayService,
    MediaStorageService? mediaStorageService,
    MediaEncryptionService? mediaEncryptionService,
    LoveConnectionService? loveConnectionService,
    ConversationSharingService? conversationSharingService,
    CoupleFeaturesService? coupleFeaturesService,
  })  : _database = database ?? LocalDatabase(),
        _chatService = chatService ?? ChatService(),
        _encryptionService = encryptionService,
        _notificationService = notificationService,
        _mediaRelayService = mediaRelayService,
        _mediaStorageService = mediaStorageService,
        _mediaEncryptionService = mediaEncryptionService,
        _loveConnectionService = loveConnectionService,
        _conversationSharingService = conversationSharingService,
        _coupleFeaturesService = coupleFeaturesService;

  CoupleFeaturesService? get coupleFeaturesService => _coupleFeaturesService;
  LoveConnectionService? get loveConnectionService => _loveConnectionService;
  ConversationSharingService? get conversationSharingService => _conversationSharingService;
  MediaEncryptionService? get mediaEncryptionService => _mediaEncryptionService;
  MediaRelayService? get mediaRelayService => _mediaRelayService;
  MediaStorageService? get mediaStorageService => _mediaStorageService;

  StreamSubscription<List<EphemeralRelayEnvelope>>? _relaySubscription;
  StreamSubscription<dynamic>? _inboxChildSubscription;
  String? _listeningUserId;

  @override
  void startRelayListener({required String currentUserId}) {
    final normUserId = HashUtils.normalizeUsername(currentUserId);
    if (_listeningUserId == normUserId && _relaySubscription != null) {
      return;
    }
    stopRelayListener();
    _listeningUserId = normUserId;
    debugPrint('RELAY: listening on /relays/$normUserId');

    // 1. Listen to /relays for backwards compatibility and test suites
    _relaySubscription = _chatService
        .watchPendingRelayEnvelopes(normUserId)
        .listen((envelopes) async {
      debugPrint('RELAY: received ${envelopes.length} envelopes on /relays/$normUserId');
      if (envelopes.isNotEmpty) {
        await processInboundEnvelopes(currentUserId: normUserId);
      }
    });

    // 2. High-concurrency onChildAdded listener on /inbox/{myUid}
    _startInboxChildListener(normUserId);
  }

  void _startInboxChildListener(String normUserId) async {
    _inboxChildSubscription?.cancel();
    _inboxChildSubscription = null;

    try {
      if (Firebase.apps.isNotEmpty) {
        String? uid = await DefaultUserDirectoryService().lookupUidByUsername(normUserId);
        uid ??= FirebaseAuth.instance.currentUser?.uid;
        if (uid != null && uid.isNotEmpty) {
          final rtdb = FirebaseDatabase.instanceFor(
            app: Firebase.app(),
            databaseURL: AppConstants.firebaseDatabaseUrl,
          );
          _inboxChildSubscription = rtdb.ref('inbox').child(uid).onChildAdded.listen((event) async {
            if (event.snapshot.value is Map) {
              final map = Map<String, dynamic>.from(event.snapshot.value as Map);
              map['_pushId'] = event.snapshot.key;
              final envelope = EphemeralRelayEnvelope.fromJson(map);
              await _processSingleEnvelope(envelope, currentUserId: normUserId, rtdbRef: event.snapshot.ref);
            }
          });
        }
      }
    } catch (e) {
      debugPrint('DefaultSyncService: _startInboxChildListener notice: $e');
    }
  }

  @override
  void stopRelayListener() {
    _relaySubscription?.cancel();
    _relaySubscription = null;
    _inboxChildSubscription?.cancel();
    _inboxChildSubscription = null;
    _listeningUserId = null;
  }

  Future<String?> _resolveRecipientPublicKey(String username) async {
    final account = await _database.getAccountByUsername(username);
    if (account?.publicIdentityKey != null && account!.publicIdentityKey!.isNotEmpty) {
      return account.publicIdentityKey;
    }

    try {
      final loveConn = await _loveConnectionService?.getLoveConnection();
      if (loveConn != null &&
          loveConn.partnerPublicKey != null &&
          loveConn.partnerPublicKey!.isNotEmpty) {
        final normPartner = HashUtils.normalizeUsername(loveConn.partnerUsername);
        final normRecipient = HashUtils.normalizeUsername(username);
        if (normPartner == normRecipient) {
          return loveConn.partnerPublicKey;
        }
      }
    } catch (_) {}

    try {
      final profile = await DefaultUserDirectoryService().lookupProfile(username);
      if (profile?.publicIdentityKey != null && profile!.publicIdentityKey.isNotEmpty) {
        return profile.publicIdentityKey;
      }
    } catch (_) {}

    return null;
  }

  @override
  bool get isOnline => _isOnline;

  @override
  void setOnline(bool online) {
    _isOnline = online;
  }

  @override
  Future<int> flushOutboundQueue({required String currentUserId}) async {
    if (!_isOnline) return 0;

    final failedMessages = await _database.getUnsentMessages(
      currentUserId: currentUserId,
    );

    int flushedCount = 0;
    for (final message in failedMessages) {
      final success = await _dispatchOutboundMessage(message);
      if (success) {
        flushedCount++;
      }
    }

    return flushedCount;
  }

  Future<bool> _dispatchOutboundMessage(ChatMessage message) async {
    if (!_isOnline) {
      await _database.updateMessageStatus(message.id, MessageStatus.failed);
      return false;
    }

    try {
      ChatMessage outbound = message;
      final enc = _encryptionService;
      if (enc != null) {
        final recipientKey = await _resolveRecipientPublicKey(message.recipientId);
        if (recipientKey != null && recipientKey.isNotEmpty) {
          final String payload;
          if (message.mediaAttachment != null) {
            payload = jsonEncode({
              'text': message.text,
              'mediaAttachment': message.mediaAttachment!.toJson(),
            });
          } else {
            payload = message.text;
          }
          final ciphertext = await enc.encryptPayload(payload, recipientKey);
          outbound = message.copyWith(text: ciphertext);
        }
      }

      await _chatService.sendMessage(outbound);
      await _database.updateMessageStatusIfProgressing(message.id, MessageStatus.sent);
      return true;
    } catch (_) {
      await _database.updateMessageStatus(message.id, MessageStatus.failed);
      return false;
    }
  }

  /// Process an individual incoming envelope cleanly, whether arriving via batch or onChildAdded
  Future<ChatMessage?> _processSingleEnvelope(
    EphemeralRelayEnvelope envelope, {
    required String currentUserId,
    DatabaseReference? rtdbRef,
  }) async {
    Future<void> ackEnvelope() async {
      if (rtdbRef != null) {
        try {
          await rtdbRef.remove();
        } catch (_) {}
      }
      await _chatService.acknowledgeAndPurge(envelope.id, recipientId: currentUserId);
    }

    // 1. Control / signal envelopes handled FIRST
    final loveConn = _loveConnectionService;
    final convSharing = _conversationSharingService;
    final coupleFeatures = _coupleFeaturesService;

    if (envelope.isLoveConnectionSignal) {
      if (loveConn != null) {
        await loveConn.processInboundLoveEnvelope(
          envelope,
          currentUserId: currentUserId,
          currentUsername: currentUserId,
        );
      }
      await ackEnvelope();
      return null;
    } else if (envelope.isLoveShareSignal) {
      if (convSharing != null) {
        await convSharing.handleInboundEnvelope(envelope);
      }
      await ackEnvelope();
      return null;
    } else if (envelope.isLoveLuvSignal) {
      if (coupleFeatures != null) {
        coupleFeatures.emitLuvBurst(envelope.senderId);
      }
      await ackEnvelope();
      return null;
    } else if (envelope.isReactionSignal) {
      if (coupleFeatures != null) {
        try {
          final data = jsonDecode(envelope.ciphertextPayload) as Map<String, dynamic>;
          await coupleFeatures.handleInboundReaction(
            messageId: data['message_id'] as String,
            senderUsername: data['sender_username'] as String? ?? envelope.senderId,
            emoji: data['emoji'] as String,
            isRemove: data['is_remove'] as bool? ?? false,
          );
        } catch (_) {}
      }
      await ackEnvelope();
      return null;
    } else if (envelope.isLoveNoteSignal) {
      if (coupleFeatures != null) {
        try {
          final data = jsonDecode(envelope.ciphertextPayload) as Map<String, dynamic>;
          final note = LoveNote.fromJson(data);
          await coupleFeatures.handleInboundLoveNote(note);
        } catch (_) {}
      }
      await ackEnvelope();
      return null;
    } else if (envelope.isTypingSignal) {
      await ackEnvelope();
      return null;
    } else if (envelope.isPresenceSignal) {
      await ackEnvelope();
      return null;
    } else if (envelope.isDeliveryReceipt) {
      await _database.updateMessageStatusIfProgressing(
        envelope.targetMessageId,
        MessageStatus.delivered,
      );
      await ackEnvelope();
      return null;
    } else if (envelope.isReadReceipt) {
      await _database.updateMessageStatusIfProgressing(
        envelope.targetMessageId,
        MessageStatus.read,
      );
      await ackEnvelope();
      return null;
    } else if (envelope.isSignalEnvelope) {
      await ackEnvelope();
      return null;
    }

    // 2. Standard incoming message
    final raw = ChatMessage(
      id: envelope.id,
      senderId: HashUtils.normalizeUsername(envelope.senderId),
      recipientId: HashUtils.normalizeUsername(envelope.recipientId),
      text: envelope.ciphertextPayload,
      timestamp: envelope.timestamp,
      status: MessageStatus.delivered,
    );

    ChatMessage decryptedMessage = raw;
    final enc = _encryptionService;
    bool decryptFailed = false;

    if (enc != null) {
      try {
        final senderAccount = await _database.getAccountByUsername(raw.senderId);
        String senderKey = senderAccount?.publicIdentityKey ?? '';
        if (senderKey.isEmpty) {
          senderKey = (await _resolveRecipientPublicKey(raw.senderId)) ?? '';
        }
        if (senderKey.isEmpty) {
          try {
            final ep = EncryptedPayload.deserialize(raw.text);
            senderKey = ep.senderPublicKey;
          } catch (_) {}
        }
        final cleartext = await enc.decryptPayload(raw.text, senderKey);
        debugPrint('DECRYPT: messageId=${envelope.id}, status=success, sender=${raw.senderId}');
        try {
          final decoded = jsonDecode(cleartext);
          if (decoded is Map<String, dynamic> && decoded.containsKey('mediaAttachment')) {
            final mediaMap = decoded['mediaAttachment'] as Map<String, dynamic>;
            var att = MediaAttachment.fromJson(mediaMap);
            final text = decoded['text'] as String? ?? '';

            final relay = _mediaRelayService;
            final storage = _mediaStorageService;
            if (att.remoteUrl != null && relay != null) {
              try {
                final blob = await relay.downloadEncryptedBlob(att.remoteUrl!);
                if (storage != null) {
                  final localPath = await storage.saveToSandbox(
                    fileName: att.fileName,
                    bytes: blob,
                    type: att.type,
                  );
                  att = att.copyWith(localPath: localPath);
                }
                await relay.purgeEncryptedBlob(att.remoteUrl!);
              } catch (_) {}
            }

            decryptedMessage = raw.copyWith(
              text: text,
              type: att.type,
              mediaAttachment: att,
            );
          } else {
            decryptedMessage = raw.copyWith(text: cleartext);
          }
        } catch (_) {
          decryptedMessage = raw.copyWith(text: cleartext);
        }
      } catch (e) {
        debugPrint('DECRYPT: messageId=${envelope.id}, status=failure, error=$e');
        decryptFailed = true;
      }
    }

    if (decryptFailed) {
      final failures = (_decryptFailures[envelope.id] ?? 0) + 1;
      _decryptFailures[envelope.id] = failures;
      if (failures >= 3) {
        // Quarantine after 3 failures on same message: save as undecryptable and ACK to unblock queue
        final quarantined = raw.copyWith(
          text: '[Undecryptable Message]',
          type: MessageType.system,
        );
        await _database.saveMessage(quarantined);
        await ackEnvelope();
        if (AppConstants.enableDebugLogs) {
          debugPrint('RECV: pushId=${envelope.id}, decrypted=false, ack=true (quarantined after 3 attempts)');
        }
        return quarantined;
      }
      return null;
    }

    _decryptFailures.remove(envelope.id);

    // Persist cleartext locally (local device owns history)
    await _database.saveMessage(decryptedMessage);
    debugPrint('DB INSERT: messageId=${decryptedMessage.id}, status=saved_to_sqlite, sender=${decryptedMessage.senderId}');

    // Notify user locally using privacy-preserving settings (zero leak)
    await _notificationService?.showLocalAlert(
      title: decryptedMessage.senderId,
      body: decryptedMessage.mediaAttachment != null
          ? (decryptedMessage.mediaAttachment!.isImage
              ? '📷 Photo'
              : decryptedMessage.mediaAttachment!.isAudio
                  ? '🎙️ Voice note'
                  : '🎥 Video')
          : decryptedMessage.text,
      conversationId: decryptedMessage.senderId,
    );

    // Atomic ACK: call .remove() ONLY AFTER local insert succeeds
    await ackEnvelope();
    if (AppConstants.enableDebugLogs) {
      debugPrint('RECV: pushId=${envelope.id}, decrypted=true, ack=true');
    }

    // Dispatch ephemeral delivery receipt back to original sender
    await sendDeliveryReceipt(
      messageId: envelope.id,
      recipientId: envelope.senderId,
      senderId: currentUserId,
    );

    return decryptedMessage;
  }

  @override
  Future<List<ChatMessage>> processInboundEnvelopes({required String currentUserId}) async {
    if (!_isOnline) return const [];

    final envelopes = await _chatService.fetchPendingRelayEnvelopes(currentUserId);
    final processedMessages = <ChatMessage>[];

    for (final envelope in envelopes) {
      final msg = await _processSingleEnvelope(envelope, currentUserId: currentUserId);
      if (msg != null) {
        processedMessages.add(msg);
      }
    }

    if (processedMessages.isNotEmpty) {
      try {
        LocalConversationRepository.instance
            .refreshConversations(currentUserId: currentUserId);
      } catch (_) {}
    }

    return processedMessages;
  }

  @override
  Future<void> sendDeliveryReceipt({
    required String messageId,
    required String recipientId,
    required String senderId,
  }) async {
    final receipt = EphemeralRelayEnvelope.deliveryReceipt(
      messageId: messageId,
      senderId: senderId,
      recipientId: recipientId,
    );
    await _chatService.sendEphemeralEnvelope(receipt);
  }

  @override
  Future<void> sendReadReceipt({
    required String messageId,
    required String recipientId,
    required String senderId,
  }) async {
    final receipt = EphemeralRelayEnvelope.readReceipt(
      messageId: messageId,
      senderId: senderId,
      recipientId: recipientId,
    );
    await _chatService.sendEphemeralEnvelope(receipt);
  }

  @override
  Future<void> reconcile({required String currentUserId}) async {
    if (!_isOnline) return;

    // 1. Process all pending inbound messages and receipts
    await processInboundEnvelopes(currentUserId: currentUserId);

    // 2. Flush any pending outbound messages queued while offline
    await flushOutboundQueue(currentUserId: currentUserId);
  }

  @override
  Future<bool> retryMessage(String messageId, {required String currentUserId}) async {
    final message = await _database.getMessageById(messageId);
    if (message == null) return false;

    // Reset status to sending before attempt
    await _database.updateMessageStatus(messageId, MessageStatus.sending);
    return await _dispatchOutboundMessage(message);
  }

  @override
  Future<int> markConversationAsRead(
    String partnerId, {
    required String currentUserId,
  }) async {
    final unreadMessages = await _database.getMessagesForPartner(
      partnerId,
      currentUserId: currentUserId,
    );

    // Update local database
    final count = await _database.markConversationAsRead(
      partnerId,
      currentUserId: currentUserId,
    );

    // Send read receipts for incoming messages that weren't already read
    for (final msg in unreadMessages) {
      if (msg.senderId == partnerId && msg.status != MessageStatus.read) {
        await sendReadReceipt(
          messageId: msg.id,
          recipientId: partnerId,
          senderId: currentUserId,
        );
      }
    }

    return count;
  }
}

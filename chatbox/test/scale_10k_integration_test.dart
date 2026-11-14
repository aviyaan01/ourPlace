import 'dart:convert';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chatbox/database/app_database.dart';
import 'package:chatbox/core/utils/hash_utils.dart';
import 'package:chatbox/database/local_database.dart';
import 'package:chatbox/models/ephemeral_relay_envelope.dart';
import 'package:chatbox/models/message.dart';
import 'package:chatbox/models/user_account.dart';
import 'package:chatbox/services/auth_service.dart';
import 'package:chatbox/services/chat_service.dart';
import 'package:chatbox/services/encryption_service.dart';
import 'package:chatbox/services/relay_service.dart';
import 'package:chatbox/services/sync_service.dart';
import 'package:chatbox/services/user_directory_service.dart';

void main() {
  group('10k Scale & Architecture Integration Tests', () {
    late AppDatabase appDb;
    late LocalDatabase db;
    late StandardE2EEEncryptionService encryption;
    late InMemoryUserDirectoryService directory;
    late InMemoryFirebaseRelayService relay;

    setUp(() {
      appDb = AppDatabase(NativeDatabase.memory());
      db = LocalDatabase(database: appDb);
      encryption = StandardE2EEEncryptionService();
      directory = InMemoryUserDirectoryService();
      relay = InMemoryFirebaseRelayService.isolated();
    });

    tearDown(() async {
      await appDb.close();
      relay.dispose();
    });

    test('Phase A: Zero-PII Synthetic Email generation maps @username cleanly', () {
      final email1 = LocalAuthService.toSyntheticEmail('@alex');
      expect(email1, equals('alex@nest.invalid'));

      final email2 = LocalAuthService.toSyntheticEmail('twilight');
      expect(email2, equals('twilight@nest.invalid'));

      final email3 = LocalAuthService.toSyntheticEmail('  @Sarah_Connor  ');
      expect(email3, equals('sarah_connor@nest.invalid'));

      // Ensure zero PII: domain is always nest.invalid and never real email
      expect(email1.endsWith('@nest.invalid'), isTrue);
    });

    test('Phase B: Username normalization strictly allows [a-z0-9_] and trims whitespace/@', () {
      expect(HashUtils.rawUsername('@Alex_123'), equals('alex_123'));
      expect(HashUtils.normalizeUsername('  @Twilight_Sparkle  '), equals('@twilight_sparkle'));
      expect(HashUtils.rawUsername('@user!#\$%test'), equals('usertest'));
      expect(HashUtils.normalizeUsername('@bob'), equals('@bob'));
    });

    test('Phase B: User Directory Prefix Search requires >= 3 chars and matches prefixes', () async {
      await directory.publishProfile(
        DirectoryProfile(
          accountId: 'uid_alexander',
          username: '@alexander',
          publicIdentityKey: 'key_alexander',
          lastSeen: DateTime.now(),
        ),
      );
      await directory.publishProfile(
        DirectoryProfile(
          accountId: 'uid_alex',
          username: '@alex',
          publicIdentityKey: 'key_alex',
          lastSeen: DateTime.now(),
        ),
      );
      await directory.publishProfile(
        DirectoryProfile(
          accountId: 'uid_bob',
          username: '@bob',
          publicIdentityKey: 'key_bob',
          lastSeen: DateTime.now(),
        ),
      );

      // Short queries (< 3 chars) return empty to protect network
      final shortResults = await directory.searchUsers('al');
      expect(shortResults, isEmpty);

      // Prefix query 'ale' returns both alex and alexander
      final aleResults = await directory.searchUsers('ale');
      expect(aleResults.length, equals(2));
      final handles = aleResults.map((p) => p.username).toList();
      expect(handles, containsAll(['@alex', '@alexander']));

      // Non-matching query
      final emptyResults = await directory.searchUsers('charlie');
      expect(emptyResults, isEmpty);
    });

    test('Phase B: MITM Key Change Detection compares known local key with directory', () async {
      const originalKey = 'original_valid_public_key_32bytes';
      const tamperedKey = 'tampered_mitm_public_key_32bytes';

      // Save known trusted contact in local database
      await db.saveAccount(
        UserAccount.create(
          accountId: 'acc_partner',
          username: '@partner',
          plaintextPassword: 'password123',
          publicIdentityKey: originalKey,
        ),
      );

      // Check known account
      final localAcc = await db.getAccountByUsername('@partner');
      expect(localAcc, isNotNull);
      expect(localAcc!.publicIdentityKey, equals(originalKey));

      // 1. Directory has matching key -> Verified
      final directoryProfileVerified = DirectoryProfile(
        accountId: 'acc_partner',
        username: '@partner',
        publicIdentityKey: originalKey,
        lastSeen: DateTime.now(),
      );
      final isKeyChangedVerified = localAcc.publicIdentityKey != null &&
          localAcc.publicIdentityKey != directoryProfileVerified.publicIdentityKey;
      expect(isKeyChangedVerified, isFalse);

      // 2. Directory has different key -> Potential MITM Alert
      final directoryProfileTampered = DirectoryProfile(
        accountId: 'acc_partner',
        username: '@partner',
        publicIdentityKey: tamperedKey,
        lastSeen: DateTime.now(),
      );
      final isKeyChangedTampered = localAcc.publicIdentityKey != null &&
          localAcc.publicIdentityKey != directoryProfileTampered.publicIdentityKey;
      expect(isKeyChangedTampered, isTrue);
    });

    test('Phase C: E2EE Enveloping, SQLite Ingestion & Atomic Delivery ACK Purge', () async {
      await encryption.initializeUserKeys('acc_alice');
      final alicePub = await encryption.getPublicIdentityKey();

      final bobEncryption = StandardE2EEEncryptionService();
      await bobEncryption.initializeUserKeys('acc_bob');
      final bobPub = await bobEncryption.getPublicIdentityKey();

      // Alice encrypts payload for Bob
      final payload = jsonEncode({'text': 'Hello Bob via 10k pipeline'});
      final ciphertext = await encryption.encryptPayload(payload, bobPub);

      // Envelope dispatched
      final envelope = EphemeralRelayEnvelope.create(
        id: 'msg_scale_001',
        senderId: '@alice',
        recipientId: '@bob',
        ciphertextPayload: ciphertext,
      );

      await relay.enqueueMessage(envelope);

      // Verify envelope is in Bob's pending queue
      final pendingBefore = await relay.fetchPendingMessages('@bob');
      expect(pendingBefore.length, equals(1));
      expect(pendingBefore.first.id, equals('msg_scale_001'));

      // Bob decrypts
      final decryptedCleartext = await bobEncryption.decryptPayload(
        pendingBefore.first.ciphertextPayload,
        alicePub,
      );
      final decoded = jsonDecode(decryptedCleartext);
      expect(decoded['text'], equals('Hello Bob via 10k pipeline'));

      // Bob saves to SQLite
      final chatMessage = ChatMessage(
        id: envelope.id,
        senderId: envelope.senderId,
        recipientId: envelope.recipientId,
        text: decoded['text'],
        timestamp: envelope.timestamp,
        status: MessageStatus.delivered,
      );
      await db.saveMessage(chatMessage);

      // Atomic ACK: remove from relay
      final acked = await relay.acknowledgeAndPurge('msg_scale_001', recipientId: '@bob');
      expect(acked, isTrue);

      // Verify envelope is permanently deleted from remote relay
      final pendingAfter = await relay.fetchPendingMessages('@bob');
      expect(pendingAfter, isEmpty);

      // Verify message is saved locally
      final savedMessages = await db.getMessagesForPartner('@alice', currentUserId: '@bob');
      expect(savedMessages.length, equals(1));
      expect(savedMessages.first.text, equals('Hello Bob via 10k pipeline'));
    });

    test('Phase C: Undecryptable Message Quarantine preserves pipeline after 3 failures', () async {
      final syncService = DefaultSyncService(
        database: db,
        encryptionService: encryption,
        chatService: ChatService(relayService: relay),
      );

      // Envelope with corrupt/undecryptable ciphertext
      final corruptEnvelope = EphemeralRelayEnvelope.create(
        id: 'corrupt_001',
        senderId: '@malicious',
        recipientId: '@alice',
        ciphertextPayload: 'NOT_VALID_CIPHERTEXT',
      );

      await relay.enqueueMessage(corruptEnvelope);

      // Attempt 1: failure -> kept in queue, not saved yet
      final batch1 = await syncService.processInboundEnvelopes(currentUserId: '@alice');
      expect(batch1, isEmpty);
      expect((await relay.fetchPendingMessages('@alice')).length, equals(1));

      // Attempt 2: failure -> kept in queue
      final batch2 = await syncService.processInboundEnvelopes(currentUserId: '@alice');
      expect(batch2, isEmpty);
      expect((await relay.fetchPendingMessages('@alice')).length, equals(1));

      // Attempt 3: 3rd failure -> quarantined, stored as undecryptable in SQLite, and ACK-purged
      final batch3 = await syncService.processInboundEnvelopes(currentUserId: '@alice');
      expect(batch3.length, equals(1));
      expect(batch3.first.text, equals('[Undecryptable Message]'));
      expect(batch3.first.type, equals(MessageType.system));

      // Queue is unblocked and envelope purged from relay
      expect((await relay.fetchPendingMessages('@alice')), isEmpty);
    });

    test('Phase C: Message pagination defaults to 50 messages ordered newest first', () async {
      // Insert 75 messages
      final baseTime = DateTime.now().subtract(const Duration(hours: 100));
      for (int i = 0; i < 75; i++) {
        await db.saveMessage(
          ChatMessage(
            id: 'page_msg_$i',
            senderId: '@bob',
            recipientId: '@alice',
            text: 'Message #$i',
            timestamp: baseTime.add(Duration(minutes: i)),
            status: MessageStatus.delivered,
          ),
        );
      }

      // Default page: 50 messages
      final page1 = await db.getMessagesForPartner('@bob', currentUserId: '@alice');
      expect(page1.length, equals(50));
      // Newest message first (#74)
      expect(page1.first.id, equals('page_msg_74'));

      // Next page with offset 50
      final page2 = await db.getMessagesForPartner(
        '@bob',
        currentUserId: '@alice',
        limit: 50,
        offset: 50,
      );
      expect(page2.length, equals(25));
      expect(page2.first.id, equals('page_msg_24'));
      expect(page2.last.id, equals('page_msg_0'));
    });
  });
}

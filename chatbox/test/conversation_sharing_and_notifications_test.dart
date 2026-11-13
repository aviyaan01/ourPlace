import 'package:chatbox/database/app_database.dart';
import 'package:chatbox/database/local_database.dart';
import 'package:chatbox/models/love_connection.dart';
import 'package:chatbox/models/message.dart';
import 'package:chatbox/models/shared_conversation_bundle.dart';
import 'package:chatbox/services/conversation_sharing_service.dart';
import 'package:chatbox/services/love_connection_service.dart';
import 'package:chatbox/services/notification_service.dart';
import 'package:chatbox/services/relay_service.dart';
import 'package:drift/native.dart';
import 'package:firebase_messaging/firebase_messaging.dart' hide NotificationSettings;
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Imported Shared Conversation Visibility Tests', () {
    late AppDatabase driftDb;
    late LocalDatabase localDb;
    late InMemoryFirebaseRelayService relay;
    late InMemoryLoveConnectionService loveConnService;
    late DefaultConversationSharingService sharingService;

    setUp(() async {
      driftDb = AppDatabase(NativeDatabase.memory());
      localDb = LocalDatabase(database: driftDb);
      await localDb.initialize();
      relay = InMemoryFirebaseRelayService.isolated();
      loveConnService = InMemoryLoveConnectionService();

      sharingService = DefaultConversationSharingService(
        relayService: relay,
        localDatabase: localDb,
        loveConnectionService: loveConnService,
      );

      // Establish verified Love Connection between Alex and Twilight
      loveConnService.setMockConnection(
        LoveConnection(
          id: 'conn_test',
          userId: 'alex_id',
          partnerUsername: '@twilight',
          partnerUserId: 'twilight_id',
          status: LoveConnectionStatus.connected,
          createdAt: DateTime.now().toUtc(),
          connectedAt: DateTime.now().toUtc(),
        ),
      );
    });

    tearDown(() async {
      sharingService.dispose();
      relay.dispose();
      await driftDb.close();
    });

    test('Imported conversation with partner Charlie (@sarah) is visible to recipient Twilight (twilight_id)', () async {
      // 1. Alex has messages with partner @sarah
      final msg1 = ChatMessage(
        id: 'msg_shared_1',
        senderId: 'alex_id',
        recipientId: '@sarah',
        text: 'Hey Sarah, here is the secret project briefing',
        timestamp: DateTime.now().subtract(const Duration(minutes: 5)),
        status: MessageStatus.delivered,
      );
      final msg2 = ChatMessage(
        id: 'msg_shared_2',
        senderId: '@sarah',
        recipientId: 'alex_id',
        text: 'Understood Alex, reviewing it now',
        timestamp: DateTime.now().subtract(const Duration(minutes: 2)),
        status: MessageStatus.delivered,
      );

      // 2. Package into a SharedConversationBundle
      final bundle = SharedConversationBundle.create(
        shareId: 'share_bundle_99',
        senderUsername: '@alex',
        conversationPartner: '@sarah',
        messages: [msg1, msg2],
      );

      // 3. Twilight imports the shared conversation
      final importedCount = await sharingService.importSharedConversation(
        bundle: bundle,
        currentUserId: 'twilight_id',
      );
      expect(importedCount, equals(2));

      // 4. Twilight queries messages for @sarah
      final sarahMessages = await localDb.getMessagesForPartner(
        '@sarah',
        currentUserId: 'twilight_id',
      );
      expect(sarahMessages.length, equals(2));
      expect(sarahMessages.map((m) => m.id), containsAll(['msg_shared_1', 'msg_shared_2']));

      // 5. Reactive watchMessagesForPartner emits the imported messages
      final streamMessages = await localDb.watchMessagesForPartner(
        '@sarah',
        currentUserId: 'twilight_id',
      ).first;
      expect(streamMessages.length, equals(2));

      // 6. Inbox distinct chat partners includes @sarah
      final distinctPartners = await localDb.getDistinctChatPartners(
        currentUserId: 'twilight_id',
      );
      expect(distinctPartners, contains('@sarah'));
      // Ensure Twilight herself is not returned as a chat partner
      expect(distinctPartners, isNot(contains('twilight_id')));
      expect(distinctPartners, isNot(contains('@twilight')));

      // 7. Latest message for @sarah resolves to the newest message
      final latest = await localDb.getLatestMessageForPartner(
        '@sarah',
        currentUserId: 'twilight_id',
      );
      expect(latest, isNotNull);
      expect(latest!.id, equals('msg_shared_2'));

      // 8. Search messages finds text within the imported messages
      final searchResults = await localDb.searchMessages(
        partnerId: '@sarah',
        query: 'secret project',
        currentUserId: 'twilight_id',
      );
      expect(searchResults.length, equals(1));
      expect(searchResults.first.id, equals('msg_shared_1'));

      // 9. Message count for @sarah matches imported count
      final count = await localDb.getMessageCountForPartner(
        '@sarah',
        currentUserId: 'twilight_id',
      );
      expect(count, equals(2));

      // 10. Mark conversation as read updates status
      final updatedRows = await localDb.markConversationAsRead(
        '@sarah',
        currentUserId: 'twilight_id',
      );
      expect(updatedRows, greaterThanOrEqualTo(1));

      // 11. Clear messages for partner removes them cleanly
      await localDb.clearMessagesForPartner(
        '@sarah',
        currentUserId: 'twilight_id',
      );
      final remaining = await localDb.getMessagesForPartner(
        '@sarah',
        currentUserId: 'twilight_id',
      );
      expect(remaining, isEmpty);
    });

    test('importSharedConversation normalizes generic current_user to exporter username', () async {
      // Alex exported a message that used the generic 'current_user' sender ID
      final genericMsg = ChatMessage(
        id: 'msg_generic_alex',
        senderId: 'current_user',
        recipientId: '@sarah',
        text: 'Message sent from Alex device with current_user tag',
        timestamp: DateTime.now(),
      );

      final bundle = SharedConversationBundle.create(
        shareId: 'share_bundle_norm',
        senderUsername: '@alex',
        conversationPartner: '@sarah',
        messages: [genericMsg],
      );

      // Ingest into Twilight storage
      await sharingService.importSharedConversation(
        bundle: bundle,
        currentUserId: 'twilight_id',
      );

      // Retrieve message from SQLite
      final retrieved = await localDb.getMessageById('msg_generic_alex');
      expect(retrieved, isNotNull);
      // Sender should be normalized to Alex, NOT left as current_user (which would be Twilight)
      expect(retrieved!.senderId, equals('@alex'));
      expect(retrieved.recipientId, equals('@sarah'));
    });
  });

  group('OS-Level Tray Alerts & Background Notification Handler Tests', () {
    test('DefaultNotificationService handles local alerts and emits onNotificationDisplayed', () async {
      final notifService = DefaultNotificationService();
      notifService.clearLogs();

      final displayedFuture = notifService.onNotificationDisplayed.first;

      await notifService.showLocalAlert(
        title: 'Secret Message',
        body: 'Hello Twilight',
        conversationId: '@alex',
        isDiscreet: false,
      );

      final event = await displayedFuture;
      expect(event['title'], equals('Secret Message'));
      expect(event['body'], equals('Hello Twilight'));
      expect(event['conversationId'], equals('@alex'));
      expect(notifService.displayedAlerts.length, equals(1));
    });

    test('firebaseMessagingBackgroundHandler executes without unhandled exceptions for wakeup signal', () async {
      final message = RemoteMessage(
        messageId: 'fcm_msg_1001',
        data: {
          'type': 'wakeup',
          'senderId': '@alex',
          'conversationId': '@alex',
        },
      );

      // Should execute cleanly and show OS tray notification safely
      expect(
        () async => await firebaseMessagingBackgroundHandler(message),
        returnsNormally,
      );
    });

    test('firebaseMessagingBackgroundHandler executes without unhandled exceptions for explicit title/body', () async {
      final message = RemoteMessage(
        messageId: 'fcm_msg_1002',
        data: {
          'title': 'New Message',
          'body': 'Encrypted content ready for sync',
          'senderId': '@sarah',
        },
      );

      expect(
        () async => await firebaseMessagingBackgroundHandler(message),
        returnsNormally,
      );
    });
  });
}

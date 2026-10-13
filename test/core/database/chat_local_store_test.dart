import 'dart:io';

import 'package:appchatdemo/core/database/chat_local_store.dart';
import 'package:appchatdemo/features/chat/domain/entities/chat_message.dart';
import 'package:appchatdemo/features/conversations/domain/entities/conversation.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

ChatMessage _message({
  required String id,
  required String clientMessageId,
  String conversationId = 'conversation',
  String senderId = 'alice',
  int sequence = 0,
  MessageStatus status = MessageStatus.sending,
}) => ChatMessage(
  id: id,
  clientMessageId: clientMessageId,
  conversationId: conversationId,
  senderId: senderId,
  text: 'Message $id',
  sequence: sequence,
  createdAt: DateTime.utc(2026, 10, 13, 12, 0, sequence),
  status: status,
);

// The shipped v2 schema used account-wide client IDs. This fixture verifies
// that upgrading keeps existing messages and queued sends.
class _LegacyChatStore extends GeneratedDatabase {
  _LegacyChatStore(super.executor);

  @override
  int get schemaVersion => 2;

  @override
  Iterable<TableInfo> get allTables => const [];

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.database.customStatement('''
      CREATE TABLE messages (
        account_id TEXT NOT NULL, id TEXT NOT NULL,
        client_message_id TEXT NOT NULL, conversation_id TEXT NOT NULL,
        sender_id TEXT NOT NULL, body TEXT NOT NULL,
        sequence INTEGER NOT NULL, created_at_ms INTEGER NOT NULL,
        status TEXT NOT NULL, PRIMARY KEY (account_id, id),
        UNIQUE (account_id, client_message_id)
      )
    ''');
      await m.database.customStatement('''
      CREATE INDEX messages_by_conversation
      ON messages (account_id, conversation_id, sequence DESC, created_at_ms DESC)
    ''');
      await m.database.customStatement('''
      CREATE TABLE outbox (
        account_id TEXT NOT NULL, client_message_id TEXT NOT NULL,
        queued_at_ms INTEGER NOT NULL,
        PRIMARY KEY (account_id, client_message_id)
      )
    ''');
      await m.database.customStatement('''
      CREATE INDEX outbox_by_queue
      ON outbox (account_id, queued_at_ms, client_message_id)
    ''');
      await m.database.customStatement('''
      CREATE TABLE conversations (
        account_id TEXT NOT NULL, id TEXT NOT NULL, title TEXT NOT NULL,
        peer_id TEXT NOT NULL, avatar_url TEXT, is_group INTEGER NOT NULL,
        unread_count INTEGER NOT NULL, is_pinned INTEGER NOT NULL,
        is_muted INTEGER NOT NULL, last_message_preview TEXT,
        last_message_at_ms INTEGER, last_read_sequence INTEGER NOT NULL,
        peer_last_read_sequence INTEGER NOT NULL,
        PRIMARY KEY (account_id, id)
      )
    ''');
    },
  );
}

void main() {
  test(
    'outbox survives restart and acknowledgement removes the local echo',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'chat-store-test-',
      );
      final file = File('${directory.path}/messages.sqlite');
      try {
        final first = ChatLocalStore(executor: NativeDatabase(file));
        await first.enqueueOutgoing(
          'alice',
          _message(id: 'local-1', clientMessageId: 'client-1'),
        );
        await first.markFailed('alice', 'conversation', 'client-1');
        await first.upsertConversation(
          'alice',
          Conversation(
            id: 'conversation',
            title: 'Bob',
            peerId: 'bob',
            unreadCount: 2,
            isOnline: true,
            isTyping: true,
            lastMessageAt: DateTime.utc(2026, 10, 13, 12),
          ),
        );
        await first.close();

        final reopened = ChatLocalStore(executor: NativeDatabase(file));
        try {
          expect(
            (await reopened.loadPending('alice')).single.status,
            MessageStatus.failed,
          );
          expect(await reopened.loadPending('bob'), isEmpty);
          expect(
            (await reopened.loadMessages('alice', 'conversation')).single.id,
            'local-1',
          );
          final conversations = await reopened.loadConversations('alice');
          expect(conversations.single.title, 'Bob');
          expect(conversations.single.unreadCount, 2);
          expect(conversations.single.isOnline, isNull);
          expect(conversations.single.isTyping, isFalse);

          await reopened.enqueueOutgoing(
            'alice',
            _message(id: 'local-1', clientMessageId: 'client-1'),
          );
          expect(
            (await reopened.loadPending('alice')).single.status,
            MessageStatus.sending,
          );

          await reopened.markSent(
            'alice',
            'client-1',
            _message(
              id: 'server-1',
              clientMessageId: 'client-1',
              sequence: 12,
              status: MessageStatus.sent,
            ),
          );
          expect(await reopened.loadPending('alice'), isEmpty);
          final cached = await reopened.loadMessages('alice', 'conversation');
          expect(cached, hasLength(1));
          expect(cached.single.id, 'server-1');
          expect(cached.single.sequence, 12);

          await reopened.enqueueOutgoing(
            'alice',
            _message(id: 'local-1', clientMessageId: 'client-1'),
          );
          expect(await reopened.loadPending('alice'), isEmpty);
          expect(
            (await reopened.loadMessages('alice', 'conversation')).single.id,
            'server-1',
          );

          await reopened.upsertMessage(
            'alice',
            _message(
              id: 'server-1',
              clientMessageId: 'client-1',
              sequence: 12,
              status: MessageStatus.read,
            ),
          );
          await reopened.upsertMessage(
            'alice',
            _message(
              id: 'server-1',
              clientMessageId: 'client-1',
              sequence: 12,
              status: MessageStatus.sent,
            ),
          );
          expect(
            (await reopened.loadMessages(
              'alice',
              'conversation',
            )).single.status,
            MessageStatus.read,
          );
        } finally {
          await reopened.close();
        }
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'paginates confirmed messages and keeps pending messages visible',
    () async {
      final store = ChatLocalStore(executor: NativeDatabase.memory());
      try {
        await store.upsertMessages('alice', [
          for (var sequence = 1; sequence <= 4; sequence++)
            _message(
              id: 'server-$sequence',
              clientMessageId: 'client-$sequence',
              sequence: sequence,
              status: MessageStatus.sent,
            ),
        ]);
        await store.enqueueOutgoing(
          'alice',
          _message(id: 'local-5', clientMessageId: 'client-5'),
        );
        await store.upsertMessage(
          'bob',
          _message(
            id: 'bob-message',
            clientMessageId: 'bob-client',
            sequence: 1,
            status: MessageStatus.sent,
          ),
        );
        await store.upsertConversations('alice', [
          const Conversation(id: 'older', title: 'Older', peerId: 'older'),
          const Conversation(
            id: 'pinned',
            title: 'Pinned',
            peerId: 'pinned',
            isPinned: true,
          ),
        ]);
        await store.upsertConversation(
          'bob',
          const Conversation(
            id: 'bob-conversation',
            title: 'Alice',
            peerId: 'alice',
          ),
        );

        expect(
          (await store.loadConversations('alice')).map((item) => item.id),
          ['pinned', 'older'],
        );

        expect(
          (await store.loadMessages(
            'alice',
            'conversation',
            limit: 3,
          )).map((message) => message.sequence),
          [3, 4, 0],
        );
        expect(
          (await store.loadMessages(
            'alice',
            'conversation',
            beforeSequence: 3,
          )).map((message) => message.sequence),
          [1, 2],
        );
        expect(await store.loadMessages('bob', 'conversation'), hasLength(1));

        await store.clearAccount('alice');
        expect(await store.loadPending('alice'), isEmpty);
        expect(await store.loadMessages('alice', 'conversation'), isEmpty);
        expect(await store.loadConversations('alice'), isEmpty);
        expect(await store.loadMessages('bob', 'conversation'), hasLength(1));
        expect(await store.loadConversations('bob'), hasLength(1));
      } finally {
        await store.close();
      }
    },
  );

  test(
    'same client ID in other conversations or from peers stays isolated',
    () async {
      final store = ChatLocalStore(executor: NativeDatabase.memory());
      try {
        await store.enqueueOutgoing(
          'alice',
          _message(
            id: 'shared-id',
            clientMessageId: 'shared-client',
            conversationId: 'first',
          ),
        );
        await store.enqueueOutgoing(
          'alice',
          _message(
            id: 'shared-id',
            clientMessageId: 'shared-client',
            conversationId: 'second',
          ),
        );
        await store.upsertMessage(
          'alice',
          _message(
            id: 'shared-id',
            clientMessageId: 'shared-client',
            conversationId: 'first',
            senderId: 'bob',
            sequence: 5,
            status: MessageStatus.sent,
          ),
        );

        expect(await store.loadPending('alice'), hasLength(2));
        expect(await store.loadMessages('alice', 'first'), hasLength(2));
        expect(await store.loadMessages('alice', 'second'), hasLength(1));

        await store.markFailed('alice', 'first', 'shared-client');
        expect(
          (await store.loadMessages(
            'alice',
            'first',
          )).where((message) => message.senderId == 'alice').single.status,
          MessageStatus.failed,
        );
        expect(
          (await store.loadMessages('alice', 'second')).single.status,
          MessageStatus.sending,
        );
        expect(
          (await store.loadMessages(
            'alice',
            'first',
          )).where((message) => message.senderId == 'bob').single.status,
          MessageStatus.sent,
        );

        await store.markSent(
          'alice',
          'shared-client',
          _message(
            id: 'server-first',
            clientMessageId: 'shared-client',
            conversationId: 'first',
            sequence: 6,
            status: MessageStatus.sent,
          ),
        );
        expect(
          (await store.loadPending('alice')).single.conversationId,
          'second',
        );
        expect(
          (await store.loadMessages(
            'alice',
            'first',
          )).where((message) => message.senderId == 'bob').single.id,
          'shared-id',
        );

        await store.removePending('alice', 'second', 'shared-client');
        expect(await store.loadPending('alice'), isEmpty);
        expect(await store.loadMessages('alice', 'second'), isEmpty);
        expect(await store.loadMessages('alice', 'first'), hasLength(2));
      } finally {
        await store.close();
      }
    },
  );

  test('upgrades v2 cache without losing messages or queued sends', () async {
    final directory = await Directory.systemTemp.createTemp('chat-v2-test-');
    final file = File('${directory.path}/messages.sqlite');
    try {
      final legacy = _LegacyChatStore(NativeDatabase(file));
      await legacy.customStatement('''
        INSERT INTO messages
          (account_id, id, client_message_id, conversation_id, sender_id,
           body, sequence, created_at_ms, status)
        VALUES ('alice', 'local-1', 'shared-client', 'first', 'alice',
                'Hello', 0, 1791892800000, 'failed')
      ''');
      await legacy.customStatement('''
        INSERT INTO outbox (account_id, client_message_id, queued_at_ms)
        VALUES ('alice', 'shared-client', 1791892800000)
      ''');
      await legacy.close();

      final upgraded = ChatLocalStore(executor: NativeDatabase(file));
      try {
        expect((await upgraded.loadPending('alice')).single.id, 'local-1');
        expect(
          (await upgraded.loadMessages('alice', 'first')).single.status,
          MessageStatus.failed,
        );
        await upgraded.enqueueOutgoing(
          'alice',
          _message(
            id: 'local-1',
            clientMessageId: 'shared-client',
            conversationId: 'second',
          ),
        );
        expect(await upgraded.loadPending('alice'), hasLength(2));
      } finally {
        await upgraded.close();
      }
    } finally {
      await directory.delete(recursive: true);
    }
  });
}

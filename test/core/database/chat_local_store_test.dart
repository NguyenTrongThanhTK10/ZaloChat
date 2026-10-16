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

class _LegacyV3ChatStore extends GeneratedDatabase {
  _LegacyV3ChatStore(super.executor);

  @override
  int get schemaVersion => 3;

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
        status TEXT NOT NULL,
        PRIMARY KEY (account_id, conversation_id, sender_id, id),
        UNIQUE (account_id, conversation_id, sender_id, client_message_id)
      )
    ''');
      await m.database.customStatement('''
        CREATE TABLE outbox (
          account_id TEXT NOT NULL, conversation_id TEXT NOT NULL,
          sender_id TEXT NOT NULL, client_message_id TEXT NOT NULL,
          queued_at_ms INTEGER NOT NULL,
          PRIMARY KEY (account_id, conversation_id, sender_id, client_message_id)
        )
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
  test('attachment metadata survives restart and recall clears it', () async {
    final directory = await Directory.systemTemp.createTemp(
      'chat-attachment-test-',
    );
    final file = File('${directory.path}/messages.sqlite');
    try {
      final first = ChatLocalStore(executor: NativeDatabase(file));
      await first.upsertMessage(
        'alice',
        ChatMessage(
          id: 'attachment',
          clientMessageId: 'attachment-client',
          conversationId: 'conversation',
          senderId: 'bob',
          text: 'Ảnh hôm nay',
          sequence: 1,
          kind: MessageKind.image,
          createdAt: DateTime.utc(2026, 10, 16),
          status: MessageStatus.sent,
          attachment: const MessageAttachment(
            name: 'photo.png',
            size: 2048,
            contentType: 'image/png',
          ),
        ),
      );
      await first.close();
      final reopened = ChatLocalStore(executor: NativeDatabase(file));
      try {
        final image = (await reopened.loadMessages(
          'alice',
          'conversation',
        )).single;
        expect(image.kind, MessageKind.image);
        expect(image.attachment?.toJson(), {
          'name': 'photo.png',
          'size': 2048,
          'contentType': 'image/png',
        });
        await reopened.upsertMessage(
          'alice',
          ChatMessage(
            id: image.id,
            clientMessageId: image.clientMessageId,
            conversationId: image.conversationId,
            senderId: image.senderId,
            text: '',
            sequence: image.sequence,
            kind: image.kind,
            createdAt: image.createdAt,
            status: image.status,
            isRecalled: true,
          ),
        );
        final recalled = (await reopened.loadMessages(
          'alice',
          'conversation',
        )).single;
        expect(recalled.isRecalled, isTrue);
        expect(recalled.attachment, isNull);
      } finally {
        await reopened.close();
      }
    } finally {
      await directory.delete(recursive: true);
    }
  });
  test(
    'v5 cache upgrades and preserves queued replies after restart',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'chat-reply-test-',
      );
      final file = File('${directory.path}/messages.sqlite');
      try {
        final legacy = _LegacyV3ChatStore(NativeDatabase(file));
        await legacy.customStatement(
          "ALTER TABLE messages ADD COLUMN hearted_by_json TEXT NOT NULL DEFAULT '[]'",
        );
        await legacy.customStatement(
          "ALTER TABLE messages ADD COLUMN kind TEXT NOT NULL DEFAULT 'text'",
        );
        await legacy.customStatement(
          'ALTER TABLE messages ADD COLUMN voice_duration_ms INTEGER',
        );
        await legacy.customStatement('PRAGMA user_version = 5');
        await legacy.close();
        final upgraded = ChatLocalStore(executor: NativeDatabase(file));
        await upgraded.enqueueOutgoing(
          'alice',
          ChatMessage(
            id: 'reply-local',
            clientMessageId: 'reply-local',
            conversationId: 'conversation',
            senderId: 'alice',
            text: 'Trả lời',
            sequence: 0,
            createdAt: DateTime.utc(2026, 10, 14),
            status: MessageStatus.sending,
            replyTo: const MessageReply(
              id: 'original',
              senderId: 'bob',
              text: '',
              kind: MessageKind.voice,
            ),
          ),
        );
        await upgraded.close();
        final reopened = ChatLocalStore(executor: NativeDatabase(file));
        try {
          final pending = (await reopened.loadPending('alice')).single;
          expect(pending.replyTo?.id, 'original');
          expect(pending.replyTo?.kind, MessageKind.voice);
          expect(
            (await reopened.loadMessages(
              'alice',
              'conversation',
            )).single.replyTo?.senderId,
            'bob',
          );
        } finally {
          await reopened.close();
        }
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test('voice message metadata survives reopening the cache', () async {
    final directory = await Directory.systemTemp.createTemp('chat-voice-test-');
    final file = File('${directory.path}/messages.sqlite');
    try {
      final first = ChatLocalStore(executor: NativeDatabase(file));
      await first.upsertMessage(
        'alice',
        ChatMessage(
          id: 'voice-1',
          clientMessageId: 'voice-client-1',
          conversationId: 'conversation',
          senderId: 'bob',
          text: '',
          kind: MessageKind.voice,
          voiceDurationMs: 2500,
          sequence: 1,
          createdAt: DateTime.utc(2026, 10, 13),
          status: MessageStatus.sent,
        ),
      );
      await first.close();
      final reopened = ChatLocalStore(executor: NativeDatabase(file));
      try {
        final voice = (await reopened.loadMessages(
          'alice',
          'conversation',
        )).single;
        expect(voice.kind, MessageKind.voice);
        expect(voice.voiceDurationMs, 2500);
      } finally {
        await reopened.close();
      }
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('v3 cache gains hearts and keeps them after restart', () async {
    final directory = await Directory.systemTemp.createTemp('chat-v3-test-');
    final file = File('${directory.path}/messages.sqlite');
    try {
      final legacy = _LegacyV3ChatStore(NativeDatabase(file));
      await legacy.customStatement(
        '''
        INSERT INTO messages
          (account_id, id, client_message_id, conversation_id, sender_id,
           body, sequence, created_at_ms, status)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
        [
          'alice',
          'server-1',
          'client-1',
          'conversation',
          'bob',
          'Xin chào',
          1,
          DateTime.utc(2026, 10, 13).millisecondsSinceEpoch,
          'sent',
        ],
      );
      await legacy.close();

      final upgraded = ChatLocalStore(executor: NativeDatabase(file));
      final oldMessage = (await upgraded.loadMessages(
        'alice',
        'conversation',
      )).single;
      expect(oldMessage.heartedBy, isEmpty);
      await upgraded.upsertMessage(
        'alice',
        oldMessage.copyWith(
          heartedBy: ['alice'],
          reactionSets: {
            'bob': [MessageReaction.like, MessageReaction.wow],
          },
        ),
      );
      await upgraded.close();

      final reopened = ChatLocalStore(executor: NativeDatabase(file));
      try {
        expect(
          (await reopened.loadMessages(
            'alice',
            'conversation',
          )).single.heartedBy,
          ['alice'],
        );
        expect(
          (await reopened.loadMessages(
            'alice',
            'conversation',
          )).single.effectiveReactionSets['bob'],
          [MessageReaction.like, MessageReaction.wow],
        );
      } finally {
        await reopened.close();
      }
    } finally {
      await directory.delete(recursive: true);
    }
  });

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
            lastDeliveredSequence: 8,
            peerLastDeliveredSequence: 5,
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
          expect(conversations.single.lastDeliveredSequence, 8);
          expect(conversations.single.peerLastDeliveredSequence, 5);
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

  test(
    'clearing downloaded history preserves queued sends and other accounts',
    () async {
      final store = ChatLocalStore(executor: NativeDatabase.memory());
      try {
        await store.upsertConversation(
          'alice',
          const Conversation(id: 'chat', title: 'Bob', peerId: 'bob'),
        );
        await store.upsertMessage(
          'alice',
          _message(
            id: 'sent',
            clientMessageId: 'sent',
            status: MessageStatus.sent,
          ),
        );
        await store.upsertMessage(
          'bob',
          _message(
            id: 'other',
            clientMessageId: 'other',
            status: MessageStatus.sent,
          ),
        );
        await store.enqueueOutgoing(
          'alice',
          _message(id: 'queued', clientMessageId: 'queued'),
        );

        expect(await store.clearDownloadedHistory('alice'), isFalse);
        expect(await store.loadPending('alice'), hasLength(1));
        expect(await store.loadConversations('alice'), hasLength(1));

        await store.removePending('alice', 'conversation', 'queued');
        expect(await store.loadMessages('alice', 'conversation'), hasLength(1));
        expect(await store.clearDownloadedHistory('alice'), isTrue);
        expect(await store.loadMessages('alice', 'conversation'), isEmpty);
        expect(await store.loadConversations('alice'), isEmpty);
        expect(await store.loadMessages('bob', 'conversation'), hasLength(1));
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

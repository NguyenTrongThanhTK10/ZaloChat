import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import '../../features/chat/domain/entities/chat_message.dart';
import '../../features/conversations/domain/entities/conversation.dart';

/// Per-account message cache and durable outgoing queue.
///
/// A single instance should be shared by the application. Pass an in-memory
/// [QueryExecutor] in tests; production uses an on-device SQLite database.
class ChatLocalStore extends GeneratedDatabase {
  ChatLocalStore({QueryExecutor? executor})
    : super(executor ?? driftDatabase(name: 'appchatdemo_chat'));

  @override
  int get schemaVersion => 9;

  // The schema is created with SQL below, so it needs no generated Drift code.
  @override
  Iterable<TableInfo> get allTables => const [];

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await _createMessagesSchema(m.database);
      await _createOutboxSchema(m.database);
      await _createConversationSchema(m.database);
    },
    onUpgrade: (m, from, to) async {
      if (from < 2) await _createConversationSchema(m.database);
      if (from < 3) await _migrateMessageKeys(m.database);
      if (from == 3) {
        await m.database.customStatement(
          "ALTER TABLE messages ADD COLUMN hearted_by_json TEXT NOT NULL DEFAULT '[]'",
        );
      }
      if (from >= 3 && from < 5) {
        await m.database.customStatement(
          "ALTER TABLE messages ADD COLUMN kind TEXT NOT NULL DEFAULT 'text'",
        );
        await m.database.customStatement(
          'ALTER TABLE messages ADD COLUMN voice_duration_ms INTEGER',
        );
      }
      if (from >= 3 && from < 6) {
        await m.database.customStatement(
          'ALTER TABLE messages ADD COLUMN reply_to_json TEXT',
        );
      }
      if (from < 7) {
        await m.database.customStatement(
          'ALTER TABLE conversations ADD COLUMN last_delivered_sequence INTEGER NOT NULL DEFAULT 0',
        );
        await m.database.customStatement(
          'ALTER TABLE conversations ADD COLUMN peer_last_delivered_sequence INTEGER NOT NULL DEFAULT 0',
        );
      }
      if (from >= 3 && from < 8) {
        await m.database.customStatement(
          'ALTER TABLE messages ADD COLUMN is_recalled INTEGER NOT NULL DEFAULT 0',
        );
      }
      if (from >= 3 && from < 9) {
        await m.database.customStatement(
          'ALTER TABLE messages ADD COLUMN attachment_json TEXT',
        );
      }
    },
  );

  static Future<void> _createMessagesSchema(GeneratedDatabase database) async {
    await database.customStatement('''
      CREATE TABLE messages (
        account_id TEXT NOT NULL,
        id TEXT NOT NULL,
        client_message_id TEXT NOT NULL,
        conversation_id TEXT NOT NULL,
        sender_id TEXT NOT NULL,
        body TEXT NOT NULL,
        sequence INTEGER NOT NULL CHECK (sequence >= 0),
        created_at_ms INTEGER NOT NULL,
        status TEXT NOT NULL,
        hearted_by_json TEXT NOT NULL DEFAULT '[]',
        kind TEXT NOT NULL DEFAULT 'text',
        voice_duration_ms INTEGER,
        reply_to_json TEXT,
        is_recalled INTEGER NOT NULL DEFAULT 0,
        attachment_json TEXT,
        PRIMARY KEY (account_id, conversation_id, sender_id, id),
        UNIQUE (account_id, conversation_id, sender_id, client_message_id)
      )
    ''');
    await database.customStatement('''
      CREATE INDEX messages_by_conversation
      ON messages (account_id, conversation_id, sequence DESC, created_at_ms DESC)
    ''');
  }

  static Future<void> _createOutboxSchema(GeneratedDatabase database) async {
    await database.customStatement('''
      CREATE TABLE outbox (
        account_id TEXT NOT NULL,
        conversation_id TEXT NOT NULL,
        sender_id TEXT NOT NULL,
        client_message_id TEXT NOT NULL,
        queued_at_ms INTEGER NOT NULL,
        PRIMARY KEY (account_id, conversation_id, sender_id, client_message_id)
      )
    ''');
    await database.customStatement('''
      CREATE INDEX outbox_by_queue
      ON outbox (account_id, queued_at_ms, conversation_id, client_message_id)
    ''');
  }

  static Future<void> _migrateMessageKeys(GeneratedDatabase database) async {
    await database.customStatement(
      'ALTER TABLE messages RENAME TO messages_v2',
    );
    await database.customStatement('DROP INDEX messages_by_conversation');
    await _createMessagesSchema(database);
    await database.customStatement('''
      INSERT INTO messages
        (account_id, id, client_message_id, conversation_id, sender_id,
         body, sequence, created_at_ms, status)
      SELECT account_id, id, client_message_id, conversation_id, sender_id,
             body, sequence, created_at_ms, status
      FROM messages_v2
    ''');
    await database.customStatement('DROP TABLE messages_v2');
    await database.customStatement('ALTER TABLE outbox RENAME TO outbox_v2');
    await database.customStatement('DROP INDEX outbox_by_queue');
    await _createOutboxSchema(database);
    await database.customStatement('''
      INSERT INTO outbox
        (account_id, conversation_id, sender_id, client_message_id,
         queued_at_ms)
      SELECT old.account_id, message.conversation_id, message.sender_id,
             old.client_message_id, old.queued_at_ms
      FROM outbox_v2 AS old
      JOIN messages AS message
        ON message.account_id = old.account_id
       AND message.client_message_id = old.client_message_id
      WHERE message.sender_id = old.account_id
    ''');
    await database.customStatement('DROP TABLE outbox_v2');
  }

  static Future<void> _createConversationSchema(GeneratedDatabase database) =>
      database.customStatement('''
        CREATE TABLE conversations (
          account_id TEXT NOT NULL,
          id TEXT NOT NULL,
          title TEXT NOT NULL,
          peer_id TEXT NOT NULL,
          avatar_url TEXT,
          is_group INTEGER NOT NULL,
          unread_count INTEGER NOT NULL,
          is_pinned INTEGER NOT NULL,
          is_muted INTEGER NOT NULL,
          last_message_preview TEXT,
          last_message_at_ms INTEGER,
          last_read_sequence INTEGER NOT NULL,
          peer_last_read_sequence INTEGER NOT NULL,
          last_delivered_sequence INTEGER NOT NULL,
          peer_last_delivered_sequence INTEGER NOT NULL,
          PRIMARY KEY (account_id, id)
        )
      ''');

  /// Saves a conversation summary received from the server or realtime feed.
  Future<void> upsertConversation(
    String accountId,
    Conversation conversation,
  ) => _upsertConversation(accountId, conversation);

  /// Updates several conversation summaries atomically.
  Future<void> upsertConversations(
    String accountId,
    Iterable<Conversation> conversations,
  ) => transaction(() async {
    for (final conversation in conversations) {
      await _upsertConversation(accountId, conversation);
    }
  });

  /// Replaces this account's full server conversation list atomically.
  Future<void> replaceConversations(
    String accountId,
    Iterable<Conversation> conversations,
  ) => transaction(() async {
    await customStatement('DELETE FROM conversations WHERE account_id = ?', [
      accountId,
    ]);
    for (final conversation in conversations) {
      await _upsertConversation(accountId, conversation);
    }
  });

  /// Reads the cached list in inbox order. Presence and typing are transient.
  Future<List<Conversation>> loadConversations(String accountId) async {
    final rows = await customSelect(
      '''
        SELECT id, title, peer_id, avatar_url, is_group, unread_count,
               is_pinned, is_muted, last_message_preview, last_message_at_ms,
               last_read_sequence, peer_last_read_sequence,
               last_delivered_sequence, peer_last_delivered_sequence
        FROM conversations
        WHERE account_id = ?
        ORDER BY is_pinned DESC, COALESCE(last_message_at_ms, 0) DESC, id ASC
      ''',
      variables: [Variable.withString(accountId)],
    ).get();

    return rows
        .map(
          (row) => Conversation(
            id: row.read<String>('id'),
            title: row.read<String>('title'),
            peerId: row.read<String>('peer_id'),
            avatarUrl: row.readNullable<String>('avatar_url'),
            isGroup: row.read<int>('is_group') != 0,
            unreadCount: row.read<int>('unread_count'),
            isPinned: row.read<int>('is_pinned') != 0,
            isMuted: row.read<int>('is_muted') != 0,
            lastMessagePreview: row.readNullable<String>(
              'last_message_preview',
            ),
            lastMessageAt: switch (row.readNullable<int>(
              'last_message_at_ms',
            )) {
              final int value => DateTime.fromMillisecondsSinceEpoch(
                value,
                isUtc: true,
              ).toLocal(),
              null => null,
            },
            lastReadSequence: row.read<int>('last_read_sequence'),
            peerLastReadSequence: row.read<int>('peer_last_read_sequence'),
            lastDeliveredSequence: row.read<int>('last_delivered_sequence'),
            peerLastDeliveredSequence: row.read<int>(
              'peer_last_delivered_sequence',
            ),
          ),
        )
        .toList(growable: false);
  }

  Future<void> removeConversation(String accountId, String conversationId) =>
      customStatement(
        'DELETE FROM conversations WHERE account_id = ? AND id = ?',
        [accountId, conversationId],
      );

  Future<void> _upsertConversation(
    String accountId,
    Conversation conversation,
  ) => customStatement(
    '''
      INSERT INTO conversations
        (account_id, id, title, peer_id, avatar_url, is_group, unread_count,
         is_pinned, is_muted, last_message_preview, last_message_at_ms,
         last_read_sequence, peer_last_read_sequence,
         last_delivered_sequence, peer_last_delivered_sequence)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT (account_id, id) DO UPDATE SET
        title = excluded.title,
        peer_id = excluded.peer_id,
        avatar_url = excluded.avatar_url,
        is_group = excluded.is_group,
        unread_count = excluded.unread_count,
        is_pinned = excluded.is_pinned,
        is_muted = excluded.is_muted,
        last_message_preview = excluded.last_message_preview,
        last_message_at_ms = excluded.last_message_at_ms,
        last_read_sequence = excluded.last_read_sequence,
        peer_last_read_sequence = excluded.peer_last_read_sequence,
        last_delivered_sequence = excluded.last_delivered_sequence,
        peer_last_delivered_sequence = excluded.peer_last_delivered_sequence
    ''',
    [
      accountId,
      conversation.id,
      conversation.title,
      conversation.peerId,
      conversation.avatarUrl,
      conversation.isGroup ? 1 : 0,
      conversation.unreadCount,
      conversation.isPinned ? 1 : 0,
      conversation.isMuted ? 1 : 0,
      conversation.lastMessagePreview,
      conversation.lastMessageAt?.toUtc().millisecondsSinceEpoch,
      conversation.lastReadSequence,
      conversation.peerLastReadSequence,
      conversation.lastDeliveredSequence,
      conversation.peerLastDeliveredSequence,
    ],
  );

  /// Inserts or replaces one message, deduplicating both server and client IDs.
  Future<void> upsertMessage(String accountId, ChatMessage message) =>
      transaction(() async {
        await _upsertMessage(accountId, message);
      });

  /// Stores a fetched page or realtime batch as one atomic cache update.
  Future<void> upsertMessages(
    String accountId,
    Iterable<ChatMessage> messages,
  ) => transaction(() async {
    for (final message in messages) {
      await _upsertMessage(accountId, message);
    }
  });

  /// Returns up to [limit] messages, oldest first. Pending messages with
  /// sequence zero appear after confirmed messages when loading the latest page.
  /// [beforeSequence] fetches only older confirmed messages for pagination.
  Future<List<ChatMessage>> loadMessages(
    String accountId,
    String conversationId, {
    int limit = 50,
    int? beforeSequence,
  }) async {
    if (limit <= 0) {
      throw ArgumentError.value(limit, 'limit', 'Must be positive');
    }

    final olderPage = beforeSequence != null;
    final rows = await customSelect(
      '''
        SELECT id, client_message_id, conversation_id, sender_id, body,
               sequence, created_at_ms, status, hearted_by_json, kind,
               voice_duration_ms, reply_to_json, is_recalled, attachment_json
        FROM messages
        WHERE account_id = ? AND conversation_id = ?
          ${olderPage ? 'AND sequence > 0 AND sequence < ?' : ''}
        ORDER BY CASE WHEN sequence = 0 THEN 1 ELSE 0 END DESC,
                 sequence DESC, created_at_ms DESC, id DESC
        LIMIT ?
      ''',
      variables: [
        Variable.withString(accountId),
        Variable.withString(conversationId),
        if (olderPage) Variable.withInt(beforeSequence),
        Variable.withInt(limit),
      ],
    ).get();

    return rows.reversed.map(_readMessage).toList(growable: false);
  }

  /// Persists an optimistic local message before any network send begins.
  /// Re-enqueueing a failed message resets its visible status to sending.
  Future<void> enqueueOutgoing(String accountId, ChatMessage message) async {
    if (message.senderId != accountId) {
      throw ArgumentError.value(
        message.senderId,
        'message.senderId',
        'Only the current account can enqueue an outgoing message',
      );
    }
    if (message.clientMessageId.isEmpty) {
      throw ArgumentError.value(
        message.clientMessageId,
        'clientMessageId',
        'Must not be empty',
      );
    }

    await transaction(() async {
      final stored = await _upsertMessage(
        accountId,
        message.copyWith(sequence: 0, status: MessageStatus.sending),
      );
      // A server echo may have confirmed this client ID before a retry starts.
      if (stored.sequence > 0) return;
      await customStatement(
        '''
          INSERT OR IGNORE INTO outbox
            (account_id, conversation_id, sender_id, client_message_id,
             queued_at_ms)
          VALUES (?, ?, ?, ?, ?)
        ''',
        [
          accountId,
          message.conversationId,
          message.senderId,
          message.clientMessageId,
          DateTime.now().toUtc().millisecondsSinceEpoch,
        ],
      );
    });
  }

  /// Loads the durable send queue in enqueue order for reconnect retries.
  Future<List<ChatMessage>> loadPending(String accountId) async {
    final rows = await customSelect(
      '''
        SELECT m.id, m.client_message_id, m.conversation_id, m.sender_id,
               m.body, m.sequence, m.created_at_ms, m.status,
               m.hearted_by_json, m.kind, m.voice_duration_ms, m.reply_to_json,
               m.is_recalled, m.attachment_json
        FROM outbox AS o
        JOIN messages AS m
          ON m.account_id = o.account_id
         AND m.conversation_id = o.conversation_id
         AND m.sender_id = o.sender_id
         AND m.client_message_id = o.client_message_id
        WHERE o.account_id = ? AND o.sender_id = ?
        ORDER BY o.queued_at_ms ASC, o.conversation_id ASC,
                 o.client_message_id ASC
      ''',
      variables: [
        Variable.withString(accountId),
        Variable.withString(accountId),
      ],
    ).get();
    return rows.map(_readMessage).toList(growable: false);
  }

  /// Replaces an optimistic message with its authoritative server version.
  Future<void> markSent(
    String accountId,
    String clientMessageId,
    ChatMessage serverMessage,
  ) async {
    if (serverMessage.clientMessageId != clientMessageId) {
      throw ArgumentError.value(
        serverMessage.clientMessageId,
        'serverMessage.clientMessageId',
        'Must match the queued clientMessageId',
      );
    }
    if (serverMessage.sequence <= 0) {
      throw ArgumentError.value(
        serverMessage.sequence,
        'serverMessage.sequence',
        'A server acknowledgement must have a positive sequence',
      );
    }
    if (serverMessage.senderId != accountId) {
      throw ArgumentError.value(
        serverMessage.senderId,
        'serverMessage.senderId',
        'Only the current account can acknowledge an outgoing message',
      );
    }

    await transaction(() async {
      await _upsertMessage(
        accountId,
        serverMessage.status == MessageStatus.sending ||
                serverMessage.status == MessageStatus.failed
            ? serverMessage.copyWith(status: MessageStatus.sent)
            : serverMessage,
      );
      await _deleteOutbox(
        accountId,
        serverMessage.conversationId,
        serverMessage.senderId,
        clientMessageId,
      );
    });
  }

  /// Marks a queued send as failed without dropping it from retry storage.
  Future<void> markFailed(
    String accountId,
    String conversationId,
    String clientMessageId,
  ) => customStatement(
    '''
          UPDATE messages SET status = 'failed'
          WHERE account_id = ? AND conversation_id = ? AND sender_id = ?
            AND client_message_id = ? AND sequence = 0
            AND EXISTS (
              SELECT 1 FROM outbox
              WHERE outbox.account_id = messages.account_id
                AND outbox.conversation_id = messages.conversation_id
                AND outbox.sender_id = messages.sender_id
                AND outbox.client_message_id = messages.client_message_id
            )
        ''',
    [accountId, conversationId, accountId, clientMessageId],
  );

  /// Cancels a queued send and removes its local-only optimistic bubble.
  Future<void> removePending(
    String accountId,
    String conversationId,
    String clientMessageId,
  ) => transaction(() async {
    await _deleteOutbox(accountId, conversationId, accountId, clientMessageId);
    await customStatement(
      '''
            DELETE FROM messages
            WHERE account_id = ? AND conversation_id = ? AND sender_id = ?
              AND client_message_id = ? AND sequence = 0
              AND status IN ('sending', 'failed')
          ''',
      [accountId, conversationId, accountId, clientMessageId],
    );
  });

  /// Removes only one account's cached messages and queued sends on sign-out.
  Future<void> clearAccount(String accountId) => transaction(() async {
    await customStatement('DELETE FROM conversations WHERE account_id = ?', [
      accountId,
    ]);
    await customStatement('DELETE FROM outbox WHERE account_id = ?', [
      accountId,
    ]);
    await customStatement('DELETE FROM messages WHERE account_id = ?', [
      accountId,
    ]);
  });

  /// Clears downloaded history only when no outgoing messages are queued.
  /// The server copy remains available for the next refresh.
  Future<bool> clearDownloadedHistory(String accountId) =>
      transaction(() async {
        final pending = await customSelect(
          'SELECT 1 FROM outbox WHERE account_id = ? LIMIT 1',
          variables: [Variable.withString(accountId)],
        ).get();
        if (pending.isNotEmpty) return false;
        await customStatement(
          'DELETE FROM conversations WHERE account_id = ?',
          [accountId],
        );
        await customStatement('DELETE FROM messages WHERE account_id = ?', [
          accountId,
        ]);
        return true;
      });

  Future<ChatMessage> _upsertMessage(
    String accountId,
    ChatMessage message,
  ) async {
    final existingRows = await customSelect(
      '''
        SELECT id, client_message_id, conversation_id, sender_id, body,
               sequence, created_at_ms, status, hearted_by_json, kind,
               voice_duration_ms, reply_to_json, is_recalled, attachment_json
        FROM messages
        WHERE account_id = ? AND conversation_id = ? AND sender_id = ?
          AND (id = ? OR client_message_id = ?)
      ''',
      variables: [
        Variable.withString(accountId),
        Variable.withString(message.conversationId),
        Variable.withString(message.senderId),
        Variable.withString(message.id),
        Variable.withString(message.clientMessageId),
      ],
    ).get();

    var value = message;
    for (final row in existingRows) {
      final cached = _readMessage(row);
      if (cached.sequence > value.sequence) {
        value = cached;
      } else if (cached.isRecalled && !value.isRecalled) {
        value = cached;
      } else if (cached.status != MessageStatus.failed &&
          cached.status != MessageStatus.sending &&
          value.status != MessageStatus.failed &&
          value.status != MessageStatus.sending &&
          _deliveryRank(cached.status) > _deliveryRank(value.status)) {
        value = value.copyWith(status: cached.status);
      }
    }

    await customStatement(
      '''
        DELETE FROM messages
        WHERE account_id = ? AND conversation_id = ? AND sender_id = ?
          AND (id = ? OR client_message_id = ?)
      ''',
      [
        accountId,
        message.conversationId,
        message.senderId,
        message.id,
        message.clientMessageId,
      ],
    );
    await customStatement(
      '''
        INSERT INTO messages
          (account_id, id, client_message_id, conversation_id, sender_id,
           body, sequence, created_at_ms, status, hearted_by_json, kind,
           voice_duration_ms, reply_to_json, is_recalled, attachment_json)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        accountId,
        value.id,
        value.clientMessageId,
        value.conversationId,
        value.senderId,
        value.text,
        value.sequence,
        value.createdAt.toUtc().millisecondsSinceEpoch,
        value.status.name,
        jsonEncode(
          value.effectiveReactionSets.map(
            (userId, reactions) => MapEntry(
              userId,
              reactions.map((reaction) => reaction.name).toList(),
            ),
          ),
        ),
        value.kind.name,
        value.voiceDurationMs,
        value.replyTo == null ? null : jsonEncode(value.replyTo!.toJson()),
        value.isRecalled ? 1 : 0,
        value.attachment == null
            ? null
            : jsonEncode(value.attachment!.toJson()),
      ],
    );

    if (value.sequence > 0) {
      await _deleteOutbox(
        accountId,
        value.conversationId,
        value.senderId,
        value.clientMessageId,
      );
    }
    return value;
  }

  Future<void> _deleteOutbox(
    String accountId,
    String conversationId,
    String senderId,
    String clientMessageId,
  ) => customStatement(
    '''
      DELETE FROM outbox
      WHERE account_id = ? AND conversation_id = ? AND sender_id = ?
        AND client_message_id = ?
    ''',
    [accountId, conversationId, senderId, clientMessageId],
  );

  ChatMessage _readMessage(QueryRow row) {
    final stored = jsonDecode(row.read<String>('hearted_by_json'));
    final reactionSets = stored is List
        ? {
            for (final userId in stored)
              userId.toString(): [MessageReaction.heart],
          }
        : (stored as Map).map(
            (userId, selected) => MapEntry(
              userId.toString(),
              (selected is List ? selected : [selected])
                  .map(
                    (reaction) =>
                        MessageReaction.values.byName(reaction.toString()),
                  )
                  .toList(),
            ),
          );
    return ChatMessage(
      id: row.read<String>('id'),
      clientMessageId: row.read<String>('client_message_id'),
      conversationId: row.read<String>('conversation_id'),
      senderId: row.read<String>('sender_id'),
      text: row.read<String>('body'),
      sequence: row.read<int>('sequence'),
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        row.read<int>('created_at_ms'),
        isUtc: true,
      ),
      status: MessageStatus.values.byName(row.read<String>('status')),
      heartedBy: [
        for (final entry in reactionSets.entries)
          if (entry.value.contains(MessageReaction.heart)) entry.key,
      ],
      reactionSets: reactionSets,
      kind: MessageKind.values.byName(row.read<String>('kind')),
      voiceDurationMs: row.read<int?>('voice_duration_ms'),
      attachment: row.read<String?>('attachment_json') == null
          ? null
          : MessageAttachment.fromJson(
              jsonDecode(row.read<String>('attachment_json'))
                  as Map<String, dynamic>,
            ),
      replyTo: row.read<String?>('reply_to_json') == null
          ? null
          : MessageReply.fromJson(
              jsonDecode(row.read<String>('reply_to_json'))
                  as Map<String, dynamic>,
            ),
      isRecalled: row.read<int>('is_recalled') != 0,
    );
  }

  int _deliveryRank(MessageStatus status) => switch (status) {
    MessageStatus.sending => 0,
    MessageStatus.failed => 0,
    MessageStatus.sent => 1,
    MessageStatus.delivered => 2,
    MessageStatus.read => 3,
  };
}

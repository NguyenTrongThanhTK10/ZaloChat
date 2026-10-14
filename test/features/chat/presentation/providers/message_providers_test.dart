import 'dart:async';

import 'package:appchatdemo/core/database/chat_local_store.dart';
import 'package:appchatdemo/core/database/chat_local_store_provider.dart';
import 'package:appchatdemo/core/media/speech_input.dart';
import 'package:appchatdemo/core/media/speech_input_provider.dart';
import 'package:appchatdemo/core/realtime/realtime_providers.dart';
import 'package:appchatdemo/core/widgets/chat_avatar.dart';
import 'package:appchatdemo/features/auth/domain/entities/chat_user.dart';
import 'package:appchatdemo/features/auth/presentation/providers/auth_providers.dart';
import 'package:appchatdemo/features/chat/domain/entities/chat_message.dart';
import 'package:appchatdemo/features/chat/domain/entities/message_page.dart';
import 'package:appchatdemo/features/chat/domain/repositories/message_repository.dart';
import 'package:appchatdemo/features/chat/presentation/pages/chat_page.dart';
import 'package:appchatdemo/features/chat/presentation/providers/message_providers.dart';
import 'package:appchatdemo/features/conversations/domain/entities/conversation.dart';
import 'package:appchatdemo/features/conversations/domain/repositories/conversation_repository.dart';
import 'package:appchatdemo/features/conversations/presentation/providers/conversation_providers.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import '../../../../support/fake_speech_input_engine.dart';

const _account = ChatUser(
  id: 'alice',
  displayName: 'Alice',
  email: 'alice@example.test',
);

const _conversation = Conversation(id: 'chat', title: 'Bob', peerId: 'bob');

ChatMessage _message({
  required String id,
  required String clientMessageId,
  required String senderId,
  required int sequence,
  required String text,
  MessageStatus status = MessageStatus.sent,
  MessageReply? replyTo,
}) => ChatMessage(
  id: id,
  clientMessageId: clientMessageId,
  conversationId: 'chat',
  senderId: senderId,
  text: text,
  sequence: sequence,
  createdAt: DateTime.utc(2026, 10, 13, 12, 0, sequence),
  status: status,
  replyTo: replyTo,
);

class _SendAttempt {
  const _SendAttempt(
    this.conversationId,
    this.clientMessageId,
    this.text,
    this.replyToMessageId,
  );

  final String conversationId;
  final String clientMessageId;
  final String text;
  final String? replyToMessageId;
}

class _MessageRepository implements MessageRepository {
  _MessageRepository({this.messages = const []});

  final List<ChatMessage> messages;
  final List<_SendAttempt> attempts = [];
  Completer<void>? sendStarted;
  Future<ChatMessage>? nextSendResult;

  @override
  Future<MessagePage> fetchPage(
    String conversationId, {
    int? beforeSequence,
    int limit = 30,
  }) async => MessagePage(items: messages, nextCursor: null);

  @override
  Future<ChatMessage> send(
    String conversationId,
    String clientMessageId,
    String text, {
    String? replyToMessageId,
  }) {
    attempts.add(
      _SendAttempt(conversationId, clientMessageId, text, replyToMessageId),
    );
    if (sendStarted?.isCompleted == false) sendStarted!.complete();
    return nextSendResult ??
        Future.value(
          _message(
            id: 'server-1',
            clientMessageId: clientMessageId,
            senderId: 'alice',
            sequence: 12,
            text: text,
            replyTo: replyToMessageId == null
                ? null
                : MessageReply.fromMessage(
                    messages.singleWhere(
                      (message) => message.id == replyToMessageId,
                    ),
                  ),
          ),
        );
  }

  @override
  Future<ChatMessage> setHeart(
    String messageId, {
    required bool hearted,
  }) async {
    final message = messages.singleWhere((item) => item.id == messageId);
    return message.copyWith(heartedBy: hearted ? ['alice'] : const []);
  }

  @override
  Future<ChatMessage> sendVoice(
    String conversationId,
    String clientMessageId,
    String filePath,
    int durationMs, {
    String? replyToMessageId,
  }) async => ChatMessage(
    id: 'voice-server',
    clientMessageId: clientMessageId,
    conversationId: conversationId,
    senderId: 'alice',
    text: '',
    kind: MessageKind.voice,
    voiceDurationMs: durationMs,
    sequence: 13,
    createdAt: DateTime.utc(2026, 10, 13),
    status: MessageStatus.sent,
  );

  @override
  Future<String> downloadVoice(String messageId) async => '/tmp/$messageId.m4a';
}

class _ConversationRepository implements ConversationRepository {
  @override
  Future<ChatUser> getUser(String userId) async =>
      ChatUser(id: userId, displayName: 'Bob', email: 'bob@example.com');

  @override
  Future<List<Conversation>> list() async => [_conversation];

  @override
  Future<int> markRead(String conversationId, int throughSequence) async =>
      throughSequence;

  @override
  Future<List<ChatUser>> searchUsers(String query) async => [];

  @override
  Future<Conversation> start(String peerUserId) async => _conversation;
}

class _ReadAwareStore extends ChatLocalStore {
  _ReadAwareStore() : super(executor: NativeDatabase.memory());

  final readPersisted = Completer<void>();

  @override
  Future<void> upsertMessages(
    String accountId,
    Iterable<ChatMessage> messages,
  ) async {
    await super.upsertMessages(accountId, messages);
    if (messages.any((message) => message.status == MessageStatus.read) &&
        !readPersisted.isCompleted) {
      readPersisted.complete();
    }
  }
}

void main() {
  setUpAll(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });
  testWidgets('dictated text can be edited and sent as a normal chat message', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = ChatLocalStore(executor: NativeDatabase.memory());
    final repository = _MessageRepository();
    final engine = FakeSpeechInputEngine();
    final speech = SpeechInput(engine);
    final container = ProviderContainer(
      overrides: [
        currentUserProvider.overrideWithValue(_account),
        realtimeServiceProvider.overrideWithValue(null),
        chatLocalStoreProvider.overrideWithValue(store),
        messageRepositoryProvider.overrideWithValue(repository),
        speechInputProvider.overrideWithValue(speech),
        conversationRepositoryProvider.overrideWithValue(
          _ConversationRepository(),
        ),
      ],
    );
    try {
      await container.read(conversationDetailProvider('chat').future);
      await container.read(messagesProvider('chat').future);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: ChatPage(conversationId: 'chat')),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Chào');
      await tester.tap(find.byKey(const ValueKey('open-voice-panel')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Gửi dạng văn bản'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('voice-record-button')));
      await tester.pumpAndSettle();
      expect(find.text('Đang nghe · Tiếng Việt'), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isTrue);
      final voiceButton = tester.widget<ChoiceChip>(
        find.ancestor(
          of: find.text('Gửi bản ghi âm'),
          matching: find.byType(ChoiceChip),
        ),
      );
      expect(voiceButton.onSelected, isNull);
      engine.words('bạn');
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Chào bạn',
      );
      expect(repository.attempts, isEmpty);
      await tester.tap(find.byKey(const ValueKey('voice-record-button')));
      await tester.pump();
      engine.words('bạn thân', finalResult: true);
      engine.done();
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).readOnly,
        isFalse,
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Chào bạn thân',
      );
      await tester.enterText(find.byType(TextField), 'Chào bạn thân!');
      await tester.pump();
      await tester.tap(find.byTooltip('Gửi tin nhắn'));
      await tester.pumpAndSettle();
      expect(repository.attempts.single.text, 'Chào bạn thân!');
      expect(engine.stopCount, 1);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      speech.dispose();
      await store.close();
    }
  });

  testWidgets('speech errors allow retry and cancel restores the typed draft', (
    tester,
  ) async {
    final store = ChatLocalStore(executor: NativeDatabase.memory());
    final repository = _MessageRepository();
    final engine = FakeSpeechInputEngine()..available = false;
    final speech = SpeechInput(engine);
    final container = ProviderContainer(
      overrides: [
        currentUserProvider.overrideWithValue(_account),
        realtimeServiceProvider.overrideWithValue(null),
        chatLocalStoreProvider.overrideWithValue(store),
        messageRepositoryProvider.overrideWithValue(repository),
        speechInputProvider.overrideWithValue(speech),
        conversationRepositoryProvider.overrideWithValue(
          _ConversationRepository(),
        ),
      ],
    );
    try {
      await container.read(conversationDetailProvider('chat').future);
      await container.read(messagesProvider('chat').future);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: ChatPage(conversationId: 'chat')),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Bản nháp');
      await tester.tap(find.byKey(const ValueKey('open-voice-panel')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Gửi dạng văn bản'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('voice-record-button')));
      await tester.pumpAndSettle();
      expect(find.textContaining('quyền micro'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Bản nháp',
      );
      engine.available = true;
      await tester.tap(find.byKey(const ValueKey('voice-record-button')));
      await tester.pumpAndSettle();
      engine.words('chưa gửi');
      await tester.pump();
      await tester.tap(find.text('Hủy nhập giọng nói'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Bản nháp',
      );
      expect(repository.attempts, isEmpty);
      expect(find.textContaining('quyền micro'), findsNothing);
      engine.words('kết quả đến muộn', finalResult: true);
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Bản nháp',
      );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      speech.dispose();
      await store.close();
    }
  });

  testWidgets('long press copies text and sends a quoted reply', (
    tester,
  ) async {
    final store = ChatLocalStore(executor: NativeDatabase.memory());
    final repository = _MessageRepository(
      messages: [
        _message(
          id: 'original',
          clientMessageId: 'original-client',
          senderId: 'bob',
          sequence: 1,
          text: 'Bạn có rảnh không?',
        ),
      ],
    );
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    final container = ProviderContainer(
      overrides: [
        currentUserProvider.overrideWithValue(_account),
        realtimeServiceProvider.overrideWithValue(null),
        chatLocalStoreProvider.overrideWithValue(store),
        messageRepositoryProvider.overrideWithValue(repository),
        conversationRepositoryProvider.overrideWithValue(
          _ConversationRepository(),
        ),
      ],
    );
    try {
      await container.read(conversationDetailProvider('chat').future);
      await container.read(messagesProvider('chat').future);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: ChatPage(conversationId: 'chat')),
        ),
      );
      await tester.pumpAndSettle();
      final original = find.byKey(const ValueKey('message-original'));
      await tester.longPress(original);
      await tester.pumpAndSettle();
      expect(find.text('Thả tim'), findsOneWidget);
      expect(find.text('Trả lời'), findsOneWidget);
      await tester.tap(find.text('Sao chép'));
      await tester.pumpAndSettle();
      expect(copied, 'Bạn có rảnh không?');

      await tester.longPress(original);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Trả lời'));
      await tester.pumpAndSettle();
      expect(find.text('Đang trả lời Bob'), findsOneWidget);
      await tester.tap(find.byTooltip('Hủy trả lời'));
      await tester.pumpAndSettle();
      expect(find.text('Đang trả lời Bob'), findsNothing);

      await tester.longPress(original);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Trả lời'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Mình rảnh');
      await tester.pump();
      await tester.tap(find.byTooltip('Gửi tin nhắn'));
      await tester.pumpAndSettle();
      expect(repository.attempts.single.replyToMessageId, 'original');
      expect(find.text('Đang trả lời Bob'), findsNothing);
      expect(find.text('Bạn có rảnh không?'), findsNWidgets(2));
      final cached = await store.loadMessages('alice', 'chat');
      expect(cached.last.replyTo?.text, 'Bạn có rảnh không?');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
      container.dispose();
      await store.close();
    }
  });

  test('sending voice stores a playable message in the cache', () async {
    final store = ChatLocalStore(executor: NativeDatabase.memory());
    final repository = _MessageRepository();
    final container = ProviderContainer(
      overrides: [
        currentUserProvider.overrideWithValue(_account),
        realtimeServiceProvider.overrideWithValue(null),
        chatLocalStoreProvider.overrideWithValue(store),
        messageRepositoryProvider.overrideWithValue(repository),
        conversationRepositoryProvider.overrideWithValue(
          _ConversationRepository(),
        ),
      ],
    );
    try {
      await container.read(messagesProvider('chat').future);
      await container
          .read(messagesProvider('chat').notifier)
          .sendVoice(
            '/tmp/recording.m4a',
            2500,
            clientMessageId: 'voice-client',
          );
      final message = container
          .read(messagesProvider('chat'))
          .requireValue
          .single;
      expect(message.kind, MessageKind.voice);
      expect(message.voiceDurationMs, 2500);
      expect(
        (await store.loadMessages('alice', 'chat')).single.kind,
        MessageKind.voice,
      );
    } finally {
      container.dispose();
      await store.close();
    }
  });

  testWidgets('voice message shows playback control', (tester) async {
    final store = ChatLocalStore(executor: NativeDatabase.memory());
    final repository = _MessageRepository(
      messages: [
        ChatMessage(
          id: 'voice-1',
          clientMessageId: 'voice-client',
          conversationId: 'chat',
          senderId: 'bob',
          text: '',
          kind: MessageKind.voice,
          voiceDurationMs: 2500,
          sequence: 1,
          createdAt: DateTime.utc(2026, 10, 13),
          status: MessageStatus.sent,
        ),
      ],
    );
    final container = ProviderContainer(
      overrides: [
        currentUserProvider.overrideWithValue(_account),
        realtimeServiceProvider.overrideWithValue(null),
        chatLocalStoreProvider.overrideWithValue(store),
        messageRepositoryProvider.overrideWithValue(repository),
        conversationRepositoryProvider.overrideWithValue(
          _ConversationRepository(),
        ),
      ],
    );
    try {
      await container.read(conversationDetailProvider('chat').future);
      await container.read(messagesProvider('chat').future);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: ChatPage(conversationId: 'chat')),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('message-voice-1')),
          matching: find.text('3s'),
        ),
        findsOneWidget,
      );
      expect(find.byTooltip('Phát tin nhắn thoại'), findsOneWidget);
      await tester.longPress(find.byTooltip('Phát tin nhắn thoại'));
      await tester.pumpAndSettle();
      final copyTile = tester.widget<ListTile>(
        find.ancestor(
          of: find.text('Sao chép'),
          matching: find.byType(ListTile),
        ),
      );
      expect(copyTile.enabled, isFalse);
      await tester.tap(find.text('Trả lời'));
      await tester.pumpAndSettle();
      expect(find.text('Đang trả lời Bob'), findsOneWidget);
      expect(find.text('🎤 Tin nhắn thoại'), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      await store.close();
    }
  });

  test(
    'failed outgoing message stays queued and retry confirms one bubble',
    () async {
      final store = ChatLocalStore(executor: NativeDatabase.memory());
      final repository = _MessageRepository();
      final firstSend = Completer<ChatMessage>();
      repository
        ..sendStarted = Completer<void>()
        ..nextSendResult = firstSend.future;
      final container = ProviderContainer(
        overrides: [
          currentUserProvider.overrideWithValue(_account),
          realtimeServiceProvider.overrideWithValue(null),
          chatLocalStoreProvider.overrideWithValue(store),
          messageRepositoryProvider.overrideWithValue(repository),
          conversationRepositoryProvider.overrideWithValue(
            _ConversationRepository(),
          ),
        ],
      );
      try {
        await container.read(conversationDetailProvider('chat').future);
        await container.read(messagesProvider('chat').future);
        final notifier = container.read(messagesProvider('chat').notifier);

        final sending = notifier.send('  Hello Bob  ');
        await repository.sendStarted!.future;
        final optimistic = container
            .read(messagesProvider('chat'))
            .requireValue;
        expect(optimistic, hasLength(1));
        expect(optimistic.single.status, MessageStatus.sending);
        expect(optimistic.single.text, 'Hello Bob');
        expect(await store.loadPending('alice'), hasLength(1));

        firstSend.completeError(StateError('offline'));
        await sending;
        final failed = container
            .read(messagesProvider('chat'))
            .requireValue
            .single;
        expect(failed.status, MessageStatus.failed);
        expect(
          (await store.loadPending('alice')).single.status,
          MessageStatus.failed,
        );
        expect(repository.attempts, hasLength(1));
        expect(repository.attempts.single.text, 'Hello Bob');

        repository.nextSendResult = null;
        await notifier.retry(failed.clientMessageId);
        final confirmed = container.read(messagesProvider('chat')).requireValue;
        expect(confirmed, hasLength(1));
        expect(confirmed.single.id, 'server-1');
        expect(confirmed.single.sequence, 12);
        expect(confirmed.single.status, MessageStatus.sent);
        expect(repository.attempts, hasLength(2));
        expect(
          repository.attempts.map((attempt) => attempt.clientMessageId),
          everyElement(failed.clientMessageId),
        );
        expect(repository.attempts.last.conversationId, 'chat');
        expect(await store.loadPending('alice'), isEmpty);
        expect(await store.loadMessages('alice', 'chat'), hasLength(1));

        await notifier.retry(failed.clientMessageId);
        expect(repository.attempts, hasLength(2));
        await container.read(conversationListProvider.notifier).refresh();
      } finally {
        container.dispose();
        await store.close();
      }
    },
  );

  test('message read uses the newest incoming sequence once', () async {
    final store = ChatLocalStore(executor: NativeDatabase.memory());
    final messages = _MessageRepository(
      messages: [
        _message(
          id: 'incoming-4',
          clientMessageId: 'incoming-4',
          senderId: 'bob',
          sequence: 4,
          text: 'First',
        ),
        _message(
          id: 'own-9',
          clientMessageId: 'own-9',
          senderId: 'alice',
          sequence: 9,
          text: 'My message',
        ),
        _message(
          id: 'incoming-7',
          clientMessageId: 'incoming-7',
          senderId: 'bob',
          sequence: 7,
          text: 'Latest',
        ),
      ],
    );
    final conversations = _ReadConversationRepository();
    final container = ProviderContainer(
      overrides: [
        currentUserProvider.overrideWithValue(_account),
        realtimeServiceProvider.overrideWithValue(null),
        chatLocalStoreProvider.overrideWithValue(store),
        messageRepositoryProvider.overrideWithValue(messages),
        conversationRepositoryProvider.overrideWithValue(conversations),
      ],
    );
    try {
      await container.read(conversationDetailProvider('chat').future);
      await container.read(messagesProvider('chat').future);
      expect(container.read(unreadCountProvider), 5);

      final notifier = container.read(messagesProvider('chat').notifier);
      await notifier.markRead();
      expect(conversations.readCalls, [('chat', 7)]);
      final updated = container.read(conversationListProvider).requireValue;
      expect(updated.first.unreadCount, 0);
      expect(updated.first.lastReadSequence, 7);
      expect(updated.last.unreadCount, 2);
      expect(container.read(unreadCountProvider), 2);
      final cachedAfterRead = await store.loadConversations('alice');
      final cachedChat = cachedAfterRead.firstWhere(
        (item) => item.id == 'chat',
      );
      expect(cachedChat.unreadCount, 0);
      expect(cachedChat.lastReadSequence, 7);
      expect(
        cachedAfterRead.firstWhere((item) => item.id == 'other').unreadCount,
        2,
      );

      await container.read(conversationDetailProvider('chat').future);
      await notifier.markRead();
      expect(conversations.readCalls, hasLength(1));

      container
          .read(conversationListProvider.notifier)
          .upsert(updated.first.copyWith(unreadCount: 1));
      expect(container.read(unreadCountProvider), 3);
      expect(
        container.read(conversationListProvider).requireValue,
        hasLength(2),
      );
      await Future<void>.delayed(Duration.zero);
      final cached = await store.loadConversations('alice');
      expect(cached.firstWhere((item) => item.id == 'chat').unreadCount, 1);
    } finally {
      container.dispose();
      await store.close();
    }
  });

  test('read response preserves newer unread conversation update', () async {
    final store = ChatLocalStore(executor: NativeDatabase.memory());
    final conversations = _ReadConversationRepository()
      ..pendingMarkRead = Completer<int>();
    final container = ProviderContainer(
      overrides: [
        currentUserProvider.overrideWithValue(_account),
        realtimeServiceProvider.overrideWithValue(null),
        chatLocalStoreProvider.overrideWithValue(store),
        conversationRepositoryProvider.overrideWithValue(conversations),
      ],
    );
    try {
      await container.read(conversationListProvider.future);
      final notifier = container.read(conversationListProvider.notifier);
      final marking = notifier.markRead('chat', 7);
      notifier.upsert(
        container
            .read(conversationListProvider)
            .requireValue
            .first
            .copyWith(unreadCount: 1),
      );
      conversations.pendingMarkRead!.complete(7);
      await marking;

      final chat = container.read(conversationListProvider).requireValue.first;
      expect(chat.unreadCount, 1);
      expect(chat.lastReadSequence, 7);
      final cached = await store.loadConversations('alice');
      expect(cached.first.unreadCount, 1);
      expect(cached.first.lastReadSequence, 7);
    } finally {
      container.dispose();
      await store.close();
    }
  });

  test(
    'peer read sequence updates outgoing status and cached message',
    () async {
      final store = _ReadAwareStore();
      final messages = _MessageRepository(
        messages: [
          _message(
            id: 'own-12',
            clientMessageId: 'own-12',
            senderId: 'alice',
            sequence: 12,
            text: 'Sent to Bob',
          ),
        ],
      );
      final container = ProviderContainer(
        overrides: [
          currentUserProvider.overrideWithValue(_account),
          realtimeServiceProvider.overrideWithValue(null),
          chatLocalStoreProvider.overrideWithValue(store),
          messageRepositoryProvider.overrideWithValue(messages),
          conversationRepositoryProvider.overrideWithValue(
            _ConversationRepository(),
          ),
        ],
      );
      try {
        await container.read(conversationDetailProvider('chat').future);
        await container.read(messagesProvider('chat').future);
        expect(
          container.read(messagesProvider('chat')).requireValue.single.status,
          MessageStatus.sent,
        );
        expect(
          (await store.loadMessages('alice', 'chat')).single.status,
          MessageStatus.sent,
        );

        container
            .read(conversationListProvider.notifier)
            .upsert(_conversation.copyWith(peerLastReadSequence: 12));
        expect(
          container.read(messagesProvider('chat')).requireValue.single.status,
          MessageStatus.read,
        );
        await store.readPersisted.future.timeout(const Duration(seconds: 2));
        expect(
          (await store.loadMessages('alice', 'chat')).single.status,
          MessageStatus.read,
        );
      } finally {
        container.dispose();
        await store.close();
      }
    },
  );

  testWidgets('chat marks incoming messages read only while at the bottom', (
    tester,
  ) async {
    final store = ChatLocalStore(executor: NativeDatabase.memory());
    final repository = _MessageRepository(
      messages: [
        for (var sequence = 1; sequence <= 30; sequence++)
          _message(
            id: 'message-$sequence',
            clientMessageId: 'client-$sequence',
            senderId: sequence >= 28 ? 'bob' : 'alice',
            sequence: sequence,
            text: 'Message $sequence with enough text to scroll the chat',
          ),
      ],
    );
    final conversations = _ReadConversationRepository();
    final container = ProviderContainer(
      overrides: [
        currentUserProvider.overrideWithValue(_account),
        realtimeServiceProvider.overrideWithValue(null),
        chatLocalStoreProvider.overrideWithValue(store),
        messageRepositoryProvider.overrideWithValue(repository),
        conversationRepositoryProvider.overrideWithValue(conversations),
      ],
    );
    try {
      // Data is ready before the route appears, matching a cached conversation.
      await container.read(conversationDetailProvider('chat').future);
      await container.read(messagesProvider('chat').future);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: ChatPage(conversationId: 'chat')),
        ),
      );
      await tester.pumpAndSettle();
      expect(conversations.readCalls, [('chat', 30)]);

      final list = tester.widget<ListView>(find.byType(ListView));
      final scroll = list.controller!;
      expect(scroll.position.maxScrollExtent, greaterThan(200));
      scroll.jumpTo(200);
      await tester.pump();
      expect(scroll.offset, greaterThan(72));

      repository.messages.add(
        _message(
          id: 'message-31',
          clientMessageId: 'client-31',
          senderId: 'bob',
          sequence: 31,
          text: 'New incoming message',
        ),
      );
      await container.read(messagesProvider('chat').notifier).refresh();
      await tester.pumpAndSettle();
      expect(
        container.read(messagesProvider('chat')).requireValue.last.sequence,
        31,
      );
      expect(conversations.readCalls, [('chat', 30)]);

      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      expect(conversations.readCalls, [('chat', 30), ('chat', 31)]);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      await store.close();
    }
  });

  testWidgets('emoji is sent as text and a message can be hearted', (
    tester,
  ) async {
    final store = ChatLocalStore(executor: NativeDatabase.memory());
    final repository = _MessageRepository(
      messages: [
        _message(
          id: 'incoming-1',
          clientMessageId: 'incoming-1',
          senderId: 'bob',
          sequence: 1,
          text: 'Xin chào',
        ),
      ],
    );
    final container = ProviderContainer(
      overrides: [
        currentUserProvider.overrideWithValue(_account),
        realtimeServiceProvider.overrideWithValue(null),
        chatLocalStoreProvider.overrideWithValue(store),
        messageRepositoryProvider.overrideWithValue(repository),
        conversationRepositoryProvider.overrideWithValue(
          _ConversationRepository(),
        ),
      ],
    );
    try {
      await container.read(conversationDetailProvider('chat').future);
      await container.read(messagesProvider('chat').future);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: ChatPage(conversationId: 'chat')),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is ChatAvatar && widget.name == 'Bob' && widget.size == 32,
        ),
        findsOneWidget,
      );

      await tester.longPress(find.byKey(const ValueKey('message-incoming-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Thả tim'));
      await tester.pumpAndSettle();
      expect(
        container
            .read(messagesProvider('chat'))
            .requireValue
            .firstWhere((message) => message.id == 'incoming-1')
            .heartedBy,
        ['alice'],
      );
      expect(find.byTooltip('Bỏ tim'), findsOneWidget);

      await tester.tap(find.byTooltip('Chọn biểu tượng cảm xúc'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('🥰'));
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '🥰',
      );

      await tester.tap(find.byTooltip('Gửi tin nhắn'));
      await tester.pumpAndSettle();
      expect(repository.attempts.single.text, '🥰');
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is ChatAvatar && widget.name == 'Bob' && widget.size == 32,
        ),
        findsOneWidget,
      );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      await store.close();
    }
  });
}

class _ReadConversationRepository implements ConversationRepository {
  @override
  Future<ChatUser> getUser(String userId) async =>
      ChatUser(id: userId, displayName: 'Bob', email: 'bob@example.com');

  final List<(String, int)> readCalls = [];
  Completer<int>? pendingMarkRead;

  @override
  Future<List<Conversation>> list() async => const [
    Conversation(
      id: 'chat',
      title: 'Bob',
      peerId: 'bob',
      unreadCount: 3,
      lastReadSequence: 1,
    ),
    Conversation(id: 'other', title: 'Cara', peerId: 'cara', unreadCount: 2),
  ];

  @override
  Future<int> markRead(String conversationId, int throughSequence) async {
    readCalls.add((conversationId, throughSequence));
    return pendingMarkRead?.future ?? throughSequence;
  }

  @override
  Future<List<ChatUser>> searchUsers(String query) async => [];

  @override
  Future<Conversation> start(String peerUserId) async => _conversation;
}

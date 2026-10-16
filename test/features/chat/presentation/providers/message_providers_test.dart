import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:appchatdemo/core/database/chat_local_store.dart';
import 'package:appchatdemo/core/database/chat_local_store_provider.dart';
import 'package:appchatdemo/core/media/speech_input.dart';
import 'package:appchatdemo/core/media/speech_input_provider.dart';
import 'package:appchatdemo/core/realtime/realtime_providers.dart';
import 'package:appchatdemo/core/widgets/chat_avatar.dart';
import 'package:appchatdemo/core/theme/app_theme.dart';
import 'package:appchatdemo/features/auth/domain/entities/chat_user.dart';
import 'package:appchatdemo/features/auth/presentation/providers/auth_providers.dart';
import 'package:appchatdemo/features/chat/domain/entities/chat_message.dart';
import 'package:appchatdemo/features/chat/domain/entities/message_page.dart';
import 'package:appchatdemo/features/chat/domain/repositories/message_repository.dart';
import 'package:appchatdemo/features/chat/presentation/pages/chat_page.dart';
import 'package:appchatdemo/features/chat/presentation/providers/message_providers.dart';
import 'package:appchatdemo/features/chat/presentation/providers/attachment_providers.dart';
import 'package:appchatdemo/features/chat/presentation/widgets/attachment_bubble.dart';
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
  List<String> heartedBy = const [],
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
  heartedBy: heartedBy,
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
  Future<ChatMessage>? nextAttachmentResult;
  String? attachmentPath;
  final attachmentAttempts =
      <({String clientId, String text, MessageKind kind})>[];

  @override
  Future<ChatMessage> sendAttachment(
    String conversationId,
    String clientMessageId,
    String filePath,
    String fileName,
    MessageKind kind, {
    String text = '',
    String? replyToMessageId,
  }) async {
    attachmentAttempts.add((clientId: clientMessageId, text: text, kind: kind));
    return nextAttachmentResult ??
        ChatMessage(
          id: 'attachment-server',
          clientMessageId: clientMessageId,
          conversationId: conversationId,
          senderId: 'alice',
          text: text,
          kind: kind,
          attachment: MessageAttachment(
            name: fileName,
            size: 42,
            contentType: 'application/octet-stream',
          ),
          sequence: 14,
          createdAt: DateTime.utc(2026, 10, 16),
          status: MessageStatus.sent,
        );
  }

  @override
  Future<String> downloadAttachment(ChatMessage message) async =>
      attachmentPath ?? '/tmp/${message.attachment!.name}';

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
  Future<ChatMessage> setReaction(
    String messageId,
    MessageReaction reaction, {
    required bool selected,
  }) async {
    final message = messages.singleWhere((item) => item.id == messageId);
    final reactionSets = message.effectiveReactionSets;
    final mine = [...reactionSets['alice'] ?? const <MessageReaction>[]];
    if (selected) {
      if (!mine.contains(reaction)) mine.add(reaction);
    } else {
      mine.remove(reaction);
    }
    if (mine.isEmpty) {
      reactionSets.remove('alice');
    } else {
      reactionSets['alice'] = mine;
    }
    final updated = message.copyWith(
      heartedBy: [
        for (final entry in reactionSets.entries)
          if (entry.value.contains(MessageReaction.heart)) entry.key,
      ],
      reactions: const {},
      reactionSets: reactionSets,
    );
    messages[messages.indexOf(message)] = updated;
    return updated;
  }

  @override
  Future<ChatMessage> recall(String messageId) async {
    final message = messages.singleWhere((item) => item.id == messageId);
    return ChatMessage(
      id: message.id,
      clientMessageId: message.clientMessageId,
      conversationId: message.conversationId,
      senderId: message.senderId,
      text: '',
      sequence: message.sequence,
      createdAt: message.createdAt,
      status: message.status,
      kind: message.kind,
      isRecalled: true,
    );
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

class _AttachmentService extends AttachmentService {
  PickedChatAttachment? selected;
  final pickedImages = <bool>[];
  final opened = <String>[];

  @override
  Future<PickedChatAttachment?> pick({required bool image}) async {
    pickedImages.add(image);
    return selected;
  }

  @override
  Future<void> open(String path) async => opened.add(path);
}

class _ConversationRepository implements ConversationRepository {
  @override
  Future<int> markDelivered(String conversationId, int throughSequence) async =>
      throughSequence;

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
  final deliveredPersisted = Completer<void>();

  @override
  Future<void> upsertMessages(
    String accountId,
    Iterable<ChatMessage> messages,
  ) async {
    await super.upsertMessages(accountId, messages);
    if (messages.any((message) => message.status == MessageStatus.delivered) &&
        !deliveredPersisted.isCompleted) {
      deliveredPersisted.complete();
    }
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
  testWidgets(
    'attachment picker keeps failed upload and retries without duplicating',
    (tester) async {
      final store = ChatLocalStore(executor: NativeDatabase.memory());
      final repository = _MessageRepository();
      final attachments = _AttachmentService()
        ..selected = PickedChatAttachment(
          path: '/tmp/ke-hoach.pdf',
          metadata: const MessageAttachment(
            name: 'ke-hoach.pdf',
            size: 42,
            contentType: 'application/octet-stream',
          ),
          kind: MessageKind.file,
        );
      final container = ProviderContainer(
        overrides: [
          currentUserProvider.overrideWithValue(_account),
          realtimeServiceProvider.overrideWithValue(null),
          chatLocalStoreProvider.overrideWithValue(store),
          messageRepositoryProvider.overrideWithValue(repository),
          attachmentServiceProvider.overrideWithValue(attachments),
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
        await tester.tap(find.byTooltip('Đính kèm ảnh hoặc tệp'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('attach-file')));
        await tester.pumpAndSettle();
        expect(attachments.pickedImages, [false]);
        expect(find.text('ke-hoach.pdf'), findsOneWidget);
        expect(find.byKey(const ValueKey('open-voice-panel')), findsNothing);
        await tester.enterText(find.byType(TextField), 'Bản kế hoạch mới');
        final failure = Completer<ChatMessage>();
        repository.nextAttachmentResult = failure.future;
        await tester.tap(find.byTooltip('Gửi tệp đính kèm'));
        await tester.pump();
        failure.completeError(StateError('offline'));
        await tester.pumpAndSettle();
        expect(find.text('Chưa gửi · Bấm gửi để thử lại'), findsOneWidget);
        expect(
          tester.widget<TextField>(find.byType(TextField)).readOnly,
          isTrue,
        );
        repository.nextAttachmentResult = null;
        await tester.tap(find.byTooltip('Gửi tệp đính kèm'));
        await tester.pumpAndSettle();
        expect(repository.attachmentAttempts, hasLength(2));
        expect(
          repository.attachmentAttempts[0],
          repository.attachmentAttempts[1],
        );
        final message = container
            .read(messagesProvider('chat'))
            .requireValue
            .single;
        expect(message.text, 'Bản kế hoạch mới');
        expect(message.attachment?.name, 'ke-hoach.pdf');
        expect(
          (await store.loadMessages('alice', 'chat')).single.attachment?.size,
          42,
        );
        expect(find.byTooltip('Đính kèm ảnh hoặc tệp'), findsOneWidget);
        await tester.tap(
          find.byKey(const ValueKey('attachment-attachment-server')),
        );
        await tester.pumpAndSettle();
        expect(attachments.opened, ['/tmp/ke-hoach.pdf']);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
        await store.close();
      }
    },
  );
  testWidgets(
    'received image opens a zoom viewer in dark mode on a small phone',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final directory = Directory.systemTemp.createTempSync(
        'chat-image-widget-',
      );
      final imageFile = File('${directory.path}/photo.png')
        ..writeAsBytesSync(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGMQTr32HwAEKwJOk+jLUgAAAABJRU5ErkJggg==',
          ),
        );
      final message = ChatMessage(
        id: 'image-received',
        clientMessageId: 'image-client',
        conversationId: 'chat',
        senderId: 'bob',
        text: 'Ảnh mới',
        sequence: 1,
        kind: MessageKind.image,
        createdAt: DateTime.utc(2026, 10, 16),
        status: MessageStatus.sent,
        attachment: MessageAttachment(
          name: 'photo.png',
          size: imageFile.lengthSync(),
          contentType: 'image/png',
        ),
      );
      final store = ChatLocalStore(executor: NativeDatabase.memory());
      final repository = _MessageRepository(messages: [message])
        ..attachmentPath = imageFile.path;
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
            child: MaterialApp(
              theme: AppTheme.dark,
              home: Scaffold(
                body: Center(
                  child: AttachmentBubble(message: message, isMine: false),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.runAsync(
          () => precacheImage(
            FileImage(imageFile),
            tester.element(find.byType(AttachmentBubble)),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('attachment-image-received')),
          findsOneWidget,
        );
        await tester.tap(
          find.byKey(const ValueKey('attachment-image-received')),
        );
        await tester.pumpAndSettle();
        expect(find.byType(InteractiveViewer), findsOneWidget);
        expect(find.byTooltip('Đóng ảnh'), findsOneWidget);
        await tester.tap(find.byTooltip('Đóng ảnh'));
        await tester.pumpAndSettle();
        expect(find.byType(InteractiveViewer), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
        await store.close();
        directory.deleteSync(recursive: true);
      }
    },
  );

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
      await tester.tap(find.byKey(const ValueKey('open-voice-panel')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Gửi dạng văn bản'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Chào');
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
      await tester.tap(find.byKey(const ValueKey('open-voice-panel')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Gửi dạng văn bản'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Bản nháp');
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
      expect(find.byKey(const ValueKey('reaction-heart')), findsOneWidget);
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

  testWidgets(
    'sender can recall a message and its cached bubble stays recalled',
    (tester) async {
      final store = ChatLocalStore(executor: NativeDatabase.memory());
      final repository = _MessageRepository(
        messages: [
          _message(
            id: 'mine',
            clientMessageId: 'mine-client',
            senderId: 'alice',
            sequence: 1,
            text: 'Private text',
          ),
          _message(
            id: 'theirs',
            clientMessageId: 'theirs-client',
            senderId: 'bob',
            sequence: 2,
            text: 'Bob text',
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
        await tester.longPress(find.byKey(const ValueKey('message-theirs')));
        await tester.pumpAndSettle();
        expect(find.text('Thu hồi tin nhắn'), findsNothing);
        await tester.tapAt(const Offset(10, 10));
        await tester.pumpAndSettle();
        await tester.longPress(find.byKey(const ValueKey('message-mine')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Thu hồi tin nhắn'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Thu hồi').last);
        await tester.pumpAndSettle();
        expect(find.text('Private text'), findsNothing);
        expect(find.text('Tin nhắn đã thu hồi'), findsOneWidget);
        final cached = await store.loadMessages('alice', 'chat');
        expect(cached.first.isRecalled, isTrue);
        expect(cached.first.text, isEmpty);
        await tester.longPress(find.byKey(const ValueKey('message-mine')));
        await tester.pumpAndSettle();
        expect(find.text('Thu hồi tin nhắn'), findsNothing);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
        await store.close();
      }
    },
  );

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
    'peer delivery and read cursors advance outgoing status and cache',
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
            .upsert(_conversation.copyWith(peerLastDeliveredSequence: 12));
        expect(
          container.read(messagesProvider('chat')).requireValue.single.status,
          MessageStatus.delivered,
        );
        await store.deliveredPersisted.future.timeout(
          const Duration(seconds: 2),
        );
        expect(
          (await store.loadMessages('alice', 'chat')).single.status,
          MessageStatus.delivered,
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
      await tester.tap(find.byKey(const ValueKey('reaction-heart')));
      await tester.pumpAndSettle();
      expect(
        container
            .read(messagesProvider('chat'))
            .requireValue
            .firstWhere((message) => message.id == 'incoming-1')
            .heartedBy,
        ['alice'],
      );
      expect(find.byTooltip('Đổi cảm xúc'), findsOneWidget);

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

  testWidgets(
    'reactions show distinct icons and a total at the bubble corner',
    (tester) async {
      final store = ChatLocalStore(executor: NativeDatabase.memory());
      final repository = _MessageRepository(
        messages: [
          _message(
            id: 'mine',
            clientMessageId: 'mine',
            senderId: 'alice',
            sequence: 1,
            text: 'Chào bạn',
            heartedBy: ['alice', 'bob'],
          ),
          _message(
            id: 'theirs',
            clientMessageId: 'theirs',
            senderId: 'bob',
            sequence: 2,
            text: 'Chào',
            heartedBy: ['bob'],
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

        for (final (messageId, count) in [('mine', 2), ('theirs', 1)]) {
          final badge = find.byKey(ValueKey('message-hearts-$messageId'));
          final icons = find.descendant(
            of: badge,
            matching: find.byIcon(Icons.favorite_rounded),
          );
          expect(icons, findsOneWidget);
          if (count > 1) {
            expect(
              find.descendant(of: badge, matching: find.text('$count')),
              findsOneWidget,
            );
          }
          for (final icon in tester.widgetList<Icon>(icons)) {
            expect(icon.color, const Color(0xFFE53935));
          }

          final bubbleRect = tester.getRect(
            find.byKey(ValueKey('message-$messageId')),
          );
          final badgeRect = tester.getRect(badge);
          expect(badgeRect.right, lessThanOrEqualTo(bubbleRect.right));
          expect(badgeRect.right, greaterThan(bubbleRect.right - 16));
          expect(badgeRect.top, lessThan(bubbleRect.bottom));
          expect(badgeRect.bottom, greaterThan(bubbleRect.bottom));
        }

        await tester.longPress(find.byKey(const ValueKey('message-mine')));
        await tester.pumpAndSettle();
        final reactionButtons = [
          for (final reaction in MessageReaction.values)
            find.byKey(ValueKey('reaction-${reaction.name}')),
        ];
        for (final button in reactionButtons) {
          expect(button, findsOneWidget);
          expect(
            tester.getCenter(button).dy,
            tester.getCenter(reactionButtons.first).dy,
          );
        }
        await tester.tap(find.byKey(const ValueKey('reaction-like')));
        await tester.pumpAndSettle();
        final updated = container
            .read(messagesProvider('chat'))
            .requireValue
            .singleWhere((message) => message.id == 'mine');
        expect(
          updated.effectiveReactionSets['alice'],
          containsAll([MessageReaction.heart, MessageReaction.like]),
        );
        expect(updated.effectiveReactions['bob'], MessageReaction.heart);
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('message-hearts-mine')),
            matching: find.text('👍'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('message-hearts-mine')),
            matching: find.text('3'),
          ),
          findsOneWidget,
        );
        final mineBadge = find.byKey(const ValueKey('message-hearts-mine'));
        final heartIcon = find.descendant(
          of: mineBadge,
          matching: find.byIcon(Icons.favorite_rounded),
        );
        final likeIcon = find.descendant(
          of: mineBadge,
          matching: find.text('👍'),
        );
        expect(
          tester.getTopLeft(likeIcon).dx - tester.getTopRight(heartIcon).dx,
          lessThanOrEqualTo(4),
        );

        await tester.longPress(find.byKey(const ValueKey('message-mine')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('reaction-laugh')));
        await tester.pumpAndSettle();
        expect(
          container
              .read(messagesProvider('chat'))
              .requireValue
              .singleWhere((message) => message.id == 'mine')
              .effectiveReactionSets['alice'],
          containsAll([
            MessageReaction.heart,
            MessageReaction.like,
            MessageReaction.laugh,
          ]),
        );

        await tester.longPress(find.byKey(const ValueKey('message-mine')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('reaction-like')));
        await tester.pumpAndSettle();
        expect(
          container
              .read(messagesProvider('chat'))
              .requireValue
              .singleWhere((message) => message.id == 'mine')
              .effectiveReactionSets['alice'],
          containsAll([MessageReaction.heart, MessageReaction.laugh]),
        );

        await tester.longPress(find.byKey(const ValueKey('message-mine')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('reaction-heart')));
        await tester.pumpAndSettle();
        expect(
          container
              .read(messagesProvider('chat'))
              .requireValue
              .singleWhere((message) => message.id == 'mine')
              .effectiveReactionSets['alice'],
          [MessageReaction.laugh],
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
        await store.close();
      }
    },
  );
}

class _ReadConversationRepository implements ConversationRepository {
  @override
  Future<int> markDelivered(String conversationId, int throughSequence) async =>
      throughSequence;

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

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/database/chat_local_store.dart';
import '../../../../core/database/chat_local_store_provider.dart';
import '../../../../core/network/api_exception.dart';
import '../../../../core/realtime/realtime_providers.dart';
import '../../../../core/realtime/realtime_service.dart';
import '../../../auth/presentation/providers/auth_providers.dart';
import '../../../conversations/presentation/providers/conversation_providers.dart';
import '../../data/models/message_mapper.dart';
import '../../data/repositories/remote_message_repository.dart';
import '../../domain/entities/chat_message.dart';
import '../../domain/repositories/message_repository.dart';

final messageRepositoryProvider = Provider<MessageRepository>((ref) {
  return RemoteMessageRepository(
    ref.watch(apiClientProvider).dio,
    ref.watch(currentUserProvider)?.id,
  );
});

final messagesProvider =
    AsyncNotifierProvider.family<MessagesNotifier, List<ChatMessage>, String>(
      MessagesNotifier.new,
    );

class MessagesNotifier extends AsyncNotifier<List<ChatMessage>> {
  MessagesNotifier(this.conversationId);

  final String conversationId;
  StreamSubscription<RealtimeEvent>? _subscription;
  int? _nextCursor;
  bool _loadingOlder = false;
  bool _loadingInitial = false;

  bool get hasMore => _nextCursor != null;
  bool get isLoadingOlder => _loadingOlder;

  String? get _accountId => ref.read(currentUserProvider)?.id;

  @override
  Future<List<ChatMessage>> build() async {
    _loadingInitial = true;
    final accountId = ref.watch(currentUserProvider)?.id;
    final service = ref.watch(realtimeServiceProvider);
    _subscription?.cancel();
    _subscription = service?.events.listen(_handleEvent);
    ref.onDispose(() => _subscription?.cancel());
    ref.listen(conversationListProvider, (_, next) {
      final conversations = next.asData?.value;
      if (conversations == null) return;
      for (final conversation in conversations) {
        if (conversation.id == conversationId) {
          _applyPeerRead(conversation.peerLastReadSequence);
          break;
        }
      }
    });
    if (accountId == null) {
      _loadingInitial = false;
      return const [];
    }

    final store = ref.read(chatLocalStoreProvider);
    final cached = await store.loadMessages(accountId, conversationId);
    if (cached.isNotEmpty) state = AsyncData(cached);
    try {
      final page = await ref
          .read(messageRepositoryProvider)
          .fetchPage(conversationId);
      _nextCursor = page.nextCursor;
      await store.upsertMessages(accountId, page.items);
      final merged = _merge([...cached, ...?state.asData?.value], page.items);
      _loadingInitial = false;
      return merged;
    } catch (_) {
      final current = state.asData?.value ?? const <ChatMessage>[];
      if (cached.isNotEmpty || current.isNotEmpty) {
        final merged = _merge(cached, current);
        _loadingInitial = false;
        return merged;
      }
      _loadingInitial = false;
      rethrow;
    }
  }

  Future<void> refresh() async {
    final accountId = _accountId;
    if (accountId == null) return;
    try {
      final page = await ref
          .read(messageRepositoryProvider)
          .fetchPage(conversationId);
      _nextCursor = page.nextCursor;
      await ref
          .read(chatLocalStoreProvider)
          .upsertMessages(accountId, page.items);
      final merged = _merge(state.asData?.value ?? const [], page.items);
      state = AsyncData(merged);
    } catch (error, stackTrace) {
      if (state.asData?.value == null) state = AsyncError(error, stackTrace);
    }
  }

  Future<void> loadOlder() async {
    final cursor = _nextCursor;
    final accountId = _accountId;
    if (cursor == null || accountId == null || _loadingOlder) return;
    _loadingOlder = true;
    try {
      final page = await ref
          .read(messageRepositoryProvider)
          .fetchPage(conversationId, beforeSequence: cursor);
      _nextCursor = page.nextCursor;
      await ref
          .read(chatLocalStoreProvider)
          .upsertMessages(accountId, page.items);
      final merged = _merge(state.asData?.value ?? const [], page.items);
      state = AsyncData(merged);
    } finally {
      _loadingOlder = false;
    }
  }

  Future<void> send(String text, {MessageReply? replyTo}) async {
    final body = text.trim();
    final accountId = _accountId;
    if (body.isEmpty || accountId == null) return;
    if (body.length > 4000) {
      throw const ApiException('Tin nhắn tối đa 4.000 ký tự.');
    }
    final id = const Uuid().v4();
    final pending = ChatMessage(
      id: id,
      clientMessageId: id,
      conversationId: conversationId,
      senderId: accountId,
      text: body,
      sequence: 0,
      createdAt: DateTime.now().toUtc(),
      status: MessageStatus.sending,
      replyTo: replyTo,
    );
    await ref.read(chatLocalStoreProvider).enqueueOutgoing(accountId, pending);
    state = AsyncData(_merge(state.asData?.value ?? const [], [pending]));
    await _sendPending(pending);
  }

  Future<void> sendVoice(
    String filePath,
    int durationMs, {
    required String clientMessageId,
    MessageReply? replyTo,
  }) async {
    final accountId = _accountId;
    if (accountId == null) throw StateError('Sign in to send voice messages');
    final message = await ref
        .read(messageRepositoryProvider)
        .sendVoice(
          conversationId,
          clientMessageId,
          filePath,
          durationMs,
          replyToMessageId: replyTo?.id,
        );
    await ref.read(chatLocalStoreProvider).upsertMessage(accountId, message);
    state = AsyncData(_merge(state.asData?.value ?? const [], [message]));
    unawaited(
      ref
          .read(conversationListProvider.notifier)
          .refresh()
          .catchError((Object _) {}),
    );
  }

  Future<void> retry(String clientMessageId) async {
    final accountId = _accountId;
    if (accountId == null) return;
    final pending =
        (await ref.read(chatLocalStoreProvider).loadPending(accountId))
            .where((message) => message.clientMessageId == clientMessageId)
            .firstOrNull;
    if (pending == null) return;
    await ref.read(chatLocalStoreProvider).enqueueOutgoing(accountId, pending);
    state = AsyncData(
      _merge(state.asData?.value ?? const [], [
        pending.copyWith(status: MessageStatus.sending),
      ]),
    );
    await _sendPending(pending);
  }

  Future<void> setHeart(ChatMessage message, {required bool hearted}) async {
    if (message.sequence == 0) return;
    final updated = await ref
        .read(messageRepositoryProvider)
        .setHeart(message.id, hearted: hearted);
    _applyUpdatedMessage(updated);
  }

  void _applyUpdatedMessage(ChatMessage updated) {
    if (updated.conversationId != conversationId) return;
    final current = state.asData?.value;
    if (current == null) return;
    final index = current.indexWhere((message) => message.id == updated.id);
    if (index < 0) return;
    final message = updated.copyWith(status: current[index].status);
    state = AsyncData([
      ...current.take(index),
      message,
      ...current.skip(index + 1),
    ]);
    final accountId = _accountId;
    if (accountId != null) {
      unawaited(
        ref.read(chatLocalStoreProvider).upsertMessage(accountId, message),
      );
    }
  }

  Future<void> _sendPending(ChatMessage pending) async {
    final accountId = _accountId;
    if (accountId == null) return;
    try {
      final sent = await ref
          .read(messageRepositoryProvider)
          .send(
            conversationId,
            pending.clientMessageId,
            pending.text,
            replyToMessageId: pending.replyTo?.id,
          );
      await ref
          .read(chatLocalStoreProvider)
          .markSent(accountId, pending.clientMessageId, sent);
      state = AsyncData(_merge(state.asData?.value ?? const [], [sent]));
      unawaited(ref.read(conversationListProvider.notifier).refresh());
    } catch (_) {
      await ref
          .read(chatLocalStoreProvider)
          .markFailed(accountId, conversationId, pending.clientMessageId);
      state = AsyncData(
        _merge(state.asData?.value ?? const [], [
          pending.copyWith(status: MessageStatus.failed),
        ]),
      );
    }
  }

  Future<void> markRead() async {
    final accountId = _accountId;
    if (accountId == null) return;
    final messages = state.asData?.value ?? const <ChatMessage>[];
    var sequence = 0;
    for (final message in messages) {
      if (message.senderId != accountId && message.sequence > sequence) {
        sequence = message.sequence;
      }
    }
    if (sequence == 0) return;
    final conversation = ref.read(conversationDetailProvider(conversationId));
    if ((conversation.asData?.value.lastReadSequence ?? 0) >= sequence) return;
    await ref
        .read(conversationListProvider.notifier)
        .markRead(conversationId, sequence);
  }

  void _handleEvent(RealtimeEvent event) {
    if (event is MessageCreatedEvent &&
        event.payload['conversationId'] == conversationId) {
      final message = messageFromJson(event.payload);
      final accountId = _accountId;
      if (accountId != null) {
        unawaited(
          ref.read(chatLocalStoreProvider).upsertMessage(accountId, message),
        );
      }
      state = AsyncData(_merge(state.asData?.value ?? const [], [message]));
    } else if (event is MessageUpdatedEvent) {
      _applyUpdatedMessage(messageFromJson(event.payload));
    } else if (event is MessageReadEvent &&
        event.payload['conversationId'] == conversationId &&
        event.payload['userId'] != _accountId) {
      final sequence =
          (event.payload['lastReadSequence'] as num?)?.toInt() ?? 0;
      _applyPeerRead(sequence);
    } else if (event is ReconnectedEvent) {
      if (!_loadingInitial) unawaited(refresh());
    }
  }

  void _applyPeerRead(int sequence) {
    final accountId = _accountId;
    final current = state.asData?.value;
    if (accountId == null || current == null || sequence <= 0) return;
    var changed = false;
    final updated = <ChatMessage>[];
    for (final message in current) {
      if (message.senderId == accountId &&
          message.sequence > 0 &&
          message.sequence <= sequence &&
          message.status != MessageStatus.read) {
        updated.add(message.copyWith(status: MessageStatus.read));
        changed = true;
      } else {
        updated.add(message);
      }
    }
    if (!changed) return;
    state = AsyncData(updated);
    unawaited(
      ref.read(chatLocalStoreProvider).upsertMessages(accountId, updated),
    );
  }

  List<ChatMessage> _merge(
    Iterable<ChatMessage> current,
    Iterable<ChatMessage> incoming,
  ) {
    final byClientId = <(String, String, String), ChatMessage>{};
    for (final message in [...current, ...incoming]) {
      final key = (
        message.conversationId,
        message.senderId,
        message.clientMessageId,
      );
      final previous = byClientId[key];
      if (previous == null ||
          message.sequence > previous.sequence ||
          (message.sequence == previous.sequence &&
              _statusRank(message.status) >= _statusRank(previous.status))) {
        byClientId[key] = message;
      }
    }
    final list = byClientId.values.toList()
      ..sort((a, b) {
        if (a.sequence == 0 && b.sequence != 0) return 1;
        if (b.sequence == 0 && a.sequence != 0) return -1;
        if (a.sequence != b.sequence) return a.sequence.compareTo(b.sequence);
        return a.createdAt.compareTo(b.createdAt);
      });
    final peerRead =
        ref
            .read(conversationDetailProvider(conversationId))
            .asData
            ?.value
            .peerLastReadSequence ??
        0;
    final accountId = _accountId;
    return List.unmodifiable([
      for (final message in list)
        if (message.senderId == accountId &&
            message.sequence > 0 &&
            message.sequence <= peerRead)
          message.copyWith(status: MessageStatus.read)
        else
          message,
    ]);
  }

  int _statusRank(MessageStatus status) => switch (status) {
    MessageStatus.sending => 0,
    MessageStatus.failed => 0,
    MessageStatus.sent => 1,
    MessageStatus.delivered => 2,
    MessageStatus.read => 3,
  };
}

final outboxSyncProvider = Provider<OutboxSync?>((ref) {
  final accountId = ref.watch(currentUserProvider)?.id;
  final service = ref.watch(realtimeServiceProvider);
  if (accountId == null || service == null) return null;
  final sync = OutboxSync(
    accountId,
    ref.watch(chatLocalStoreProvider),
    ref.watch(messageRepositoryProvider),
    service,
    (conversationId) => ref.invalidate(messagesProvider(conversationId)),
  );
  unawaited(sync.flush());
  ref.onDispose(sync.dispose);
  return sync;
});

class OutboxSync {
  OutboxSync(
    this._accountId,
    this._store,
    this._repository,
    RealtimeService service,
    this._onSent,
  ) {
    _subscription = service.events.listen((event) {
      if (event is ReconnectedEvent) unawaited(flush());
    });
  }

  final String _accountId;
  final ChatLocalStore _store;
  final MessageRepository _repository;
  final void Function(String conversationId) _onSent;
  late final StreamSubscription<RealtimeEvent> _subscription;
  bool _flushing = false;

  Future<void> flush() async {
    if (_flushing) return;
    _flushing = true;
    try {
      for (final message in await _store.loadPending(_accountId)) {
        try {
          final sent = await _repository.send(
            message.conversationId,
            message.clientMessageId,
            message.text,
            replyToMessageId: message.replyTo?.id,
          );
          await _store.markSent(_accountId, message.clientMessageId, sent);
          _onSent(message.conversationId);
        } catch (_) {
          await _store.markFailed(
            _accountId,
            message.conversationId,
            message.clientMessageId,
          );
          _onSent(message.conversationId);
        }
      }
    } finally {
      _flushing = false;
    }
  }

  void dispose() => unawaited(_subscription.cancel());
}

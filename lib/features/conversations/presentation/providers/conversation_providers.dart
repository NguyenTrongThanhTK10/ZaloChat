import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/database/chat_local_store_provider.dart';
import '../../../../core/realtime/realtime_providers.dart';
import '../../../../core/realtime/realtime_service.dart';
import '../../../auth/domain/entities/chat_user.dart';
import '../../../auth/presentation/providers/auth_providers.dart';
import '../../../chat/data/models/message_mapper.dart';
import '../../../chat/data/repositories/remote_message_repository.dart';
import '../../data/models/conversation_mapper.dart';
import '../../data/repositories/remote_conversation_repository.dart';
import '../../domain/entities/conversation.dart';
import '../../domain/repositories/conversation_repository.dart';

final conversationRepositoryProvider = Provider<ConversationRepository>((ref) {
  return RemoteConversationRepository(ref.watch(apiClientProvider).dio);
});

final conversationListProvider =
    AsyncNotifierProvider<ConversationListNotifier, List<Conversation>>(
      ConversationListNotifier.new,
    );

final conversationDetailProvider = FutureProvider.family<Conversation, String>((
  ref,
  id,
) async {
  final items = await ref.watch(conversationListProvider.future);
  for (final item in items) {
    if (item.id == id) return item;
  }
  throw StateError('Không tìm thấy cuộc trò chuyện.');
});

final userSearchProvider = FutureProvider.family<List<ChatUser>, String>(
  (ref, query) => ref.watch(conversationRepositoryProvider).searchUsers(query),
);

final userDetailProvider = FutureProvider.family<ChatUser, String>(
  (ref, id) => ref.watch(conversationRepositoryProvider).getUser(id),
);

final unreadCountProvider = Provider<int>((ref) {
  final items = ref.watch(conversationListProvider).asData?.value ?? const [];
  return items.fold<int>(0, (count, item) => count + item.unreadCount);
});

class ConversationListNotifier extends AsyncNotifier<List<Conversation>> {
  StreamSubscription<RealtimeEvent>? _subscription;
  final _updatesDuringLoad = <String, Conversation>{};
  bool _loadingRemote = false;

  @override
  Future<List<Conversation>> build() async {
    _loadingRemote = true;
    _updatesDuringLoad.clear();
    final service = ref.watch(realtimeServiceProvider);
    _subscription?.cancel();
    _subscription = service?.events.listen(_handleEvent);
    ref.onDispose(() => _subscription?.cancel());
    final accountId = ref.watch(currentUserProvider)?.id;
    if (accountId == null) {
      _loadingRemote = false;
      return const [];
    }
    final store = ref.read(chatLocalStoreProvider);
    final cached = await store.loadConversations(accountId);
    if (cached.isNotEmpty) state = AsyncData(_mergeUpdates(cached));
    try {
      final remote = await ref.read(conversationRepositoryProvider).list();
      await store.replaceConversations(accountId, remote);
      final updates = _updatesDuringLoad.values.toList();
      final merged = _mergeUpdates(remote, clear: true);
      _loadingRemote = false;
      unawaited(_syncIncoming(merged));
      if (updates.isNotEmpty) {
        unawaited(store.upsertConversations(accountId, updates));
      }
      return merged;
    } catch (_) {
      _loadingRemote = false;
      if (cached.isNotEmpty || _updatesDuringLoad.isNotEmpty) {
        return _mergeUpdates(cached, clear: true);
      }
      rethrow;
    }
  }

  void _handleEvent(RealtimeEvent event) {
    if (event is ConversationUpdatedEvent) {
      try {
        upsert(conversationFromJson(event.payload));
      } catch (_) {
        unawaited(refresh());
      }
    } else if (event is MessageCreatedEvent) {
      unawaited(_receiveIncoming(event.payload));
    } else if (event is ReconnectedEvent) {
      if (!_loadingRemote) unawaited(refresh());
    }
  }

  void upsert(Conversation conversation) {
    final current = state.asData?.value;
    final previous = current
        ?.where((item) => item.id == conversation.id)
        .firstOrNull;
    if (previous != null) {
      conversation = _preserveCursors(conversation, previous);
    }
    if (_loadingRemote) _updatesDuringLoad[conversation.id] = conversation;
    final updated =
        [conversation, ...?current?.where((item) => item.id != conversation.id)]
          ..sort((a, b) {
            if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
            final aTime =
                a.lastMessageAt ?? DateTime.fromMillisecondsSinceEpoch(0);
            final bTime =
                b.lastMessageAt ?? DateTime.fromMillisecondsSinceEpoch(0);
            return bTime.compareTo(aTime);
          });
    state = AsyncData(List.unmodifiable(updated));
    final accountId = ref.read(currentUserProvider)?.id;
    if (accountId != null) {
      unawaited(
        ref
            .read(chatLocalStoreProvider)
            .upsertConversation(accountId, conversation),
      );
    }
  }

  Future<void> refresh() async {
    final accountId = ref.read(currentUserProvider)?.id;
    if (accountId == null) return;
    _loadingRemote = true;
    _updatesDuringLoad.clear();
    try {
      final remote = await ref.read(conversationRepositoryProvider).list();
      await ref
          .read(chatLocalStoreProvider)
          .replaceConversations(accountId, remote);
      final updates = _updatesDuringLoad.values.toList();
      final merged = _mergeUpdates(remote, clear: true);
      _loadingRemote = false;
      state = AsyncData(merged);
      unawaited(_syncIncoming(merged));
      if (updates.isNotEmpty) {
        unawaited(
          ref
              .read(chatLocalStoreProvider)
              .upsertConversations(accountId, updates),
        );
      }
    } catch (error, stackTrace) {
      if (state.asData?.value == null) state = AsyncError(error, stackTrace);
    } finally {
      _loadingRemote = false;
    }
  }

  Future<Conversation> start(String peerUserId) async {
    try {
      await future;
    } catch (_) {
      // A new conversation can recover from a failed inbox load.
    }
    final conversation = await ref
        .read(conversationRepositoryProvider)
        .start(peerUserId);
    upsert(conversation);
    final accountId = ref.read(currentUserProvider)?.id;
    if (accountId != null) {
      await ref
          .read(chatLocalStoreProvider)
          .upsertConversation(accountId, conversation);
    }
    return conversation;
  }

  Future<void> markRead(String id, int throughSequence) async {
    final before = state.asData?.value
        .where((conversation) => conversation.id == id)
        .firstOrNull;
    final sequence = await ref
        .read(conversationRepositoryProvider)
        .markRead(id, throughSequence);
    final current = state.asData?.value;
    if (current == null) return;
    final updated = [
      for (final conversation in current)
        if (conversation.id == id)
          conversation.copyWith(
            // A newer conversation event may include unread messages that
            // arrived while this request was in flight.
            unreadCount: identical(conversation, before)
                ? 0
                : conversation.unreadCount,
            lastReadSequence: conversation.lastReadSequence > sequence
                ? conversation.lastReadSequence
                : sequence,
            lastDeliveredSequence: conversation.lastDeliveredSequence > sequence
                ? conversation.lastDeliveredSequence
                : sequence,
          )
        else
          conversation,
    ];
    state = AsyncData(updated);
    final accountId = ref.read(currentUserProvider)?.id;
    if (accountId != null) {
      for (final conversation in updated) {
        if (conversation.id == id) {
          await ref
              .read(chatLocalStoreProvider)
              .upsertConversation(accountId, conversation);
          break;
        }
      }
    }
  }

  Future<void> markDelivered(String id, int throughSequence) async {
    if (!ref.mounted) return;
    final accountId = ref.read(currentUserProvider)?.id;
    if (accountId == null) return;
    final sequence = await ref
        .read(conversationRepositoryProvider)
        .markDelivered(id, throughSequence);
    if (!ref.mounted) return;
    final current = state.asData?.value;
    if (current == null) return;
    for (final conversation in current) {
      if (conversation.id != id) continue;
      if (conversation.lastDeliveredSequence >= sequence) return;
      upsert(conversation.copyWith(lastDeliveredSequence: sequence));
      return;
    }
  }

  Future<void> _receiveIncoming(Map<String, dynamic> payload) async {
    if (!ref.mounted) return;
    final accountId = ref.read(currentUserProvider)?.id;
    if (accountId == null || payload['senderId'] == accountId) return;
    try {
      final message = messageFromJson(payload);
      await ref.read(chatLocalStoreProvider).upsertMessage(accountId, message);
      if (!ref.mounted) return;
      await markDelivered(message.conversationId, message.sequence);
    } catch (_) {
      // A reconnect refresh will retry any missed acknowledgement.
    }
  }

  Future<void> _syncIncoming(List<Conversation> conversations) async {
    if (!ref.mounted) return;
    if (ref.read(realtimeServiceProvider) == null) return;
    final accountId = ref.read(currentUserProvider)?.id;
    if (accountId == null) return;
    final repository = RemoteMessageRepository(
      ref.read(apiClientProvider).dio,
      accountId,
    );
    for (final conversation in conversations) {
      if (!ref.mounted) return;
      if (conversation.unreadCount == 0) continue;
      try {
        int? beforeSequence;
        while (true) {
          final page = await repository.fetchPage(
            conversation.id,
            beforeSequence: beforeSequence,
          );
          if (!ref.mounted) return;
          await ref
              .read(chatLocalStoreProvider)
              .upsertMessages(accountId, page.items);
          if (!ref.mounted) return;
          final newestIncoming = page.items
              .where((message) => message.senderId != accountId)
              .firstOrNull;
          if (newestIncoming != null) {
            if (newestIncoming.sequence > conversation.lastDeliveredSequence) {
              await markDelivered(conversation.id, newestIncoming.sequence);
            }
            break;
          }
          beforeSequence = page.nextCursor;
          if (beforeSequence == null) break;
        }
      } catch (_) {
        // Keep existing cursor; the next refresh or reconnect retries.
      }
    }
  }

  List<Conversation> _mergeUpdates(
    List<Conversation> base, {
    bool clear = false,
  }) {
    final byId = {
      for (final conversation in base) conversation.id: conversation,
    };
    for (final entry in _updatesDuringLoad.entries) {
      final previous = byId[entry.key];
      byId[entry.key] = previous == null
          ? entry.value
          : _preserveCursors(entry.value, previous);
    }
    if (clear) _updatesDuringLoad.clear();
    final updated = byId.values.toList()
      ..sort((a, b) {
        if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
        final aTime = a.lastMessageAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bTime = b.lastMessageAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return bTime.compareTo(aTime);
      });
    return List.unmodifiable(updated);
  }

  Conversation _preserveCursors(Conversation value, Conversation previous) =>
      value.copyWith(
        lastReadSequence: previous.lastReadSequence > value.lastReadSequence
            ? previous.lastReadSequence
            : value.lastReadSequence,
        peerLastReadSequence:
            previous.peerLastReadSequence > value.peerLastReadSequence
            ? previous.peerLastReadSequence
            : value.peerLastReadSequence,
        lastDeliveredSequence:
            previous.lastDeliveredSequence > value.lastDeliveredSequence
            ? previous.lastDeliveredSequence
            : value.lastDeliveredSequence,
        peerLastDeliveredSequence:
            previous.peerLastDeliveredSequence > value.peerLastDeliveredSequence
            ? previous.peerLastDeliveredSequence
            : value.peerLastDeliveredSequence,
      );
}

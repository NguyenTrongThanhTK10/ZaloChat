import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/database/chat_local_store_provider.dart';
import '../../../../core/realtime/realtime_providers.dart';
import '../../../../core/realtime/realtime_service.dart';
import '../../../auth/domain/entities/chat_user.dart';
import '../../../auth/presentation/providers/auth_providers.dart';
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
    } else if (event is ReconnectedEvent) {
      if (!_loadingRemote) unawaited(refresh());
    }
  }

  void upsert(Conversation conversation) {
    if (_loadingRemote) _updatesDuringLoad[conversation.id] = conversation;
    final current = state.asData?.value;
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

  List<Conversation> _mergeUpdates(
    List<Conversation> base, {
    bool clear = false,
  }) {
    final byId = {
      for (final conversation in base) conversation.id: conversation,
    };
    byId.addAll(_updatesDuringLoad);
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
}

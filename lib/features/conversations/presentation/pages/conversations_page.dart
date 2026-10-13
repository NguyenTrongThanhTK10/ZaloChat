import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/chat_avatar.dart';
import '../../../../core/widgets/content_state.dart';
import '../../../auth/domain/entities/chat_user.dart';
import '../../../auth/presentation/providers/auth_providers.dart';
import '../../domain/entities/conversation.dart';
import '../providers/conversation_providers.dart';

enum _ConversationFilter { all, unread }

class ConversationsPage extends ConsumerStatefulWidget {
  const ConversationsPage({super.key});

  @override
  ConsumerState<ConversationsPage> createState() => _ConversationsPageState();
}

class _ConversationsPageState extends ConsumerState<ConversationsPage> {
  final _searchController = TextEditingController();
  String _query = '';
  _ConversationFilter _filter = _ConversationFilter.all;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      setState(() => _query = _searchController.text.trim().toLowerCase());
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final conversations = ref.watch(conversationListProvider);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showNewChatSheet(context),
        icon: const Icon(Icons.edit_square),
        label: const Text('Tin nhắn mới'),
      ),
      appBar: AppBar(
        title: const Text('Tin nhắn'),
        actions: [
          if (conversations.hasValue && conversations.requireValue.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: AppSpacing.lg),
              child: Center(
                child: Text(
                  '${conversations.requireValue.length} cuộc trò chuyện',
                  style: Theme.of(context).textTheme.labelMedium
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: Column(
            children: [
              _SearchAndFilters(
                controller: _searchController,
                query: _query,
                filter: _filter,
                onFilterChanged: (value) => setState(() => _filter = value),
              ),
              Expanded(
                child: conversations.when(
                  loading: () => const ConversationListSkeleton(),
                  error: (_, _) => ContentState(
                    icon: Icons.wifi_off_rounded,
                    title: 'Không tải được tin nhắn',
                    message: 'Kiểm tra kết nối rồi thử lại.',
                    actionLabel: 'Thử lại',
                    onAction: () =>
                        ref.read(conversationListProvider.notifier).refresh(),
                  ),
                  data: (items) {
                    if (items.isEmpty) {
                      return ContentState(
                        icon: Icons.forum_outlined,
                        title: 'Chưa có cuộc trò chuyện',
                        message: 'Cuộc trò chuyện của bạn sẽ xuất hiện ở đây.',
                        actionLabel: 'Làm mới',
                        onAction: () => ref
                            .read(conversationListProvider.notifier)
                            .refresh(),
                      );
                    }

                    final visible =
                        items.where((conversation) {
                          final matchesFilter = switch (_filter) {
                            _ConversationFilter.all => true,
                            _ConversationFilter.unread =>
                              conversation.unreadCount > 0,
                          };
                          if (!matchesFilter) return false;
                          if (_query.isEmpty) return true;
                          return conversation.title.toLowerCase().contains(
                                _query,
                              ) ||
                              (conversation.lastMessagePreview
                                      ?.toLowerCase()
                                      .contains(_query) ??
                                  false);
                        }).toList()..sort((a, b) {
                          if (a.isPinned != b.isPinned) {
                            return a.isPinned ? -1 : 1;
                          }
                          final aTime = a.lastMessageAt;
                          final bTime = b.lastMessageAt;
                          if (aTime == null) {
                            return bTime == null ? 0 : 1;
                          }
                          if (bTime == null) {
                            return -1;
                          }
                          return bTime.compareTo(aTime);
                        });

                    if (visible.isEmpty) {
                      return ContentState(
                        icon: Icons.search_off_rounded,
                        title: 'Không tìm thấy cuộc trò chuyện',
                        message: _query.isNotEmpty
                            ? 'Thử tên hoặc nội dung tìm kiếm khác.'
                            : 'Chưa có cuộc trò chuyện trong mục này.',
                      );
                    }

                    return RefreshIndicator(
                      onRefresh: () =>
                          ref.read(conversationListProvider.notifier).refresh(),
                      child: ListView.separated(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.only(bottom: AppSpacing.xl),
                        itemCount: visible.length,
                        separatorBuilder: (_, _) => Divider(
                          height: 1,
                          indent: 80,
                          endIndent: AppSpacing.lg,
                          color: scheme.outlineVariant.withValues(alpha: 0.4),
                        ),
                        itemBuilder: (context, index) {
                          final conversation = visible[index];
                          return _ConversationTile(
                            conversation: conversation,
                            onTap: () => context.push(
                              '/chat/${Uri.encodeComponent(conversation.id)}',
                            ),
                          );
                        },
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showNewChatSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (sheetContext) {
        final screenHeight = MediaQuery.sizeOf(sheetContext).height;
        final keyboardHeight = MediaQuery.viewInsetsOf(sheetContext).bottom;
        return Padding(
          padding: EdgeInsets.only(bottom: keyboardHeight),
          child: SizedBox(
            height: math.max(
              200.0,
              math.min(560.0, screenHeight - keyboardHeight - 32),
            ),
            child: const _NewChatSheet(),
          ),
        );
      },
    );
  }
}

class _NewChatSheet extends ConsumerStatefulWidget {
  const _NewChatSheet();

  @override
  ConsumerState<_NewChatSheet> createState() => _NewChatSheetState();
}

class _NewChatSheetState extends ConsumerState<_NewChatSheet> {
  final _searchController = TextEditingController();
  Timer? _debounce;
  String _query = '';
  String? _creatingUserId;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    _debounce?.cancel();
    final query = _searchController.text.trim();
    if (query.length < 2) {
      setState(() => _query = '');
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _query = query);
    });
  }

  Future<void> _startConversation(ChatUser user) async {
    if (_creatingUserId != null) return;
    setState(() => _creatingUserId = user.id);
    try {
      final conversation = await ref
          .read(conversationListProvider.notifier)
          .start(user.id);
      if (!mounted) return;
      final router = GoRouter.of(context);
      Navigator.of(context).pop();
      router.push('/chat/${Uri.encodeComponent(conversation.id)}');
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Không thể mở cuộc trò chuyện. Vui lòng thử lại.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _creatingUserId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final currentUserId = ref.watch(currentUserProvider)?.id;
    final results = _query.length >= 2
        ? ref.watch(userSearchProvider(_query))
        : null;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.xl,
                AppSpacing.sm,
                AppSpacing.xl,
                AppSpacing.lg,
              ),
              child: Text(
                'Tin nhắn mới',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: TextField(
                controller: _searchController,
                autofocus: true,
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(
                  hintText: 'Tìm người dùng theo tên hoặc email',
                  prefixIcon: Icon(Icons.search_rounded),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Expanded(
              child: results == null
                  ? const ContentState(
                      icon: Icons.person_search_rounded,
                      title: 'Tìm người để trò chuyện',
                      message: 'Nhập ít nhất 2 ký tự để tìm kiếm.',
                    )
                  : results.when(
                      loading: () => const ConversationListSkeleton(),
                      error: (_, _) => ContentState(
                        icon: Icons.wifi_off_rounded,
                        title: 'Không tìm được người dùng',
                        message: 'Kiểm tra kết nối rồi thử lại.',
                        actionLabel: 'Thử lại',
                        onAction: () =>
                            ref.invalidate(userSearchProvider(_query)),
                      ),
                      data: (users) {
                        final visible = users
                            .where((user) => user.id != currentUserId)
                            .toList();
                        if (visible.isEmpty) {
                          return const ContentState(
                            icon: Icons.search_off_rounded,
                            title: 'Không có kết quả',
                            message: 'Thử tên hoặc email khác.',
                          );
                        }
                        return ListView.builder(
                          itemCount: visible.length,
                          itemBuilder: (context, index) {
                            final user = visible[index];
                            return ListTile(
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: AppSpacing.lg,
                                vertical: AppSpacing.xs,
                              ),
                              leading: ChatAvatar(
                                name: user.displayName,
                                size: 44,
                              ),
                              title: Text(
                                user.displayName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                user.email,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: _creatingUserId == user.id
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.chevron_right_rounded),
                              enabled: _creatingUserId == null,
                              onTap: () => _startConversation(user),
                            );
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchAndFilters extends StatelessWidget {
  const _SearchAndFilters({
    required this.controller,
    required this.query,
    required this.filter,
    required this.onFilterChanged,
  });

  final TextEditingController controller;
  final String query;
  final _ConversationFilter filter;
  final ValueChanged<_ConversationFilter> onFilterChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.lg,
        AppSpacing.md,
      ),
      child: Column(
        children: [
          TextField(
            controller: controller,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Tìm cuộc trò chuyện',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Xóa tìm kiếm',
                      onPressed: controller.clear,
                      icon: const Icon(Icons.close_rounded),
                    ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          SizedBox(
            width: double.infinity,
            child: Wrap(
              spacing: AppSpacing.sm,
              children: [
                _chip('Tất cả', _ConversationFilter.all),
                _chip('Chưa đọc', _ConversationFilter.unread),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, _ConversationFilter value) {
    return ChoiceChip(
      label: Text(label),
      selected: filter == value,
      onSelected: (_) => onFilterChanged(value),
    );
  }
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({required this.conversation, required this.onTap});

  final Conversation conversation;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unread = conversation.unreadCount > 0;
    final preview = conversation.isTyping
        ? 'Đang nhập…'
        : conversation.lastMessagePreview?.trim().isNotEmpty == true
        ? conversation.lastMessagePreview!
        : 'Chưa có tin nhắn';

    return Material(
      color: theme.colorScheme.surface,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.md,
          ),
          child: Row(
            children: [
              ChatAvatar(
                name: conversation.title,
                imageUrl: conversation.avatarUrl,
                online: conversation.isOnline == true,
                isGroup: conversation.isGroup,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            conversation.title,
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: unread
                                  ? FontWeight.w700
                                  : FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Text(
                          _timeLabel(conversation.lastMessageAt),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: unread
                                ? theme.colorScheme.primary
                                : theme.colorScheme.onSurfaceVariant,
                            fontWeight: unread
                                ? FontWeight.w700
                                : FontWeight.w400,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            preview,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: conversation.isTyping
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.onSurfaceVariant,
                              fontWeight: unread
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                          ),
                        ),
                        if (conversation.isPinned || conversation.isMuted) ...[
                          const SizedBox(width: AppSpacing.xs),
                          if (conversation.isPinned)
                            Icon(
                              Icons.push_pin_rounded,
                              size: 15,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          if (conversation.isMuted)
                            Icon(
                              Icons.notifications_off_outlined,
                              size: 15,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                        ],
                        if (unread) ...[
                          const SizedBox(width: AppSpacing.sm),
                          Container(
                            constraints: const BoxConstraints(
                              minWidth: 20,
                              minHeight: 20,
                            ),
                            padding: const EdgeInsets.symmetric(horizontal: 5),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              conversation.unreadCount > 99
                                  ? '99+'
                                  : '${conversation.unreadCount}',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onPrimary,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _timeLabel(DateTime? timestamp) {
    if (timestamp == null) return '';
    final date = timestamp.toLocal();
    final today = DateTime.now();
    if (date.year == today.year &&
        date.month == today.month &&
        date.day == today.day) {
      return '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    }
    return '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}';
  }
}

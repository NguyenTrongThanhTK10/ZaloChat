import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/realtime/realtime_providers.dart';
import '../../../../core/realtime/realtime_service.dart';
import '../../../../core/widgets/chat_avatar.dart';
import '../../../../core/widgets/content_state.dart';
import '../../../auth/presentation/providers/auth_providers.dart';
import '../../../conversations/presentation/providers/conversation_providers.dart';
import '../../domain/entities/chat_message.dart';
import '../providers/message_providers.dart';

class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key, required this.conversationId});

  final String conversationId;

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage>
    with WidgetsBindingObserver {
  final _composerController = TextEditingController();
  final _scrollController = ScrollController();
  bool _sending = false;
  bool _loadingOlder = false;
  bool _showLatestButton = false;
  int _lastMarkedSequence = 0;
  bool _isResumed = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(covariant ChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.conversationId != widget.conversationId) {
      _lastMarkedSequence = 0;
      _showLatestButton = false;
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _composerController.dispose();
    super.dispose();
  }

  void _onScroll() {
    final show = _scrollController.offset > 180;
    if (show != _showLatestButton && mounted) {
      setState(() => _showLatestButton = show);
    }
    if (_scrollController.offset <= 72) {
      final current = ref.read(messagesProvider(widget.conversationId));
      final messages = current.asData?.value;
      if (messages != null) _markReadWhenNeeded(messages);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isResumed = state == AppLifecycleState.resumed;
    if (_isResumed) {
      final messages = ref
          .read(messagesProvider(widget.conversationId))
          .asData
          ?.value;
      if (messages != null) _markReadWhenNeeded(messages);
    }
  }

  Future<void> _sendMessage() async {
    final text = _composerController.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await ref
          .read(messagesProvider(widget.conversationId).notifier)
          .send(text);
      if (mounted && _composerController.text.trim() == text) {
        _composerController.clear();
      }
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          0,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Không gửi được tin nhắn. Vui lòng thử lại.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _retryMessage(String clientMessageId) async {
    try {
      await ref
          .read(messagesProvider(widget.conversationId).notifier)
          .retry(clientMessageId);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Chưa thể gửi lại. Vui lòng thử sau.')),
        );
      }
    }
  }

  Future<void> _loadOlder() async {
    if (_loadingOlder) return;
    final provider = messagesProvider(widget.conversationId);
    if (!ref.read(provider.notifier).hasMore) return;
    setState(() => _loadingOlder = true);
    try {
      await ref.read(provider.notifier).loadOlder();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Không tải được tin nhắn cũ.')),
        );
      }
    } finally {
      if (mounted) setState(() => _loadingOlder = false);
    }
  }

  void _markReadWhenNeeded(List<ChatMessage> messages) {
    if (!_isResumed || ModalRoute.of(context)?.isCurrent != true) return;
    if (_scrollController.hasClients && _scrollController.offset > 72) return;
    final currentUserId = ref.read(currentUserProvider)?.id;
    if (currentUserId == null) return;
    var latestIncomingSequence = _lastMarkedSequence;
    for (final message in messages) {
      if (message.senderId != currentUserId &&
          message.sequence > latestIncomingSequence) {
        latestIncomingSequence = message.sequence;
      }
    }
    if (latestIncomingSequence == _lastMarkedSequence) return;
    _lastMarkedSequence = latestIncomingSequence;
    unawaited(_markRead());
  }

  Future<void> _markRead() async {
    try {
      await ref
          .read(messagesProvider(widget.conversationId).notifier)
          .markRead();
    } catch (_) {
      // The provider retains the unread state so a later update can retry.
      _lastMarkedSequence = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final detail = ref.watch(conversationDetailProvider(widget.conversationId));
    final messages = ref.watch(messagesProvider(widget.conversationId));
    final currentUserId = ref.watch(currentUserProvider)?.id;
    final connection = ref.watch(connectionStatusProvider).asData?.value;
    final conversation = detail.asData?.value;
    final theme = Theme.of(context);

    final visibleMessages = messages.asData?.value;
    if (visibleMessages != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _markReadWhenNeeded(visibleMessages);
      });
    }

    ref.listen(messagesProvider(widget.conversationId), (previous, next) {
      final list = next.asData?.value;
      if (list == null) {
        return;
      }

      final oldList = previous?.asData?.value;
      final receivedNewMessage =
          oldList != null &&
          oldList.isNotEmpty &&
          list.length > oldList.length &&
          list.last.clientMessageId != oldList.last.clientMessageId;
      if (receivedNewMessage &&
          _scrollController.hasClients &&
          _scrollController.offset > 180) {
        final oldExtent = _scrollController.position.maxScrollExtent;
        final oldOffset = _scrollController.offset;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_scrollController.hasClients) {
            return;
          }
          final newExtent = _scrollController.position.maxScrollExtent;
          final addedExtent = newExtent - oldExtent;
          if (addedExtent > 0) {
            _scrollController.jumpTo(
              math.min(oldOffset + addedExtent, newExtent),
            );
          }
        });
      }
      _markReadWhenNeeded(list);
    });

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            if (conversation != null) ...[
              ChatAvatar(
                name: conversation.title,
                imageUrl: conversation.avatarUrl,
                size: 38,
                online: conversation.isOnline == true,
                isGroup: conversation.isGroup,
              ),
              const SizedBox(width: AppSpacing.md),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    conversation?.title ?? 'Tin nhắn',
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (conversation?.isOnline == true)
                    Text(
                      'Đang hoạt động',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: AppColors.online,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: Column(
            children: [
              Expanded(
                child: detail.hasError
                    ? ContentState(
                        icon: Icons.error_outline_rounded,
                        title: 'Không mở được cuộc trò chuyện',
                        message: 'Vui lòng thử lại.',
                        actionLabel: 'Thử lại',
                        onAction: () => ref.invalidate(
                          conversationDetailProvider(widget.conversationId),
                        ),
                      )
                    : Stack(
                        children: [
                          messages.when(
                            loading: () => const _ChatMessagesSkeleton(),
                            error: (_, _) => ContentState(
                              icon: Icons.wifi_off_rounded,
                              title: 'Không tải được tin nhắn',
                              message: 'Kiểm tra kết nối rồi thử lại.',
                              actionLabel: 'Thử lại',
                              onAction: () => ref
                                  .read(
                                    messagesProvider(widget.conversationId)
                                        .notifier,
                                  )
                                  .refresh(),
                            ),
                            data: (items) => items.isEmpty
                                ? const ContentState(
                                    icon: Icons.chat_bubble_outline_rounded,
                                    title: 'Bắt đầu trò chuyện',
                                    message: 'Gửi lời chào để bắt đầu cuộc trò chuyện.',
                                  )
                                : _messageList(items, currentUserId),
                          ),
                          if (_showLatestButton && messages.hasValue)
                            Positioned(
                              right: AppSpacing.lg,
                              bottom: AppSpacing.lg,
                              child: FloatingActionButton.small(
                                heroTag: 'latest-message',
                                tooltip: 'Đến tin nhắn mới nhất',
                                onPressed: () => _scrollController.animateTo(
                                  0,
                                  duration: const Duration(milliseconds: 260),
                                  curve: Curves.easeOutCubic,
                                ),
                                child: const Icon(Icons.arrow_downward_rounded),
                              ),
                            ),
                        ],
                      ),
              ),
              if (connection == ConnectionStatus.disconnected)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.lg,
                    vertical: AppSpacing.sm,
                  ),
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.wifi_off_rounded, size: 16),
                      const SizedBox(width: AppSpacing.sm),
                      Flexible(
                        child: Text(
                          'Ngoại tuyến · tin nhắn sẽ gửi lại khi có mạng',
                          style: theme.textTheme.labelMedium,
                        ),
                      ),
                    ],
                  ),
                ),
              if (!detail.hasError) _composer(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _messageList(List<ChatMessage> messages, String? currentUserId) {
    final hasMore = ref
        .read(messagesProvider(widget.conversationId).notifier)
        .hasMore;
    return ListView.builder(
      controller: _scrollController,
      reverse: true,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.xl,
      ),
      itemCount: messages.length + (hasMore ? 1 : 0),
      itemBuilder: (context, reverseIndex) {
        if (reverseIndex == messages.length) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.lg),
              child: _loadingOlder
                  ? const Padding(
                      padding: EdgeInsets.all(AppSpacing.md),
                      child: CircularProgressIndicator(),
                    )
                  : TextButton.icon(
                      onPressed: _loadOlder,
                      icon: const Icon(Icons.history_rounded),
                      label: const Text('Tải tin nhắn cũ'),
                    ),
            ),
          );
        }
        final index = messages.length - 1 - reverseIndex;
        final message = messages[index];
        final startsDay =
            index == 0 ||
            !_sameDay(
              messages[index - 1].createdAt.toLocal(),
              message.createdAt.toLocal(),
            );
        return Column(
          children: [
            if (startsDay) _DayDivider(date: message.createdAt.toLocal()),
            _MessageBubble(
              message: message,
              isMine: message.senderId == currentUserId,
              onRetry: message.status == MessageStatus.failed
                  ? () => _retryMessage(message.clientMessageId)
                  : null,
            ),
          ],
        );
      },
    );
  }

  Widget _composer(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      elevation: 2,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.sm,
            AppSpacing.md,
            AppSpacing.sm,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: _composerController,
                  minLines: 1,
                  maxLines: 5,
                  keyboardType: TextInputType.multiline,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    hintText: 'Nhập tin nhắn…',
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _composerController,
                builder: (context, value, _) {
                  final canSend = value.text.trim().isNotEmpty && !_sending;
                  return IconButton.filled(
                    tooltip: 'Gửi tin nhắn',
                    onPressed: canSend ? _sendMessage : null,
                    icon: _sending
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send_rounded),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

class _DayDivider extends StatelessWidget {
  const _DayDivider({required this.date});

  final DateTime date;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(date.year, date.month, date.day);
    final label = day == today
        ? 'Hôm nay'
        : day == today.subtract(const Duration(days: 1))
        ? 'Hôm qua'
        : '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.xs,
        ),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelSmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.isMine,
    this.onRetry,
  });

  final ChatMessage message;
  final bool isMine;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final timestamp = message.createdAt.toLocal();
    final time =
        '${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}';
    final status = switch (message.status) {
      MessageStatus.sending => (
        'Đang gửi',
        Icons.schedule_rounded,
        scheme.onSurfaceVariant,
      ),
      MessageStatus.sent => (
        'Đã gửi',
        Icons.check_rounded,
        scheme.onSurfaceVariant,
      ),
      MessageStatus.delivered => (
        'Đã nhận',
        Icons.done_all_rounded,
        scheme.onSurfaceVariant,
      ),
      MessageStatus.read => ('Đã xem', Icons.done_all_rounded, scheme.primary),
      MessageStatus.failed => (
        'Gửi thất bại',
        Icons.error_outline_rounded,
        scheme.error,
      ),
    };

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: math.min(MediaQuery.sizeOf(context).width, 620) * 0.78,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
          child: Column(
            crossAxisAlignment: isMine
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg,
                  vertical: AppSpacing.md,
                ),
                decoration: BoxDecoration(
                  color: isMine ? scheme.primaryContainer : scheme.surface,
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(20),
                    topRight: const Radius.circular(20),
                    bottomLeft: Radius.circular(isMine ? 20 : 6),
                    bottomRight: Radius.circular(isMine ? 6 : 20),
                  ),
                ),
                child: SelectableText(
                  message.text,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: isMine
                        ? scheme.onPrimaryContainer
                        : scheme.onSurface,
                    height: 1.4,
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    time,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  if (isMine) ...[
                    const SizedBox(width: AppSpacing.xs),
                    Tooltip(
                      message: status.$1,
                      child: Icon(status.$2, size: 15, color: status.$3),
                    ),
                  ],
                ],
              ),
              if (isMine && onRetry != null)
                TextButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh_rounded, size: 16),
                  label: const Text('Gửi lại'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChatMessagesSkeleton extends StatelessWidget {
  const _ChatMessagesSkeleton();

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.surfaceContainerHighest;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          _placeholder(color, Alignment.centerLeft, 180),
          _placeholder(color, Alignment.centerRight, 220),
          _placeholder(color, Alignment.centerLeft, 130),
          _placeholder(color, Alignment.centerRight, 190),
        ],
      ),
    );
  }

  Widget _placeholder(Color color, Alignment alignment, double width) {
    return Align(
      alignment: alignment,
      child: Container(
        width: width,
        height: 52,
        margin: const EdgeInsets.only(bottom: AppSpacing.md),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(20),
        ),
      ),
    );
  }
}

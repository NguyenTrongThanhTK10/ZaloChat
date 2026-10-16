import 'package:flutter/material.dart';

import '../../domain/entities/chat_message.dart';

enum MessageAction { copy, reply, recall }

class MessageActionsSheet extends StatelessWidget {
  const MessageActionsSheet({
    super.key,
    required this.message,
    required this.selectedReactions,
    required this.isMine,
    required this.canReact,
    required this.canReply,
    required this.canRecall,
  });

  final ChatMessage message;
  final List<MessageReaction> selectedReactions;
  final bool isMine;
  final bool canReact;
  final bool canReply;
  final bool canRecall;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: scheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: Text(
                    message.isRecalled ? 'Tùy chọn tin nhắn' : 'Bày tỏ cảm xúc',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.5,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  tooltip: 'Đóng',
                  onPressed: () => Navigator.pop(context),
                  style: IconButton.styleFrom(
                    backgroundColor: scheme.surfaceContainerLow,
                    foregroundColor: scheme.onSurfaceVariant,
                  ),
                  icon: const Icon(Icons.close_rounded, size: 20),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(16),
              ),
              child: IntrinsicHeight(
                child: Row(
                  children: [
                    Container(
                      width: 3,
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            isMine ? 'Tin nhắn của bạn' : 'Tin nhắn đang chọn',
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: scheme.primary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            message.isRecalled
                                ? 'Tin nhắn đã được thu hồi'
                                : message.kind == MessageKind.voice
                                ? '🎙 Tin nhắn thoại'
                                : message.kind == MessageKind.image
                                ? '📷 Ảnh'
                                : message.kind == MessageKind.file
                                ? message.attachment?.name ?? 'Tệp đính kèm'
                                : message.text,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (!message.isRecalled) ...[
              const SizedBox(height: 20),
              LayoutBuilder(
                builder: (context, constraints) {
                  final columns =
                      constraints.maxWidth < 320 ||
                          MediaQuery.textScalerOf(context).scale(12) > 16
                      ? 3
                      : 6;
                  return Wrap(
                    spacing: 4,
                    runSpacing: 12,
                    children: [
                      for (final reaction in MessageReaction.values)
                        SizedBox(
                          width:
                              (constraints.maxWidth - (columns - 1) * 4) /
                              columns,
                          child: _ReactionOption(
                            reaction: reaction,
                            selected: selectedReactions.contains(reaction),
                            enabled: canReact,
                          ),
                        ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 14),
              Text(
                'Chạm để thả cảm xúc · Chạm lại để gỡ',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 24),
            Material(
              clipBehavior: Clip.antiAlias,
              color: scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(20),
              child: Column(
                children: [
                  _ActionTile(
                    icon: Icons.copy_rounded,
                    label: 'Sao chép',
                    enabled:
                        message.kind == MessageKind.text && !message.isRecalled,
                    action: MessageAction.copy,
                  ),
                  const Divider(height: 1, indent: 64, endIndent: 16),
                  _ActionTile(
                    icon: Icons.reply_rounded,
                    label: 'Trả lời',
                    enabled: canReply,
                    action: MessageAction.reply,
                  ),
                ],
              ),
            ),
            if (canRecall) ...[
              const SizedBox(height: 10),
              Material(
                clipBehavior: Clip.antiAlias,
                color: scheme.errorContainer.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(20),
                child: const _ActionTile(
                  key: ValueKey('recall-message-action'),
                  icon: Icons.undo_rounded,
                  label: 'Thu hồi tin nhắn',
                  enabled: true,
                  action: MessageAction.recall,
                  destructive: true,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ReactionOption extends StatelessWidget {
  const _ReactionOption({
    required this.reaction,
    required this.selected,
    required this.enabled,
  });

  final MessageReaction reaction;
  final bool selected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final label = reactionLabel(reaction);
    final actionLabel = selected
        ? 'Gỡ ${reaction == MessageReaction.heart ? 'tim' : label.toLowerCase()}'
        : label;
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      label: actionLabel,
      onTap: enabled ? () => Navigator.pop(context, reaction) : null,
      excludeSemantics: true,
      child: Tooltip(
        message: actionLabel,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            key: ValueKey('reaction-${reaction.name}'),
            borderRadius: BorderRadius.circular(16),
            onTap: enabled ? () => Navigator.pop(context, reaction) : null,
            child: Opacity(
              opacity: enabled ? 1 : 0.4,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  children: [
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: selected
                                ? scheme.primaryContainer
                                : scheme.surfaceContainerLow,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: selected
                                  ? scheme.primary
                                  : Colors.transparent,
                              width: 1.5,
                            ),
                          ),
                          alignment: Alignment.center,
                          child: MessageReactionIcon(reaction, size: 30),
                        ),
                        if (selected)
                          Positioned(
                            right: -1,
                            bottom: -1,
                            child: Container(
                              padding: const EdgeInsets.all(2),
                              decoration: BoxDecoration(
                                color: scheme.primary,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: scheme.surface,
                                  width: 2,
                                ),
                              ),
                              child: Icon(
                                Icons.check_rounded,
                                size: 10,
                                color: scheme.onPrimary,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: MediaQuery.textScalerOf(context).scale(10) * 2.8,
                      child: Text(
                        label,
                        maxLines: 2,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontSize: 10,
                          height: 1.4,
                          color: selected
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
                          fontWeight: selected
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    super.key,
    required this.icon,
    required this.label,
    required this.enabled,
    required this.action,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final bool enabled;
  final MessageAction action;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = destructive ? scheme.error : scheme.primary;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      minLeadingWidth: 36,
      horizontalTitleGap: 14,
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: enabled
              ? color.withValues(alpha: 0.09)
              : scheme.onSurface.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(11),
        ),
        child: Icon(icon, size: 20, color: enabled ? color : scheme.outline),
      ),
      title: Text(
        label,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: enabled && destructive ? scheme.error : null,
        ),
      ),
      trailing: Icon(
        Icons.chevron_right_rounded,
        size: 20,
        color: enabled ? scheme.onSurfaceVariant : scheme.outline,
      ),
      enabled: enabled,
      onTap: enabled ? () => Navigator.pop(context, action) : null,
    );
  }
}

String reactionLabel(MessageReaction reaction) => switch (reaction) {
  MessageReaction.heart => 'Thả tim',
  MessageReaction.like => 'Thích',
  MessageReaction.laugh => 'Cười',
  MessageReaction.wow => 'Ngạc nhiên',
  MessageReaction.sad => 'Khóc',
  MessageReaction.angry => 'Tức giận',
};

class MessageReactionIcon extends StatelessWidget {
  const MessageReactionIcon(this.reaction, {super.key, this.size = 18});

  final MessageReaction reaction;
  final double size;

  @override
  Widget build(BuildContext context) => reaction == MessageReaction.heart
      ? Icon(Icons.favorite_rounded, size: size, color: const Color(0xFFE53935))
      : Text(
          switch (reaction) {
            MessageReaction.heart => '❤️',
            MessageReaction.like => '👍',
            MessageReaction.laugh => '😆',
            MessageReaction.wow => '😮',
            MessageReaction.sad => '😢',
            MessageReaction.angry => '😡',
          },
          textScaler: TextScaler.noScaling,
          style: TextStyle(fontSize: size, height: 1),
        );
}

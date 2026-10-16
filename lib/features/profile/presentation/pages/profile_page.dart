import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/chat_preferences_provider.dart';
import '../../../../app/theme_mode_provider.dart';
import '../../../../core/database/chat_local_store_provider.dart';
import '../../../../core/network/api_exception.dart';
import '../widgets/profile_components.dart';
import '../../../auth/presentation/providers/auth_providers.dart';
import '../../../chat/presentation/providers/message_providers.dart';
import '../../../conversations/presentation/providers/conversation_providers.dart';

class ProfilePage extends ConsumerWidget {
  const ProfilePage({super.key});

  Future<void> _clearHistory(BuildContext context, WidgetRef ref) async {
    final accountId = ref.read(currentUserProvider)?.id;
    if (accountId == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Xóa dữ liệu trên thiết bị?'),
        content: const Text(
          'Tin nhắn đã tải sẽ được xóa khỏi thiết bị này và tải lại từ máy chủ khi bạn mở cuộc trò chuyện.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Hủy'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Xóa dữ liệu'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    try {
      final cleared = await ref
          .read(chatLocalStoreProvider)
          .clearDownloadedHistory(accountId);
      if (!context.mounted) return;
      if (cleared) {
        ref.invalidate(conversationListProvider);
        ref.invalidate(messagesProvider);
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            cleared
                ? 'Đã xóa dữ liệu trên thiết bị.'
                : 'Còn tin nhắn đang chờ gửi. Hãy gửi xong rồi thử lại.',
          ),
        ),
      );
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ApiException.from(error).message)),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    final themeMode = ref.watch(themeModeProvider);
    final textSize = ref.watch(messageTextSizeProvider);
    final showPreview = ref.watch(messagePreviewProvider);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Cá nhân',
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w800,
            letterSpacing: -0.6,
          ),
        ),
        backgroundColor: theme.scaffoldBackgroundColor,
        toolbarHeight: 72,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
            children: [
              ProfileHeaderCard(
                user: user,
                onEdit: () => context.push('/profile/edit'),
                onPhoto: () => context.push('/profile/edit?photo=true'),
              ),
              const SizedBox(height: 28),
              ProfileSection(
                title: 'Giao diện',
                children: [
                  ProfileThemePicker(
                    value: themeMode,
                    onChanged: (mode) =>
                        ref.read(themeModeProvider.notifier).setMode(mode),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              ProfileSection(
                title: 'Trò chuyện',
                children: [
                  ProfileSettingTile(
                    icon: Icons.text_fields_rounded,
                    title: 'Cỡ chữ tin nhắn',
                    value: switch (textSize) {
                      MessageTextSize.small => 'Nhỏ',
                      MessageTextSize.normal => 'Vừa',
                      MessageTextSize.large => 'Lớn',
                    },
                    onTap: () => _chooseTextSize(context, ref, textSize),
                  ),
                  SwitchListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    secondary: ProfileSettingIcon(
                      icon: Icons.chat_bubble_outline_rounded,
                      color: scheme.primary,
                    ),
                    title: const Text(
                      'Xem trước tin nhắn',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                    subtitle: Text(
                      'Hiện nội dung trong danh sách chat',
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    value: showPreview,
                    onChanged: (visible) => ref
                        .read(messagePreviewProvider.notifier)
                        .setVisible(visible),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              ProfileSection(
                title: 'Dữ liệu & tài khoản',
                children: [
                  ProfileSettingTile(
                    icon: Icons.cleaning_services_outlined,
                    title: 'Xóa dữ liệu đã tải',
                    subtitle: 'Giải phóng bộ nhớ tin nhắn trên thiết bị',
                    onTap: () => _clearHistory(context, ref),
                  ),
                  ProfileSettingTile(
                    icon: Icons.logout_rounded,
                    title: 'Đăng xuất',
                    destructive: true,
                    onTap: () async {
                      try {
                        await ref.read(authProvider.notifier).logout();
                      } catch (error) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(ApiException.from(error).message),
                            ),
                          );
                        }
                      }
                    },
                  ),
                ],
              ),
              const SizedBox(height: 28),
              Text(
                'Lumi Chat',
                textAlign: TextAlign.center,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Phiên bản 0.1.0',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _chooseTextSize(
    BuildContext context,
    WidgetRef ref,
    MessageTextSize current,
  ) async {
    final selected = await showModalBottomSheet<MessageTextSize>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      builder: (context) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(
                  'Cỡ chữ tin nhắn',
                  style: Theme.of(context).textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              for (final (size, label, fontSize) in [
                (MessageTextSize.small, 'Nhỏ', 12.0),
                (MessageTextSize.normal, 'Vừa', 14.0),
                (MessageTextSize.large, 'Lớn', 18.0),
              ])
                ListTile(
                  title: Text(label, style: TextStyle(fontSize: fontSize)),
                  trailing: size == current
                      ? Icon(
                          Icons.check_circle_rounded,
                          color: Theme.of(context).colorScheme.primary,
                        )
                      : null,
                  onTap: () => Navigator.pop(context, size),
                ),
            ],
          ),
        ),
      ),
    );
    if (selected != null) {
      await ref.read(messageTextSizeProvider.notifier).setSize(selected);
    }
  }
}

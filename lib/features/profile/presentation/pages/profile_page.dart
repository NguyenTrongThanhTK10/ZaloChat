import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/chat_preferences_provider.dart';
import '../../../../app/theme_mode_provider.dart';
import '../../../../core/database/chat_local_store_provider.dart';
import '../../../../core/network/api_exception.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/chat_avatar.dart';
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
      appBar: AppBar(title: const Text('Cá nhân')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.xl),
                  child: Row(
                    children: [
                      ChatAvatar(name: user?.displayName ?? '?', size: 64),
                      const SizedBox(width: AppSpacing.lg),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              user?.displayName ?? '',
                              style: theme.textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: AppSpacing.xs),
                            Text(
                              user?.email ?? '',
                              style: TextStyle(color: scheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.edit_outlined),
                  title: const Text('Chỉnh sửa thông tin cá nhân'),
                  subtitle: const Text('Cập nhật tên hiển thị và email'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => context.push('/profile/edit'),
                ),
              ),
              const SizedBox(height: AppSpacing.xl),
              _sectionTitle(context, 'Giao diện'),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.palette_outlined),
                  title: const Text('Chế độ hiển thị'),
                  subtitle: const Text(
                    'Chọn giao diện sáng, tối hoặc theo máy',
                  ),
                  trailing: DropdownButton<ThemeMode>(
                    value: themeMode,
                    underline: const SizedBox.shrink(),
                    onChanged: (mode) {
                      if (mode != null) {
                        ref.read(themeModeProvider.notifier).setMode(mode);
                      }
                    },
                    items: const [
                      DropdownMenuItem(
                        value: ThemeMode.system,
                        child: Text('Hệ thống'),
                      ),
                      DropdownMenuItem(
                        value: ThemeMode.light,
                        child: Text('Sáng'),
                      ),
                      DropdownMenuItem(
                        value: ThemeMode.dark,
                        child: Text('Tối'),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.xl),
              _sectionTitle(context, 'Tin nhắn'),
              Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.format_size_rounded),
                      title: const Text('Cỡ chữ tin nhắn'),
                      subtitle: const Text(
                        'Áp dụng cho nội dung cuộc trò chuyện',
                      ),
                      trailing: DropdownButton<MessageTextSize>(
                        value: textSize,
                        underline: const SizedBox.shrink(),
                        onChanged: (size) {
                          if (size != null) {
                            ref
                                .read(messageTextSizeProvider.notifier)
                                .setSize(size);
                          }
                        },
                        items: const [
                          DropdownMenuItem(
                            value: MessageTextSize.small,
                            child: Text('Nhỏ'),
                          ),
                          DropdownMenuItem(
                            value: MessageTextSize.normal,
                            child: Text('Vừa'),
                          ),
                          DropdownMenuItem(
                            value: MessageTextSize.large,
                            child: Text('Lớn'),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1, indent: 56),
                    SwitchListTile(
                      secondary: const Icon(Icons.preview_outlined),
                      title: const Text('Hiện nội dung xem trước'),
                      subtitle: const Text(
                        'Hiện tin nhắn mới nhất trong danh sách',
                      ),
                      value: showPreview,
                      onChanged: (value) => ref
                          .read(messagePreviewProvider.notifier)
                          .setVisible(value),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.xl),
              _sectionTitle(context, 'Dữ liệu và tài khoản'),
              Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.cleaning_services_outlined),
                      title: const Text('Xóa dữ liệu đã tải'),
                      subtitle: const Text(
                        'Giải phóng dữ liệu tin nhắn trên thiết bị',
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => _clearHistory(context, ref),
                    ),
                    const Divider(height: 1, indent: 56),
                    ListTile(
                      leading: Icon(Icons.logout_rounded, color: scheme.error),
                      title: Text(
                        'Đăng xuất',
                        style: TextStyle(color: scheme.error),
                      ),
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
              ),
              const SizedBox(height: AppSpacing.xl),
              Text(
                'Lumi Chat · phiên bản 0.1.0',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String title) => Padding(
    padding: const EdgeInsets.only(left: AppSpacing.xs, bottom: AppSpacing.sm),
    child: Text(title, style: Theme.of(context).textTheme.titleMedium),
  );
}

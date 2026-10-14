import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/network/api_exception.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/chat_avatar.dart';
import '../../../auth/presentation/providers/auth_providers.dart';

class EditProfilePage extends ConsumerStatefulWidget {
  const EditProfilePage({super.key});

  @override
  ConsumerState<EditProfilePage> createState() => _EditProfilePageState();
}

class _EditProfilePageState extends ConsumerState<EditProfilePage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _emailController;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final user = ref.read(currentUserProvider);
    _nameController = TextEditingController(text: user?.displayName ?? '');
    _emailController = TextEditingController(text: user?.email ?? '');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(authProvider.notifier)
          .updateProfile(
            _nameController.text.trim(),
            _emailController.text.trim(),
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Đã cập nhật thông tin cá nhân.')),
      );
      context.pop();
    } catch (error) {
      if (mounted) setState(() => _error = ApiException.from(error).message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Chỉnh sửa thông tin')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: ListView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.xl),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Center(
                          child: ChatAvatar(
                            name: _nameController.text.trim().isEmpty
                                ? '?'
                                : _nameController.text.trim(),
                            size: 76,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.xl),
                        Text(
                          'Thông tin cá nhân',
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        Text(
                          'Tên hiển thị sẽ xuất hiện trong danh sách bạn bè và cuộc trò chuyện.',
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                        const SizedBox(height: AppSpacing.xl),
                        TextFormField(
                          controller: _nameController,
                          enabled: !_saving,
                          textCapitalization: TextCapitalization.words,
                          textInputAction: TextInputAction.next,
                          autofillHints: const [AutofillHints.name],
                          onChanged: (_) => setState(() {}),
                          decoration: const InputDecoration(
                            labelText: 'Tên hiển thị',
                            prefixIcon: Icon(Icons.person_outline_rounded),
                          ),
                          validator: (value) {
                            final length = value?.trim().length ?? 0;
                            if (length == 0) {
                              return 'Vui lòng nhập tên hiển thị.';
                            }
                            if (length > 80) return 'Tên không quá 80 ký tự.';
                            return null;
                          },
                        ),
                        const SizedBox(height: AppSpacing.lg),
                        TextFormField(
                          controller: _emailController,
                          enabled: !_saving,
                          keyboardType: TextInputType.emailAddress,
                          textInputAction: TextInputAction.done,
                          autofillHints: const [AutofillHints.email],
                          autocorrect: false,
                          decoration: const InputDecoration(
                            labelText: 'Email',
                            prefixIcon: Icon(Icons.alternate_email_rounded),
                          ),
                          onFieldSubmitted: (_) => _save(),
                          validator: (value) {
                            final email = value?.trim() ?? '';
                            if (email.length > 254 ||
                                !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$')
                                    .hasMatch(email)) {
                              return 'Vui lòng nhập email hợp lệ.';
                            }
                            return null;
                          },
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: AppSpacing.lg),
                          Semantics(
                            liveRegion: true,
                            child: Text(
                              _error!,
                              style: TextStyle(color: scheme.error),
                            ),
                          ),
                        ],
                        const SizedBox(height: AppSpacing.xl),
                        FilledButton.icon(
                          onPressed: _saving ? null : _save,
                          icon: _saving
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.check_rounded),
                          label: Text(_saving ? 'Đang lưu...' : 'Lưu thay đổi'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

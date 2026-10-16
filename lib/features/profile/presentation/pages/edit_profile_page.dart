import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/network/api_exception.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/chat_avatar.dart';
import '../../../auth/presentation/providers/auth_providers.dart';
import '../providers/profile_photo_provider.dart';

class EditProfilePage extends ConsumerStatefulWidget {
  const EditProfilePage({super.key, this.selectPhotoOnOpen = false});

  final bool selectPhotoOnOpen;

  @override
  ConsumerState<EditProfilePage> createState() => _EditProfilePageState();
}

class _EditProfilePageState extends ConsumerState<EditProfilePage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _emailController;
  bool _saving = false;
  bool _pickingPhoto = false;
  bool _removeAvatar = false;
  String? _photoPath;
  late final ProfilePhotoService _photos;
  String? _error;

  @override
  void initState() {
    super.initState();
    final user = ref.read(currentUserProvider);
    _nameController = TextEditingController(text: user?.displayName ?? '');
    _emailController = TextEditingController(text: user?.email ?? '');
    _photos = ref.read(profilePhotoServiceProvider);
    if (widget.selectPhotoOnOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_pickPhoto());
      });
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    if (!_saving) unawaited(_photos.discard(_photoPath));
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || _pickingPhoto || !_formKey.currentState!.validate()) return;
    final savedPhoto = _photoPath;
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
            avatarPath: _photoPath,
            removeAvatar: _removeAvatar,
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Đã cập nhật thông tin cá nhân.')),
      );
      context.pop();
    } catch (error) {
      if (mounted) setState(() => _error = ApiException.from(error).message);
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      } else {
        await _photos.discard(savedPhoto);
      }
    }
  }

  Future<void> _pickPhoto() async {
    if (_saving || _pickingPhoto) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _pickingPhoto = true;
      _error = null;
    });
    try {
      final path = await _photos.pick();
      if (!mounted) {
        await _photos.discard(path);
        return;
      }
      if (path == null) return;
      final previous = _photoPath;
      setState(() {
        _photoPath = path;
        _removeAvatar = false;
      });
      await _photos.discard(previous);
    } catch (error) {
      if (mounted) setState(() => _error = ApiException.from(error).message);
    } finally {
      if (mounted) setState(() => _pickingPhoto = false);
    }
  }

  Future<void> _photoActions() async {
    if (_saving || _pickingPhoto) return;
    final hasPhoto =
        _photoPath != null ||
        (!_removeAvatar && ref.read(currentUserProvider)?.avatarUrl != null);
    if (!hasPhoto) {
      await _pickPhoto();
      return;
    }
    final remove = await showModalBottomSheet<bool>(
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
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('Chọn ảnh mới'),
                onTap: () => Navigator.pop(context, false),
              ),
              ListTile(
                leading: Icon(
                  Icons.delete_outline_rounded,
                  color: Theme.of(context).colorScheme.error,
                ),
                title: const Text('Gỡ ảnh đại diện'),
                onTap: () => Navigator.pop(context, true),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || remove == null) return;
    if (!remove) {
      await _pickPhoto();
      return;
    }
    final previous = _photoPath;
    setState(() {
      _photoPath = null;
      _removeAvatar = true;
    });
    await _photos.discard(previous);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final user = ref.watch(currentUserProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Chỉnh sửa hồ sơ'),
        backgroundColor: theme.scaffoldBackgroundColor,
      ),
      bottomNavigationBar: Material(
        color: theme.scaffoldBackgroundColor,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
            child: Center(
              heightFactor: 1,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 588),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _saving || _pickingPhoto ? null : _save,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 52),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    icon: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check_rounded),
                    label: Text(_saving ? 'Đang lưu...' : 'Lưu thay đổi'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: ListView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            scheme.primaryContainer.withValues(alpha: 0.55),
                            scheme.surface,
                          ],
                        ),
                        borderRadius: BorderRadius.circular(26),
                      ),
                      child: Column(
                        children: [
                          Semantics(
                            button: true,
                            label: 'Thay ảnh đại diện',
                            child: GestureDetector(
                              key: const ValueKey('profile-photo-picker'),
                              onTap: _saving || _pickingPhoto
                                  ? null
                                  : _photoActions,
                              child: Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(5),
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: scheme.surface,
                                      boxShadow: [
                                        BoxShadow(
                                          color: scheme.primary.withValues(
                                            alpha: 0.1,
                                          ),
                                          blurRadius: 24,
                                          offset: const Offset(0, 8),
                                        ),
                                      ],
                                    ),
                                    child: ChatAvatar(
                                      name: _nameController.text.trim(),
                                      imageUrl: _removeAvatar
                                          ? null
                                          : user?.avatarUrl,
                                      imageProvider: _photoPath == null
                                          ? null
                                          : FileImage(File(_photoPath!)),
                                      size: 100,
                                    ),
                                  ),
                                  Positioned(
                                    right: 0,
                                    bottom: 0,
                                    child: Container(
                                      width: 34,
                                      height: 34,
                                      decoration: BoxDecoration(
                                        color: scheme.primary,
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color: scheme.surface,
                                          width: 3,
                                        ),
                                      ),
                                      child: _pickingPhoto
                                          ? Padding(
                                              padding: const EdgeInsets.all(7),
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                                color: scheme.onPrimary,
                                              ),
                                            )
                                          : Icon(
                                              Icons.camera_alt_rounded,
                                              size: 16,
                                              color: scheme.onPrimary,
                                            ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          TextButton.icon(
                            onPressed: _saving || _pickingPhoto
                                ? null
                                : _photoActions,
                            icon: const Icon(
                              Icons.add_photo_alternate_outlined,
                              size: 18,
                            ),
                            label: Text(
                              _pickingPhoto
                                  ? 'Đang xử lý ảnh...'
                                  : 'Thay ảnh đại diện',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          Text(
                            'Ảnh được căn giữa trong khung tròn',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xl),
                    Text(
                      'Thông tin của bạn',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      'Giúp bạn bè nhận ra bạn trong cuộc trò chuyện.',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: AppSpacing.xl),
                    Container(
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        color: scheme.surface,
                        borderRadius: BorderRadius.circular(22),
                      ),
                      child: Column(
                        children: [
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
                        ],
                      ),
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
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

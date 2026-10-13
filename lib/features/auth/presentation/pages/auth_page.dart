import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/network/api_exception.dart';
import '../../../../core/theme/app_theme.dart';
import '../providers/auth_providers.dart';
import '../widgets/auth_brand_panel.dart';

class AuthPage extends ConsumerStatefulWidget {
  const AuthPage({super.key, this.register = false});

  final bool register;

  @override
  ConsumerState<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends ConsumerState<AuthPage> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _busy = false;
  bool _obscurePassword = true;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate() || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final auth = ref.read(authProvider.notifier);
      if (widget.register) {
        await auth.register(
          _nameController.text.trim(),
          _emailController.text.trim(),
          _passwordController.text,
        );
      } else {
        await auth.login(
          _emailController.text.trim(),
          _passwordController.text,
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = ApiException.from(error).message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isDark
                ? const [Color(0xFF101B2D), Color(0xFF101722)]
                : const [Color(0xFFEDF4FF), Color(0xFFF8FAFE), Colors.white],
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 900;
              final padding = wide ? 40.0 : 20.0;
              final minHeight = constraints.maxHeight - padding * 2;
              return SingleChildScrollView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: EdgeInsets.all(padding),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: minHeight > 0 ? minHeight : 0,
                  ),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: wide ? 1120 : 460),
                      child: wide
                          ? Row(
                              children: [
                                const Expanded(
                                  child: AuthBrandPanel(expanded: true),
                                ),
                                const SizedBox(width: 40),
                                Expanded(child: _formCard(context)),
                              ],
                            )
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const AuthBrandPanel(),
                                const SizedBox(height: 20),
                                _formCard(context),
                              ],
                            ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _formCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.xl),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(
          color: isDark
              ? scheme.outlineVariant.withValues(alpha: 0.4)
              : const Color(0xFFE4ECF8),
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF173C78)
                .withValues(alpha: isDark ? 0.12 : 0.06),
            blurRadius: 40,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: AutofillGroup(
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.register ? 'Tạo tài khoản mới' : 'Chào mừng trở lại',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.7,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                widget.register
                    ? 'Bắt đầu những cuộc trò chuyện ý nghĩa cùng Lối Chat.'
                    : 'Đăng nhập để tiếp tục trò chuyện\ncùng những người bạn yêu quý.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 28),
              if (widget.register) ...[
                _fieldLabel(context, 'Tên hiển thị'),
                Semantics(
                  label: 'Tên hiển thị',
                  child: TextFormField(
                    controller: _nameController,
                    enabled: !_busy,
                    textCapitalization: TextCapitalization.words,
                    textInputAction: TextInputAction.next,
                    autofillHints: const [AutofillHints.name],
                    decoration: _inputDecoration(
                      context,
                      hint: 'Tên mọi người sẽ nhìn thấy',
                      icon: Icons.person_outline_rounded,
                    ),
                    validator: (value) => (value?.trim().length ?? 0) < 2
                        ? 'Nhập ít nhất 2 ký tự.'
                        : null,
                  ),
                ),
                const SizedBox(height: 20),
              ],
              _fieldLabel(context, 'Email'),
              Semantics(
                label: 'Email',
                child: TextFormField(
                  controller: _emailController,
                  enabled: !_busy,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.email],
                  autocorrect: false,
                  decoration: _inputDecoration(
                    context,
                    hint: 'ban@example.com',
                    icon: Icons.alternate_email_rounded,
                  ),
                  validator: (value) => value?.trim().contains('@') != true
                      ? 'Nhập email hợp lệ.'
                      : null,
                ),
              ),
              const SizedBox(height: 20),
              _fieldLabel(context, 'Mật khẩu'),
              Semantics(
                label: 'Mật khẩu',
                child: TextFormField(
                  controller: _passwordController,
                  enabled: !_busy,
                  obscureText: _obscurePassword,
                  autocorrect: false,
                  enableSuggestions: false,
                  textInputAction: TextInputAction.done,
                  autofillHints: [
                    widget.register
                        ? AutofillHints.newPassword
                        : AutofillHints.password,
                  ],
                  onFieldSubmitted: (_) => _submit(),
                  decoration:
                      _inputDecoration(
                        context,
                        hint: widget.register
                            ? 'Tối thiểu 8 ký tự'
                            : 'Nhập mật khẩu',
                        icon: Icons.lock_outline_rounded,
                      ).copyWith(
                        suffixIcon: IconButton(
                          tooltip: _obscurePassword
                              ? 'Hiện mật khẩu'
                              : 'Ẩn mật khẩu',
                          onPressed: _busy
                              ? null
                              : () => setState(
                                  () => _obscurePassword = !_obscurePassword,
                                ),
                          icon: Icon(
                            _obscurePassword
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                            size: 21,
                          ),
                        ),
                      ),
                  validator: (value) => (value?.length ?? 0) < 8
                      ? 'Mật khẩu cần ít nhất 8 ký tự.'
                      : null,
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: AppSpacing.lg),
                Semantics(
                  liveRegion: true,
                  child: Container(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    decoration: BoxDecoration(
                      color: scheme.errorContainer.withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.info_outline_rounded,
                          color: scheme.error,
                          size: 20,
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Text(
                            _error!,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: scheme.onErrorContainer,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 28),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF2479EC), Color(0xFF135CCE)],
                  ),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    if (!_busy)
                      BoxShadow(
                        color: AppColors.blue.withValues(alpha: 0.23),
                        blurRadius: 18,
                        offset: const Offset(0, 7),
                      ),
                  ],
                ),
                child: FilledButton(
                  onPressed: _busy ? null : _submit,
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.transparent,
                    disabledBackgroundColor: Colors.transparent,
                    foregroundColor: Colors.white,
                    disabledForegroundColor: Colors.white.withValues(
                      alpha: 0.85,
                    ),
                    minimumSize: const Size.fromHeight(56),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 16,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    textStyle: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (_busy) ...[
                        const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(width: 10),
                      ],
                      Flexible(
                        child: Text(
                          _busy
                              ? (widget.register
                                    ? 'Đang tạo tài khoản…'
                                    : 'Đang đăng nhập…')
                              : (widget.register
                                    ? 'Tạo tài khoản'
                                    : 'Đăng nhập'),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      if (!_busy) ...[
                        const SizedBox(width: 10),
                        const Icon(Icons.arrow_forward_rounded, size: 19),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    widget.register
                        ? 'Bạn đã có tài khoản?'
                        : 'Bạn chưa có tài khoản?',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => context.go(
                            widget.register ? '/login' : '/register',
                          ),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      textStyle: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    child: Text(widget.register ? 'Đăng nhập' : 'Đăng ký ngay'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _fieldLabel(BuildContext context, String label) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: ExcludeSemantics(
      child: Text(
        label,
        style: Theme.of(context).textTheme.bodyMedium
            ?.copyWith(fontWeight: FontWeight.w600),
      ),
    ),
  );

  InputDecoration _inputDecoration(
    BuildContext context, {
    required String hint,
    required IconData icon,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(
        color: scheme.outlineVariant.withValues(alpha: 0.55),
      ),
    );
    return InputDecoration(
      hintText: hint,
      filled: true,
      fillColor: theme.brightness == Brightness.dark
          ? const Color(0xFF202E42)
          : const Color(0xFFF7F9FD),
      prefixIcon: Icon(icon, size: 21, color: scheme.onSurfaceVariant),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      border: border,
      enabledBorder: border,
      disabledBorder: border,
      focusedBorder: border.copyWith(
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
      errorBorder: border.copyWith(borderSide: BorderSide(color: scheme.error)),
      focusedErrorBorder: border.copyWith(
        borderSide: BorderSide(color: scheme.error, width: 1.5),
      ),
      errorMaxLines: 3,
    );
  }
}

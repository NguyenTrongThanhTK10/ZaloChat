import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/network/api_exception.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/chat_avatar.dart';
import '../../../../core/widgets/content_state.dart';
import '../../../conversations/presentation/providers/conversation_providers.dart';

class PeoplePage extends ConsumerStatefulWidget {
  const PeoplePage({super.key});

  @override
  ConsumerState<PeoplePage> createState() => _PeoplePageState();
}

class _PeoplePageState extends ConsumerState<PeoplePage> {
  final _search = TextEditingController();
  Timer? _debounce;
  String _query = '';
  String? _startingId;

  @override
  void initState() {
    super.initState();
    _search.addListener(() {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 300), () {
        if (mounted) setState(() => _query = _search.text.trim());
      });
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _openChat(String userId) async {
    if (_startingId != null) return;
    setState(() => _startingId = userId);
    try {
      final conversation = await ref
          .read(conversationListProvider.notifier)
          .start(userId);
      if (mounted) {
        context.push('/chat/${Uri.encodeComponent(conversation.id)}');
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ApiException.from(error).message)),
        );
      }
    } finally {
      if (mounted) setState(() => _startingId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final users = ref.watch(userSearchProvider(_query));
    return Scaffold(
      appBar: AppBar(title: const Text('Mọi người')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: TextField(
                  controller: _search,
                  decoration: const InputDecoration(
                    hintText: 'Tìm theo tên hoặc email',
                    prefixIcon: Icon(Icons.search_rounded),
                  ),
                ),
              ),
              Expanded(
                child: users.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (_, _) => ContentState(
                    icon: Icons.wifi_off_rounded,
                    title: 'Không tải được danh sách',
                    message: 'Kiểm tra kết nối rồi thử lại.',
                    actionLabel: 'Thử lại',
                    onAction: () => ref.invalidate(userSearchProvider(_query)),
                  ),
                  data: (items) => items.isEmpty
                      ? const ContentState(
                          icon: Icons.people_outline_rounded,
                          title: 'Không tìm thấy người dùng',
                          message: 'Thử một tên hoặc email khác.',
                        )
                      : ListView.builder(
                          itemCount: items.length,
                          itemBuilder: (context, index) {
                            final user = items[index];
                            return ListTile(
                              leading: IconButton(
                                tooltip: 'Xem thông tin ${user.displayName}',
                                padding: EdgeInsets.zero,
                                iconSize: 44,
                                onPressed: () => context.push(
                                  '/people/${Uri.encodeComponent(user.id)}',
                                ),
                                icon: ChatAvatar(
                                  name: user.displayName,
                                  imageUrl: user.avatarUrl,
                                  size: 44,
                                ),
                              ),
                              title: Text(user.displayName),
                              subtitle: Text(user.email),
                              trailing: _startingId == user.id
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.chevron_right_rounded),
                              onTap: () => _openChat(user.id),
                            );
                          },
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

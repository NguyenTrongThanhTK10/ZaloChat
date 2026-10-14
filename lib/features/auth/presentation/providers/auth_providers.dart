import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../../core/database/chat_local_store_provider.dart';
import '../../../../core/network/api_client.dart';
import '../../../../core/security/token_store.dart';
import '../../data/repositories/remote_auth_repository.dart';
import '../../domain/entities/auth_session.dart';
import '../../domain/entities/chat_user.dart';
import '../../domain/repositories/auth_repository.dart';

final tokenStoreProvider = Provider<TokenStore>(
  (ref) => TokenStore(const FlutterSecureStorage()),
);

final apiClientProvider = Provider<ApiClient>((ref) {
  final client = ApiClient(ref.watch(tokenStoreProvider));
  ref.onDispose(client.dispose);
  return client;
});

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => RemoteAuthRepository(
    ref.watch(apiClientProvider).dio,
    ref.watch(tokenStoreProvider),
  ),
);

final authProvider = AsyncNotifierProvider<AuthNotifier, AuthSession?>(
  AuthNotifier.new,
);

final currentUserProvider = Provider<ChatUser?>(
  (ref) => ref.watch(authProvider).asData?.value?.user,
);

class AuthNotifier extends AsyncNotifier<AuthSession?> {
  StreamSubscription<void>? _expiredSubscription;

  @override
  Future<AuthSession?> build() {
    _expiredSubscription?.cancel();
    _expiredSubscription = ref.read(apiClientProvider).sessionExpired.listen((
      _,
    ) {
      unawaited(Future<void>.microtask(_handleExpired));
    });
    ref.onDispose(() => _expiredSubscription?.cancel());
    return ref.read(authRepositoryProvider).restore();
  }

  Future<void> _handleExpired() async {
    if (!ref.mounted) return;
    final accountId = state.asData?.value?.user.id;
    state = const AsyncData(null);
    if (accountId != null) {
      await ref.read(chatLocalStoreProvider).clearAccount(accountId);
    }
  }

  Future<void> login(String email, String password) async {
    state = AsyncData(
      await ref.read(authRepositoryProvider).login(email, password),
    );
  }

  Future<void> register(
    String displayName,
    String email,
    String password,
  ) async {
    state = AsyncData(
      await ref
          .read(authRepositoryProvider)
          .register(displayName, email, password),
    );
  }

  Future<void> logout() async {
    final accountId = state.asData?.value?.user.id;
    await ref.read(authRepositoryProvider).logout();
    if (accountId != null) {
      await ref.read(chatLocalStoreProvider).clearAccount(accountId);
    }
    state = const AsyncData(null);
  }

  Future<void> updateProfile(String displayName, String email) async {
    final user = await ref
        .read(authRepositoryProvider)
        .updateProfile(displayName, email);
    if (!ref.mounted || state.asData?.value?.user.id != user.id) return;
    state = AsyncData(AuthSession(user));
  }
}

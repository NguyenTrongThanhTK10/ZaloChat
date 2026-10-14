import 'package:appchatdemo/features/auth/domain/entities/auth_session.dart';
import 'package:appchatdemo/features/auth/domain/entities/chat_user.dart';
import 'package:appchatdemo/features/auth/presentation/providers/auth_providers.dart';
import 'package:appchatdemo/features/profile/presentation/pages/edit_profile_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class TestAuthNotifier extends AuthNotifier {
  static ChatUser? savedUser;

  @override
  Future<AuthSession?> build() async => const AuthSession(
    ChatUser(id: 'user-1', displayName: 'Tên cũ', email: 'old@example.com'),
  );

  @override
  Future<void> updateProfile(String displayName, String email) async {
    savedUser = ChatUser(id: 'user-1', displayName: displayName, email: email);
    state = AsyncData(AuthSession(savedUser!));
  }
}

void main() {
  testWidgets('prefills, validates and saves profile changes', (tester) async {
    TestAuthNotifier.savedUser = null;
    final router = GoRouter(
      initialLocation: '/profile',
      routes: [
        GoRoute(
          path: '/profile',
          builder: (_, _) => Consumer(
            builder: (context, ref, _) {
              ref.watch(currentUserProvider);
              return const Scaffold(body: Text('Hồ sơ'));
            },
          ),
        ),
        GoRoute(
          path: '/profile/edit',
          builder: (_, _) => const EditProfilePage(),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [authProvider.overrideWith(TestAuthNotifier.new)],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    router.push('/profile/edit');
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextFormField>(find.byType(TextFormField).at(0)).controller?.text,
      'Tên cũ',
    );
    expect(
      tester.widget<TextFormField>(find.byType(TextFormField).at(1)).controller?.text,
      'old@example.com',
    );
    await tester.enterText(find.byType(TextFormField).at(0), '');
    await tester.enterText(find.byType(TextFormField).at(1), 'invalid');
    await tester.tap(find.text('Lưu thay đổi'));
    await tester.pump();
    expect(find.text('Vui lòng nhập tên hiển thị.'), findsOneWidget);
    expect(find.text('Vui lòng nhập email hợp lệ.'), findsOneWidget);
    expect(TestAuthNotifier.savedUser, isNull);

    await tester.enterText(find.byType(TextFormField).at(0), 'Tên mới');
    await tester.enterText(find.byType(TextFormField).at(1), 'new@example.com');
    await tester.tap(find.text('Lưu thay đổi'));
    await tester.pumpAndSettle();

    expect(find.text('Hồ sơ'), findsOneWidget);
    expect(TestAuthNotifier.savedUser?.displayName, 'Tên mới');
    expect(TestAuthNotifier.savedUser?.email, 'new@example.com');
  });
}

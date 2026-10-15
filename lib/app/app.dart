import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/theme/app_theme.dart';
import '../features/auth/presentation/pages/auth_page.dart';
import '../features/auth/presentation/providers/auth_providers.dart';
import '../features/chat/presentation/pages/chat_page.dart';
import '../features/chat/presentation/providers/message_providers.dart';
import '../features/conversations/presentation/pages/conversations_page.dart';
import '../features/conversations/presentation/providers/conversation_providers.dart';
import '../features/contacts/presentation/pages/people_page.dart';
import '../features/contacts/presentation/pages/person_detail_page.dart';
import '../features/profile/presentation/pages/profile_page.dart';
import '../features/profile/presentation/pages/edit_profile_page.dart';
import 'theme_mode_provider.dart';

final appRouterProvider = Provider<GoRouter>((ref) {
  final signedIn = ref.watch(
    currentUserProvider.select((user) => user != null),
  );
  final router = GoRouter(
    initialLocation: signedIn ? '/' : '/login',
    redirect: (_, state) {
      final path = state.uri.path;
      final isAuthRoute = path == '/login' || path == '/register';
      if (!signedIn && !isAuthRoute) return '/login';
      if (signedIn && isAuthRoute) return '/';
      return null;
    },
    routes: [
      GoRoute(path: '/login', builder: (_, _) => const AuthPage()),
      GoRoute(
        path: '/register',
        builder: (_, _) => const AuthPage(register: true),
      ),
      GoRoute(
        path: '/',
        builder: (_, _) =>
            const AppShell(selectedIndex: 0, child: ConversationsPage()),
      ),
      GoRoute(
        path: '/people',
        builder: (_, _) =>
            const AppShell(selectedIndex: 1, child: PeoplePage()),
      ),
      GoRoute(
        path: '/profile',
        builder: (_, _) =>
            const AppShell(selectedIndex: 2, child: ProfilePage()),
      ),
      GoRoute(
        path: '/profile/edit',
        builder: (_, _) => const EditProfilePage(),
      ),
      GoRoute(
        path: '/chat/:id',
        builder: (_, state) =>
            ChatPage(conversationId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/people/:id',
        builder: (_, state) =>
            PersonDetailPage(userId: state.pathParameters['id']!),
      ),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});

class ChatApp extends ConsumerWidget {
  const ChatApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final auth = ref.watch(authProvider);
    if (auth.isLoading) {
      return MaterialApp(
        title: 'Lumi Chat',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: themeMode,
        home: const Scaffold(body: Center(child: CircularProgressIndicator())),
      );
    }
    ref.watch(outboxSyncProvider);
    ref.watch(conversationListProvider);
    return MaterialApp.router(
      title: 'Lumi Chat',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: themeMode,
      routerConfig: ref.watch(appRouterProvider),
    );
  }
}

class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.selectedIndex, required this.child});

  final int selectedIndex;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: child,
      bottomNavigationBar: NavigationBar(
        selectedIndex: selectedIndex,
        onDestinationSelected: (index) => context.go(switch (index) {
          0 => '/',
          1 => '/people',
          _ => '/profile',
        }),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline_rounded),
            selectedIcon: Icon(Icons.chat_bubble_rounded),
            label: 'Tin nhắn',
          ),
          NavigationDestination(
            icon: Icon(Icons.people_outline_rounded),
            selectedIcon: Icon(Icons.people_rounded),
            label: 'Mọi người',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline_rounded),
            selectedIcon: Icon(Icons.person_rounded),
            label: 'Cá nhân',
          ),
        ],
      ),
    );
  }
}

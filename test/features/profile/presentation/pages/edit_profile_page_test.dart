import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:appchatdemo/features/auth/domain/entities/auth_session.dart';
import 'package:appchatdemo/features/auth/domain/entities/chat_user.dart';
import 'package:appchatdemo/features/auth/presentation/providers/auth_providers.dart';
import 'package:appchatdemo/features/profile/presentation/pages/edit_profile_page.dart';
import 'package:appchatdemo/features/profile/presentation/pages/profile_page.dart';
import 'package:appchatdemo/features/profile/presentation/providers/profile_photo_provider.dart';
import 'package:appchatdemo/app/theme_mode_provider.dart';
import 'package:appchatdemo/core/theme/app_theme.dart';
import 'package:appchatdemo/core/network/api_exception.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

final _imageBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGMQTr32HwAEKwJOk+jLUgAAAABJRU5ErkJggg==',
);

class _PhotoService extends ProfilePhotoService {
  String? selected;
  final discarded = <String?>[];
  @override
  Future<String?> pick() async => selected;
  @override
  Future<void> discard(String? path) async => discarded.add(path);
}

class TestAuthNotifier extends AuthNotifier {
  static ChatUser? savedUser;
  static String? savedPhoto;
  static bool failSave = false;

  @override
  Future<AuthSession?> build() async => const AuthSession(
    ChatUser(id: 'user-1', displayName: 'Tên cũ', email: 'old@example.com'),
  );

  @override
  Future<void> updateProfile(
    String displayName,
    String email, {
    String? avatarPath,
    bool removeAvatar = false,
  }) async {
    if (failSave) throw const ApiException('Không thể kết nối máy chủ.');
    savedPhoto = avatarPath;
    savedUser = ChatUser(id: 'user-1', displayName: displayName, email: email);
    state = AsyncData(AuthSession(savedUser!));
  }
}

void main() {
  setUp(() {
    TestAuthNotifier.savedUser = null;
    TestAuthNotifier.savedPhoto = null;
    TestAuthNotifier.failSave = false;
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  testWidgets(
    'photo preparation creates a bounded square and cleans its own draft',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'profile-photo-prepare-',
      );
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (call) async =>
                call.method == 'getTemporaryDirectory' ? directory.path : null,
          );
      try {
        await tester.runAsync(() async {
          final original = File('${directory.path}/original.png')
            ..writeAsBytesSync(_imageBytes);
          final service = ProfilePhotoService();
          final path = await service.prepare(original.path);
          final codec = await ui.instantiateImageCodec(
            await File(path).readAsBytes(),
          );
          final image = (await codec.getNextFrame()).image;
          expect((image.width, image.height), (512, 512));
          final pixels = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          expect(pixels!.buffer.asUint8List().sublist(0, 4), [
            19,
            101,
            214,
            255,
          ]);
          image.dispose();
          codec.dispose();
          expect(await File(path).length(), lessThan(5_000_000));
          await service.discard(path);
          expect(await File(path).exists(), isFalse);
          expect(await original.exists(), isTrue);
          final oversized = File('${directory.path}/oversized.png');
          final handle = oversized.openSync(mode: FileMode.write)
            ..truncateSync(10_000_001);
          handle.closeSync();
          await expectLater(
            service.prepare(oversized.path),
            throwsA(isA<ApiException>()),
          );
        });
      } finally {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        directory.deleteSync(recursive: true);
      }
    },
  );

  testWidgets(
    'photo draft stays on save failure and is submitted with profile changes',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync('profile-ui-test-');
      final file = File('${directory.path}/avatar.png')
        ..writeAsBytesSync(_imageBytes);
      final photos = _PhotoService()..selected = file.path;
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
      try {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              authProvider.overrideWith(TestAuthNotifier.new),
              profilePhotoServiceProvider.overrideWithValue(photos),
            ],
            child: MaterialApp.router(
              routerConfig: router,
              theme: AppTheme.dark,
            ),
          ),
        );
        await tester.pumpAndSettle();
        router.push('/profile/edit');
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => precacheImage(
            FileImage(file),
            tester.element(find.byType(EditProfilePage)),
          ),
        );
        await tester.tap(find.byKey(const ValueKey('profile-photo-picker')));
        await tester.pumpAndSettle();
        expect(TestAuthNotifier.savedPhoto, isNull);
        await tester.enterText(
          find.byType(TextFormField).first,
          'Tên có ảnh mới',
        );
        TestAuthNotifier.failSave = true;
        await tester.tap(find.text('Lưu thay đổi'));
        await tester.pumpAndSettle();
        expect(find.text('Không thể kết nối máy chủ.'), findsOneWidget);
        expect(TestAuthNotifier.savedUser, isNull);
        expect(find.byType(EditProfilePage), findsOneWidget);
        TestAuthNotifier.failSave = false;
        await tester.tap(find.text('Lưu thay đổi'));
        await tester.pumpAndSettle();
        expect(TestAuthNotifier.savedPhoto, file.path);
        expect(TestAuthNotifier.savedUser?.displayName, 'Tên có ảnh mới');
        expect(find.text('Hồ sơ'), findsOneWidget);
        expect(photos.discarded, contains(file.path));
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        directory.deleteSync(recursive: true);
      }
    },
  );

  testWidgets(
    'profile adapts to a small phone with large text and changes theme',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final container = ProviderContainer(
        overrides: [authProvider.overrideWith(TestAuthNotifier.new)],
      );
      try {
        await container.read(authProvider.future);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: AppTheme.dark,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(2)),
                child: child!,
              ),
              home: const ProfilePage(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Tên cũ'), findsOneWidget);
        await tester.drag(find.byType(ListView).first, const Offset(0, -500));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('profile-theme-dark')));
        await tester.pumpAndSettle();
        expect(container.read(themeModeProvider), ThemeMode.dark);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
      }
    },
  );

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
      tester
          .widget<TextFormField>(find.byType(TextFormField).at(0))
          .controller
          ?.text,
      'Tên cũ',
    );
    expect(
      tester
          .widget<TextFormField>(find.byType(TextFormField).at(1))
          .controller
          ?.text,
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

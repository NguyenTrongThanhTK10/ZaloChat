import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/presentation/providers/auth_providers.dart';

final avatarBytesProvider = FutureProvider.autoDispose
    .family<Uint8List, String>((ref, url) async {
      final userId = ref.watch(currentUserProvider.select((user) => user?.id));
      if (userId == null) throw StateError('Sign in to view avatars');
      final response = await ref
          .watch(apiClientProvider)
          .dio
          .get<List<int>>(
            url,
            options: Options(responseType: ResponseType.bytes),
          );
      return Uint8List.fromList(response.data!);
    });

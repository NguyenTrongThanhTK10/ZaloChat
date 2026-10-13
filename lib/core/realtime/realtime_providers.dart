import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/presentation/providers/auth_providers.dart';
import 'realtime_service.dart';

final realtimeServiceProvider = Provider<RealtimeService?>((ref) {
  final user = ref.watch(currentUserProvider);
  if (user == null) return null;
  final service = RealtimeService(
    ref.watch(apiClientProvider).dio,
    ref.watch(tokenStoreProvider),
  );
  unawaited(service.connect());
  ref.onDispose(() => unawaited(service.dispose()));
  return service;
});

final connectionStatusProvider = StreamProvider<ConnectionStatus>((ref) async* {
  final service = ref.watch(realtimeServiceProvider);
  if (service == null) {
    yield ConnectionStatus.disconnected;
    return;
  }
  yield service.status;
  yield* service.statuses;
});

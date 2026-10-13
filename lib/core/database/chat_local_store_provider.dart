import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'chat_local_store.dart';

final chatLocalStoreProvider = Provider<ChatLocalStore>((ref) {
  final store = ChatLocalStore();
  ref.onDispose(() => unawaited(store.close()));
  return store;
});

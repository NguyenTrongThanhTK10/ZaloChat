import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum MessageTextSize { small, normal, large }

final messageTextSizeProvider =
    NotifierProvider<MessageTextSizeNotifier, MessageTextSize>(
      MessageTextSizeNotifier.new,
    );

class MessageTextSizeNotifier extends Notifier<MessageTextSize> {
  static const _key = 'message_text_size';
  final _preferences = SharedPreferencesAsync();
  bool _changed = false;

  @override
  MessageTextSize build() {
    unawaited(_load());
    return MessageTextSize.normal;
  }

  Future<void> _load() async {
    final value = await _preferences.getString(_key);
    if (!ref.mounted || _changed) return;
    state = MessageTextSize.values.firstWhere(
      (size) => size.name == value,
      orElse: () => MessageTextSize.normal,
    );
  }

  Future<void> setSize(MessageTextSize size) async {
    _changed = true;
    state = size;
    await _preferences.setString(_key, size.name);
  }
}

final messagePreviewProvider = NotifierProvider<MessagePreviewNotifier, bool>(
  MessagePreviewNotifier.new,
);

class MessagePreviewNotifier extends Notifier<bool> {
  static const _key = 'show_message_preview';
  final _preferences = SharedPreferencesAsync();
  bool _changed = false;

  @override
  bool build() {
    unawaited(_load());
    return true;
  }

  Future<void> _load() async {
    final value = await _preferences.getBool(_key);
    if (!ref.mounted || _changed || value == null) return;
    state = value;
  }

  Future<void> setVisible(bool visible) async {
    _changed = true;
    state = visible;
    await _preferences.setBool(_key, visible);
  }
}

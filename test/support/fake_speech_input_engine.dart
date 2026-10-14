import 'package:appchatdemo/core/media/speech_input.dart';
import 'package:flutter/foundation.dart';

class FakeSpeechInputEngine implements SpeechInputEngine {
  bool available = true;
  Future<bool>? initialization;
  int initializationCount = 0;
  int listenCount = 0;
  int stopCount = 0;
  int cancelCount = 0;
  String? localeId;
  ValueChanged<String>? onStatus;
  ValueChanged<String>? onError;
  void Function(String, bool)? onResult;
  List<SpeechLanguage> installedLanguages = const [
    SpeechLanguage('en_US', 'English'),
    SpeechLanguage('vi-VN', 'Vietnamese'),
  ];

  @override
  Future<bool> initialize({
    required ValueChanged<String> onStatus,
    required ValueChanged<String> onError,
  }) async {
    initializationCount++;
    this.onStatus = onStatus;
    this.onError = onError;
    return initialization == null ? available : await initialization!;
  }

  @override
  Future<List<SpeechLanguage>> languages() async => installedLanguages;
  @override
  Future<SpeechLanguage?> systemLanguage() async =>
      const SpeechLanguage('en_US', 'English');

  @override
  Future<void> listen({
    required String localeId,
    required void Function(String words, bool isFinal) onResult,
  }) async {
    listenCount++;
    this.localeId = localeId;
    this.onResult = onResult;
    onStatus?.call('listening');
  }

  void words(String text, {bool finalResult = false}) =>
      onResult?.call(text, finalResult);
  void done() => onStatus?.call('done');

  @override
  Future<void> stop() async {
    stopCount++;
  }

  @override
  Future<void> cancel() async {
    cancelCount++;
    onStatus?.call('done');
  }
}

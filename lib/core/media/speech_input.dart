import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_to_text.dart';

enum SpeechInputState { idle, starting, listening, finishing }

class SpeechLanguage {
  const SpeechLanguage(this.id, this.name);
  final String id;
  final String name;
}

abstract class SpeechInputEngine {
  Future<bool> initialize({
    required ValueChanged<String> onStatus,
    required ValueChanged<String> onError,
  });
  Future<List<SpeechLanguage>> languages();
  Future<SpeechLanguage?> systemLanguage();
  Future<void> listen({
    required String localeId,
    required void Function(String words, bool isFinal) onResult,
  });
  Future<void> stop();
  Future<void> cancel();
}

class NativeSpeechInputEngine implements SpeechInputEngine {
  final SpeechToText _speech = SpeechToText();

  @override
  Future<bool> initialize({
    required ValueChanged<String> onStatus,
    required ValueChanged<String> onError,
  }) async {
    if (!kIsWeb &&
        defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS) {
      return false;
    }
    return _speech.initialize(
      onStatus: onStatus,
      onError: (error) => onError(error.errorMsg),
      options: [SpeechToText.androidNoBluetooth],
    );
  }

  @override
  Future<List<SpeechLanguage>> languages() async => (await _speech.locales())
      .map((locale) => SpeechLanguage(locale.localeId, locale.name))
      .toList();

  @override
  Future<SpeechLanguage?> systemLanguage() async {
    final locale = await _speech.systemLocale();
    return locale == null ? null : SpeechLanguage(locale.localeId, locale.name);
  }

  @override
  Future<void> listen({
    required String localeId,
    required void Function(String words, bool isFinal) onResult,
  }) async {
    await _speech.listen(
      onResult: (result) =>
          onResult(result.recognizedWords, result.finalResult),
      listenOptions: SpeechListenOptions(
        localeId: localeId,
        listenMode: ListenMode.dictation,
        partialResults: true,
        cancelOnError: true,
        autoPunctuation: true,
        listenFor: const Duration(seconds: 60),
        pauseFor: const Duration(seconds: 4),
      ),
    );
  }

  @override
  Future<void> stop() => _speech.stop();
  @override
  Future<void> cancel() => _speech.cancel();
}

/// One recognizer per app. Partial results replace the current dictated phrase,
/// preserving the draft and selection that existed before listening started.
class SpeechInput extends ChangeNotifier {
  SpeechInput(this._engine);

  final SpeechInputEngine _engine;
  SpeechInputState _state = SpeechInputState.idle;
  TextEditingValue _original = TextEditingValue.empty;
  TextEditingValue value = TextEditingValue.empty;
  String? error;
  String languageName = 'Tiếng Việt';
  bool _initialized = false;
  Future<bool>? _initializing;
  SpeechLanguage? _language;
  bool _acceptResults = false;
  bool _disposed = false;
  int _session = 0;
  Timer? _deadline;

  SpeechInputState get state => _state;
  bool get active => _state != SpeechInputState.idle;

  Future<void> start(TextEditingValue draft) async {
    if (active || _disposed) return;
    final session = ++_session;
    _original = draft;
    value = draft;
    error = null;
    _state = SpeechInputState.starting;
    notifyListeners();
    try {
      _initializing ??= _initialize();
      final available = await _initializing!;
      if (!_current(session)) return;
      if (!available) {
        _fail(
          'Chưa dùng được nhận dạng giọng nói. Hãy kiểm tra quyền micro, '
          'quyền nhận dạng giọng nói và dịch vụ trên thiết bị.',
        );
        return;
      }
      if (_language == null) {
        final languages = await _engine.languages();
        final vietnamese = languages.where(
          (language) =>
              language.id.toLowerCase().replaceAll('-', '_').split('_').first ==
              'vi',
        );
        _language =
            vietnamese.firstOrNull ??
            await _engine.systemLanguage() ??
            const SpeechLanguage('vi_VN', 'Tiếng Việt');
      }
      if (!_current(session)) return;
      languageName = _language!.id.toLowerCase().startsWith('vi')
          ? 'Tiếng Việt'
          : _language!.name;
      _acceptResults = true;
      await _engine.listen(
        localeId: _language!.id,
        onResult: (words, isFinal) {
          if (!_current(session) || !_acceptResults) return;
          _replacePhrase(words);
          if (isFinal) {
            _state = SpeechInputState.finishing;
            _awaitFinalStatus(session);
          }
          notifyListeners();
        },
      );
      if (_current(session) && _state == SpeechInputState.starting) {
        _deadline = Timer(const Duration(seconds: 5), () {
          if (_current(session) && _state == SpeechInputState.starting) {
            _fail('Không bắt đầu nhận dạng được. Vui lòng thử lại.');
          }
        });
      }
    } catch (_) {
      if (_current(session)) {
        _fail('Không mở được nhận dạng giọng nói. Vui lòng thử lại.');
      }
    }
  }

  Future<bool> _initialize() async {
    try {
      _initialized = await _engine.initialize(
        onStatus: _onStatus,
        onError: (code) {
          if (!_disposed &&
              (_acceptResults || _state == SpeechInputState.starting)) {
            _fail(_errorMessage(code));
          }
        },
      );
      return _initialized;
    } finally {
      // Successful initialization retains the callbacks for the app lifetime.
      if (!_initialized) _initializing = null;
    }
  }

  void _replacePhrase(String words) {
    words = words.trim();
    if (words.isEmpty) return;
    final selection = _original.selection;
    final start = selection.isValid
        ? selection.start.clamp(0, _original.text.length)
        : _original.text.length;
    final end = selection.isValid
        ? selection.end.clamp(start, _original.text.length)
        : start;
    final prefix = _original.text.substring(0, start);
    final suffix = _original.text.substring(end);
    final before = prefix.isNotEmpty && !RegExp(r'[\s(\[{]$').hasMatch(prefix)
        ? ' '
        : '';
    final after =
        suffix.isNotEmpty && !RegExp(r'^[\s.,!?;:)\]}]').hasMatch(suffix)
        ? ' '
        : '';
    final insertion = '$before$words$after';
    value = TextEditingValue(
      text: '$prefix$insertion$suffix',
      selection: TextSelection.collapsed(
        offset: prefix.length + insertion.length,
      ),
    );
  }

  void _onStatus(String status) {
    if (!active || _disposed || !_acceptResults) return;
    if (status == SpeechToText.listeningStatus &&
        _state == SpeechInputState.starting) {
      _deadline?.cancel();
      _state = SpeechInputState.listening;
      notifyListeners();
    } else if (status == SpeechToText.notListeningStatus) {
      _state = SpeechInputState.finishing;
      _awaitFinalStatus(_session);
      notifyListeners();
    } else if (status == SpeechToText.doneStatus) {
      _finish(_session);
    }
  }

  Future<void> stop() async {
    if (!active || _disposed) return;
    if (_state == SpeechInputState.starting) {
      await cancel();
      return;
    }
    final session = _session;
    _state = SpeechInputState.finishing;
    _awaitFinalStatus(session);
    notifyListeners();
    try {
      await _engine.stop();
    } catch (_) {
      if (_current(session)) _finish(session);
    }
  }

  Future<void> cancel() async {
    if (!active || _disposed) return;
    final session = ++_session;
    _acceptResults = false;
    _deadline?.cancel();
    value = _original;
    _state = SpeechInputState.finishing;
    notifyListeners();
    await _cancelEngine(session);
  }

  void _fail(String message) {
    error = message;
    final session = ++_session;
    _acceptResults = false;
    _deadline?.cancel();
    _state = SpeechInputState.finishing;
    notifyListeners();
    unawaited(_cancelEngine(session));
  }

  Future<void> _cancelEngine(int session) async {
    try {
      if (_initialized) await _engine.cancel();
    } catch (_) {
      // Native recognition can already be closed after an interruption.
    } finally {
      if (_current(session)) _finish(session);
    }
  }

  void _awaitFinalStatus(int session) {
    _deadline?.cancel();
    _deadline = Timer(const Duration(seconds: 3), () {
      if (_current(session)) {
        _acceptResults = false;
        unawaited(_cancelEngine(session));
      }
    });
  }

  void _finish(int session) {
    if (!_current(session)) return;
    _deadline?.cancel();
    _acceptResults = false;
    _state = SpeechInputState.idle;
    notifyListeners();
  }

  bool _current(int session) => !_disposed && session == _session;

  String _errorMessage(String code) => switch (code) {
    'error_no_match' || 'error_speech_timeout' =>
      'Chưa nghe rõ lời nói. Nhấn Nói để nhập và thử lại.',
    'error_network' || 'error_network_timeout' || 'error_server_disconnected' =>
      'Nhận dạng giọng nói cần kết nối mạng. Kiểm tra mạng rồi thử lại.',
    'error_permission' || 'error_insufficient_permissions' =>
      'Hãy cấp quyền micro và nhận dạng giọng nói trong cài đặt ứng dụng.',
    'error_language_not_supported' || 'error_language_unavailable' =>
      'Ngôn ngữ nhận dạng chưa có trên thiết bị. Kiểm tra cài đặt giọng nói.',
    _ => 'Không nhận dạng được giọng nói. Vui lòng thử lại.',
  };

  @override
  void dispose() {
    _disposed = true;
    _session++;
    _acceptResults = false;
    _deadline?.cancel();
    if (_initialized) unawaited(_engine.cancel().catchError((Object _) {}));
    super.dispose();
  }
}

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../../features/chat/domain/repositories/message_repository.dart';

class VoicePlayback extends ChangeNotifier {
  VoicePlayback(this._repository) {
    _stateSubscription = _player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed && !_resetting) {
        unawaited(_resetAfterCompletion());
      }
      _notify();
    });
    _positionSubscription = _player.positionStream.listen((_) => _notify());
  }

  final MessageRepository _repository;
  final AudioPlayer _player = AudioPlayer();
  StreamSubscription<PlayerState>? _stateSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  String? messageId;
  bool loading = false;
  bool _disposed = false;
  bool _resetting = false;
  bool get isPlaying => _player.playing;
  Duration get position => _player.position;

  Future<void> pause() async {
    if (!_disposed) await _player.pause();
  }

  Future<void> toggle(String id) async {
    if (loading || _disposed) return;
    if (messageId == id) {
      if (_player.playing) {
        await _player.pause();
      } else {
        unawaited(_play());
      }
      _notify();
      return;
    }
    loading = true;
    messageId = id;
    _notify();
    try {
      await _player.stop();
      if (_disposed) return;
      final path = await _repository.downloadVoice(id);
      if (_disposed) return;
      await _player.setFilePath(path);
      if (_disposed) return;
      unawaited(_play());
    } catch (_) {
      messageId = null;
      rethrow;
    } finally {
      loading = false;
      _notify();
    }
  }

  Future<void> _play() async {
    try {
      await _player.play();
    } catch (_) {
      // Switching messages interrupts the previous play future.
      _notify();
    }
  }

  Future<void> _resetAfterCompletion() async {
    _resetting = true;
    try {
      await _player.pause();
      await _player.seek(Duration.zero);
    } catch (_) {
      // The player may be disposed while a recording ends.
    } finally {
      _resetting = false;
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_stateSubscription?.cancel());
    unawaited(_positionSubscription?.cancel());
    unawaited(_player.dispose());
    super.dispose();
  }
}

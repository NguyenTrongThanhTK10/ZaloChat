import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

class VoiceRecording {
  const VoiceRecording(this.path, this.durationMs);

  final String path;
  final int durationMs;
}

class VoiceRecorder {
  final AudioRecorder _recorder = AudioRecorder();
  final Stopwatch _watch = Stopwatch();

  Future<bool> start() async {
    if (!await _recorder.hasPermission()) return false;
    final directory = Directory(
      '${(await getTemporaryDirectory()).path}/voice',
    );
    await directory.create(recursive: true);
    final path = '${directory.path}/${const Uuid().v4()}.m4a';
    await _recorder.start(
      const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 64000),
      path: path,
    );
    _watch
      ..reset()
      ..start();
    return true;
  }

  Duration get elapsed => _watch.elapsed;

  Future<VoiceRecording?> stop() async {
    _watch.stop();
    final path = await _recorder.stop();
    if (path == null) return null;
    return VoiceRecording(path, _watch.elapsedMilliseconds.clamp(0, 120000));
  }

  Future<void> cancel() async {
    _watch.stop();
    await _recorder.cancel();
  }

  Future<void> dispose() => _recorder.dispose();
}

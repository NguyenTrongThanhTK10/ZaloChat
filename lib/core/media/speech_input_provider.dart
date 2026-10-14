import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'speech_input.dart';

final speechInputProvider = Provider<SpeechInput>((ref) {
  final input = SpeechInput(NativeSpeechInputEngine());
  ref.onDispose(input.dispose);
  return input;
});

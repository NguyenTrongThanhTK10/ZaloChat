import 'dart:async';

import 'package:appchatdemo/core/media/speech_input.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_speech_input_engine.dart';

void main() {
  test(
    'partial results replace the phrase and keep surrounding draft text',
    () async {
      final engine = FakeSpeechInputEngine();
      final input = SpeechInput(engine);
      addTearDown(input.dispose);
      await input.start(
        const TextEditingValue(
          text: 'Chào nhé',
          selection: TextSelection.collapsed(offset: 4),
        ),
      );
      expect(engine.localeId, 'vi-VN');
      engine.words('bạn');
      expect(input.value.text, 'Chào bạn nhé');
      engine.words('bạn thân');
      engine.words('bạn thân', finalResult: true);
      engine.done();
      expect(input.value.text, 'Chào bạn thân nhé');
      expect(input.state, SpeechInputState.idle);

      await input.start(
        const TextEditingValue(
          text: 'Tôi thích mèo nhất',
          selection: TextSelection(baseOffset: 10, extentOffset: 13),
        ),
      );
      engine.words('chó', finalResult: true);
      engine.done();
      expect(input.value.text, 'Tôi thích chó nhất');
      expect(engine.initializationCount, 1);
    },
  );

  test(
    'cancel restores the draft and ignores late callbacks from that session',
    () async {
      final engine = FakeSpeechInputEngine();
      final input = SpeechInput(engine);
      addTearDown(input.dispose);
      const draft = TextEditingValue(
        text: 'Bản nháp',
        selection: TextSelection.collapsed(offset: 8),
      );
      await input.start(draft);
      engine.words('chưa gửi');
      final oldResult = engine.onResult!;
      await input.cancel();
      expect(input.value, draft);
      oldResult('kết quả đến muộn', true);
      expect(input.value, draft);
      await input.start(draft);
      oldResult('kết quả của phiên cũ', true);
      expect(input.value, draft);
      engine.words('mới', finalResult: true);
      engine.done();
      expect(input.value.text, 'Bản nháp mới');
    },
  );

  test('stop accepts final words before recognition finishes', () async {
    final engine = FakeSpeechInputEngine();
    final input = SpeechInput(engine);
    addTearDown(input.dispose);
    await input.start(TextEditingValue.empty);
    engine.words('xin');
    await input.stop();
    expect(input.state, SpeechInputState.finishing);
    expect(engine.stopCount, 1);
    engine.words('xin chào', finalResult: true);
    engine.done();
    expect(input.value.text, 'xin chào');
    expect(input.active, isFalse);
  });

  test(
    'unavailable recognition preserves the draft and allows retry',
    () async {
      final engine = FakeSpeechInputEngine()..available = false;
      final input = SpeechInput(engine);
      addTearDown(input.dispose);
      const draft = TextEditingValue(text: 'Đang soạn');
      await input.start(draft);
      expect(input.error, contains('quyền micro'));
      expect(input.value, draft);
      expect(input.active, isFalse);
      expect(engine.listenCount, 0);
      engine.available = true;
      await input.start(draft);
      expect(engine.listenCount, 1);
      expect(input.error, isNull);
    },
  );

  test(
    'network error retains recognized text and ignores later results',
    () async {
      final engine = FakeSpeechInputEngine();
      final input = SpeechInput(engine);
      addTearDown(input.dispose);
      await input.start(TextEditingValue.empty);
      engine.words('Đã nhận được');
      engine.onError!('error_network');
      await Future<void>.delayed(Duration.zero);
      expect(input.error, contains('kết nối mạng'));
      expect(input.active, isFalse);
      engine.words('không thay thế bản nháp', finalResult: true);
      expect(input.value.text, 'Đã nhận được');
    },
  );

  test(
    'closing during permission initialization prevents microphone startup',
    () async {
      final permission = Completer<bool>();
      final engine = FakeSpeechInputEngine()
        ..initialization = permission.future;
      final input = SpeechInput(engine);
      final starting = input.start(TextEditingValue.empty);
      await input.cancel();
      permission.complete(true);
      await starting;
      expect(engine.listenCount, 0);
      expect(input.active, isFalse);
      input.dispose();
    },
  );
}

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import '../../../../core/network/api_exception.dart';
import '../../domain/entities/chat_message.dart';
import '../../domain/entities/message_page.dart';
import '../../domain/repositories/message_repository.dart';
import '../models/message_mapper.dart';

class RemoteMessageRepository implements MessageRepository {
  RemoteMessageRepository(this._dio, this._accountId);

  final Dio _dio;
  final String? _accountId;

  @override
  Future<MessagePage> fetchPage(
    String conversationId, {
    int? beforeSequence,
    int limit = 30,
  }) async {
    try {
      final query = <String, Object>{'limit': limit};
      if (beforeSequence != null) query['beforeSequence'] = beforeSequence;
      final response = await _dio.get(
        '/api/conversations/$conversationId/messages',
        queryParameters: query,
      );
      final json = Map<String, dynamic>.from(response.data as Map);
      return MessagePage(
        items: (json['items'] as List)
            .map(messageFromJson)
            .toList(growable: false),
        nextCursor: (json['nextCursor'] as num?)?.toInt(),
      );
    } catch (error) {
      throw ApiException.from(error);
    }
  }

  @override
  Future<ChatMessage> send(
    String conversationId,
    String clientMessageId,
    String text, {
    String? replyToMessageId,
  }) async {
    try {
      final response = await _dio.post(
        '/api/conversations/$conversationId/messages',
        data: {
          'clientMessageId': clientMessageId,
          'text': text,
          'replyToMessageId': ?replyToMessageId,
        },
      );
      return messageFromJson(response.data);
    } catch (error) {
      throw ApiException.from(error);
    }
  }

  @override
  Future<ChatMessage> setHeart(
    String messageId, {
    required bool hearted,
  }) async {
    try {
      final path = '/api/messages/$messageId/heart';
      final response = hearted ? await _dio.put(path) : await _dio.delete(path);
      return messageFromJson(response.data);
    } catch (error) {
      throw ApiException.from(error);
    }
  }

  @override
  Future<ChatMessage> setReaction(
    String messageId,
    MessageReaction reaction, {
    required bool selected,
  }) async {
    try {
      final path = '/api/messages/$messageId/reaction';
      final response = !selected
          ? await _dio.delete('$path/${reaction.name}')
          : await _dio.put(path, data: {'type': reaction.name});
      return messageFromJson(response.data);
    } catch (error) {
      throw ApiException.from(error);
    }
  }

  @override
  Future<ChatMessage> recall(String messageId) async {
    try {
      final response = await _dio.put('/api/messages/$messageId/recall');
      return messageFromJson(response.data);
    } catch (error) {
      throw ApiException.from(error);
    }
  }

  @override
  Future<ChatMessage> sendVoice(
    String conversationId,
    String clientMessageId,
    String filePath,
    int durationMs, {
    String? replyToMessageId,
  }) async {
    try {
      final form = FormData.fromMap({
        'clientMessageId': clientMessageId,
        'durationMs': durationMs.toString(),
        'replyToMessageId': ?replyToMessageId,
        'audio': await MultipartFile.fromFile(
          filePath,
          filename: 'voice.m4a',
          contentType: DioMediaType('audio', 'mp4'),
        ),
      });
      final response = await _dio.post(
        '/api/conversations/$conversationId/voice',
        data: form,
        options: Options(sendTimeout: const Duration(seconds: 60)),
      );
      return messageFromJson(response.data);
    } catch (error) {
      throw ApiException.from(error);
    }
  }

  @override
  Future<String> downloadVoice(String messageId) async {
    final accountId = _accountId;
    if (accountId == null) throw StateError('Sign in to play voice messages');
    final cache = Directory(
      '${(await getTemporaryDirectory()).path}/voice/$accountId',
    );
    await cache.create(recursive: true);
    final file = File('${cache.path}/$messageId.m4a');
    if (await file.exists() && await file.length() > 0) return file.path;
    final partial = File('${file.path}.partial');
    try {
      await _dio.download('/api/messages/$messageId/audio', partial.path);
      await partial.rename(file.path);
      return file.path;
    } catch (error) {
      if (await partial.exists()) await partial.delete();
      throw ApiException.from(error);
    }
  }
}

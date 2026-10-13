import 'package:dio/dio.dart';

import '../../../../core/network/api_exception.dart';
import '../../domain/entities/chat_message.dart';
import '../../domain/entities/message_page.dart';
import '../../domain/repositories/message_repository.dart';
import '../models/message_mapper.dart';

class RemoteMessageRepository implements MessageRepository {
  RemoteMessageRepository(this._dio);

  final Dio _dio;

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
    String text,
  ) async {
    try {
      final response = await _dio.post(
        '/api/conversations/$conversationId/messages',
        data: {'clientMessageId': clientMessageId, 'text': text},
      );
      return messageFromJson(response.data);
    } catch (error) {
      throw ApiException.from(error);
    }
  }
}

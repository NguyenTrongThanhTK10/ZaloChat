import 'package:dio/dio.dart';

import '../../../../core/network/api_exception.dart';
import '../../../auth/domain/entities/chat_user.dart';
import '../../domain/entities/conversation.dart';
import '../../domain/repositories/conversation_repository.dart';
import '../models/conversation_mapper.dart';

class RemoteConversationRepository implements ConversationRepository {
  RemoteConversationRepository(this._dio);

  final Dio _dio;

  @override
  Future<ChatUser> getUser(String userId) async {
    try {
      final response = await _dio.get(
        '/api/users/${Uri.encodeComponent(userId)}',
      );
      return _userFromJson(response.data);
    } catch (error) {
      throw ApiException.from(error);
    }
  }

  @override
  Future<List<Conversation>> list() async {
    try {
      final response = await _dio.get('/api/conversations');
      return (response.data as List)
          .map((item) => conversationFromJson(item))
          .toList(growable: false);
    } catch (error) {
      throw ApiException.from(error);
    }
  }

  @override
  Future<List<ChatUser>> searchUsers(String query) async {
    try {
      final response = await _dio.get(
        '/api/users',
        queryParameters: {'query': query},
      );
      return (response.data as List).map(_userFromJson).toList(growable: false);
    } catch (error) {
      throw ApiException.from(error);
    }
  }

  ChatUser _userFromJson(Object? source) {
    final json = Map<String, dynamic>.from(source as Map);
    return ChatUser(
      id: json['id'] as String,
      displayName: json['displayName'] as String,
      email: json['email'] as String,
      avatarUrl: json['avatarUrl'] as String?,
    );
  }

  @override
  Future<Conversation> start(String peerUserId) async {
    try {
      final response = await _dio.post(
        '/api/conversations',
        data: {'peerUserId': peerUserId},
      );
      return conversationFromJson(response.data);
    } catch (error) {
      throw ApiException.from(error);
    }
  }

  @override
  Future<int> markRead(String conversationId, int throughSequence) async {
    try {
      final response = await _dio.post(
        '/api/conversations/$conversationId/read',
        data: {'throughSequence': throughSequence},
      );
      final body = Map<String, dynamic>.from(response.data as Map);
      return (body['lastReadSequence'] as num).toInt();
    } catch (error) {
      throw ApiException.from(error);
    }
  }

  @override
  Future<int> markDelivered(String conversationId, int throughSequence) async {
    try {
      final response = await _dio.post(
        '/api/conversations/$conversationId/delivered',
        data: {'throughSequence': throughSequence},
      );
      final body = Map<String, dynamic>.from(response.data as Map);
      return (body['lastDeliveredSequence'] as num).toInt();
    } catch (error) {
      throw ApiException.from(error);
    }
  }
}

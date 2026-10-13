import '../../../auth/domain/entities/chat_user.dart';
import '../entities/conversation.dart';

abstract class ConversationRepository {
  Future<List<Conversation>> list();
  Future<List<ChatUser>> searchUsers(String query);
  Future<Conversation> start(String peerUserId);
  Future<int> markRead(String conversationId, int throughSequence);
}

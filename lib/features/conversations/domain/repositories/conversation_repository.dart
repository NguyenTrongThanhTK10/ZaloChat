import '../../../auth/domain/entities/chat_user.dart';
import '../entities/conversation.dart';

abstract class ConversationRepository {
  Future<ChatUser> getUser(String userId);
  Future<List<Conversation>> list();
  Future<List<ChatUser>> searchUsers(String query);
  Future<Conversation> start(String peerUserId);
  Future<int> markRead(String conversationId, int throughSequence);
}

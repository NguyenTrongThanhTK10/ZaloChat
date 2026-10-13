import '../entities/chat_message.dart';
import '../entities/message_page.dart';

abstract class MessageRepository {
  Future<MessagePage> fetchPage(
    String conversationId, {
    int? beforeSequence,
    int limit = 30,
  });

  Future<ChatMessage> send(
    String conversationId,
    String clientMessageId,
    String text,
  );
}

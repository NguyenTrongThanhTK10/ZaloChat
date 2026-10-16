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
    String text, {
    String? replyToMessageId,
  });

  Future<ChatMessage> sendVoice(
    String conversationId,
    String clientMessageId,
    String filePath,
    int durationMs, {
    String? replyToMessageId,
  });

  Future<String> downloadVoice(String messageId);

  Future<ChatMessage> sendAttachment(
    String conversationId,
    String clientMessageId,
    String filePath,
    String fileName,
    MessageKind kind, {
    String text = '',
    String? replyToMessageId,
  });

  Future<String> downloadAttachment(ChatMessage message);

  Future<ChatMessage> setHeart(String messageId, {required bool hearted});

  Future<ChatMessage> setReaction(
    String messageId,
    MessageReaction reaction, {
    required bool selected,
  });

  Future<ChatMessage> recall(String messageId);
}

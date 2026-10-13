enum MessageStatus { sending, sent, delivered, read, failed }

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.clientMessageId,
    required this.conversationId,
    required this.senderId,
    required this.text,
    required this.sequence,
    required this.createdAt,
    required this.status,
  });

  final String id;
  final String clientMessageId;
  final String conversationId;
  final String senderId;
  final String text;
  final int sequence;
  final DateTime createdAt;
  final MessageStatus status;

  ChatMessage copyWith({String? id, int? sequence, MessageStatus? status}) {
    return ChatMessage(
      id: id ?? this.id,
      clientMessageId: clientMessageId,
      conversationId: conversationId,
      senderId: senderId,
      text: text,
      sequence: sequence ?? this.sequence,
      createdAt: createdAt,
      status: status ?? this.status,
    );
  }
}

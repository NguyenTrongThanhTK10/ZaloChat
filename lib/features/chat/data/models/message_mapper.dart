import '../../domain/entities/chat_message.dart';

ChatMessage messageFromJson(Object? source) {
  final json = Map<String, dynamic>.from(source as Map);
  return ChatMessage(
    id: json['id'] as String,
    clientMessageId: json['clientMessageId'] as String,
    conversationId: json['conversationId'] as String,
    senderId: json['senderId'] as String,
    text: json['text'] as String,
    sequence: (json['sequence'] as num).toInt(),
    createdAt: DateTime.parse(json['createdAt'] as String).toLocal(),
    status: MessageStatus.sent,
  );
}

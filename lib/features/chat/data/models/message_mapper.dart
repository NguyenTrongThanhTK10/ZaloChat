import '../../domain/entities/chat_message.dart';

ChatMessage messageFromJson(Object? source) {
  final json = Map<String, dynamic>.from(source as Map);
  return ChatMessage(
    id: json['id'] as String,
    clientMessageId: json['clientMessageId'] as String,
    conversationId: json['conversationId'] as String,
    senderId: json['senderId'] as String,
    text: json['text'] as String,
    kind: messageKindFromName(json['kind']),
    attachment: json['attachment'] is Map
        ? MessageAttachment.fromJson(
            Map<String, dynamic>.from(json['attachment'] as Map),
          )
        : null,
    voiceDurationMs: (json['voiceDurationMs'] as num?)?.toInt(),
    replyTo: json['replyTo'] is Map
        ? MessageReply.fromJson(
            Map<String, dynamic>.from(json['replyTo'] as Map),
          )
        : null,
    sequence: (json['sequence'] as num).toInt(),
    createdAt: DateTime.parse(json['createdAt'] as String).toLocal(),
    status: MessageStatus.sent,
    isRecalled: json['isRecalled'] == true,
    heartedBy: (json['heartedBy'] as List? ?? const [])
        .map((id) => id.toString())
        .toList(growable: false),
    reactions: (json['reactions'] as Map? ?? const {}).map(
      (userId, reaction) => MapEntry(
        userId.toString(),
        MessageReaction.values.byName(reaction.toString()),
      ),
    ),
    reactionSets: (json['reactionSets'] as Map? ?? const {}).map(
      (userId, reactions) => MapEntry(
        userId.toString(),
        (reactions as List)
            .map(
              (reaction) => MessageReaction.values.byName(reaction.toString()),
            )
            .toList(growable: false),
      ),
    ),
  );
}

import '../../domain/entities/conversation.dart';

Conversation conversationFromJson(Object? source) {
  final json = Map<String, dynamic>.from(source as Map);
  final peer = Map<String, dynamic>.from(json['peer'] as Map);
  final lastMessage = json['lastMessage'] is Map
      ? Map<String, dynamic>.from(json['lastMessage'] as Map)
      : null;
  return Conversation(
    id: json['id'] as String,
    title: peer['displayName'] as String,
    peerId: peer['id'] as String,
    unreadCount: (json['unreadCount'] as num?)?.toInt() ?? 0,
    lastReadSequence: (json['lastReadSequence'] as num?)?.toInt() ?? 0,
    peerLastReadSequence: (json['peerLastReadSequence'] as num?)?.toInt() ?? 0,
    lastMessagePreview: lastMessage?['text'] as String?,
    lastMessageAt: lastMessage?['createdAt'] is String
        ? DateTime.parse(lastMessage!['createdAt'] as String).toLocal()
        : null,
  );
}

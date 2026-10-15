enum MessageStatus { sending, sent, delivered, read, failed }

enum MessageKind { text, voice }

enum MessageReaction { heart, like, laugh, wow, sad, angry }

class MessageReply {
  const MessageReply({
    required this.id,
    required this.senderId,
    required this.text,
    required this.kind,
  });

  factory MessageReply.fromMessage(ChatMessage message) => MessageReply(
    id: message.id,
    senderId: message.senderId,
    text: message.text,
    kind: message.kind,
  );

  factory MessageReply.fromJson(Map<String, dynamic> json) => MessageReply(
    id: json['id'] as String,
    senderId: json['senderId'] as String,
    text: json['text'] as String,
    kind: json['kind'] == 'voice' ? MessageKind.voice : MessageKind.text,
  );

  final String id;
  final String senderId;
  final String text;
  final MessageKind kind;

  Map<String, dynamic> toJson() => {
    'id': id,
    'senderId': senderId,
    'text': text,
    'kind': kind.name,
  };
}

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
    this.kind = MessageKind.text,
    this.voiceDurationMs,
    this.heartedBy = const [],
    this.reactions = const {},
    this.reactionSets = const {},
    this.replyTo,
    this.isRecalled = false,
  });

  final String id;
  final String clientMessageId;
  final String conversationId;
  final String senderId;
  final String text;
  final int sequence;
  final DateTime createdAt;
  final MessageStatus status;
  final MessageKind kind;
  final int? voiceDurationMs;
  final List<String> heartedBy;
  final Map<String, MessageReaction> reactions;
  final Map<String, List<MessageReaction>> reactionSets;
  final MessageReply? replyTo;
  final bool isRecalled;

  Map<String, List<MessageReaction>> get effectiveReactionSets {
    final selected = {
      for (final entry in reactionSets.entries) entry.key: [...entry.value],
    };
    for (final entry in reactions.entries) {
      selected.putIfAbsent(entry.key, () => [entry.value]);
    }
    for (final userId in heartedBy) {
      final values = selected.putIfAbsent(userId, () => []);
      if (!values.contains(MessageReaction.heart)) {
        values.add(MessageReaction.heart);
      }
    }
    return selected;
  }

  Map<String, MessageReaction> get effectiveReactions => {
    for (final entry in effectiveReactionSets.entries)
      if (entry.value.isNotEmpty) entry.key: entry.value.last,
  };

  ChatMessage copyWith({
    String? id,
    int? sequence,
    MessageStatus? status,
    List<String>? heartedBy,
    Map<String, MessageReaction>? reactions,
    Map<String, List<MessageReaction>>? reactionSets,
    bool? isRecalled,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      clientMessageId: clientMessageId,
      conversationId: conversationId,
      senderId: senderId,
      text: text,
      sequence: sequence ?? this.sequence,
      createdAt: createdAt,
      status: status ?? this.status,
      kind: kind,
      voiceDurationMs: voiceDurationMs,
      heartedBy: heartedBy ?? this.heartedBy,
      reactions: reactions ?? this.reactions,
      reactionSets: reactionSets ?? this.reactionSets,
      replyTo: replyTo,
      isRecalled: isRecalled ?? this.isRecalled,
    );
  }
}

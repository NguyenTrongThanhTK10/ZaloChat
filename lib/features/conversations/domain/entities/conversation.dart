class Conversation {
  const Conversation({
    required this.id,
    required this.title,
    required this.peerId,
    this.avatarUrl,
    this.isGroup = false,
    this.isOnline,
    this.unreadCount = 0,
    this.isPinned = false,
    this.isMuted = false,
    this.isTyping = false,
    this.lastMessagePreview,
    this.lastMessageAt,
    this.lastReadSequence = 0,
    this.peerLastReadSequence = 0,
  });

  final String id;
  final String title;
  final String peerId;
  final String? avatarUrl;
  final bool isGroup;
  final bool? isOnline;
  final int unreadCount;
  final bool isPinned;
  final bool isMuted;
  final bool isTyping;
  final String? lastMessagePreview;
  final DateTime? lastMessageAt;
  final int lastReadSequence;
  final int peerLastReadSequence;

  Conversation copyWith({
    int? unreadCount,
    String? lastMessagePreview,
    DateTime? lastMessageAt,
    int? lastReadSequence,
    int? peerLastReadSequence,
  }) {
    return Conversation(
      id: id,
      title: title,
      peerId: peerId,
      avatarUrl: avatarUrl,
      isGroup: isGroup,
      isOnline: isOnline,
      unreadCount: unreadCount ?? this.unreadCount,
      isPinned: isPinned,
      isMuted: isMuted,
      isTyping: isTyping,
      lastMessagePreview: lastMessagePreview ?? this.lastMessagePreview,
      lastMessageAt: lastMessageAt ?? this.lastMessageAt,
      lastReadSequence: lastReadSequence ?? this.lastReadSequence,
      peerLastReadSequence: peerLastReadSequence ?? this.peerLastReadSequence,
    );
  }
}

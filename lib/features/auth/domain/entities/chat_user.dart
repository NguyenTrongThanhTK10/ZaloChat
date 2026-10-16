class ChatUser {
  const ChatUser({
    required this.id,
    required this.displayName,
    required this.email,
    this.avatarUrl,
  });

  final String id;
  final String displayName;
  final String email;
  final String? avatarUrl;
}

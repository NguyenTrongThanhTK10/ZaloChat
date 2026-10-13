import 'chat_message.dart';

class MessagePage {
  const MessagePage({required this.items, required this.nextCursor});

  final List<ChatMessage> items;
  final int? nextCursor;
}

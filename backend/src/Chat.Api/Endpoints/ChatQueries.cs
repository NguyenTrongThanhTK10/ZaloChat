using Chat.Api.Models;

namespace Chat.Api.Endpoints;

internal static class ChatQueries
{
    public static ConversationRecord GetConversation(ChatState state, Guid conversationId, Guid userId)
    {
        var conversation = state.Conversations.FirstOrDefault(item => item.Id == conversationId);
        if (conversation is null || !conversation.Contains(userId))
            throw ApiException.NotFound("Conversation not found.");
        return conversation;
    }

    public static ConversationDto ToDto(ChatState state, ConversationRecord conversation, Guid userId)
    {
        var peer = state.Users.Single(user => user.Id == conversation.PeerId(userId));
        var lastMessage = state.Messages
            .Where(message => message.ConversationId == conversation.Id)
            .MaxBy(message => message.Sequence);
        var lastRead = conversation.ReadSequence(userId);
        var unreadCount = state.Messages.LongCount(message =>
            message.ConversationId == conversation.Id &&
            message.SenderId != userId && message.Sequence > lastRead);

        return new ConversationDto(conversation.Id, UserDto.From(peer),
            lastMessage is null ? null : MessageDto.From(lastMessage), unreadCount,
            lastRead, conversation.ReadSequence(peer.Id),
            conversation.DeliveredSequence(userId), conversation.DeliveredSequence(peer.Id));
    }
}

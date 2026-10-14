using System.Security.Claims;
using Chat.Api.Data;
using Chat.Api.Hubs;
using Chat.Api.Models;
using Microsoft.AspNetCore.SignalR;

namespace Chat.Api.Endpoints;

public static partial class ChatEndpoints
{
    public static void MapChatEndpoints(this WebApplication app)
    {
        var api = app.MapGroup("/api").RequireAuthorization();
        api.MapGet("/users", GetUsersAsync);
        api.MapGet("/users/{id:guid}", GetUserAsync);
        api.MapGet("/conversations", GetConversationsAsync);
        api.MapPost("/conversations", CreateConversationAsync);
        api.MapGet("/conversations/{id:guid}/messages", GetMessagesAsync);
        api.MapPost("/conversations/{id:guid}/messages", SendMessageAsync)
            .RequireRateLimiting("send");
        api.MapPost("/conversations/{id:guid}/voice", SendVoiceAsync)
            .RequireRateLimiting("send");
        api.MapGet("/messages/{id:guid}/audio", GetVoiceAsync);
        api.MapPut("/messages/{id:guid}/heart", AddHeartAsync);
        api.MapDelete("/messages/{id:guid}/heart", RemoveHeartAsync);
        api.MapPost("/conversations/{id:guid}/read", MarkReadAsync);
    }

    private static async Task<IResult> GetUsersAsync(
        string? query, ClaimsPrincipal principal, ChatStore store, CancellationToken cancellationToken)
    {
        if (query?.Length > 80) throw ApiException.Validation("Search query is too long.");
        var userId = principal.CurrentUserId();
        var term = query?.Trim() ?? "";
        var users = await store.ReadAsync(state => state.Users
            .Where(user => user.Id != userId &&
                (term.Length == 0 || user.DisplayName.Contains(term, StringComparison.OrdinalIgnoreCase) ||
                 user.Email.Contains(term, StringComparison.OrdinalIgnoreCase)))
            .OrderBy(user => user.DisplayName)
            .Take(50)
            .Select(UserDto.From)
            .ToList(), cancellationToken);
        return Results.Ok(users);
    }

    private static async Task<IResult> GetUserAsync(
        Guid id, ClaimsPrincipal principal, ChatStore store, CancellationToken cancellationToken)
    {
        var currentUserId = principal.CurrentUserId();
        var user = await store.ReadAsync(state => state.Users
            .Where(item => item.Id == id && item.Id != currentUserId)
            .Select(UserDto.From)
            .FirstOrDefault(), cancellationToken);
        if (user is null) throw ApiException.NotFound("User not found.");
        return Results.Ok(user);
    }

    private static async Task<IResult> GetConversationsAsync(
        ClaimsPrincipal principal, ChatStore store, CancellationToken cancellationToken)
    {
        var userId = principal.CurrentUserId();
        var conversations = await store.ReadAsync(state => state.Conversations
            .Where(conversation => conversation.Contains(userId))
            .Select(conversation => new
            {
                Dto = ChatQueries.ToDto(state, conversation, userId),
                Activity = state.Messages
                    .Where(message => message.ConversationId == conversation.Id)
                    .MaxBy(message => message.Sequence)?.CreatedAt ?? conversation.CreatedAt
            })
            .OrderByDescending(item => item.Activity)
            .Select(item => item.Dto)
            .ToList(), cancellationToken);
        return Results.Ok(conversations);
    }

    private static async Task<IResult> CreateConversationAsync(
        CreateConversationRequest request, ClaimsPrincipal principal, ChatStore store,
        IHubContext<ChatHub> hub, ILogger<ChatHub> logger, CancellationToken cancellationToken)
    {
        var userId = principal.CurrentUserId();
        if (request.PeerUserId == Guid.Empty || request.PeerUserId == userId)
            throw ApiException.Validation("A different peer user ID is required.");

        var result = await store.MutateAsync(state =>
        {
            if (state.Users.All(user => user.Id != request.PeerUserId))
                throw ApiException.NotFound("Peer user not found.");
            var existing = state.Conversations.FirstOrDefault(conversation =>
                conversation.Contains(userId) && conversation.Contains(request.PeerUserId));
            var created = existing is null;
            var conversation = existing ?? new ConversationRecord
            {
                Id = Guid.NewGuid(),
                UserAId = userId.CompareTo(request.PeerUserId) < 0 ? userId : request.PeerUserId,
                UserBId = userId.CompareTo(request.PeerUserId) < 0 ? request.PeerUserId : userId,
                CreatedAt = DateTimeOffset.UtcNow
            };
            if (created) state.Conversations.Add(conversation);
            return new ConversationMutation(
                ChatQueries.ToDto(state, conversation, userId),
                ChatQueries.ToDto(state, conversation, request.PeerUserId),
                request.PeerUserId, created);
        }, cancellationToken);

        if (result.Created)
            await PublishConversationsAsync(hub, logger, userId, result.PeerId,
                result.ForUser, result.ForPeer);
        return Results.Json(result.ForUser, statusCode: result.Created ? 201 : 200);
    }

    private static async Task<IResult> GetMessagesAsync(
        Guid id, long? beforeSequence, int? limit, ClaimsPrincipal principal,
        ChatStore store, CancellationToken cancellationToken)
    {
        if (beforeSequence is <= 0)
            throw ApiException.Validation("beforeSequence must be positive.");
        var pageSize = limit ?? 30;
        if (pageSize is < 1 or > 100)
            throw ApiException.Validation("limit must be between 1 and 100.");
        var userId = principal.CurrentUserId();
        var page = await store.ReadAsync(state =>
        {
            ChatQueries.GetConversation(state, id, userId);
            var selected = state.Messages
                .Where(message => message.ConversationId == id &&
                    (beforeSequence is null || message.Sequence < beforeSequence))
                .OrderByDescending(message => message.Sequence)
                .Take(pageSize + 1)
                .ToList();
            var items = selected.Take(pageSize).Select(MessageDto.From).ToList();
            long? nextCursor = selected.Count > pageSize ? items[^1].Sequence : null;
            return new MessagePageDto(items, nextCursor);
        }, cancellationToken);
        return Results.Ok(page);
    }

    private static async Task<IResult> SendMessageAsync(
        Guid id, SendMessageRequest request, ClaimsPrincipal principal, ChatStore store,
        IHubContext<ChatHub> hub, ILogger<ChatHub> logger, CancellationToken cancellationToken)
    {
        if (request.ClientMessageId == Guid.Empty)
            throw ApiException.Validation("clientMessageId must be a nonempty UUID.");
        if (string.IsNullOrWhiteSpace(request.Text) || request.Text.Length > 4000)
            throw ApiException.Validation("Text must contain 1 to 4000 characters.");
        var userId = principal.CurrentUserId();
        var result = await store.MutateAsync(state =>
        {
            var conversation = ChatQueries.GetConversation(state, id, userId);
            var existing = state.Messages.FirstOrDefault(message =>
                message.ConversationId == id && message.SenderId == userId &&
                message.ClientMessageId == request.ClientMessageId);
            if (existing is not null)
            {
                if (existing.Kind != "text" || existing.Text != request.Text ||
                    existing.ReplyTo?.Id != request.ReplyToMessageId)
                    throw ApiException.Conflict("clientMessageId was already used with different text.");
                return new SendMutation(MessageDto.From(existing), false,
                    conversation.PeerId(userId),
                    ChatQueries.ToDto(state, conversation, userId),
                    ChatQueries.ToDto(state, conversation, conversation.PeerId(userId)));
            }

            var message = new MessageRecord
            {
                Id = Guid.NewGuid(), ClientMessageId = request.ClientMessageId,
                ConversationId = id, SenderId = userId, Text = request.Text,
                ReplyTo = CreateReply(state, id, request.ReplyToMessageId),
                Sequence = conversation.NextSequence++, CreatedAt = DateTimeOffset.UtcNow
            };
            state.Messages.Add(message);
            var peerId = conversation.PeerId(userId);
            return new SendMutation(MessageDto.From(message), true, peerId,
                ChatQueries.ToDto(state, conversation, userId),
                ChatQueries.ToDto(state, conversation, peerId));
        }, cancellationToken);

        if (result.Created)
        {
            await PublishAsync(async () =>
            {
                await Task.WhenAll(
                    hub.Clients.Group(ChatHub.UserGroup(userId))
                        .SendAsync("MessageCreated", result.Message),
                    hub.Clients.Group(ChatHub.UserGroup(result.PeerId))
                        .SendAsync("MessageCreated", result.Message));
            }, logger);
            await PublishConversationsAsync(hub, logger, userId, result.PeerId,
                result.ForUser, result.ForPeer);
        }
        return Results.Json(result.Message, statusCode: result.Created ? 201 : 200);
    }

    private static MessageReplyDto? CreateReply(ChatState state, Guid conversationId,
        Guid? messageId)
    {
        if (messageId is null) return null;
        var target = state.Messages.FirstOrDefault(message =>
            message.Id == messageId && message.ConversationId == conversationId);
        if (target is null)
            throw ApiException.Validation("The replied message must belong to this conversation.");
        return new MessageReplyDto(target.Id, target.SenderId, target.Text, target.Kind);
    }

    private static async Task<IResult> MarkReadAsync(
        Guid id, MarkReadRequest request, ClaimsPrincipal principal, ChatStore store,
        IHubContext<ChatHub> hub, ILogger<ChatHub> logger, CancellationToken cancellationToken)
    {
        if (request.ThroughSequence < 0)
            throw ApiException.Validation("throughSequence cannot be negative.");
        var userId = principal.CurrentUserId();
        var result = await store.MutateAsync(state =>
        {
            var conversation = ChatQueries.GetConversation(state, id, userId);
            var previous = conversation.ReadSequence(userId);
            var current = Math.Max(previous, Math.Min(request.ThroughSequence,
                conversation.NextSequence - 1));
            conversation.SetReadSequence(userId, current);
            var peerId = conversation.PeerId(userId);
            return new ReadMutation(current, current > previous, peerId,
                ChatQueries.ToDto(state, conversation, userId),
                ChatQueries.ToDto(state, conversation, peerId));
        }, cancellationToken);

        if (result.Advanced)
        {
            var readEvent = new ReadEventDto(id, userId, result.Sequence);
            await PublishAsync(async () =>
            {
                await Task.WhenAll(
                    hub.Clients.Group(ChatHub.UserGroup(userId))
                        .SendAsync("MessageRead", readEvent),
                    hub.Clients.Group(ChatHub.UserGroup(result.PeerId))
                        .SendAsync("MessageRead", readEvent));
            }, logger);
            await PublishConversationsAsync(hub, logger, userId, result.PeerId,
                result.ForUser, result.ForPeer);
        }
        return Results.Ok(new ReadDto(result.Sequence));
    }

    private static Task<IResult> AddHeartAsync(
        Guid id, ClaimsPrincipal principal, ChatStore store,
        IHubContext<ChatHub> hub, ILogger<ChatHub> logger, CancellationToken cancellationToken) =>
        SetHeartAsync(id, true, principal, store, hub, logger, cancellationToken);

    private static Task<IResult> RemoveHeartAsync(
        Guid id, ClaimsPrincipal principal, ChatStore store,
        IHubContext<ChatHub> hub, ILogger<ChatHub> logger, CancellationToken cancellationToken) =>
        SetHeartAsync(id, false, principal, store, hub, logger, cancellationToken);

    private static async Task<IResult> SetHeartAsync(
        Guid id, bool hearted, ClaimsPrincipal principal, ChatStore store,
        IHubContext<ChatHub> hub, ILogger<ChatHub> logger, CancellationToken cancellationToken)
    {
        var userId = principal.CurrentUserId();
        var result = await store.MutateAsync(state =>
        {
            var message = state.Messages.FirstOrDefault(item => item.Id == id);
            if (message is null)
                throw ApiException.NotFound("Message not found.");
            var conversation = ChatQueries.GetConversation(state, message.ConversationId, userId);
            var changed = hearted
                ? !message.HeartedBy.Contains(userId)
                : message.HeartedBy.Contains(userId);
            if (changed)
            {
                if (hearted) message.HeartedBy.Add(userId);
                else message.HeartedBy.Remove(userId);
            }
            return new HeartMutation(MessageDto.From(message), changed,
                conversation.PeerId(userId));
        }, cancellationToken);

        if (result.Changed)
        {
            await PublishAsync(async () =>
            {
                await Task.WhenAll(
                    hub.Clients.Group(ChatHub.UserGroup(userId))
                        .SendAsync("MessageUpdated", result.Message),
                    hub.Clients.Group(ChatHub.UserGroup(result.PeerId))
                        .SendAsync("MessageUpdated", result.Message));
            }, logger);
        }
        return Results.Ok(result.Message);
    }

    private static async Task PublishConversationsAsync(
        IHubContext<ChatHub> hub, ILogger logger, Guid userId, Guid peerId,
        ConversationDto forUser, ConversationDto forPeer)
    {
        await PublishAsync(async () =>
        {
            await Task.WhenAll(
                hub.Clients.Group(ChatHub.UserGroup(userId))
                    .SendAsync("ConversationUpdated", forUser),
                hub.Clients.Group(ChatHub.UserGroup(peerId))
                    .SendAsync("ConversationUpdated", forPeer));
        }, logger);
    }

    private static async Task PublishAsync(Func<Task> publish, ILogger logger)
    {
        try { await publish(); }
        catch (Exception exception)
        {
            // The REST write has committed. Reconnect sync remains the recovery path.
            logger.LogWarning(exception, "Realtime publish failed after a committed chat write.");
        }
    }

    private sealed record ConversationMutation(
        ConversationDto ForUser, ConversationDto ForPeer, Guid PeerId, bool Created);
    private sealed record SendMutation(
        MessageDto Message, bool Created, Guid PeerId,
        ConversationDto ForUser, ConversationDto ForPeer);
    private sealed record ReadMutation(
        long Sequence, bool Advanced, Guid PeerId,
        ConversationDto ForUser, ConversationDto ForPeer);
    private sealed record HeartMutation(MessageDto Message, bool Changed, Guid PeerId);
}

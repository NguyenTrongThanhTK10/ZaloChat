namespace Chat.Api.Models;

public sealed class ChatState
{
    public int SchemaVersion { get; set; } = 1;
    public List<UserRecord> Users { get; set; } = [];
    public List<ConversationRecord> Conversations { get; set; } = [];
    public List<MessageRecord> Messages { get; set; } = [];
    public List<RefreshSessionRecord> RefreshSessions { get; set; } = [];
}

public sealed class UserRecord
{
    public Guid Id { get; set; }
    public string DisplayName { get; set; } = "";
    public string Email { get; set; } = "";
    public AvatarRecord? Avatar { get; set; }
    public string PasswordSalt { get; set; } = "";
    public string PasswordHash { get; set; } = "";
    public DateTimeOffset CreatedAt { get; set; }
}

public sealed class ConversationRecord
{
    public Guid Id { get; set; }
    public Guid UserAId { get; set; }
    public Guid UserBId { get; set; }
    public long NextSequence { get; set; } = 1;
    public long UserAReadSequence { get; set; }
    public long UserBReadSequence { get; set; }
    public long UserADeliveredSequence { get; set; }
    public long UserBDeliveredSequence { get; set; }
    public DateTimeOffset CreatedAt { get; set; }

    public bool Contains(Guid userId) => UserAId == userId || UserBId == userId;
    public Guid PeerId(Guid userId) => UserAId == userId ? UserBId : UserAId;
    public long ReadSequence(Guid userId) => UserAId == userId ? UserAReadSequence : UserBReadSequence;
    public long DeliveredSequence(Guid userId) => UserAId == userId
        ? Math.Max(UserADeliveredSequence, UserAReadSequence)
        : Math.Max(UserBDeliveredSequence, UserBReadSequence);

    public void SetReadSequence(Guid userId, long sequence)
    {
        if (UserAId == userId) UserAReadSequence = sequence;
        else UserBReadSequence = sequence;
        SetDeliveredSequence(userId, sequence);
    }

    public void SetDeliveredSequence(Guid userId, long sequence)
    {
        if (UserAId == userId) UserADeliveredSequence = Math.Max(UserADeliveredSequence, sequence);
        else UserBDeliveredSequence = Math.Max(UserBDeliveredSequence, sequence);
    }
}

public sealed class MessageRecord
{
    public Guid Id { get; set; }
    public Guid ClientMessageId { get; set; }
    public Guid ConversationId { get; set; }
    public Guid SenderId { get; set; }
    public string Text { get; set; } = "";
    public string Kind { get; set; } = "text";
    public int? VoiceDurationMs { get; set; }
    public string? VoiceSha256 { get; set; }
    public AttachmentRecord? Attachment { get; set; }
    public long Sequence { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
    public List<Guid> HeartedBy { get; set; } = [];
    public Dictionary<Guid, string> Reactions { get; set; } = [];
    public Dictionary<Guid, List<string>> ReactionSets { get; set; } = [];
    public MessageReplyDto? ReplyTo { get; set; }
    public bool IsRecalled { get; set; }
}

public sealed class RefreshSessionRecord
{
    public Guid Id { get; set; }
    public Guid UserId { get; set; }
    public string TokenHash { get; set; } = "";
    public DateTimeOffset ExpiresAt { get; set; }
    public bool Revoked { get; set; }
}

public sealed record AvatarRecord(Guid Version, string ContentType);

public sealed record UserDto(Guid Id, string DisplayName, string Email, string? AvatarUrl)
{
    public static UserDto From(UserRecord user) => new(user.Id, user.DisplayName, user.Email,
        user.Avatar is { } avatar ? $"/api/users/{user.Id}/avatar/{avatar.Version}" : null);
}

public sealed record AttachmentRecord(string Name, long Size, string ContentType, string Sha256);
public sealed record AttachmentDto(string Name, long Size, string ContentType);

public sealed record MessageReplyDto(Guid Id, Guid SenderId, string Text, string Kind);

public sealed record MessageDto(
    Guid Id,
    Guid ClientMessageId,
    Guid ConversationId,
    Guid SenderId,
    string Text,
    string Kind,
    int? VoiceDurationMs,
    long Sequence,
    DateTimeOffset CreatedAt,
    IReadOnlyList<Guid> HeartedBy,
    MessageReplyDto? ReplyTo,
    IReadOnlyDictionary<Guid, string> Reactions,
    IReadOnlyDictionary<Guid, IReadOnlyList<string>> ReactionSets,
    bool IsRecalled,
    AttachmentDto? Attachment)
{
    public static MessageDto From(MessageRecord message)
    {
        var reactionSets = message.ReactionSets.ToDictionary(
            item => item.Key, item => new List<string>(item.Value));
        foreach (var (userId, reaction) in message.Reactions)
            if (!reactionSets.ContainsKey(userId)) reactionSets[userId] = [reaction];
        foreach (var userId in message.HeartedBy)
        {
            if (!reactionSets.TryGetValue(userId, out var selected))
                reactionSets[userId] = selected = [];
            if (!selected.Contains("heart")) selected.Add("heart");
        }
        var reactions = reactionSets.ToDictionary(item => item.Key, item => item.Value.Last());
        return new(message.Id, message.ClientMessageId, message.ConversationId,
            message.SenderId, message.Text, message.Kind, message.VoiceDurationMs,
            message.Sequence, message.CreatedAt,
            reactionSets.Where(item => item.Value.Contains("heart")).Select(item => item.Key).ToArray(),
            message.ReplyTo, reactions,
            reactionSets.ToDictionary(item => item.Key, item => (IReadOnlyList<string>)item.Value),
            message.IsRecalled,
            message.Attachment is { } attachment
                ? new AttachmentDto(attachment.Name, attachment.Size, attachment.ContentType)
                : null);
    }
}

public sealed record ConversationDto(
    Guid Id,
    UserDto Peer,
    MessageDto? LastMessage,
    long UnreadCount,
    long LastReadSequence,
    long PeerLastReadSequence,
    long LastDeliveredSequence,
    long PeerLastDeliveredSequence);

public sealed record AuthDto(UserDto User, string AccessToken, string RefreshToken);
public sealed record MessagePageDto(IReadOnlyList<MessageDto> Items, long? NextCursor);
public sealed record ReadDto(long LastReadSequence);
public sealed record ReadEventDto(Guid ConversationId, Guid UserId, long LastReadSequence);
public sealed record DeliveredDto(long LastDeliveredSequence);
public sealed record DeliveredEventDto(Guid ConversationId, Guid UserId, long LastDeliveredSequence);
public sealed record ApiError(string Code, string Message);

public sealed record RegisterRequest(string? DisplayName, string? Email, string? Password);
public sealed record SetReactionRequest(string? Type);
public sealed record LoginRequest(string? Email, string? Password);
public sealed record RefreshRequest(string? RefreshToken);
public sealed record UpdateProfileRequest(string? DisplayName, string? Email);
public sealed record CreateConversationRequest(Guid PeerUserId);
public sealed record SendMessageRequest(Guid ClientMessageId, string? Text,
    Guid? ReplyToMessageId = null);
public sealed record MarkReadRequest(long ThroughSequence);
public sealed record MarkDeliveredRequest(long ThroughSequence);

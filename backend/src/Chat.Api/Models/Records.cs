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
    public DateTimeOffset CreatedAt { get; set; }

    public bool Contains(Guid userId) => UserAId == userId || UserBId == userId;
    public Guid PeerId(Guid userId) => UserAId == userId ? UserBId : UserAId;
    public long ReadSequence(Guid userId) => UserAId == userId ? UserAReadSequence : UserBReadSequence;

    public void SetReadSequence(Guid userId, long sequence)
    {
        if (UserAId == userId) UserAReadSequence = sequence;
        else UserBReadSequence = sequence;
    }
}

public sealed class MessageRecord
{
    public Guid Id { get; set; }
    public Guid ClientMessageId { get; set; }
    public Guid ConversationId { get; set; }
    public Guid SenderId { get; set; }
    public string Text { get; set; } = "";
    public long Sequence { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
}

public sealed class RefreshSessionRecord
{
    public Guid Id { get; set; }
    public Guid UserId { get; set; }
    public string TokenHash { get; set; } = "";
    public DateTimeOffset ExpiresAt { get; set; }
    public bool Revoked { get; set; }
}

public sealed record UserDto(Guid Id, string DisplayName, string Email)
{
    public static UserDto From(UserRecord user) => new(user.Id, user.DisplayName, user.Email);
}

public sealed record MessageDto(
    Guid Id,
    Guid ClientMessageId,
    Guid ConversationId,
    Guid SenderId,
    string Text,
    long Sequence,
    DateTimeOffset CreatedAt)
{
    public static MessageDto From(MessageRecord message) => new(
        message.Id, message.ClientMessageId, message.ConversationId,
        message.SenderId, message.Text, message.Sequence, message.CreatedAt);
}

public sealed record ConversationDto(
    Guid Id,
    UserDto Peer,
    MessageDto? LastMessage,
    long UnreadCount,
    long LastReadSequence,
    long PeerLastReadSequence);

public sealed record AuthDto(UserDto User, string AccessToken, string RefreshToken);
public sealed record MessagePageDto(IReadOnlyList<MessageDto> Items, long? NextCursor);
public sealed record ReadDto(long LastReadSequence);
public sealed record ReadEventDto(Guid ConversationId, Guid UserId, long LastReadSequence);
public sealed record ApiError(string Code, string Message);

public sealed record RegisterRequest(string? DisplayName, string? Email, string? Password);
public sealed record LoginRequest(string? Email, string? Password);
public sealed record RefreshRequest(string? RefreshToken);
public sealed record CreateConversationRequest(Guid PeerUserId);
public sealed record SendMessageRequest(Guid ClientMessageId, string? Text);
public sealed record MarkReadRequest(long ThroughSequence);

using System.Security.Claims;
using System.Security.Cryptography;
using Chat.Api.Data;
using Chat.Api.Hubs;
using Chat.Api.Models;
using Microsoft.AspNetCore.Http.Features;
using Microsoft.AspNetCore.SignalR;

namespace Chat.Api.Endpoints;

public static partial class ChatEndpoints
{
    private const long MaxVoiceBytes = 2_000_000;
    private const long MaxVoiceRequestBytes = 2_500_000;
    private const int MaxVoiceDurationMs = 120_000;

    private static async Task<IResult> SendVoiceAsync(
        Guid id, HttpRequest request, ClaimsPrincipal principal, ChatStore store,
        ChatOptions options, IHubContext<ChatHub> hub, ILogger<ChatHub> logger,
        CancellationToken cancellationToken)
    {
        var sizeFeature = request.HttpContext.Features.Get<IHttpMaxRequestBodySizeFeature>();
        if (sizeFeature is { IsReadOnly: false })
            sizeFeature.MaxRequestBodySize = MaxVoiceRequestBytes;
        if (request.ContentLength > MaxVoiceRequestBytes)
            return Results.StatusCode(StatusCodes.Status413PayloadTooLarge);
        if (!request.HasFormContentType)
            throw ApiException.Validation("A multipart voice recording is required.");

        var form = await request.ReadFormAsync(cancellationToken);
        if (!Guid.TryParse(form["clientMessageId"], out var clientMessageId) ||
            clientMessageId == Guid.Empty)
            throw ApiException.Validation("clientMessageId must be a nonempty UUID.");
        if (!int.TryParse(form["durationMs"], out var durationMs) ||
            durationMs is < 1000 or > MaxVoiceDurationMs)
            throw ApiException.Validation("Voice duration must be 1 to 120 seconds.");
        var audio = form.Files.GetFile("audio");
        Guid? replyToMessageId = null;
        if (form.ContainsKey("replyToMessageId"))
        {
            if (!Guid.TryParse(form["replyToMessageId"], out var replyId) || replyId == Guid.Empty)
                throw ApiException.Validation("replyToMessageId must be a nonempty UUID.");
            replyToMessageId = replyId;
        }
        if (audio is null || audio.Length is < 12 or > MaxVoiceBytes)
            throw ApiException.Validation("Voice recording must be at most 2 MB.");

        var userId = principal.CurrentUserId();
        await store.ReadAsync(state => ChatQueries.GetConversation(state, id, userId),
            cancellationToken);

        Directory.CreateDirectory(options.VoiceDirectory);
        if (!OperatingSystem.IsWindows())
            File.SetUnixFileMode(options.VoiceDirectory,
                UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        var messageId = Guid.NewGuid();
        var path = VoicePath(options, messageId);
        var keepFile = false;
        try
        {
            await using (var source = audio.OpenReadStream())
            {
                var header = new byte[12];
                await source.ReadExactlyAsync(header, cancellationToken);
                if (!header.AsSpan(4, 4).SequenceEqual("ftyp"u8))
                    throw ApiException.Validation("Only M4A voice recordings are supported.");
                await using var target = new FileStream(path, FileMode.CreateNew,
                    FileAccess.Write, FileShare.None, 81920, FileOptions.Asynchronous);
                await target.WriteAsync(header, cancellationToken);
                await source.CopyToAsync(target, cancellationToken);
                await target.FlushAsync(cancellationToken);
            }
            if (!OperatingSystem.IsWindows())
                File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite);
            var hash = Convert.ToHexString(
                SHA256.HashData(await File.ReadAllBytesAsync(path, cancellationToken)));

            var result = await store.MutateAsync(state =>
            {
                var conversation = ChatQueries.GetConversation(state, id, userId);
                var existing = state.Messages.FirstOrDefault(message =>
                    message.ConversationId == id && message.SenderId == userId &&
                    message.ClientMessageId == clientMessageId);
                if (existing is not null)
                {
                    if (existing.Kind != "voice" || existing.VoiceSha256 != hash ||
                        existing.VoiceDurationMs != durationMs ||
                        existing.ReplyTo?.Id != replyToMessageId)
                        throw ApiException.Conflict("clientMessageId was already used with different content.");
                    return new SendMutation(MessageDto.From(existing), false,
                        conversation.PeerId(userId),
                        ChatQueries.ToDto(state, conversation, userId),
                        ChatQueries.ToDto(state, conversation, conversation.PeerId(userId)));
                }

                var message = new MessageRecord
                {
                    Id = messageId, ClientMessageId = clientMessageId,
                    ConversationId = id, SenderId = userId,
                    Kind = "voice", Text = "", VoiceDurationMs = durationMs,
                    ReplyTo = CreateReply(state, id, replyToMessageId),
                    VoiceSha256 = hash, Sequence = conversation.NextSequence++,
                    CreatedAt = DateTimeOffset.UtcNow
                };
                state.Messages.Add(message);
                var peerId = conversation.PeerId(userId);
                return new SendMutation(MessageDto.From(message), true, peerId,
                    ChatQueries.ToDto(state, conversation, userId),
                    ChatQueries.ToDto(state, conversation, peerId));
            }, cancellationToken);
            keepFile = result.Created;

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
        finally
        {
            if (!keepFile && File.Exists(path)) File.Delete(path);
        }
    }

    private static async Task<IResult> GetVoiceAsync(
        Guid id, ClaimsPrincipal principal, ChatStore store, ChatOptions options,
        CancellationToken cancellationToken)
    {
        var userId = principal.CurrentUserId();
        var message = await store.ReadAsync(state =>
        {
            var found = state.Messages.FirstOrDefault(item => item.Id == id);
            if (found is null || found.Kind != "voice")
                throw ApiException.NotFound("Voice message not found.");
            ChatQueries.GetConversation(state, found.ConversationId, userId);
            return MessageDto.From(found);
        }, cancellationToken);
        var path = VoicePath(options, message.Id);
        return File.Exists(path)
            ? Results.File(path, "audio/mp4", enableRangeProcessing: true)
            : Results.NotFound();
    }

    private static string VoicePath(ChatOptions options, Guid messageId) =>
        Path.Combine(options.VoiceDirectory, $"{messageId:N}.m4a");
}

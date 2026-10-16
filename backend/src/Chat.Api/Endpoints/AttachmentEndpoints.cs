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
    private const long MaxAttachmentBytes = 20_000_000;
    private const long MaxAttachmentRequestBytes = MaxAttachmentBytes + 1_000_000;

    private static async Task<IResult> SendAttachmentAsync(
        Guid id, HttpRequest request, ClaimsPrincipal principal, ChatStore store,
        ChatOptions options, IHubContext<ChatHub> hub, ILogger<ChatHub> logger,
        CancellationToken cancellationToken)
    {
        var sizeFeature = request.HttpContext.Features.Get<IHttpMaxRequestBodySizeFeature>();
        if (sizeFeature is { IsReadOnly: false })
            sizeFeature.MaxRequestBodySize = MaxAttachmentRequestBytes;
        if (request.ContentLength > MaxAttachmentRequestBytes)
            return Results.StatusCode(StatusCodes.Status413PayloadTooLarge);
        var userId = principal.CurrentUserId();
        await store.ReadAsync(state => ChatQueries.GetConversation(state, id, userId), cancellationToken);
        if (!request.HasFormContentType)
            throw ApiException.Validation("A multipart attachment is required.");
        var form = await request.ReadFormAsync(cancellationToken);
        if (!Guid.TryParse(form["clientMessageId"], out var clientMessageId) || clientMessageId == Guid.Empty)
            throw ApiException.Validation("clientMessageId must be a nonempty UUID.");
        var kind = form["kind"].ToString();
        if (kind is not ("image" or "file"))
            throw ApiException.Validation("Attachment kind must be image or file.");
        var text = form["text"].ToString().Trim();
        if (text.Length > 4000) throw ApiException.Validation("Caption must be at most 4000 characters.");
        Guid? replyToMessageId = null;
        if (form.ContainsKey("replyToMessageId"))
        {
            if (!Guid.TryParse(form["replyToMessageId"], out var replyId) || replyId == Guid.Empty)
                throw ApiException.Validation("replyToMessageId must be a nonempty UUID.");
            replyToMessageId = replyId;
        }
        var file = form.Files.GetFile("file");
        if (file is null || file.Length is < 1 or > MaxAttachmentBytes)
            throw ApiException.Validation("Attachment must be between 1 byte and 20 MB.");
        var name = Path.GetFileName(file.FileName.Replace('\\', '/'));
        name = new string(name.Where(character => !char.IsControl(character)).ToArray()).Trim();
        if (name.Length is < 1 or > 180 || name is "." or "..")
            throw ApiException.Validation("Attachment filename must contain 1 to 180 characters.");

        Directory.CreateDirectory(options.AttachmentDirectory);
        if (!OperatingSystem.IsWindows())
            File.SetUnixFileMode(options.AttachmentDirectory,
                UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        var messageId = Guid.NewGuid();
        var path = AttachmentPath(options, messageId);
        var keepFile = false;
        try
        {
            await using (var target = new FileStream(path, FileMode.CreateNew, FileAccess.Write,
                FileShare.None, 81920, FileOptions.Asynchronous))
                await file.CopyToAsync(target, cancellationToken);
            if (!OperatingSystem.IsWindows())
                File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite);
            string hash;
            var contentType = "application/octet-stream";
            await using (var source = File.OpenRead(path))
            {
                if (kind == "image")
                {
                    var header = new byte[Math.Min(32, file.Length)];
                    await source.ReadExactlyAsync(header, cancellationToken);
                    contentType = Chat.Api.Media.ImageFileTypes.Detect(header)
                        ?? throw ApiException.Validation("Unsupported image. Use JPEG, PNG, GIF, WebP, BMP, HEIC or AVIF.");
                    source.Position = 0;
                }
                hash = Convert.ToHexString(await SHA256.HashDataAsync(source, cancellationToken));
            }
            var result = await store.MutateAsync(state =>
            {
                var conversation = ChatQueries.GetConversation(state, id, userId);
                var existing = state.Messages.FirstOrDefault(message =>
                    message.ConversationId == id && message.SenderId == userId &&
                    message.ClientMessageId == clientMessageId);
                if (existing is not null)
                {
                    if (existing.Kind != kind || existing.Attachment is not { } previous ||
                        previous.Sha256 != hash || previous.Name != name || existing.Text != text ||
                        existing.ReplyTo?.Id != replyToMessageId)
                        throw ApiException.Conflict("clientMessageId was already used with different content.");
                    return new SendMutation(MessageDto.From(existing), false, conversation.PeerId(userId),
                        ChatQueries.ToDto(state, conversation, userId),
                        ChatQueries.ToDto(state, conversation, conversation.PeerId(userId)));
                }
                var message = new MessageRecord
                {
                    Id = messageId, ClientMessageId = clientMessageId, ConversationId = id,
                    SenderId = userId, Kind = kind, Text = text,
                    Attachment = new AttachmentRecord(name, file.Length, contentType, hash),
                    ReplyTo = CreateReply(state, id, replyToMessageId),
                    Sequence = conversation.NextSequence++, CreatedAt = DateTimeOffset.UtcNow
                };
                state.Messages.Add(message);
                var peerId = conversation.PeerId(userId);
                return new SendMutation(MessageDto.From(message), true, peerId,
                    ChatQueries.ToDto(state, conversation, userId), ChatQueries.ToDto(state, conversation, peerId));
            }, cancellationToken);
            keepFile = result.Created;
            if (result.Created)
            {
                await PublishAsync(async () => await Task.WhenAll(
                    hub.Clients.Group(ChatHub.UserGroup(userId)).SendAsync("MessageCreated", result.Message),
                    hub.Clients.Group(ChatHub.UserGroup(result.PeerId)).SendAsync("MessageCreated", result.Message)), logger);
                await PublishConversationsAsync(hub, logger, userId, result.PeerId, result.ForUser, result.ForPeer);
            }
            return Results.Json(result.Message, statusCode: result.Created ? 201 : 200);
        }
        finally
        {
            if (!keepFile && File.Exists(path)) File.Delete(path);
        }
    }

    private static async Task<IResult> GetAttachmentAsync(
        Guid id, HttpResponse response, ClaimsPrincipal principal, ChatStore store, ChatOptions options,
        CancellationToken cancellationToken)
    {
        var userId = principal.CurrentUserId();
        var attachment = await store.ReadAsync(state =>
        {
            var message = state.Messages.FirstOrDefault(item => item.Id == id);
            if (message is null || message.IsRecalled || message.Attachment is null)
                throw ApiException.NotFound("Attachment not found.");
            ChatQueries.GetConversation(state, message.ConversationId, userId);
            return message.Attachment;
        }, cancellationToken);
        response.Headers.XContentTypeOptions = "nosniff";
        var path = AttachmentPath(options, id);
        return File.Exists(path)
            ? Results.File(path, attachment.ContentType, attachment.Name, enableRangeProcessing: true)
            : Results.NotFound();
    }

    private static string AttachmentPath(ChatOptions options, Guid messageId) =>
        Path.Combine(options.AttachmentDirectory, messageId.ToString("N"));

}

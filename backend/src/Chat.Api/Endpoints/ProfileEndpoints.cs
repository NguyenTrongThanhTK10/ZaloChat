using System.Net.Mail;
using System.Security.Claims;
using Chat.Api.Data;
using Chat.Api.Hubs;
using Chat.Api.Models;
using Microsoft.AspNetCore.Http.Features;
using Microsoft.AspNetCore.SignalR;

namespace Chat.Api.Endpoints;

public static partial class AuthEndpoints
{
    private const long MaxAvatarBytes = 5_000_000;

    private static async Task<IResult> UpdateProfileWithAvatarAsync(
        HttpRequest request, ClaimsPrincipal principal, ChatStore store, ChatOptions options,
        IHubContext<ChatHub> hub, ILogger<ChatHub> logger, CancellationToken cancellationToken)
    {
        var limit = MaxAvatarBytes + 1_000_000;
        var sizeFeature = request.HttpContext.Features.Get<IHttpMaxRequestBodySizeFeature>();
        if (sizeFeature is { IsReadOnly: false }) sizeFeature.MaxRequestBodySize = limit;
        if (request.ContentLength > limit) return Results.StatusCode(StatusCodes.Status413PayloadTooLarge);
        if (!request.HasFormContentType) throw ApiException.Validation("A multipart profile is required.");
        var form = await request.ReadFormAsync(cancellationToken);
        var displayName = form["displayName"].ToString().Trim();
        var email = form["email"].ToString().Trim().ToLowerInvariant();
        if (string.IsNullOrWhiteSpace(displayName) || displayName.Length > 80)
            throw ApiException.Validation("Display name must contain 1 to 80 characters.");
        if (string.IsNullOrWhiteSpace(email) || email.Length > 254 ||
            !MailAddress.TryCreate(email, out var address) ||
            !string.Equals(address.Address, email, StringComparison.OrdinalIgnoreCase))
            throw ApiException.Validation("A valid email address is required.");
        var userId = principal.CurrentUserId();
        var file = form.Files.GetFile("avatar");
        var removeAvatar = form["removeAvatar"].ToString() == "true";
        if (file is not null && removeAvatar) throw ApiException.Validation("Choose an avatar or remove it, not both.");
        if (file is not null && file.Length is < 12 or > MaxAvatarBytes)
            throw ApiException.Validation("Avatar must be an image of at most 5 MB.");
        AvatarRecord? replacement = null;
        string? path = null;
        var committed = false;
        try
        {
            if (file is not null)
            {
                await using var source = file.OpenReadStream();
                var header = new byte[Math.Min(32, file.Length)];
                await source.ReadExactlyAsync(header, cancellationToken);
                var contentType = Chat.Api.Media.ImageFileTypes.Detect(header)
                    ?? throw ApiException.Validation("Avatar must be a supported image.");
                replacement = new AvatarRecord(Guid.NewGuid(), contentType);
                var directory = Path.Combine(options.AvatarDirectory, userId.ToString("N"));
                Directory.CreateDirectory(directory);
                if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(directory,
                    UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
                path = AvatarPath(options, userId, replacement.Version);
                await using (var target = new FileStream(path, FileMode.CreateNew, FileAccess.Write,
                    FileShare.None, 81920, FileOptions.Asynchronous))
                {
                    await target.WriteAsync(header, cancellationToken);
                    await source.CopyToAsync(target, cancellationToken);
                    await target.FlushAsync(cancellationToken);
                }
                if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(path,
                    UnixFileMode.UserRead | UnixFileMode.UserWrite);
            }
            var result = await store.MutateAsync(state =>
            {
                var user = state.Users.FirstOrDefault(item => item.Id == userId)
                    ?? throw ApiException.Unauthorized();
                if (state.Users.Any(item => item.Id != userId && item.Email == email))
                    throw ApiException.Conflict("Email is already registered.");
                var previous = user.Avatar;
                user.DisplayName = displayName;
                user.Email = email;
                if (replacement is not null || removeAvatar) user.Avatar = replacement;
                return (User: UserDto.From(user), Previous: previous);
            }, cancellationToken);
            committed = true;
            if ((replacement is not null || removeAvatar) && result.Previous is { } old)
            {
                try { File.Delete(AvatarPath(options, userId, old.Version)); }
                catch (IOException exception) { logger.LogWarning(exception, "Could not delete old avatar for {UserId}.", userId); }
            }
            await PublishProfileUpdatedAsync(userId, store, hub, logger);
            return Results.Ok(result.User);
        }
        finally
        {
            if (!committed && path is not null && File.Exists(path)) File.Delete(path);
        }
    }

    private static async Task<IResult> GetAvatarAsync(
        Guid id, Guid version, HttpResponse response, ChatStore store, ChatOptions options,
        CancellationToken cancellationToken)
    {
        var avatar = await store.ReadAsync(state => state.Users
            .FirstOrDefault(user => user.Id == id)?.Avatar, cancellationToken);
        if (avatar is null || avatar.Version != version) return Results.NotFound();
        var path = AvatarPath(options, id, version);
        response.Headers.XContentTypeOptions = "nosniff";
        response.Headers.CacheControl = "private, max-age=3600";
        return File.Exists(path) ? Results.File(path, avatar.ContentType) : Results.NotFound();
    }

    private static string AvatarPath(ChatOptions options, Guid userId, Guid version) =>
        Path.Combine(options.AvatarDirectory, userId.ToString("N"), version.ToString("N"));

    private static async Task PublishProfileUpdatedAsync(
        Guid userId, ChatStore store, IHubContext<ChatHub> hub, ILogger<ChatHub> logger)
    {
        try
        {
            var updates = await store.ReadAsync(state => state.Conversations
                .Where(conversation => conversation.Contains(userId))
                .Select(conversation => (Peer: conversation.PeerId(userId),
                    Dto: ChatQueries.ToDto(state, conversation, conversation.PeerId(userId))))
                .ToList(), CancellationToken.None);
            foreach (var update in updates)
                await hub.Clients.Group(ChatHub.UserGroup(update.Peer)).SendAsync("ConversationUpdated", update.Dto);
        }
        catch (Exception exception)
        {
            logger.LogWarning(exception, "Could not publish profile update for {UserId}.", userId);
        }
    }
}

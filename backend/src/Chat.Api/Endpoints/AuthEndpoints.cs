using System.Net.Mail;
using System.Security.Claims;
using Chat.Api.Auth;
using Chat.Api.Data;
using Chat.Api.Models;

namespace Chat.Api.Endpoints;

public static class AuthEndpoints
{
    public static void MapAuthEndpoints(this WebApplication app)
    {
        var auth = app.MapGroup("/api/auth");
        auth.MapPost("/register", RegisterAsync).RequireRateLimiting("auth");
        auth.MapPost("/login", LoginAsync).RequireRateLimiting("auth");
        auth.MapPost("/refresh", RefreshAsync).RequireRateLimiting("auth");
        auth.MapGet("/me", GetMeAsync).RequireAuthorization();
        auth.MapPut("/me", UpdateMeAsync).RequireAuthorization();
    }

    public static Guid CurrentUserId(this ClaimsPrincipal user) =>
        Guid.Parse(user.FindFirstValue(ClaimTypes.NameIdentifier)!);

    private static async Task<IResult> RegisterAsync(
        RegisterRequest request, ChatStore store, TokenService tokens, CancellationToken cancellationToken)
    {
        var displayName = request.DisplayName?.Trim();
        var email = request.Email?.Trim().ToLowerInvariant();
        if (string.IsNullOrWhiteSpace(displayName) || displayName.Length > 80)
            throw ApiException.Validation("Display name must contain 1 to 80 characters.");
        if (string.IsNullOrWhiteSpace(email) || email.Length > 254 ||
            !MailAddress.TryCreate(email, out var address) ||
            !string.Equals(address.Address, email, StringComparison.OrdinalIgnoreCase))
            throw ApiException.Validation("A valid email address is required.");
        if (request.Password is null || request.Password.Length is < 8 or > 128)
            throw ApiException.Validation("Password must contain 8 to 128 characters.");

        var (salt, hash) = PasswordHasher.Hash(request.Password);
        var refresh = tokens.CreateRefreshToken();
        var user = await store.MutateAsync(state =>
        {
            if (state.Users.Any(existing => existing.Email == email))
                throw ApiException.Conflict("Email is already registered.");
            var created = new UserRecord
            {
                Id = Guid.NewGuid(), DisplayName = displayName, Email = email,
                PasswordSalt = salt, PasswordHash = hash, CreatedAt = DateTimeOffset.UtcNow
            };
            state.Users.Add(created);
            state.RefreshSessions.Add(NewSession(created.Id, refresh.Hash));
            return UserDto.From(created);
        }, cancellationToken);

        return Results.Json(new AuthDto(user, tokens.CreateAccessToken(user.Id), refresh.Raw),
            statusCode: StatusCodes.Status201Created);
    }

    private static async Task<IResult> LoginAsync(
        LoginRequest request, ChatStore store, TokenService tokens, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(request.Email) || string.IsNullOrEmpty(request.Password))
            throw ApiException.Validation("Email and password are required.");
        var email = request.Email.Trim().ToLowerInvariant();
        var user = await store.ReadAsync(state =>
            state.Users.FirstOrDefault(existing => existing.Email == email), cancellationToken);
        if (user is null || !PasswordHasher.Verify(request.Password, user.PasswordSalt, user.PasswordHash))
            throw ApiException.Unauthorized();

        var refresh = tokens.CreateRefreshToken();
        await store.MutateAsync(state =>
        {
            state.RefreshSessions.Add(NewSession(user.Id, refresh.Hash));
            return true;
        }, cancellationToken);
        return Results.Ok(new AuthDto(UserDto.From(user), tokens.CreateAccessToken(user.Id), refresh.Raw));
    }

    private static async Task<IResult> RefreshAsync(
        RefreshRequest request, ChatStore store, TokenService tokens, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(request.RefreshToken))
            throw ApiException.Validation("Refresh token is required.");
        var oldHash = TokenService.HashRefreshToken(request.RefreshToken);
        var next = tokens.CreateRefreshToken();
        var user = await store.MutateAsync(state =>
        {
            var session = state.RefreshSessions.FirstOrDefault(existing =>
                existing.TokenHash == oldHash && !existing.Revoked &&
                existing.ExpiresAt > DateTimeOffset.UtcNow);
            if (session is null) throw ApiException.Unauthorized();
            session.Revoked = true;
            state.RefreshSessions.Add(NewSession(session.UserId, next.Hash));
            return UserDto.From(state.Users.Single(existing => existing.Id == session.UserId));
        }, cancellationToken);
        return Results.Ok(new AuthDto(user, tokens.CreateAccessToken(user.Id), next.Raw));
    }

    private static async Task<IResult> GetMeAsync(
        ClaimsPrincipal principal, ChatStore store, CancellationToken cancellationToken)
    {
        var userId = principal.CurrentUserId();
        var user = await store.ReadAsync(state =>
            state.Users.FirstOrDefault(existing => existing.Id == userId), cancellationToken);
        if (user is null) throw ApiException.Unauthorized();
        return Results.Ok(UserDto.From(user));
    }

    private static async Task<IResult> UpdateMeAsync(
        UpdateProfileRequest request, ClaimsPrincipal principal, ChatStore store,
        CancellationToken cancellationToken)
    {
        var displayName = request.DisplayName?.Trim();
        var email = request.Email?.Trim().ToLowerInvariant();
        if (string.IsNullOrWhiteSpace(displayName) || displayName.Length > 80)
            throw ApiException.Validation("Display name must contain 1 to 80 characters.");
        if (string.IsNullOrWhiteSpace(email) || email.Length > 254 ||
            !MailAddress.TryCreate(email, out var address) ||
            !string.Equals(address.Address, email, StringComparison.OrdinalIgnoreCase))
            throw ApiException.Validation("A valid email address is required.");

        var userId = principal.CurrentUserId();
        var updated = await store.MutateAsync(state =>
        {
            var user = state.Users.FirstOrDefault(existing => existing.Id == userId)
                ?? throw ApiException.Unauthorized();
            if (state.Users.Any(existing => existing.Id != userId && existing.Email == email))
                throw ApiException.Conflict("Email is already registered.");
            user.DisplayName = displayName;
            user.Email = email;
            return UserDto.From(user);
        }, cancellationToken);
        return Results.Ok(updated);
    }

    private static RefreshSessionRecord NewSession(Guid userId, string tokenHash) => new()
    {
        Id = Guid.NewGuid(), UserId = userId, TokenHash = tokenHash,
        ExpiresAt = DateTimeOffset.UtcNow.AddDays(30)
    };
}

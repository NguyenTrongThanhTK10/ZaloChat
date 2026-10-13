using Chat.Api;
using Chat.Api.Auth;
using Chat.Api.Data;
using Chat.Api.Endpoints;
using Chat.Api.Hubs;
using Chat.Api.Models;
using Microsoft.AspNetCore.Authentication;
using System.Security.Claims;
using System.Threading.RateLimiting;

var builder = WebApplication.CreateBuilder(args);
var chatOptions = ChatOptions.From(builder.Configuration, builder.Environment);
builder.Services.AddSingleton(chatOptions);
builder.Services.AddSingleton<ChatStore>();
builder.Services.AddSingleton<TokenService>();
builder.Services.AddSignalR();
builder.Services.AddAuthentication("Bearer")
    .AddScheme<AuthenticationSchemeOptions, BearerAuthenticationHandler>("Bearer", _ => { });
builder.Services.AddAuthorization();
builder.Services.AddRateLimiter(options =>
{
    options.RejectionStatusCode = StatusCodes.Status429TooManyRequests;
    options.AddPolicy("auth", context => RateLimitPartition.GetFixedWindowLimiter(
        context.Connection.RemoteIpAddress?.ToString() ?? "unknown",
        _ => new FixedWindowRateLimiterOptions
        {
            PermitLimit = 20, Window = TimeSpan.FromMinutes(1), QueueLimit = 0
        }));
    options.AddPolicy("send", context => RateLimitPartition.GetFixedWindowLimiter(
        context.User.FindFirstValue(ClaimTypes.NameIdentifier) ??
            context.Connection.RemoteIpAddress?.ToString() ?? "unknown",
        _ => new FixedWindowRateLimiterOptions
        {
            PermitLimit = 60, Window = TimeSpan.FromMinutes(1), QueueLimit = 0
        }));
});

var app = builder.Build();
app.Services.GetRequiredService<ChatStore>(); // Validate and lock the data file before serving requests.

app.Use(async (context, next) =>
{
    try
    {
        await next(context);
    }
    catch (ApiException exception)
    {
        if (context.Response.HasStarted) throw;
        context.Response.StatusCode = exception.StatusCode;
        await context.Response.WriteAsJsonAsync(new ApiError(exception.Code, exception.Message));
    }
});
app.UseStatusCodePages(async statusContext =>
{
    var response = statusContext.HttpContext.Response;
    var error = response.StatusCode switch
    {
        400 => new ApiError("validation_error", "The request is invalid."),
        401 => new ApiError("unauthorized", "Authentication is required."),
        403 => new ApiError("forbidden", "Access is denied."),
        404 => new ApiError("not_found", "Resource not found."),
        429 => new ApiError("rate_limited", "Too many requests. Try again later."),
        _ => new ApiError("request_error", "The request could not be completed.")
    };
    await response.WriteAsJsonAsync(error);
});
app.UseAuthentication();
app.UseRateLimiter();
app.UseAuthorization();

app.MapGet("/health", () => Results.Ok(new { status = "ok" }));
app.MapGet("/openapi/v1.json", () => Results.File(
    Path.Combine(AppContext.BaseDirectory, "openapi.json"), "application/json"));
app.MapAuthEndpoints();
app.MapChatEndpoints();
app.MapHub<ChatHub>("/hubs/chat").RequireAuthorization();

app.Run();

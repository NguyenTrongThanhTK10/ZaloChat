namespace Chat.Api.Models;

public sealed class ApiException(int statusCode, string code, string message) : Exception(message)
{
    public int StatusCode { get; } = statusCode;
    public string Code { get; } = code;

    public static ApiException Validation(string message) => new(400, "validation_error", message);
    public static ApiException Unauthorized() => new(401, "unauthorized", "Invalid credentials or token.");
    public static ApiException NotFound(string message) => new(404, "not_found", message);
    public static ApiException Forbidden(string message) => new(403, "forbidden", message);
    public static ApiException Conflict(string message) => new(409, "conflict", message);
}

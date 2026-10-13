using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Chat.Api.Auth;

public sealed class TokenService(ChatOptions options)
{
    private const string Issuer = "Chat.Api";
    private const string Audience = "Chat.Client";
    private static readonly string Header = Encode(Encoding.UTF8.GetBytes("{\"alg\":\"HS256\",\"typ\":\"JWT\"}"));

    public string CreateAccessToken(Guid userId)
    {
        var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var payload = Encode(JsonSerializer.SerializeToUtf8Bytes(new
        {
            sub = userId.ToString("D"), iss = Issuer, aud = Audience,
            iat = now, exp = now + 15 * 60
        }));
        var unsigned = $"{Header}.{payload}";
        return $"{unsigned}.{Sign(unsigned)}";
    }

    public bool TryValidateAccessToken(string token, out Guid userId)
    {
        userId = Guid.Empty;
        var parts = token.Split('.');
        if (parts.Length != 3 || parts.Any(string.IsNullOrEmpty)) return false;
        try
        {
            var expected = Decode(Sign(parts[0] + "." + parts[1]));
            var actual = Decode(parts[2]);
            if (!CryptographicOperations.FixedTimeEquals(expected, actual)) return false;

            using var header = JsonDocument.Parse(Decode(parts[0]));
            if (header.RootElement.GetProperty("alg").GetString() != "HS256") return false;
            using var payload = JsonDocument.Parse(Decode(parts[1]));
            var root = payload.RootElement;
            if (root.GetProperty("iss").GetString() != Issuer ||
                root.GetProperty("aud").GetString() != Audience) return false;
            var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
            if (root.GetProperty("exp").GetInt64() <= now ||
                root.GetProperty("iat").GetInt64() > now + 30) return false;
            return Guid.TryParse(root.GetProperty("sub").GetString(), out userId) &&
                   userId != Guid.Empty;
        }
        catch (Exception exception) when (exception is FormatException or JsonException or KeyNotFoundException)
        {
            return false;
        }
    }

    public (string Raw, string Hash) CreateRefreshToken()
    {
        var raw = Encode(RandomNumberGenerator.GetBytes(32));
        return (raw, HashRefreshToken(raw));
    }

    public static string HashRefreshToken(string token) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(token)));

    private string Sign(string unsigned) =>
        Encode(HMACSHA256.HashData(options.SigningKey, Encoding.ASCII.GetBytes(unsigned)));

    private static string Encode(byte[] bytes) => Convert.ToBase64String(bytes)
        .TrimEnd('=').Replace('+', '-').Replace('/', '_');

    private static byte[] Decode(string text)
    {
        var base64 = text.Replace('-', '+').Replace('_', '/');
        return Convert.FromBase64String(base64.PadRight((base64.Length + 3) / 4 * 4, '='));
    }
}

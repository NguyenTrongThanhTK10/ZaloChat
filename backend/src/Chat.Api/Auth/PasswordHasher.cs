using System.Security.Cryptography;

namespace Chat.Api.Auth;

public static class PasswordHasher
{
    private const int Iterations = 210_000;

    public static (string Salt, string Hash) Hash(string password)
    {
        var salt = RandomNumberGenerator.GetBytes(16);
        var hash = Rfc2898DeriveBytes.Pbkdf2(password, salt, Iterations,
            HashAlgorithmName.SHA256, 32);
        return (Convert.ToBase64String(salt), Convert.ToBase64String(hash));
    }

    public static bool Verify(string password, string saltText, string hashText)
    {
        var salt = Convert.FromBase64String(saltText);
        var expected = Convert.FromBase64String(hashText);
        var actual = Rfc2898DeriveBytes.Pbkdf2(password, salt, Iterations,
            HashAlgorithmName.SHA256, expected.Length);
        return CryptographicOperations.FixedTimeEquals(expected, actual);
    }
}

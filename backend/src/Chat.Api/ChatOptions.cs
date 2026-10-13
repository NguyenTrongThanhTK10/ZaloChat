using System.Security.Cryptography;
using System.Text;

namespace Chat.Api;

public sealed class ChatOptions
{
    public required string DataPath { get; init; }
    public required byte[] SigningKey { get; init; }

    public static ChatOptions From(IConfiguration configuration, IHostEnvironment environment)
    {
        var configuredPath = configuration["Chat:DataPath"];
        var dataPath = Path.GetFullPath(
            string.IsNullOrWhiteSpace(configuredPath) ? "data/chat-state.json" : configuredPath,
            environment.ContentRootPath);
        var dataDirectory = Path.GetDirectoryName(dataPath)!;
        Directory.CreateDirectory(dataDirectory);

        var configuredKey = configuration["Chat:SigningKey"];
        byte[] signingKey;
        if (!string.IsNullOrEmpty(configuredKey))
        {
            signingKey = Encoding.UTF8.GetBytes(configuredKey);
        }
        else if (environment.IsDevelopment())
        {
            var keyPath = Path.Combine(dataDirectory, "signing-key.bin");
            if (!File.Exists(keyPath))
            {
                var generated = RandomNumberGenerator.GetBytes(32);
                try
                {
                    using var stream = new FileStream(keyPath, FileMode.CreateNew, FileAccess.Write, FileShare.None);
                    stream.Write(generated);
                    stream.Flush(true);
                    if (!OperatingSystem.IsWindows())
                        File.SetUnixFileMode(keyPath, UnixFileMode.UserRead | UnixFileMode.UserWrite);
                }
                catch (IOException) when (File.Exists(keyPath))
                {
                    // Another local process created it first.
                }
            }
            signingKey = File.ReadAllBytes(keyPath);
        }
        else
        {
            throw new InvalidOperationException("Chat:SigningKey must be set outside Development.");
        }

        if (signingKey.Length < 32)
            throw new InvalidOperationException("Chat:SigningKey must contain at least 32 bytes.");

        return new ChatOptions { DataPath = dataPath, SigningKey = signingKey };
    }
}

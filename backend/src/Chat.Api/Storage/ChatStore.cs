using System.Text.Json;
using Chat.Api.Models;

namespace Chat.Api.Data;

/// <summary>Single-process file store. Only publish a mutation after its snapshot is committed.</summary>
public sealed class ChatStore : IDisposable
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);
    private readonly SemaphoreSlim gate = new(1, 1);
    private readonly FileStream processLock;
    private readonly string dataPath;
    private ChatState state;

    public ChatStore(ChatOptions options)
    {
        dataPath = options.DataPath;
        Directory.CreateDirectory(Path.GetDirectoryName(dataPath)!);
        // Keep a separate lock open so replacing the snapshot does not release ownership.
        processLock = new FileStream(dataPath + ".lock", FileMode.OpenOrCreate,
            FileAccess.ReadWrite, FileShare.None);
        try
        {
            state = File.Exists(dataPath)
                ? JsonSerializer.Deserialize<ChatState>(File.ReadAllBytes(dataPath), JsonOptions)
                    ?? throw new InvalidDataException("The chat data file is empty.")
                : new ChatState();
            if (state.SchemaVersion != 1 || state.Users is null || state.Conversations is null ||
                state.Messages is null || state.RefreshSessions is null)
                throw new InvalidDataException("Unsupported or invalid chat data file.");
        }
        catch
        {
            processLock.Dispose();
            throw;
        }
    }

    public async Task<T> ReadAsync<T>(Func<ChatState, T> read, CancellationToken cancellationToken = default)
    {
        await gate.WaitAsync(cancellationToken);
        try { return read(state); }
        finally { gate.Release(); }
    }

    public async Task<T> MutateAsync<T>(Func<ChatState, T> mutate, CancellationToken cancellationToken = default)
    {
        await gate.WaitAsync(cancellationToken);
        try
        {
            // Failed validation or disk writes must leave both memory and disk unchanged.
            var next = JsonSerializer.Deserialize<ChatState>(
                JsonSerializer.SerializeToUtf8Bytes(state, JsonOptions), JsonOptions)!;
            var result = mutate(next);
            var temporaryPath = dataPath + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                await using (var stream = new FileStream(temporaryPath, FileMode.CreateNew,
                    FileAccess.Write, FileShare.None, 81920, FileOptions.Asynchronous))
                {
                    if (!OperatingSystem.IsWindows())
                        File.SetUnixFileMode(temporaryPath, UnixFileMode.UserRead | UnixFileMode.UserWrite);
                    await JsonSerializer.SerializeAsync(stream, next, JsonOptions, cancellationToken);
                    await stream.FlushAsync(cancellationToken);
                    stream.Flush(flushToDisk: true);
                }
                cancellationToken.ThrowIfCancellationRequested();
                File.Move(temporaryPath, dataPath, overwrite: true);
                state = next;
                return result;
            }
            finally
            {
                if (File.Exists(temporaryPath)) File.Delete(temporaryPath);
            }
        }
        finally { gate.Release(); }
    }

    public void Dispose()
    {
        processLock.Dispose();
        gate.Dispose();
    }
}

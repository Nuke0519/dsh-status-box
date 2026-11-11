namespace DSHStatusBox.Core;

/// <summary>
/// Tiny append-only log next to the state files; the Windows app has no console,
/// so this is where bridge failures and task outcomes end up.
/// </summary>
public static class Log
{
    private static readonly object Gate = new();

    public static string? FileOverride { get; set; }

    public static void Write(string message)
    {
        string line = $"{DateTimeOffset.Now:yyyy-MM-dd HH:mm:ss.fff} {message}{Environment.NewLine}";
        try
        {
            lock (Gate)
            {
                File.AppendAllText(FileOverride ?? AppPaths.LogFile, line);
            }
        }
        catch
        {
            // logging must never take the companion down
        }
    }
}

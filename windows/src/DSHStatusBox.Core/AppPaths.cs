using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Unicode;

namespace DSHStatusBox.Core;

/// <summary>
/// Where the companion keeps its durable state. On Windows this is
/// <c>%APPDATA%\DSHStatusBox</c>; elsewhere (tests, development) it falls back to
/// <c>~/.dsh-status-box</c> so the core can be exercised without Windows.
/// </summary>
public static class AppPaths
{
    public const string DirectoryName = "DSHStatusBox";

    public static string BaseDir
    {
        get
        {
            string? overrideDir = Environment.GetEnvironmentVariable("DSH_STATUS_BOX_HOME");
            if (!string.IsNullOrEmpty(overrideDir))
            {
                Directory.CreateDirectory(overrideDir);
                return overrideDir;
            }

            if (OperatingSystem.IsWindows())
            {
                string appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
                if (!string.IsNullOrEmpty(appData))
                {
                    string dir = Path.Combine(appData, DirectoryName);
                    Directory.CreateDirectory(dir);
                    return dir;
                }
            }

            string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            string fallback = Path.Combine(home, ".dsh-status-box");
            Directory.CreateDirectory(fallback);
            return fallback;
        }
    }

    public static string StateFile(string name) => Path.Combine(BaseDir, name);

    public static string LogFile => StateFile("companion.log");

    public static JsonSerializerOptions Json { get; } = new()
    {
        WriteIndented = false,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        // keep CJK task text readable on the wire instead of \uXXXX soup
        Encoder = JavaScriptEncoder.Create(UnicodeRanges.All),
    };
}

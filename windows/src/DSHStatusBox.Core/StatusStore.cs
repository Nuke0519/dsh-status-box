using System.Text.Json;

namespace DSHStatusBox.Core;

public readonly record struct StatusTotals(int Waiting, int Running, int Done, int Idle, int Total);

public sealed record StatusWorkspace(string Id, string Title, int Waiting, int Running, int Done);

public sealed record StatusSession(string Title, string State, string Workspace);

/// <summary>
/// Last status payload pushed by the DSH page over <c>POST /status</c>. Kept in
/// memory and mirrored to <c>status.json</c>, so a companion restart (or a
/// throttled/minimized renderer) still shows the last known numbers instead of
/// falling back to "not connected" immediately.
/// </summary>
public sealed class StatusStore
{
    public const double StaleAfterSeconds = 90.0;

    private readonly object _gate = new();
    private readonly string _path;
    private readonly string _logPath;
    private string _raw = "{}";
    private StatusTotals _totals;
    private List<StatusWorkspace> _workspaces = new();
    private List<StatusSession> _sessions = new();
    private DateTimeOffset? _at;

    public StatusStore(string? path = null)
    {
        _path = path ?? AppPaths.StateFile("status.json");
        _logPath = AppPaths.StateFile("status.raw.json");
        LoadFromDisk();
    }

    public bool HasValue
    {
        get
        {
            lock (_gate)
            {
                return _at.HasValue;
            }
        }
    }

    public DateTimeOffset? LastUpdated
    {
        get
        {
            lock (_gate)
            {
                return _at;
            }
        }
    }

    public string Raw
    {
        get
        {
            lock (_gate)
            {
                return _raw;
            }
        }
    }

    public StatusTotals Totals
    {
        get
        {
            lock (_gate)
            {
                return _totals;
            }
        }
    }

    public IReadOnlyList<StatusWorkspace> Workspaces
    {
        get
        {
            lock (_gate)
            {
                return _workspaces.ToArray();
            }
        }
    }

    public IReadOnlyList<StatusSession> Sessions
    {
        get
        {
            lock (_gate)
            {
                return _sessions.ToArray();
            }
        }
    }

    public bool IsLive(double staleSeconds = StaleAfterSeconds)
    {
        lock (_gate)
        {
            return _at.HasValue && (DateTimeOffset.UtcNow - _at.Value).TotalSeconds < staleSeconds;
        }
    }

    /// <summary>Stores a POST /status payload. Returns false when it is not a JSON object.</summary>
    public bool Apply(string body)
    {
        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(body);
        }
        catch (JsonException error)
        {
            Log.Write($"status rejected: {error.Message}");
            return false;
        }

        if (document.RootElement.ValueKind != JsonValueKind.Object)
        {
            document.Dispose();
            return false;
        }

        StatusTotals totals = default;
        var workspaces = new List<StatusWorkspace>();
        var sessions = new List<StatusSession>();

        if (document.RootElement.TryGetProperty("totals", out JsonElement totalsElement) &&
            totalsElement.ValueKind == JsonValueKind.Object)
        {
            totals = new StatusTotals(
                Int(totalsElement, "waiting"),
                Int(totalsElement, "running"),
                Int(totalsElement, "done"),
                Int(totalsElement, "idle"),
                Int(totalsElement, "total"));
        }

        if (document.RootElement.TryGetProperty("workspaces", out JsonElement workspaceElement) &&
            workspaceElement.ValueKind == JsonValueKind.Array)
        {
            foreach (JsonElement item in workspaceElement.EnumerateArray())
            {
                if (item.ValueKind != JsonValueKind.Object)
                {
                    continue;
                }

                workspaces.Add(new StatusWorkspace(
                    String(item, "id"),
                    String(item, "title"),
                    Int(item, "waiting"),
                    Int(item, "running"),
                    Int(item, "done")));
            }
        }

        if (document.RootElement.TryGetProperty("sessions", out JsonElement sessionElement) &&
            sessionElement.ValueKind == JsonValueKind.Array)
        {
            foreach (JsonElement item in sessionElement.EnumerateArray())
            {
                if (item.ValueKind != JsonValueKind.Object)
                {
                    continue;
                }

                sessions.Add(new StatusSession(
                    String(item, "title"),
                    String(item, "state"),
                    String(item, "workspace")));
            }
        }

        document.Dispose();

        lock (_gate)
        {
            _raw = body;
            _totals = totals;
            _workspaces = workspaces;
            _sessions = sessions;
            _at = DateTimeOffset.UtcNow;
            SaveLocked();
        }

        return true;
    }

    private void LoadFromDisk()
    {
        try
        {
            if (!File.Exists(_path))
            {
                return;
            }

            using JsonDocument stored = JsonDocument.Parse(File.ReadAllText(_path));
            if (stored.RootElement.ValueKind != JsonValueKind.Object)
            {
                return;
            }

            string raw = stored.RootElement.TryGetProperty("raw", out JsonElement rawElement) &&
                         rawElement.ValueKind == JsonValueKind.String
                ? rawElement.GetString() ?? string.Empty
                : string.Empty;

            DateTimeOffset? at = null;
            if (stored.RootElement.TryGetProperty("at", out JsonElement atElement) &&
                atElement.ValueKind == JsonValueKind.String &&
                DateTimeOffset.TryParse(atElement.GetString(), out DateTimeOffset parsed))
            {
                at = parsed;
            }

            if (raw.Length == 0)
            {
                return;
            }

            if (Apply(raw))
            {
                lock (_gate)
                {
                    // restore the original timestamp: the numbers are last-known, not new
                    _at = at ?? _at;
                }
            }
        }
        catch (Exception error)
        {
            Log.Write($"status load failed: {error.Message}");
        }
    }

    private void SaveLocked()
    {
        try
        {
            string json = JsonSerializer.Serialize(
                new Dictionary<string, object?>
                {
                    ["raw"] = _raw,
                    ["at"] = _at?.ToString("O"),
                },
                AppPaths.Json);
            File.WriteAllText(_path, json);
            File.WriteAllText(_logPath, _raw);
        }
        catch (Exception error)
        {
            Log.Write($"status save failed: {error.Message}");
        }
    }

    private static int Int(JsonElement element, string name)
    {
        if (!element.TryGetProperty(name, out JsonElement value))
        {
            return 0;
        }

        return value.ValueKind switch
        {
            JsonValueKind.Number => value.TryGetInt32(out int number) ? number : 0,
            JsonValueKind.String => int.TryParse(value.GetString(), out int parsed) ? parsed : 0,
            _ => 0,
        };
    }

    private static string String(JsonElement element, string name) =>
        element.TryGetProperty(name, out JsonElement value) && value.ValueKind == JsonValueKind.String
            ? value.GetString() ?? string.Empty
            : string.Empty;
}

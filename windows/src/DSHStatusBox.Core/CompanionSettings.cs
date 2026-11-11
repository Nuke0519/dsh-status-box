using System.Text.Json;

namespace DSHStatusBox.Core;

/// <summary>
/// The single user preference that the DSH settings page toggles: whether sending
/// from the capture window should reveal the conversation page afterwards.
/// Persisted as <c>config.json</c> = <c>{"openOnSend": bool}</c>.
/// </summary>
public sealed class CompanionSettings
{
    private readonly object _gate = new();
    private readonly string _path;
    private bool _openOnSend;
    private string _dshExe = string.Empty;

    public CompanionSettings(string? path = null)
    {
        _path = path ?? AppPaths.StateFile("config.json");
        Load();
    }

    public bool OpenOnSend
    {
        get
        {
            lock (_gate)
            {
                return _openOnSend;
            }
        }
        set
        {
            lock (_gate)
            {
                _openOnSend = value;
                SaveLocked();
            }
        }
    }

    /// <summary>Optional explicit path to the DeepSeek Harness executable.</summary>
    public string DshExe
    {
        get
        {
            lock (_gate)
            {
                return _dshExe;
            }
        }
        set
        {
            lock (_gate)
            {
                _dshExe = (value ?? string.Empty).Trim();
                SaveLocked();
            }
        }
    }

    public bool ToggleOpenOnSend()
    {
        lock (_gate)
        {
            _openOnSend = !_openOnSend;
            SaveLocked();
            return _openOnSend;
        }
    }

    private void Load()
    {
        try
        {
            if (!File.Exists(_path))
            {
                return;
            }

            using JsonDocument document = JsonDocument.Parse(File.ReadAllText(_path));
            if (document.RootElement.ValueKind != JsonValueKind.Object)
            {
                return;
            }

            if (document.RootElement.TryGetProperty("openOnSend", out JsonElement value) &&
                (value.ValueKind == JsonValueKind.True || value.ValueKind == JsonValueKind.False))
            {
                _openOnSend = value.GetBoolean();
            }

            if (document.RootElement.TryGetProperty("dshExe", out JsonElement exe) &&
                exe.ValueKind == JsonValueKind.String)
            {
                _dshExe = (exe.GetString() ?? string.Empty).Trim();
            }
        }
        catch (Exception error)
        {
            Log.Write($"config load failed: {error.Message}");
        }
    }

    private void SaveLocked()
    {
        try
        {
            string openText = _openOnSend ? "true" : "false";
            string json = _dshExe.Length == 0
                ? $"{{\"openOnSend\":{openText}}}"
                : System.Text.Json.JsonSerializer.Serialize(
                    new Dictionary<string, object?> { ["openOnSend"] = _openOnSend, ["dshExe"] = _dshExe },
                    AppPaths.Json);
            File.WriteAllText(_path, json);
        }
        catch (Exception error)
        {
            Log.Write($"config save failed: {error.Message}");
        }
    }
}

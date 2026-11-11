using System.Text.Json;
using System.Text.Json.Serialization;

namespace DSHStatusBox.Core;

/// <summary>One queued task as stored on disk.</summary>
public sealed class QueuedTask
{
    public string Id { get; set; } = string.Empty;
    public string Text { get; set; } = string.Empty;
    public string WorkspaceId { get; set; } = string.Empty;
    public string State { get; set; } = "pending";
    public double At { get; set; }
    public bool Open { get; set; }
}

/// <summary>One task as handed to the DSH page by <c>GET /command</c>.</summary>
public sealed class WireTask
{
    [JsonPropertyName("id")] public string Id { get; set; } = string.Empty;
    [JsonPropertyName("text")] public string Text { get; set; } = string.Empty;
    [JsonPropertyName("workspaceId")] public string WorkspaceId { get; set; } = string.Empty;
    [JsonPropertyName("open")] public bool Open { get; set; }
}

/// <summary>
/// Durable task queue. The companion can accept tasks while DSH is closed; each
/// page polls <c>GET /command</c> and acknowledges with <c>POST /command/ack</c>.
/// A task stuck "inflight" (page killed mid-delivery) is retried after
/// <see cref="RetryAfterSeconds"/> seconds.
/// </summary>
public sealed class TaskQueue
{
    public const double RetryAfterSeconds = 45.0;

    private readonly object _gate = new();
    private readonly string _path;
    private readonly List<QueuedTask> _tasks = new();

    public TaskQueue(string? path = null)
    {
        _path = path ?? AppPaths.StateFile("queue.json");
        Load();
    }

    public int Count
    {
        get
        {
            lock (_gate)
            {
                return _tasks.Count;
            }
        }
    }

    public QueuedTask Enqueue(string workspaceId, string text, bool open)
    {
        var task = new QueuedTask
        {
            Id = Guid.NewGuid().ToString("D"),
            Text = text,
            WorkspaceId = workspaceId ?? string.Empty,
            State = "pending",
            At = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0,
            Open = open,
        };

        lock (_gate)
        {
            _tasks.Add(task);
            SaveLocked();
        }

        Log.Write($"task queued ({task.Id}) workspace=\"{task.WorkspaceId}\" open={open}");
        return task;
    }

    public IReadOnlyList<WireTask> TakePending()
    {
        var output = new List<WireTask>();
        lock (_gate)
        {
            double now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;
            foreach (QueuedTask task in _tasks)
            {
                bool retry = now - task.At > RetryAfterSeconds;
                if (task.State != "pending" && !retry)
                {
                    continue;
                }

                task.State = "inflight";
                task.At = now;
                output.Add(new WireTask
                {
                    Id = task.Id,
                    Text = task.Text,
                    WorkspaceId = task.WorkspaceId,
                    Open = task.Open,
                });
            }

            if (output.Count > 0)
            {
                SaveLocked();
            }
        }

        return output;
    }

    /// <summary>Removes the task; returns its text so the UI can offer a retry.</summary>
    public string? Ack(string id, bool ok, string? error)
    {
        string? text = null;
        lock (_gate)
        {
            int index = _tasks.FindIndex(task => task.Id == id);
            if (index >= 0)
            {
                text = _tasks[index].Text;
                _tasks.RemoveAt(index);
            }

            SaveLocked();
        }

        Log.Write(ok
            ? $"task delivered ({id})"
            : $"task failed ({id}): {(string.IsNullOrEmpty(error) ? "unknown" : error)}");
        return text;
    }

    private void Load()
    {
        try
        {
            if (!File.Exists(_path))
            {
                return;
            }

            List<QueuedTask>? stored =
                JsonSerializer.Deserialize<List<QueuedTask>>(File.ReadAllText(_path), AppPaths.Json);
            if (stored == null)
            {
                return;
            }

            lock (_gate)
            {
                _tasks.Clear();
                _tasks.AddRange(stored);
            }
        }
        catch (Exception error)
        {
            Log.Write($"queue load failed: {error.Message}");
        }
    }

    private void SaveLocked()
    {
        try
        {
            File.WriteAllText(_path, JsonSerializer.Serialize(_tasks, AppPaths.Json));
        }
        catch (Exception error)
        {
            Log.Write($"queue save failed: {error.Message}");
        }
    }
}

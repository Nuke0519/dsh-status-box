using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;

namespace DSHStatusBox.Core;

/// <summary>Read-only hooks the UI layer exposes to the bridge's diagnostic routes.</summary>
public interface IBridgeUi
{
    bool PanelVisible { get; }
    bool PanelFocused { get; }
    string PanelField { get; }
    string PanelTarget { get; }
    int HotKeyRegisterStatus { get; }
    int HotKeyPresses { get; }
    string BundleId { get; }
}

/// <summary>
/// Loopback HTTP bridge spoken by the DSH page (see <c>client.js</c>). Deliberately
/// a hand-written HTTP/1.1 server on <see cref="TcpListener"/>: the protocol is a
/// handful of tiny JSON routes and this keeps the companion free of URL
/// reservations, admin rights and HTTP.sys quirks.
/// </summary>
public sealed class BridgeServer : IDisposable
{
    public const int DefaultPort = 59421;

    private readonly object _listenerGate = new();
    private readonly TaskQueue _queue;
    private readonly CompanionSettings _settings;
    private readonly StatusStore _status;
    private TcpListener? _listener;
    private volatile bool _running;
    private volatile IBridgeUi? _ui;

    public BridgeServer(TaskQueue queue, CompanionSettings settings, StatusStore status, int port = 0)
    {
        _queue = queue;
        _settings = settings;
        _status = status;
        Port = port > 0 ? port : EnvironmentPort();
    }

    public int Port { get; }

    /// <summary>Raised on the network thread; subscribers must marshal to their UI thread.</summary>
    public event Action? SummonRequested;

    public event Action? StatusUpdated;

    public event Action? SettingsChanged;

    public event Action<bool, string?, string?, string?>? TaskAcknowledged;

    public void AttachUi(IBridgeUi? ui) => _ui = ui;

    public static int EnvironmentPort()
    {
        string? raw = Environment.GetEnvironmentVariable("DSH_STATUS_BOX_PORT");
        return int.TryParse(raw, out int port) && port > 0 ? port : DefaultPort;
    }

    public void Start()
    {
        lock (_listenerGate)
        {
            if (_running)
            {
                return;
            }

            var listener = new TcpListener(IPAddress.Loopback, Port);
            listener.Server.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
            listener.Start();
            _listener = listener;
            _running = true;
        }

        Log.Write($"bridge listening on http://127.0.0.1:{Port}");
        _ = Task.Run(AcceptLoopAsync);
    }

    public void Dispose()
    {
        _running = false;
        lock (_listenerGate)
        {
            try
            {
                _listener?.Stop();
            }
            catch
            {
                // shutting down anyway
            }

            _listener = null;
        }
    }

    private async Task AcceptLoopAsync()
    {
        while (_running)
        {
            TcpListener? listener = _listener;
            if (listener == null)
            {
                return;
            }

            TcpClient client;
            try
            {
                client = await listener.AcceptTcpClientAsync().ConfigureAwait(false);
            }
            catch (Exception) when (!_running)
            {
                return;
            }
            catch (Exception error)
            {
                Log.Write($"accept failed: {error.Message}");
                continue;
            }

            _ = Task.Run(() => HandleAsync(client));
        }
    }

    private async Task HandleAsync(TcpClient client)
    {
        using (client)
        {
            try
            {
                client.NoDelay = true;
                client.ReceiveTimeout = 4000;
                client.SendTimeout = 4000;
                using NetworkStream stream = client.GetStream();

                Request? request = await ReadRequestAsync(stream).ConfigureAwait(false);
                if (request == null)
                {
                    return;
                }

                (int code, string body) = Dispatch(request);
                await WriteResponseAsync(stream, request.Origin, code, body).ConfigureAwait(false);
            }
            catch (Exception error)
            {
                Log.Write($"request failed: {error.Message}");
            }
        }
    }

    private (int Code, string Body) Dispatch(Request request)
    {
        string path = request.Path;
        string method = request.Method;

        Log.Write($"request {method} {path}");

        string? origin = request.Origin;
        if (!string.IsNullOrEmpty(origin) && !OriginAllowed(origin))
        {
            Log.Write($"rejected origin {origin}");
            return (403, "{\"ok\":false,\"error\":\"origin\"}");
        }

        if (method == "OPTIONS")
        {
            return (204, string.Empty);
        }

        try
        {
            switch (path)
            {
                case "/ping":
                    return (200, "{\"ok\":true}");

                case "/summon":
                case "/nudge":
                    if (method is not ("GET" or "POST"))
                    {
                        return (404, "{\"ok\":false}");
                    }

                    SummonRequested?.Invoke();
                    return (200, "{\"ok\":true}");

                case "/config" when method is "GET" or "POST":
                    if (method == "POST")
                    {
                        ApplyConfig(request.Body);
                    }

                    // JSON booleans, not 0/1: the settings page type-checks the field.
                    return (200, _settings.OpenOnSend
                        ? "{\"openOnSend\":true}"
                        : "{\"openOnSend\":false}");

                case "/status" when method == "POST":
                    if (!_status.Apply(request.Body))
                    {
                        return (404, "{\"ok\":false}");
                    }

                    StatusUpdated?.Invoke();
                    return (200, "{\"ok\":true}");

                case "/command" when method == "GET":
                    IReadOnlyList<WireTask> tasks = _queue.TakePending();
                    return (200, JsonSerializer.Serialize(new { tasks }, AppPaths.Json));

                case "/task" when method == "POST":
                    return EnqueueFromRequest(request.Body);

                case "/command/ack" when method == "POST":
                    return Acknowledge(request.Body);

                case "/hotkey":
                    return (200, HotKeyState());

                case "/debug" when DebugEnabled():
                    return (200, string.IsNullOrEmpty(_status.Raw) ? "{}" : _status.Raw);

                case "/panelstate" when DebugEnabled():
                    return (200, PanelState());

                case "/menu" when DebugEnabled():
                    return (200, "{\"items\":[]}");

                default:
                    return (404, "{\"ok\":false}");
            }
        }
        catch (Exception error)
        {
            Log.Write($"route {path} failed: {error.Message}");
            return (500, "{\"ok\":false,\"error\":\"internal\"}");
        }
    }

    private (int Code, string Body) EnqueueFromRequest(string body)
    {
        string text = string.Empty;
        string workspaceId = string.Empty;

        try
        {
            using JsonDocument document = JsonDocument.Parse(body);
            if (document.RootElement.ValueKind == JsonValueKind.Object)
            {
                if (document.RootElement.TryGetProperty("text", out JsonElement textElement) &&
                    textElement.ValueKind == JsonValueKind.String)
                {
                    text = textElement.GetString() ?? string.Empty;
                }

                if (document.RootElement.TryGetProperty("workspaceId", out JsonElement workspaceElement) &&
                    workspaceElement.ValueKind == JsonValueKind.String)
                {
                    workspaceId = workspaceElement.GetString() ?? string.Empty;
                }
            }
        }
        catch (JsonException)
        {
            // fall through to the empty-prompt reply
        }

        text = text.Trim();
        if (text.Length == 0)
        {
            return (200, "{\"ok\":false,\"error\":\"empty\"}");
        }

        QueuedTask task = _queue.Enqueue(workspaceId, text, _settings.OpenOnSend);
        return (200, $"{{\"ok\":true,\"id\":\"{task.Id}\"}}");
    }

    private (int Code, string Body) Acknowledge(string body)
    {
        string id = string.Empty;
        bool ok = false;
        string? error = null;

        try
        {
            using JsonDocument document = JsonDocument.Parse(body);
            if (document.RootElement.ValueKind != JsonValueKind.Object)
            {
                return (404, "{\"ok\":false}");
            }

            if (document.RootElement.TryGetProperty("id", out JsonElement idElement) &&
                idElement.ValueKind == JsonValueKind.String)
            {
                id = idElement.GetString() ?? string.Empty;
            }

            if (document.RootElement.TryGetProperty("ok", out JsonElement okElement))
            {
                ok = okElement.ValueKind == JsonValueKind.True;
            }

            if (document.RootElement.TryGetProperty("error", out JsonElement errorElement) &&
                errorElement.ValueKind == JsonValueKind.String)
            {
                error = errorElement.GetString();
            }
        }
        catch (JsonException)
        {
            return (404, "{\"ok\":false}");
        }

        if (id.Length == 0)
        {
            return (200, "{\"ok\":false}");
        }

        string? text = _queue.Ack(id, ok, error);
        TaskAcknowledged?.Invoke(ok, error, id, text);
        return (200, "{\"ok\":true}");
    }

    private void ApplyConfig(string body)
    {
        try
        {
            using JsonDocument document = JsonDocument.Parse(body);
            if (document.RootElement.ValueKind != JsonValueKind.Object)
            {
                return;
            }

            if (document.RootElement.TryGetProperty("openOnSend", out JsonElement value) &&
                (value.ValueKind == JsonValueKind.True || value.ValueKind == JsonValueKind.False))
            {
                _settings.OpenOnSend = value.GetBoolean();
                SettingsChanged?.Invoke();
            }
        }
        catch (JsonException error)
        {
            Log.Write($"config rejected: {error.Message}");
        }
    }

    private string PanelState()
    {
        IBridgeUi? ui = _ui;
        if (ui == null)
        {
            return "{\"visible\":0,\"key\":0,\"appActive\":0,\"field\":\"\",\"target\":\"\"}";
        }

        return JsonSerializer.Serialize(
            new
            {
                visible = ui.PanelVisible ? 1 : 0,
                key = ui.PanelFocused ? 1 : 0,
                appActive = ui.PanelVisible ? 1 : 0,
                field = ui.PanelField,
                target = ui.PanelTarget,
            },
            AppPaths.Json);
    }

    private string HotKeyState()
    {
        IBridgeUi? ui = _ui;
        return JsonSerializer.Serialize(
            new
            {
                register = ui?.HotKeyRegisterStatus ?? 0,
                handler = ui?.HotKeyRegisterStatus ?? 0,
                alt = 0,
                presses = ui?.HotKeyPresses ?? 0,
                source = "win32",
                trusted = 1,
                bundle = ui?.BundleId ?? "dsh-status-box.windows",
            },
            AppPaths.Json);
    }

    private static bool OriginAllowed(string origin) =>
        origin.StartsWith("dsh-app://", StringComparison.OrdinalIgnoreCase) ||
        origin.StartsWith("http://127.0.0.1:", StringComparison.OrdinalIgnoreCase) ||
        origin.StartsWith("http://localhost:", StringComparison.OrdinalIgnoreCase) ||
        origin.Equals("http://127.0.0.1", StringComparison.OrdinalIgnoreCase) ||
        origin.Equals("http://localhost", StringComparison.OrdinalIgnoreCase) ||
        origin.StartsWith("file://", StringComparison.OrdinalIgnoreCase) ||
        origin.Equals("null", StringComparison.OrdinalIgnoreCase);

    private static bool DebugEnabled() =>
        Environment.GetEnvironmentVariable("DSH_STATUS_BOX_DEBUG") == "1";

    private static async Task<Request?> ReadRequestAsync(NetworkStream stream)
    {
        var buffer = new List<byte>(2048);
        var chunk = new byte[1024];

        while (true)
        {
            int read = await stream.ReadAsync(chunk).ConfigureAwait(false);
            if (read <= 0)
            {
                return null;
            }

            buffer.AddRange(chunk.AsSpan(0, read).ToArray());
            int headerEnd = FindHeaderEnd(buffer);
            if (headerEnd >= 0)
            {
                string headerText = Encoding.UTF8.GetString(buffer.ToArray(), 0, headerEnd);

                int contentLength = 0;
                string? origin = null;
                foreach (string line in headerText.Split("\r\n").Skip(1))
                {
                    int colon = line.IndexOf(':');
                    if (colon <= 0)
                    {
                        continue;
                    }

                    string name = line[..colon].Trim();
                    string value = line[(colon + 1)..].Trim();
                    if (name.Equals("Content-Length", StringComparison.OrdinalIgnoreCase))
                    {
                        int.TryParse(value, out contentLength);
                    }
                    else if (name.Equals("Origin", StringComparison.OrdinalIgnoreCase))
                    {
                        origin = value;
                    }
                }

                int bodyStart = headerEnd + 4;
                var bodyBytes = new List<byte>(buffer.Skip(bodyStart));
                while (bodyBytes.Count < contentLength)
                {
                    int more = await stream.ReadAsync(chunk).ConfigureAwait(false);
                    if (more <= 0)
                    {
                        break;
                    }

                    bodyBytes.AddRange(chunk.AsSpan(0, more).ToArray());
                }

                string requestLine = headerText.Split("\r\n")[0];
                string[] parts = requestLine.Split(' ');
                if (parts.Length < 2)
                {
                    return null;
                }

                string target = parts[1];
                int queryIndex = target.IndexOf('?');
                if (queryIndex >= 0)
                {
                    target = target[..queryIndex];
                }

                byte[] bodyArray = bodyBytes.Take(contentLength).ToArray();
                return new Request(parts[0].ToUpperInvariant(), target, origin, Encoding.UTF8.GetString(bodyArray));
            }

            if (buffer.Count > 64 * 1024)
            {
                return null;
            }
        }
    }

    private static int FindHeaderEnd(IReadOnlyList<byte> buffer)
    {
        for (int index = 3; index < buffer.Count; index++)
        {
            if (buffer[index - 3] == '\r' && buffer[index - 2] == '\n' &&
                buffer[index - 1] == '\r' && buffer[index] == '\n')
            {
                return index - 3;
            }
        }

        return -1;
    }

    private static async Task WriteResponseAsync(NetworkStream stream, string? origin, int code, string body)
    {
        string reason = code switch
        {
            200 => "OK",
            204 => "No Content",
            403 => "Forbidden",
            404 => "Not Found",
            500 => "Internal Server Error",
            _ => "OK",
        };

        byte[] payload = Encoding.UTF8.GetBytes(body);
        var builder = new StringBuilder();
        builder.Append($"HTTP/1.1 {code} {reason}\r\n");
        builder.Append("Content-Type: application/json; charset=utf-8\r\n");
        builder.Append($"Content-Length: {payload.Length}\r\n");
        builder.Append("Cache-Control: no-store\r\n");
        builder.Append("Connection: close\r\n");
        if (!string.IsNullOrEmpty(origin) && OriginAllowed(origin))
        {
            builder.Append($"Access-Control-Allow-Origin: {origin}\r\n");
            builder.Append("Vary: Origin\r\n");
        }
        else
        {
            builder.Append("Access-Control-Allow-Origin: *\r\n");
        }

        builder.Append("Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n");
        builder.Append("Access-Control-Allow-Headers: Content-Type, Access-Control-Request-Private-Network\r\n");
        // Chrome's Private Network Access preflight fails the request without this
        // header on the response, even for loopback-to-loopback calls.
        builder.Append("Access-Control-Allow-Private-Network: true\r\n");
        builder.Append("Access-Control-Max-Age: 600\r\n");
        builder.Append("\r\n");

        byte[] head = Encoding.UTF8.GetBytes(builder.ToString());
        await stream.WriteAsync(head).ConfigureAwait(false);
        if (payload.Length > 0)
        {
            await stream.WriteAsync(payload).ConfigureAwait(false);
        }

        await stream.FlushAsync().ConfigureAwait(false);
    }

    private sealed record Request(string Method, string Path, string? Origin, string Body);
}

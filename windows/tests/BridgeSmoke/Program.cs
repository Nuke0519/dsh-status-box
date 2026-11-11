using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using DSHStatusBox.Core;

namespace BridgeSmoke;

/// <summary>
/// Exercises the platform-neutral bridge core on any OS: this is the part of the
/// Windows companion that has to speak exactly the same protocol as the DSH page
/// and the macOS companion, so it is worth running for real during development.
/// </summary>
internal static class Program
{
    private static int _failures;
    private static BridgeServer _server = null!;
    private static TaskQueue _queue = null!;
    private static CompanionSettings _settings = null!;
    private static StatusStore _status = null!;
    private static HttpClient _http = null!;
    private static string _baseUrl = string.Empty;

    private static async Task<int> Main()
    {
        string home = Path.Combine(Path.GetTempPath(), "dsh-status-box-smoke-" + Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(home);
        Environment.SetEnvironmentVariable("DSH_STATUS_BOX_HOME", home);
        Log.FileOverride = Path.Combine(home, "companion.log");

        int port = FreePort();
        Environment.SetEnvironmentVariable("DSH_STATUS_BOX_PORT", port.ToString());

        _queue = new TaskQueue(Path.Combine(home, "queue.json"));
        _settings = new CompanionSettings(Path.Combine(home, "config.json"));
        _status = new StatusStore(Path.Combine(home, "status.json"));
        _server = new BridgeServer(_queue, _settings, _status);

        int taskAcks = 0;
        bool lastAckOk = false;
        _server.TaskAcknowledged += (ok, error, id, text) =>
        {
            taskAcks++;
            lastAckOk = ok;
            Console.WriteLine($"  (ack event: id={id} ok={ok} error={error})");
        };

        _server.Start();
        _baseUrl = $"http://127.0.0.1:{port}";
        _http = new HttpClient { Timeout = TimeSpan.FromSeconds(5) };

        await WaitUntilListening();

        var appSentStatus = """
            {"v":1,"ts":1794317960708,
             "totals":{"waiting":1,"running":2,"done":1,"idle":8,"total":12},
             "workspaces":[
               {"id":"w-alpha","title":"default-workspace","waiting":1,"running":2,"done":1},
               {"id":"w-beta","title":"beta","waiting":0,"running":0,"done":0}],
             "sessions":[
               {"title":"写周报","state":"running","workspace":"default-workspace"},
               {"title":"审阅 PPT","state":"waiting","workspace":"default-workspace"}]}
            """;

        // ---- routes the page relies on -------------------------------------
        Check("GET /ping", (await Get("/ping")).Body, "{\"ok\":true}");

        HttpResponseMessage optionsResponse = await Send(HttpMethod.Options, "/status", null, "dsh-app://app");
        Check("preflight OPTIONS status", optionsResponse.StatusCode, HttpStatusCode.NoContent);
        Check(
            "preflight allows private network",
            optionsResponse.Headers.TryGetValues("Access-Control-Allow-Private-Network", out IEnumerable<string>? pna)
                ? string.Join(",", pna)
                : "missing",
            "true");
        Check(
            "preflight echoes the app origin",
            optionsResponse.Headers.TryGetValues("Access-Control-Allow-Origin", out IEnumerable<string>? acao)
                ? string.Join(",", acao)
                : "missing",
            "dsh-app://app");

        Check(
            "foreign origin is rejected",
            (await Send(HttpMethod.Post, "/status", appSentStatus, "https://evil.example")).StatusCode,
            HttpStatusCode.Forbidden);

        HttpResponseMessage statusResponse = await Send(HttpMethod.Post, "/status", appSentStatus, "dsh-app://app");
        Check("POST /status", statusResponse.StatusCode, HttpStatusCode.OK);
        Check("status totals parsed", _status.Totals, new StatusTotals(1, 2, 1, 8, 12));
        Check("status workspaces parsed", _status.Workspaces.Count, 2);
        Check("status sessions parsed", _status.Sessions.Count, 2);
        Check("status is live", _status.IsLive(), true);
        Check("status persisted", File.Exists(Path.Combine(home, "status.json")), true);

        Check("GET /config default", (await Get("/config")).Body, "{\"openOnSend\":false}");
        Check("POST /config", (await SendBody(HttpMethod.Post, "/config", "{\"openOnSend\":true}", "dsh-app://app")).Body, "{\"openOnSend\":true}");
        Check("config applied", _settings.OpenOnSend, true);
        Check("config persisted", File.ReadAllText(Path.Combine(home, "config.json")), "{\"openOnSend\":true}");
        Check("POST /config back off", (await SendBody(HttpMethod.Post, "/config", "{\"openOnSend\":false}", "dsh-app://app")).Body, "{\"openOnSend\":false}");

        // ---- task queue ----------------------------------------------------
        Check("GET /command empty", (await Get("/command")).Body, "{\"tasks\":[]}");
        Check("POST /task empty prompt", (await SendBody(HttpMethod.Post, "/task", "{\"text\":\"   \"}", "dsh-app://app")).Body, "{\"ok\":false,\"error\":\"empty\"}");

        _settings.OpenOnSend = true; // the queued task must snapshot this
        HttpResponseMessage enqueueResponse = await Send(HttpMethod.Post, "/task", "{\"text\":\"  写个周报  \",\"workspaceId\":\"w-alpha\"}", "dsh-app://app");
        Check("POST /task", enqueueResponse.StatusCode, HttpStatusCode.OK);
        using JsonDocument enqueued = JsonDocument.Parse(await enqueueResponse.Content.ReadAsStringAsync());
        string taskId = enqueued.RootElement.GetProperty("id").GetString() ?? string.Empty;
        Check("queued task has an id", taskId.Length, 36);
        Check("queue holds one task", _queue.Count, 1);

        string commandBody = (await Get("/command")).Body;
        Check("GET /command delivers the task", commandBody.Contains("\"text\":\"写个周报\""), true);
        Check("wire task carries open", commandBody.Contains("\"open\":true"), true);
        Check("wire task carries workspace", commandBody.Contains("\"workspaceId\":\"w-alpha\""), true);
        Check("inflight task is not delivered twice", (await Get("/command")).Body, "{\"tasks\":[]}");

        Check("POST /command/ack", (await SendBody(HttpMethod.Post, "/command/ack", $"{{\"id\":\"{taskId}\",\"ok\":true,\"error\":\"\"}}", "dsh-app://app")).Body, "{\"ok\":true}");
        Check("queue drained", _queue.Count, 0);
        Check("ack raised an event", taskAcks, 1);
        Check("ack reported success", lastAckOk, true);

        // a failed delivery must report the reason back
        await Send(HttpMethod.Post, "/task", "{\"text\":\"会失败的\",\"workspaceId\":\"\"}", "dsh-app://app");
        using JsonDocument secondQueue = JsonDocument.Parse((await Get("/command")).Body);
        string failedId = secondQueue.RootElement.GetProperty("tasks")[0].GetProperty("id").GetString() ?? string.Empty;
        await Send(HttpMethod.Post, "/command/ack", $"{{\"id\":\"{failedId}\",\"ok\":false,\"error\":\"noService\"}}", "dsh-app://app");
        Check("failed ack still drains", _queue.Count, 0);
        Check("failed ack reported failure", lastAckOk, false);

        // a task that was delivered but never acked is retried after the timeout
        QueuedTask stuck = _queue.Enqueue("", "重试我", false);
        await Get("/command");
        string queuePath = Path.Combine(home, "queue.json");
        string json = File.ReadAllText(queuePath);
        Check("stuck task is inflight", json.Contains("\"state\":\"inflight\""), true);
        var reloaded = new TaskQueue(queuePath);
        Check("inflight task survives a restart", reloaded.Count, 1);
        _ = stuck;

        // ---- summon + diagnostics ------------------------------------------
        int summons = 0;
        _server.SummonRequested += () => summons++;
        await Get("/summon");
        await Get("/nudge");
        Check("summon/nudge raise events", summons, 2);

        Check("debug routes are off by default", (await Get("/debug")).Status, HttpStatusCode.NotFound);
        Environment.SetEnvironmentVariable("DSH_STATUS_BOX_DEBUG", "1");
        Check("debug routes gated by env", (await Get("/debug")).Status, HttpStatusCode.OK);
        Check("debug mirrors the last payload", _status.Raw.Contains("\"waiting\":1"), true);
        Check("panelstate available for debugging", (await Get("/panelstate")).Status, HttpStatusCode.OK);
        Check("hotkey diagnostics", (await Get("/hotkey")).Body.Contains("\"source\":\"win32\""), true);
        Environment.SetEnvironmentVariable("DSH_STATUS_BOX_DEBUG", null);

        Check("unknown route", (await Get("/nope")).Status, HttpStatusCode.NotFound);

        _server.Dispose();
        _http.Dispose();

        Console.WriteLine();
        Console.WriteLine(_failures == 0 ? "ALL CHECKS PASSED" : $"{_failures} CHECK(S) FAILED");
        return _failures == 0 ? 0 : 1;
    }

    // ---------------------------------------------------------------- helpers

    private static async Task WaitUntilListening()
    {
        var probe = new Stopwatch();
        probe.Start();
        while (probe.Elapsed < TimeSpan.FromSeconds(5))
        {
            try
            {
                HttpResponseMessage response = await _http.GetAsync(_baseUrl + "/ping");
                if (response.IsSuccessStatusCode)
                {
                    return;
                }
            }
            catch
            {
                // not up yet
            }

            await Task.Delay(25);
        }

        throw new InvalidOperationException("bridge did not start");
    }

    private static async Task<(HttpStatusCode Status, string Body)> Get(string path)
    {
        HttpResponseMessage response = await _http.GetAsync(_baseUrl + path);
        return (response.StatusCode, await response.Content.ReadAsStringAsync());
    }

    private static async Task<(HttpStatusCode Status, string Body)> SendBody(HttpMethod method, string path, string? body, string? origin)
    {
        HttpResponseMessage response = await Send(method, path, body, origin);
        return (response.StatusCode, await response.Content.ReadAsStringAsync());
    }

    private static async Task<HttpResponseMessage> Send(HttpMethod method, string path, string? body, string? origin)
    {
        using var request = new HttpRequestMessage(method, _baseUrl + path);
        if (body != null)
        {
            request.Content = new StringContent(body, Encoding.UTF8, "text/plain");
        }

        if (origin != null)
        {
            request.Headers.TryAddWithoutValidation("Origin", origin);
        }

        return await _http.SendAsync(request);
    }

    private static void Check(string label, object? actual, object? expected)
    {
        string actualText = actual?.ToString() ?? "null";
        string expectedText = expected?.ToString() ?? "null";
        if (actualText == expectedText)
        {
            Console.WriteLine($"PASS {label}");
            return;
        }

        _failures++;
        Console.WriteLine($"FAIL {label}\n     expected: {expectedText}\n     actual:   {actualText}");
    }

    private static int FreePort()
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        int port = ((IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();
        return port;
    }
}

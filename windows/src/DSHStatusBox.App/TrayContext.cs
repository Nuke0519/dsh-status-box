using System.Diagnostics;
using System.Drawing;
using System.Windows.Forms;
using DSHStatusBox.Core;

namespace DSHStatusBox.App;

/// <summary>
/// Tray application glue: owns the invisible tray icon, the capture window and the
/// loopback bridge. The bridge runs on background threads; every callback that
/// touches WinForms is marshalled back through the message loop.
/// </summary>
internal sealed class TrayContext : ApplicationContext, IBridgeUi
{
    private readonly TaskQueue _queue;
    private readonly CompanionSettings _settings;
    private readonly StatusStore _status;
    private readonly BridgeServer _server;
    private readonly WhaleIcons _icons;
    private readonly HotKeyWindow _hotkey;
    private readonly CaptureForm _capture;
    private readonly NotifyIcon _tray;
    private readonly ContextMenuStrip _menu;
    private readonly ToolStripMenuItem _headerItem;
    private readonly ToolStripMenuItem _summaryItem;
    private readonly ToolStripMenuItem _workspaceHeaderItem;
    private readonly ToolStripMenuItem _sessionsHeaderItem;
    private readonly ToolStripMenuItem _openOnSendItem;
    private readonly System.Windows.Forms.Timer _refreshTimer;
    private readonly System.Windows.Forms.Timer _detailTimer;
    private readonly List<ToolStripItem> _dynamicItems = new();

    private StatusVisual _visual = StatusVisual.Offline;
    private int _count;
    private string _lastTooltip = string.Empty;

    public TrayContext()
    {
        _queue = new TaskQueue();
        _settings = new CompanionSettings();
        _status = new StatusStore();
        _icons = new WhaleIcons();

        _hotkey = new HotKeyWindow();
        _hotkey.Pressed += TogglePanel;

        _capture = new CaptureForm();
        _capture.SubmitRequested += OnSubmit;

        _headerItem = new ToolStripMenuItem("…") { Enabled = false };
        _summaryItem = new ToolStripMenuItem("…") { Enabled = false };
        _workspaceHeaderItem = new ToolStripMenuItem("工作区") { Enabled = false };
        _sessionsHeaderItem = new ToolStripMenuItem("会话") { Enabled = false };
        _openOnSendItem = new ToolStripMenuItem("发送后打开对话页")
        {
            CheckOnClick = false,
            ShortcutKeyDisplayString = "开关",
        };
        _openOnSendItem.Click += (_, _) =>
        {
            _settings.ToggleOpenOnSend();
            UpdateOpenOnSendItem();
            _capture.SetNormalHint("Enter 发起 · Esc 关闭");
        };

        _menu = new ContextMenuStrip();
        _menu.Items.Add(_headerItem);
        _menu.Items.Add(_summaryItem);
        _menu.Items.Add(new ToolStripSeparator());
        _menu.Items.Add(_workspaceHeaderItem);
        _menu.Items.Add(_sessionsHeaderItem);
        _menu.Items.Add(new ToolStripSeparator());
        _menu.Items.Add(new ToolStripMenuItem("新建任务…   Ctrl+Alt+Shift+D", null, (_, _) => ShowPanel()));
        _menu.Items.Add(_openOnSendItem);
        _menu.Items.Add(new ToolStripMenuItem("打开 DSH", null, (_, _) => OpenDsh()));
        _menu.Items.Add(new ToolStripMenuItem("打开配置文件夹", null, (_, _) => OpenConfigFolder()));
        _menu.Items.Add(new ToolStripSeparator());
        _menu.Items.Add(new ToolStripMenuItem("退出状态盒", null, (_, _) => ExitThread()));
        _menu.Opening += (_, _) => RebuildMenu();

        _tray = new NotifyIcon
        {
            Visible = true,
            ContextMenuStrip = _menu,
            Text = "状态盒",
        };
        _tray.MouseClick += (_, args) =>
        {
            if (args.Button == MouseButtons.Left)
            {
                ShowPanel();
            }
        };

        UpdateOpenOnSendItem();

        _server = new BridgeServer(_queue, _settings, _status);
        _server.AttachUi(this);
        _server.SummonRequested += () => PostToUi(ShowPanel);
        _server.StatusUpdated += () => PostToUi(UpdateVisual);
        _server.SettingsChanged += () => PostToUi(UpdateOpenOnSendItem);
        _server.TaskAcknowledged += OnTaskAcknowledged;

        try
        {
            _server.Start();
        }
        catch (Exception error)
        {
            Log.Write($"bridge start failed: {error.Message}");
            _tray.Text = "状态盒：端口被占用";
        }

        _hotkey.Register();

        _refreshTimer = new System.Windows.Forms.Timer { Interval = 2000 };
        _refreshTimer.Tick += (_, _) => UpdateVisual();
        _refreshTimer.Start();

        // keeps relative timestamps and the "last known" freshness honest
        _detailTimer = new System.Windows.Forms.Timer { Interval = 5000 };
        _detailTimer.Tick += (_, _) => { };
        _detailTimer.Start();

        UpdateVisual();
        Log.Write("companion started");
    }

    // ------------------------------------------------------------ bridge hooks

    public bool PanelVisible => _capture.Visible;

    public bool PanelFocused => _capture.Visible && (_capture.ContainsFocus || _capture.Focused);

    public string PanelField => _capture.FieldText;

    public string PanelTarget => _capture.TargetWorkspaceId;

    public int HotKeyRegisterStatus => _hotkey.RegisterStatus;

    public int HotKeyPresses => _hotkey.Presses;

    public string BundleId => "dsh-status-box.windows";

    // ---------------------------------------------------------------- actions

    private void TogglePanel()
    {
        if (_capture.Visible)
        {
            _capture.HidePanel();
            return;
        }

        ShowPanel();
    }

    private void ShowPanel()
    {
        CaptureForm form = _capture;
        string current = form.TargetWorkspaceId;
        form.SetTargets(TargetList(), current);
        form.SetNormalHint(_settings.OpenOnSend ? "Enter 发起 · 发送后打开对话页" : "Enter 发起 · Esc 关闭");
        form.ShowPanel();
    }

    private IReadOnlyList<(string Id, string Title)> TargetList()
    {
        var targets = new List<(string Id, string Title)>();
        foreach (StatusWorkspace workspace in _status.Workspaces)
        {
            if (workspace.Id.Length > 0)
            {
                targets.Add((workspace.Id, string.IsNullOrEmpty(workspace.Title) ? workspace.Id : workspace.Title));
            }
        }

        if (targets.Count == 0)
        {
            targets.Add((string.Empty, "默认工作区"));
        }

        return targets;
    }

    private bool OnSubmit(string workspaceId, string text)
    {
        QueuedTask task = _queue.Enqueue(workspaceId, text, _settings.OpenOnSend);
        Log.Write($"task queued ({task.Id}) via capture window");

        if (!DshProcess.IsRunning() || _settings.OpenOnSend)
        {
            DshProcess.Open(_settings.DshExe);
        }

        return true;
    }

    private void OnTaskAcknowledged(bool ok, string? error, string? id, string? text)
    {
        if (ok)
        {
            return;
        }

        PostToUi(() => _capture.ShowFailure(text ?? string.Empty, error));
    }

    private void OpenDsh()
    {
        DshProcess.Open(_settings.DshExe);
    }

    private static void OpenConfigFolder()
    {
        try
        {
            Directory.CreateDirectory(AppPaths.BaseDir);
            Process.Start(new ProcessStartInfo(AppPaths.BaseDir) { UseShellExecute = true });
        }
        catch (Exception error)
        {
            Log.Write($"open config folder failed: {error.Message}");
        }
    }

    // ------------------------------------------------------------ rendering

    private void UpdateVisual()
    {
        StatusTotals totals = _status.Totals;
        bool dshUp = DshProcess.IsRunning();
        bool live = _status.IsLive();

        StatusVisual visual;
        int count;
        if (!_status.HasValue)
        {
            visual = StatusVisual.Offline;
            count = 0;
        }
        else if (!live && !dshUp)
        {
            visual = StatusVisual.Offline;
            count = 0;
        }
        else if (totals.Waiting > 0)
        {
            visual = StatusVisual.Waiting;
            count = totals.Waiting;
        }
        else if (totals.Running > 0)
        {
            visual = StatusVisual.Running;
            count = totals.Running;
        }
        else if (totals.Done > 0 && live)
        {
            visual = StatusVisual.Done;
            count = totals.Done;
        }
        else
        {
            visual = StatusVisual.Idle;
            count = 0;
        }

        _visual = visual;
        _count = count;
        _tray.Icon = _icons.Get(visual, count);

        string tooltip = BuildTooltip(totals, visual);
        if (tooltip != _lastTooltip)
        {
            _lastTooltip = tooltip;
            _tray.Text = tooltip.Length > 63 ? tooltip[..63] : tooltip;
        }

        if (_menu.Visible)
        {
            RebuildMenu();
        }
    }

    private string BuildTooltip(StatusTotals totals, StatusVisual visual)
    {
        string suffix = "点击或 Ctrl+Alt+Shift+D 新建任务";
        return visual switch
        {
            StatusVisual.Offline => $"状态盒：未连接（任务会排队，启动后自动发出）；{suffix}",
            StatusVisual.Waiting =>
                $"状态盒：{totals.Waiting} 个任务等你处理 · {totals.Running} 个运行中 · {suffix}",
            StatusVisual.Running => $"状态盒：{totals.Running} 个运行中 · {totals.Waiting} 个待处理 · {suffix}",
            StatusVisual.Done => $"状态盒：{totals.Done} 个已完成 · {suffix}",
            _ => $"状态盒：空闲；{suffix}",
        };
    }

    private void UpdateOpenOnSendItem()
    {
        _openOnSendItem.Checked = _settings.OpenOnSend;
        _openOnSendItem.CheckState = _settings.OpenOnSend ? CheckState.Checked : CheckState.Unchecked;
    }

    private void RebuildMenu()
    {
        StatusTotals totals = _status.Totals;
        _headerItem.Text = totals.Waiting > 0
            ? $"◉ {totals.Waiting} 个任务等你处理"
            : _status.IsLive() ? "○ 没有需要你处理的" : "○ 未连接";
        _summaryItem.Text = $"● {totals.Running} 运行中    ✓ {totals.Done} 已完成";
        UpdateOpenOnSendItem();

        foreach (ToolStripItem item in _dynamicItems)
        {
            item.Dispose();
        }

        _dynamicItems.Clear();

        int insertAt = _menu.Items.IndexOf(_workspaceHeaderItem) + 1;
        IReadOnlyList<StatusWorkspace> workspaces = _status.Workspaces;
        if (workspaces.Count == 0)
        {
            _workspaceHeaderItem.Visible = false;
        }
        else
        {
            _workspaceHeaderItem.Visible = true;
            int shown = 0;
            foreach (StatusWorkspace workspace in workspaces)
            {
                if (shown >= 5)
                {
                    break;
                }

                string title = string.IsNullOrEmpty(workspace.Title) ? workspace.Id : workspace.Title;
                var item = new ToolStripMenuItem($"{title} · {workspace.Running} 运行 / {workspace.Waiting} 待处理")
                {
                    Enabled = false,
                };
                _menu.Items.Insert(insertAt++, item);
                _dynamicItems.Add(item);
                shown++;
            }
        }

        int sessionInsertAt = _menu.Items.IndexOf(_sessionsHeaderItem) + 1;
        IReadOnlyList<StatusSession> sessions = _status.Sessions;
        if (sessions.Count == 0)
        {
            _sessionsHeaderItem.Visible = false;
        }
        else
        {
            _sessionsHeaderItem.Visible = true;
            int shown = 0;
            foreach (StatusSession session in sessions)
            {
                if (shown >= 8)
                {
                    break;
                }

                string dot = session.State switch
                {
                    "waiting" => "◉",
                    "running" => "●",
                    "done" => "✓",
                    _ => "○",
                };
                var item = new ToolStripMenuItem($"{dot} {session.Title}")
                {
                    ToolTipText = session.Workspace,
                };
                item.Click += (_, _) => DshProcess.Open();
                _menu.Items.Insert(sessionInsertAt++, item);
                _dynamicItems.Add(item);
                shown++;
            }
        }
    }

    private void PostToUi(Action action)
    {
        if (_capture.IsHandleCreated)
        {
            _capture.BeginInvoke(action);
            return;
        }

        action();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _refreshTimer.Dispose();
            _detailTimer.Dispose();
            _hotkey.Dispose();
            _capture.Dispose();
            _tray.Visible = false;
            _tray.Dispose();
            _menu.Dispose();
            _icons.Dispose();
            _server.Dispose();
        }

        base.Dispose(disposing);
    }
}

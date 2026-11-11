using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;

namespace DSHStatusBox.App;

/// <summary>
/// The Spotlight-style capture window: one input field, no buttons. Enter queues a
/// task, Tab cycles the target workspace, Esc or clicking away hides it. Kept
/// deliberately minimal — everything else lives in the tray menu.
/// </summary>
internal sealed class CaptureForm : Form
{
    private const int EmSetCueBanner = 0x1501;
    private const int WmSetRedraw = 0x000B;

    private readonly TextBox _field;
    private readonly Label _glyph;
    private readonly Label _hint;
    private readonly System.Windows.Forms.Timer _hintTimer;
    private string _normalHint = "Enter 发起 · Esc 关闭";

    private IReadOnlyList<(string Id, string Title)> _targets = Array.Empty<(string, string)>();
    private int _targetIndex;
    private DateTime _shownAt = DateTime.MinValue;
    private bool _submitting;

    public CaptureForm()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        TopMost = true;
        KeyPreview = true;
        BackColor = Color.FromArgb(0x23, 0x24, 0x27);
        Size = new Size(560, 64);
        DoubleBuffered = true;
        Padding = new Padding(0);

        _glyph = new Label
        {
            Text = "\uE70F", // Segoe MDL2 "Edit"
            Font = new Font("Segoe MDL2 Assets", 14f, FontStyle.Regular, GraphicsUnit.Point),
            ForeColor = Color.FromArgb(0xB8, 0xBC, 0xC4),
            TextAlign = ContentAlignment.MiddleCenter,
            BackColor = Color.Transparent,
        };

        _field = new TextBox
        {
            BorderStyle = BorderStyle.None,
            BackColor = Color.FromArgb(0x23, 0x24, 0x27),
            ForeColor = Color.FromArgb(0xF2, 0xF3, 0xF5),
            Font = new Font("Microsoft YaHei UI", 12f, FontStyle.Regular, GraphicsUnit.Point),
            ShortcutsEnabled = true,
        };

        _hint = new Label
        {
            Text = "↵",
            Font = new Font("Segoe UI", 9f, FontStyle.Regular, GraphicsUnit.Point),
            ForeColor = Color.FromArgb(0x8A, 0x8F, 0x98),
            TextAlign = ContentAlignment.MiddleRight,
            BackColor = Color.Transparent,
        };

        Controls.Add(_glyph);
        Controls.Add(_field);
        Controls.Add(_hint);

        _hintTimer = new System.Windows.Forms.Timer { Interval = 3600 };
        _hintTimer.Tick += (_, _) =>
        {
            _hintTimer.Stop();
            ResetHint();
        };

        _field.KeyDown += OnFieldKeyDown;
        Deactivate += OnDeactivate;
        Paint += OnPaint;
        Resize += (_, _) => LayoutChildren();
        LayoutChildren();
    }

    public string FieldText
    {
        get => _field.Text;
        set => _field.Text = value;
    }

    public string TargetLabel =>
        _targets.Count == 0 ? string.Empty
        : string.IsNullOrEmpty(_targets[Math.Clamp(_targetIndex, 0, _targets.Count - 1)].Title)
            ? _targets[Math.Clamp(_targetIndex, 0, _targets.Count - 1)].Id
            : _targets[Math.Clamp(_targetIndex, 0, _targets.Count - 1)].Title;

    public string TargetWorkspaceId =>
        _targets.Count == 0 ? string.Empty : _targets[Math.Clamp(_targetIndex, 0, _targets.Count - 1)].Id;

    /// <summary>Queues the current text; returns false when it was empty.</summary>
    public event Func<string, string, bool>? SubmitRequested;

    public void SetTargets(IReadOnlyList<(string Id, string Title)> targets, string preferredId)
    {
        string previousId = TargetWorkspaceId;
        _targets = targets;
        int index = targets.ToList().FindIndex(item => item.Id == preferredId);
        if (index < 0)
        {
            index = targets.ToList().FindIndex(item => item.Id == previousId);
        }

        _targetIndex = index < 0 ? 0 : index;
        ApplyCue();
    }

    public void SetNormalHint(string hint)
    {
        _normalHint = hint;
        ResetHint();
    }

    public void ShowPanel(bool focusField = true)
    {
        ApplyCue();
        PositionOnPointerScreen();
        _shownAt = DateTime.UtcNow;
        if (!Visible)
        {
            Show();
        }

        Activate();
        TopMost = true;
        if (focusField)
        {
            _field.Focus();
            _field.SelectAll();
        }
    }

    public void HidePanel()
    {
        _hintTimer.Stop();
        ResetHint();
        if (Visible)
        {
            Hide();
        }
    }

    public void ShowFailure(string text, string? error)
    {
        _field.Text = text ?? string.Empty;
        _hint.ForeColor = Color.FromArgb(0xE5, 0x5B, 0x4B);
        _hint.Text = string.IsNullOrEmpty(error) ? "发送失败" : $"发送失败（{error}）";
        System.Media.SystemSounds.Exclamation.Play();
        ShowPanel();
        _field.Focus();
        _field.SelectAll();
        _hintTimer.Stop();
        _hintTimer.Start();
    }

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        ApplyRoundedRegion();
    }

    protected override void OnPaintBackground(PaintEventArgs e)
    {
        if (ClientRectangle.Width <= 0 || ClientRectangle.Height <= 0)
        {
            return;
        }

        using var brush = new SolidBrush(BackColor);
        e.Graphics.FillRectangle(brush, ClientRectangle);
        using var pen = new Pen(Color.FromArgb(0x3A, 0x3D, 0x43), 1f);
        e.Graphics.DrawRectangle(pen, 0, 0, ClientRectangle.Width - 1, ClientRectangle.Height - 1);
    }

    private void OnPaint(object? sender, PaintEventArgs e)
    {
        // background/border are drawn in OnPaintBackground; nothing else to do here
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
    }

    private void OnDeactivate(object? sender, EventArgs e)
    {
        // Ignore the activation bounce right after the hot key shows the window.
        if ((DateTime.UtcNow - _shownAt).TotalMilliseconds < 280)
        {
            return;
        }

        if (_submitting || _hintTimer.Enabled)
        {
            return;
        }

        HidePanel();
    }

    private void OnFieldKeyDown(object? sender, KeyEventArgs e)
    {
        switch (e.KeyCode)
        {
            case Keys.Enter:
                e.SuppressKeyPress = true;
                Submit();
                break;
            case Keys.Escape:
                e.SuppressKeyPress = true;
                HidePanel();
                break;
            case Keys.Tab:
                e.SuppressKeyPress = true;
                CycleTarget(e.Shift ? -1 : 1);
                break;
        }
    }

    private void CycleTarget(int delta)
    {
        if (_targets.Count <= 1)
        {
            return;
        }

        _targetIndex = (_targetIndex + delta + _targets.Count) % _targets.Count;
        ApplyCue();
    }

    private void Submit()
    {
        string text = _field.Text.Trim();
        if (text.Length == 0)
        {
            System.Media.SystemSounds.Beep.Play();
            return;
        }

        bool accepted = SubmitRequested == null || SubmitRequested(TargetWorkspaceId, text);
        if (!accepted)
        {
            return;
        }

        _field.Text = string.Empty;
        _submitting = true;
        HidePanel();
        _submitting = false;
    }

    private void ApplyCue()
    {
        if (!_field.IsHandleCreated)
        {
            return;
        }

        string target = TargetLabel;
        string cue = string.IsNullOrEmpty(target)
            ? "描述一个任务，按 Enter 直接发起…"
            : $"发到「{target}」：输入任务，按 Enter 发起…";
        SendMessage(_field.Handle, EmSetCueBanner, new IntPtr(1), cue);
    }

    private void ResetHint()
    {
        _hint.ForeColor = Color.FromArgb(0x8A, 0x8F, 0x98);
        _hint.Text = _normalHint;
    }

    private void LayoutChildren()
    {
        int height = ClientSize.Height;
        _glyph.Bounds = new Rectangle(14, 0, 32, height);
        _hint.Bounds = new Rectangle(ClientSize.Width - 190, 0, 176, height);
        _field.Bounds = new Rectangle(52, (height - 26) / 2 + 1, Math.Max(80, ClientSize.Width - 52 - 196), 26);
    }

    private void PositionOnPointerScreen()
    {
        Screen screen = Screen.FromPoint(Cursor.Position);
        Rectangle area = screen.WorkingArea;
        int x = area.Left + (area.Width - Width) / 2;
        int y = area.Top + (int)(area.Height * 0.22);
        Location = new Point(x, y);
    }

    private void ApplyRoundedRegion()
    {
        const int radius = 12;
        using var path = new GraphicsPath();
        Rectangle bounds = new(0, 0, Width, Height);
        int diameter = radius * 2;
        path.AddArc(bounds.X, bounds.Y, diameter, diameter, 180, 90);
        path.AddArc(bounds.Right - diameter, bounds.Y, diameter, diameter, 270, 90);
        path.AddArc(bounds.Right - diameter, bounds.Bottom - diameter, diameter, diameter, 0, 90);
        path.AddArc(bounds.X, bounds.Bottom - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();
        Region?.Dispose();
        Region = new Region(path);
        RedrawBorder();
    }

    private void RedrawBorder()
    {
        SendMessage(Handle, WmSetRedraw, IntPtr.Zero, IntPtr.Zero);
        Invalidate();
        SendMessage(Handle, WmSetRedraw, new IntPtr(1), IntPtr.Zero);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _hintTimer.Dispose();
        }

        base.Dispose(disposing);
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr SendMessage(IntPtr handle, int message, IntPtr wParam, string lParam);

    [DllImport("user32.dll")]
    private static extern IntPtr SendMessage(IntPtr handle, int message, IntPtr wParam, IntPtr lParam);
}

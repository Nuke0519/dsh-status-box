using System.Runtime.InteropServices;
using DSHStatusBox.Core;

namespace DSHStatusBox.App;

/// <summary>
/// Owns the global hot key. Windows delivers <c>WM_HOTKEY</c> to the thread that
/// registered it, so a message-only window is enough — no keyboard hook, no
/// elevated rights, and it keeps working while DSH is closed or minimized.
/// </summary>
internal sealed class HotKeyWindow : NativeWindow, IDisposable
{
    private const int WmHotKey = 0x0312;
    private const int HotKeyId = 0xC0DE;
    private const int VkD = 0x44;
    private const uint ModAlt = 0x0001;
    private const uint ModControl = 0x0002;
    private const uint ModShift = 0x0004;
    private const uint ModNoRepeat = 0x4000;

    private bool _registered;

    public HotKeyWindow()
    {
        CreateHandle(new CreateParams
        {
            Caption = "DSHStatusBoxHotKey",
            Parent = new IntPtr(-3), // HWND_MESSAGE
        });
    }

    /// <summary>Raised when the user presses Ctrl+Alt+Shift+D. Fired on the UI thread.</summary>
    public event Action? Pressed;

    public int RegisterStatus { get; private set; } = -1;

    public int Presses { get; private set; }

    public void Register()
    {
        if (_registered)
        {
            return;
        }

        bool ok = RegisterHotKey(
            Handle,
            HotKeyId,
            ModControl | ModAlt | ModShift | ModNoRepeat,
            VkD);
        RegisterStatus = ok ? 0 : Marshal.GetLastWin32Error();
        _registered = ok;
        Log.Write(ok
            ? "global hotkey registered (Ctrl+Alt+Shift+D)"
            : $"global hotkey registration failed: {RegisterStatus}");
    }

    public void Unregister()
    {
        if (!_registered)
        {
            return;
        }

        UnregisterHotKey(Handle, HotKeyId);
        _registered = false;
    }

    protected override void WndProc(ref Message message)
    {
        if (message.Msg == WmHotKey && message.WParam.ToInt32() == HotKeyId)
        {
            Presses++;
            Pressed?.Invoke();
            return;
        }

        base.WndProc(ref message);
    }

    public void Dispose()
    {
        Unregister();
        DestroyHandle();
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool RegisterHotKey(IntPtr window, int id, uint modifiers, uint virtualKey);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnregisterHotKey(IntPtr window, int id);
}

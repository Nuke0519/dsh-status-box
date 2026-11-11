using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using DSHStatusBox.Core;
using Microsoft.Win32;

namespace DSHStatusBox.App;

/// <summary>
/// Finds, focuses and launches the DeepSeek Harness desktop app on Windows.
/// The companion never assumes an install path: it walks the uninstall registry
/// entries first, then a few conventional locations, and finally an explicit
/// <c>dshExe</c> setting.
/// </summary>
internal static class DshProcess
{
    private const int SwRestore = 9;

    public static bool IsRunning()
    {
        foreach (Process process in Process.GetProcesses())
        {
            try
            {
                if (process.ProcessName.Contains("deepseek", StringComparison.OrdinalIgnoreCase))
                {
                    return true;
                }
            }
            catch
            {
                // processes can vanish between enumeration and inspection
            }
            finally
            {
                process.Dispose();
            }
        }

        return FindMainWindow() != IntPtr.Zero;
    }

    public static bool TryFocus()
    {
        IntPtr window = FindMainWindow();
        if (window == IntPtr.Zero)
        {
            return false;
        }

        if (IsIconic(window))
        {
            ShowWindow(window, SwRestore);
        }

        SetForegroundWindow(window);
        return true;
    }

    public static bool TryLaunch(string? configuredExe = null)
    {
        string? exe = LocateExecutable(configuredExe);
        if (exe == null)
        {
            Log.Write("deepseek harness executable not found");
            return false;
        }

        try
        {
            Process.Start(new ProcessStartInfo(exe) { UseShellExecute = true });
            Log.Write($"launched DeepSeek Harness from {exe}");
            return true;
        }
        catch (Exception error)
        {
            Log.Write($"launch failed: {error.Message}");
            return false;
        }
    }

    /// <summary>Brings DSH forward, starting it when it is not running.</summary>
    public static void Open(string? configuredExe = null)
    {
        if (TryFocus())
        {
            return;
        }

        TryLaunch(configuredExe);
    }

    private static string? LocateExecutable(string? configuredExe)
    {
        if (!string.IsNullOrWhiteSpace(configuredExe) && File.Exists(configuredExe))
        {
            return configuredExe;
        }

        foreach (string candidate in RegistryCandidates())
        {
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }

        string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        string programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        string programFilesX86 = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);

        string[] conventional =
        {
            Path.Combine(localAppData, "Programs", "DeepSeek Harness", "DeepSeek Harness.exe"),
            Path.Combine(localAppData, "DeepSeek Harness", "DeepSeek Harness.exe"),
            Path.Combine(localAppData, "Programs", "deepseek-harness", "DeepSeek Harness.exe"),
            Path.Combine(programFiles, "DeepSeek Harness", "DeepSeek Harness.exe"),
            Path.Combine(programFilesX86, "DeepSeek Harness", "DeepSeek Harness.exe"),
        };

        return conventional.FirstOrDefault(File.Exists);
    }

    private static IEnumerable<string> RegistryCandidates()
    {
        string[] roots =
        {
            @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
            @"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
        };

        foreach (RegistryKey hive in new[] { Registry.CurrentUser, Registry.LocalMachine })
        {
            foreach (string root in roots)
            {
                using RegistryKey? uninstall = hive.OpenSubKey(root);
                if (uninstall == null)
                {
                    continue;
                }

                foreach (string name in uninstall.GetSubKeyNames())
                {
                    using RegistryKey? entry = uninstall.OpenSubKey(name);
                    if (entry == null)
                    {
                        continue;
                    }

                    string display = entry.GetValue("DisplayName") as string ?? string.Empty;
                    if (!display.Contains("DeepSeek Harness", StringComparison.OrdinalIgnoreCase) &&
                        !display.Contains("deepseek-harness", StringComparison.OrdinalIgnoreCase))
                    {
                        continue;
                    }

                    string? icon = entry.GetValue("DisplayIcon") as string;
                    if (!string.IsNullOrWhiteSpace(icon))
                    {
                        string cleaned = icon.Trim().Trim('"');
                        int comma = cleaned.IndexOf(',');
                        if (comma > 0)
                        {
                            cleaned = cleaned[..comma];
                        }

                        if (cleaned.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
                        {
                            yield return cleaned;
                        }
                    }

                    if (entry.GetValue("InstallLocation") is string location && location.Length > 0)
                    {
                        yield return Path.Combine(location, "DeepSeek Harness.exe");
                    }
                }
            }
        }
    }

    private static IntPtr FindMainWindow()
    {
        IntPtr found = IntPtr.Zero;
        EnumWindows((handle, _) =>
        {
            if (!IsWindowVisible(handle))
            {
                return true;
            }

            int length = GetWindowTextLength(handle);
            if (length == 0)
            {
                return true;
            }

            var title = new StringBuilder(length + 1);
            GetWindowText(handle, title, title.Capacity);
            string text = title.ToString();
            if (text.Contains("DeepSeek Harness", StringComparison.OrdinalIgnoreCase))
            {
                found = handle;
                return false;
            }

            return true;
        }, IntPtr.Zero);

        return found;
    }

    private delegate bool EnumWindowsProc(IntPtr handle, IntPtr parameter);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr handle);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr handle, StringBuilder text, int maxCount);

    [DllImport("user32.dll")]
    private static extern int GetWindowTextLength(IntPtr handle);

    [DllImport("user32.dll")]
    private static extern bool IsIconic(IntPtr handle);

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr handle, int command);

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr handle);
}

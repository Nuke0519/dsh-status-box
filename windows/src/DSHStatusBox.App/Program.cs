using System.Threading;
using System.Windows.Forms;
using DSHStatusBox.Core;

namespace DSHStatusBox.App;

internal static class Program
{
    private const string InstanceMutex = "Global\\dsh-status-box-companion";

    [STAThread]
    private static void Main()
    {
        using var mutex = new Mutex(true, InstanceMutex, out bool createdNew);
        if (!createdNew)
        {
            MessageBox.Show(
                "状态盒已经在运行（看看任务栏右下角的托盘图标）。",
                "DSH 状态盒",
                MessageBoxButtons.OK,
                MessageBoxIcon.Information);
            return;
        }

        ApplicationConfiguration.Initialize();
        Log.Write($"companion starting (pid {Environment.ProcessId})");

        try
        {
            Application.Run(new TrayContext());
        }
        catch (Exception error)
        {
            Log.Write($"fatal: {error}");
            MessageBox.Show(
                $"状态盒启动失败：{error.Message}\n\n日志：{AppPaths.LogFile}",
                "DSH 状态盒",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
        }
        finally
        {
            Log.Write("companion exited");
            mutex.ReleaseMutex();
        }
    }
}

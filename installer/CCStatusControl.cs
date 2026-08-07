using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Windows.Forms;

[assembly: AssemblyTitle("CC Status Control")]
[assembly: AssemblyDescription("Control center for CC Status")]
[assembly: AssemblyCompany("Local Codex Tools")]
[assembly: AssemblyProduct("CC Status")]

internal static class CCStatusControl
{
    private static readonly string AppRoot = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
    private static readonly string StatusAppPath = Path.Combine(AppRoot, "CCStatus.ps1");
    private static readonly string DataRoot = Path.Combine(AppRoot, "data");
    private static readonly string ExitRequestPath = Path.Combine(DataRoot, "exit.request");
    private static readonly string ShowRequestPath = Path.Combine(DataRoot, "show.request");
    private static readonly string PidPath = Path.Combine(DataRoot, "status.pid");

    [STAThread]
    private static int Main(string[] args)
    {
        string command = args.Length > 0 ? args[0].ToLowerInvariant() : String.Empty;
        try
        {
            if (command == "/start" || command == "--start")
            {
                StartStatusApp();
                return 0;
            }
            if (command == "/exit" || command == "--exit")
            {
                StopStatusApp();
                return 0;
            }

            return 0;
        }
        catch (Exception exception)
        {
            MessageBox.Show(exception.Message, "CC Status", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }

    private static void StartStatusApp()
    {
        if (!File.Exists(StatusAppPath))
            throw new FileNotFoundException("找不到 CC Status 主程序。", StatusAppPath);

        Directory.CreateDirectory(DataRoot);
        if (IsStatusAppRunning())
        {
            File.WriteAllText(ShowRequestPath, DateTimeOffset.UtcNow.ToString("o"), new UTF8Encoding(false));
            return;
        }
        if (File.Exists(PidPath))
            File.Delete(PidPath);

        string powerShell = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.Windows),
            @"System32\WindowsPowerShell\v1.0\powershell.exe");
        ProcessStartInfo startInfo = new ProcessStartInfo
        {
            FileName = powerShell,
            Arguments = "-NoProfile -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File \"" + StatusAppPath + "\"",
            WorkingDirectory = AppRoot,
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden
        };
        Process.Start(startInfo);
    }

    private static bool IsStatusAppRunning()
    {
        if (!File.Exists(PidPath)) return false;
        int processId;
        if (!Int32.TryParse(File.ReadAllText(PidPath).Trim(), out processId)) return false;
        try
        {
            Process process = Process.GetProcessById(processId);
            return !process.HasExited;
        }
        catch
        {
            return false;
        }
    }

    private static void StopStatusApp()
    {
        Directory.CreateDirectory(DataRoot);
        File.WriteAllText(ExitRequestPath, DateTimeOffset.UtcNow.ToString("o"), new UTF8Encoding(false));
        for (int index = 0; index < 25 && File.Exists(PidPath); index++)
            Thread.Sleep(100);
    }
}

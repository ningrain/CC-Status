using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Windows.Forms;

[assembly: AssemblyTitle("CC Status Control")]
[assembly: AssemblyDescription("Control center for CC Status")]
[assembly: AssemblyCompany("Local Codex Tools")]
[assembly: AssemblyProduct("CC Status")]
[assembly: AssemblyVersion("2.1.0.0")]
[assembly: AssemblyFileVersion("2.1.0.0")]

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

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(CreateControlWindow());
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

    private static Form CreateControlWindow()
    {
        Form form = new Form
        {
            Text = "CC Status 控制中心",
            StartPosition = FormStartPosition.CenterScreen,
            FormBorderStyle = FormBorderStyle.FixedDialog,
            MaximizeBox = false,
            MinimizeBox = false,
            ClientSize = new Size(360, 176),
            Font = new Font("Microsoft YaHei UI", 9F)
        };
        form.Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        Label description = new Label
        {
            AutoSize = false,
            Text = "手动打开或退出 CC Status。",
            Location = new Point(24, 22),
            Size = new Size(312, 32),
            TextAlign = ContentAlignment.MiddleCenter
        };
        Button startButton = new Button
        {
            Text = "打开 CC Status",
            Location = new Point(24, 74),
            Size = new Size(144, 42)
        };
        Button stopButton = new Button
        {
            Text = "退出 CC Status",
            Location = new Point(192, 74),
            Size = new Size(144, 42)
        };
        Button closeButton = new Button
        {
            Text = "关闭",
            Location = new Point(128, 132),
            Size = new Size(104, 30),
            DialogResult = DialogResult.Cancel
        };

        startButton.Click += delegate
        {
            StartStatusApp();
            MessageBox.Show(form, "已发送打开请求。", "CC Status", MessageBoxButtons.OK, MessageBoxIcon.Information);
        };
        stopButton.Click += delegate
        {
            StopStatusApp();
            MessageBox.Show(form, "小组件已退出。", "CC Status", MessageBoxButtons.OK, MessageBoxIcon.Information);
        };
        closeButton.Click += delegate { form.Close(); };

        form.AcceptButton = startButton;
        form.CancelButton = closeButton;
        form.Controls.Add(description);
        form.Controls.Add(startButton);
        form.Controls.Add(stopButton);
        form.Controls.Add(closeButton);
        return form;
    }
}

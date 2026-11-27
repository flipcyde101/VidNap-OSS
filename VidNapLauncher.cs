using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Windows.Forms;
using System.Reflection;
using System.Text.RegularExpressions;
[assembly: AssemblyTitle("VidNap")]
[assembly: AssemblyVersion("0.3.2.0")]
[assembly: AssemblyFileVersion("0.3.2.0")]

internal static class VidNapLauncher
{
    [STAThread]
    private static int Main()
    {
        bool created;
        using (var mutex = new Mutex(true, "Local\\VidNap.Launcher", out created))
        {
        if (!created) { MessageBox.Show("VidNap is already running. Check the taskbar for its window.", "VidNap"); return 0; }
        try { return Run(); }
        catch (Exception ex) { return Fail("VidNap could not start. Check that its files are present and accessible.\n\n" + ex.Message, 3); }
        }
    }
    private static readonly object LogGate = new object();
    private static readonly string LogPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "VidNap", "launcher.log");
    private static void Log(string message)
    {
        if (String.IsNullOrEmpty(message)) return;
        message = Regex.Replace(message, @"https?://[^\s<>""']+", delegate(Match match) {
            string value = match.Value;
            int query = value.IndexOfAny(new char[] { '?', '#' });
            if (query >= 0) value = value.Substring(0, query) + "?[redacted]";
            return Regex.Replace(value, @"(https?://)[^/@\s]+@", "$1[redacted]@");
        }, RegexOptions.IgnoreCase);
        lock (LogGate) {
            try {
                Directory.CreateDirectory(Path.GetDirectoryName(LogPath));
                if (File.Exists(LogPath) && new FileInfo(LogPath).Length > 262144) File.Delete(LogPath);
                File.AppendAllText(LogPath, DateTime.UtcNow.ToString("o") + " " + message.Substring(0, Math.Min(message.Length, 4096)) + Environment.NewLine);
            } catch { /* Logging must not prevent the actionable error dialog. */ }
        }
    }
    private static int Fail(string message, int code)
    {
        Log(message);
        MessageBox.Show(message + "\n\nDiagnostic log (if writable): " + LogPath, "VidNap startup problem", MessageBoxButtons.OK, MessageBoxIcon.Error);
        return code;
    }
    private static int Run()
    {
        string script = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "VidNap.ps1");
        if (!File.Exists(script))
        {
            return Fail("VidNap.ps1 is missing. Restore the complete VidNap folder; the launcher cannot run by itself.\nExpected: " + script, 2);
        }

        var startInfo = new ProcessStartInfo
        {
            FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe"),
            Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -STA -File \"" + script + "\"",
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = AppDomain.CurrentDomain.BaseDirectory,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };

        using (Process process = Process.Start(startInfo))
        {
            if (process == null)
            {
                return Fail("Windows PowerShell did not start. Verify Windows PowerShell is available and retry.", 3);
            }

            process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e) { Log(e.Data); };
            process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e) { Log(e.Data); };
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();
            process.WaitForExit();
            if (process.ExitCode != 0) return Fail("VidNap exited with code " + process.ExitCode + ". Review the diagnostic log for details, then retry. If files are missing, restore the full application folder.", process.ExitCode);
            return process.ExitCode;
        }
    }
}

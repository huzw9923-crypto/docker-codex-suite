using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

[assembly: AssemblyTitle("Docker Codex Suite")]
[assembly: AssemblyDescription("Standalone Docker API menu and launcher for Codex Desktop")]
[assembly: AssemblyCompany("Docker Codex Suite Community")]
[assembly: AssemblyProduct("Docker Codex Suite")]
[assembly: AssemblyCopyright("Copyright (c) 2026 Docker Codex Suite contributors")]
[assembly: AssemblyVersion("1.0.0.1")]
[assembly: AssemblyFileVersion("1.0.0.1")]
[assembly: AssemblyInformationalVersion("1.2.0")]

namespace DockerCodexSuite
{
    internal static class DockerCodexLauncher
    {
        [STAThread]
        private static int Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            try
            {
                string baseDir = AppDomain.CurrentDomain.BaseDirectory;
                string mode = args.Length > 0 ? args[0].ToLowerInvariant() : "--launch";
                if (mode == "--bridge")
                {
                    StartPowerShell(baseDir, "docker-codex-standalone-launch.ps1", "-Action BridgeOnly", true);
                    return 0;
                }
                if (mode == "--bridge-restart")
                {
                    StartPowerShell(baseDir, "docker-codex-standalone-launch.ps1", "-Action RestartBridge", true);
                    return 0;
                }
                if (mode == "--bridge-restart-migrate")
                {
                    StartPowerShell(
                        baseDir,
                        "docker-codex-standalone-launch.ps1",
                        "-Action RestartBridge -AllowSuiteMigration",
                        true);
                    return 0;
                }
                if (mode == "--bridge-stop")
                {
                    StartPowerShell(baseDir, "docker-codex-standalone-launch.ps1", "-Action StopBridge", true);
                    return 0;
                }
                if (mode == "--launch-switcher")
                {
                    StartPowerShell(baseDir, "docker-codex-standalone-launch.ps1", "-Action Launch", true);
                    StartPowerShell(baseDir, "docker-codex-api-switch.ps1", "-Action Gui", false);
                    return 0;
                }
                if (mode == "--switcher")
                {
                    StartPowerShell(baseDir, "docker-codex-api-switch.ps1", "-Action Gui", false);
                    return 0;
                }
                if (mode == "--status")
                {
                    StartPowerShell(baseDir, "docker-codex-api-switch.ps1", "-Action StatusGui", false);
                    return 0;
                }
                if (mode == "--profiles")
                {
                    StartPowerShell(baseDir, "docker-codex-api-switch.ps1", "-Action Gui", false);
                    return 0;
                }

                StartPowerShell(baseDir, "docker-codex-standalone-launch.ps1", "-Action Launch", true);
                return 0;
            }
            catch (Exception exception)
            {
                MessageBox.Show(
                    exception.Message,
                    "Docker Codex Suite",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
                return 1;
            }
        }

        private static void StartPowerShell(string baseDir, string scriptName, string arguments, bool wait)
        {
            string scriptPath = Path.Combine(baseDir, scriptName);
            if (!File.Exists(scriptPath))
            {
                throw new FileNotFoundException("Missing controller script.", scriptPath);
            }

            ProcessStartInfo info = CreatePowerShellInfo(baseDir, scriptPath, arguments);
            Process process = Process.Start(info);
            if (process == null)
            {
                throw new InvalidOperationException("Unable to start PowerShell.");
            }
            if (wait)
            {
                process.WaitForExit();
                if (process.ExitCode != 0)
                {
                    throw new InvalidOperationException("Docker Codex launcher exited with code " + process.ExitCode + ".");
                }
            }
            else
            {
                // Surface immediate startup failures instead of silently returning
                // when the hidden PowerShell host cannot load the GUI script.
                if (process.WaitForExit(500) && process.ExitCode != 0)
                {
                    throw new InvalidOperationException(
                        "Docker Codex API switcher exited with code " + process.ExitCode + ".");
                }
            }
        }

        private static ProcessStartInfo CreatePowerShellInfo(string baseDir, string scriptPath, string arguments)
        {
            ProcessStartInfo info = new ProcessStartInfo();
            info.FileName = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.System),
                "WindowsPowerShell\\v1.0\\powershell.exe");
            info.Arguments = "-NoProfile -Sta -ExecutionPolicy Bypass -File " + Quote(scriptPath) + " " + arguments;
            info.WorkingDirectory = baseDir;
            info.UseShellExecute = false;
            info.CreateNoWindow = true;
            info.WindowStyle = ProcessWindowStyle.Hidden;
            return info;
        }

        private static string Quote(string value)
        {
            return "\"" + value.Replace("\"", "\\\"") + "\"";
        }
    }
}

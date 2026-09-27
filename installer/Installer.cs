using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.IO.Compression;
using System.Net;
using System.Net.Sockets;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;

[assembly: AssemblyTitle("Docker Codex Suite Setup")]
[assembly: AssemblyDescription("Installer for the Docker Codex Suite community tool")]
[assembly: AssemblyCompany("Docker Codex Suite Community")]
[assembly: AssemblyProduct("Docker Codex Suite")]
[assembly: AssemblyCopyright("Copyright (c) 2026 Docker Codex Suite contributors")]
[assembly: AssemblyVersion("1.0.0.1")]
[assembly: AssemblyFileVersion("1.0.0.1")]
[assembly: AssemblyInformationalVersion("1.1.11")]
[assembly: ComVisible(false)]

namespace DockerCodexSuiteInstaller
{
    internal static class Program
    {
        internal const string ProductName = "Docker Codex Suite";
        internal const string ProductVersion = "1.1.11";

        [STAThread]
        private static int Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            bool silent = Array.Exists(args, delegate(string value)
            {
                return string.Equals(value, "--silent", StringComparison.OrdinalIgnoreCase)
                    || string.Equals(value, "--extract-only", StringComparison.OrdinalIgnoreCase);
            });

            try
            {
                CommandLine commandLine = new CommandLine(args);
                string uninstallCompleteDirectory = commandLine.Value("--uninstall-complete", "");
                if (!string.IsNullOrWhiteSpace(uninstallCompleteDirectory))
                {
                    return InstallerEngine.CompleteUninstall(uninstallCompleteDirectory);
                }
                if (commandLine.Has("--uninstall"))
                {
                    return InstallerEngine.Uninstall(commandLine.Has("--silent"));
                }

                string extractOnly = commandLine.Value("--extract-only", "");
                if (!string.IsNullOrWhiteSpace(extractOnly))
                {
                    InstallerEngine.ExtractPayloadOnly(extractOnly);
                    return 0;
                }

                if (commandLine.Has("--silent"))
                {
                    InstallOptions options = InstallOptions.FromCommandLine(commandLine);
                    InstallerEngine engine = new InstallerEngine(delegate(string message)
                    {
                        Console.WriteLine(message);
                    });
                    engine.Install(options);
                    return 0;
                }

                Application.Run(new InstallerForm());
                return 0;
            }
            catch (Exception exception)
            {
                if (silent)
                {
                    string errorPath = Path.Combine(Path.GetTempPath(), "DockerCodexSuite-setup-error.log");
                    File.WriteAllText(errorPath, exception.ToString(), new UTF8Encoding(false));
                    return 1;
                }
                MessageBox.Show(
                    exception.ToString(),
                    ProductName + " Setup",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
                return 1;
            }
        }
    }

    internal sealed class CommandLine
    {
        private readonly Dictionary<string, string> values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

        internal CommandLine(string[] args)
        {
            for (int index = 0; index < args.Length; index++)
            {
                string current = args[index];
                if (!current.StartsWith("--", StringComparison.Ordinal))
                {
                    continue;
                }
                string value = "true";
                if (index + 1 < args.Length && !args[index + 1].StartsWith("--", StringComparison.Ordinal))
                {
                    value = args[++index];
                }
                values[current] = value;
            }
        }

        internal bool Has(string name)
        {
            return values.ContainsKey(name);
        }

        internal string Value(string name, string fallback)
        {
            string value;
            return values.TryGetValue(name, out value) ? value : fallback;
        }
    }

    internal static class UserPaths
    {
        internal static string Profile()
        {
            string fromEnvironment = Environment.GetEnvironmentVariable("USERPROFILE");
            if (!string.IsNullOrWhiteSpace(fromEnvironment))
            {
                return Path.GetFullPath(fromEnvironment);
            }
            return Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        }

        internal static string LocalAppData()
        {
            string fromEnvironment = Environment.GetEnvironmentVariable("LOCALAPPDATA");
            if (!string.IsNullOrWhiteSpace(fromEnvironment))
            {
                return Path.GetFullPath(fromEnvironment);
            }
            return Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        }

        internal static string CodexHome()
        {
            string configured = Environment.ExpandEnvironmentVariables(
                Environment.GetEnvironmentVariable("CODEX_HOME") ?? "").Trim();
            if (configured.Length == 0)
            {
                return Path.Combine(Profile(), ".codex");
            }
            if (!Path.IsPathRooted(configured))
            {
                throw new InvalidOperationException("CODEX_HOME must be an absolute path: " + configured);
            }
            return Path.GetFullPath(configured);
        }

        internal static string Documents()
        {
            string profileDocuments = Path.Combine(Profile(), "Documents");
            if (Directory.Exists(profileDocuments)) return profileDocuments;

            string knownFolder = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);
            return string.IsNullOrWhiteSpace(knownFolder) ? profileDocuments : Path.GetFullPath(knownFolder);
        }
    }

    internal static class InstallRegistration
    {
        private const string UninstallKeyPath =
            "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\DockerCodexSuite";
        private const string RunKeyPath =
            "Software\\Microsoft\\Windows\\CurrentVersion\\Run";
        private const string BridgeRunValueName = "DockerCodexSuiteBridge";

        internal static string ResolvePreferredInstallDirectory()
        {
            string existing = ReadExistingSuiteInstallDirectory();
            if (!string.IsNullOrWhiteSpace(existing)) return existing;

            return Path.Combine(UserPaths.LocalAppData(), "DockerCodexSuite");
        }

        internal static string ReadExistingSuiteInstallDirectory()
        {
            string registered = ReadRegisteredInstallDirectory();
            if (IsSuiteInstallDirectory(registered)) return registered;

            string startup = ReadStartupInstallDirectory();
            if (IsSuiteInstallDirectory(startup)) return startup;

            return "";
        }

        internal static string ResolveUpgradeInstallDirectory(string requestedDirectory)
        {
            return ResolveUpgradeInstallDirectory(requestedDirectory, ReadExistingSuiteInstallDirectory());
        }

        internal static string ResolveUpgradeInstallDirectory(string requestedDirectory, string existingDirectory)
        {
            string existing = NormalizeDirectory(existingDirectory);
            return string.IsNullOrWhiteSpace(existing)
                ? NormalizeDirectory(requestedDirectory)
                : existing;
        }

        internal static bool AreSameDirectory(string left, string right)
        {
            return string.Equals(
                NormalizeDirectory(left),
                NormalizeDirectory(right),
                StringComparison.OrdinalIgnoreCase);
        }

        internal static string ReadRegisteredInstallDirectory()
        {
            try
            {
                using (RegistryKey key = Registry.CurrentUser.OpenSubKey(UninstallKeyPath, false))
                {
                    string value = key == null ? "" : key.GetValue("InstallLocation", "") as string;
                    return NormalizeDirectory(value);
                }
            }
            catch
            {
                return "";
            }
        }

        internal static string ReadStartupInstallDirectory()
        {
            try
            {
                using (RegistryKey key = Registry.CurrentUser.OpenSubKey(RunKeyPath, false))
                {
                    string command = key == null ? "" : key.GetValue(BridgeRunValueName, "") as string;
                    string launcher = ExtractExecutablePath(command);
                    return string.IsNullOrWhiteSpace(launcher)
                        ? ""
                        : NormalizeDirectory(Path.GetDirectoryName(launcher));
                }
            }
            catch
            {
                return "";
            }
        }

        internal static string ExtractExecutablePath(string commandLine)
        {
            string value = (commandLine ?? "").Trim();
            if (value.Length == 0) return "";
            if (value[0] == '"')
            {
                int endQuote = value.IndexOf('"', 1);
                return endQuote > 1 ? value.Substring(1, endQuote - 1) : "";
            }

            int exeIndex = value.IndexOf(".exe", StringComparison.OrdinalIgnoreCase);
            if (exeIndex < 0) return "";
            return value.Substring(0, exeIndex + 4).Trim();
        }

        internal static string ResolvePreferredInstallDirectoryForTesting(
            string defaultDirectory,
            string registeredDirectory,
            string startupCommand,
            string[] existingDirectories)
        {
            string registered = NormalizeDirectory(registeredDirectory);
            if (ContainsDirectory(existingDirectories, registered)) return registered;

            string startupExecutable = ExtractExecutablePath(startupCommand);
            string startup = string.IsNullOrWhiteSpace(startupExecutable)
                ? ""
                : NormalizeDirectory(Path.GetDirectoryName(startupExecutable));
            if (ContainsDirectory(existingDirectories, startup)) return startup;

            return NormalizeDirectory(defaultDirectory);
        }

        internal static bool IsSuiteInstallDirectory(string directory)
        {
            if (string.IsNullOrWhiteSpace(directory) || !Directory.Exists(directory)) return false;
            return File.Exists(Path.Combine(directory, "DockerCodex.exe"))
                || (File.Exists(Path.Combine(directory, "settings.json"))
                    && File.Exists(Path.Combine(directory, "docker-codex-api-switch.ps1")));
        }

        private static bool ContainsDirectory(string[] directories, string candidate)
        {
            if (string.IsNullOrWhiteSpace(candidate) || directories == null) return false;
            foreach (string directory in directories)
            {
                if (string.Equals(NormalizeDirectory(directory), candidate, StringComparison.OrdinalIgnoreCase))
                {
                    return true;
                }
            }
            return false;
        }

        private static string NormalizeDirectory(string value)
        {
            if (string.IsNullOrWhiteSpace(value)) return "";
            try
            {
                return Path.GetFullPath(value.Trim().Trim('"')).TrimEnd(Path.DirectorySeparatorChar);
            }
            catch
            {
                return "";
            }
        }
    }

    internal sealed class EnvironmentDetection
    {
        internal string DockerDir;
        internal string WorkspaceDir;
        internal string Summary;
        internal bool FoundExisting;
        internal bool DockerCliFound;
        internal bool DockerDaemonAvailable;
        internal bool ExistingContainerFound;
        internal string ContainerName;
        internal string ContainerStatus;
        internal string ServiceName;
        internal string ProjectName;
        internal bool CodexInstalled;
        internal int SshPort;
        internal string ApiEnvKey;
        internal int ContainerCount;
        internal int CodexContainerCount;
        internal bool ContainerScanIncomplete;
        internal bool ContainerSelectionBlocked;
        internal string[] ContainerNames = new string[0];
        internal string[] ComposeProjectNames = new string[0];
        internal string[] CodexContainerNames = new string[0];
    }

    internal sealed class ContainerDetection
    {
        internal string ComposeDir;
        internal string WorkspaceDir;
        internal string ContainerName;
        internal string Status;
        internal string ServiceName;
        internal string ProjectName;
        internal bool CodexDeclared;
        internal bool CodexInstalled;
        internal int SshPort;
    }

    internal sealed class ContainerScanResult
    {
        internal ContainerDetection Selected;
        internal int ContainerCount;
        internal bool ScanIncomplete;
        internal bool SelectionBlocked;
        internal string[] ContainerNames = new string[0];
        internal string[] ComposeProjectNames = new string[0];
        internal string[] CodexContainerNames = new string[0];
    }

    internal static class PortUtility
    {
        internal static bool IsAvailable(int port)
        {
            TcpListener listener = null;
            try
            {
                listener = new TcpListener(IPAddress.Loopback, port);
                listener.Start();
                return true;
            }
            catch (SocketException)
            {
                return false;
            }
            finally
            {
                if (listener != null) listener.Stop();
            }
        }

        internal static int FindAvailable(int preferredPort)
        {
            int start = Math.Max(1024, Math.Min(preferredPort, 65535));
            for (int port = start; port <= Math.Min(start + 200, 65535); port++)
            {
                if (IsAvailable(port)) return port;
            }
            throw new InvalidOperationException("No free local TCP port was found near " + preferredPort + ".");
        }
    }

    internal static class EnvironmentDetector
    {
        private static readonly object CacheLock = new object();
        private static EnvironmentDetection cached;

        internal static EnvironmentDetection Detect(bool refresh)
        {
            lock (CacheLock)
            {
                if (!refresh && cached != null) return cached;

                string settingsPath = Path.Combine(
                    InstallRegistration.ResolvePreferredInstallDirectory(),
                    "settings.json");
                cached = DetectCore(
                    settingsPath,
                    Environment.GetEnvironmentVariable("DOCKER_CODEX_COMPOSE_DIR"),
                    true,
                    null);
                return cached;
            }
        }

        internal static EnvironmentDetection DetectForTesting(
            string settingsPath,
            string environmentComposeDir,
            string[] scanCandidates)
        {
            return DetectCore(settingsPath, environmentComposeDir, false, scanCandidates);
        }

        internal static ContainerDetection ParseDockerMetadataForTesting(string metadata, string containerName)
        {
            return ParseDockerMetadata(metadata, containerName);
        }

        internal static string RunDockerInspectForTesting(string executable, string containerName, out bool timedOut)
        {
            return RunDockerInspect(executable, containerName, out timedOut);
        }

        private static EnvironmentDetection DetectCore(
            string settingsPath,
            string environmentComposeDir,
            bool inspectDocker,
            string[] scanCandidates)
        {
            string dockerDir = "";
            string workspaceDir = "";
            List<string> sources = new List<string>();
            string dockerExecutable = inspectDocker ? FindDockerExecutable() : "";
            bool dockerCliFound = !string.IsNullOrEmpty(dockerExecutable);
            bool dockerDaemonAvailable = dockerCliFound && ProbeDockerDaemon(dockerExecutable);
            string preferredContainerName = ReadPreferredContainerName(settingsPath);
            ContainerScanResult containerScan = dockerDaemonAvailable
                ? ScanDockerContainers(dockerExecutable, preferredContainerName)
                : new ContainerScanResult();
            ContainerDetection existingContainer = containerScan.Selected;

            string settingsDocker;
            string settingsWorkspace;
            if (TryReadSettings(settingsPath, out settingsDocker, out settingsWorkspace))
            {
                dockerDir = NormalizePath(settingsDocker, Path.GetDirectoryName(settingsPath));
                workspaceDir = NormalizePath(settingsWorkspace, Path.GetDirectoryName(settingsPath));
                if (!Directory.Exists(dockerDir)) dockerDir = "";
                if (!Directory.Exists(workspaceDir)) workspaceDir = "";
                if (!string.IsNullOrEmpty(dockerDir) || !string.IsNullOrEmpty(workspaceDir))
                {
                    AddSource(sources, "上次安装设置");
                }
            }

            FillWorkspaceFromCompose(ref workspaceDir, dockerDir);

            if (string.IsNullOrEmpty(dockerDir))
            {
                string fromEnvironment = NormalizePath(environmentComposeDir, UserPaths.Profile());
                if (!string.IsNullOrEmpty(fromEnvironment))
                {
                    dockerDir = fromEnvironment;
                    AddSource(sources, "环境变量 DOCKER_CODEX_COMPOSE_DIR");
                }
            }

            FillWorkspaceFromCompose(ref workspaceDir, dockerDir);

            if (existingContainer != null && (string.IsNullOrEmpty(dockerDir) || string.IsNullOrEmpty(workspaceDir)))
            {
                bool usedContainer = false;
                if (string.IsNullOrEmpty(dockerDir) && !string.IsNullOrEmpty(existingContainer.ComposeDir))
                {
                    dockerDir = existingContainer.ComposeDir;
                    usedContainer = true;
                }
                if (string.IsNullOrEmpty(workspaceDir) && !string.IsNullOrEmpty(existingContainer.WorkspaceDir))
                {
                    workspaceDir = existingContainer.WorkspaceDir;
                    usedContainer = true;
                }
                if (usedContainer)
                {
                    AddSource(sources, "Docker 容器 " + existingContainer.ContainerName);
                }
            }

            FillWorkspaceFromCompose(ref workspaceDir, dockerDir);

            if (string.IsNullOrEmpty(dockerDir))
            {
                string[] candidates = scanCandidates ?? FindCommonComposeDirectories();
                foreach (string candidate in candidates)
                {
                    string normalized = NormalizePath(candidate, UserPaths.Profile());
                    if (!string.IsNullOrEmpty(normalized) && FindComposeFile(normalized) != "")
                    {
                        dockerDir = normalized;
                        AddSource(sources, "现有 compose");
                        break;
                    }
                }
            }

            FillWorkspaceFromCompose(ref workspaceDir, dockerDir);

            if (string.IsNullOrEmpty(dockerDir))
            {
                dockerDir = Path.Combine(UserPaths.Profile(), "DockerCodex");
            }
            if (string.IsNullOrEmpty(workspaceDir))
            {
                workspaceDir = UserPaths.Documents();
            }

            EnvironmentDetection result = new EnvironmentDetection();
            result.DockerDir = Path.GetFullPath(dockerDir);
            result.WorkspaceDir = Path.GetFullPath(workspaceDir);
            result.DockerCliFound = dockerCliFound;
            result.DockerDaemonAvailable = dockerDaemonAvailable;
            result.ExistingContainerFound = existingContainer != null;
            result.ContainerName = existingContainer == null ? "" : existingContainer.ContainerName;
            result.ContainerStatus = existingContainer == null ? "" : existingContainer.Status;
            result.ServiceName = existingContainer == null ? "" : existingContainer.ServiceName;
            result.ProjectName = existingContainer == null ? "" : existingContainer.ProjectName;
            result.CodexInstalled = existingContainer != null && existingContainer.CodexInstalled;
            result.SshPort = existingContainer == null ? 0 : existingContainer.SshPort;
            result.ApiEnvKey = ReadApiEnvKey(result.DockerDir);
            result.ContainerCount = containerScan.ContainerCount;
            result.CodexContainerCount = containerScan.CodexContainerNames.Length;
            result.ContainerScanIncomplete = containerScan.ScanIncomplete;
            result.ContainerSelectionBlocked = containerScan.SelectionBlocked
                || (existingContainer != null && existingContainer.SshPort <= 0);
            result.ContainerNames = containerScan.ContainerNames;
            result.ComposeProjectNames = containerScan.ComposeProjectNames;
            result.CodexContainerNames = containerScan.CodexContainerNames;
            result.FoundExisting = sources.Count > 0 || existingContainer != null;

            string pathSummary = sources.Count > 0
                ? "目录：" + string.Join(" + ", sources.ToArray())
                : "目录：未发现已有环境，使用默认路径";
            string runtimeSummary;
            if (!dockerCliFound)
            {
                runtimeSummary = "Docker：未安装";
            }
            else if (!dockerDaemonAvailable)
            {
                runtimeSummary = "Docker：已安装但 daemon 未运行";
            }
            else if (result.ContainerScanIncomplete)
            {
                runtimeSummary = "Docker：容器扫描未完成；为避免控制错误容器，安装已阻止，请重新检测";
            }
            else if (result.ContainerSelectionBlocked && result.CodexContainerCount > 1)
            {
                runtimeSummary = "Docker：发现多个 Codex 容器（"
                    + string.Join("、", result.CodexContainerNames)
                    + "）；无法安全自动选择，安装已阻止";
            }
            else if (result.ContainerSelectionBlocked && existingContainer != null)
            {
                runtimeSummary = "Docker：确认容器 " + existingContainer.ContainerName
                    + " 已安装 Codex，但未发现可用 SSH 端口；不会新建或控制其他容器";
            }
            else if (existingContainer == null)
            {
                runtimeSummary = "Docker：已检查 " + result.ContainerCount
                    + " 个容器，未发现 Codex CLI；安装时将新建独立容器";
            }
            else
            {
                runtimeSummary = "Docker：已检查 " + result.ContainerCount + " 个容器；仅复用 Codex 容器 "
                    + existingContainer.ContainerName
                    + "（" + existingContainer.Status + "）；Codex CLI："
                    + (existingContainer.CodexInstalled ? "已安装" : "未确认")
                    + (existingContainer.SshPort > 0 ? "；SSH：" + existingContainer.SshPort : "");
            }
            result.Summary = pathSummary + Environment.NewLine + runtimeSummary;
            return result;
        }

        private static void FillWorkspaceFromCompose(ref string workspaceDir, string dockerDir)
        {
            if (!string.IsNullOrEmpty(workspaceDir) || string.IsNullOrEmpty(dockerDir)) return;
            workspaceDir = ReadWorkspaceFromCompose(dockerDir);
        }

        private static bool TryReadSettings(string settingsPath, out string dockerDir, out string workspaceDir)
        {
            dockerDir = "";
            workspaceDir = "";
            if (string.IsNullOrWhiteSpace(settingsPath) || !File.Exists(settingsPath)) return false;

            try
            {
                JavaScriptSerializer serializer = new JavaScriptSerializer();
                Dictionary<string, object> settings = serializer.Deserialize<Dictionary<string, object>>(
                    File.ReadAllText(settingsPath, Encoding.UTF8));
                dockerDir = DictionaryString(settings, "composeDir");
                workspaceDir = DictionaryString(settings, "workspaceDir");
                return !string.IsNullOrWhiteSpace(dockerDir) || !string.IsNullOrWhiteSpace(workspaceDir);
            }
            catch
            {
                return false;
            }
        }

        private static string ReadPreferredContainerName(string settingsPath)
        {
            if (string.IsNullOrWhiteSpace(settingsPath) || !File.Exists(settingsPath)) return "";
            try
            {
                JavaScriptSerializer serializer = new JavaScriptSerializer();
                Dictionary<string, object> settings = serializer.Deserialize<Dictionary<string, object>>(
                    File.ReadAllText(settingsPath, Encoding.UTF8));
                string name = DictionaryString(settings, "containerName");
                return IsSafeContainerName(name) ? name : "";
            }
            catch
            {
                return "";
            }
        }

        internal static bool DockerDaemonIsAvailable()
        {
            string docker = FindDockerExecutable();
            return !string.IsNullOrEmpty(docker) && ProbeDockerDaemon(docker);
        }

        internal static string DockerExecutableForInstall()
        {
            return FindDockerExecutable();
        }

        internal static ContainerDetection InspectContainerForInstall(string containerName)
        {
            if (!IsSafeContainerName(containerName)) return null;
            string docker = FindDockerExecutable();
            if (string.IsNullOrEmpty(docker) || !ProbeDockerDaemon(docker)) return null;

            bool timedOut;
            string metadata = RunDockerInspect(docker, containerName, out timedOut);
            if (timedOut) return null;
            ContainerDetection result = ParseDockerMetadata(metadata, containerName);
            if (result != null)
            {
                bool probeIncomplete;
                result.CodexInstalled = ProbeCodexInstalled(docker, result, out probeIncomplete);
                if (probeIncomplete) return null;
            }
            return result;
        }

        internal static ContainerScanResult ScanContainersForTesting(string docker, string preferredContainerName)
        {
            return ScanDockerContainers(docker, preferredContainerName);
        }

        internal static ContainerScanResult ScanContainersForInstall()
        {
            string docker = FindDockerExecutable();
            if (string.IsNullOrEmpty(docker) || !ProbeDockerDaemon(docker))
            {
                ContainerScanResult unavailable = new ContainerScanResult();
                unavailable.ScanIncomplete = true;
                unavailable.SelectionBlocked = true;
                return unavailable;
            }
            return ScanDockerContainers(docker, "");
        }

        private static ContainerScanResult ScanDockerContainers(string docker, string preferredContainerName)
        {
            ContainerScanResult scan = new ContainerScanResult();
            List<string> containerNames = new List<string>();
            List<string> projectNames = new List<string>();
            List<string> codexNames = new List<string>();
            List<ContainerDetection> codexContainers = new List<ContainerDetection>();
            int listExitCode;
            bool listTimedOut;
            string listOutput = RunDockerCommand(
                docker,
                "ps -a --format \"{{.Names}}\"",
                8000,
                out listExitCode,
                out listTimedOut);
            if (listTimedOut || listExitCode != 0)
            {
                scan.ScanIncomplete = true;
                scan.SelectionBlocked = true;
                return scan;
            }

            foreach (string line in listOutput.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries))
            {
                string name = line.Trim();
                if (!IsSafeContainerName(name) || ContainsIgnoreCase(containerNames, name)) continue;
                containerNames.Add(name);

                bool timedOut;
                string metadata = RunDockerInspect(docker, name, out timedOut);
                if (timedOut)
                {
                    scan.ScanIncomplete = true;
                    continue;
                }

                ContainerDetection result = ParseDockerMetadata(metadata, name);
                if (result == null)
                {
                    scan.ScanIncomplete = true;
                    continue;
                }
                if (!string.IsNullOrWhiteSpace(result.ProjectName)
                    && !ContainsIgnoreCase(projectNames, result.ProjectName))
                {
                    projectNames.Add(result.ProjectName);
                }

                bool probeIncomplete;
                result.CodexInstalled = ProbeCodexInstalled(docker, result, out probeIncomplete);
                if (probeIncomplete)
                {
                    scan.ScanIncomplete = true;
                    continue;
                }
                if (result.CodexInstalled)
                {
                    codexNames.Add(result.ContainerName);
                    codexContainers.Add(result);
                }
            }

            if (codexContainers.Count == 1)
            {
                scan.Selected = codexContainers[0];
            }
            else if (codexContainers.Count > 1)
            {
                foreach (ContainerDetection candidate in codexContainers)
                {
                    if (string.Equals(candidate.ContainerName, preferredContainerName, StringComparison.OrdinalIgnoreCase))
                    {
                        scan.Selected = candidate;
                        break;
                    }
                }
                if (scan.Selected == null) scan.SelectionBlocked = true;
            }

            if (scan.ScanIncomplete) scan.SelectionBlocked = true;
            scan.ContainerCount = containerNames.Count;
            scan.ContainerNames = containerNames.ToArray();
            scan.ComposeProjectNames = projectNames.ToArray();
            scan.CodexContainerNames = codexNames.ToArray();
            return scan;
        }

        private static string RunDockerInspect(string docker, string containerName, out bool timedOut)
        {
            int exitCode;
            return RunDockerCommand(
                docker,
                "inspect --format \"{{json .Config.Labels}}|||{{json .Mounts}}|||{{.State.Status}}|||{{json .NetworkSettings.Ports}}|||{{json .HostConfig.PortBindings}}\" " + containerName,
                8000,
                out exitCode,
                out timedOut);
        }

        private static bool ProbeDockerDaemon(string docker)
        {
            int exitCode;
            bool timedOut;
            string output = RunDockerCommand(
                docker,
                "version --format \"{{.Server.Version}}\"",
                5000,
                out exitCode,
                out timedOut);
            return !timedOut && exitCode == 0 && !string.IsNullOrWhiteSpace(output);
        }

        private static bool ProbeCodexInstalled(
            string docker,
            ContainerDetection container,
            out bool probeIncomplete)
        {
            probeIncomplete = false;
            if (container.CodexDeclared) return true;

            if (!string.Equals(container.Status, "running", StringComparison.OrdinalIgnoreCase))
            {
                return ProbeCodexBinary(docker, container.ContainerName, out probeIncomplete);
            }

            int exitCode;
            bool timedOut;
            RunDockerCommand(
                docker,
                "exec " + container.ContainerName + " sh -lc \"command -v codex >/dev/null 2>&1\"",
                8000,
                out exitCode,
                out timedOut);
            if (timedOut)
            {
                probeIncomplete = true;
                return false;
            }
            if (exitCode == 0) return true;
            if (exitCode == 1) return false;
            return ProbeCodexBinary(docker, container.ContainerName, out probeIncomplete);
        }

        private static bool ProbeCodexBinary(string docker, string containerName, out bool probeIncomplete)
        {
            probeIncomplete = false;
            string probeRoot = Path.Combine(Path.GetTempPath(), "DockerCodexSuite-probe-" + Guid.NewGuid().ToString("N"));
            string[] paths =
            {
                "/usr/local/bin/codex",
                "/home/codex/.local/bin/codex",
                "/opt/codex/bin/codex"
            };
            try
            {
                Directory.CreateDirectory(probeRoot);
                for (int index = 0; index < paths.Length; index++)
                {
                    string target = Path.Combine(probeRoot, "codex-" + index);
                    int exitCode;
                    bool timedOut;
                    RunDockerCommand(
                        docker,
                        "cp " + containerName + ":" + paths[index] + " " + QuoteProcessArgument(target),
                        5000,
                        out exitCode,
                        out timedOut);
                    if (timedOut || exitCode < 0)
                    {
                        probeIncomplete = true;
                        return false;
                    }
                    if (exitCode == 0) return true;
                }
                return false;
            }
            finally
            {
                try
                {
                    if (Directory.Exists(probeRoot)) Directory.Delete(probeRoot, true);
                }
                catch
                {
                }
            }
        }

        private static bool IsSafeContainerName(string name)
        {
            return !string.IsNullOrWhiteSpace(name)
                && Regex.IsMatch(name, "^[A-Za-z0-9][A-Za-z0-9_.-]*$");
        }

        private static bool ContainsIgnoreCase(List<string> values, string candidate)
        {
            foreach (string value in values)
            {
                if (string.Equals(value, candidate, StringComparison.OrdinalIgnoreCase)) return true;
            }
            return false;
        }

        private static string QuoteProcessArgument(string value)
        {
            return "\"" + (value ?? "").Replace("\"", "\\\"") + "\"";
        }

        private static string RunDockerCommand(
            string docker,
            string arguments,
            int timeoutMilliseconds,
            out int exitCode,
            out bool timedOut)
        {
            exitCode = -1;
            timedOut = false;
            StringBuilder output = new StringBuilder();
            object outputLock = new object();
            try
            {
                ProcessStartInfo info = new ProcessStartInfo();
                info.FileName = docker;
                info.Arguments = arguments;
                info.UseShellExecute = false;
                info.CreateNoWindow = true;
                info.RedirectStandardOutput = true;
                info.RedirectStandardError = true;
                info.StandardOutputEncoding = Encoding.UTF8;
                info.StandardErrorEncoding = Encoding.UTF8;

                using (Process process = new Process())
                {
                    process.StartInfo = info;
                    process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs eventArgs)
                    {
                        if (eventArgs.Data == null) return;
                        lock (outputLock) output.AppendLine(eventArgs.Data);
                    };
                    process.ErrorDataReceived += delegate { };
                    process.Start();
                    process.BeginOutputReadLine();
                    process.BeginErrorReadLine();
                    if (!process.WaitForExit(timeoutMilliseconds))
                    {
                        timedOut = true;
                        try { process.Kill(); }
                        catch { }
                        return "";
                    }
                    process.WaitForExit();
                    exitCode = process.ExitCode;
                }
            }
            catch
            {
                return "";
            }

            lock (outputLock) return output.ToString();
        }

        private static ContainerDetection ParseDockerMetadata(string metadata, string containerName)
        {
            if (string.IsNullOrWhiteSpace(metadata)) return null;
            try
            {
                string[] sections = metadata.Trim().Split(new[] { "|||" }, StringSplitOptions.None);
                if (sections.Length < 2) return null;

                string labelsJson = sections[0].Trim();
                string mountsJson = sections[1].Trim();
                string status = sections.Length > 2 ? sections[2].Trim() : "";
                string portsJson = sections.Length > 3 ? sections[3].Trim() : "{}";
                string hostPortBindingsJson = sections.Length > 4 ? sections[4].Trim() : "{}";
                JavaScriptSerializer serializer = new JavaScriptSerializer();
                Dictionary<string, object> labels = serializer.DeserializeObject(labelsJson) as Dictionary<string, object>;
                object[] mounts = serializer.DeserializeObject(mountsJson) as object[];
                Dictionary<string, object> ports = serializer.DeserializeObject(portsJson) as Dictionary<string, object>;
                Dictionary<string, object> hostPortBindings = serializer.DeserializeObject(hostPortBindingsJson) as Dictionary<string, object>;

                ContainerDetection result = new ContainerDetection();
                result.ContainerName = containerName;
                result.Status = status;
                result.ServiceName = DictionaryString(labels, "com.docker.compose.service");
                result.ProjectName = DictionaryString(labels, "com.docker.compose.project");
                result.CodexDeclared = string.Equals(
                    DictionaryString(labels, "io.docker-codex-suite.codex-cli"),
                    "true",
                    StringComparison.OrdinalIgnoreCase);
                result.SshPort = ReadSshPort(ports);
                if (result.SshPort == 0)
                {
                    result.SshPort = ReadSshPort(hostPortBindings);
                }
                result.ComposeDir = NormalizePath(
                    DictionaryString(labels, "com.docker.compose.project.working_dir"),
                    UserPaths.Profile());

                if (mounts != null)
                {
                    foreach (object mountValue in mounts)
                    {
                        Dictionary<string, object> mount = mountValue as Dictionary<string, object>;
                        if (mount == null) continue;

                        string destination = DictionaryString(mount, "Destination").Replace('\\', '/').TrimEnd('/');
                        string source = NormalizePath(DictionaryString(mount, "Source"), UserPaths.Profile());
                        if (destination.Equals("/workspace/Documents", StringComparison.OrdinalIgnoreCase))
                        {
                            result.WorkspaceDir = source;
                        }
                        else if (string.IsNullOrEmpty(result.ComposeDir)
                            && destination.Equals("/home/codex/.codex", StringComparison.OrdinalIgnoreCase)
                            && !string.IsNullOrEmpty(source))
                        {
                            DirectoryInfo parent = Directory.GetParent(source);
                            if (parent != null && FindComposeFile(parent.FullName) != "")
                            {
                                result.ComposeDir = parent.FullName;
                            }
                        }
                    }
                }

                return string.IsNullOrEmpty(result.ComposeDir)
                    && string.IsNullOrEmpty(result.WorkspaceDir)
                    && string.IsNullOrEmpty(result.Status)
                    ? null
                    : result;
            }
            catch
            {
                return null;
            }
        }

        private static int ReadSshPort(Dictionary<string, object> ports)
        {
            if (ports == null) return 0;
            object value;
            object[] bindings = ports.TryGetValue("22/tcp", out value) ? value as object[] : null;
            if (bindings == null) return 0;

            foreach (object bindingValue in bindings)
            {
                Dictionary<string, object> binding = bindingValue as Dictionary<string, object>;
                int port;
                if (binding != null && int.TryParse(DictionaryString(binding, "HostPort"), out port))
                {
                    return port;
                }
            }
            return 0;
        }

        private static string ReadApiEnvKey(string dockerDir)
        {
            if (string.IsNullOrWhiteSpace(dockerDir)) return "DOCKER_CODEX_API_KEY";
            string[] configPaths =
            {
                Path.Combine(dockerDir, "codex-home", "config.local-mode.toml"),
                Path.Combine(dockerDir, "codex-home", "config.toml")
            };
            foreach (string path in configPaths)
            {
                try
                {
                    if (!File.Exists(path)) continue;
                    Match match = Regex.Match(
                        File.ReadAllText(path, Encoding.UTF8),
                        "(?m)^\\s*env_key\\s*=\\s*\"([^\"]+)\"\\s*$",
                        RegexOptions.IgnoreCase);
                    if (match.Success) return match.Groups[1].Value;
                }
                catch
                {
                }
            }
            return "DOCKER_CODEX_API_KEY";
        }

        private static string[] FindCommonComposeDirectories()
        {
            List<string> preferred = new List<string>();
            List<string> driveCandidates = new List<string>();
            HashSet<string> seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

            AddComposeCandidate(preferred, seen, Path.Combine(UserPaths.Profile(), "DockerCodex"));
            AddComposeCandidate(preferred, seen, Path.Combine(UserPaths.Profile(), "Documents", "DockerCodex"));

            try
            {
                foreach (DriveInfo drive in DriveInfo.GetDrives())
                {
                    if (drive.DriveType != DriveType.Fixed || !drive.IsReady) continue;
                    string dockerRoot = Path.Combine(drive.RootDirectory.FullName, "docker");
                    if (!Directory.Exists(dockerRoot)) continue;

                    int checkedDirectories = 0;
                    foreach (string directory in Directory.GetDirectories(dockerRoot))
                    {
                        if (++checkedDirectories > 128) break;
                        string name = Path.GetFileName(directory) ?? "";
                        if (name.IndexOf("codex", StringComparison.OrdinalIgnoreCase) < 0) continue;
                        AddComposeCandidate(driveCandidates, seen, directory);
                    }
                }
            }
            catch
            {
            }

            driveCandidates.Sort(delegate(string left, string right)
            {
                bool leftHasState = Directory.Exists(Path.Combine(left, "codex-home"));
                bool rightHasState = Directory.Exists(Path.Combine(right, "codex-home"));
                if (leftHasState != rightHasState) return leftHasState ? -1 : 1;
                return string.Compare(left, right, StringComparison.OrdinalIgnoreCase);
            });
            preferred.AddRange(driveCandidates);
            return preferred.ToArray();
        }

        private static void AddComposeCandidate(List<string> candidates, HashSet<string> seen, string path)
        {
            string normalized = NormalizePath(path, UserPaths.Profile());
            if (string.IsNullOrEmpty(normalized) || FindComposeFile(normalized) == "" || !seen.Add(normalized)) return;
            candidates.Add(normalized);
        }

        private static string ReadWorkspaceFromCompose(string dockerDir)
        {
            string composePath = FindComposeFile(dockerDir);
            if (composePath == "") return "";

            try
            {
                string pendingSource = "";
                foreach (string rawLine in File.ReadAllLines(composePath, Encoding.UTF8))
                {
                    string line = rawLine.Trim();
                    if (line.StartsWith("- type:", StringComparison.OrdinalIgnoreCase))
                    {
                        pendingSource = "";
                    }
                    else if (line.StartsWith("source:", StringComparison.OrdinalIgnoreCase))
                    {
                        pendingSource = YamlScalar(line.Substring("source:".Length));
                    }
                    else if (line.StartsWith("target:", StringComparison.OrdinalIgnoreCase))
                    {
                        string target = YamlScalar(line.Substring("target:".Length)).Replace('\\', '/').TrimEnd('/');
                        if (target.Equals("/workspace/Documents", StringComparison.OrdinalIgnoreCase))
                        {
                            return NormalizePath(pendingSource, dockerDir);
                        }
                        pendingSource = "";
                    }
                }
            }
            catch
            {
            }
            return "";
        }

        private static string FindComposeFile(string directory)
        {
            if (string.IsNullOrWhiteSpace(directory) || !Directory.Exists(directory)) return "";
            string[] names = { "compose.yml", "compose.yaml", "docker-compose.yml", "docker-compose.yaml" };
            foreach (string name in names)
            {
                string candidate = Path.Combine(directory, name);
                if (File.Exists(candidate)) return candidate;
            }
            return "";
        }

        private static string YamlScalar(string value)
        {
            string result = (value ?? "").Trim();
            if (result.Length >= 2 && ((result[0] == '"' && result[result.Length - 1] == '"')
                || (result[0] == '\'' && result[result.Length - 1] == '\'')))
            {
                char quote = result[0];
                result = result.Substring(1, result.Length - 2);
                if (quote == '"') result = result.Replace("\\\"", "\"").Replace("\\\\", "\\");
                return result;
            }

            int comment = result.IndexOf(" #", StringComparison.Ordinal);
            return comment >= 0 ? result.Substring(0, comment).TrimEnd() : result;
        }

        private static string NormalizePath(string value, string baseDirectory)
        {
            if (string.IsNullOrWhiteSpace(value)) return "";
            try
            {
                string expanded = Environment.ExpandEnvironmentVariables(value.Trim().Trim('"'));
                if (expanded.IndexOf("${", StringComparison.Ordinal) >= 0) return "";
                if (!Path.IsPathRooted(expanded)) expanded = Path.Combine(baseDirectory, expanded);
                return Path.GetFullPath(expanded);
            }
            catch
            {
                return "";
            }
        }

        private static string DictionaryString(Dictionary<string, object> dictionary, string key)
        {
            if (dictionary == null) return "";
            object value;
            return dictionary.TryGetValue(key, out value) && value != null ? Convert.ToString(value) : "";
        }

        private static string FindDockerExecutable()
        {
            string overridePath = Environment.GetEnvironmentVariable("DOCKER_CODEX_DOCKER_EXE");
            if (!string.IsNullOrWhiteSpace(overridePath) && File.Exists(overridePath))
            {
                return Path.GetFullPath(overridePath);
            }

            string programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
            string bundled = Path.Combine(programFiles, "Docker", "Docker", "resources", "bin", "docker.exe");
            if (File.Exists(bundled)) return bundled;

            string path = Environment.GetEnvironmentVariable("PATH") ?? "";
            foreach (string directory in path.Split(Path.PathSeparator))
            {
                try
                {
                    string candidate = Path.Combine(directory.Trim(), "docker.exe");
                    if (File.Exists(candidate)) return candidate;
                }
                catch
                {
                }
            }
            return "";
        }

        private static void AddSource(List<string> sources, string source)
        {
            if (!sources.Contains(source)) sources.Add(source);
        }
    }

    internal sealed class InstallOptions
    {
        internal string InstallDir;
        internal string DockerDir;
        internal string WorkspaceDir;
        internal string SshKeyPath;
        internal int SshPort;
        internal bool BuildDocker;
        internal bool LaunchAfter;
        internal bool SkipSsh;
        internal bool SkipShortcuts;
        internal bool SkipRegistry;
        internal bool TestMode;
        internal string DetectionSummary;
        internal string ExistingInstallDir;
        internal bool DetectedExisting;
        internal bool DockerCliFound;
        internal bool DockerDaemonAvailable;
        internal bool ExistingContainerFound;
        internal string ExistingContainerName;
        internal string ExistingContainerStatus;
        internal bool ExistingCodexInstalled;
        internal bool StopExistingContainer;
        internal bool ReuseExistingContainer;
        internal bool RestartExistingContainerAfterInstall;
        internal bool ContainerSelectionBlocked;
        internal bool ContainerScanIncomplete;
        internal int ExistingCodexContainerCount;
        internal string ContainerName;
        internal string ServiceName;
        internal string ProjectName;
        internal string ApiEnvKey;
        internal string RemoteHostId;

        internal static InstallOptions Defaults()
        {
            return Defaults(false);
        }

        internal static InstallOptions Defaults(bool refreshDetection)
        {
            string userProfile = UserPaths.Profile();
            EnvironmentDetection detection = EnvironmentDetector.Detect(refreshDetection);
            InstallOptions options = FromDetection(detection);
            if (options.ReuseExistingContainer)
            {
                string existingIdentity = FindExistingSshIdentity(userProfile, detection.DockerDir, options.SshPort);
                if (!string.IsNullOrWhiteSpace(existingIdentity)) options.SshKeyPath = existingIdentity;
            }
            return options;
        }

        internal static InstallOptions FromDetection(EnvironmentDetection detection)
        {
            if (detection == null) throw new ArgumentNullException("detection");
            string userProfile = UserPaths.Profile();
            InstallOptions options = new InstallOptions();
            options.ExistingInstallDir = InstallRegistration.ReadExistingSuiteInstallDirectory();
            options.InstallDir = string.IsNullOrWhiteSpace(options.ExistingInstallDir)
                ? InstallRegistration.ResolvePreferredInstallDirectory()
                : options.ExistingInstallDir;
            options.DockerDir = detection.DockerDir;
            options.WorkspaceDir = detection.WorkspaceDir;
            options.SshKeyPath = Path.Combine(userProfile, ".ssh", "docker_codex_ed25519");
            options.SshPort = detection.SshPort > 0 ? detection.SshPort : 2223;
            options.ContainerSelectionBlocked = detection.ContainerSelectionBlocked;
            options.ContainerScanIncomplete = detection.ContainerScanIncomplete;
            options.ExistingCodexContainerCount = detection.CodexContainerCount;
            options.ReuseExistingContainer = detection.ExistingContainerFound
                && detection.CodexInstalled
                && !options.ContainerSelectionBlocked;
            options.BuildDocker = detection.DockerDaemonAvailable
                && !options.ReuseExistingContainer
                && !options.ContainerSelectionBlocked
                && detection.CodexContainerCount == 0;
            options.RestartExistingContainerAfterInstall = options.ReuseExistingContainer;
            options.LaunchAfter = false;
            options.DetectionSummary = detection.Summary;
            options.DetectedExisting = detection.FoundExisting;
            options.DockerCliFound = detection.DockerCliFound;
            options.DockerDaemonAvailable = detection.DockerDaemonAvailable;
            options.ExistingContainerFound = detection.ExistingContainerFound;
            options.ExistingContainerName = detection.ContainerName;
            options.ExistingContainerStatus = detection.ContainerStatus;
            options.ExistingCodexInstalled = detection.CodexInstalled;
            options.StopExistingContainer = false;
            options.ContainerName = options.ReuseExistingContainer
                ? detection.ContainerName
                : FindAvailableDockerName("docker-codex", detection.ContainerNames);
            options.ServiceName = options.ReuseExistingContainer && !string.IsNullOrWhiteSpace(detection.ServiceName)
                ? detection.ServiceName
                : "codex-dev";
            options.ProjectName = options.ReuseExistingContainer && !string.IsNullOrWhiteSpace(detection.ProjectName)
                ? detection.ProjectName
                : FindAvailableDockerName("docker-codex-suite", detection.ComposeProjectNames);
            options.ApiEnvKey = string.IsNullOrWhiteSpace(detection.ApiEnvKey)
                ? "DOCKER_CODEX_API_KEY"
                : detection.ApiEnvKey;
            options.RemoteHostId = "remote-ssh-discovered:docker-codex-suite";
            return options;
        }

        internal static InstallOptions FromCommandLine(CommandLine commandLine)
        {
            InstallOptions options = Defaults();
            options.TestMode = commandLine.Has("--test-mode");
            string requestedInstallDir = Path.GetFullPath(commandLine.Value("--install-dir", options.InstallDir));
            options.InstallDir = options.TestMode
                ? requestedInstallDir
                : InstallRegistration.ResolveUpgradeInstallDirectory(requestedInstallDir);
            options.DockerDir = Path.GetFullPath(commandLine.Value("--docker-dir", options.DockerDir));
            options.WorkspaceDir = Path.GetFullPath(commandLine.Value("--workspace-dir", options.WorkspaceDir));
            options.SshKeyPath = Path.GetFullPath(commandLine.Value("--ssh-key", options.SshKeyPath));
            options.ApiEnvKey = commandLine.Value("--api-env-key", options.ApiEnvKey);
            int port;
            if (int.TryParse(commandLine.Value("--ssh-port", options.SshPort.ToString()), out port))
            {
                options.SshPort = port;
            }
            options.BuildDocker = !options.ReuseExistingContainer
                && !options.ContainerSelectionBlocked
                && options.ExistingCodexContainerCount == 0
                && !commandLine.Has("--no-docker");
            options.StopExistingContainer = false;
            options.LaunchAfter = commandLine.Has("--launch");
            options.SkipSsh = commandLine.Has("--skip-ssh");
            options.SkipShortcuts = commandLine.Has("--skip-shortcuts");
            options.SkipRegistry = commandLine.Has("--skip-registry");
            if (options.TestMode)
            {
                options.BuildDocker = false;
                options.StopExistingContainer = false;
                options.RestartExistingContainerAfterInstall = false;
                options.LaunchAfter = false;
                options.SkipSsh = true;
                options.SkipShortcuts = true;
                options.SkipRegistry = true;
            }
            return options;
        }

        private static string FindAvailableDockerName(string baseName, string[] usedNames)
        {
            string[] used = usedNames ?? new string[0];
            for (int suffix = 1; suffix < 10000; suffix++)
            {
                string candidate = suffix == 1 ? baseName : baseName + "-" + suffix;
                bool occupied = false;
                foreach (string usedName in used)
                {
                    if (string.Equals(candidate, usedName, StringComparison.OrdinalIgnoreCase))
                    {
                        occupied = true;
                        break;
                    }
                }
                if (!occupied) return candidate;
            }
            throw new InvalidOperationException("Could not allocate a safe Docker name.");
        }

        private static string FindExistingSshIdentity(string userProfile, string dockerDir, int sshPort)
        {
            string sshDir = Path.Combine(userProfile, ".ssh");
            string configPath = Path.Combine(sshDir, "config");
            if (File.Exists(configPath))
            {
                string config = File.ReadAllText(configPath, Encoding.UTF8);
                MatchCollection blocks = Regex.Matches(
                    config,
                    "(?ms)^\\s*Host\\s+[^\\r\\n]+\\r?\\n(?<body>.*?)(?=^\\s*Host\\s+|\\z)");
                foreach (Match block in blocks)
                {
                    string body = block.Groups["body"].Value;
                    string hostName = GetSshDirective(body, "HostName");
                    string portText = GetSshDirective(body, "Port");
                    string identity = GetSshDirective(body, "IdentityFile");
                    int port;
                    if ((!string.Equals(hostName, "127.0.0.1", StringComparison.OrdinalIgnoreCase)
                            && !string.Equals(hostName, "localhost", StringComparison.OrdinalIgnoreCase))
                        || !int.TryParse(portText, out port)
                        || port != sshPort
                        || string.IsNullOrWhiteSpace(identity))
                    {
                        continue;
                    }

                    string resolved = ResolveSshIdentityPath(identity, userProfile);
                    if (File.Exists(resolved)) return resolved;
                }
            }

            string composeIdentity = FindComposeIdentity(sshDir, dockerDir);
            if (!string.IsNullOrWhiteSpace(composeIdentity)) return composeIdentity;

            string legacy = Path.Combine(sshDir, "codex_docker_ed25519");
            return File.Exists(legacy) ? legacy : "";
        }

        private static string GetSshDirective(string block, string name)
        {
            Match match = Regex.Match(
                block,
                "(?mi)^\\s*" + Regex.Escape(name) + "\\s+(?<value>.+?)\\s*$");
            return match.Success ? match.Groups["value"].Value.Trim() : "";
        }

        private static string ResolveSshIdentityPath(string value, string userProfile)
        {
            string path = Environment.ExpandEnvironmentVariables(value.Trim().Trim('"'));
            path = path.Replace('/', Path.DirectorySeparatorChar);
            if (path.StartsWith("~" + Path.DirectorySeparatorChar, StringComparison.Ordinal))
            {
                path = Path.Combine(userProfile, path.Substring(2));
            }
            return Path.IsPathRooted(path) ? Path.GetFullPath(path) : "";
        }

        private static string FindComposeIdentity(string sshDir, string dockerDir)
        {
            if (string.IsNullOrWhiteSpace(dockerDir) || !Directory.Exists(dockerDir)) return "";
            string[] names = { "compose.yml", "compose.yaml", "docker-compose.yml", "docker-compose.yaml" };
            string publicKey = "";
            foreach (string name in names)
            {
                string composePath = Path.Combine(dockerDir, name);
                if (!File.Exists(composePath)) continue;
                Match match = Regex.Match(
                    File.ReadAllText(composePath, Encoding.UTF8),
                    "ssh-ed25519\\s+(?<key>[A-Za-z0-9+/=]+)",
                    RegexOptions.IgnoreCase);
                if (match.Success) publicKey = match.Groups["key"].Value;
                break;
            }
            if (string.IsNullOrWhiteSpace(publicKey) || !Directory.Exists(sshDir)) return "";

            foreach (string publicKeyPath in Directory.GetFiles(sshDir, "*.pub"))
            {
                string[] fields = File.ReadAllText(publicKeyPath, Encoding.UTF8)
                    .Trim()
                    .Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
                if (fields.Length >= 2 && string.Equals(fields[1], publicKey, StringComparison.Ordinal))
                {
                    return publicKeyPath.Substring(0, publicKeyPath.Length - 4);
                }
            }
            return "";
        }
    }

    internal sealed class ManagedSkillInstallResult
    {
        internal string Action;
        internal string DestinationPath;
        internal string BackupPath;
        internal bool BackupCreated;
    }

    internal sealed class ManagedSkillMarker
    {
        public string product { get; set; }
        public string component { get; set; }
        public string version { get; set; }
        public string backup_path { get; set; }
        public Dictionary<string, string> files { get; set; }
    }

    internal static class ManagedSkillInstaller
    {
        private const string Product = "Docker Codex Suite";
        private const string Component = "project-commander";
        private const string MarkerName = ".docker-codex-suite-managed.json";
        private static readonly string[] RequiredFiles =
        {
            "SKILL.md",
            "agents/openai.yaml",
            "scripts/project-commander.ps1"
        };

        internal static ManagedSkillInstallResult Install(
            string sourceDirectory,
            string codexHome,
            string version,
            Action<string> report)
        {
            sourceDirectory = Path.GetFullPath(sourceDirectory);
            codexHome = Path.GetFullPath(codexHome);
            ValidateSource(sourceDirectory);

            Dictionary<string, string> incomingFiles = BuildManifest(sourceDirectory);
            string skillsRoot = Path.Combine(codexHome, "skills");
            string destination = Path.Combine(skillsRoot, Component);
            Directory.CreateDirectory(skillsRoot);

            ManagedSkillMarker oldMarker = ReadMarker(destination);
            if (Directory.Exists(destination) && DirectoryMatchesManifest(destination, incomingFiles))
            {
                WriteMarker(destination, version, incomingFiles, TrustedBackupPath(codexHome, oldMarker));
                Report(report, oldMarker == null
                    ? "Registered the existing Project Commander skill as a managed component."
                    : "Project Commander is already current.");
                return new ManagedSkillInstallResult
                {
                    Action = oldMarker == null ? "registered" : "unchanged",
                    DestinationPath = destination,
                    BackupPath = TrustedBackupPath(codexHome, oldMarker),
                    BackupCreated = false
                };
            }

            bool destinationExists = Directory.Exists(destination);
            bool oldManagedCopyIsClean = destinationExists
                && oldMarker != null
                && DirectoryMatchesManifest(destination, oldMarker.files);
            string preservedBackup = TrustedBackupPath(codexHome, oldMarker);
            string stagingRoot = Path.Combine(codexHome, ".dcs-stage");
            Directory.CreateDirectory(stagingRoot);
            string staged = Path.Combine(stagingRoot, "i-" + ShortId());
            CopyDirectory(sourceDirectory, staged);

            string displaced = "";
            bool backupCreated = false;
            if (destinationExists)
            {
                if (oldManagedCopyIsClean)
                {
                    displaced = Path.Combine(stagingRoot, "p-" + ShortId());
                }
                else
                {
                    displaced = NextBackupPath(codexHome);
                    Directory.CreateDirectory(Path.GetDirectoryName(displaced));
                    preservedBackup = displaced;
                    backupCreated = true;
                }
            }

            WriteMarker(staged, version, incomingFiles, preservedBackup);
            try
            {
                if (destinationExists) Directory.Move(destination, displaced);
                try
                {
                    Directory.Move(staged, destination);
                }
                catch
                {
                    if (destinationExists && !Directory.Exists(destination) && Directory.Exists(displaced))
                    {
                        Directory.Move(displaced, destination);
                    }
                    throw;
                }

                if (destinationExists && oldManagedCopyIsClean && Directory.Exists(displaced))
                {
                    Directory.Delete(displaced, true);
                }
            }
            finally
            {
                if (Directory.Exists(staged)) Directory.Delete(staged, true);
                DeleteIfEmpty(stagingRoot);
            }

            if (backupCreated)
            {
                Report(report, "Backed up the previous Project Commander skill to " + displaced + ".");
            }
            Report(report, "Installed Project Commander into the main Codex space: " + destination + ".");
            return new ManagedSkillInstallResult
            {
                Action = destinationExists
                    ? (backupCreated ? "replaced-with-backup" : "updated")
                    : "installed",
                DestinationPath = destination,
                BackupPath = preservedBackup,
                BackupCreated = backupCreated
            };
        }

        internal static bool UninstallIfUnmodified(string codexHome, Action<string> report)
        {
            codexHome = Path.GetFullPath(codexHome);
            string destination = Path.Combine(codexHome, "skills", Component);
            ManagedSkillMarker marker = ReadMarker(destination);
            if (marker == null || !DirectoryMatchesManifest(destination, marker.files))
            {
                if (Directory.Exists(destination))
                {
                    Report(report, "Project Commander contains user changes and was preserved during uninstall.");
                }
                return false;
            }

            string backup = TrustedBackupPath(codexHome, marker);
            if (!string.IsNullOrEmpty(backup) && Directory.Exists(backup))
            {
                string stagingRoot = Path.Combine(codexHome, ".dcs-stage");
                Directory.CreateDirectory(stagingRoot);
                string removed = Path.Combine(stagingRoot, "u-" + ShortId());
                Directory.Move(destination, removed);
                try
                {
                    Directory.Move(backup, destination);
                    Directory.Delete(removed, true);
                }
                catch
                {
                    if (!Directory.Exists(destination) && Directory.Exists(removed))
                    {
                        Directory.Move(removed, destination);
                    }
                    throw;
                }
                finally
                {
                    DeleteIfEmpty(stagingRoot);
                }
                Report(report, "Restored the Project Commander copy that existed before installation.");
                return true;
            }

            Directory.Delete(destination, true);
            Report(report, "Removed the unmodified managed Project Commander skill.");
            return true;
        }

        private static void ValidateSource(string sourceDirectory)
        {
            if (!Directory.Exists(sourceDirectory))
            {
                throw new DirectoryNotFoundException("Bundled Project Commander skill is missing: " + sourceDirectory);
            }
            if (File.Exists(Path.Combine(sourceDirectory, MarkerName)))
            {
                throw new InvalidDataException("The bundled skill must not contain installation state.");
            }
            foreach (string relative in RequiredFiles)
            {
                string path = Path.Combine(sourceDirectory, relative.Replace('/', Path.DirectorySeparatorChar));
                if (!File.Exists(path))
                {
                    throw new FileNotFoundException("Bundled Project Commander file is missing.", path);
                }
            }
        }

        private static Dictionary<string, string> BuildManifest(string directory)
        {
            Dictionary<string, string> files = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            string root = Path.GetFullPath(directory).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            string[] paths = Directory.GetFiles(root, "*", SearchOption.AllDirectories);
            Array.Sort(paths, StringComparer.OrdinalIgnoreCase);
            foreach (string path in paths)
            {
                string relative = Path.GetFullPath(path).Substring(root.Length).Replace('\\', '/');
                if (string.Equals(relative, MarkerName, StringComparison.OrdinalIgnoreCase)) continue;
                files.Add(relative, HashFile(path));
            }
            return files;
        }

        private static bool DirectoryMatchesManifest(string directory, Dictionary<string, string> expected)
        {
            if (!Directory.Exists(directory) || expected == null) return false;
            try
            {
                Dictionary<string, string> actual = BuildManifest(directory);
                if (actual.Count != expected.Count) return false;
                foreach (KeyValuePair<string, string> item in expected)
                {
                    string hash;
                    if (!actual.TryGetValue(item.Key, out hash)
                        || !string.Equals(hash, item.Value, StringComparison.OrdinalIgnoreCase))
                    {
                        return false;
                    }
                }
                return true;
            }
            catch
            {
                return false;
            }
        }

        private static string HashFile(string path)
        {
            using (SHA256 hash = SHA256.Create())
            using (FileStream stream = File.OpenRead(path))
            {
                byte[] bytes = hash.ComputeHash(stream);
                StringBuilder builder = new StringBuilder(bytes.Length * 2);
                foreach (byte value in bytes) builder.Append(value.ToString("x2"));
                return builder.ToString();
            }
        }

        private static ManagedSkillMarker ReadMarker(string directory)
        {
            string path = Path.Combine(directory, MarkerName);
            if (!File.Exists(path)) return null;
            try
            {
                ManagedSkillMarker marker = new JavaScriptSerializer().Deserialize<ManagedSkillMarker>(
                    File.ReadAllText(path, Encoding.UTF8));
                if (marker == null
                    || !string.Equals(marker.product, Product, StringComparison.Ordinal)
                    || !string.Equals(marker.component, Component, StringComparison.Ordinal)
                    || marker.files == null)
                {
                    return null;
                }
                Dictionary<string, string> normalized = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                foreach (KeyValuePair<string, string> item in marker.files)
                {
                    if (string.IsNullOrWhiteSpace(item.Key) || string.IsNullOrWhiteSpace(item.Value)) return null;
                    normalized.Add(item.Key.Replace('\\', '/'), item.Value);
                }
                marker.files = normalized;
                return marker;
            }
            catch
            {
                return null;
            }
        }

        private static void WriteMarker(
            string directory,
            string version,
            Dictionary<string, string> files,
            string backupPath)
        {
            ManagedSkillMarker marker = new ManagedSkillMarker
            {
                product = Product,
                component = Component,
                version = version,
                backup_path = string.IsNullOrEmpty(backupPath) ? null : backupPath,
                files = new Dictionary<string, string>(files, StringComparer.OrdinalIgnoreCase)
            };
            string json = new JavaScriptSerializer().Serialize(marker) + "\r\n";
            File.WriteAllText(Path.Combine(directory, MarkerName), json, new UTF8Encoding(false));
        }

        private static void CopyDirectory(string source, string destination)
        {
            Directory.CreateDirectory(destination);
            string root = Path.GetFullPath(source).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            foreach (string directory in Directory.GetDirectories(root, "*", SearchOption.AllDirectories))
            {
                string relative = Path.GetFullPath(directory).Substring(root.Length);
                Directory.CreateDirectory(Path.Combine(destination, relative));
            }
            foreach (string file in Directory.GetFiles(root, "*", SearchOption.AllDirectories))
            {
                string relative = Path.GetFullPath(file).Substring(root.Length);
                string target = Path.Combine(destination, relative);
                Directory.CreateDirectory(Path.GetDirectoryName(target));
                File.Copy(file, target, true);
            }
        }

        private static string NextBackupPath(string codexHome)
        {
            string root = BackupRoot(codexHome);
            string stem = DateTime.Now.ToString("yyyyMMdd-HHmmss-fff");
            for (int suffix = 0; suffix < 1000; suffix++)
            {
                string name = suffix == 0 ? stem : stem + "-" + suffix;
                string candidate = Path.Combine(root, name);
                if (!Directory.Exists(candidate) && !File.Exists(candidate)) return candidate;
            }
            throw new IOException("Could not allocate a Project Commander backup directory.");
        }

        private static string TrustedBackupPath(string codexHome, ManagedSkillMarker marker)
        {
            if (marker == null || string.IsNullOrWhiteSpace(marker.backup_path)) return "";
            try
            {
                string root = BackupRoot(codexHome).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
                string candidate = Path.GetFullPath(marker.backup_path);
                return candidate.StartsWith(root, StringComparison.OrdinalIgnoreCase) ? candidate : "";
            }
            catch
            {
                return "";
            }
        }

        private static string BackupRoot(string codexHome)
        {
            return Path.Combine(codexHome, "docker-codex-suite-backups", "skills", Component);
        }

        private static string ShortId()
        {
            return Guid.NewGuid().ToString("N").Substring(0, 12);
        }

        private static void DeleteIfEmpty(string directory)
        {
            if (Directory.Exists(directory)
                && Directory.GetFileSystemEntries(directory).Length == 0)
            {
                Directory.Delete(directory, false);
            }
        }

        private static void Report(Action<string> report, string message)
        {
            if (report != null) report(message);
        }
    }

    internal sealed class InstallerEngine
    {
        private const string PayloadResourceName = "DockerCodex.Payload";
        private const string SshBlockStart = "# BEGIN Docker Codex Suite";
        private const string SshBlockEnd = "# END Docker Codex Suite";
        private readonly Action<string> report;
        private string installLogPath;

        internal InstallerEngine(Action<string> reportAction)
        {
            report = reportAction ?? delegate { };
        }

        internal void Install(InstallOptions options)
        {
            if (options == null) throw new ArgumentNullException("options");
            if (!options.TestMode)
            {
                string existingInstallDir = InstallRegistration.ReadExistingSuiteInstallDirectory();
                if (!string.IsNullOrWhiteSpace(existingInstallDir))
                {
                    string requestedInstallDir = options.InstallDir;
                    options.InstallDir = InstallRegistration.ResolveUpgradeInstallDirectory(
                        requestedInstallDir,
                        existingInstallDir);
                    if (!InstallRegistration.AreSameDirectory(requestedInstallDir, options.InstallDir))
                    {
                        report("Existing installation detected; upgrade directory fixed to " + options.InstallDir + ".");
                    }
                }
            }
            ValidateOptions(options);
            PrepareDockerRuntime(options);
            Directory.CreateDirectory(options.InstallDir);
            Directory.CreateDirectory(Path.Combine(options.InstallDir, "data"));
            installLogPath = Path.Combine(options.InstallDir, "data", "install.log");

            Log("Installing " + Program.ProductName + " " + Program.ProductVersion + "...");
            Log("Controller: " + options.InstallDir);
            Log("Docker solution: " + options.DockerDir);
            Log("Workspace: " + options.WorkspaceDir);
            Log("SSH port: " + options.SshPort);

            if (!options.TestMode) CloseRunningControllerWindows();
            string legacyPackagedSkill = Path.Combine(options.InstallDir, "skills", "project-commander");
            if (Directory.Exists(legacyPackagedSkill))
            {
                Directory.Delete(legacyPackagedSkill, true);
                Log("Removed the legacy bundled Project Commander payload.");
            }
            ExtractPayload(options.InstallDir, true);
            Log("Controller payload extracted.");
            EnsureEmptyProfileStore(options.InstallDir);
            Log("Local profile store ready.");

            string publicKey = options.SkipSsh
                ? "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIStandaloneTestOnly docker-codex-test"
                : EnsureSshKey(options.SshKeyPath);

            if (options.ReuseExistingContainer)
            {
                Log("Reusing existing Docker Codex container " + options.ContainerName + ".");
                Log("Existing Docker files and compose configuration were left unchanged.");
            }
            else
            {
                InstallDockerSolution(options, publicKey);
                Log("Docker solution files ready.");
            }
            WriteSettings(options);
            Log("Controller settings written.");
            if (!options.TestMode) RepairActiveProfile(options.InstallDir);

            if (!options.SkipSsh)
            {
                UpdateSshConfig(options);
            }
            else
            {
                Log("SSH configuration skipped.");
            }
            if (!options.SkipShortcuts)
            {
                CreateShortcuts(options.InstallDir);
                VerifyShortcuts(options.InstallDir);
            }
            else
            {
                Log("Start Menu shortcuts skipped.");
            }
            if (!options.SkipRegistry)
            {
                RegisterUninstaller(options);
                RegisterBridgeStartup(options.InstallDir);
                VerifyRegistration(options.InstallDir);
            }
            else
            {
                Log("Uninstall registry entry skipped.");
            }
            if (options.BuildDocker)
            {
                BuildAndStartDocker(options.DockerDir);
            }
            else if (options.ReuseExistingContainer
                && options.RestartExistingContainerAfterInstall
                && !options.TestMode)
            {
                RestartExistingCodexContainer(options);
            }
            if (!options.TestMode)
            {
                RestartStandaloneBridge(options.InstallDir);
                ReconnectDockerCodex(options.InstallDir);
            }
            if (options.LaunchAfter)
            {
                LaunchDockerCodex(options.InstallDir);
            }

            Log("Installation complete.");
        }

        internal static void LaunchDockerCodexAfterInstall(string installDir, Action<string> reportAction)
        {
            StartDockerCodexProcess(installDir, "--launch-switcher");
            if (reportAction != null)
            {
                reportAction("Docker Codex Suite switcher launch requested.");
            }
        }

        private void LaunchDockerCodex(string installDir)
        {
            Log("Launching Docker Codex Suite...");
            StartDockerCodexProcess(installDir);
            Log("Docker Codex Suite launch requested.");
        }

        private static void StartDockerCodexProcess(string installDir, string arguments = "--launch")
        {
            string launcher = Path.Combine(installDir, "DockerCodex.exe");
            if (!File.Exists(launcher))
            {
                throw new FileNotFoundException("Docker Codex launcher is missing.", launcher);
            }

            ProcessStartInfo info = new ProcessStartInfo();
            info.FileName = launcher;
            info.Arguments = arguments;
            info.WorkingDirectory = installDir;
            info.UseShellExecute = false;
            info.CreateNoWindow = true;
            info.WindowStyle = ProcessWindowStyle.Hidden;
            Process process = Process.Start(info);
            if (process == null)
            {
                throw new InvalidOperationException("Unable to start Docker Codex Suite.");
            }
            process.Dispose();
        }

        internal static bool IsControllerWindowForTesting(string processName, string windowTitle)
        {
            string name = (processName ?? "").Trim();
            string title = (windowTitle ?? "").Trim();
            bool isPowerShell = string.Equals(name, "powershell", StringComparison.OrdinalIgnoreCase)
                || string.Equals(name, "powershell.exe", StringComparison.OrdinalIgnoreCase)
                || string.Equals(name, "pwsh", StringComparison.OrdinalIgnoreCase)
                || string.Equals(name, "pwsh.exe", StringComparison.OrdinalIgnoreCase);
            if (!isPowerShell || title.Length == 0) return false;
            return title.StartsWith("Docker Codex API", StringComparison.OrdinalIgnoreCase)
                || title.IndexOf("Docker API", StringComparison.OrdinalIgnoreCase) >= 0
                || title.IndexOf("Codex++ API", StringComparison.OrdinalIgnoreCase) >= 0;
        }

        private void CloseRunningControllerWindows()
        {
            List<Process> candidates = new List<Process>();
            candidates.AddRange(Process.GetProcessesByName("powershell"));
            candidates.AddRange(Process.GetProcessesByName("pwsh"));
            foreach (Process process in candidates)
            {
                using (process)
                {
                    try
                    {
                        process.Refresh();
                        if (process.MainWindowHandle == IntPtr.Zero
                            || !IsControllerWindowForTesting(process.ProcessName, process.MainWindowTitle))
                        {
                            continue;
                        }

                        Log("Closing an older Docker Codex controller window before upgrade (PID " + process.Id + ").");
                        process.CloseMainWindow();
                        if (!process.WaitForExit(4000))
                        {
                            process.Kill();
                            process.WaitForExit(4000);
                        }
                    }
                    catch (Exception exception)
                    {
                        Log("Unable to close an older controller window: " + exception.Message);
                    }
                }
            }
        }

        private void RepairActiveProfile(string installDir)
        {
            string script = Path.Combine(installDir, "docker-codex-api-switch.ps1");
            if (!File.Exists(script)) return;
            string powershell = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.System),
                "WindowsPowerShell", "v1.0", "powershell.exe");
            if (!File.Exists(powershell)) return;

            Log("Checking the active API profile configuration...");
            RunProcess(
                powershell,
                "-NoProfile -NoLogo -NonInteractive -ExecutionPolicy Bypass -File "
                    + Quote(script) + " -Action RepairProfile",
                installDir,
                false);
        }

        private void ReconnectDockerCodex(string installDir)
        {
            string script = Path.Combine(installDir, "docker-codex-api-switch.ps1");
            if (!File.Exists(script)) return;
            string powershell = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.System),
                "WindowsPowerShell", "v1.0", "powershell.exe");
            if (!File.Exists(powershell)) return;

            Log("Requesting a native Docker Codex reconnect and model-list refresh...");
            RunProcess(
                powershell,
                "-NoProfile -NoLogo -NonInteractive -ExecutionPolicy Bypass -File "
                    + Quote(script) + " -Action Reconnect",
                installDir,
                false);
        }

        private void PrepareDockerRuntime(InstallOptions options)
        {
            if (!options.BuildDocker) return;
            if (!EnvironmentDetector.DockerDaemonIsAvailable())
            {
                throw new InvalidOperationException(
                    "Docker Desktop is not installed or its daemon is not running. Start Docker Desktop and retry, or clear the Docker build option.");
            }

            for (int attempt = 0; attempt < 20 && !PortUtility.IsAvailable(options.SshPort); attempt++)
            {
                System.Threading.Thread.Sleep(250);
            }
            if (!PortUtility.IsAvailable(options.SshPort))
            {
                int replacementPort = PortUtility.FindAvailable(options.SshPort + 1);
                Log("SSH port " + options.SshPort + " is still occupied; using " + replacementPort + " instead.");
                options.SshPort = replacementPort;
            }
        }

        internal static void ExtractPayloadOnly(string destination)
        {
            destination = Path.GetFullPath(destination);
            Directory.CreateDirectory(destination);
            ExtractPayload(destination, false);
        }

        private static void ValidateOptions(InstallOptions options)
        {
            if (options.SshPort < 1024 || options.SshPort > 65535)
            {
                throw new ArgumentOutOfRangeException("SshPort", "SSH port must be between 1024 and 65535.");
            }
            if (string.IsNullOrWhiteSpace(options.InstallDir) || string.IsNullOrWhiteSpace(options.DockerDir))
            {
                throw new ArgumentException("Installation directories cannot be empty.");
            }
            if (!Regex.IsMatch(options.ApiEnvKey ?? "", "^[A-Za-z_][A-Za-z0-9_]*$"))
            {
                throw new ArgumentException("The Docker API environment variable name is invalid.");
            }
            if (options.ContainerSelectionBlocked)
            {
                throw new InvalidOperationException(
                    "Docker container detection is ambiguous or incomplete. No container will be created or controlled until detection succeeds.");
            }
            if (options.StopExistingContainer)
            {
                throw new InvalidOperationException("Stopping an existing container during installation is not permitted.");
            }
            if (!Regex.IsMatch(options.ContainerName ?? "", "^[A-Za-z0-9][A-Za-z0-9_.-]*$")
                || !Regex.IsMatch(options.ServiceName ?? "", "^[A-Za-z0-9][A-Za-z0-9_.-]*$")
                || !Regex.IsMatch(options.ProjectName ?? "", "^[A-Za-z0-9][A-Za-z0-9_.-]*$"))
            {
                throw new InvalidOperationException("Unsafe Docker project, service, or container name detected.");
            }
            if (options.ReuseExistingContainer)
            {
                if (options.BuildDocker)
                {
                    throw new InvalidOperationException("An existing Codex container cannot be rebuilt by the installer.");
                }
                ContainerDetection existing = EnvironmentDetector.InspectContainerForInstall(options.ContainerName);
                if (existing == null || !existing.CodexInstalled)
                {
                    throw new InvalidOperationException(
                        "The reusable Docker Codex container " + options.ContainerName
                        + " is no longer available. Run detection again before installing.");
                }
            }
            else if (options.BuildDocker)
            {
                ContainerScanResult current = EnvironmentDetector.ScanContainersForInstall();
                if (current.ScanIncomplete || current.SelectionBlocked)
                {
                    throw new InvalidOperationException(
                        "Docker container detection could not be completed safely. No new container was created.");
                }
                if (current.CodexContainerNames.Length > 0)
                {
                    throw new InvalidOperationException(
                        "A Docker container with Codex CLI now exists ("
                        + string.Join(", ", current.CodexContainerNames)
                        + "). Run detection again; the installer will reuse it instead of creating another container.");
                }
                if (Array.Exists(current.ContainerNames, delegate(string name)
                    {
                        return string.Equals(name, options.ContainerName, StringComparison.OrdinalIgnoreCase);
                    }))
                {
                    throw new InvalidOperationException(
                        "The new container name " + options.ContainerName + " is already occupied. Run detection again.");
                }
                if (Array.Exists(current.ComposeProjectNames, delegate(string name)
                    {
                        return string.Equals(name, options.ProjectName, StringComparison.OrdinalIgnoreCase);
                    }))
                {
                    throw new InvalidOperationException(
                        "The new Docker project name " + options.ProjectName + " is already occupied. Run detection again.");
                }
            }
            Directory.CreateDirectory(options.WorkspaceDir);
        }

        private static void ExtractPayload(string destination, bool preserveData)
        {
            Assembly assembly = Assembly.GetExecutingAssembly();
            using (Stream stream = assembly.GetManifestResourceStream(PayloadResourceName))
            {
                if (stream == null)
                {
                    throw new InvalidOperationException("Embedded payload was not found.");
                }
                using (ZipArchive archive = new ZipArchive(stream, ZipArchiveMode.Read, false))
                {
                    string root = Path.GetFullPath(destination + Path.DirectorySeparatorChar);
                    foreach (ZipArchiveEntry entry in archive.Entries)
                    {
                        string relative = entry.FullName.Replace('/', Path.DirectorySeparatorChar);
                        if (preserveData && relative.StartsWith("data" + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                        {
                            continue;
                        }
                        string target = Path.GetFullPath(Path.Combine(destination, relative));
                        if (!target.StartsWith(root, StringComparison.OrdinalIgnoreCase))
                        {
                            throw new InvalidDataException("Unsafe payload path: " + entry.FullName);
                        }
                        if (string.IsNullOrEmpty(entry.Name))
                        {
                            Directory.CreateDirectory(target);
                            continue;
                        }
                        Directory.CreateDirectory(Path.GetDirectoryName(target));
                        using (Stream input = entry.Open())
                        using (FileStream output = new FileStream(target, FileMode.Create, FileAccess.Write, FileShare.None))
                        {
                            input.CopyTo(output);
                        }
                    }
                }
            }
        }

        private void EnsureEmptyProfileStore(string installDir)
        {
            string path = Path.Combine(installDir, "data", "api-profiles.json");
            if (!File.Exists(path))
            {
                WriteUtf8(path, "[]\r\n");
            }
        }

        private void MigrateControllerState(string previousInstallDir, string installDir)
        {
            if (!InstallRegistration.IsSuiteInstallDirectory(previousInstallDir))
            {
                Log("Previous controller files were not found; no local state was migrated.");
                return;
            }

            string sourceData = Path.Combine(previousInstallDir, "data");
            string targetData = Path.Combine(installDir, "data");
            if (!Directory.Exists(sourceData))
            {
                Log("Previous controller data directory was not found; no local state was migrated.");
                return;
            }

            Directory.CreateDirectory(targetData);
            foreach (string fileName in new[] { "api-profiles.json", "switch-state.json", "chat-proxy.json" })
            {
                string source = Path.Combine(sourceData, fileName);
                string target = Path.Combine(targetData, fileName);
                if (!File.Exists(source)) continue;

                bool targetIsEmptyProfile = false;
                if (string.Equals(fileName, "api-profiles.json", StringComparison.OrdinalIgnoreCase)
                    && File.Exists(target))
                {
                    try
                    {
                        targetIsEmptyProfile = string.Equals(
                            File.ReadAllText(target, Encoding.UTF8).Trim(),
                            "[]",
                            StringComparison.Ordinal);
                    }
                    catch
                    {
                        targetIsEmptyProfile = false;
                    }
                }
                if (File.Exists(target) && !targetIsEmptyProfile)
                {
                    Log("Kept existing controller state: " + fileName + ".");
                    continue;
                }

                try
                {
                    File.Copy(source, target, true);
                    Log("Migrated controller state: " + fileName + ".");
                }
                catch (Exception exception)
                {
                    Log("Unable to migrate controller state " + fileName + ": " + exception.Message);
                }
            }
        }

        private string EnsureSshKey(string keyPath)
        {
            string publicKeyPath = keyPath + ".pub";
            if (!File.Exists(keyPath) || !File.Exists(publicKeyPath))
            {
                Directory.CreateDirectory(Path.GetDirectoryName(keyPath));
                string sshKeygen = FindExecutable("ssh-keygen.exe", Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "OpenSSH"));
                if (string.IsNullOrEmpty(sshKeygen))
                {
                    throw new InvalidOperationException("Windows OpenSSH Client is required (ssh-keygen.exe was not found).");
                }
                Log("Generating an Ed25519 SSH key...");
                RunProcess(
                    sshKeygen,
                    "-q -t ed25519 -f " + Quote(keyPath) + " -N \"\" -C docker-codex-local",
                    Path.GetDirectoryName(keyPath),
                    true);
            }
            string publicKey = File.ReadAllText(publicKeyPath, Encoding.UTF8).Trim();
            if (!publicKey.StartsWith("ssh-ed25519 ", StringComparison.Ordinal))
            {
                throw new InvalidDataException("The generated SSH public key is invalid.");
            }
            return publicKey;
        }

        private void InstallDockerSolution(InstallOptions options, string publicKey)
        {
            Log("Writing sanitized Docker solution files...");
            Directory.CreateDirectory(options.DockerDir);
            Directory.CreateDirectory(Path.Combine(options.DockerDir, "codex-home"));

            string templates = Path.Combine(options.InstallDir, "docker-template");
            CopyTemplate(Path.Combine(templates, "Dockerfile"), Path.Combine(options.DockerDir, "Dockerfile"));
            CopyTemplate(Path.Combine(templates, "docker-entrypoint.sh"), Path.Combine(options.DockerDir, "docker-entrypoint.sh"));
            CopyTemplate(Path.Combine(templates, "update-container.ps1"), Path.Combine(options.DockerDir, "update-container.ps1"));
            CopyTemplate(Path.Combine(templates, ".env.example"), Path.Combine(options.DockerDir, ".env.example"));

            string compose = File.ReadAllText(Path.Combine(templates, "compose.template.yml"), Encoding.UTF8);
            compose = compose.Replace("{{PROJECT_NAME}}", options.ProjectName);
            compose = compose.Replace("{{SERVICE_NAME}}", options.ServiceName);
            compose = compose.Replace("{{CONTAINER_NAME}}", options.ContainerName);
            compose = compose.Replace("{{SSH_PUBLIC_KEY}}", EscapeYaml(publicKey));
            compose = compose.Replace("{{SSH_PORT}}", options.SshPort.ToString());
            compose = compose.Replace("{{WORKSPACE_PATH}}", EscapeYaml(options.WorkspaceDir.Replace('\\', '/')));
            compose = compose.Replace("DOCKER_CODEX_API_KEY", options.ApiEnvKey);
            WriteWithBackup(Path.Combine(options.DockerDir, "compose.yml"), compose);

            string config = File.ReadAllText(Path.Combine(templates, "config.template.toml"), Encoding.UTF8);
            string localConfig = Path.Combine(options.DockerDir, "codex-home", "config.local-mode.toml");
            string activeConfig = Path.Combine(options.DockerDir, "codex-home", "config.toml");
            if (!File.Exists(localConfig)) WriteUtf8(localConfig, config);
            if (!File.Exists(activeConfig)) WriteUtf8(activeConfig, config);

            string envPath = Path.Combine(options.DockerDir, ".env");
            if (!File.Exists(envPath))
            {
                WriteUtf8(envPath, options.ApiEnvKey + "=\r\n");
            }
        }

        private void WriteSettings(InstallOptions options)
        {
            Dictionary<string, object> settings = new Dictionary<string, object>();
            settings["version"] = Program.ProductVersion;
            settings["dataDir"] = "data";
            settings["composeDir"] = options.DockerDir;
            settings["workspaceDir"] = options.WorkspaceDir;
            string codexHome = UserPaths.CodexHome();
            settings["hostConfigPath"] = Path.Combine(codexHome, "config.toml");
            settings["hostAuthPath"] = Path.Combine(codexHome, "auth.json");
            settings["profilesPath"] = "data\\api-profiles.json";
            settings["statePath"] = "data\\switch-state.json";
            settings["nodePath"] = ResolveNodeRuntime();
            settings["remoteHostId"] = options.RemoteHostId;
            settings["projectName"] = options.ProjectName;
            settings["serviceName"] = options.ServiceName;
            settings["containerName"] = options.ContainerName;
            settings["sshPort"] = options.SshPort;
            settings["apiEnvKey"] = options.ApiEnvKey;
            settings["debugPort"] = 9229;
            settings["bridgePort"] = 38118;
            settings["chatProxyPort"] = 38119;
            settings["codexAppUserModelId"] = "OpenAI.Codex_2p2nqsd0c76g0!App";
            JavaScriptSerializer serializer = new JavaScriptSerializer();
            WriteUtf8(Path.Combine(options.InstallDir, "settings.json"), serializer.Serialize(settings) + "\r\n");
        }

        private static string ResolveNodeRuntime()
        {
            string userProfile = UserPaths.Profile();
            string codexNode = Path.Combine(
                userProfile,
                ".cache", "codex-runtimes", "codex-primary-runtime", "dependencies", "node", "bin", "node.exe");
            if (File.Exists(codexNode)) return codexNode;

            string programFilesNode = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
                "nodejs", "node.exe");
            if (File.Exists(programFilesNode)) return programFilesNode;

            string fromPath = FindExecutable("node.exe", "");
            if (!string.IsNullOrEmpty(fromPath)) return fromPath;
            throw new InvalidOperationException(
                "Node.js was not found. Start Codex Desktop once so its local runtime is installed, then run Setup again.");
        }

        private void UpdateSshConfig(InstallOptions options)
        {
            string sshDir = Path.Combine(UserPaths.Profile(), ".ssh");
            Directory.CreateDirectory(sshDir);
            string configPath = Path.Combine(sshDir, "config");
            string existing = File.Exists(configPath) ? File.ReadAllText(configPath, Encoding.UTF8) : "";
            existing = RemoveManagedSshBlock(existing).TrimEnd();
            StringBuilder block = new StringBuilder();
            block.AppendLine(SshBlockStart);
            block.AppendLine("Host docker-codex-suite");
            block.AppendLine("  HostName 127.0.0.1");
            block.AppendLine("  Port " + options.SshPort);
            block.AppendLine("  User codex");
            block.AppendLine("  IdentityFile \"" + options.SshKeyPath.Replace('\\', '/') + "\"");
            block.AppendLine("  IdentitiesOnly yes");
            block.AppendLine("  StrictHostKeyChecking accept-new");
            block.AppendLine(SshBlockEnd);
            string output = (existing.Length == 0 ? "" : existing + "\r\n\r\n") + block.ToString();
            WriteUtf8(configPath, output);
            Log("Updated SSH host: docker-codex-suite");
        }

        private static string RemoveManagedSshBlock(string text)
        {
            string pattern = "(?ms)^" + Regex.Escape(SshBlockStart) + ".*?^" + Regex.Escape(SshBlockEnd) + "\\r?\\n?";
            return Regex.Replace(text, pattern, "");
        }

        private void CreateShortcuts(string installDir)
        {
            string folder = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "Microsoft", "Windows", "Start Menu", "Programs", Program.ProductName);
            if (Directory.Exists(folder))
            {
                foreach (string oldShortcut in Directory.GetFiles(folder, "*.lnk", SearchOption.TopDirectoryOnly))
                {
                    File.Delete(oldShortcut);
                }
            }
            Directory.CreateDirectory(folder);
            string launcher = Path.Combine(installDir, "DockerCodex.exe");
            CreateShortcut(Path.Combine(folder, "Docker Codex Suite.lnk"), launcher, "", installDir, "启动 Codex 并加载 Docker API 菜单");
            CreateShortcut(Path.Combine(folder, "Docker Codex API 切换器.lnk"), launcher, "--switcher", installDir, "打开 Docker Codex API 切换器");
            CreateShortcut(Path.Combine(folder, "使用说明.lnk"), Path.Combine(installDir, "docs", "README.md"), "", installDir, "Docker Codex Suite 使用说明");
            Log("Created Start Menu shortcuts.");
        }

        private void VerifyShortcuts(string installDir)
        {
            string folder = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "Microsoft", "Windows", "Start Menu", "Programs", Program.ProductName);
            string launcher = Path.GetFullPath(Path.Combine(installDir, "DockerCodex.exe"));
            if (!File.Exists(launcher)) throw new FileNotFoundException("Docker Codex launcher is missing.", launcher);

            string[] shortcuts = Directory.Exists(folder)
                ? Directory.GetFiles(folder, "*.lnk", SearchOption.TopDirectoryOnly)
                : new string[0];
            bool foundLauncher = false;
            bool foundSwitcher = false;
            Type shellType = Type.GetTypeFromProgID("WScript.Shell");
            if (shellType == null) throw new InvalidOperationException("WScript.Shell is unavailable.");
            object shellObject = Activator.CreateInstance(shellType);
            dynamic shell = shellObject;
            try
            {
                foreach (string shortcutPath in shortcuts)
                {
                    dynamic shortcut = shell.CreateShortcut(shortcutPath);
                    try
                    {
                        string target = (string)shortcut.TargetPath;
                        string arguments = ((string)shortcut.Arguments ?? "").Trim();
                        bool targetMatches = string.Equals(
                            Path.GetFullPath(target ?? "").TrimEnd(Path.DirectorySeparatorChar),
                            launcher.TrimEnd(Path.DirectorySeparatorChar),
                            StringComparison.OrdinalIgnoreCase);
                        bool storedTargetMatches = ShortcutContainsPath(shortcutPath, launcher);
                        if (!targetMatches && !storedTargetMatches)
                        {
                            continue;
                        }
                        if (arguments.Length == 0) foundLauncher = true;
                        if (string.Equals(arguments, "--switcher", StringComparison.OrdinalIgnoreCase)) foundSwitcher = true;
                    }
                    finally
                    {
                        Marshal.FinalReleaseComObject(shortcut);
                    }
                }
            }
            finally
            {
                Marshal.FinalReleaseComObject(shellObject);
            }

            if (!foundLauncher || !foundSwitcher)
            {
                throw new InvalidOperationException(
                    "Start Menu shortcuts do not point to the selected installation directory: " + installDir);
            }
            Log("Verified Start Menu shortcuts point to the selected installation directory.");
        }

        private static bool ShortcutContainsPath(string shortcutPath, string expectedPath)
        {
            try
            {
                byte[] bytes = File.ReadAllBytes(shortcutPath);
                string unicode = Encoding.Unicode.GetString(bytes);
                string ascii = Encoding.ASCII.GetString(bytes);
                return unicode.IndexOf(expectedPath, StringComparison.OrdinalIgnoreCase) >= 0
                    || ascii.IndexOf(expectedPath, StringComparison.OrdinalIgnoreCase) >= 0;
            }
            catch
            {
                return false;
            }
        }

        private void VerifyRegistration(string installDir)
        {
            string expected = Path.GetFullPath(installDir).TrimEnd(Path.DirectorySeparatorChar);
            string registered = InstallRegistration.ReadRegisteredInstallDirectory();
            string startup = InstallRegistration.ReadStartupInstallDirectory();
            if (!string.Equals(expected, registered, StringComparison.OrdinalIgnoreCase)
                || !string.Equals(expected, startup, StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException(
                    "Windows startup registration does not point to the selected installation directory.");
            }
            Log("Verified Windows startup and uninstall registration.");
        }

        private static void CreateShortcut(string shortcutPath, string target, string arguments, string workingDirectory, string description)
        {
            Type shellType = Type.GetTypeFromProgID("WScript.Shell");
            if (shellType == null) throw new InvalidOperationException("WScript.Shell is unavailable.");
            object shellObject = Activator.CreateInstance(shellType);
            dynamic shell = shellObject;
            dynamic shortcut = shell.CreateShortcut(shortcutPath);
            shortcut.TargetPath = target;
            shortcut.Arguments = arguments;
            shortcut.WorkingDirectory = workingDirectory;
            shortcut.Description = description;
            shortcut.IconLocation = target + ",0";
            shortcut.Save();
            Marshal.FinalReleaseComObject(shortcut);
            Marshal.FinalReleaseComObject(shellObject);
        }

        private void RegisterUninstaller(InstallOptions options)
        {
            string uninstaller = Path.Combine(options.InstallDir, "DockerCodexSuite-Uninstall.exe");
            string current = Application.ExecutablePath;
            if (!string.Equals(Path.GetFullPath(current), Path.GetFullPath(uninstaller), StringComparison.OrdinalIgnoreCase))
            {
                File.Copy(current, uninstaller, true);
            }

            using (RegistryKey key = Registry.CurrentUser.CreateSubKey("Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\DockerCodexSuite"))
            {
                key.SetValue("DisplayName", Program.ProductName);
                key.SetValue("DisplayVersion", Program.ProductVersion);
                key.SetValue("Publisher", "Docker Codex Suite Community");
                key.SetValue("InstallLocation", options.InstallDir);
                key.SetValue("DisplayIcon", Path.Combine(options.InstallDir, "DockerCodex.exe"));
                key.SetValue("UninstallString", Quote(uninstaller) + " --uninstall");
                key.SetValue("NoModify", 1, RegistryValueKind.DWord);
                key.SetValue("NoRepair", 1, RegistryValueKind.DWord);
            }
        }

        private void RegisterBridgeStartup(string installDir)
        {
            string launcher = Path.Combine(installDir, "DockerCodex.exe");
            using (RegistryKey key = Registry.CurrentUser.CreateSubKey(
                "Software\\Microsoft\\Windows\\CurrentVersion\\Run"))
            {
                key.SetValue("DockerCodexSuiteBridge", Quote(launcher) + " --bridge", RegistryValueKind.String);
            }
            Log("Registered the Docker API menu bridge for Windows sign-in.");
        }

        private void BuildAndStartDocker(string dockerDir)
        {
            string docker = EnvironmentDetector.DockerExecutableForInstall();
            if (string.IsNullOrEmpty(docker))
            {
                throw new InvalidOperationException("Docker Desktop is required (docker.exe was not found).");
            }
            Log("Building and starting the Docker Codex container. This can take several minutes...");
            RunProcess(docker, "compose up -d --build", dockerDir, true);
            Log("Docker container started.");
        }

        private void RestartExistingCodexContainer(InstallOptions options)
        {
            ContainerDetection verified = EnvironmentDetector.InspectContainerForInstall(options.ContainerName);
            if (verified == null || !verified.CodexInstalled)
            {
                throw new InvalidOperationException(
                    "Refusing to restart " + options.ContainerName + " because Codex CLI could not be confirmed.");
            }

            string docker = EnvironmentDetector.DockerExecutableForInstall();
            string workingDirectory = Directory.Exists(options.DockerDir)
                ? options.DockerDir
                : UserPaths.Profile();
            Log("Restarting the reused Docker Codex container " + options.ContainerName + "...");
            RunProcess(docker, "restart --timeout 1 " + options.ContainerName, workingDirectory, true);

            ContainerDetection restarted = EnvironmentDetector.InspectContainerForInstall(options.ContainerName);
            if (restarted == null
                || !restarted.CodexInstalled
                || !string.Equals(restarted.Status, "running", StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException(
                    "The reused Docker Codex container did not return to a verified running state after restart.");
            }
            Log("Reused Docker Codex container restarted; no rebuild or compose up was performed.");
        }

        private void RestartStandaloneBridge(string installDir)
        {
            string launcher = Path.Combine(installDir, "DockerCodex.exe");
            if (!File.Exists(launcher))
            {
                throw new FileNotFoundException("Docker Codex launcher is missing.", launcher);
            }
            Log("Starting the persistent Docker API menu bridge...");
            // The bridge leaves a persistent Node child behind. Do not give it
            // redirected installer pipes, or asynchronous stream draining never reaches EOF.
            RunProcess(launcher, "--bridge-restart-migrate", installDir, true, false, 30000);
            Log("Docker API menu bridge is running.");
        }

        internal void RestartStandaloneBridgeForTesting(string installDir)
        {
            RestartStandaloneBridge(installDir);
        }

        private void RunProcess(
            string executable,
            string arguments,
            string workingDirectory,
            bool failOnNonZero,
            bool captureOutput = true,
            int timeoutMilliseconds = 0)
        {
            ProcessStartInfo info = new ProcessStartInfo();
            info.FileName = executable;
            info.Arguments = arguments;
            info.WorkingDirectory = workingDirectory;
            info.UseShellExecute = false;
            info.CreateNoWindow = true;
            info.RedirectStandardOutput = captureOutput;
            info.RedirectStandardError = captureOutput;
            if (captureOutput)
            {
                info.StandardOutputEncoding = Encoding.UTF8;
                info.StandardErrorEncoding = Encoding.UTF8;
            }

            using (Process process = new Process())
            {
                process.StartInfo = info;
                if (captureOutput)
                {
                    process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs eventArgs)
                    {
                        if (!string.IsNullOrWhiteSpace(eventArgs.Data)) Log(eventArgs.Data);
                    };
                    process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs eventArgs)
                    {
                        if (!string.IsNullOrWhiteSpace(eventArgs.Data)) Log(eventArgs.Data);
                    };
                }
                process.Start();
                if (captureOutput)
                {
                    process.BeginOutputReadLine();
                    process.BeginErrorReadLine();
                }
                bool exited = true;
                if (timeoutMilliseconds <= 0)
                {
                    process.WaitForExit();
                }
                else
                {
                    exited = process.WaitForExit(timeoutMilliseconds);
                }
                if (!exited)
                {
                    try { process.Kill(); }
                    catch { }
                    throw new TimeoutException(
                        Path.GetFileName(executable) + " did not exit within " + timeoutMilliseconds + " ms.");
                }
                if (captureOutput) process.WaitForExit();
                if (failOnNonZero && process.ExitCode != 0)
                {
                    throw new InvalidOperationException(Path.GetFileName(executable) + " exited with code " + process.ExitCode + ".");
                }
            }
        }

        private void CopyTemplate(string source, string destination)
        {
            if (!File.Exists(source)) throw new FileNotFoundException("Missing Docker template.", source);
            WriteWithBackup(destination, File.ReadAllText(source, Encoding.UTF8));
        }

        private void WriteWithBackup(string path, string content)
        {
            if (File.Exists(path))
            {
                string existing = File.ReadAllText(path, Encoding.UTF8);
                if (!string.Equals(existing, content, StringComparison.Ordinal))
                {
                    string backup = path + ".backup-" + DateTime.Now.ToString("yyyyMMdd-HHmmss");
                    File.Copy(path, backup, false);
                    Log("Backed up existing file: " + backup);
                }
            }
            WriteUtf8(path, content);
        }

        private static string EscapeYaml(string value)
        {
            return value.Replace("\\", "\\\\").Replace("\"", "\\\"");
        }

        private static string FindExecutable(string name, string preferredDirectory)
        {
            if (!string.IsNullOrEmpty(preferredDirectory))
            {
                string preferred = Path.Combine(preferredDirectory, name);
                if (File.Exists(preferred)) return preferred;
            }
            string path = Environment.GetEnvironmentVariable("PATH") ?? "";
            foreach (string directory in path.Split(Path.PathSeparator))
            {
                try
                {
                    string candidate = Path.Combine(directory.Trim(), name);
                    if (File.Exists(candidate)) return candidate;
                }
                catch
                {
                }
            }
            return "";
        }

        private static void WriteUtf8(string path, string text)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path));
            File.WriteAllText(path, text, new UTF8Encoding(false));
        }

        private static string Quote(string value)
        {
            return "\"" + value.Replace("\"", "\\\"") + "\"";
        }

        private void Log(string message)
        {
            string line = "[" + DateTime.Now.ToString("HH:mm:ss") + "] " + message;
            report(line);
            if (!string.IsNullOrEmpty(installLogPath))
            {
                try
                {
                    File.AppendAllText(installLogPath, line + Environment.NewLine, new UTF8Encoding(false));
                }
                catch
                {
                }
            }
        }

        internal static int Uninstall(bool silent)
        {
            if (!silent)
            {
                DialogResult result = MessageBox.Show(
                    "卸载控制器和快捷方式？Docker 目录、工作区、SSH 密钥和 API 配置将保留。",
                    Program.ProductName,
                    MessageBoxButtons.YesNo,
                    MessageBoxIcon.Question);
                if (result != DialogResult.Yes) return 0;
            }

            string currentDir = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
            string registeredDir = InstallRegistration.ReadRegisteredInstallDirectory();
            string startupDir = InstallRegistration.ReadStartupInstallDirectory();
            string installDir = "";
            if (InstallRegistration.IsSuiteInstallDirectory(registeredDir)
                && string.Equals(currentDir, registeredDir, StringComparison.OrdinalIgnoreCase))
            {
                installDir = registeredDir;
            }
            else if (InstallRegistration.IsSuiteInstallDirectory(startupDir)
                && string.Equals(currentDir, startupDir, StringComparison.OrdinalIgnoreCase))
            {
                installDir = startupDir;
            }
            else
            {
                string message =
                    "拒绝卸载：当前卸载程序不是 Windows 注册的 Docker Codex Suite 安装目录。\r\n\r\n"
                    + "请从“应用和功能”或当前安装目录中的 DockerCodexSuite-Uninstall.exe 启动卸载。";
                if (!silent) MessageBox.Show(message, Program.ProductName, MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return 1;
            }
            string launcher = Path.Combine(installDir, "DockerCodex.exe");
            string shortcuts = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "Microsoft", "Windows", "Start Menu", "Programs", Program.ProductName);
            try
            {
                if (File.Exists(launcher))
                {
                    try
                    {
                        ProcessStartInfo stopBridge = new ProcessStartInfo();
                        stopBridge.FileName = launcher;
                        stopBridge.Arguments = "--bridge-stop";
                        stopBridge.WorkingDirectory = installDir;
                        stopBridge.UseShellExecute = false;
                        stopBridge.CreateNoWindow = true;
                        using (Process process = Process.Start(stopBridge))
                        {
                            if (process != null) process.WaitForExit(10000);
                        }
                    }
                    catch
                    {
                    }
                }
                if (Directory.Exists(shortcuts)) Directory.Delete(shortcuts, true);
                Registry.CurrentUser.DeleteSubKeyTree("Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\DockerCodexSuite", false);
                using (RegistryKey runKey = Registry.CurrentUser.OpenSubKey(
                    "Software\\Microsoft\\Windows\\CurrentVersion\\Run",
                    true))
                {
                    if (runKey != null) runKey.DeleteValue("DockerCodexSuiteBridge", false);
                }

                string sshConfig = Path.Combine(UserPaths.Profile(), ".ssh", "config");
                if (File.Exists(sshConfig))
                {
                    string text = File.ReadAllText(sshConfig, Encoding.UTF8);
                    File.WriteAllText(sshConfig, RemoveManagedSshBlock(text), new UTF8Encoding(false));
                }

                try
                {
                    ManagedSkillInstaller.UninstallIfUnmodified(UserPaths.CodexHome(), null);
                }
                catch
                {
                    // A locked or user-controlled skill must not block removal of the controller.
                }

                StartUninstallCompletionHelper(installDir);
                return 0;
            }
            catch (Exception exception)
            {
                if (!silent) MessageBox.Show(exception.Message, Program.ProductName, MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 1;
            }
        }

        private static void StartUninstallCompletionHelper(string installDir)
        {
            string helperPath = Path.Combine(
                Path.GetTempPath(),
                "DockerCodexSuite-Uninstall-" + Guid.NewGuid().ToString("N") + ".exe");
            File.Copy(Application.ExecutablePath, helperPath, true);

            ProcessStartInfo helper = new ProcessStartInfo();
            helper.FileName = helperPath;
            helper.Arguments = "--uninstall-complete " + Quote(installDir);
            helper.WorkingDirectory = Path.GetTempPath();
            helper.UseShellExecute = false;
            helper.CreateNoWindow = true;
            helper.WindowStyle = ProcessWindowStyle.Hidden;
            Process process = Process.Start(helper);
            if (process == null)
            {
                throw new InvalidOperationException("Unable to start the uninstall completion helper.");
            }
            process.Dispose();
        }

        internal static int CompleteUninstall(string installDir)
        {
            string target;
            try
            {
                target = Path.GetFullPath(installDir ?? "").TrimEnd(Path.DirectorySeparatorChar);
                if (string.IsNullOrWhiteSpace(target) || Path.GetPathRoot(target) == target)
                {
                    throw new InvalidOperationException("The uninstall target directory is invalid.");
                }
            }
            catch (Exception exception)
            {
                MessageBox.Show(exception.Message, Program.ProductName, MessageBoxButtons.OK, MessageBoxIcon.Error);
                ScheduleCompletionHelperDeletion(Application.ExecutablePath);
                return 1;
            }

            Exception lastError = null;
            for (int attempt = 0; attempt < 80 && Directory.Exists(target); attempt++)
            {
                try
                {
                    Directory.Delete(target, true);
                }
                catch (Exception exception)
                {
                    lastError = exception;
                    System.Threading.Thread.Sleep(250);
                }
            }

            if (Directory.Exists(target))
            {
                string detail = lastError == null ? "未知错误" : lastError.Message;
                MessageBox.Show(
                    "卸载未完成，安装目录仍被占用：\r\n" + target + "\r\n\r\n" + detail,
                    Program.ProductName,
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
                ScheduleCompletionHelperDeletion(Application.ExecutablePath);
                return 1;
            }

            MessageBox.Show(
                "Docker Codex Suite 已卸载完成。\r\n\r\nDocker 目录、工作区、SSH 密钥和 API 配置已保留。",
                Program.ProductName,
                MessageBoxButtons.OK,
                MessageBoxIcon.Information);
            ScheduleCompletionHelperDeletion(Application.ExecutablePath);
            return 0;
        }

        private static void ScheduleCompletionHelperDeletion(string helperPath)
        {
            try
            {
                ProcessStartInfo cleanup = new ProcessStartInfo();
                cleanup.FileName = "cmd.exe";
                cleanup.Arguments = "/d /c ping 127.0.0.1 -n 3 >nul & del /f /q " + Quote(helperPath);
                cleanup.WorkingDirectory = Path.GetTempPath();
                cleanup.UseShellExecute = false;
                cleanup.CreateNoWindow = true;
                cleanup.WindowStyle = ProcessWindowStyle.Hidden;
                Process process = Process.Start(cleanup);
                if (process != null) process.Dispose();
            }
            catch
            {
            }
        }
    }

    internal sealed class CodexPalette
    {
        internal bool IsDark;
        internal Color Window;
        internal Color Surface;
        internal Color SurfaceAlt;
        internal Color Input;
        internal Color Text;
        internal Color Muted;
        internal Color Border;
        internal Color Primary;
        internal Color PrimaryText;
        internal Color Success;
        internal Color Warning;
        internal Color WarningSurface;

        internal static CodexPalette Current()
        {
            bool isDark = ReadDarkMode();
            if (isDark)
            {
                return new CodexPalette
                {
                    IsDark = true,
                    Window = Color.FromArgb(24, 24, 24),
                    Surface = Color.FromArgb(33, 33, 33),
                    SurfaceAlt = Color.FromArgb(48, 48, 48),
                    Input = Color.FromArgb(33, 33, 33),
                    Text = Color.FromArgb(237, 237, 237),
                    Muted = Color.FromArgb(175, 175, 175),
                    Border = Color.FromArgb(52, 52, 52),
                    Primary = Color.FromArgb(237, 237, 237),
                    PrimaryText = Color.FromArgb(13, 13, 13),
                    Success = Color.FromArgb(105, 197, 158),
                    Warning = Color.FromArgb(231, 190, 124),
                    WarningSurface = Color.FromArgb(43, 37, 26)
                };
            }

            return new CodexPalette
            {
                IsDark = false,
                Window = Color.FromArgb(249, 249, 249),
                Surface = Color.White,
                SurfaceAlt = Color.FromArgb(243, 243, 243),
                Input = Color.White,
                Text = Color.FromArgb(13, 13, 13),
                Muted = Color.FromArgb(93, 93, 93),
                Border = Color.FromArgb(229, 229, 229),
                Primary = Color.FromArgb(13, 13, 13),
                PrimaryText = Color.White,
                Success = Color.FromArgb(35, 126, 91),
                Warning = Color.FromArgb(126, 82, 18),
                WarningSurface = Color.FromArgb(255, 247, 232)
            };
        }

        private static bool ReadDarkMode()
        {
            string preference = Environment.GetEnvironmentVariable("DOCKER_CODEX_THEME") ?? "";
            if (string.Equals(preference, "dark", StringComparison.OrdinalIgnoreCase)) return true;
            if (string.Equals(preference, "light", StringComparison.OrdinalIgnoreCase)) return false;

            try
            {
                using (RegistryKey key = Registry.CurrentUser.OpenSubKey(
                    "Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"))
                {
                    object value = key == null ? null : key.GetValue("AppsUseLightTheme");
                    if (value != null) return Convert.ToInt32(value) == 0;
                }
            }
            catch
            {
            }
            return false;
        }
    }

    internal static class CodexTheme
    {
        [DllImport("dwmapi.dll")]
        private static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size);

        internal static Font Font(float size, FontStyle style)
        {
            Font font = new Font("Segoe UI Variable Text", size, style, GraphicsUnit.Point);
            if (string.Equals(font.Name, "Segoe UI Variable Text", StringComparison.OrdinalIgnoreCase)) return font;
            font.Dispose();
            return new Font("Segoe UI", size, style, GraphicsUnit.Point);
        }

        internal static void ApplyTitleBar(Form form, bool dark)
        {
            if (!form.IsHandleCreated) return;
            int enabled = dark ? 1 : 0;
            try
            {
                if (DwmSetWindowAttribute(form.Handle, 20, ref enabled, sizeof(int)) != 0)
                {
                    DwmSetWindowAttribute(form.Handle, 19, ref enabled, sizeof(int));
                }
            }
            catch
            {
            }
        }
    }

    internal sealed class CodexButton : Button
    {
        private bool hovered;
        private bool pressed;

        internal int CornerRadius { get; set; }
        internal Color BorderColor { get; set; }
        internal Color HoverBackColor { get; set; }
        internal Color PressedBackColor { get; set; }
        internal Color DisabledBackColor { get; set; }
        internal Color DisabledForeColor { get; set; }
        internal Color DisabledBorderColor { get; set; }

        internal CodexButton()
        {
            CornerRadius = 6;
            BorderColor = Color.Black;
            HoverBackColor = Color.Gainsboro;
            PressedBackColor = Color.Silver;
            DisabledBackColor = Color.Gainsboro;
            DisabledForeColor = Color.Gray;
            DisabledBorderColor = Color.Silver;
            FlatStyle = FlatStyle.Flat;
            FlatAppearance.BorderSize = 0;
            UseVisualStyleBackColor = false;
            SetStyle(
                ControlStyles.UserPaint
                | ControlStyles.AllPaintingInWmPaint
                | ControlStyles.OptimizedDoubleBuffer
                | ControlStyles.ResizeRedraw,
                true);
        }

        protected override void OnPaint(PaintEventArgs eventArgs)
        {
            Graphics graphics = eventArgs.Graphics;
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            graphics.Clear(Parent == null ? BackColor : Parent.BackColor);

            Rectangle bounds = new Rectangle(0, 0, Math.Max(1, Width - 1), Math.Max(1, Height - 1));
            Color fill = !Enabled
                ? DisabledBackColor
                : pressed
                    ? PressedBackColor
                    : hovered ? HoverBackColor : BackColor;
            Color border = Enabled ? BorderColor : DisabledBorderColor;
            Color text = Enabled ? ForeColor : DisabledForeColor;

            using (GraphicsPath path = CreateRoundedPath(bounds, CornerRadius))
            using (SolidBrush brush = new SolidBrush(fill))
            using (Pen pen = new Pen(border, 1F))
            {
                graphics.FillPath(brush, path);
                graphics.DrawPath(pen, path);
            }

            TextFormatFlags flags = TextFormatFlags.HorizontalCenter
                | TextFormatFlags.VerticalCenter
                | TextFormatFlags.SingleLine
                | TextFormatFlags.EndEllipsis
                | TextFormatFlags.NoPadding;
            if (!UseMnemonic) flags |= TextFormatFlags.NoPrefix;
            TextRenderer.DrawText(graphics, Text, Font, ClientRectangle, text, flags);

            if (Focused && ShowFocusCues && Width > 10 && Height > 10)
            {
                Rectangle focusBounds = new Rectangle(4, 4, Width - 9, Height - 9);
                using (GraphicsPath focusPath = CreateRoundedPath(focusBounds, Math.Max(2, CornerRadius - 2)))
                using (Pen focusPen = new Pen(text, 1F))
                {
                    focusPen.DashStyle = DashStyle.Dot;
                    graphics.DrawPath(focusPen, focusPath);
                }
            }
        }

        private static GraphicsPath CreateRoundedPath(Rectangle bounds, int radius)
        {
            GraphicsPath path = new GraphicsPath();
            int safeRadius = Math.Max(1, Math.Min(radius, Math.Min(bounds.Width, bounds.Height) / 2));
            int diameter = safeRadius * 2;
            Rectangle arc = new Rectangle(bounds.Location, new Size(diameter, diameter));
            path.AddArc(arc, 180F, 90F);
            arc.X = bounds.Right - diameter;
            path.AddArc(arc, 270F, 90F);
            arc.Y = bounds.Bottom - diameter;
            path.AddArc(arc, 0F, 90F);
            arc.X = bounds.Left;
            path.AddArc(arc, 90F, 90F);
            path.CloseFigure();
            return path;
        }

        protected override void OnMouseEnter(EventArgs eventArgs)
        {
            hovered = true;
            Invalidate();
            base.OnMouseEnter(eventArgs);
        }

        protected override void OnMouseLeave(EventArgs eventArgs)
        {
            hovered = false;
            pressed = false;
            Invalidate();
            base.OnMouseLeave(eventArgs);
        }

        protected override void OnMouseDown(MouseEventArgs eventArgs)
        {
            if (eventArgs.Button == MouseButtons.Left) pressed = true;
            Invalidate();
            base.OnMouseDown(eventArgs);
        }

        protected override void OnMouseUp(MouseEventArgs eventArgs)
        {
            pressed = false;
            Invalidate();
            base.OnMouseUp(eventArgs);
        }

        protected override void OnEnabledChanged(EventArgs eventArgs)
        {
            Invalidate();
            base.OnEnabledChanged(eventArgs);
        }
    }

    internal sealed class InstallerForm : Form
    {
        private readonly TextBox installDirText;
        private readonly TextBox dockerDirText;
        private readonly TextBox workspaceDirText;
        private readonly Label subtitleLabel;
        private readonly Label detectionLabel;
        private readonly Label warningLabel;
        private readonly Panel detectionPanel;
        private readonly Panel warningPanel;
        private readonly Panel logFrame;
        private readonly Button redetectButton;
        private readonly NumericUpDown portInput;
        private readonly CheckBox stopExistingCheck;
        private readonly CheckBox buildDockerCheck;
        private readonly CheckBox launchCheck;
        private readonly Button installButton;
        private readonly ProgressBar progress;
        private readonly RichTextBox logBox;
        private readonly List<Button> secondaryButtons = new List<Button>();
        private InstallOptions detectedOptions;
        private CodexPalette palette;

        internal InstallerForm()
        {
            Text = Program.ProductName + " 安装程序";
            StartPosition = FormStartPosition.CenterScreen;
            ClientSize = new Size(860, 780);
            MinimumSize = new Size(800, 700);
            AutoScaleMode = AutoScaleMode.Dpi;
            Font = CodexTheme.Font(9F, FontStyle.Regular);
            DoubleBuffered = true;
            palette = CodexPalette.Current();

            TableLayoutPanel root = new TableLayoutPanel();
            root.Dock = DockStyle.Fill;
            root.Padding = new Padding(28, 18, 28, 18);
            root.ColumnCount = 1;
            root.RowCount = 7;
            root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
            root.RowStyles.Add(new RowStyle(SizeType.Absolute, 72F));
            root.RowStyles.Add(new RowStyle(SizeType.Absolute, 194F));
            root.RowStyles.Add(new RowStyle(SizeType.Absolute, 58F));
            root.RowStyles.Add(new RowStyle(SizeType.Absolute, 108F));
            root.RowStyles.Add(new RowStyle(SizeType.Absolute, 58F));
            root.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));
            root.RowStyles.Add(new RowStyle(SizeType.Absolute, 52F));
            Controls.Add(root);

            Panel header = new Panel();
            header.Dock = DockStyle.Fill;
            header.Margin = new Padding(0);
            root.Controls.Add(header, 0, 0);

            Label title = new Label();
            title.Text = "Docker Codex Suite";
            title.Font = CodexTheme.Font(20F, FontStyle.Bold);
            title.AutoSize = true;
            title.Location = new Point(0, 0);
            header.Controls.Add(title);

            subtitleLabel = new Label();
            subtitleLabel.Text = "安装控制器与独立 Docker Codex 工作环境";
            subtitleLabel.Font = CodexTheme.Font(9.5F, FontStyle.Regular);
            subtitleLabel.AutoSize = true;
            subtitleLabel.Location = new Point(2, 42);
            header.Controls.Add(subtitleLabel);

            Panel pathPanel = new Panel();
            pathPanel.Dock = DockStyle.Fill;
            pathPanel.Margin = new Padding(0);
            root.Controls.Add(pathPanel, 0, 1);

            InstallOptions defaults = InstallOptions.Defaults();
            installDirText = AddPathRow(pathPanel, "控制器安装目录", defaults.InstallDir, 0, BrowseFolder);
            dockerDirText = AddPathRow(pathPanel, "Docker 方案目录", defaults.DockerDir, 62, BrowseFolder);
            workspaceDirText = AddPathRow(pathPanel, "容器可访问工作区", defaults.WorkspaceDir, 124, BrowseFolder);

            detectionPanel = new Panel();
            detectionPanel.Dock = DockStyle.Fill;
            detectionPanel.Margin = new Padding(0, 3, 0, 7);
            root.Controls.Add(detectionPanel, 0, 2);

            detectionLabel = new Label();
            detectionLabel.Location = new Point(12, 8);
            detectionLabel.Size = new Size(650, 36);
            detectionLabel.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;
            detectionLabel.AutoEllipsis = true;
            detectionPanel.Controls.Add(detectionLabel);

            redetectButton = new CodexButton();
            redetectButton.Text = "重新检测";
            redetectButton.Location = new Point(692, 7);
            redetectButton.Size = new Size(100, 32);
            redetectButton.Anchor = AnchorStyles.Top | AnchorStyles.Right;
            redetectButton.Click += RedetectButtonClick;
            detectionPanel.Controls.Add(redetectButton);
            secondaryButtons.Add(redetectButton);

            Panel optionsPanel = new Panel();
            optionsPanel.Dock = DockStyle.Fill;
            optionsPanel.Margin = new Padding(0);
            root.Controls.Add(optionsPanel, 0, 3);

            AddLabel(optionsPanel, "本机 SSH 端口", 0, 8);
            portInput = new NumericUpDown();
            portInput.Location = new Point(0, 34);
            portInput.Width = 140;
            portInput.Minimum = 1024;
            portInput.Maximum = 65535;
            portInput.Value = 2223;
            optionsPanel.Controls.Add(portInput);

            stopExistingCheck = new CheckBox();
            stopExistingCheck.AutoSize = true;
            stopExistingCheck.Location = new Point(182, 7);
            stopExistingCheck.AutoCheck = false;
            stopExistingCheck.TabStop = false;
            stopExistingCheck.Visible = false;
            optionsPanel.Controls.Add(stopExistingCheck);

            buildDockerCheck = new CheckBox();
            buildDockerCheck.Text = "安装后构建并启动 Docker 容器（首次可能需要数分钟）";
            buildDockerCheck.AutoSize = true;
            buildDockerCheck.Location = new Point(182, 36);
            buildDockerCheck.CheckedChanged += BuildDockerCheckChanged;
            optionsPanel.Controls.Add(buildDockerCheck);

            launchCheck = new CheckBox();
            launchCheck.Text = "安装完成后启动 Docker Codex Suite（打开切换器）";
            launchCheck.AutoSize = true;
            launchCheck.Location = new Point(182, 65);
            optionsPanel.Controls.Add(launchCheck);

            warningPanel = new Panel();
            warningPanel.Dock = DockStyle.Fill;
            warningPanel.Margin = new Padding(0, 0, 0, 8);
            warningPanel.Padding = new Padding(12, 8, 12, 8);
            root.Controls.Add(warningPanel, 0, 4);

            warningLabel = new Label();
            warningLabel.Text = "安全提示：SSH 仅绑定 127.0.0.1；容器拥有 SYS_ADMIN 且可读写所选工作区。安装包不包含任何 API Key 或 auth.json。";
            warningLabel.Dock = DockStyle.Fill;
            warningLabel.AutoEllipsis = true;
            warningLabel.TextAlign = ContentAlignment.MiddleLeft;
            warningPanel.Controls.Add(warningLabel);

            Panel logSection = new Panel();
            logSection.Dock = DockStyle.Fill;
            logSection.Margin = new Padding(0);
            root.Controls.Add(logSection, 0, 5);

            Label logLabel = new Label();
            logLabel.Text = "安装日志";
            logLabel.Font = CodexTheme.Font(9.5F, FontStyle.Bold);
            logLabel.AutoSize = true;
            logLabel.Location = new Point(0, 0);
            logSection.Controls.Add(logLabel);

            logFrame = new Panel();
            logFrame.Location = new Point(0, 27);
            logFrame.Size = new Size(804, 145);
            logFrame.Anchor = AnchorStyles.Top | AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right;
            logFrame.Padding = new Padding(1);
            logSection.Controls.Add(logFrame);

            logBox = new RichTextBox();
            logBox.Dock = DockStyle.Fill;
            logBox.ReadOnly = true;
            logBox.BorderStyle = BorderStyle.None;
            logBox.Font = new Font("Consolas", 8.5F);
            logBox.DetectUrls = false;
            logFrame.Controls.Add(logBox);

            Panel footer = new Panel();
            footer.Dock = DockStyle.Fill;
            footer.Margin = new Padding(0);
            root.Controls.Add(footer, 0, 6);

            progress = new ProgressBar();
            progress.Location = new Point(0, 17);
            progress.Size = new Size(628, 18);
            progress.Anchor = AnchorStyles.Left | AnchorStyles.Right | AnchorStyles.Top;
            progress.Visible = false;
            footer.Controls.Add(progress);

            installButton = new CodexButton();
            installButton.Text = "安装";
            installButton.Font = CodexTheme.Font(9.5F, FontStyle.Bold);
            installButton.Location = new Point(650, 7);
            installButton.Size = new Size(154, 38);
            installButton.Anchor = AnchorStyles.Top | AnchorStyles.Right;
            installButton.Click += InstallButtonClick;
            footer.Controls.Add(installButton);

            ApplyDetectedOptions(defaults);
            ApplyTheme();
        }

        private Label AddLabel(Control parent, string text, int left, int top)
        {
            Label label = new Label();
            label.Text = text;
            label.AutoSize = true;
            label.Location = new Point(left, top);
            parent.Controls.Add(label);
            return label;
        }

        private TextBox AddPathRow(Control parent, string labelText, string defaultValue, int top, EventHandler browseHandler)
        {
            AddLabel(parent, labelText, 0, top);
            TextBox textBox = new TextBox();
            textBox.Text = defaultValue;
            textBox.Location = new Point(0, top + 25);
            textBox.Size = new Size(696, 28);
            textBox.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;
            parent.Controls.Add(textBox);

            Button browse = new CodexButton();
            browse.Text = "浏览";
            browse.Tag = textBox;
            browse.Location = new Point(714, top + 23);
            browse.Size = new Size(90, 32);
            browse.Anchor = AnchorStyles.Top | AnchorStyles.Right;
            browse.Click += browseHandler;
            parent.Controls.Add(browse);
            secondaryButtons.Add(browse);
            return textBox;
        }

        private void BrowseFolder(object sender, EventArgs eventArgs)
        {
            Button button = (Button)sender;
            TextBox target = (TextBox)button.Tag;
            using (FolderBrowserDialog dialog = new FolderBrowserDialog())
            {
                dialog.SelectedPath = target.Text;
                dialog.ShowNewFolderButton = true;
                if (dialog.ShowDialog(this) == DialogResult.OK) target.Text = dialog.SelectedPath;
            }
        }

        private void RedetectButtonClick(object sender, EventArgs eventArgs)
        {
            ToggleControls(false);
            detectionLabel.Text = "自动检测：正在检查已有 Docker 环境...";
            detectionLabel.ForeColor = palette.Muted;
            progress.Visible = true;
            progress.Style = ProgressBarStyle.Marquee;

            BackgroundWorker worker = new BackgroundWorker();
            worker.DoWork += delegate(object workerSender, DoWorkEventArgs workArgs)
            {
                workArgs.Result = InstallOptions.Defaults(true);
            };
            worker.RunWorkerCompleted += delegate(object workerSender, RunWorkerCompletedEventArgs completeArgs)
            {
                progress.Style = ProgressBarStyle.Blocks;
                progress.Visible = false;
                ToggleControls(true);
                if (completeArgs.Error != null)
                {
                    detectionLabel.Text = "自动检测失败，当前路径未更改";
                    detectionLabel.ForeColor = palette.Warning;
                    AppendLog(completeArgs.Error.Message);
                    return;
                }

                InstallOptions detected = (InstallOptions)completeArgs.Result;
                ApplyDetectedOptions(detected);
                AppendLog(detected.DetectionSummary);
            };
            worker.RunWorkerAsync();
        }

        private void SetDetectionState(InstallOptions options)
        {
            detectionLabel.Text = options.DetectionSummary;
            detectionLabel.ForeColor = options.DockerDaemonAvailable && !options.ContainerSelectionBlocked
                ? palette.Success
                : palette.Warning;
        }

        private void ApplyDetectedOptions(InstallOptions options)
        {
            detectedOptions = options;
            installDirText.Text = options.InstallDir;
            dockerDirText.Text = options.DockerDir;
            workspaceDirText.Text = options.WorkspaceDir;
            portInput.Value = Math.Max(portInput.Minimum, Math.Min(portInput.Maximum, options.SshPort));
            buildDockerCheck.Checked = options.BuildDocker;
            buildDockerCheck.Visible = !options.ReuseExistingContainer;
            stopExistingCheck.Visible = options.ReuseExistingContainer;
            stopExistingCheck.Text = options.ReuseExistingContainer
                ? "仅复用 Codex 容器 " + options.ContainerName + "（安装后只重启，不重建）"
                : "";
            stopExistingCheck.Checked = options.ReuseExistingContainer;
            SetDetectionState(options);
            UpdateRuntimeControls(true);
        }

        private void BuildDockerCheckChanged(object sender, EventArgs eventArgs)
        {
            if (detectedOptions == null) return;
            stopExistingCheck.Checked = detectedOptions.ReuseExistingContainer;
        }

        private void UpdateRuntimeControls(bool enabled)
        {
            bool dockerReady = detectedOptions != null && detectedOptions.DockerDaemonAvailable;
            bool reuseExisting = detectedOptions != null && detectedOptions.ReuseExistingContainer;
            bool containerSelectionSafe = detectedOptions != null && !detectedOptions.ContainerSelectionBlocked;
            bool installDirectoryLocked = detectedOptions != null
                && !string.IsNullOrWhiteSpace(detectedOptions.ExistingInstallDir);
            installButton.Enabled = enabled && dockerReady && containerSelectionSafe;
            buildDockerCheck.Enabled = enabled && dockerReady && containerSelectionSafe && !reuseExisting;
            stopExistingCheck.Enabled = enabled && reuseExisting;
            installDirText.ReadOnly = installDirectoryLocked;
            installDirText.Enabled = enabled;
            dockerDirText.Enabled = enabled && !reuseExisting;
            workspaceDirText.Enabled = enabled && !reuseExisting;
            portInput.Enabled = enabled && !reuseExisting;
            foreach (Button button in secondaryButtons)
            {
                TextBox target = button.Tag as TextBox;
                button.Enabled = enabled
                    && (!installDirectoryLocked || target != installDirText)
                    && (!reuseExisting || (target != dockerDirText && target != workspaceDirText));
            }
            redetectButton.Enabled = enabled;
        }

        private void InstallButtonClick(object sender, EventArgs eventArgs)
        {
            InstallOptions options = InstallOptions.Defaults();
            string requestedInstallDir = Path.GetFullPath(installDirText.Text.Trim());
            options.InstallDir = InstallRegistration.ResolveUpgradeInstallDirectory(requestedInstallDir);
            options.DockerDir = Path.GetFullPath(dockerDirText.Text.Trim());
            options.WorkspaceDir = Path.GetFullPath(workspaceDirText.Text.Trim());
            options.SshPort = (int)portInput.Value;
            options.BuildDocker = !options.ReuseExistingContainer
                && !options.ContainerSelectionBlocked
                && options.ExistingCodexContainerCount == 0
                && buildDockerCheck.Checked;
            options.StopExistingContainer = false;
            options.LaunchAfter = launchCheck.Checked;
            bool launchAfterInstall = options.LaunchAfter;
            // The completion dialog owns the foreground window. Defer GUI launch
            // until the user closes it so Codex can actually become visible.
            options.LaunchAfter = false;

            installButton.Visible = false;
            ToggleControls(false);
            progress.Visible = true;
            progress.Style = ProgressBarStyle.Marquee;
            AppendLog("Starting installation...");

            BackgroundWorker worker = new BackgroundWorker();
            worker.DoWork += delegate(object workerSender, DoWorkEventArgs workArgs)
            {
                try
                {
                    InstallerEngine engine = new InstallerEngine(AppendLogThreadSafe);
                    engine.Install(options);
                    workArgs.Result = null;
                }
                catch (Exception exception)
                {
                    workArgs.Result = exception;
                }
            };
            worker.RunWorkerCompleted += delegate(object workerSender, RunWorkerCompletedEventArgs completeArgs)
            {
                progress.Style = ProgressBarStyle.Blocks;
                ToggleControls(true);
                Exception error = completeArgs.Result as Exception;
                if (error == null)
                {
                    progress.Value = 100;
                    MessageBox.Show(this, "安装完成。", Program.ProductName, MessageBoxButtons.OK, MessageBoxIcon.Information);
                    if (launchAfterInstall)
                    {
                        try
                        {
                            InstallerEngine.LaunchDockerCodexAfterInstall(options.InstallDir, AppendLog);
                        }
                        catch (Exception launchException)
                        {
                            AppendLog(launchException.ToString());
                            MessageBox.Show(this, launchException.Message, Program.ProductName, MessageBoxButtons.OK, MessageBoxIcon.Error);
                        }
                    }
                }
                else
                {
                    installButton.Visible = true;
                    progress.Visible = false;
                    AppendLog(error.ToString());
                    MessageBox.Show(this, error.Message, Program.ProductName, MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
            };
            worker.RunWorkerAsync();
        }

        private void ToggleControls(bool enabled)
        {
            installButton.Enabled = enabled;
            installDirText.Enabled = enabled;
            UpdateRuntimeControls(enabled);
            launchCheck.Enabled = enabled;
        }

        private void AppendLogThreadSafe(string line)
        {
            if (InvokeRequired)
            {
                BeginInvoke(new Action<string>(AppendLog), line);
            }
            else
            {
                AppendLog(line);
            }
        }

        private void AppendLog(string line)
        {
            logBox.AppendText(line + Environment.NewLine);
            logBox.SelectionStart = logBox.TextLength;
            logBox.ScrollToCaret();
        }

        private void ApplyTheme()
        {
            palette = CodexPalette.Current();
            BackColor = palette.Window;
            ForeColor = palette.Text;
            ApplyControlTheme(this);

            subtitleLabel.ForeColor = palette.Muted;
            detectionPanel.BackColor = palette.Surface;
            warningPanel.BackColor = palette.WarningSurface;
            warningLabel.BackColor = palette.WarningSurface;
            warningLabel.ForeColor = palette.Warning;
            logFrame.BackColor = palette.Border;
            logBox.BackColor = palette.Surface;
            logBox.ForeColor = palette.Text;

            foreach (Button button in secondaryButtons)
            {
                ApplyButtonTheme(button, false);
            }
            ApplyButtonTheme(installButton, true);

            if (detectedOptions != null) SetDetectionState(detectedOptions);
            CodexTheme.ApplyTitleBar(this, palette.IsDark);
            Invalidate(true);
        }

        private void ApplyControlTheme(Control parent)
        {
            foreach (Control control in parent.Controls)
            {
                control.ForeColor = palette.Text;
                if (control is Panel || control is TableLayoutPanel)
                {
                    control.BackColor = palette.Window;
                }
                else if (control is TextBox)
                {
                    TextBox textBox = (TextBox)control;
                    textBox.BackColor = palette.Input;
                    textBox.ForeColor = palette.Text;
                    textBox.BorderStyle = BorderStyle.FixedSingle;
                }
                else if (control is RichTextBox)
                {
                    RichTextBox richTextBox = (RichTextBox)control;
                    richTextBox.BackColor = palette.Surface;
                    richTextBox.ForeColor = palette.Text;
                }
                else if (control is NumericUpDown)
                {
                    control.BackColor = palette.Input;
                    control.ForeColor = palette.Text;
                }
                else if (control is CheckBox)
                {
                    control.BackColor = palette.Window;
                }
                else if (control is Label)
                {
                    control.BackColor = Color.Transparent;
                }

                if (control.HasChildren) ApplyControlTheme(control);
            }
        }

        private void ApplyButtonTheme(Button button, bool primary)
        {
            button.FlatStyle = FlatStyle.Flat;
            button.UseVisualStyleBackColor = false;
            button.Cursor = Cursors.Hand;
            button.FlatAppearance.BorderSize = 0;
            button.FlatAppearance.BorderColor = primary ? palette.Primary : palette.Text;
            button.FlatAppearance.MouseOverBackColor = primary ? palette.Muted : palette.SurfaceAlt;
            button.FlatAppearance.MouseDownBackColor = palette.Border;
            button.BackColor = primary ? palette.Primary : palette.Surface;
            button.ForeColor = primary ? palette.PrimaryText : palette.Text;

            CodexButton roundedButton = button as CodexButton;
            if (roundedButton != null)
            {
                roundedButton.CornerRadius = 6;
                roundedButton.BorderColor = primary ? palette.Primary : palette.Text;
                roundedButton.HoverBackColor = primary ? palette.Muted : palette.SurfaceAlt;
                roundedButton.PressedBackColor = primary ? palette.Primary : palette.Border;
                roundedButton.DisabledBackColor = palette.SurfaceAlt;
                roundedButton.DisabledForeColor = palette.Muted;
                roundedButton.DisabledBorderColor = palette.Border;
                roundedButton.Invalidate();
            }
        }

        protected override void OnShown(EventArgs eventArgs)
        {
            base.OnShown(eventArgs);
            CodexTheme.ApplyTitleBar(this, palette.IsDark);
        }

        protected override void WndProc(ref Message message)
        {
            base.WndProc(ref message);
            if ((message.Msg == 0x001A || message.Msg == 0x031A) && IsHandleCreated && !IsDisposed)
            {
                BeginInvoke(new Action(ApplyTheme));
            }
        }
    }
}

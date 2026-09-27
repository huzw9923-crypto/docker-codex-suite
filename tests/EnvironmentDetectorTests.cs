using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

namespace DockerCodexSuiteInstaller
{
    internal static class EnvironmentDetectorTests
    {
        private static int Main(string[] args)
        {
            int processHelperExitCode;
            if (TryRunPersistentProcessHelper(args, out processHelperExitCode))
            {
                return processHelperExitCode;
            }

            int fakeDockerExitCode;
            if (TryRunFakeDocker(args, out fakeDockerExitCode))
            {
                return fakeDockerExitCode;
            }

            int fakeToolExitCode;
            if (TryRunFakeTool(args, out fakeToolExitCode))
            {
                return fakeToolExitCode;
            }

            try
            {
                string testRoot = args.Length > 0
                    ? Path.GetFullPath(args[0])
                    : Path.Combine(Path.GetTempPath(), "DockerCodexSuite-detector-tests");
                Directory.CreateDirectory(testRoot);

                TestPreviousSettings(Path.Combine(testRoot, "settings"));
                TestMojibakeSettingsRecovery(Path.Combine(testRoot, "mojibake-settings"));
                TestComposeWorkspace(Path.Combine(testRoot, "compose"));
                TestDockerMetadata(Path.Combine(testRoot, "docker-metadata"));
                TestDockerUtf8ProcessOutput();
                TestContainerDiscoverySafety(Path.Combine(testRoot, "container-discovery"));
                TestPortDetection();
                TestInstallOptionsReusePolicy();
                TestControllerWindowDetection();
                TestPersistentBridgeProcessLifecycle(Path.Combine(testRoot, "bridge-process-lifecycle"));
                TestCodexHomeResolution(Path.Combine(testRoot, "codex-home-resolution"));
                TestInstallRegistration(Path.Combine(testRoot, "install-registration"));
                TestManagedSkillInstallation(Path.Combine(testRoot, "managed-skill"));
                TestPrerequisiteDetectAllInstalled(Path.Combine(testRoot, "prereq-installed"));
                TestPrerequisiteDetectMissing();
                TestWingetDetection();
                TestPrerequisiteInstallOneSkipsInstalled();

                if (args.Length >= 3)
                {
                    TestCurrentMachine(args[1], args[2]);
                    TestCurrentMachinePrerequisites();
                }

                Console.WriteLine("EnvironmentDetector tests passed.");
                return 0;
            }
            catch (Exception exception)
            {
                Console.Error.WriteLine(exception.ToString());
                return 1;
            }
        }

        private static bool TryRunPersistentProcessHelper(string[] args, out int exitCode)
        {
            exitCode = 0;
            if (args.Length == 0) return false;
            if (string.Equals(args[0], "--persistent-bridge-child", StringComparison.OrdinalIgnoreCase))
            {
                Thread.Sleep(3000);
                return true;
            }
            if (!string.Equals(args[0], "--bridge-restart-migrate", StringComparison.OrdinalIgnoreCase))
            {
                return false;
            }

            ProcessStartInfo child = new ProcessStartInfo();
            child.FileName = Assembly.GetExecutingAssembly().Location;
            child.Arguments = "--persistent-bridge-child";
            child.UseShellExecute = false;
            child.CreateNoWindow = true;
            Process.Start(child);
            Console.WriteLine("persistent bridge helper started");
            return true;
        }

        private static void TestPersistentBridgeProcessLifecycle(string root)
        {
            if (Directory.Exists(root)) Directory.Delete(root, true);
            Directory.CreateDirectory(root);
            string launcher = Path.Combine(root, "DockerCodex.exe");
            File.Copy(Assembly.GetExecutingAssembly().Location, launcher, true);

            Stopwatch watch = Stopwatch.StartNew();
            new InstallerEngine(null).RestartStandaloneBridgeForTesting(root);
            watch.Stop();
            AssertTrue(
                watch.ElapsedMilliseconds < 2000,
                "persistent bridge startup does not wait for inherited output handles");
        }

        private static void TestPreviousSettings(string root)
        {
            string dockerDir = Path.Combine(root, "existing-docker");
            string workspaceDir = Path.Combine(root, "existing-workspace");
            Directory.CreateDirectory(dockerDir);
            Directory.CreateDirectory(workspaceDir);

            Dictionary<string, object> settings = new Dictionary<string, object>();
            settings["composeDir"] = dockerDir;
            settings["workspaceDir"] = workspaceDir;
            string settingsPath = Path.Combine(root, "settings.json");
            Directory.CreateDirectory(root);
            File.WriteAllText(
                settingsPath,
                new JavaScriptSerializer().Serialize(settings),
                new UTF8Encoding(false));

            EnvironmentDetection detected = EnvironmentDetector.DetectForTesting(
                settingsPath,
                "",
                new string[0]);
            AssertPath(dockerDir, detected.DockerDir, "settings composeDir");
            AssertPath(workspaceDir, detected.WorkspaceDir, "settings workspaceDir");
            AssertTrue(detected.Summary.IndexOf("上次安装设置", StringComparison.Ordinal) >= 0, "settings source");
        }

        private static void TestComposeWorkspace(string root)
        {
            string dockerDir = Path.Combine(root, "codex-compose");
            string workspaceDir = Path.Combine(root, "workspace with spaces");
            Directory.CreateDirectory(dockerDir);
            Directory.CreateDirectory(workspaceDir);

            string compose =
                "services:\r\n" +
                "  codex-dev:\r\n" +
                "    volumes:\r\n" +
                "      - type: bind\r\n" +
                "        source: \"" + workspaceDir.Replace('\\', '/') + "\"\r\n" +
                "        target: /workspace/Documents\r\n";
            File.WriteAllText(Path.Combine(dockerDir, "compose.yml"), compose, new UTF8Encoding(false));

            EnvironmentDetection detected = EnvironmentDetector.DetectForTesting(
                Path.Combine(root, "missing-settings.json"),
                "",
                new[] { dockerDir });
            AssertPath(dockerDir, detected.DockerDir, "compose directory scan");
            AssertPath(workspaceDir, detected.WorkspaceDir, "compose workspace mount");
            AssertTrue(detected.Summary.IndexOf("现有 compose", StringComparison.Ordinal) >= 0, "compose source");
        }

        private static void TestMojibakeSettingsRecovery(string root)
        {
            string dockerDir = Path.Combine(root, "existing-docker");
            string workspaceDir = Path.Combine(root, "桌面文件", "codex_documents");
            string mojibakeWorkspace = Path.Combine(root, "妗岄潰鏂囦欢", "codex_documents");
            Directory.CreateDirectory(dockerDir);
            Directory.CreateDirectory(workspaceDir);

            string compose =
                "services:\r\n" +
                "  codex-dev:\r\n" +
                "    volumes:\r\n" +
                "      - type: bind\r\n" +
                "        source: \"" + workspaceDir.Replace('\\', '/') + "\"\r\n" +
                "        target: /workspace/Documents\r\n";
            File.WriteAllText(Path.Combine(dockerDir, "compose.yml"), compose, new UTF8Encoding(false));

            Dictionary<string, object> settings = new Dictionary<string, object>();
            settings["composeDir"] = dockerDir;
            settings["workspaceDir"] = mojibakeWorkspace;
            string settingsPath = Path.Combine(root, "settings.json");
            File.WriteAllText(
                settingsPath,
                new JavaScriptSerializer().Serialize(settings),
                new UTF8Encoding(false));

            EnvironmentDetection detected = EnvironmentDetector.DetectForTesting(
                settingsPath,
                "",
                new string[0]);
            AssertPath(dockerDir, detected.DockerDir, "mojibake recovery compose directory");
            AssertPath(workspaceDir, detected.WorkspaceDir, "mojibake recovery workspace");
        }

        private static void TestDockerMetadata(string root)
        {
            string dockerDir = Path.Combine(root, "codex-host");
            string workspaceDir = Path.Combine(root, "workspace");
            Directory.CreateDirectory(dockerDir);
            Directory.CreateDirectory(workspaceDir);

            Dictionary<string, object> labels = new Dictionary<string, object>();
            labels["com.docker.compose.project.working_dir"] = dockerDir;
            labels["com.docker.compose.service"] = "codex-dev-d";
            Dictionary<string, object> mount = new Dictionary<string, object>();
            mount["Type"] = "bind";
            mount["Source"] = workspaceDir;
            mount["Destination"] = "/workspace/Documents";
            Dictionary<string, object> portBinding = new Dictionary<string, object>();
            portBinding["HostIp"] = "127.0.0.1";
            portBinding["HostPort"] = "2223";
            Dictionary<string, object> ports = new Dictionary<string, object>();
            ports["22/tcp"] = new object[] { portBinding };

            JavaScriptSerializer serializer = new JavaScriptSerializer();
            string metadata = serializer.Serialize(labels)
                + "|||" + serializer.Serialize(new object[] { mount })
                + "|||running|||" + serializer.Serialize(ports);
            ContainerDetection detected = EnvironmentDetector.ParseDockerMetadataForTesting(metadata, "codex-dev-d");
            AssertTrue(detected != null, "Docker metadata result");
            AssertPath(dockerDir, detected.ComposeDir, "Docker metadata compose directory");
            AssertPath(workspaceDir, detected.WorkspaceDir, "Docker metadata workspace");
            AssertTrue(detected.Status == "running", "Docker metadata status");
            AssertTrue(detected.ServiceName == "codex-dev-d", "Docker metadata service");
            AssertTrue(detected.SshPort == 2223, "Docker metadata SSH port");

            Dictionary<string, object> emptyNetworkPorts = new Dictionary<string, object>();
            emptyNetworkPorts["22/tcp"] = null;
            string hostBindingMetadata = serializer.Serialize(labels)
                + "|||" + serializer.Serialize(new object[] { mount })
                + "|||running|||" + serializer.Serialize(emptyNetworkPorts)
                + "|||" + serializer.Serialize(ports);
            ContainerDetection hostBindingDetected = EnvironmentDetector.ParseDockerMetadataForTesting(
                hostBindingMetadata,
                "codex-dev-d");
            AssertTrue(hostBindingDetected != null, "Docker host port binding result");
            AssertTrue(hostBindingDetected.SshPort == 2223, "Docker host port binding SSH fallback");
        }

        private static void TestDockerUtf8ProcessOutput()
        {
            bool timedOut;
            string metadata = EnvironmentDetector.RunDockerInspectForTesting(
                Assembly.GetExecutingAssembly().Location,
                "codex-dev-d",
                out timedOut);
            AssertTrue(!timedOut, "UTF-8 Docker process timeout");

            ContainerDetection detected = EnvironmentDetector.ParseDockerMetadataForTesting(metadata, "codex-dev-d");
            AssertTrue(detected != null, "UTF-8 Docker process result");
            AssertTrue(detected.SshPort == 2223, "UTF-8 Docker host port binding fallback");
            AssertPath(@"D:\docker\codex-docker-host-d", detected.ComposeDir, "UTF-8 Docker compose directory");
            AssertPath(@"D:\user\桌面文件\apps\codex_documents", detected.WorkspaceDir, "UTF-8 Docker workspace");
            AssertTrue(metadata.IndexOf("妗岄潰鏂囦欢", StringComparison.Ordinal) < 0, "Docker output mojibake");
        }

        private static void TestPortDetection()
        {
            TcpListener listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            try
            {
                int occupiedPort = ((IPEndPoint)listener.LocalEndpoint).Port;
                AssertTrue(!PortUtility.IsAvailable(occupiedPort), "occupied port detection");
                AssertTrue(PortUtility.FindAvailable(occupiedPort) != occupiedPort, "automatic replacement port");
            }
            finally
            {
                listener.Stop();
            }
        }

        private static void TestInstallOptionsReusePolicy()
        {
            EnvironmentDetection existing = new EnvironmentDetection();
            existing.DockerDir = @"D:\docker\codex-docker-host-d";
            existing.WorkspaceDir = @"D:\workspace";
            existing.Summary = "existing";
            existing.FoundExisting = true;
            existing.DockerCliFound = true;
            existing.DockerDaemonAvailable = true;
            existing.ExistingContainerFound = true;
            existing.ContainerName = "codex-dev-d";
            existing.ContainerStatus = "running";
            existing.ServiceName = "codex-dev-d";
            existing.CodexInstalled = true;
            existing.SshPort = 2223;
            existing.ApiEnvKey = "IKUNCODE_API_KEY";

            InstallOptions reused = InstallOptions.FromDetection(existing);
            AssertTrue(reused.ReuseExistingContainer, "existing Codex container reuse");
            AssertTrue(!reused.BuildDocker, "reuse skips Docker build");
            AssertTrue(!reused.StopExistingContainer, "reuse does not stop existing container");
            AssertTrue(reused.RestartExistingContainerAfterInstall, "reuse restarts after installation");
            AssertTrue(reused.ContainerName == "codex-dev-d", "reuse container name");
            AssertTrue(reused.ServiceName == "codex-dev-d", "reuse service name");
            AssertTrue(reused.SshPort == 2223, "reuse SSH port");

            EnvironmentDetection fresh = new EnvironmentDetection();
            fresh.DockerDir = @"D:\docker\new-codex";
            fresh.WorkspaceDir = @"D:\workspace";
            fresh.Summary = "fresh";
            fresh.DockerCliFound = true;
            fresh.DockerDaemonAvailable = true;
            fresh.ApiEnvKey = "DOCKER_CODEX_API_KEY";
            fresh.ContainerNames = new[] { "docker-codex", "database" };
            fresh.ComposeProjectNames = new[] { "docker-codex-suite" };

            InstallOptions created = InstallOptions.FromDetection(fresh);
            AssertTrue(!created.ReuseExistingContainer, "fresh install does not reuse");
            AssertTrue(created.BuildDocker, "fresh install builds Docker container");
            AssertTrue(created.ContainerName == "docker-codex-2", "fresh container name avoids collision");
            AssertTrue(created.ServiceName == "codex-dev", "fresh service name");
            AssertTrue(created.ProjectName == "docker-codex-suite-2", "fresh project name avoids collision");

            existing.CodexInstalled = false;
            InstallOptions incompatible = InstallOptions.FromDetection(existing);
            AssertTrue(!incompatible.ReuseExistingContainer, "incompatible container is not reused");
            AssertTrue(!incompatible.StopExistingContainer, "incompatible container is not stopped");

            EnvironmentDetection ambiguous = new EnvironmentDetection();
            ambiguous.DockerDir = @"D:\docker\ambiguous";
            ambiguous.WorkspaceDir = @"D:\workspace";
            ambiguous.DockerCliFound = true;
            ambiguous.DockerDaemonAvailable = true;
            ambiguous.CodexContainerCount = 2;
            ambiguous.CodexContainerNames = new[] { "codex-one", "codex-two" };
            ambiguous.ContainerSelectionBlocked = true;
            InstallOptions blocked = InstallOptions.FromDetection(ambiguous);
            AssertTrue(blocked.ContainerSelectionBlocked, "ambiguous Codex selection is blocked");
            AssertTrue(!blocked.ReuseExistingContainer, "ambiguous selection is not reused");
            AssertTrue(!blocked.BuildDocker, "ambiguous selection never creates a container");
        }

        private static void TestControllerWindowDetection()
        {
            AssertTrue(
                InstallerEngine.IsControllerWindowForTesting("powershell.exe", "Docker Codex API Switcher"),
                "main controller window detection");
            AssertTrue(
                InstallerEngine.IsControllerWindowForTesting("pwsh", "Edit Docker API Profile"),
                "profile editor window detection");
            AssertTrue(
                InstallerEngine.IsControllerWindowForTesting("powershell", "Import Codex++ API Profile"),
                "Codex++ import window detection");
            AssertTrue(
                !InstallerEngine.IsControllerWindowForTesting("node", "Docker Codex API Switcher"),
                "non-PowerShell process is preserved");
            AssertTrue(
                !InstallerEngine.IsControllerWindowForTesting("powershell", "Windows PowerShell"),
                "unrelated PowerShell window is preserved");
        }

        private static void TestContainerDiscoverySafety(string root)
        {
            Directory.CreateDirectory(root);
            string previousContainers = Environment.GetEnvironmentVariable("FAKE_DOCKER_CONTAINERS");
            string previousCodexContainers = Environment.GetEnvironmentVariable("FAKE_DOCKER_CODEX_CONTAINERS");
            string previousLog = Environment.GetEnvironmentVariable("FAKE_DOCKER_LOG");
            string previousStateFile = Environment.GetEnvironmentVariable("FAKE_DOCKER_STATE_FILE");
            string logPath = Path.Combine(root, "docker.log");
            string statePath = Path.Combine(root, "docker-state.txt");
            try
            {
                Environment.SetEnvironmentVariable("FAKE_DOCKER_LOG", logPath);
                Environment.SetEnvironmentVariable("FAKE_DOCKER_CONTAINERS", "database,custom-codex,cache");
                Environment.SetEnvironmentVariable("FAKE_DOCKER_CODEX_CONTAINERS", "custom-codex");
                ContainerScanResult unique = EnvironmentDetector.ScanContainersForTesting(
                    Assembly.GetExecutingAssembly().Location,
                    "");
                AssertTrue(unique.ContainerCount == 3, "all Docker containers enumerated");
                AssertTrue(unique.CodexContainerNames.Length == 1, "only one Codex container confirmed");
                AssertTrue(unique.Selected != null && unique.Selected.ContainerName == "custom-codex", "arbitrary Codex container selected");
                AssertTrue(!unique.SelectionBlocked, "unique Codex container is safe to reuse");

                string log = File.ReadAllText(logPath, Encoding.UTF8);
                AssertTrue(log.IndexOf("ps -a", StringComparison.OrdinalIgnoreCase) >= 0, "Docker container enumeration command");
                AssertTrue(log.IndexOf("exec database", StringComparison.OrdinalIgnoreCase) >= 0, "ordinary database inspected");
                AssertTrue(log.IndexOf("exec cache", StringComparison.OrdinalIgnoreCase) >= 0, "ordinary cache inspected");
                AssertTrue(log.IndexOf(" stop ", StringComparison.OrdinalIgnoreCase) < 0, "scan never stops a container");
                AssertTrue(log.IndexOf(" restart ", StringComparison.OrdinalIgnoreCase) < 0, "scan never restarts a container");
                AssertTrue(log.IndexOf(" compose ", StringComparison.OrdinalIgnoreCase) < 0, "scan never invokes compose");

                File.WriteAllText(statePath, "stopped", new UTF8Encoding(false));
                Environment.SetEnvironmentVariable("FAKE_DOCKER_STATE_FILE", statePath);
                Environment.SetEnvironmentVariable("FAKE_DOCKER_CONTAINERS", "database,offline-codex");
                Environment.SetEnvironmentVariable("FAKE_DOCKER_CODEX_CONTAINERS", "offline-codex");
                ContainerScanResult stopped = EnvironmentDetector.ScanContainersForTesting(
                    Assembly.GetExecutingAssembly().Location,
                    "");
                AssertTrue(stopped.Selected != null && stopped.Selected.ContainerName == "offline-codex", "stopped Codex container detected read-only");
                AssertTrue(stopped.Selected.Status == "exited", "stopped Codex status preserved");
                log = File.ReadAllText(logPath, Encoding.UTF8);
                AssertTrue(log.IndexOf("start offline-codex", StringComparison.OrdinalIgnoreCase) < 0, "scan never starts a stopped Codex container");
                Environment.SetEnvironmentVariable("FAKE_DOCKER_STATE_FILE", null);

                Environment.SetEnvironmentVariable("FAKE_DOCKER_CONTAINERS", "database,cache");
                Environment.SetEnvironmentVariable("FAKE_DOCKER_CODEX_CONTAINERS", "__none__");
                ContainerScanResult none = EnvironmentDetector.ScanContainersForTesting(
                    Assembly.GetExecutingAssembly().Location,
                    "");
                AssertTrue(none.Selected == null, "zero Codex containers selects nothing");
                AssertTrue(none.CodexContainerNames.Length == 0, "zero Codex containers confirmed");
                AssertTrue(!none.SelectionBlocked, "complete zero-Codex scan allows fresh installation");

                Environment.SetEnvironmentVariable("FAKE_DOCKER_CONTAINERS", "codex-one,database,codex-two");
                Environment.SetEnvironmentVariable("FAKE_DOCKER_CODEX_CONTAINERS", "codex-one,codex-two");
                ContainerScanResult ambiguous = EnvironmentDetector.ScanContainersForTesting(
                    Assembly.GetExecutingAssembly().Location,
                    "");
                AssertTrue(ambiguous.Selected == null, "multiple Codex containers are not guessed");
                AssertTrue(ambiguous.CodexContainerNames.Length == 2, "multiple Codex containers counted");
                AssertTrue(ambiguous.SelectionBlocked, "multiple Codex containers block installation");

                ContainerScanResult preferred = EnvironmentDetector.ScanContainersForTesting(
                    Assembly.GetExecutingAssembly().Location,
                    "codex-two");
                AssertTrue(preferred.Selected != null && preferred.Selected.ContainerName == "codex-two", "saved Codex container preference reused");
                AssertTrue(!preferred.SelectionBlocked, "verified saved Codex preference resolves ambiguity");
            }
            finally
            {
                Environment.SetEnvironmentVariable("FAKE_DOCKER_CONTAINERS", previousContainers);
                Environment.SetEnvironmentVariable("FAKE_DOCKER_CODEX_CONTAINERS", previousCodexContainers);
                Environment.SetEnvironmentVariable("FAKE_DOCKER_LOG", previousLog);
                Environment.SetEnvironmentVariable("FAKE_DOCKER_STATE_FILE", previousStateFile);
            }
        }

        private static bool TryRunFakeTool(string[] args, out int exitCode)
        {
            exitCode = 0;
            if (args.Length == 0) return false;
            string first = args[0].ToLowerInvariant();

            if (first == "-l")
            {
                if (Environment.GetEnvironmentVariable("FAKE_WSL_STATE") == "installed")
                {
                    Console.WriteLine("Windows Subsystem for Linux Distributions:");
                    Console.WriteLine("Ubuntu-24.04    Running         2");
                }
                else
                {
                    exitCode = 1;
                }
                return true;
            }

            if (first == "--version")
            {
                string nodeOutput = Environment.GetEnvironmentVariable("FAKE_NODE_VERSION_OUTPUT");
                if (nodeOutput != null)
                {
                    if (nodeOutput == "fail") exitCode = 1;
                    else Console.WriteLine(nodeOutput);
                }
                else
                {
                    Console.WriteLine("v1.8.1911");
                }
                return true;
            }

            if (first == "install")
            {
                if (Environment.GetEnvironmentVariable("FAKE_WINGET_INSTALL_RESULT") == "fail") exitCode = 1;
                return true;
            }

            return false;
        }

        private static string SetTestEnv(string name, string value)
        {
            string previous = Environment.GetEnvironmentVariable(name);
            Environment.SetEnvironmentVariable(name, value);
            return previous;
        }

        private static void TestPrerequisiteDetectAllInstalled(string root)
        {
            Directory.CreateDirectory(root);
            string self = Assembly.GetExecutingAssembly().Location;
            string codexRoot = Path.Combine(root, "codex-root");
            Directory.CreateDirectory(Path.Combine(codexRoot, "Packages", "OpenAI.Codex_fakepkg"));

            string prevWsl = SetTestEnv("DOCKER_CODEX_WSL_EXE", self);
            string prevWslState = SetTestEnv("FAKE_WSL_STATE", "installed");
            string prevNode = SetTestEnv("DOCKER_CODEX_NODE_EXE", self);
            string prevNodeOut = SetTestEnv("FAKE_NODE_VERSION_OUTPUT", "v22.11.0");
            string prevSsh = SetTestEnv("DOCKER_CODEX_SSH_EXE", self);
            string prevDocker = SetTestEnv("DOCKER_CODEX_DOCKER_EXE", self);
            string prevCodex = SetTestEnv("DOCKER_CODEX_CODEX_ROOT", codexRoot);
            try
            {
                List<PrerequisiteStatus> statuses = PrerequisiteDetector.DetectAll();
                AssertTrue(statuses.Count == 5, "prerequisite detect-all returns five entries");
                foreach (PrerequisiteStatus status in statuses)
                {
                    AssertTrue(
                        status.State == PrerequisiteState.Installed,
                        "prerequisite installed: " + status.Id + " detail=" + status.Detail);
                }
            }
            finally
            {
                SetTestEnv("DOCKER_CODEX_WSL_EXE", prevWsl);
                SetTestEnv("FAKE_WSL_STATE", prevWslState);
                SetTestEnv("DOCKER_CODEX_NODE_EXE", prevNode);
                SetTestEnv("FAKE_NODE_VERSION_OUTPUT", prevNodeOut);
                SetTestEnv("DOCKER_CODEX_SSH_EXE", prevSsh);
                SetTestEnv("DOCKER_CODEX_DOCKER_EXE", prevDocker);
                SetTestEnv("DOCKER_CODEX_CODEX_ROOT", prevCodex);
            }
        }

        private static void TestPrerequisiteDetectMissing()
        {
            string missingCodexRoot = Path.Combine(
                Path.GetTempPath(),
                "DockerCodexSuite-no-such-codex-root-" + Guid.NewGuid().ToString("N"));
            string self = Assembly.GetExecutingAssembly().Location;

            string prevWsl = SetTestEnv("DOCKER_CODEX_WSL_EXE", self);
            string prevWslState = SetTestEnv("FAKE_WSL_STATE", "missing");
            string prevNode = SetTestEnv("DOCKER_CODEX_NODE_EXE", self);
            string prevNodeOut = SetTestEnv("FAKE_NODE_VERSION_OUTPUT", "v14.17.0");
            string prevCodex = SetTestEnv("DOCKER_CODEX_CODEX_ROOT", missingCodexRoot);
            try
            {
                PrerequisiteStatus wsl = PrerequisiteDetector.DetectWsl();
                AssertTrue(wsl.State == PrerequisiteState.Missing, "missing wsl is reported missing");
                PrerequisiteStatus node = PrerequisiteDetector.DetectNode();
                AssertTrue(node.State == PrerequisiteState.Missing, "low node version is reported missing");
                PrerequisiteStatus codex = PrerequisiteDetector.DetectCodex();
                AssertTrue(codex.State == PrerequisiteState.Missing, "missing codex is reported missing");
            }
            finally
            {
                SetTestEnv("DOCKER_CODEX_WSL_EXE", prevWsl);
                SetTestEnv("FAKE_WSL_STATE", prevWslState);
                SetTestEnv("DOCKER_CODEX_NODE_EXE", prevNode);
                SetTestEnv("FAKE_NODE_VERSION_OUTPUT", prevNodeOut);
                SetTestEnv("DOCKER_CODEX_CODEX_ROOT", prevCodex);
            }
        }

        private static void TestWingetDetection()
        {
            string prevWinget = SetTestEnv("DOCKER_CODEX_WINGET_EXE", Assembly.GetExecutingAssembly().Location);
            string prevNodeOut = SetTestEnv("FAKE_NODE_VERSION_OUTPUT", null);
            try
            {
                string version = "";
                AssertTrue(PrerequisiteDetector.WingetAvailable(out version), "fake winget is detected");
                AssertTrue(version.Contains("1.8"), "winget version text is parsed");
            }
            finally
            {
                SetTestEnv("DOCKER_CODEX_WINGET_EXE", prevWinget);
                SetTestEnv("FAKE_NODE_VERSION_OUTPUT", prevNodeOut);
            }
        }

        private static void TestPrerequisiteInstallOneSkipsInstalled()
        {
            PrerequisiteStatus installed = new PrerequisiteStatus
            {
                Id = "wsl",
                Name = "WSL2 + Ubuntu-24.04",
                State = PrerequisiteState.Installed,
                Detail = "ready"
            };
            int reportCount = 0;
            PrerequisiteStatus result = PrerequisiteInstaller.InstallOne(
                installed,
                delegate(string id, string message, int percent)
                {
                    reportCount += 1;
                });
            AssertTrue(result.State == PrerequisiteState.Installed, "installed prerequisite is not reinstalled");
            AssertTrue(reportCount == 1, "install-one reports exactly once for installed item");

            PrerequisiteStatus unknown = new PrerequisiteStatus
            {
                Id = "nope",
                Name = "Unknown",
                State = PrerequisiteState.Missing,
                Detail = ""
            };
            PrerequisiteStatus failed = PrerequisiteInstaller.InstallOne(unknown, delegate { });
            AssertTrue(failed.State == PrerequisiteState.Failed, "unknown prerequisite fails instead of crashing");
        }

        private static void TestCurrentMachinePrerequisites()
        {
            List<PrerequisiteStatus> statuses = PrerequisiteDetector.DetectAll();
            foreach (PrerequisiteStatus status in statuses)
            {
                AssertTrue(
                    status.State == PrerequisiteState.Installed,
                    "real machine prerequisite must be ready: " + status.Id + " detail=" + status.Detail);
            }
        }

        private static bool TryRunFakeDocker(string[] args, out int exitCode)
        {
            exitCode = 0;
            if (args.Length == 0) return false;
            string command = args[0].ToLowerInvariant();
            if (command != "version" && command != "ps" && command != "inspect" && command != "exec"
                && command != "cp" && command != "stop" && command != "start" && command != "restart" && command != "compose")
            {
                return false;
            }

            AppendFakeDockerLog(string.Join(" ", args));
            if (command == "version")
            {
                Console.WriteLine("27.0.0");
                return true;
            }
            if (command == "ps")
            {
                string containers = Environment.GetEnvironmentVariable("FAKE_DOCKER_CONTAINERS") ?? "codex-dev-d";
                foreach (string name in containers.Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries))
                {
                    Console.WriteLine(name.Trim());
                }
                return true;
            }
            if (command == "inspect")
            {
                string containerName = args[args.Length - 1];
                string statePath = Environment.GetEnvironmentVariable("FAKE_DOCKER_STATE_FILE") ?? "";
                string status = File.Exists(statePath) && File.ReadAllText(statePath).Contains("stopped")
                    ? "exited"
                    : "running";
                EmitDockerMetadata(status, containerName);
                return true;
            }
            if (command == "exec")
            {
                string configured = Environment.GetEnvironmentVariable("FAKE_DOCKER_CODEX_CONTAINERS");
                if (configured == null) return true;
                string containerName = args.Length > 1 ? args[1] : "";
                if (!IsFakeCodexContainer(configured, containerName)) exitCode = 1;
                return true;
            }
            if (command == "cp")
            {
                string configured = Environment.GetEnvironmentVariable("FAKE_DOCKER_CODEX_CONTAINERS") ?? "";
                string source = args.Length > 1 ? args[1] : "";
                int separator = source.IndexOf(':');
                string containerName = separator > 0 ? source.Substring(0, separator) : source;
                if (!IsFakeCodexContainer(configured, containerName)) exitCode = 1;
                return true;
            }
            if (command == "stop" || command == "start" || command == "restart")
            {
                string statePath = Environment.GetEnvironmentVariable("FAKE_DOCKER_STATE_FILE") ?? "";
                if (!string.IsNullOrWhiteSpace(statePath))
                {
                    File.WriteAllText(statePath, command == "stop" ? "stopped" : "running", new UTF8Encoding(false));
                }
                return true;
            }
            if (command == "compose" && Environment.GetEnvironmentVariable("FAKE_DOCKER_FAIL_COMPOSE") == "1")
            {
                exitCode = 1;
            }
            return true;
        }

        private static bool IsFakeCodexContainer(string configured, string containerName)
        {
            return Array.Exists(
                (configured ?? "").Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries),
                delegate(string name)
                {
                    return string.Equals(name.Trim(), containerName, StringComparison.OrdinalIgnoreCase);
                });
        }

        private static void AppendFakeDockerLog(string line)
        {
            string logPath = Environment.GetEnvironmentVariable("FAKE_DOCKER_LOG") ?? "";
            if (string.IsNullOrWhiteSpace(logPath)) return;
            File.AppendAllText(logPath, line + Environment.NewLine, new UTF8Encoding(false));
        }

        private static void EmitDockerMetadata(string status, string containerName)
        {
            Dictionary<string, object> labels = new Dictionary<string, object>();
            labels["com.docker.compose.project.working_dir"] = @"D:\docker\codex-docker-host-d";
            labels["com.docker.compose.service"] = "codex-dev-d";
            labels["com.docker.compose.project"] = "codex-docker-host-d";
            Dictionary<string, object> mount = new Dictionary<string, object>();
            mount["Type"] = "bind";
            mount["Source"] = @"D:\user\桌面文件\apps\codex_documents";
            mount["Destination"] = "/workspace/Documents";
            Dictionary<string, object> portBinding = new Dictionary<string, object>();
            portBinding["HostIp"] = "127.0.0.1";
            portBinding["HostPort"] = "2223";
            Dictionary<string, object> ports = new Dictionary<string, object>();
            ports["22/tcp"] = new object[] { portBinding };
            Dictionary<string, object> networkPorts = new Dictionary<string, object>();
            networkPorts["22/tcp"] = null;

            JavaScriptSerializer serializer = new JavaScriptSerializer();
            Console.OutputEncoding = new UTF8Encoding(false);
            Console.WriteLine(
                serializer.Serialize(labels)
                + "|||" + serializer.Serialize(new object[] { mount })
                + "|||" + status + "|||" + serializer.Serialize(networkPorts)
                + "|||" + serializer.Serialize(ports));
        }

        private static void TestCurrentMachine(string expectedDockerDir, string expectedWorkspaceDir)
        {
            EnvironmentDetection detected = EnvironmentDetector.Detect(true);
            AssertPath(expectedDockerDir, detected.DockerDir, "current Docker directory");
            AssertPath(expectedWorkspaceDir, detected.WorkspaceDir, "current workspace directory");
            Console.WriteLine("Detected Docker directory: " + detected.DockerDir);
            Console.WriteLine("Detected workspace: " + detected.WorkspaceDir);
            Console.WriteLine(detected.Summary);
            string[] commandLine = Environment.GetCommandLineArgs();
            if (commandLine.Length >= 5)
            {
                AssertTrue(detected.DockerDaemonAvailable, "current Docker daemon");
                AssertTrue(detected.ContainerName == commandLine[4], "current Codex container");
                AssertTrue(detected.ContainerStatus == "running", "current container status");
                AssertTrue(detected.CodexInstalled, "current container Codex CLI");
                AssertTrue(detected.SshPort == 2223, "current container SSH port");
                InstallOptions options = InstallOptions.Defaults(true);
                AssertTrue(options.ReuseExistingContainer, "current container reuse mode");
                AssertTrue(!options.BuildDocker, "current reuse skips Docker build");
                AssertTrue(!options.StopExistingContainer, "current reuse does not stop container");
                AssertTrue(options.ContainerName == commandLine[4], "current reused container name");
                AssertTrue(File.Exists(options.SshKeyPath), "current reused SSH identity");
                if (commandLine.Length >= 6)
                {
                    AssertTrue(detected.ApiEnvKey == commandLine[5], "current API environment key");
                }
            }
        }

        private static void TestCodexHomeResolution(string root)
        {
            string previous = Environment.GetEnvironmentVariable("CODEX_HOME");
            try
            {
                string custom = Path.Combine(root, "\u4e3b\u7a7a\u95f4", ".codex-custom");
                Environment.SetEnvironmentVariable("CODEX_HOME", custom);
                AssertPath(custom, UserPaths.CodexHome(), "custom CODEX_HOME");

                Environment.SetEnvironmentVariable("CODEX_HOME", "relative-codex-home");
                bool rejected = false;
                try
                {
                    UserPaths.CodexHome();
                }
                catch (InvalidOperationException)
                {
                    rejected = true;
                }
                AssertTrue(rejected, "relative CODEX_HOME rejected");
            }
            finally
            {
                Environment.SetEnvironmentVariable("CODEX_HOME", previous);
            }
        }

        private static void TestInstallRegistration(string root)
        {
            if (Directory.Exists(root)) Directory.Delete(root, true);
            Directory.CreateDirectory(root);

            string defaultDirectory = Path.Combine(root, "default");
            string registeredDirectory = Path.Combine(root, "中文安装目录", "Docker Codex Suite");
            string startupDirectory = Path.Combine(root, "startup directory");
            Directory.CreateDirectory(defaultDirectory);
            Directory.CreateDirectory(registeredDirectory);
            Directory.CreateDirectory(startupDirectory);

            string registeredLauncher = Path.Combine(registeredDirectory, "DockerCodex.exe");
            string startupLauncher = Path.Combine(startupDirectory, "DockerCodex.exe");
            File.WriteAllText(registeredLauncher, "", new UTF8Encoding(false));
            File.WriteAllText(startupLauncher, "", new UTF8Encoding(false));

            string selected = InstallRegistration.ResolvePreferredInstallDirectoryForTesting(
                defaultDirectory,
                registeredDirectory,
                "\"" + startupLauncher + "\" --bridge",
                new[] { defaultDirectory, registeredDirectory, startupDirectory });
            AssertPath(registeredDirectory, selected, "registered custom installation directory");

            string requestedUpgradeDirectory = Path.Combine(root, "requested-upgrade-directory");
            AssertPath(
                registeredDirectory,
                InstallRegistration.ResolveUpgradeInstallDirectory(
                    requestedUpgradeDirectory,
                    registeredDirectory),
                "upgrade keeps registered installation directory");
            AssertPath(
                requestedUpgradeDirectory,
                InstallRegistration.ResolveUpgradeInstallDirectory(requestedUpgradeDirectory, ""),
                "fresh installation keeps requested directory");
            AssertTrue(
                InstallRegistration.AreSameDirectory(
                    registeredDirectory + Path.DirectorySeparatorChar,
                    registeredDirectory),
                "installation directory comparison normalizes trailing separators");

            selected = InstallRegistration.ResolvePreferredInstallDirectoryForTesting(
                defaultDirectory,
                Path.Combine(root, "missing"),
                "\"" + startupLauncher + "\" --bridge",
                new[] { defaultDirectory, startupDirectory });
            AssertPath(startupDirectory, selected, "startup custom installation directory");

            selected = InstallRegistration.ResolvePreferredInstallDirectoryForTesting(
                defaultDirectory,
                Path.Combine(root, "missing"),
                "powershell.exe -File \"" + Path.Combine(root, "missing.ps1") + "\"",
                new[] { defaultDirectory });
            AssertPath(defaultDirectory, selected, "default installation directory fallback");

            AssertPath(
                registeredLauncher,
                InstallRegistration.ExtractExecutablePath("\"" + registeredLauncher + "\" --switcher"),
                "quoted launcher command parsing");
            AssertPath(
                startupLauncher,
                InstallRegistration.ExtractExecutablePath(startupLauncher + " --bridge"),
                "unquoted launcher command parsing");
        }

        private static void TestManagedSkillInstallation(string root)
        {
            if (Directory.Exists(root)) Directory.Delete(root, true);
            Directory.CreateDirectory(root);

            string source = Path.Combine(root, "payload", "project-commander");
            WriteSkillSource(source, "first-version");
            string codexHome = Path.Combine(root, "\u4e2d\u6587\u8def\u5f84", ".codex");
            string unrelated = Path.Combine(codexHome, "skills", "unrelated-skill", "SKILL.md");
            Directory.CreateDirectory(Path.GetDirectoryName(unrelated));
            File.WriteAllText(unrelated, "unrelated\r\n", new UTF8Encoding(false));

            ManagedSkillInstallResult installed = ManagedSkillInstaller.Install(source, codexHome, "test-1", null);
            string destination = Path.Combine(codexHome, "skills", "project-commander");
            AssertTrue(installed.Action == "installed", "fresh managed skill install");
            AssertTrue(!installed.BackupCreated, "fresh install has no backup");
            AssertTrue(File.Exists(Path.Combine(destination, "SKILL.md")), "managed skill SKILL.md installed");
            AssertTrue(File.Exists(Path.Combine(destination, "agents", "openai.yaml")), "managed skill agent metadata installed");
            AssertTrue(File.Exists(Path.Combine(destination, "scripts", "project-commander.ps1")), "managed skill script installed");
            AssertTrue(File.Exists(Path.Combine(destination, ".docker-codex-suite-managed.json")), "managed skill marker installed");
            AssertTrue(File.ReadAllText(unrelated, Encoding.UTF8) == "unrelated\r\n", "unrelated skill preserved");

            ManagedSkillInstallResult unchanged = ManagedSkillInstaller.Install(source, codexHome, "test-1", null);
            AssertTrue(unchanged.Action == "unchanged", "identical managed skill remains in place");
            AssertTrue(!unchanged.BackupCreated, "identical managed skill creates no backup");

            string installedSkill = Path.Combine(destination, "SKILL.md");
            File.AppendAllText(installedSkill, "user-customization\r\n", new UTF8Encoding(false));
            ManagedSkillInstallResult replaced = ManagedSkillInstaller.Install(source, codexHome, "test-2", null);
            AssertTrue(replaced.Action == "replaced-with-backup", "modified managed skill replaced with backup");
            AssertTrue(replaced.BackupCreated && Directory.Exists(replaced.BackupPath), "modified skill backup exists");
            AssertTrue(
                File.ReadAllText(Path.Combine(replaced.BackupPath, "SKILL.md"), Encoding.UTF8).Contains("user-customization"),
                "modified skill content preserved in backup");
            AssertTrue(!File.ReadAllText(installedSkill, Encoding.UTF8).Contains("user-customization"), "bundled skill restored after backup");
            AssertTrue(File.ReadAllText(unrelated, Encoding.UTF8) == "unrelated\r\n", "unrelated skill survives replacement");

            bool restored = ManagedSkillInstaller.UninstallIfUnmodified(codexHome, null);
            AssertTrue(restored, "unmodified managed skill uninstalled");
            AssertTrue(Directory.Exists(destination), "pre-install skill restored on uninstall");
            AssertTrue(File.ReadAllText(installedSkill, Encoding.UTF8).Contains("user-customization"), "user backup restored on uninstall");
            AssertTrue(File.ReadAllText(unrelated, Encoding.UTF8) == "unrelated\r\n", "unrelated skill survives uninstall");

            string updateSource = Path.Combine(root, "update-payload", "project-commander");
            string updateHome = Path.Combine(root, "update-home", ".codex");
            WriteSkillSource(updateSource, "old-managed-version");
            ManagedSkillInstaller.Install(updateSource, updateHome, "old", null);
            WriteSkillSource(updateSource, "new-managed-version");
            ManagedSkillInstallResult updated = ManagedSkillInstaller.Install(updateSource, updateHome, "new", null);
            AssertTrue(updated.Action == "updated", "clean managed skill upgraded in place");
            AssertTrue(!updated.BackupCreated, "clean managed upgrade creates no backup");
            string updatedScript = Path.Combine(updateHome, "skills", "project-commander", "scripts", "project-commander.ps1");
            AssertTrue(File.ReadAllText(updatedScript, Encoding.UTF8).Contains("new-managed-version"), "managed skill update applied");

            File.AppendAllText(updatedScript, "user-edit\r\n", new UTF8Encoding(false));
            bool preserved = !ManagedSkillInstaller.UninstallIfUnmodified(updateHome, null);
            AssertTrue(preserved && File.Exists(updatedScript), "user-modified managed skill preserved on uninstall");
        }

        private static void WriteSkillSource(string root, string scriptVersion)
        {
            Directory.CreateDirectory(Path.Combine(root, "agents"));
            Directory.CreateDirectory(Path.Combine(root, "scripts"));
            File.WriteAllText(
                Path.Combine(root, "SKILL.md"),
                "---\r\nname: project-commander\r\ndescription: test\r\n---\r\n",
                new UTF8Encoding(false));
            File.WriteAllText(
                Path.Combine(root, "agents", "openai.yaml"),
                "interface:\r\n  display_name: Project Commander\r\n",
                new UTF8Encoding(false));
            File.WriteAllText(
                Path.Combine(root, "scripts", "project-commander.ps1"),
                "Write-Output '" + scriptVersion + "'\r\n",
                new UTF8Encoding(false));
        }

        private static void AssertPath(string expected, string actual, string label)
        {
            if (!string.Equals(
                Path.GetFullPath(expected).TrimEnd('\\'),
                Path.GetFullPath(actual).TrimEnd('\\'),
                StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException(label + " mismatch. Expected '" + expected + "', got '" + actual + "'.");
            }
        }

        private static void AssertTrue(bool condition, string label)
        {
            if (!condition) throw new InvalidOperationException("Assertion failed: " + label + ".");
        }
    }
}

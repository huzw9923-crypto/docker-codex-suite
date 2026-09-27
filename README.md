# Docker Codex Suite

一个非官方的 Windows + Docker Codex 本地开发方案：一行安装，在官方 Codex Desktop 顶部加入 `Docker API` 菜单，把 Codex CLI 跑在本地 Docker 容器中，并支持多套 API 配置一键切换。

详细使用说明见 [docs/README.md](docs/README.md)。

## 功能特性

- 一键生成 Docker Codex SSH 容器、独立 SSH 密钥和 Codex Host 配置，模板见 `src/docker/`
- 在 Codex Desktop 顶部注入 `Docker API` 菜单（中英文界面均支持）
- 管理 Responses API 与 Chat Completions 两类配置；Chat 上游由内置适配器转换为 Responses API（含 `tool_search` 与多智能体兼容）
- API 切换后自动重启远程 app-server 并主动重连；传输层瞬态故障自动退避重试，必要时回退容器重启
- 提供独立 API 切换器、状态检查、容器更新脚本与连通性诊断（provider doctor）

## 目录结构

```
├── build.ps1          # 构建入口：8 步（测试门禁 → 编译 C# → 组装 payload → 打包 EXE → manifest）
├── src/
│   ├── controller/    # 安装后的运行时：切换器 GUI、桥接服务、代理、重连助手、启动器 C#
│   ├── docker/        # 容器模板：Dockerfile、compose.template.yml、entrypoint、config 模板
│   └── skills/        # Project Commander skill（安装到 Codex 主空间）
├── installer/         # WinForms 安装器源码（Installer.cs + app.manifest）
├── tests/             # 回归测试（node + PowerShell + C#）
├── tools/             # 辅助脚本（隐藏启动 VBS）
├── docs/              # 使用说明、隐私、安全、发行说明
├── release-assets/    # 发布物料源文件
├── dist/              # 发布产物（仅保留最新安装包；二进制不入 git）
└── _archive/          # 历史构建/安装测试产物归档（不入 git）
```

## 快速构建

前置：Windows 10/11 x64、.NET Framework 4.x（`csc.exe`）、Node.js 22+（或已启动过 Codex Desktop）、Docker Desktop。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File build.ps1 -Version 1.1.11
```

- `-Version` 必须与 `installer/Installer.cs` 中 `ProductVersion` 一致，否则构建直接失败
- `-SkipSmokeTest` 可跳过安装器 UI 冒烟与解包 smoke（加速本地验证）
- 产物：`dist/DockerCodexSuite-Setup-<版本>-win-x64.exe` + `release-manifest.json` + `SHA256SUMS.txt`

注意：`dist/release-manifest.json` 与 `SHA256SUMS.txt` 只在下一次成功构建时才会被覆盖更新；当前值可能停留在上一个构建版本。

## 测试

构建的 `[1/8]` 阶段自动运行回归门禁，也可单独执行：

```powershell
$node = "$env:USERPROFILE\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe"
& $node tests\chat-proxy-tests.js
& $node --test tests\chat-proxy-tool-search-tests.js
& $node --test tests\responses-proxy-tests.js
& $node tests\app-reconnect-tests.js
& $node tests\bridge-menu-tests.js
& $node tests\provider-doctor-tests.js
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\profile-manager-tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\protocol-path-tests.ps1
```

新增回归测试后，把对应调用追加到 `build.ps1` 的 `[1/8]` 测试门禁段（失败即中断构建）。

## 开发指引

- 编码规范：`.js` 全部 no-BOM + UTF-8 + 纯 LF + `"use strict"`；`.ps1` 全部 UTF-8 BOM + 纯 LF
- `src/controller/` 下的每个 `.ps1`/`.js` 都会被复制进安装 payload（[4/8] 阶段）并被 payload 密钥扫描；新脚本不要硬编码本机路径或密钥
- 桥接器与重连助手通过 Codex Desktop 的调试通道（9229）注入菜单与执行重启，依赖 renderer DOM/IPC 结构；Codex Desktop 更新导致注入失败时优先检查 `data/bridge.log`
- 安装包通过 `& setup.exe --extract-only <dir>` 可不解包调试（见 `build.ps1` smoke 段）
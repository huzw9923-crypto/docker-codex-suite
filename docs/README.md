# Docker Codex Suite 1.2.0

一个非官方的 Windows + Docker Codex 本地开发方案。

## 功能

- 一键生成 Docker Codex SSH 容器、独立 SSH 密钥和 Codex Host 配置。
- 在官方 Codex Desktop 顶部加入 `Docker API` 菜单，不依赖 Codex++。
- 菜单桥接器随当前用户登录自动启动，并持续等待 Codex Desktop 的调试端口；应用关闭后不会丢失后续重连能力。
- 管理 Responses API 与 Chat Completions 两类配置；Chat 上游由内置适配器转换为 Codex 所需的 Responses API。
- Chat 兼容层支持原生 `tool_search`、延迟工具发现和 `multi_agent_v1` 命名空间，可在 DeepSeek 等 Chat 上游使用 Docker Codex 多智能体。
- 可选择性地一次性导入 Codex++ API 配置；导入完成后独立保存，不依赖 Codex++ 运行。
- API 切换后重启远程 app-server，并主动恢复连接。
- 提供独立 API 切换器、状态检查和 Docker 容器更新脚本。
- 安装前枚举全部 Docker 容器，并以容器内 Codex CLI 为准识别目标，不依赖固定容器名。
- 只自动复用唯一且兼容的 Codex 容器；检测不完整或存在多个未选定的 Codex 容器时阻止安装，不控制普通容器。
- 复用安装完成后仅执行容器重启，不重建、不覆盖现有 Compose；只有确认不存在 Codex 容器时才创建新容器。

## 前置条件

- Windows 10/11 x64
- Docker Desktop，使用 Linux containers
- OpenAI Codex Desktop
- Codex Desktop 已至少启动一次，以安装其本地 Node 运行时；也可使用系统 Node.js 22+
- Windows OpenSSH Client
- 首次构建 Docker 镜像时可访问 `chatgpt.com`

## 使用

1. 运行 `DockerCodexSuite-Setup-1.2.0-win-x64.exe`。首次安装可自定义目录；检测到已有版本时，升级目录会固定为原安装目录。
2. 确认自动检测出的 Docker 方案目录、工作区、容器状态和 SSH 端口。
3. 安装完成后，从开始菜单打开 `Docker Codex Suite`。
4. 在顶部 `Docker API` 菜单中新建、导入或切换 API 配置。
5. 新建一个 Codex 任务后，可直接使用 Docker API 菜单管理容器和 API 配置。

如果 Codex 已经直接启动且没有调试通道，请完整退出 Codex 后再从本工具启动。

安装器不会自动安装或修改任何 Codex skill；已有用户 skill 会保留不变。

升级时，安装器会从现有注册信息恢复并锁定原安装目录，原目录中的 API 配置和切换状态会保留；同时重建开始菜单与开机启动入口，并只重启已确认的 Docker Codex 容器，不重建容器。

## 免责声明

这是社区工具，与 OpenAI 无隶属或背书关系。Codex、OpenAI 及相关标识属于其各自权利人。

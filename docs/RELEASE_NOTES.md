## Unreleased

### 原生重启可靠性

- API 切换写入容器配置后，重连助手对 app-server 的自愈重启窗口做退避重试，不再把瞬态的 `AppServerTransportConnectError: socket hang up` 当成致命错误。
- 重试耗尽后降级为可用性失败，切换器自动走"docker restart → 等待 SSH → 原生重连"回退链，不再中断整个切换。
- `app-reconnect-tests.js`、`bridge-menu-tests.js`、`provider-doctor-tests.js` 全部纳入构建前置回归门禁。

### 英文界面菜单注入

- `Docker API` 菜单注入脚本同时支持中文（文件/编辑/视图/帮助）与英文（File/Edit/View/Help）菜单栏；Codex Desktop 使用英文界面时注入不再停留在 waiting。
- 新增 bridge 菜单注入回归测试，覆盖中英文与异常菜单结构场景。

# Docker Codex Suite 1.0.0.beta1

## GUI startup reliability

- Do not bundle or install Project Commander; existing user-managed Codex skills remain untouched.
- Show a completion dialog only after the uninstall helper has removed the controller directory.
- Quote the switcher script path when launching the GUI child process, including paths with spaces.
- Start hidden child processes through `ProcessStartInfo` and an absolute Windows PowerShell path, avoiding `Path`/`PATH` environment collisions.
- Scope the single-instance mutex to the actual install directory and recover when a stale process owns the mutex without a visible window.
- Add bootstrap diagnostics and package smoke checks for Chinese and space-containing installation directories.

## Upgrade directory locking

- Resolve the installed controller directory from existing uninstall and startup registrations instead of assuming `%LOCALAPPDATA%`.
- Lock the installer path field and ignore a different `--install-dir` whenever a valid existing installation is found.
- Keep first-time custom-directory installation available when no existing suite installation is detected.
- Rebuild Start Menu and startup entries in the original directory without rebuilding Docker containers.


## API 切换兼容

- Chat Completions 与 Responses API 统一经过独立本地兼容网关，切换配置时保留同一个 Docker Codex 任务。
- 转发到新上游前只规范化历史记录中的非法工具名，不修改容器内会话数据库。
- Responses 配置往返切换、模型目录更新和安装升级时的离线配置修复已加入构建测试。

修复 Chat Completions 兼容层无法完成 Docker Codex 多智能体调用的问题。

## 修复

- 将 Responses `tool_search` 映射为 Chat 上游可调用的具名函数，并把返回调用恢复为原生 `tool_search_call`。
- 将历史 `tool_search_output` 中发现的工具注册到下一轮请求，保留 `multi_agent_v1` 命名空间与真实工具名。
- 过滤 Chat 上游不支持的工具类型，不再生成错误的 `tool`、`tool_2` 占位工具。
- 流式与非流式路径都恢复原生 tool-search output item；流式路径不再误发 function-call argument 事件。

## 边界

- 这是 Docker Codex Suite 的 Chat Completions → Responses 兼容层修复，不是 Codex 原生 Responses API 或 Docker 线程调度缺陷。
- 不改变模型、API Key、容器配置或多智能体工具本身。

## 验证

- 新增 6 项 `tool_search` 回归测试，并纳入安装包构建前置检查；原有 Chat proxy 回归同时执行。
- 实际流程覆盖 `tool_search → spawn_agent → wait → SUBAGENT_OK → close_agent → FINAL_OK`。

# Docker Codex Suite 1.1.4

把 Project Commander 作为 Docker Codex 方案的主空间组件纳入安装包。

## 新增

- 安装器将 Project Commander 安装到主空间 `CODEX_HOME\skills\project-commander`，未设置 `CODEX_HOME` 时使用 `%USERPROFILE%\.codex`。
- 支持 `/list`、`/new`、`/project`、`/status`、`/send` 和 `/help`，每个 `/workspace/Documents` 项目只绑定一个持久 commander 任务。
- Project Commander 通过宿主机 Docker CLI 验证唯一的 Codex 容器，不依赖固定容器名，也不会安装到容器内。

## 升级与安全

- 使用文件哈希受管清单区分官方旧版本与用户修改；冲突内容先备份到 Codex Home 下的非 skill 扫描目录。
- 升级和卸载只处理 `project-commander`，不触碰其他 skill；卸载时保留用户修改，并在可用时恢复安装前副本。
- 构建阶段检查 Project Commander 必需文件、安装状态文件、主机绝对路径、API 凭据和其他本地秘密。

## 验证

- 覆盖中文 `CODEX_HOME`、首次安装、重复安装、受管升级、用户改动备份、卸载恢复和其他 skill 保留。
- 单文件 EXE 解包 smoke test 验证 Project Commander 的 `SKILL.md`、agent metadata 与 PowerShell gateway 均在 payload 中。

# Docker Codex Suite 1.1.3

修复 Codex Desktop 的实验模型白名单会把自定义 Docker catalog 过滤为空的问题。

## 修复

- 后台 bridge 读取当前 Docker 模型 catalog，只把其中明确列出的非隐藏模型合并到对应远程 `models/list` observer。
- 兼容补丁仅作用于原始查询确实返回这些 catalog 模型的远程连接，不修改主空间模型、不伪装模型 ID，也不改写上游请求。
- Codex 启动、远程任务首次打开和 API profile 切换后都会自动重新检查；切回非 catalog 配置时会恢复原 observer。
- 原生重连同时刷新原始模型查询和前端 observer，避免出现“接口已有模型但二级菜单为空”。

## 验证

- Codex Desktop 的模型二级菜单实际显示 `deepseek-v4-pro` 与 `deepseek-v4-flash`。
- 容器 app-server、常驻监听器、renderer 原始查询和最终菜单四层结果一致。

# Docker Codex Suite 1.1.2

修复升级后旧切换器窗口仍使用旧逻辑写配置，导致 Docker Codex 模型列表为空或回退到内置 GPT 模型的问题。

## 修复

- 安装升级前只关闭 Docker Codex Suite 自己的 PowerShell 窗口，不影响普通 PowerShell、其他容器或其他应用。
- 升级时自动修复当前 API profile 的 `model_catalog_json` 与模型目录，再重启已经验证的 Codex 容器；不会重建容器。
- 原生重连成功后精确刷新对应远程主机的 `models/list` 查询缓存，使新模型列表立即进入 Codex 模型选择器。
- 保留没有缓存远程模型查询时的兼容行为，首次进入 Docker Codex 时仍由 Codex 正常加载模型列表。

## 验证

- DeepSeek 配置恢复后，容器 app-server 与 Codex Desktop 均返回 `deepseek-v4-pro` 和 `deepseek-v4-flash`。
- 升级窗口识别不会关闭普通 PowerShell 或后台 Node bridge。

# Docker Codex Suite 1.1.1

修复切换 API 后 Docker Codex 模型选择器仍显示内置 GPT 模型的问题。

## 修复

- 应用 API 配置时，根据所选默认模型和模型列表生成 Codex 原生 `model_catalog_json`。
- 模型目录随配置一起写入 Docker Codex 的 `CODEX_HOME`，并在既有 app-server 重启后立即生效。
- Chat Completions 配置以文本模态写入目录；Responses 配置保留文本和图片模态。
- 本地模板中的旧目录设置不会覆盖当前 API 配置生成的目录。
- 目录只包含模型元数据，不写入 API Key 或其他凭据。

## 验证

- DeepSeek 配置的原生 `model/list` 返回 `deepseek-v4-pro`（默认）和 `deepseek-v4-flash`，不再回退到内置 GPT 列表。

# Docker Codex Suite 1.1.0

新增可选的 Codex++ 配置导入，以及独立的 Chat Completions → Responses 转换能力。

## 新增

- 在 API 切换器中预览并勾选 Codex++ 配置，一次性导入后独立保存，不形成运行时依赖。
- 支持直接应用 Chat Completions 配置；内置主机代理在 `127.0.0.1:38119` 完成 Responses 请求与流式事件转换。
- 支持 DeepSeek `reasoning_content`、普通函数工具及 Codex 自定义工具调用。
- 导入过程保留真实上游和模型列表，自动读取 Codex++ `authContents`，但不在预览窗口或代理配置中显示 API Key。
- 以 Codex++ Profile ID 作为稳定导入标识，重复导入执行更新而不是创建副本。

## 安全与兼容

- 聚合配置、缺少 API Key 的配置，以及只指向 Codex++ 本地 `57321` 转发端口的配置不会被导入。
- 导入操作不会自动切换 API 或重启容器；只有用户点击“应用所选配置”后才执行既有的重启与重连流程。
- Chat 转换器由现有后台 Bridge 托管，不创建额外容器，也不依赖 Codex++。

# Docker Codex Suite 1.0.0

首个可发布版本，提供 Windows 单文件 EXE 安装器。

## 新增

- 安装官方 Codex Desktop 的独立 `Docker API` 顶部菜单，不依赖 Codex++。
- Docker API 菜单桥接器改为持久等待和自动重连，并注册当前用户登录自启动；安装或升级后会主动重启桥接器加载新版本。
- Docker SSH 开发容器模板、独立 Ed25519 密钥和 `docker-codex-suite` SSH Host 自动配置。
- 多 API 配置列表、新建配置、主空间配置同步和 Docker 本地配置切换。
- API 切换后通过 Codex renderer bridge 重启远程 app-server 并主动重连。
- 单文件安装、开始菜单入口、HKCU 卸载项、现有配置备份和静默安装模式。
- 安装时自动识别上次设置、现有 Docker 容器和 compose 目录，并还原 `/workspace/Documents` 对应的 Windows 工作区；路径仍可手动覆盖。
- Docker 元数据、PowerShell 配置和界面路径统一使用 UTF-8，支持包含中文的 Docker 目录、工作区及配置名称。
- 安装器枚举全部 Docker 容器并实际验证 Codex CLI，不再依赖 `docker-codex` 或其他固定名称。
- 多个普通容器中只复用确认含 Codex 的目标；多个 Codex、扫描不完整或缺少 SSH 端口时阻止操作。
- 复用安装只执行 `docker restart`，不重建、不运行 Compose；确认零 Codex 容器时才使用未占用名称创建新容器。
- 安装 payload 密钥扫描、SHA256 清单、隐私和安全说明。

## 前置条件

- Windows 10/11 x64
- Docker Desktop（Linux containers）
- OpenAI Codex Desktop，并至少启动过一次
- Windows OpenSSH Client

## 已知限制

- 当前构建未做 Authenticode 签名，首次下载可能出现 SmartScreen 提示。
- 首次 Docker 镜像构建需要网络访问 `chatgpt.com` 和 Ubuntu 软件源。
- Codex Desktop 更新可能改变 renderer DOM 或 IPC；出现菜单缺失时需要更新控制器。
- 仅验证 Windows x64，尚未提供 ARM64 版本。

## 安全边界

安装包不包含 API Key、`auth.json`、SSH 私钥、API 配置列表、Codex 会话或日志。SSH 端口只绑定 `127.0.0.1`。容器使用 `SYS_ADMIN` 和 `seccomp=unconfined` 支持嵌套沙箱，请只挂载允许容器读写的工作区。

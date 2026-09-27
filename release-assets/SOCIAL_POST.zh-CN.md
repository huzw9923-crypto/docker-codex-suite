# 社交平台发布文案

做了一个非官方的 **Docker Codex Suite**：把 Codex Desktop、Docker SSH 开发环境和多 API 切换整合成一个 Windows EXE 安装包。

主要功能：

- 官方 Codex 顶部直接出现 `Docker API` 菜单，不依赖 Codex++
- 一键生成 Docker Codex 容器、独立 SSH 密钥和 Host 配置
- 自动识别已有 Docker Codex 目录和容器工作区，也可手动改路径
- API 配置列表可新建、切换，也可跟随主空间配置
- 支持一次性导入 Codex++ 配置，导入后不依赖 Codex++
- 内置 Chat Completions → Responses 转换，可直接使用 DeepSeek 等 Chat 上游
- Chat 上游支持 `tool_search` 与 `multi_agent_v1`，Docker Codex 多智能体可完成发现、启动、等待和关闭子智能体的完整流程
- 切换后自动重启远程 app-server 并主动重连
- 不自动安装额外 Codex skill，保留主空间现有配置
- SSH 仅监听 `127.0.0.1`，安装包不包含任何 API Key、auth.json 或私钥

适合希望把 Codex 工作区隔离进 Docker，同时又需要方便切换 API 的 Windows 用户。

前置条件：Windows 10/11 x64、Docker Desktop、Codex Desktop、Windows OpenSSH Client。

下载：`DockerCodexSuite-Setup-1.0.0.beta1-win-x64.exe`

校验值见同目录 `SHA256SUMS.txt`。

注意：这是未获 OpenAI 背书的社区工具；当前测试构建未签名，Windows 可能显示 SmartScreen 提示。容器为支持嵌套沙箱使用了 `SYS_ADMIN` 和 `seccomp=unconfined`，请阅读随包安全说明后使用。

#Codex #Docker #Windows #开发工具 #AI编程

# Claude Desktop for Windows 中国版

在 Windows 上使用官方 Claude Desktop，通过第三方推理网关（DeepSeek、MiniMax、cc-switch、自建反代等）对话和写代码，不需要 claude.ai 登录。

> 本项目受 [aaddrick/claude-desktop-debian](https://github.com/aaddrick/claude-desktop-debian) 启发。2026-11 版已从“改 Linux fork 的 app.asar”切换为“官方 Windows MSIX + 官方 3P 配置”，不再维护 minified JS 补丁。

## 为什么重写

旧版基于 Claude Desktop `1.6608.2` 的 Linux 构建，打了 5 个补丁（`claude-native` stub、Cowork bypass、CCD 环境透传、探针修复、WSL HostBackend）。2026-10 的官方 Windows 版已经到 `3.6556.2`，并且原生支持 **3P（third-party inference）**：

- 官方从 `HKCU\SOFTWARE\Policies\Claude` 读取 3P 配置；
- Chat / Code / Cowork 都走同一套官方推理路径；
- Windows 原生模块、托盘、Code CLI 都由官方包提供。

因此新版的默认做法是：**不解包、不修改 `app.asar`，只安装官方 MSIX 并写入受支持的 3P 策略**。这比继续追 minified 变量名可靠得多。

## 两种安装模式

| 模式 | 需要管理员 | Chat | Code | Cowork | 数据位置 |
|---|---|---|---|---|---|
| **便携版** | 否 | 可用（走网关） | 可用 | 不可用（官方要求 MSIX + Hyper-V） | 安装目录下 `data\`（用快捷方式启动） |
| **MSIX 版** | 通常需要（侧载/首次安装） | 可用（走网关） | 可用 | 可用（需 Hyper-V / 虚拟机平台） | `%LOCALAPPDATA%\Claude-3p` |

便携版解包官方 MSIX 到普通目录，用 `--user-data-dir` 隔离数据；Cowork 的 VM 服务需要 Windows 包身份、HCS/Hyper-V 和系统服务权限，便携版不再伪造 MSIX。

## 快速开始

1. 安装 [VC++ 2015-2022 x64 Redistributable](https://aka.ms/vs/17/release/vc_redist.x64.exe)（多数 Windows 已自带）。
2. 双击 `Install.bat`。
3. 选择模式：
   - `1` 便携版：输入安装目录（默认 `%LOCALAPPDATA%\Programs\Claude-CN`）。
   - `2` MSIX 版：安装官方包，适合需要 Cowork 的机器。
4. 输入网关根地址、API Key，可选模型 ID（逗号分隔，留空则自动发现）。
5. 安装器会下载/校验官方 MSIX（284 MB，SHA-256 固定），安装，写 3P 策略，并做自检。

安装器会先找仓库目录下的 `Claude*.msix`，再找 `%LOCALAPPDATA%\Claude-CN\cache`，最后才下载。手动下载的文件放在项目根目录即可。

安装器优先用 BITS 下载；如果网络慢，可以手动下载后指定本地文件：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 `
  -Mode Portable `
  -MsixPath .\Claude-20c019a1e61fa5b687616af57d31f97bb3181723.msix
```

### 手动下载 MSIX

```text
https://downloads.claude.ai/releases/win32/x64/3.6556.2/Claude-20c019a1e61fa5b687616af57d31f97bb3181723.msix
SHA-256: C0AC245C9AD458ABD550BCBF2A0B34C75C51173A27F3C870602E5452CF3484F1
大小:    284230330 bytes
```

Anthropic 可能在同一 URL 替换文件。若哈希不匹配，安装器会拒绝继续；请重新下载，或只在确认文件来源后使用 `-SkipHashCheck`。

## 网关要求

3P 模式要求网关实现 Anthropic Messages API：

- `POST /v1/messages`，支持流式和 tool use；
- `GET /v1/models` 可选；不实现时需要在安装时或 `Set-Gateway.bat` 里填写模型 ID；
- 基地址填**根地址**，不要填到 `/v1/messages`。程序会自己追加 `/v1/messages`。

常见组合：

| 场景 | 基地址示例 | 认证 |
|---|---|---|
| cc-switch 本地代理 | `http://127.0.0.1:3000` | `bearer` |
| 自建 Anthropic 反代 | `https://your-gateway.example.com` | `bearer` 或 `x-api-key` |
| 厂商 Anthropic 兼容端点 | 厂商文档给出的根地址 | 按厂商要求 |

如果网关只支持 OpenAI 协议，需要先经过 cc-switch / LiteLLM / 自建转换层，不能直接填 OpenAI 的 `/v1/chat/completions`。

## 用 cc-switch 切换网关

安装器会先读 `%USERPROFILE%\.claude\settings.json`、`settings.local.json` 和 `ANTHROPIC_*` 环境变量，作为默认值。cc-switch 修改这些配置后：

1. 运行 `Set-Gateway.bat`（优先读取 `settings.json`，缺失时提示输入）；
2. 完全退出并重新打开 Claude Desktop。

官方 3P 配置在启动时读取；运行中的窗口不会热切换网关。

## 常用命令

```powershell
# 便携版，指定目录
.\Install.ps1 -Mode Portable -InstallDir D:\Claude-CN -BaseUrl http://127.0.0.1:3000 -ApiKey sk-xxx

# MSIX 版
.\Install.ps1 -Mode Msix -BaseUrl http://127.0.0.1:3000 -ApiKey sk-xxx

# 已有 MSIX，直接用本地文件
.\Install.ps1 -Mode Portable -MsixPath .\Claude.msix -BaseUrl ... -ApiKey ...

# 只更新网关
.\Set-Gateway.ps1 -BaseUrl http://127.0.0.1:3000 -ApiKey sk-xxx

# 卸载（默认保留聊天数据）
.\Uninstall.ps1

# 卸载并删除 3P 聊天数据
.\Uninstall.ps1 -PurgeData
```

非交互（适合脚本）：

```powershell
.\Install.ps1 -Mode Portable -InstallDir D:\Claude-CN `
  -BaseUrl http://127.0.0.1:3000 -ApiKey sk-xxx `
  -NonInteractive -NoLaunch
```

## MSIX 版与 Cowork

MSIX 版安装的是 Anthropic 官方包，包家族名 `Claude_pzs8sxrjxfjjc`，应用 ID `Claude`。Cowork 需要：

- Windows 10 19041+ 或 Windows 11；
- 开启“虚拟机平台”（Virtual Machine Platform），通常还需要 Hyper-V；
- 允许侧载/安装受信任的 MSIX（设置 → 应用 → 高级应用设置，或企业策略）；
- 首次 Cowork 会下载约 1 GB 的工作区，网络需可达 `downloads.claude.ai`。

以管理员身份检查/开启虚拟机平台：

```powershell
dism /online /get-featureinfo /featurename:VirtualMachinePlatform
dism /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
```

开启后重启。官方也提供 Cowork readiness check，可先验证机器是否支持。

## 数据与隐私

- 便携版：`<安装目录>\data\`。快捷方式通过 `Launch-Claude.vbs` 设置
  `CLAUDE_USER_DATA_DIR`，会话、配置库和日志都在这里；直接运行
  `app\claude.exe` 会回落到 `%LOCALAPPDATA%\Claude-3p`；
- MSIX 版：`%LOCALAPPDATA%\Claude-3p`；
- 3P 策略：`HKCU\SOFTWARE\Policies\Claude`；
- API Key 存在 HKCU 策略值里，只有当前 Windows 用户可读；
- 安装器写入 `disableNonessentialTelemetry=true` 和 `disableEssentialTelemetry=true`；
- 对话内容只应发往你配置的网关。网关运营方仍能看到 prompt/response，请自行评估。

卸载默认不删除聊天数据；只有 `-PurgeData` 才会删除 `Claude-3p` 数据目录。

## 故障排查

| 现象 | 处理 |
|---|---|
| 安装器提示 SHA-256 不匹配 | Anthropic 替换了同 URL 的文件；重新下载，或 `-SkipHashCheck` 仅在信任文件时使用 |
| 启动后 3P 配置错误 | 运行 `Set-Gateway.bat` 重写策略；确认 URL 是根地址、Key 有效、`AuthScheme` 正确 |
| Chat 能开但请求 404 | 网关没有实现 `/v1/messages`，或基地址多写了 `/v1` |
| 模型列表为空 | 网关不支持 `/v1/models`；用 `Set-Gateway.ps1 -Models model-a,model-b` 显式列出 |
| Code 首次打开很慢 | 官方客户端要下载约 106 MB 的 Claude Code CLI；网络慢时多等一会 |
| Cowork 显示 unsupported / msix_required | 便携版不支持 Cowork；改用 MSIX 版并开启虚拟机平台 |
| 便携版启动空白 | 确认 `app\resources\app.asar` 和 `app\resources\ion-dist\index.html` 存在；重新安装 |
| 安装 MSIX 报 0x80073CFF | 系统策略禁止侧载；启用“允许安装受信任的应用”或改用便携版 |
| 旧版数据看不到 | 官方客户端会尝试从旧 3P 目录迁移；不要先删除 `%LOCALAPPDATA%\Claude-3p` |

安装日志在项目目录的 `install.log`。自检失败时，日志会列出文件或注册表项。

## 仓库结构

```text
├── Install.bat / Install.ps1         # 安装器
├── Set-Gateway.bat / Set-Gateway.ps1 # 更新网关
├── Uninstall.bat / Uninstall.ps1     # 卸载
├── lib/Common.ps1                    # 下载、校验、策略、解包、快捷方式
├── assets/                           # 图标 + Launch-Claude.vbs
├── docs/legacy-patches.md            # 旧版补丁说明（已移除）
└── CHANGELOG.md
```

安装后便携版的布局：

```text
<安装目录>\
├── app\              # 官方 MSIX 的 app/ 内容（claude.exe、resources、ion-dist）
├── data\             # 便携版 userData（会话/配置/日志）
└── Launch-Claude.vbs # 设置 CLAUDE_USER_DATA_DIR 后启动 app\claude.exe
```

## 旧版补丁为什么删除

旧版 5 个补丁的作用、失效原因和迁移结论见 [`docs/legacy-patches.md`](docs/legacy-patches.md)。核心结论：

- 官方 Windows 包已经有真实的 `@ant/claude-native` 绑定，不需要 JS stub；
- 3P 是官方模式，不需要 `NODE_ENV=production` / 强制 `windowsStore`；
- Code 的网关由官方 3P 配置传递，不需要 hook `child_process.spawn`；
- 探针和模型校验由官方实现处理，不需要改 `index.js`；
- 新 Cowork 是 Go 的 `cowork-svc.exe` + HCS/Hyper-V，旧的 WSL HostBackend 协议不再匹配。

旧实现仍保留在 git 历史中，需要对照时查看上一次提交。

## 验证范围

本仓库的静态验证包括：MSIX SHA-256 / ZIP 完整性、`app.asar` 与 `ion-dist` 布局、3P 策略键名、安装器自检。真实 Windows 上的 Chat/Code/Cowork 端到端行为取决于你的 Windows 版本、网关和 Hyper-V 配置；建议先在测试目录跑便携版，再决定是否装 MSIX。

## 致谢

- [aaddrick/claude-desktop-debian](https://github.com/aaddrick/claude-desktop-debian)：Linux 打包与 launcher 思路；
- [cc-switch](https://github.com/farion1231/cc-switch)：网关切换；
- Anthropic：官方 Claude Desktop 与 3P 文档。

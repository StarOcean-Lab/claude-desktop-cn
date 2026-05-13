# Claude Desktop for Windows 中国版

在 Windows 上免安装、免登录、免魔法使用 Claude Desktop，接入 DeepSeek / MiniMax 等第三方模型。**除 Chat tab 外，体验几乎等同于官方 Claude Desktop。**

> 本项目受 [aaddrick/claude-desktop-debian](https://github.com/aaddrick/claude-desktop-debian) 启发，在其 Linux fork 基础上做了 Windows 适配和一系列补丁。

## 为什么需要这个项目

在中国大陆使用官方 Claude Desktop 有四个障碍：

- **网络不可达** — `claude.ai` / `anthropic.com` 被墙，Chat tab 无法登录
- **必须 MSIX 安装** — 官方只有 MSIX 安装包，便携部署不可能
- **模型限制** — 官方只允许 Anthropic 自有模型，无法用 DeepSeek 等第三方
- **账号门槛** — 需要稳定的 Anthropic 账号，门槛越来越高

本项目把这四个障碍全干掉了。最终效果：一个 `D:\claude-desktop-portable\` 目录，双击 `Claude.exe` 就直接能用，**除了 Chat tab 以外，跟官方 Claude Desktop 体验几乎一模一样**。

## 能做什么

- **Cowork tab 完整可用** — 流式对话、文件读写、ripgrep 搜索、任务管理、MCP servers
- **Code tab 完整可用** — Claude Code CLI，本地 binary 运行，不下载任何东西
- **Bash 命令执行（接近官方体验）** — 自动检测 WSL2 发行版和用户，把 bash 命令转发到真 Linux 环境执行（`/etc`、`/proc`、`apt` 等都正常），跟官方 Claude Desktop 的 VM 沙箱体验几乎一致。没有 WSL 也能退回到 Windows 原生 shell
- **接入任意 Anthropic 兼容 gateway** — DeepSeek、MiniMax、自建反代都可以
- **数据隔离** — 用户数据在 `%LOCALAPPDATA%\Claude-3p\`，跟官方 Claude Desktop 互不干扰
- **开箱即用** — `prebuilt/` 目录放了打好补丁的 `app.asar`，5 分钟跑通

## 不能做什么

| 功能 | 说明 |
|---|---|
| Chat tab | 需要登录 `claude.ai` OAuth，不走第三方 gateway，无法使用 |
| Computer Use | 需要 macOS Swift addon，Windows 没有 |
| VM 硬隔离 | portable 模式无法满足 MSIX + Hyper-V，bash 走 WSL2/HostBackend |
| 自动更新 | 永久禁用 |

## 快速开始

> **Note**
> `prebuilt/` 目录里已经放好了打好补丁的 `app.asar`，跳过手动 patching。

**前置条件**：安装 [Claude Code](https://github.com/anthropics/claude-code) 和 VC++ 2015-2022 x64 Redistributable。

双击 `Install.bat`，按 GUI 向导完成安装。

> **Tip**
> 推荐用 [cc-switch](https://github.com/farion1231/cc-switch) 管理 gateway 配置：在 cc-switch 中开启代理，`ANTHROPIC_BASE_URL` 指向 cc-switch 的代理地址，之后切模型、换 key、换厂商一键完成，**免重启 Claude Desktop**。

## 原理

本项目对 [aaddrick 的 Linux Claude Desktop fork](https://github.com/aaddrick/claude-desktop-debian) 打了 5 个补丁，让它能在 Windows 上以 3p（第三方推理）模式运行：

| 补丁 | 解决的问题 |
|---|---|
| **claude-native stub** | 用 JS stub 替换 Linux 原生模块 `@ant/claude-native`，提供 `readRegistryValues` 桥接 + Proxy 兜底。解决启动崩溃、空白窗口两大故障 |
| **Cowork bypass** | 强制 `process.windowsStore = true`（绕过 MSIX 检测）、设 `NODE_ENV=production`（允许第三方模型名）、strip `ANTHROPIC_*` 环境变量（防止系统 env 污染推理路径） |
| **CCD env passthrough** | Hook Code tab 的 spawn，让 `claude.exe` 子进程继承用户级系统环境变量而非 enterprise-policies 配置。仅双 gateway 场景需要 |
| **Probe fix** | 把端点可达性探针从 POST `/v1/messages` 简化为 GET base URL，避免没带认证 header 被 gateway 拒绝导致误报 |
| **HostBackend daemon** | 用 Windows daemon 替换 Linux VM 沙箱，自动检测 WSL2 Ubuntu 转发 bash 命令，没有 WSL 则回退到 Windows 原生 shell |

所有补丁由 `patches/apply-all-patches.ps1` 一键执行。aaddrick 发新版后跑一次即可，脚本能抗 minifier 变量重命名。

## 仓库结构

```
├── README.md
├── 0-README.txt                               ← 速查卡片
├── Install.bat                                ← GUI 安装器启动入口（双击运行）
├── Install.ps1                                ← GUI 安装向导
├── patches/
│   ├── apply-all-patches.ps1                  ← 一键：解包 → 打补丁 → 打包
│   ├── claude-native-stub.js                  ← Linux JS stub + readRegistryValues 桥接
│   ├── cowork-bypass-snippet.js               ← Cowork tab 解锁
│   ├── ccd-env-passthrough.js                 ← Code/Cowork 双 gateway 隔离
│   ├── frame-fix-wrapper-full-patches.js      ← 四合一 wrapper
│   ├── apply-probe-fix.cjs                    ← 端点探针修复
│   ├── cowork-vm-service-win.js               ← Windows HostBackend daemon（WSL2 自动检测）
│   ├── enterprise-policies.example.json       ← 可选 policy 模板
│   ├── native-modules-windows-x64.zip          ← Electron 41.5.0 ABI 兼容 node-pty
│   ├── repack-asar.ps1                        ← 独立打包脚本
│   └── icons/                                 ← 应用图标
└── prebuilt/
    ├── app.asar                               ← 打好补丁的 app.asar (25 MB)
    ├── app.asar.unpacked/                     ← 原生模块目录
    └── ion-dist/                              ← SPA UI 资源 (~100 MB，漏拷启动空白窗口)
```

## 系统要求

| 组件 | 最低 | 验证版本 |
|---|---|---|
| Windows | 10 21H2 或 11（x64） | 11 22H2 build 22621 |
| VC++ Redistributable | 2015-2022 x64 | v14.50.35710.00 |
| Node.js | 18+（asar 打包 + Claude Code CLI） | 22.17.1 |
| Electron | 41.5.0 win32-x64 | 41.5.0 |
| WSL2（可选，推荐） | 任意发行版，自动检测 | 已验证 Ubuntu / Debian / Kali |

无需管理员权限、无需改注册表、无需 `claude.ai` / `anthropic.com` 网络可达、无需官方 Claude Desktop 已安装。

## 支持的国内厂商

DeepSeek、MiniMax、豆包、通义千问、智谱等，只要厂商提供了 Anthropic Messages API 兼容端点就能直接用。换模型、换 key、换厂商通过 [cc-switch](https://github.com/farion1231/cc-switch) 代理一键切换，**无需重启 Claude Desktop**，非常方便。

## 致谢

- [aaddrick/claude-desktop-debian](https://github.com/aaddrick/claude-desktop-debian) — Linux Claude Desktop fork 和 frame-fix-wrapper，整个 Windows 移植的基础
- [Anthropic](https://www.anthropic.com/) — Claude Desktop 和 Claude Code CLI
- [Electron](https://www.electronjs.org/) — 跨平台桌面框架

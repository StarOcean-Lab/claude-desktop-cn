═══════════════════════════════════════════════════════════════════════
   Claude Desktop · Windows 3p Portable 部署 Kit
═══════════════════════════════════════════════════════════════════════

本包含完整部署所需的全部文件 + 实证修复 patches。把整个包给同事，
他照着 Claude-Desktop-Windows-完整部署指南.md 第 0 章 Quick Start
12 步走 30 分钟即可跑通。

──────────────────────────────────────────────────────────────────────
内容清单
──────────────────────────────────────────────────────────────────────

Claude-Desktop-Windows-完整部署指南.md      主指南 (925 行 / ~40 KB)
                                            按 §0 Quick Start 一条龙做

patches/
├── claude-native-stub.js                   核心 stub: Linux JS stub
│                                           + readRegistryValues 桥接
│                                           解决"无窗口/空白窗口"两大故障
│
├── cowork-bypass-snippet.js                Cowork tab 解锁 (3 块 patch)
│                                           - process.windowsStore=true
│                                           - NODE_ENV=production
│                                           - delete process.env.ANTHROPIC_*
│
├── ccd-env-passthrough.js                  Code tab spawn hook
│                                           (仅当 Cowork/Code 用不同 gateway)
│
├── frame-fix-wrapper-full-patches.js       一键合并版 wrapper
│                                           = aaddrick wrapper
│                                           + cowork-bypass + ccd-passthrough
│
├── enterprise-policies.example.json        可选 override 模板
│                                           默认配置走 ~/.claude/settings.json
│                                           只在需要 Cowork/CLI 双网关隔离时用
│
├── native-modules-windows-x64.zip          Electron 41.5.0 ABI 兼容的
│                                           node-pty 4 件套（520 KB）
│                                           Code tab 必需
│
└── repack-asar.ps1                         一键 repack 脚本

prebuilt/
├── app.asar                                已经 patched 好的 app.asar
│                                           (无需自己跑 §3.3 整个 patch
│                                            流程，跳过去用现成的)
├── app.asar.unpacked/                      含 native modules 的运行时目录
│                                           (含 cowork-vm-service.js +
│                                            conpty.node + winpty 三件套)
└── ion-dist/                               SPA UI 资源 (~100 MB)
                                            app:// 协议从这里加载页面;
                                            缺失会导致启动报
                                            "ERR_FILE_NOT_FOUND
                                             app://localhost/epitaxy"

──────────────────────────────────────────────────────────────────────
极速部署（用 prebuilt/ 跳过 patch 流程，5 分钟）
──────────────────────────────────────────────────────────────────────

1. 装 VC++ 2015-2022 x64 Redistributable
   下载: https://aka.ms/vs/17/release/vc_redist.x64.exe

2. 装 npm Claude Code CLI (Code tab 必需)
   npm install -g @anthropic-ai/claude-code

3. 下载 Electron 41.5.0 win32-x64
   https://github.com/electron/electron/releases/download/v41.5.0/electron-v41.5.0-win32-x64.zip
   解压到 D:\claude-desktop-portable\
   把 electron.exe 改名为 Claude.exe

4. 拷贝 prebuilt/app.asar 到 D:\claude-desktop-portable\resources\app.asar
   拷贝 prebuilt/app.asar.unpacked/ 到 D:\claude-desktop-portable\resources\app.asar.unpacked\
   拷贝 prebuilt/ion-dist/         到 D:\claude-desktop-portable\resources\ion-dist\
                                    (必需; 否则启动时 app://localhost/ 会 ERR_FILE_NOT_FOUND)

5. 配 ~/.claude/settings.json (Cowork + CLI 共用同一份配置)
   {
     "env": {
       "ANTHROPIC_BASE_URL": "https://your.gateway/anthropic",
       "ANTHROPIC_AUTH_TOKEN": "sk-..."
     }
   }
   (双 gateway 隔离场景才需要 enterprise-policies.json，见主指南)

6. 拷贝 npm 装的 claude.exe 到 CCD 缓存路径
   $ver = '2.1.128'
   $dir = "$env:LOCALAPPDATA\Claude-3p\claude-code\$ver"
   New-Item -ItemType Directory -Path $dir -Force
   Copy-Item "$(npm root -g)\@anthropic-ai\claude-code\bin\claude.exe" "$dir\claude.exe" -Force
   New-Item -ItemType File -Path "$dir\.verified" -Force

7. 双击 D:\claude-desktop-portable\Claude.exe → 应见聊天界面

详细步骤 / 故障排查 / 双 gateway 配置 / 升级流程 →
全部在主指南里。

──────────────────────────────────────────────────────────────────────
不能解锁的功能（已知限制）
──────────────────────────────────────────────────────────────────────

✗ Chat tab               需要 Anthropic 账号登录 claude.ai (国内不可达)
✗ Computer Use           需要 macOS Swift addon
✗ 沙箱隔离 (Bwrap/KVM)  HostBackend 模式无隔离；有 WSL2 可后续添加

✓ Cowork 完整功能（shell 命令执行、ripgrep 搜索、文件读写、任务管理）
  (2026-05-13: 新增 Windows HostBackend daemon 支持)
✓ Code tab 完整 Claude Code (含 MCP servers)
✓ 多 gateway 隔离 (Cowork=DeepSeek, Code=right.codes 等)

主指南 §8 有完整对比表。

═══════════════════════════════════════════════════════════════════════

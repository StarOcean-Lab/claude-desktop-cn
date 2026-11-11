Claude Desktop for Windows 中国版 - 速查卡
==========================================

新版：官方 Windows MSIX 5.1231.2 + 官方 3P 配置
旧版：1.6608.2 Linux fork + app.asar 补丁（已删除）

两种模式
--------
1) 便携版（推荐先试）
   - 无需管理员
   - Chat / Code 可用，Cowork 不可用
   - 数据在 <安装目录>\data（用桌面快捷方式启动）
   - 双击 Install.bat，选择 1

2) MSIX 版
   - 安装官方 MSIX，支持 Cowork
   - 需要侧载/管理员；Cowork 需要 Hyper-V / 虚拟机平台
   - 数据在 %LOCALAPPDATA%\Claude-3p
   - 双击 Install.bat，选择 2

安装前
------
- 64 位 Windows 10 19041+ / Windows 11
- VC++ 2015-2022 x64 Redistributable
- 一个实现 Anthropic Messages API 的网关
  （POST /v1/messages，支持流式 + tool use）
- 网关基地址填根地址，不要带 /v1/messages

手动下载 MSIX
-------------
https://downloads.claude.ai/releases/win32/x64/5.1231.2/Claude-26912242b6649f3e503e012d9b7b9367d09c68e4.msix
SHA-256: 49FBF2FC335A2CC19BBC8C7D22016F5EFFD5FB3D90F3F0EE60F5A912961AC97B
大小:    297627772 bytes

国内镜像（同 SHA-256）：
https://github.com/Wangnov/claude-app-mirror/releases/download/claude-app-v5.1231.2/Claude-win-x64.msix
https://gh-proxy.com/https://github.com/Wangnov/claude-app-mirror/releases/download/claude-app-v5.1231.2/Claude-win-x64.msix

指定本地文件：
  powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 `
    -Mode Portable -MsixPath .\Claude-win-x64.msix

切换网关
--------
  Set-Gateway.bat
  （读取 %USERPROFILE%\.claude\settings.json 或交互输入）
  完全退出并重启 Claude Desktop。

卸载
----
  Uninstall.bat
  （默认保留聊天数据；-PurgeData 才删除）

数据/配置
---------
  便携版数据: <安装目录>\data（Launch-Claude.vbs 设置 CLAUDE_USER_DATA_DIR）
  MSIX 数据:  %LOCALAPPDATA%\Claude-3p
  3P 策略:    HKCU\SOFTWARE\Policies\Claude
  安装日志:   install.log

故障排查
--------
- 3P 配置错误：检查 URL/Key/AuthScheme，运行 Set-Gateway.bat
- 模型为空：网关不支持 /v1/models，用 -Models 显式列出
- Cowork msix_required：便携版不支持，改用 MSIX 版
- Cowork 首次下载：1.35 GB VM 根盘，国内可能很慢；见 docs/cowork-offline.md
- 0x80073CFF：系统禁止侧载，启用“允许安装受信任的应用”
- Code 首次慢：官方要下载约 106 MB 的 Claude Code CLI

更多说明见 README.md、docs/cowork-offline.md 和 docs/legacy-patches.md。

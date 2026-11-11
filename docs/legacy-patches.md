# 旧版 Windows 补丁退役说明

旧版（Claude Desktop `1.6608.2`，Linux fork）通过 `frame-fix-wrapper.js`
注入 5 个补丁。新版基于官方 Windows MSIX `3.6556.2`，这些补丁不再适用，
已从工作树删除，仅保留在 git 历史中。

| 旧补丁 | 旧作用 | 为什么退役 |
|---|---|---|
| `claude-native-stub.js` | 用 JS stub 替换 Linux 的 `@ant/claude-native`，并把 `~/.claude/settings.json` 合成为 3P 配置 | 官方 Windows MSIX 自带真实的 `claude-native-binding.node`；3P 配置由官方 `HKCU\SOFTWARE\Policies\Claude` 读取 |
| `cowork-bypass-snippet.js` | 强制 `process.windowsStore=true`、`NODE_ENV=production`、删除 `ANTHROPIC_*`，解锁 Cowork | 3P 是官方模式；任意模型名由官方 schema 接受；环境变量不再参与 3P 配置 |
| `ccd-env-passthrough.js` | Hook `child_process.spawn`，让 Code 子进程使用用户级网关 | 官方 3P 配置会把 gateway 凭据传给 Code；不再需要改 `child_process` |
| `apply-probe-fix.cjs` | 把网关探针从 POST `/v1/messages` 改为 GET 根地址 | 官方探针和模型发现是 3P 的一部分；配置无效时会在 UI 报错，不再需要改 `index.js` |
| `cowork-vm-service-win.js` | 用 Node/WSL2 HostBackend 替换 Linux VM 服务，监听命名管道 | 新 Cowork 是 Go 的 `cowork-svc.exe` + HCS/Hyper-V；协议、权限和包身份都变了，旧 daemon 不再兼容 |

## 迁移结论

1. **便携版**：官方 MSIX 解包后直接运行 `claude.exe`，用
   `--user-data-dir` 隔离数据。Chat/Code 仍可用；Cowork 需要 MSIX，
   便携版不再伪造 `windowsStore`。
2. **MSIX 版**：安装官方包后，官方 3P 配置即可启用 Chat/Code/Cowork。
   Cowork 还要求 Hyper-V / 虚拟机平台和约 1 GB 的首次工作区下载。
3. **网关**：写 HKCU 策略，不再改 `app.asar`；cc-switch 改完
   `settings.json` 后运行 `Set-Gateway.bat` 再重启客户端。
4. **旧数据**：官方客户端会尝试从旧 3P 目录迁移；升级时不要先删除
   `%LOCALAPPDATA%\Claude-3p`。

## 何时需要重新引入 asar 补丁

只有满足以下条件才考虑：

- 官方 Windows 包存在真实的 Linux/Windows 功能缺口；
- 该缺口无法通过官方 3P 配置、策略键或启动参数解决；
- 有一个可在每次上游更新后稳定定位的锚点；
- 能证明补丁改变了 pristine 包的字节，并有退役条件。

否则默认走官方配置路径。

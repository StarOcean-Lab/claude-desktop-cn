# Cowork VM 下载与离线方案

Cowork 不是普通 Electron 窗口：它要在本机启动一个 Linux 虚拟机。标准 MSIX
首次使用 Cowork 时，会从 `downloads.claude.ai` 下载 VM 根盘和内核。本文记录
实际文件、国内网络情况、官方离线包和社区分流，供排查使用。

## 下载了什么

以 5.1231.2（VM bundle `072b6cbfe74f428a98bd86035f83b322b369d1f1`）为例：

| 文件 | 大小 | SHA-256（win32 x64） | 用途 |
|---|---:|---|---|
| `rootfs.vhdx.zst` | 1,309,889,215 B（约 1.31 GB） | `c480f8a62d0d9be20e1a1ee31b9f25c73097f793127dcefa90b0c59ada0e12ad` | Linux 根盘，解压约 7.83 GB |
| `vmlinuz.zst` | 14,758,684 B | `3118616ef6ba3866652284b8b4c224a96876c56091724c35c93caf1ccb9b50a9` | 内核 |
| `initrd.zst` | 28,024,101 B | `e3c5ce2b8e9e9adf67de7ec83cafa4a0c65fab8a22036a6b53f03c9765b3342a` | initramfs |
| 合计 | 约 1.35 GB 压缩 | | 解压后约 8 GB |

URL 形如：

```text
https://downloads.claude.ai/vms/linux/x64/<bundle-sha>/rootfs.vhdx.zst
https://downloads.claude.ai/vms/linux/x64/<bundle-sha>/vmlinuz.zst
https://downloads.claude.ai/vms/linux/x64/<bundle-sha>/initrd.zst
```

5.1231.2 和 3.6556.2 的 bundle SHA 都是
`072b6cbfe74f428a98bd86035f83b322b369d1f1`，所以这三个文件可以直接复用。

## 国内能下吗

能连，但不稳定。`downloads.claude.ai` 是 Google Cloud Storage 前置的自定义域名，
国内常见被墙、限速或中断。我这边实测：

- `rootfs.vhdx.zst` 返回 HTTP 200，`Content-Type: application/zstd`；
- 单线程 1 MB range 约 **143 KB/s**，1.35 GB 约 **2.6 小时**；
- aria2 8–16 线程或代理能快很多，但不保证；镜像作者也明确说该域名在国内
  经常被墙或限速。

所以“能下载”不等于“能稳定装好 Cowork”。

## 本地预置（安装器已支持）

如果已经手动下好三个 `.zst`，放在项目根目录（或任意目录），安装器会在
MSIX 安装后校验 SHA-256 并复制到：

```text
%LOCALAPPDATA%\Claude-3p\vm_bundles\claudevm.bundle
```

```powershell
.\Install.ps1 -Mode Msix -VmBundleDir . -BaseUrl ... -ApiKey ...
```

首次 Cowork 会直接本地解压，不再访问 `downloads.claude.ai`。复制 1.35 GB
后还要解压约 7.8 GB，建议 C: 至少留 10 GB。版本或哈希不匹配时安装器会
拒绝使用，不会把旧 VM 塞进去。

## 官方离线 MSIX（推荐）

Anthropic 提供**离线安装包**，把 VM 工作区和 Claude CLI 都打进包里，运行时
不需要再访问 `downloads.claude.ai`。体积比标准包大数 GB。

固定入口（会 302 到版本化文件）：

```text
https://claude.ai/api/desktop/win32/x64/offline/latest/redirect
```

国内直连这个入口会 **403**（区域限制），需要代理/海外网络下载一次。下载后：

```powershell
.\Install.ps1 -Mode Msix -MsixPath .\Claude-offline.msix -SkipHashCheck
```

离线包的 size/SHA-256 与标准包不同，`-SkipHashCheck` 会跳过标准包的校验；
只对你确认来源的官方离线包使用。安装后的 MSIX 包身份、Cowork 和 3P 配置
与标准包一致。

## 社区镜像/分流

### 标准 MSIX（只解决安装包）

- [Wangnov/claude-app-mirror](https://github.com/Wangnov/claude-app-mirror)：
  官方原包镜像，5.1231.2 的 Windows x64 MSIX 在 GitHub Releases；另有
  `https://claudeapp.agentsmirror.com/latest/win-x64` 短链。只镜像标准 MSIX，
  **不包含** Cowork VM。
- [l1i1/ClaudeDesktop-Installer](https://github.com/l1i1/ClaudeDesktop-Installer)：
  多源下载标准 MSIX（GitHub/R2/官方）+ 补 Claude Code CLI；不包含 VM。
- 百度网盘有 1.9255.0 标准 MSIX + `claude.exe` + 切换工具的分享，例如
  [cnblogs 教程](https://www.cnblogs.com/lijiext/p/20186706)；也不是 Cowork VM。

### Cowork VM（1.35 GB）

没有找到可靠的、版本化的公开镜像。当前可见的途径：

- [CSDN 手动下载教程](https://blog.csdn.net/sun_ranger/article/details/161122142)：
  用 aria2 下载三个 `.zst`，再放进 VM bundle 目录；只是教程，不是镜像。
- [linux.sb 的百度网盘分享](https://linux.sb/topic/12584)：
  `pan.baidu.com/s/1VntkNOGr_eMsBmps8rhvlQ?pwd=txyc`。作者自己说没下载，
  未验证版本；可能是旧版/整体修复包。VM 镜像会在本机执行代码，不建议直接
  使用来历不明的旧镜像。
- [chat2work](https://github.com/is-hp-is-mad/chat2work)：第三方工具，
  提供从已装好的 Claude 备份 VM 镜像的功能（需自行审代码）。

### 从一台能用的机器复制

如果另一台机器已经成功运行同版本 Cowork，可以复制整个 VM bundle：

```text
%LOCALAPPDATA%\Claude-3p\vm_bundles\claudevm.bundle
```

MSIX 的包内视角可能把路径虚拟化到：

```text
%LOCALAPPDATA%\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude-3p\vm_bundles\claudevm.bundle
```

如果 Cowork 报 “VHDX file not found” 或下载完成后仍找不到 VM，社区做法是
在两处之间做 junction/hardlink：

- [CocoLoop 讨论](https://www.cocoloop.cn/t/topic/5008)
- [linux.do 讨论](https://linux.do/t/topic/2072551/10)

复制/链接前确认目标版本与 `072b6c...` 一致；不同版本混用会导致 Cowork
启动失败。hardlink 要求同一卷；跨盘用 junction。

## 官方 preseed 机制

客户端支持从安装包预置 VM bundle：

```text
<安装目录>\app\resources\preseed\vm_bundle\<bundle-sha>.zst
```

存在这个文件时，客户端会把它复制到缓存，不再下载。标准 MSIX 不带这个文件；
官方 offline MSIX 带。社区如果以后做出 5.1231.2 的 preseed 包，放到该路径
即可。不要在版本不匹配时硬塞旧包。

## 建议顺序

1. **MSIX 版 + 官方 offline MSIX**：最稳，运行时零下载；需要代理下一次。
2. **代理 + aria2 8–16 线程**：直接下三个 `.zst`，适合能稳定代理的环境。
3. **从同版本可用机器复制 `claudevm.bundle`**：适合内网/朋友互助。
4. 不要直接使用未验证的旧版百度网盘 VM；版本/安全风险不值得。

## 参考

- 官方 3P 安装文档（含 offline 说明）：
  <https://claude.com/docs/third-party/claude-desktop/installation>
- 标准 MSIX 镜像清单：
  <https://github.com/Wangnov/claude-app-mirror/releases/download/claude-app-v5.1231.2/release-manifest.json>
- 5.1231.2 VM bundle 仍为 `072b6c...`（从 app.asar 的
  `vmBundleManifest` 提取）。

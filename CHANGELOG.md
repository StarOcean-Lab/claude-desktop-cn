# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [5.1231.2-cn.1] - 2026-11-11

### Added

- Mirror-first MSIX download: `gh-proxy` / GitHub release
  (`Wangnov/claude-app-mirror`) before the official
  `downloads.claude.ai` URL, with the same pinned SHA-256.
- Local MSIX search in the project directory, `Downloads`, `下载`, and the
  desktop, so a manually downloaded file is found without `-MsixPath`.
- `docs/cowork-offline.md`: VM bundle URLs/sizes, official offline MSIX,
  community mirrors, preseed path, and the MSIX virtualization/hardlink fix.

### Changed

- **BREAKING**: rebased on the official Windows MSIX `5.1231.2`
  (297,627,772 bytes,
  `49FBF2FC335A2CC19BBC8C7D22016F5EFFD5FB3D90F3F0EE60F5A912961AC97B`).
- The 5.x package moved the SPA UI from `resources/ion-dist/` to
  `resources/ion-dist.asar`; the installer self-check accepts either layout.
- `-SkipHashCheck` with `-MsixPath` now skips both size and SHA-256, so the
  official multi-GB offline MSIX (which includes the Cowork VM and CLI) can be
  installed.
- MSIX install can stage a locally downloaded Cowork VM bundle
  (`rootfs.vhdx.zst`, `vmlinuz.zst`, `initrd.zst`) from the project root or
  `-VmBundleDir`, verify its pinned SHA-256 values, and copy it to
  `%LOCALAPPDATA%\Claude-3p\vm_bundles\claudevm.bundle` to avoid the 1.35 GB
  runtime download.

### Notes

- The Cowork VM bundle is unchanged from 3.6556.2:
  `072b6cbfe74f428a98bd86035f83b322b369d1f1`.
- No reliable public mirror of the 1.35 GB VM bundle was found; the official
  offline MSIX remains the supported no-download path.

## [3.6556.2-cn.1] - 2026-11-11

### Added

- Installer for the official Claude Desktop Windows MSIX `3.6556.2` (x64),
  with pinned size and SHA-256 verification.
- Portable mode: extracts the official `app/` tree, isolates user data with
  `CLAUDE_USER_DATA_DIR` + `--user-data-dir` through `Launch-Claude.vbs`, and
  creates a desktop shortcut without admin rights.
- MSIX mode: installs the official package (Cowork support) and registers a
  desktop shortcut through the `shell:AppsFolder` launcher.
- Official 3P configuration through `HKCU\SOFTWARE\Policies\Claude`:
  `inferenceProvider=gateway`, base URL, credential, auth scheme, model list,
  no sign-in chooser, no auto-update, and telemetry off.
- `Set-Gateway.ps1` / `Set-Gateway.bat`: refresh the policy from
  `%USERPROFILE%\.claude\settings.json` or from command-line arguments, for
  cc-switch workflows.
- `Uninstall.ps1` / `Uninstall.bat`: remove the package or portable app,
  restore the previous HKCU policy values, and optionally purge 3P data.
- Installer self-check for the app layout and the HKCU policy.
- `docs/legacy-patches.md` records why the old app.asar patch suite was
  retired.

### Changed

- **BREAKING**: the package is now based on the official Windows MSIX instead
  of the `1.6608.2` Linux-derived `app.asar`.
- `README.md` and `0-README.txt` now describe the two install modes, the
  gateway requirements, and the Cowork/Hyper-V constraint.
- The installer no longer requires Node.js, npm, or a separate Electron
  runtime download.

### Removed

- `prebuilt/app.asar`, `prebuilt/ion-dist`, and the old tray/icon copies.
- The `frame-fix-wrapper` patch, `claude-native` stub, Cowork bypass, CCD env
  passthrough, probe fix, WSL HostBackend daemon, and their helper scripts.

### Fixed

- Portable installs no longer depend on a stale asar patched against a
  six-month-old Linux build.
- The API key is no longer duplicated into a second config file; it lives only
  in the user's HKCU policy hive.

### Known limitations

- Cowork requires the MSIX package, package identity, and Hyper-V / Virtual
  Machine Platform. The portable mode intentionally does not fake MSIX.
- Chat/Code/Cowork against a real gateway were not end-to-end tested on
  Windows in this repository; see "验证范围" in the README.

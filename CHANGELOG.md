# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [3.6556.2-cn.1] - 2026-11-11

### Added

- Installer for the official Claude Desktop Windows MSIX `3.6556.2` (x64),
  with pinned size and SHA-256 verification.
- Portable mode: extracts the official `app/` tree, isolates user data with
  `--user-data-dir`, and creates a desktop shortcut without admin rights.
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

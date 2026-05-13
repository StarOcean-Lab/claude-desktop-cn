// Cowork-on-portable-Windows bypass snippets — paste into frame-fix-wrapper.js
// =============================================================================
// Insert these blocks immediately AFTER `console.log('[Frame Fix] Wrapper loaded');`
// They unlock Cowork tab on a portable (non-MSIX) Windows build.
//
// Four problems solved (in order):
// 1. yukonSilver gate: Hc() returns false for non-MSIX installs, the bundle
//    shows "Cowork requires a newer installation / msix_required". Force
//    process.windowsStore = true so Hc() short-circuits to true.
// 2. Anthropic-model-name validation: const LLA = NODE_ENV !== "production".
//    Electron leaves NODE_ENV unset, so LLA = true and the bundle rejects
//    inferenceModels names that don't look like Anthropic's catalog.
//    Force NODE_ENV = "production" before the main bundle is loaded.
// 3. user-level env contamination: Electron inherits the user's system env,
//    including ANTHROPIC_BASE_URL / ANTHROPIC_AUTH_TOKEN that may be set
//    for an already-working Claude Code CLI. Capture, then delete from
//    process.env. The CCD spawn hook re-injects them into spawned claude.exe
//    child processes (Code tab).
// 4. Cowork daemon auto-start: the main bundle only auto-spawns the VM
//    daemon on Linux (process.platform === "linux"). On Windows, we fork
//    cowork-vm-service-win.js (HostBackend) before the main bundle connects
//    to \\.\pipe\cowork-vm-service. Patched 2026-05-13.

// === BEGIN Cowork bypass blocks ==============================================

// (1) yukonSilver msix_required bypass
if (process.platform === 'win32' && !process.windowsStore) {
  try {
    Object.defineProperty(process, 'windowsStore', {
      value: true, writable: false, configurable: true, enumerable: true,
    });
    console.log('[Cowork] forced process.windowsStore=true (bypass msix_required)');
  } catch (e) {
    console.warn('[Cowork] failed to set process.windowsStore:', e && e.message);
  }
}

// (2) Anthropic-model-name validation bypass via NODE_ENV
if (!process.env.NODE_ENV) {
  process.env.NODE_ENV = 'production';
  console.log('[Cowork] forced process.env.NODE_ENV=production (bypass model-name validation)');
}

// (3) Strip user-level ANTHROPIC_* env — Cowork uses enterprise-policies,
// Code tab gets re-injection via the spawn hook.
delete process.env.ANTHROPIC_BASE_URL;
delete process.env.ANTHROPIC_AUTH_TOKEN;
delete process.env.ANTHROPIC_API_KEY;
console.log('[Cowork] stripped ANTHROPIC_* from process.env (Cowork will read enterprise-policies)');

// === END Cowork bypass blocks ================================================

// === Cowork daemon auto-start (Windows HostBackend) ===========================
// On Linux, the main bundle auto-spawns cowork-vm-service.js. On Windows,
// the auto-spawn is gated behind process.platform === "linux". This mirrors
// the Linux logic: starts the HostBackend daemon that listens on
// \\.\pipe\cowork-vm-service before the main bundle connects.
// Always fork (no pipe probe) — if a daemon is already running, the new
// fork fails to bind the pipe and exits immediately.
if (process.platform === 'win32') {
  (function () {
    try {
      var _cp = require('child_process');
      var _fs = require('fs');
      var _path = require('path');
      var _os = require('os');

      // Daemon lives at resources/app.asar.unpacked/cowork-vm-service-win.js
      var _daemonPath = _path.join(
        process.resourcesPath || _path.dirname(__dirname),
        'app.asar.unpacked', 'cowork-vm-service-win.js'
      );
      if (!_fs.existsSync(_daemonPath)) {
        console.warn('[Cowork] Windows daemon not found at', _daemonPath);
        return;
      }

      var _logDir = _path.join(
        process.env.USERPROFILE || _os.homedir(),
        '.config', 'Claude', 'logs'
      );
      var _stdio = 'ignore';
      try {
        _fs.mkdirSync(_logDir, { recursive: true });
        var _logFd = _fs.openSync(
          _path.join(_logDir, 'cowork_vm_daemon.log'), 'a'
        );
        _stdio = ['ignore', _logFd, _logFd, 'ipc'];
      } catch (_) {}

      var _child = _cp.fork(_daemonPath, [], {
        detached: true,
        stdio: _stdio,
        env: Object.assign({}, process.env, { ELECTRON_RUN_AS_NODE: '1' }),
      });

      _child.on('error', function (err) {
        try { console.error('[Cowork] daemon spawn error:', err.message); } catch (_) {}
      });

      _child.unref();
      console.log('[Cowork] Windows daemon started, pid=' + _child.pid);
    } catch (e) {
      try { console.error('[Cowork] daemon auto-start failed:', e && e.message); } catch (_) {}
    }
  })();
}
// === END Cowork daemon auto-start =============================================

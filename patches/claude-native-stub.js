// Hybrid @ant/claude-native for Windows portable build.
// Loads the real native binding (.node) and merges in Electron-backed
// implementations for UI/window-management methods the native binding
// does not export. Patched 2026-05-13 to fix Cowork sandbox startup
// (VMP check, getHcsStatus) by loading the real .node binary.

const path = require('path');
const fs = require('fs');
const os = require('os');

// Load the real native binding
let native;
try {
  native = require('./claude-native-binding.node');
} catch (e) {
  console.warn('[Claude Native] Failed to load .node binding, using fallback:', e.message);
  native = {};
}

// === KeyboardKey (not in native binding, used by frontend UI) ===
const KeyboardKey = {
  Backspace: 43, Tab: 280, Enter: 261, Shift: 272, Control: 61,
  Alt: 40, CapsLock: 56, Escape: 85, Space: 276, PageUp: 251,
  PageDown: 250, End: 83, Home: 154, LeftArrow: 175, UpArrow: 282,
  RightArrow: 262, DownArrow: 81, Delete: 79, Meta: 187,
};
Object.freeze(KeyboardKey);

// === Electron window helpers (not in native binding) ===
function getWindow() {
  try {
    const { BrowserWindow } = require('electron');
    const focused = BrowserWindow.getFocusedWindow();
    if (focused) return focused;
    const win = BrowserWindow.getAllWindows().find((w) => !w.isDestroyed());
    return win || null;
  } catch (e) {
    console.warn('[Claude Native] getWindow() failed:', e);
    return null;
  }
}

// === readRegistryValues override: synthesize from settings.json ===
// The real native binding reads Windows Registry, but on the portable build
// we synthesize enterprise config from the user's Claude CLI settings.
function readRegistryValues(queries) {
  if (!Array.isArray(queries)) return [];
  let cfg = {};
  try {
    const envSources = [
      path.join(os.homedir(), '.claude', 'settings.json'),
      path.join(os.homedir(), '.claude', 'settings.local.json'),
    ];
    let merged = {};
    for (const p of envSources) {
      if (!fs.existsSync(p)) continue;
      try {
        const parsed = JSON.parse(fs.readFileSync(p, 'utf8'));
        if (parsed && typeof parsed.env === 'object') merged = { ...merged, ...parsed.env };
      } catch (e) {
        try { console.warn('[Claude Native] settings parse failed:', p, e.message); } catch {}
      }
    }
    const baseUrl = merged.ANTHROPIC_BASE_URL || '';
    const authToken = merged.ANTHROPIC_AUTH_TOKEN || '';
    const apiKey = merged.ANTHROPIC_API_KEY || '';
    if (baseUrl) {
      cfg = {
        deploymentMode: '3p',
        inferenceProvider: 'gateway',
        inferenceGatewayBaseUrl: baseUrl,
        inferenceGatewayApiKey: authToken || apiKey || '',
        inferenceGatewayAuthScheme: authToken ? 'bearer' : (apiKey ? 'x-api-key' : 'bearer'),
        inferenceModels: [
          ...new Set([
            merged.ANTHROPIC_DEFAULT_OPUS_MODEL || 'claude-opus-4-7',
            merged.ANTHROPIC_DEFAULT_SONNET_MODEL || 'claude-sonnet-4-6',
            merged.ANTHROPIC_DEFAULT_HAIKU_MODEL || 'claude-haiku-4-5',
          ].filter(Boolean)),
        ],
        disableAutoUpdates: true,
        disableDeploymentModeChooser: true,
      };
    }
    const policiesPath = path.join(process.env.LOCALAPPDATA || '', 'Claude-3p', 'enterprise-policies.json');
    if (fs.existsSync(policiesPath)) {
      try {
        const parsed = JSON.parse(fs.readFileSync(policiesPath, 'utf8'));
        cfg = { ...cfg, ...parsed };
      } catch (e) {
        try { console.warn('[Claude Native] enterprise-policies.json parse failed:', e.message); } catch {}
      }
    }
  } catch (e) {
    try { console.warn('[Claude Native] readRegistryValues: load failed:', e.message); } catch {}
  }
  return queries.map(q => {
    const key = q && q.hive && q.keyPath && q.valueName
      ? `${q.hive}\\${q.keyPath}\\${q.valueName}`
      : '';
    let value = null;
    if (q && q.valueName && Object.prototype.hasOwnProperty.call(cfg, q.valueName)) {
      value = cfg[q.valueName];
    }
    return { key, value };
  });
}

// === AuthRequest stub ===
class AuthRequest {
  static isAvailable() { return false; }
  async start(url, scheme, windowHandle) { throw new Error('AuthRequest not available'); }
  cancel() {}
}

// === Merge: native binding + Electron-backed extras ===
const merged = {
  ...native,
  readRegistryValues,
  KeyboardKey,
  AuthRequest: native.AuthRequest || AuthRequest,
  getWindowsVersion: () => "10.0.0",
  setWindowEffect: () => {},
  removeWindowEffect: () => {},
  getIsMaximized: () => { const w = getWindow(); return w ? w.isMaximized() : false; },
  flashFrame: (flash) => { const w = getWindow(); if (w) w.flashFrame(typeof flash === 'boolean' ? flash : true); },
  clearFlashFrame: () => { const w = getWindow(); if (w) w.flashFrame(false); },
  showNotification: () => {},
  setProgressBar: (progress) => {
    const w = getWindow();
    if (w && typeof progress === 'number') w.setProgressBar(Math.max(0, Math.min(1, progress)));
  },
  clearProgressBar: () => { const w = getWindow(); if (w) w.setProgressBar(-1); },
  setOverlayIcon: () => {},
  clearOverlayIcon: () => {},
};

// Proxy fallback for any missing method
module.exports = new Proxy(merged, {
  get(target, prop, receiver) {
    if (prop in target) return Reflect.get(target, prop, receiver);
    if (typeof prop === 'symbol') return undefined;
    console.warn(`[Claude Native] missing method '${String(prop)}' - returning no-op`);
    return (..._args) => undefined;
  },
});

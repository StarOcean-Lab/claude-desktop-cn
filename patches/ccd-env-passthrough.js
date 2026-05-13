// CCD env passthrough — paste-in patch for frame-fix-wrapper.js
// =============================================================
// Insert this whole block immediately AFTER the line
//   console.log('[Frame Fix] Wrapper loaded');
// in asar-extract/frame-fix-wrapper.js, then re-pack the asar.
//
// What it fixes
// -------------
// Claude Desktop's main bundle (T4(e) at .vite/build/index.js, search for
// `CLAUDE_CODE_ENTRYPOINT`) builds the env for spawned claude.exe child
// processes (Code tab) by setting:
//   ANTHROPIC_BASE_URL = enterprise-policies.json's inferenceGatewayBaseUrl
//   ANTHROPIC_AUTH_TOKEN = enterprise-policies.json's inferenceGatewayApiKey
// This forces Code tab's CLI subprocess to use the SAME gateway as Cowork
// tab. If you already have a working Claude Code CLI setup with a DIFFERENT
// gateway in your user-level system env (typical example: Cowork on DeepSeek
// for /v1/messages, Code on right.codes for full Claude Code subscription),
// this overwrites your setup and breaks Code tab.
//
// This patch hooks child_process.spawn (and execFile/fork) to detect spawns
// of claude.exe under the CCD storage dir. When detected, it restores the
// user's original ANTHROPIC_BASE_URL and ANTHROPIC_AUTH_TOKEN — captured at
// wrapper load time, before the main bundle has a chance to mutate them —
// into the spawn's env object. All other env vars from the main bundle pass
// through untouched, so SDK behaviour stays consistent.

// === BEGIN CCD env passthrough patch =====================================

// Capture user-level env vars at wrapper load (before main bundle runs).
const userBaseUrl = process.env.ANTHROPIC_BASE_URL || process.env.CLAUDE_CODE_USER_BASE_URL || '';
const userAuthToken = process.env.ANTHROPIC_AUTH_TOKEN || process.env.CLAUDE_CODE_USER_AUTH_TOKEN || '';
const userApiKey = process.env.ANTHROPIC_API_KEY || process.env.CLAUDE_CODE_USER_API_KEY || '';
const ccdEnvPassthrough = !!(userBaseUrl || userAuthToken || userApiKey);

if (ccdEnvPassthrough) {
  console.log('[CCD-env] passthrough armed (Code tab will use user-level env vars)');
  console.log('[CCD-env]   ANTHROPIC_BASE_URL =', userBaseUrl || '(unset)');
  console.log('[CCD-env]   ANTHROPIC_AUTH_TOKEN =', userAuthToken ? '(present)' : '(unset)');
  console.log('[CCD-env]   ANTHROPIC_API_KEY =', userApiKey ? '(present)' : '(unset)');
} else {
  console.log('[CCD-env] passthrough NOT armed (no user ANTHROPIC_* env vars at startup)');
}

function isCcdClaudeExe(file) {
  if (typeof file !== 'string') return false;
  const f = file.replace(/\\/g, '/').toLowerCase();
  if (f.includes('/claude-code/') && f.endsWith('/claude.exe')) return true;
  if (f.endsWith('/claude.exe') && f.includes('/claude-3p/')) return true;
  return false;
}

function applyCcdEnvPassthrough(env) {
  if (!env || typeof env !== 'object') return env;
  const patched = { ...env };
  if (userBaseUrl) patched.ANTHROPIC_BASE_URL = userBaseUrl;
  if (userAuthToken) {
    patched.ANTHROPIC_AUTH_TOKEN = userAuthToken;
    if (userBaseUrl) patched.ANTHROPIC_API_KEY = '';
  }
  if (userApiKey && !userAuthToken) {
    patched.ANTHROPIC_API_KEY = userApiKey;
    patched.ANTHROPIC_AUTH_TOKEN = '';
  }
  return patched;
}

if (ccdEnvPassthrough) {
  const cp = originalRequire.call(module, 'child_process');
  const origSpawn = cp.spawn;
  const origExecFile = cp.execFile;
  const origFork = cp.fork;
  cp.spawn = function (file, args, options) {
    if (isCcdClaudeExe(file)) {
      console.log('[CCD-env] spawn intercepted:', file);
      if (options && options.env) options.env = applyCcdEnvPassthrough(options.env);
      else options = { ...(options || {}), env: applyCcdEnvPassthrough(process.env) };
    }
    return origSpawn.call(this, file, args, options);
  };
  cp.execFile = function (file, args, options, cb) {
    if (isCcdClaudeExe(file)) {
      console.log('[CCD-env] execFile intercepted:', file);
      if (typeof options === 'function') { cb = options; options = undefined; }
      if (options && options.env) options.env = applyCcdEnvPassthrough(options.env);
      else options = { ...(options || {}), env: applyCcdEnvPassthrough(process.env) };
    }
    return origExecFile.call(this, file, args, options, cb);
  };
  cp.fork = function (modulePath, args, options) {
    if (isCcdClaudeExe(modulePath)) {
      console.log('[CCD-env] fork intercepted:', modulePath);
      if (options && options.env) options.env = applyCcdEnvPassthrough(options.env);
    }
    return origFork.call(this, modulePath, args, options);
  };
  try {
    const cpNode = originalRequire.call(module, 'node:child_process');
    cpNode.spawn = cp.spawn;
    cpNode.execFile = cp.execFile;
    cpNode.fork = cp.fork;
  } catch {}
  console.log('[CCD-env] child_process.{spawn,execFile,fork} patched');
}

// === END CCD env passthrough patch =======================================

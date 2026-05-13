#!/usr/bin/env node

/**
 * Windows Cowork VM Service Daemon (HostBackend)
 *
 * Windows equivalent of the Linux cowork-vm-service. Listens on a named pipe
 * using the same length-prefixed JSON protocol. Runs processes directly on
 * the host (no sandbox isolation), mirroring the Linux HostBackend.
 *
 * Protocol:
 *   Transport: Windows named pipe at \\.\pipe\cowork-vm-service
 *   Framing:   4-byte big-endian length prefix + JSON payload
 *   Request:   { method: "methodName", id: N, params: {...} }
 *   Response:  { success: true, result: {...}, id: N }
 *   Events:    { type: "stdout"|"stderr"|"exit"|"error"|"networkStatus"|"apiReachability"|"startupStep", ... }
 */

const net = require('net');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawn: spawnProcess, execFileSync } = require('child_process');

// ============================================================
// Configuration
// ============================================================

const PIPE_PATH = '\\\\.\\pipe\\cowork-vm-service';
const DEBUG = process.env.COWORK_VM_DEBUG === '1' ||
    process.env.CLAUDE_LINUX_DEBUG === '1';
const LOG_PREFIX = '[cowork-vm-service-win]';

const LOG_DIR = path.join(
    process.env.USERPROFILE || os.homedir(),
    '.config', 'Claude', 'logs'
);
const LOG_FILE = path.join(LOG_DIR, 'cowork_vm_daemon.log');

function formatArgs(args) {
    return args.map(a => typeof a === 'string' ? a : JSON.stringify(a)).join(' ');
}

try {
    fs.mkdirSync(path.dirname(LOG_FILE), { recursive: true });
} catch (_) {}

function writeLog(level, args) {
    const ts = new Date().toISOString();
    const msg = `${ts} [${level}] ${LOG_PREFIX} ${formatArgs(args)}\n`;
    try {
        fs.appendFileSync(LOG_FILE, msg);
    } catch (_) {}
}

function logLifecycle(event, detail) {
    const stack = detail && detail.stack
        ? detail.stack
        : (detail !== undefined ? String(detail) : '');
    writeLog('lifecycle', stack ? [event, stack] : [event]);
}

function log(...args) {
    if (!DEBUG) return;
    writeLog('debug', args);
    console.log(LOG_PREFIX, ...args);
}

function logError(...args) {
    writeLog('error', args);
    console.error(LOG_PREFIX, ...args);
}

// ============================================================
// Length-Prefixed JSON Protocol
// ============================================================

function writeMessage(socket, message) {
    const json = JSON.stringify(message);
    const jsonBuf = Buffer.from(json, 'utf8');
    const lenBuf = Buffer.alloc(4);
    lenBuf.writeUInt32BE(jsonBuf.length, 0);
    socket.write(Buffer.concat([lenBuf, jsonBuf]));
}

function parseMessage(buffer) {
    if (buffer.length < 4) return null;
    const len = buffer.readUInt32BE(0);
    if (buffer.length < 4 + len) return null;
    const json = buffer.subarray(4, 4 + len).toString('utf8');
    const remaining = Buffer.from(buffer.subarray(4 + len));
    return { message: JSON.parse(json), remaining };
}

// ============================================================
// Environment Helpers
// ============================================================

const BLOCKED_ENV_KEYS = new Set([
    'CLAUDECODE', 'ELECTRON_RUN_AS_NODE', 'ELECTRON_NO_ASAR',
]);

const FORWARDED_ENV_KEYS = ['CLAUDE_CODE_OAUTH_TOKEN'];

function filterEnv(source, stripPrefixes = []) {
    const result = {};
    for (const [k, v] of Object.entries(source)) {
        if (BLOCKED_ENV_KEYS.has(k)) continue;
        if (stripPrefixes.some(p => k.startsWith(p))) continue;
        result[k] = v;
    }
    return result;
}

function buildSpawnEnv(appEnv) {
    const mergedEnv = {
        ...filterEnv(process.env, ['CLAUDE_CODE_']),
        ...filterEnv(appEnv || {}),
        TERM: 'xterm-256color',
    };
    for (const key of FORWARDED_ENV_KEYS) {
        if (process.env[key] && mergedEnv[key] === undefined) {
            mergedEnv[key] = process.env[key];
        }
    }
    return mergedEnv;
}

// ============================================================
// Path Resolution
// ============================================================

function resolveWorkDir(cwd, sharedCwdPath) {
    let workDir = cwd || os.homedir();
    if (sharedCwdPath) {
        workDir = path.resolve(os.homedir(), sharedCwdPath);
    }
    if (!fs.existsSync(workDir)) {
        log(`resolveWorkDir: cwd "${workDir}" does not exist, using home dir`);
        workDir = os.homedir();
    }
    return workDir;
}

// ============================================================
// Command Resolution
// ============================================================

function resolveSdkBinary(sdkSubpath, version, label) {
    if (!sdkSubpath || !version) return null;
    const candidatePath = path.join(
        path.resolve(os.homedir(), sdkSubpath), version, 'claude'
    );
    try {
        fs.accessSync(candidatePath, fs.constants.X_OK);
        log(`${label}: SDK binary found: ${candidatePath}`);
        return candidatePath;
    } catch (e) {
        log(`${label}: SDK binary not found: ${candidatePath}`);
        return null;
    }
}

function resolveCommand(command, sdkBinaryPath) {
    const basename = path.basename(command);

    if (basename === 'claude' &&
            sdkBinaryPath && fs.existsSync(sdkBinaryPath)) {
        log(`resolveCommand: using SDK binary: ${sdkBinaryPath}`);
        return { command: sdkBinaryPath, error: null };
    }

    if (fs.existsSync(command)) {
        return { command, error: null };
    }

    try {
        const resolved = execFileSync('where.exe', [basename],
            { encoding: 'utf-8' }).trim().split('\r\n')[0];
        log(`resolveCommand: resolved via where.exe: ${resolved}`);
        return { command: resolved, error: null };
    } catch (e) {
        return { command: null, error: `${command} not found` };
    }
}

// ============================================================
// HostBackend — Run processes directly on host (no isolation)
// ============================================================

class HostBackend {
    constructor(emitEvent) {
        this.emitEvent = emitEvent;
        this.config = { memoryMB: 8192, cpuCount: 4 };
        this.running = true;           // Auto-start: no VM to boot
        this.guestConnected = true;     // Auto-start: no guest to wait for
        this.sdkBinaryPath = null;
        this.processes = new Map();
    }

    async init(config) {
        if (config.memoryMB !== undefined) this.config.memoryMB = config.memoryMB;
        if (config.cpuCount !== undefined) this.config.cpuCount = config.cpuCount;
        log('HostBackend configured:', this.config);
    }

    async startVM(params) {
        if (this.running) { log('HostBackend: already running'); return {}; }
        this.running = true;
        setTimeout(() => {
            this.guestConnected = true;
            this.emitEvent({ type: 'networkStatus', status: 'connected' });
            log('HostBackend: guest connected');
        }, 500);
        return {};
    }

    async stopVM() {
        log('HostBackend: stopVM');
        this._killAllProcesses();
        // Don't reset running/guestConnected — HostBackend has no
        // actual VM to stop. Keep state alive so the main process's
        // polling sees ready state immediately after reconnect.
        return {};
    }

    isRunning() {
        return { running: this.running };
    }

    isGuestConnected() {
        return { connected: this.guestConnected };
    }

    async spawn(params) {
        const { id, name, command, args, cwd, env, sharedCwdPath } = params;

        log(`HostBackend spawn: id=${id}, name=${name}, command=${command}`);

        const workDir = resolveWorkDir(cwd, sharedCwdPath);
        const resolved = resolveCommand(command, this.sdkBinaryPath);

        if (resolved.error) {
            this.emitEvent({ type: 'stderr', id, data: `Error: ${resolved.error}\n` });
            this.emitEvent({ type: 'exit', id, exitCode: 127, signal: null });
            return {};
        }

        const mergedEnv = buildSpawnEnv(env);
        const processArgs = args || [];

        log(`HostBackend spawn: cmd=${resolved.command}, args=${JSON.stringify(processArgs)}`);
        log(`HostBackend spawn: cwd=${workDir}`);

        const proc = spawnProcess(resolved.command, processArgs, {
            cwd: workDir,
            env: mergedEnv,
            stdio: ['pipe', 'pipe', 'pipe'],
        });

        log(`HostBackend spawn: pid=${proc.pid}`);
        this.processes.set(id, proc);

        proc.stdout.on('data', (data) => {
            this.emitEvent({ type: 'stdout', id, data: data.toString() });
        });

        proc.stderr.on('data', (data) => {
            this.emitEvent({ type: 'stderr', id, data: data.toString() });
        });

        proc.on('exit', (exitCode, signal) => {
            log(`HostBackend: process ${id} exited: code=${exitCode}, signal=${signal}`);
            this.processes.delete(id);
            this.emitEvent({ type: 'exit', id, exitCode, signal });
        });

        proc.on('error', (err) => {
            this.emitEvent({ type: 'error', id, message: err.message });
        });

        return {};
    }

    async kill(params) {
        const { id, signal } = params;
        const proc = this.processes.get(id);
        if (proc) {
            try {
                if (signal === 'SIGKILL' || signal === 'SIGTERM') {
                    // On Windows, use taskkill for forceful termination
                    try {
                        execFileSync('taskkill', ['/PID', String(proc.pid), '/F', '/T']);
                    } catch (_) {
                        proc.kill('SIGKILL');
                    }
                } else {
                    proc.kill(signal || 'SIGTERM');
                }
            } catch (e) {
                log(`HostBackend: kill failed for ${id}:`, e.message);
            }
        }
        return {};
    }

    async writeStdin(params) {
        const { id, data } = params;
        const proc = this.processes.get(id);
        if (proc && proc.stdin && !proc.stdin.destroyed) {
            proc.stdin.write(data);
        }
        return {};
    }

    isProcessRunning(params) {
        return { running: !!this.processes.get(params.id) };
    }

    async mountPath(params) {
        const { subpath } = params;
        log(`HostBackend mountPath: ${subpath}`);
        const resolved = path.resolve(os.homedir(), subpath || '');
        return { guestPath: resolved };
    }

    async readFile(params) {
        const { filePath } = params;
        log(`HostBackend readFile: ${filePath}`);
        const resolved = path.resolve(filePath);
        const home = os.homedir();
        if (!resolved.startsWith(home + path.sep) && resolved !== home) {
            return { error: 'Access denied: path outside home directory' };
        }
        try {
            const content = fs.readFileSync(resolved, 'utf8');
            return { content };
        } catch (e) {
            return { error: e.message };
        }
    }

    async installSdk(params) {
        const { sdkSubpath, version } = params;
        log(`HostBackend installSdk: ${sdkSubpath}@${version}`);
        const resolved = resolveSdkBinary(sdkSubpath, version, 'HostBackend');
        if (resolved) this.sdkBinaryPath = resolved;
        return {};
    }

    async addApprovedOauthToken(params) {
        log('HostBackend: addApprovedOauthToken');
        return {};
    }

    _killAllProcesses() {
        for (const [id, proc] of this.processes) {
            try {
                execFileSync('taskkill', ['/PID', String(proc.pid), '/F', '/T']);
            } catch (e) {
                try { proc.kill('SIGKILL'); } catch (_) {}
            }
        }
        this.processes.clear();
    }
}

// ============================================================
// WSL2 Backend Detection + Path Translation
// ============================================================

// User can pin a specific distro / user via env. If unset, daemon picks the
// first installed distro and probes its default user via `whoami`.
const WSL_DISTRO_OVERRIDE = process.env.COWORK_WSL_DISTRO || null;
const WSL_USER_OVERRIDE = process.env.COWORK_WSL_USER || null;

function listWslDistros() {
    const out = execFileSync('wsl.exe', ['-l', '-q'],
        { encoding: 'utf-16le', stdio: ['ignore', 'pipe', 'ignore'] });
    return out.split('\n').map(s => s.trim().replace(/\0/g, '')).filter(Boolean);
}

function probeDefaultUser(distro) {
    try {
        const out = execFileSync('wsl.exe',
            ['-d', distro, '-e', 'whoami'],
            { encoding: 'utf-8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 15000 });
        const user = out.trim();
        return user || null;
    } catch {
        return null;
    }
}

function detectWslAvailable() {
    // 1. wsl.exe must be on PATH
    try {
        execFileSync('where.exe', ['wsl.exe'],
            { encoding: 'utf-8', stdio: ['ignore', 'pipe', 'ignore'] });
    } catch {
        return { ok: false, reason: 'wsl.exe not on PATH' };
    }

    // 2. Need at least one installed distro
    let distros;
    try {
        distros = listWslDistros();
    } catch (e) {
        return { ok: false, reason: `wsl -l failed: ${e.message}` };
    }
    if (distros.length === 0) {
        return {
            ok: false,
            reason: 'no WSL distribution installed (run: wsl --install -d Ubuntu)'
        };
    }

    // 3. Pick distro: override env -> first installed
    let distro;
    if (WSL_DISTRO_OVERRIDE) {
        if (!distros.includes(WSL_DISTRO_OVERRIDE)) {
            return {
                ok: false,
                reason: `COWORK_WSL_DISTRO="${WSL_DISTRO_OVERRIDE}" not installed (have: ${distros.join(', ')})`
            };
        }
        distro = WSL_DISTRO_OVERRIDE;
    } else {
        distro = distros[0];
    }

    // 4. Probe default user (unless overridden)
    let user;
    if (WSL_USER_OVERRIDE) {
        user = WSL_USER_OVERRIDE;
    } else {
        user = probeDefaultUser(distro);
        if (!user) {
            return {
                ok: false,
                reason: `unable to probe default user in distro "${distro}" (first launch may require setup)`
            };
        }
    }

    return { ok: true, distro, user };
}

// C:\Users\92940\Desktop  ->  /mnt/c/Users/92940/Desktop
function winPathToWsl(p) {
    if (!p) return p;
    const m = p.match(/^([A-Za-z]):[\\\/](.*)$/);
    if (!m) return p;
    return `/mnt/${m[1].toLowerCase()}/${m[2].replace(/\\/g, '/')}`;
}

// 1p VM mount-path detector: "/sessions/<id>/mnt/<MountName>[/...]" or same w/o leading slash.
// Main bundle uses this to refer to host mounts (Desktop, uploads, outputs, etc.)
function tryMapVmMount(p, winHome) {
    if (!p) return null;
    const m = p.match(/^\/?sessions\/[^/]+\/mnt\/(.+)$/);
    if (!m) return null;
    const winAbs = path.resolve(winHome, m[1]);
    return winPathToWsl(winAbs);
}

// Resolve main-bundle cwd/sharedCwdPath into a WSL path.
// Priority: sharedCwdPath > cwd. Recognized forms:
//   1p VM mount  "/sessions/<id>/mnt/<MountName>[/...]"  -> /mnt/c/Users/<user>/<MountName>/...
//   Windows abs  "C:\Users\..."                          -> /mnt/c/Users/...
//   Real Linux   "/home/jack", "/tmp", "/etc"            -> pass through
//   Relative     "Desktop", "outputs"                    -> /mnt/c/Users/<user>/<rel>
function resolveWslCwd(cwd, sharedCwdPath) {
    const winHome = os.homedir();

    if (sharedCwdPath) {
        const mapped = tryMapVmMount(sharedCwdPath, winHome);
        if (mapped) return mapped;
        const winAbs = path.resolve(winHome, sharedCwdPath);
        return winPathToWsl(winAbs);
    }
    if (cwd) {
        if (/^[A-Za-z]:[\\\/]/.test(cwd)) {
            return winPathToWsl(cwd);
        }
        const mapped = tryMapVmMount(cwd, winHome);
        if (mapped) return mapped;
        if (cwd.startsWith('/')) {
            // Real Linux absolute path (e.g. /home/jack, /tmp) — pass through.
            return cwd;
        }
        // Bare relative path -> resolve under host home
        const winAbs = path.resolve(winHome, cwd);
        return winPathToWsl(winAbs);
    }
    return winPathToWsl(winHome);
}

// Env keys that must NOT be propagated into WSL (Windows-only semantics)
const WSL_BLOCKED_ENV_KEYS = new Set([
    'PATH', 'PATHEXT', 'USERPROFILE', 'HOMEPATH', 'HOMEDRIVE',
    'LOCALAPPDATA', 'APPDATA', 'TEMP', 'TMP', 'SYSTEMROOT',
    'SYSTEMDRIVE', 'COMSPEC', 'PROGRAMFILES', 'PROGRAMFILES(X86)',
    'PROGRAMW6432', 'PROGRAMDATA', 'WINDIR', 'OS', 'COMPUTERNAME',
    'USERNAME', 'USERDOMAIN', 'USERDOMAIN_ROAMINGPROFILE',
    'PSMODULEPATH', 'LOGONSERVER', 'SESSIONNAME', 'PROCESSOR_ARCHITECTURE',
    'PROCESSOR_IDENTIFIER', 'PROCESSOR_LEVEL', 'PROCESSOR_REVISION',
    'NUMBER_OF_PROCESSORS', 'COMMONPROGRAMFILES', 'COMMONPROGRAMFILES(X86)',
    'COMMONPROGRAMW6432', 'PUBLIC', 'ALLUSERSPROFILE',
    'CLAUDECODE', 'ELECTRON_RUN_AS_NODE', 'ELECTRON_NO_ASAR',
]);

// Build an `env` command prefix that sets vars inside WSL.
// WSL 2.6.x does NOT support `wsl.exe --env`, so we prepend `env KEY=VAL ...`
// before the user command. Usage:
//   wsl.exe -d Ubuntu -u jack --cd <cwd> -e env KEY1=V1 KEY2=V2 <command> <args...>
function buildWslEnvPrefix(appEnv) {
    const assignments = [];
    const seen = new Set();
    const push = (k, v) => {
        if (!k) return;
        if (WSL_BLOCKED_ENV_KEYS.has(k.toUpperCase())) return;
        if (seen.has(k)) return;
        seen.add(k);
        // `env` parses up to the first non-KEY=VAL arg as the command, so
        // values with spaces are fine — they're separate argv elements.
        assignments.push(`${k}=${v}`);
    };
    // Only forward explicitly-allowed host env vars (matches HostBackend behavior)
    for (const k of FORWARDED_ENV_KEYS) {
        if (process.env[k]) push(k, process.env[k]);
    }
    // Caller-provided env (CLAUDE_*, ANTHROPIC_*, etc.)
    for (const [k, v] of Object.entries(appEnv || {})) push(k, v);
    // Force UTF-8 so Linux stdout decodes cleanly in main process
    push('LANG', 'C.UTF-8');
    push('LC_ALL', 'C.UTF-8');
    push('TERM', 'xterm-256color');
    return assignments.length ? ['env', ...assignments] : [];
}

// ============================================================
// WSLBackend — Forward processes to WSL2 distro (near-1p Linux experience)
// ============================================================

class WSLBackend {
    constructor(emitEvent, { distro, user } = {}) {
        this.emitEvent = emitEvent;
        this.config = { memoryMB: 8192, cpuCount: 4 };
        this.running = true;
        // Initial true so main process sees "VM already connected" on restart
        // and skips the download_and_sdk_prepare path (which would try to fetch
        // rootfs.vhdx.zst / claude.zst from downloads.claude.ai). WSL is
        // started lazily by `wsl.exe` on first spawn anyway; warmup just
        // hides the ~1.4s cold-start latency.
        this.guestConnected = true;
        this.sdkBinaryPath = null;
        this.processes = new Map();
        this.distro = distro;
        this.user = user;

        // Kick off background setup immediately (don't rely on main process
        // calling startVM — it may skip startVM when guestConnected is true).
        setImmediate(() => this._backgroundSetup());
    }

    async init(config) {
        if (config.memoryMB !== undefined) this.config.memoryMB = config.memoryMB;
        if (config.cpuCount !== undefined) this.config.cpuCount = config.cpuCount;
        log(`WSLBackend configured:`, this.config, `distro=${this.distro} user=${this.user}`);
    }

    async startVM(params) {
        // Also re-trigger setup in case constructor's setImmediate hadn't run yet
        setImmediate(() => this._backgroundSetup());
        return {};
    }

    _backgroundSetup() {
        if (this._setupDone) return;
        this._setupDone = true;
        try {
            // 1. Warm up WSL distro
            execFileSync('wsl.exe',
                ['-d', this.distro, '-u', this.user, '-e', 'true'],
                { timeout: 30000, stdio: 'ignore' });
            log('WSLBackend: WSL distro is warm');

            // 2. Pre-create common 1p mount target dirs under host home so
            //    wsl --cd into them doesn't fail with "chdir failed".
            //    Main bundle uses these mount names: Desktop, uploads, outputs,
            //    .claude/skills, .claude/projects, .auto-memory.
            const winHome = os.homedir();
            const commonMounts = [
                'outputs', 'uploads', '.auto-memory',
                '.claude', '.claude/skills', '.claude/projects',
            ];
            for (const m of commonMounts) {
                try { fs.mkdirSync(path.join(winHome, m), { recursive: true }); }
                catch (_) {}
            }
            log('WSLBackend: common mount target dirs ensured');

            // 3. Create $HOME/<Dir> symlinks to host Windows folders so
            //    AI-written ~/Desktop, ~/Documents etc. resolve correctly.
            this._ensureHomeSymlinks();

            this.emitEvent({ type: 'networkStatus', status: 'connected' });
        } catch (e) {
            logError('WSLBackend: background setup failed:', e.message);
            this.emitEvent({ type: 'networkStatus', status: 'disconnected' });
        }
    }

    _ensureHomeSymlinks() {
        const wslWinHome = winPathToWsl(os.homedir());
        // Mount targets we just mkdir'd + classic user folders. Build a flat
        // list of leaf names (those used for ~/X paths). Skip 'outputs',
        // 'uploads', '.auto-memory' which are already in $HOME (the bare
        // names already work after WSL home is mapped, no need to symlink).
        const dirs = ['Desktop', 'Documents', 'Downloads', 'Pictures', 'Videos', 'Music'];
        const script = dirs.map(d =>
            `[ -d "${wslWinHome}/${d}" ] && [ ! -e "$HOME/${d}" ] && ln -sf "${wslWinHome}/${d}" "$HOME/${d}"`
        ).join('; ') + '; true';
        try {
            execFileSync('wsl.exe',
                ['-d', this.distro, '-u', this.user, '-e', 'bash', '-lc', script],
                { timeout: 10000, stdio: 'ignore' });
            log('WSLBackend: home dir symlinks ensured');
        } catch (e) {
            log('WSLBackend: symlink setup skipped:', e.message);
        }
    }

    async stopVM() {
        log('WSLBackend: stopVM');
        this._killAllProcesses();
        // Deliberately NOT calling `wsl --terminate`: the distro might be in use elsewhere.
        return {};
    }

    isRunning() {
        return { running: this.running };
    }

    isGuestConnected() {
        return { connected: this.guestConnected };
    }

    async spawn(params) {
        const { id, name, command, args, cwd, env, sharedCwdPath } = params;

        log(`WSLBackend spawn: id=${id}, name=${name}, command=${command}`);

        const wslCwd = resolveWslCwd(cwd, sharedCwdPath);
        const envPrefix = buildWslEnvPrefix(env);   // ['env', 'K=V', ...]  or []

        // If main bundle asks for `claude` and we discovered a Linux SDK binary, swap it in
        let actualCmd = command;
        let actualArgs = args || [];
        if (path.basename(command || '') === 'claude' && this.sdkBinaryPath) {
            actualCmd = this.sdkBinaryPath;
            log(`WSLBackend spawn: using SDK binary: ${actualCmd}`);
        }

        // wsl.exe -d <distro> -u <user> --cd <cwd> -e env K=V ... <cmd> <args>
        const wslArgs = [
            '-d', this.distro,
            '-u', this.user,
            '--cd', wslCwd,
            '-e', ...envPrefix, actualCmd, ...actualArgs,
        ];

        log(`WSLBackend spawn: cwd=${wslCwd}`);
        log(`WSLBackend spawn: cmd=${actualCmd} args=${JSON.stringify(actualArgs)}`);

        const proc = spawnProcess('wsl.exe', wslArgs, {
            stdio: ['pipe', 'pipe', 'pipe'],
            windowsHide: true,
        });

        log(`WSLBackend spawn: pid=${proc.pid}`);
        this.processes.set(id, proc);

        proc.stdout.on('data', (data) => {
            this.emitEvent({ type: 'stdout', id, data: data.toString('utf8') });
        });
        proc.stderr.on('data', (data) => {
            this.emitEvent({ type: 'stderr', id, data: data.toString('utf8') });
        });
        proc.on('exit', (exitCode, signal) => {
            log(`WSLBackend: process ${id} exited: code=${exitCode}, signal=${signal}`);
            this.processes.delete(id);
            this.emitEvent({ type: 'exit', id, exitCode, signal });
        });
        proc.on('error', (err) => {
            this.emitEvent({ type: 'error', id, message: err.message });
        });

        return {};
    }

    async kill(params) {
        const { id, signal } = params;
        const proc = this.processes.get(id);
        if (!proc) return {};
        try {
            // Kill the wsl.exe wrapper tree; WSL distro reaps the in-distro children.
            execFileSync('taskkill', ['/PID', String(proc.pid), '/F', '/T'],
                { stdio: 'ignore' });
        } catch (_) {
            try { proc.kill(signal || 'SIGTERM'); } catch (_) {}
        }
        return {};
    }

    async writeStdin(params) {
        const { id, data } = params;
        const proc = this.processes.get(id);
        if (proc && proc.stdin && !proc.stdin.destroyed) {
            proc.stdin.write(data);
        }
        return {};
    }

    isProcessRunning(params) {
        return { running: !!this.processes.get(params.id) };
    }

    async mountPath(params) {
        const { subpath } = params;
        log(`WSLBackend mountPath: ${subpath}`);
        const winAbs = path.resolve(os.homedir(), subpath || '');
        // mkdir the mount target if missing so subsequent `wsl --cd` succeeds.
        // (1p VM creates the bind-mount target automatically; we mimic that here.)
        try { fs.mkdirSync(winAbs, { recursive: true }); } catch (_) {}
        return { guestPath: winPathToWsl(winAbs) };
    }

    async readFile(params) {
        // Read from Windows fs directly (home subdir is visible to the host).
        // Identical to HostBackend behavior.
        const { filePath } = params;
        log(`WSLBackend readFile: ${filePath}`);
        const resolved = path.resolve(filePath);
        const home = os.homedir();
        if (!resolved.startsWith(home + path.sep) && resolved !== home) {
            return { error: 'Access denied: path outside home directory' };
        }
        try {
            const content = fs.readFileSync(resolved, 'utf8');
            return { content };
        } catch (e) {
            return { error: e.message };
        }
    }

    async installSdk(params) {
        const { sdkSubpath, version } = params;
        log(`WSLBackend installSdk: ${sdkSubpath}@${version}`);
        if (!sdkSubpath || !version) return {};
        // Check for a Linux executable at the WSL-translated path.
        const winCandidate = path.join(
            path.resolve(os.homedir(), sdkSubpath), version, 'claude');
        const wslCandidate = winPathToWsl(winCandidate);
        try {
            execFileSync('wsl.exe',
                ['-d', this.distro, '-u', this.user, '-e', 'test', '-x', wslCandidate],
                { timeout: 5000, stdio: 'ignore' });
            this.sdkBinaryPath = wslCandidate;
            log(`WSLBackend: SDK binary found: ${wslCandidate}`);
        } catch (_) {
            log(`WSLBackend: SDK binary not found at ${wslCandidate} (Cowork bash unaffected)`);
        }
        return {};
    }

    async addApprovedOauthToken(params) {
        log('WSLBackend: addApprovedOauthToken');
        return {};
    }

    _killAllProcesses() {
        for (const [id, proc] of this.processes) {
            try {
                execFileSync('taskkill', ['/PID', String(proc.pid), '/F', '/T'],
                    { stdio: 'ignore' });
            } catch (_) {
                try { proc.kill('SIGKILL'); } catch (_) {}
            }
        }
        this.processes.clear();
    }
}

// ============================================================
// VMManager — Thin Dispatcher
// ============================================================

class VMManager {
    constructor() {
        this.eventSubscribers = new Set();
        const forceHost = process.env.COWORK_FORCE_HOSTBACKEND === '1';
        const wsl = forceHost
            ? { ok: false, reason: 'COWORK_FORCE_HOSTBACKEND=1' }
            : detectWslAvailable();
        if (wsl.ok) {
            log(`VMManager: using WSLBackend (distro=${wsl.distro}, user=${wsl.user})`);
            writeLog('lifecycle', [`backend=WSLBackend distro=${wsl.distro} user=${wsl.user}`]);
            this.backend = new WSLBackend(
                (event) => this.broadcastEvent(event),
                { distro: wsl.distro, user: wsl.user }
            );
        } else {
            log(`VMManager: WSL unavailable (${wsl.reason}); falling back to HostBackend`);
            writeLog('lifecycle', [`backend=HostBackend reason=${wsl.reason}`]);
            this.backend = new HostBackend((event) => this.broadcastEvent(event));
        }
    }

    configure(params) {
        const config = {};
        if (params.memoryMB !== undefined) config.memoryMB = params.memoryMB;
        if (params.cpuCount !== undefined) config.cpuCount = params.cpuCount;
        this.backend.init(config).catch((e) => {
            logError('Backend init error:', e.message);
        });
        log('Configured:', params);
        return {};
    }

    async createVM(params) {
        log(`createVM: bundle=${params.bundlePath}`);
        return {};
    }

    async startVM(params) {
        return this.backend.startVM(params);
    }

    async stopVM() {
        return this.backend.stopVM();
    }

    isRunning() {
        return this.backend.isRunning();
    }

    isGuestConnected() {
        return this.backend.isGuestConnected();
    }

    async spawn(params) {
        return this.backend.spawn(params);
    }

    async kill(params) {
        return this.backend.kill(params);
    }

    async writeStdin(params) {
        return this.backend.writeStdin(params);
    }

    isProcessRunning(params) {
        return this.backend.isProcessRunning(params);
    }

    async mountPath(params) {
        return this.backend.mountPath(params);
    }

    async readFile(params) {
        return this.backend.readFile(params);
    }

    async installSdk(params) {
        return this.backend.installSdk(params);
    }

    async addApprovedOauthToken(params) {
        return this.backend.addApprovedOauthToken(params);
    }

    async getSessionsDiskInfo(params) {
        return { totalBytes: 0, freeBytes: 0, sessions: [] };
    }

    async deleteSessionDirs(params) {
        return { deleted: params.names || [], errors: {} };
    }

    setDebugLogging(params) {
        log(`setDebugLogging: ${params.enabled}`);
        return {};
    }

    async sendGuestResponse(params) {
        log('sendGuestResponse:', params);
        return {};
    }

    subscribeEvents(socket) {
        this.eventSubscribers.add(socket);
        socket.on('close', () => {
            this.eventSubscribers.delete(socket);
        });
        return {};
    }

    broadcastEvent(event) {
        for (const socket of this.eventSubscribers) {
            try {
                writeMessage(socket, event);
            } catch (e) {
                log('Failed to send event:', e.message);
                this.eventSubscribers.delete(socket);
            }
        }
    }
}

// ============================================================
// Method Dispatch
// ============================================================

const vm = new VMManager();

const METHODS = {
    configure:              (params) => vm.configure(params),
    createVM:               (params) => vm.createVM(params),
    startVM:                (params) => vm.startVM(params),
    stopVM:                 () => vm.stopVM(),
    isRunning:              () => vm.isRunning(),
    isGuestConnected:       () => vm.isGuestConnected(),
    spawn:                  (params) => vm.spawn(params),
    kill:                   (params) => vm.kill(params),
    writeStdin:             (params) => vm.writeStdin(params),
    isProcessRunning:       (params) => vm.isProcessRunning(params),
    mountPath:              (params) => vm.mountPath(params),
    readFile:               (params) => vm.readFile(params),
    installSdk:             (params) => vm.installSdk(params),
    addApprovedOauthToken:  (params) => vm.addApprovedOauthToken(params),
    getSessionsDiskInfo:    (params) => vm.getSessionsDiskInfo(params),
    deleteSessionDirs:      (params) => vm.deleteSessionDirs(params),
    setDebugLogging:        (params) => vm.setDebugLogging(params),
    sendGuestResponse:      (params) => vm.sendGuestResponse(params),
    subscribeEvents:        (params, socket) => vm.subscribeEvents(socket),
};

async function handleRequest(request, socket) {
    const { method, params } = request;
    // Redact env block (may contain API keys)
    if (params && params.env) {
        const { env, ...rest } = params;
        const summary = JSON.stringify(rest).substring(0, 2000) + ' [env: redacted]';
        log(`Request: ${method}`, summary);
    } else {
        log(`Request: ${method}`);
    }

    const handler = METHODS[method];
    if (!handler) {
        return { success: false, error: `Unknown method: ${method}` };
    }

    try {
        const result = await handler(params || {}, socket);
        return { success: true, result: result || {} };
    } catch (e) {
        logError(`Method ${method} failed:`, e.message);
        return { success: false, error: e.message };
    }
}

// ============================================================
// Named Pipe Server
// ============================================================

function startServer() {
    const server = net.createServer((socket) => {
        log('Client connected');
        let buffer = Buffer.alloc(0);

        socket.on('data', async (data) => {
            buffer = Buffer.concat([buffer, data]);

            let parsed;
            try {
                parsed = parseMessage(buffer);
            } catch (e) {
                logError('Parse error:', e.message);
                buffer = Buffer.alloc(0);
                return;
            }

            while (parsed) {
                buffer = parsed.remaining;
                const response = await handleRequest(parsed.message, socket);
                if (parsed.message.id !== undefined) {
                    response.id = parsed.message.id;
                }
                writeMessage(socket, response);

                try {
                    parsed = parseMessage(buffer);
                } catch (e) {
                    logError('Parse error:', e.message);
                    buffer = Buffer.alloc(0);
                    return;
                }
            }
        });

        socket.on('error', (err) => {
            if (err.code !== 'ECONNRESET' && err.code !== 'EPIPE') {
                log('Socket error:', err.message);
            }
        });

        socket.on('close', () => {
            log('Client disconnected');
        });
    });

    server.on('error', (err) => {
        logError('Server error:', err.message);
        process.exit(1);
    });

    server.listen(PIPE_PATH, () => {
        log(`Listening on ${PIPE_PATH}`);
        console.log(`${LOG_PREFIX} Service started on ${PIPE_PATH}`);
        logLifecycle('listening', PIPE_PATH);
    });

    // Graceful shutdown
    const shutdown = () => {
        log('Shutting down...');
        vm.stopVM().catch(() => {}).finally(() => {
            server.close();
            process.exit(0);
        });
    };

    process.on('SIGTERM', () => { logLifecycle('SIGTERM received'); shutdown(); });
    process.on('SIGINT', () => { logLifecycle('SIGINT received'); shutdown(); });
    process.on('uncaughtException', (err) => {
        logLifecycle('uncaughtException', err);
        logError('Uncaught exception:', err);
        shutdown();
    });
    process.on('unhandledRejection', (reason) => {
        logLifecycle('unhandledRejection', reason);
        logError('Unhandled rejection:', reason);
    });
    process.on('exit', (code) => {
        logLifecycle('exit', `code=${code}`);
    });
}

// ============================================================
// Entry Point
// ============================================================

if (require.main === module) {
    logLifecycle('startup', `pid=${process.pid} pipe=${PIPE_PATH}`);
    startServer();
}

module.exports = { HostBackend, VMManager, METHODS };

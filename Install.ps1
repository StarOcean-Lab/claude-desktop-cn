#Requires -Version 5.1
<#
.SYNOPSIS
    Claude Desktop Windows 3p Portable - GUI Installer
.DESCRIPTION
    Wizard-style installer: select path, configure gateway, install.
    Bundles prebuilt app.asar; downloads Electron 41.5.0 at install time.
#>

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

# Force UTF-8 console encoding for child-process stdout. Without this,
# `npm root -g` on a system with a non-ASCII username (e.g. Chinese)
# returns mangled paths because PowerShell 5.1 decodes child stdout as
# the OEM codepage (GBK). UTF-8 byte sequences like 0xE5 0x90 0x95 0x5C
# (= "吕\") get misread as 0xE5 0x90 + 0x95 0x5C = "鍚昞", silently
# losing the backslash.
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ── constants ────────────────────────────────────────────────────────────────
$ELECTRON_URL  = 'https://github.com/electron/electron/releases/download/v41.5.0/electron-v41.5.0-win32-x64.zip'
$ELECTRON_ZIP  = "$env:TEMP\electron-41.5.0-win32-x64.zip"
$SCRIPT_DIR    = Split-Path -Parent $MyInvocation.MyCommand.Path
$PREBUILT_DIR  = Join-Path $SCRIPT_DIR 'prebuilt'
$DEFAULT_INSTALL = 'D:\claude-desktop-portable'

# Native binary resolution (mirror fallback for users behind GFW)
$NPMMIRROR_REGISTRY = 'https://registry.npmmirror.com'
$BINARY_PKG_NAME    = '@anthropic-ai/claude-code-win32-x64'
$BINARY_CACHE_DIR   = "$env:TEMP\claude-code-binaries-cache"
$REAL_EXE_MIN_BYTES = 50MB   # real claude.exe is ~215 MB; cmd shim is < 1 KB

# ── helpers ──────────────────────────────────────────────────────────────────

# Validates that a file path points to a real native claude.exe (not a cmd
# shim, 0-byte placeholder, or partial download). Real binary is ~215 MB
# with a "MZ" PE header; npm's claude.cmd shim is a few hundred bytes of
# batch script, which Windows spawn() rejects with "spawn UNKNOWN".
function Test-IsRealClaudeExe {
    param([string]$path)
    if (-not $path -or -not (Test-Path $path)) { return $false }
    try { $size = (Get-Item $path -EA Stop).Length } catch { return $false }
    if ($size -lt $REAL_EXE_MIN_BYTES) { return $false }
    try {
        $fs = [System.IO.File]::OpenRead($path)
        try {
            $b0 = $fs.ReadByte(); $b1 = $fs.ReadByte()
            return ($b0 -eq 0x4D -and $b1 -eq 0x5A)  # "MZ"
        } finally { $fs.Dispose() }
    } catch { return $false }
}

# Reads the claude-code version that the bundled app.asar was built
# against. Claude Desktop spawns claude.exe from
# %LOCALAPPDATA%\Claude-3p\claude-code\<this version>\claude.exe, so
# this is the source of truth — NOT whatever version npm currently
# offers (which can be newer than the asar). Returns $null if the
# version pattern can't be found.
function Get-AppAsarRequiredVersion {
    param([string]$asarPath)
    if (-not $asarPath -or -not (Test-Path $asarPath)) { return $null }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($asarPath)
        $text = [System.Text.Encoding]::UTF8.GetString($bytes)
        # match the manifest block written by the build:
        #   "manifest":{"version":"2.1.128","commit":"..."
        if ($text -match '"manifest":\{"version":"(\d+\.\d+\.\d+)"') {
            return $matches[1]
        }
    } catch {}
    return $null
}

# Returns plausible npm-global "node_modules" roots, with the safest
# (PowerShell-native env-var derived) candidates first. We avoid relying
# solely on `npm root -g` because on Windows + non-ASCII username it
# returns a mangled path due to OEM-codepage stdout decoding.
function Get-NpmGlobalRootCandidates {
    $candidates = @()
    # PS-native env vars are always correctly encoded
    if ($env:APPDATA)      { $candidates += "$env:APPDATA\npm\node_modules" }
    if ($env:LOCALAPPDATA) { $candidates += "$env:LOCALAPPDATA\npm\node_modules" }
    if ($env:ProgramFiles) { $candidates += "$env:ProgramFiles\nodejs\node_modules" }
    # Then fall back to whatever npm/pnpm/yarn report (UTF-8 console
    # encoding is forced at script top, so on most systems these are
    # also correct now)
    try { $r = (npm root -g 2>$null);  if ($r) { $candidates += "$r".Trim() } } catch {}
    try { $r = (pnpm root -g 2>$null); if ($r) { $candidates += "$r".Trim() } } catch {}
    try { $r = (yarn global dir 2>$null); if ($r) { $candidates += "$("$r".Trim())\node_modules" } } catch {}
    return $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique
}

# Reads the version straight from the npm package's package.json.
# Avoids running `claude --version` which can succeed on a broken
# install (the cmd shim still prints a version) and mislead the rest
# of the installer.
function Get-NpmClaudeCodePackageVersion {
    foreach ($root in Get-NpmGlobalRootCandidates) {
        $pj = Join-Path $root '@anthropic-ai\claude-code\package.json'
        if (Test-Path $pj) {
            try {
                $v = (Get-Content $pj -Raw -Encoding UTF8 | ConvertFrom-Json).version
                if ($v -match '^(\d+\.\d+\.\d+)') { return $matches[1] }
            } catch {}
        }
    }
    return $null
}

function Find-NpmClaudeCode {
    # Priority 1: platform-specific subpackage shipping the real native binary
    $platformRel = '@anthropic-ai\claude-code-win32-x64\claude.exe'
    # Priority 2: legacy main-package layout (rare; bundled binary)
    $legacyRel   = '@anthropic-ai\claude-code\bin\claude.exe'

    $roots = @(Get-NpmGlobalRootCandidates)

    # nvm node version dirs (each version has its own node_modules)
    $nvmBases = @("$env:APPDATA\nvm", "$env:LOCALAPPDATA\nvm")
    if ($env:NVM_HOME) { $nvmBases += $env:NVM_HOME }
    foreach ($base in $nvmBases) {
        if (-not $base -or -not (Test-Path $base)) { continue }
        Get-ChildItem $base -Directory -EA SilentlyContinue | ForEach-Object {
            $roots += "$($_.FullName)\node_modules"
        }
    }

    foreach ($r in $roots | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique) {
        $b = Join-Path $r $platformRel
        if (Test-IsRealClaudeExe $b) { return $b }
        # tolerate sub-folder layouts inside the platform package
        $platformDir = Join-Path $r '@anthropic-ai\claude-code-win32-x64'
        if (Test-Path $platformDir) {
            $hit = Get-ChildItem $platformDir -Recurse -Filter 'claude.exe' -EA SilentlyContinue |
                Where-Object { Test-IsRealClaudeExe $_.FullName } | Select-Object -First 1
            if ($hit) { return $hit.FullName }
        }
        $b = Join-Path $r $legacyRel
        if (Test-IsRealClaudeExe $b) { return $b }
    }

    # manual install candidates (last resort)
    $candidates = @(
        "$env:LOCALAPPDATA\Programs\claude\claude.exe",
        "$env:ProgramFiles\claude\claude.exe"
    )
    foreach ($c in $candidates) { if (Test-IsRealClaudeExe $c) { return $c } }

    return $null
}

# Backward-compat: page-0 prereq check still calls Get-ClaudeCodeVersion
function Get-ClaudeCodeVersion {
    param($binPath)
    $v = Get-NpmClaudeCodePackageVersion
    if ($v) { return $v }
    if ($binPath -and (Test-Path $binPath)) {
        try {
            $ver = (& $binPath --version 2>$null).Trim()
            if ($ver -match '(\d+\.\d+\.\d+)') { return $matches[1] }
        } catch {}
    }
    return $null
}

# Fetch package metadata from npmmirror for a given version.
# Returns @{ tarball = '...'; shasum = '...' } or $null.
function Get-MirrorTarballInfo {
    param([string]$version)
    $url = "$NPMMIRROR_REGISTRY/$BINARY_PKG_NAME/$version"
    try {
        $meta = Invoke-RestMethod -Uri $url -UseBasicParsing -TimeoutSec 30
        if ($meta -and $meta.dist -and $meta.dist.tarball) {
            return @{ tarball = $meta.dist.tarball; shasum = $meta.dist.shasum }
        }
    } catch {}
    return $null
}

# Streaming download with byte-level progress reporting.
function Invoke-DownloadWithProgress {
    param([string]$url, [string]$dest, [scriptblock]$onProgress)
    $req = [System.Net.HttpWebRequest]::Create($url)
    $req.UserAgent = 'ClaudeDesktop3pInstaller'
    $req.Timeout   = 60000
    $resp = $req.GetResponse()
    try {
        $total  = [int64]$resp.ContentLength
        $stream = $resp.GetResponseStream()
        $fs = [System.IO.File]::Create($dest)
        try {
            $buf = New-Object byte[] 131072
            $totalRead = [int64]0
            $lastPct = -1
            while (($read = $stream.Read($buf, 0, $buf.Length)) -gt 0) {
                $fs.Write($buf, 0, $read)
                $totalRead += $read
                if ($onProgress -and $total -gt 0) {
                    $pct = [int](($totalRead * 100) / $total)
                    if ($pct -ne $lastPct) {
                        & $onProgress $pct $totalRead $total
                        $lastPct = $pct
                    }
                }
            }
        } finally {
            $fs.Dispose(); $stream.Dispose()
        }
    } finally { $resp.Dispose() }
}

# Resolves a real claude.exe for the given version: cache hit -> npmmirror
# tarball download + SHA-1 verify + tar extract + PE verify. Returns the
# absolute path to the cached claude.exe, or $null on failure.
function Get-ClaudeBinaryFromMirror {
    param([Parameter(Mandatory)] [string]$version)
    $cacheDir = Join-Path $BINARY_CACHE_DIR $version
    $cacheExe = Join-Path $cacheDir 'claude.exe'

    if (Test-IsRealClaudeExe $cacheExe) {
        Write-Log "  -> mirror cache hit: $cacheExe ($([math]::Round((Get-Item $cacheExe).Length/1MB,1)) MB)" $CLR_OK
        return $cacheExe
    }

    Write-Log "Resolving $BINARY_PKG_NAME@$version from $NPMMIRROR_REGISTRY ..."
    $info = Get-MirrorTarballInfo -version $version
    if (-not $info) {
        Write-Log "  ERROR: cannot fetch package metadata for v$version" ([System.Drawing.Color]::FromArgb(248,113,113))
        return $null
    }
    Write-Log "  tarball: $($info.tarball)" $CLR_DIM

    New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
    $tgz = Join-Path $cacheDir 'pkg.tgz'
    if (Test-Path $tgz) { Remove-Item $tgz -Force }

    try {
        Set-Progress 84 "Downloading claude.exe v$version (~71 MB)..."
        Invoke-DownloadWithProgress -url $info.tarball -dest $tgz -onProgress {
            param($pct, $rec, $tot)
            Set-Progress (84 + [int]($pct * 0.07)) ("Downloading: {0}% ({1}/{2} MB)" -f $pct, [math]::Round($rec/1MB,1), [math]::Round($tot/1MB,1))
        }
    } catch {
        Write-Log "  ERROR: download failed: $_" ([System.Drawing.Color]::FromArgb(248,113,113))
        return $null
    }

    if ($info.shasum) {
        $actual = (Get-FileHash $tgz -Algorithm SHA1).Hash.ToLower()
        if ($actual -ne $info.shasum.ToLower()) {
            Write-Log "  ERROR: SHA-1 mismatch (expected $($info.shasum), got $actual)" ([System.Drawing.Color]::FromArgb(248,113,113))
            Remove-Item $tgz -Force -EA SilentlyContinue
            return $null
        }
        Write-Log "  -> SHA-1 verified" $CLR_OK
    }

    Set-Progress 91 'Extracting claude.exe (~215 MB)...'
    $extractDir = Join-Path $cacheDir 'extract'
    if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
    New-Item -ItemType Directory -Path $extractDir -Force | Out-Null

    if (-not (Get-Command tar -EA SilentlyContinue)) {
        Write-Log "  ERROR: 'tar' not found (requires Windows 10 1803+)" ([System.Drawing.Color]::FromArgb(248,113,113))
        return $null
    }
    $tarOut = & tar -xzf $tgz -C $extractDir 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Log "  ERROR: tar extraction failed: $tarOut" ([System.Drawing.Color]::FromArgb(248,113,113))
        return $null
    }

    $extractedExe = Join-Path $extractDir 'package\claude.exe'
    if (-not (Test-IsRealClaudeExe $extractedExe)) {
        Write-Log "  ERROR: extracted claude.exe failed PE/size check" ([System.Drawing.Color]::FromArgb(248,113,113))
        return $null
    }

    Move-Item $extractedExe $cacheExe -Force
    Remove-Item $extractDir -Recurse -Force -EA SilentlyContinue
    Remove-Item $tgz -Force -EA SilentlyContinue
    Write-Log "  -> cached: $cacheExe ($([math]::Round((Get-Item $cacheExe).Length/1MB,1)) MB)" $CLR_OK
    return $cacheExe
}

function Test-VcRedist {
    $key = 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64'
    try { return ((Get-ItemProperty $key -EA Stop).Installed -eq 1) } catch { return $false }
}

function Read-ExistingSettings {
    $path = Join-Path $env:USERPROFILE '.claude\settings.json'
    if (-not (Test-Path $path)) { return $null }
    try {
        $json = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $url  = $json.env.ANTHROPIC_BASE_URL
        $key  = $json.env.ANTHROPIC_AUTH_TOKEN
        if ($url -and $key) {
            return @{ url = $url; key = $key }
        }
    } catch {}
    return $null
}

# ── color palette ────────────────────────────────────────────────────────────
$CLR_BG    = [System.Drawing.Color]::FromArgb(24, 24, 27)
$CLR_PANEL = [System.Drawing.Color]::FromArgb(36, 36, 40)
$CLR_ACCENT= [System.Drawing.Color]::FromArgb(139, 92, 246)  # violet
$CLR_FG    = [System.Drawing.Color]::White
$CLR_DIM   = [System.Drawing.Color]::FromArgb(161, 161, 170)
$CLR_INPUT = [System.Drawing.Color]::FromArgb(48, 48, 52)
$CLR_BTN   = [System.Drawing.Color]::FromArgb(109, 62, 216)
$CLR_OK    = [System.Drawing.Color]::FromArgb(34, 197, 94)
$CLR_WARN  = [System.Drawing.Color]::FromArgb(234, 179, 8)

function New-Label {
    param($text, $x, $y, $w, $h, $size=10, $bold=$false, $color=$null)
    $lbl = [System.Windows.Forms.Label]::new()
    $lbl.Text = $text
    $lbl.Location = [System.Drawing.Point]::new($x, $y)
    $lbl.Size = [System.Drawing.Size]::new($w, $h)
    $lbl.ForeColor = if ($color) { $color } else { $CLR_FG }
    $lbl.BackColor = [System.Drawing.Color]::Transparent
    $style = if ($bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    $lbl.Font = [System.Drawing.Font]::new('Segoe UI', $size, $style)
    return $lbl
}

function New-TextBox {
    param($x, $y, $w, $text='', $password=$false)
    $tb = [System.Windows.Forms.TextBox]::new()
    $tb.Location = [System.Drawing.Point]::new($x, $y)
    $tb.Size = [System.Drawing.Size]::new($w, 28)
    $tb.Text = $text
    $tb.BackColor = $CLR_INPUT
    $tb.ForeColor = $CLR_FG
    $tb.BorderStyle = 'FixedSingle'
    $tb.Font = [System.Drawing.Font]::new('Consolas', 10)
    if ($password) { $tb.UseSystemPasswordChar = $true }
    return $tb
}

function New-Button {
    param($text, $x, $y, $w=110, $h=34, $accent=$false)
    $btn = [System.Windows.Forms.Button]::new()
    $btn.Text = $text
    $btn.Location = [System.Drawing.Point]::new($x, $y)
    $btn.Size = [System.Drawing.Size]::new($w, $h)
    $btn.FlatStyle = 'Flat'
    $btn.BackColor = if ($accent) { $CLR_BTN } else { $CLR_PANEL }
    $btn.ForeColor = $CLR_FG
    $btn.FlatAppearance.BorderColor = if ($accent) { $CLR_ACCENT } else { [System.Drawing.Color]::FromArgb(70,70,75) }
    $btn.FlatAppearance.BorderSize = 1
    $btn.Font = [System.Drawing.Font]::new('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
    return $btn
}

# ── main form ────────────────────────────────────────────────────────────────
$form = [System.Windows.Forms.Form]::new()
$form.Text = 'Claude Desktop · Windows 3p Portable Installer'
$form.Size = [System.Drawing.Size]::new(620, 540)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.BackColor = $CLR_BG
$form.Icon = [System.Drawing.SystemIcons]::Application

# header strip
$header = [System.Windows.Forms.Panel]::new()
$header.Dock = 'Top'
$header.Height = 70
$header.BackColor = $CLR_PANEL
$form.Controls.Add($header)

$headerTitle = New-Label 'Claude Desktop · Portable Installer' 20 12 450 28 15 $true $CLR_FG
$headerSub   = New-Label '3rd-party gateway · no Anthropic account needed' 20 40 450 22 9 $false $CLR_DIM
$header.Controls.AddRange(@($headerTitle, $headerSub))

# step indicator
$stepPanel = [System.Windows.Forms.Panel]::new()
$stepPanel.Location = [System.Drawing.Point]::new(0, 70)
$stepPanel.Size = [System.Drawing.Size]::new(620, 32)
$stepPanel.BackColor = [System.Drawing.Color]::FromArgb(30,30,34)
$form.Controls.Add($stepPanel)

$stepLabels = @()
$stepNames  = @('  1. Prerequisites  ', '  2. Install Path  ', '  3. Gateway Config  ', '  4. Installing  ', '  5. Done  ')
$stepX = 0
foreach ($s in $stepNames) {
    $sw = 124
    $sl = New-Label $s $stepX 6 $sw 20 8 $false $CLR_DIM
    $sl.TextAlign = 'MiddleCenter'
    $stepPanel.Controls.Add($sl)
    $stepLabels += $sl
    $stepX += $sw
}

function Set-Step {
    param($idx)
    for ($i=0; $i -lt $stepLabels.Count; $i++) {
        if ($i -eq $idx) {
            $stepLabels[$i].ForeColor = $CLR_ACCENT
            $stepLabels[$i].Font = [System.Drawing.Font]::new('Segoe UI', 8, [System.Drawing.FontStyle]::Bold)
        } else {
            $stepLabels[$i].ForeColor = $CLR_DIM
            $stepLabels[$i].Font = [System.Drawing.Font]::new('Segoe UI', 8)
        }
    }
}

# content panel (swapped per step)
$content = [System.Windows.Forms.Panel]::new()
$content.Location = [System.Drawing.Point]::new(0, 102)
$content.Size = [System.Drawing.Size]::new(620, 380)
$content.BackColor = $CLR_BG
$form.Controls.Add($content)

# nav buttons
$btnBack = New-Button '< Back'   20  470 100 34
$btnNext = New-Button 'Next >'  500  470 100 34 $true
$btnBack.Enabled = $false
$form.Controls.AddRange(@($btnBack, $btnNext))

# ── step pages ───────────────────────────────────────────────────────────────
$pages = @()

# ---------- page 0: prerequisites ----------
$p0 = [System.Windows.Forms.Panel]::new()
$p0.Dock = 'Fill'; $p0.BackColor = $CLR_BG

$p0.Controls.Add((New-Label 'System Prerequisites' 24 16 400 28 13 $true))
$p0.Controls.Add((New-Label 'The installer will check required components.' 24 48 550 20 9 $false $CLR_DIM))

# status rows
$prereqs = @(
    @{ label='Visual C++ 2015-2022 x64 Redistributable'; key='vcredist' },
    @{ label='Node.js + npm  (for Claude Code CLI)';      key='node'    },
    @{ label='Claude Code CLI  (@anthropic-ai/claude-code)'; key='ccd' }
)
$prereqIcons  = @{}
$prereqStatus = @{}
$py = 85
foreach ($pr in $prereqs) {
    $icon = New-Label '?' 24 $py 24 24 11 $true $CLR_DIM
    $lbl  = New-Label $pr.label 52 ($py+2) 440 20 9
    $stat = New-Label '' 496 ($py+2) 88 20 9 $false $CLR_DIM
    $stat.TextAlign = 'MiddleRight'
    $p0.Controls.AddRange(@($icon, $lbl, $stat))
    $prereqIcons[$pr.key]  = $icon
    $prereqStatus[$pr.key] = $stat
    $py += 36
}

$p0Hint = New-Label '' 24 200 570 80 8.5 $false $CLR_WARN
$p0Hint.AutoSize = $false
$p0.Controls.Add($p0Hint)

$btnCheckPrereqs = New-Button 'Check Now' 24 290 110 32
$p0.Controls.Add($btnCheckPrereqs)

$pages += $p0

# check prereqs logic
function Invoke-CheckPrereqs {
    # vcredist
    if (Test-VcRedist) {
        $prereqIcons['vcredist'].ForeColor = $CLR_OK
        $prereqIcons['vcredist'].Text = [char]0x2714
        $prereqStatus['vcredist'].Text = 'Installed'
        $prereqStatus['vcredist'].ForeColor = $CLR_OK
        $script:vcOk = $true
    } else {
        $prereqIcons['vcredist'].ForeColor = $CLR_WARN
        $prereqIcons['vcredist'].Text = [char]0x26A0
        $prereqStatus['vcredist'].Text = 'Missing'
        $prereqStatus['vcredist'].ForeColor = $CLR_WARN
        $script:vcOk = $false
    }
    # node
    try {
        $nv = (node --version 2>$null).Trim()
        $prereqIcons['node'].ForeColor = $CLR_OK
        $prereqIcons['node'].Text = [char]0x2714
        $prereqStatus['node'].Text = $nv
        $prereqStatus['node'].ForeColor = $CLR_OK
        $script:nodeOk = $true
    } catch {
        $prereqIcons['node'].ForeColor = $CLR_WARN
        $prereqIcons['node'].Text = [char]0x26A0
        $prereqStatus['node'].Text = 'Not found'
        $prereqStatus['node'].ForeColor = $CLR_WARN
        $script:nodeOk = $false
    }
    # ccd: npm package presence (via package.json) + native binary presence
    $ccdVer = Get-NpmClaudeCodePackageVersion
    $ccdBin = Find-NpmClaudeCode
    $script:ccdVersion = $ccdVer
    $script:ccdBinPath = $ccdBin
    if ($ccdVer -and $ccdBin) {
        $prereqIcons['ccd'].ForeColor = $CLR_OK
        $prereqIcons['ccd'].Text = [char]0x2714
        $prereqStatus['ccd'].Text = "v$ccdVer"
        $prereqStatus['ccd'].ForeColor = $CLR_OK
        $script:ccdOk = $true
    } elseif ($ccdVer -and -not $ccdBin) {
        # npm package installed but native binary missing/broken (the
        # exact failure mode that causes "spawn UNKNOWN" downstream).
        # Installer will repair via npmmirror in step 8.
        $prereqIcons['ccd'].ForeColor = $CLR_WARN
        $prereqIcons['ccd'].Text = [char]0x26A0
        $prereqStatus['ccd'].Text = "v$ccdVer (will fetch binary)"
        $prereqStatus['ccd'].ForeColor = $CLR_WARN
        $script:ccdOk = $false
    } else {
        $prereqIcons['ccd'].ForeColor = $CLR_DIM
        $prereqIcons['ccd'].Text = [char]0x2B58  # circle
        $prereqStatus['ccd'].Text = 'Will install'
        $prereqStatus['ccd'].ForeColor = $CLR_DIM
        $script:ccdOk = $false
    }

    $hints = @()
    if (-not $script:vcOk) { $hints += "• VC++ Redistributable missing: download from https://aka.ms/vs/17/release/vc_redist.x64.exe" }
    if (-not $script:nodeOk) { $hints += "• Node.js not found: install from https://nodejs.org (v18+)" }
    $p0Hint.Text = ($hints -join "`n")

    $btnNext.Enabled = ($script:vcOk -and $script:nodeOk)
}

$btnCheckPrereqs.Add_Click({ Invoke-CheckPrereqs })

# ---------- page 1: install path ----------
$p1 = [System.Windows.Forms.Panel]::new()
$p1.Dock = 'Fill'; $p1.BackColor = $CLR_BG

$p1.Controls.Add((New-Label 'Installation Path' 24 16 400 28 13 $true))
$p1.Controls.Add((New-Label 'Choose where to extract Electron and place the app files.' 24 48 560 20 9 $false $CLR_DIM))
$p1.Controls.Add((New-Label 'Install directory' 24 85 200 20 9 $false $CLR_DIM))

$tbInstallPath = New-TextBox 24 108 490 $DEFAULT_INSTALL
$btnBrowse = New-Button 'Browse...' 518 106 76 28
$p1.Controls.AddRange(@($tbInstallPath, $btnBrowse))

$p1.Controls.Add((New-Label 'Required disk space:  ~450 MB  (Electron ~200 MB + app ~27 MB + UI ~100 MB + Claude Code ~226 MB)' 24 145 560 20 8.5 $false $CLR_DIM))

$btnBrowse.Add_Click({
    $dlg = [System.Windows.Forms.FolderBrowserDialog]::new()
    $dlg.Description = 'Select installation folder'
    $dlg.SelectedPath = $tbInstallPath.Text
    $dlg.ShowNewFolderButton = $true
    if ($dlg.ShowDialog() -eq 'OK') { $tbInstallPath.Text = $dlg.SelectedPath }
})

$pages += $p1

# ---------- page 2: gateway ----------
$p2 = [System.Windows.Forms.Panel]::new()
$p2.Dock = 'Fill'; $p2.BackColor = $CLR_BG

$p2.Controls.Add((New-Label 'Gateway Configuration' 24 16 400 28 13 $true))

# existing settings notice (shown/hidden dynamically)
$p2ExistingNotice = [System.Windows.Forms.Panel]::new()
$p2ExistingNotice.Location = [System.Drawing.Point]::new(24, 48)
$p2ExistingNotice.Size = [System.Drawing.Size]::new(570, 68)
$p2ExistingNotice.BackColor = [System.Drawing.Color]::FromArgb(20, 34, 197, 94)
$p2ExistingNotice.BorderStyle = 'FixedSingle'
$p2ExistingNotice.Visible = $false
$noticeIcon = New-Label ([char]0x2714) 10 8 24 24 12 $true $CLR_OK
$noticeText = New-Label 'Existing settings.json detected.' 36 8 400 20 9 $true $CLR_OK
$noticeUrl  = New-Label '' 36 28 500 20 8.5 $false $CLR_DIM
$p2ExistingNotice.Controls.AddRange(@($noticeIcon, $noticeText, $noticeUrl))
$p2.Controls.Add($p2ExistingNotice)

$chkSkip = [System.Windows.Forms.CheckBox]::new()
$chkSkip.Location = [System.Drawing.Point]::new(24, 122)
$chkSkip.Size = [System.Drawing.Size]::new(16, 20)
$chkSkip.BackColor = [System.Drawing.Color]::Transparent
$chkSkip.Visible = $false
$lblSkip = New-Label 'Use existing configuration (skip this step)' 44 122 380 20 9 $false $CLR_OK
$lblSkip.Visible = $false
$p2.Controls.AddRange(@($chkSkip, $lblSkip))

$chkSkip.Add_CheckedChanged({
    $skip = $chkSkip.Checked
    $tbBaseUrl.Enabled = -not $skip
    $tbApiKey.Enabled  = -not $skip
    $chkShow.Enabled   = -not $skip
})

$p2.Controls.Add((New-Label 'API Base URL' 24 152 200 20 9 $false $CLR_DIM))
$tbBaseUrl = New-TextBox 24 174 570 'https://api.deepseek.com/anthropic'

$p2.Controls.Add((New-Label 'API Key  (sk-...)' 24 210 200 20 9 $false $CLR_DIM))
$tbApiKey = New-TextBox 24 233 570 '' $true

$p2.Controls.Add((New-Label 'Show key' 44 268 80 20 8))
$chkShow = [System.Windows.Forms.CheckBox]::new()
$chkShow.Location = [System.Drawing.Point]::new(28, 267)
$chkShow.Size = [System.Drawing.Size]::new(16, 20)
$chkShow.BackColor = [System.Drawing.Color]::Transparent
$chkShow.Add_CheckedChanged({ $tbApiKey.UseSystemPasswordChar = -not $chkShow.Checked })
$p2.Controls.Add($chkShow)

$p2.Controls.Add((New-Label 'Supported gateways: DeepSeek · MiniMax · OpenRouter · any Anthropic-compatible reverse proxy' 24 300 560 36 8.5 $false $CLR_DIM))

$p2.Controls.AddRange(@($tbBaseUrl, $tbApiKey))
$pages += $p2

# ---------- page 3: progress ----------
$p3 = [System.Windows.Forms.Panel]::new()
$p3.Dock = 'Fill'; $p3.BackColor = $CLR_BG

$p3.Controls.Add((New-Label 'Installing...' 24 16 400 28 13 $true))

$logBox = [System.Windows.Forms.RichTextBox]::new()
$logBox.Location = [System.Drawing.Point]::new(24, 52)
$logBox.Size = [System.Drawing.Size]::new(570, 200)
$logBox.BackColor = [System.Drawing.Color]::FromArgb(18,18,20)
$logBox.ForeColor = $CLR_FG
$logBox.Font = [System.Drawing.Font]::new('Consolas', 8.5)
$logBox.ReadOnly = $true
$logBox.BorderStyle = 'None'
$logBox.ScrollBars = 'Vertical'
$p3.Controls.Add($logBox)

$progress = [System.Windows.Forms.ProgressBar]::new()
$progress.Location = [System.Drawing.Point]::new(24, 260)
$progress.Size = [System.Drawing.Size]::new(570, 14)
$progress.Style = 'Continuous'
$progress.Minimum = 0
$progress.Maximum = 100
$p3.Controls.Add($progress)

$lblProgress = New-Label '' 24 278 570 20 8.5 $false $CLR_DIM
$p3.Controls.Add($lblProgress)

$pages += $p3

function Write-Log {
    param($msg, $color=$null)
    $logBox.SelectionStart = $logBox.TextLength
    $logBox.SelectionLength = 0
    if ($color) { $logBox.SelectionColor = $color } else { $logBox.SelectionColor = $CLR_FG }
    $logBox.AppendText("$msg`n")
    $logBox.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

function Set-Progress {
    param($pct, $msg)
    $progress.Value = [Math]::Min($pct, 100)
    $lblProgress.Text = $msg
    [System.Windows.Forms.Application]::DoEvents()
}

# ---------- page 4: done ----------
$p4 = [System.Windows.Forms.Panel]::new()
$p4.Dock = 'Fill'; $p4.BackColor = $CLR_BG

$doneIcon = New-Label [char]0x2714 220 30 160 80 48 $true $CLR_OK
$doneIcon.TextAlign = 'MiddleCenter'
$p4.Controls.Add($doneIcon)

$p4.Controls.Add((New-Label 'Installation Complete!' 120 110 380 32 14 $true))
$donePath = New-Label '' 24 150 570 20 9 $false $CLR_DIM
$p4.Controls.Add($donePath)

# expected limitations notice
$doneNotice = [System.Windows.Forms.Panel]::new()
$doneNotice.Location = [System.Drawing.Point]::new(24, 175)
$doneNotice.Size = [System.Drawing.Size]::new(570, 90)
$doneNotice.BackColor = [System.Drawing.Color]::FromArgb(30, 234, 179, 8)
$doneNotice.BorderStyle = 'FixedSingle'
$doneNotice.Controls.Add((New-Label ([char]0x2139 + '  What to expect after launch:') 10 6 500 20 9 $true $CLR_WARN))
$doneNotice.Controls.Add((New-Label ([char]0x2714 + '  Cowork tab: connects via your gateway  (main feature)') 10 26 530 18 8.5 $false $CLR_OK))
$doneNotice.Controls.Add((New-Label ([char]0x2714 + '  Code tab: Claude Code CLI (requires gateway in settings.json)') 10 44 530 18 8.5 $false $CLR_OK))
$doneNotice.Controls.Add((New-Label ([char]0x2716 + '  Chat tab: shows connection error  (expected — needs claude.ai, not supported)') 10 62 540 18 8.5 $false $CLR_WARN))
$p4.Controls.Add($doneNotice)

$btnLaunch = New-Button 'Launch Claude' 220 280 180 40 $true
$btnLaunch.Font = [System.Drawing.Font]::new('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
$p4.Controls.Add($btnLaunch)

$pages += $p4

# ── step state ───────────────────────────────────────────────────────────────
$script:currentStep    = 0
$script:vcOk           = $false
$script:nodeOk         = $false
$script:ccdOk          = $false
$script:ccdVersion     = ''
$script:ccdBinPath     = ''
$script:existingConfig = Read-ExistingSettings

function Show-Page {
    param($idx)
    $content.Controls.Clear()
    $content.Controls.Add($pages[$idx])
    Set-Step $idx
    $script:currentStep = $idx
    $btnBack.Enabled = ($idx -gt 0 -and $idx -lt 3)
    $btnNext.Visible = ($idx -lt 3)
    $btnBack.Visible = ($idx -lt 3)

    # populate page 2 with existing config if available
    if ($idx -eq 2 -and $script:existingConfig) {
        $p2ExistingNotice.Visible = $true
        $chkSkip.Visible  = $true
        $lblSkip.Visible  = $true
        $noticeUrl.Text   = "URL: $($script:existingConfig.url)"
        $tbBaseUrl.Text   = $script:existingConfig.url
        $tbApiKey.UseSystemPasswordChar = $false
        $tbApiKey.Text    = $script:existingConfig.key
        $tbApiKey.UseSystemPasswordChar = $true
        $chkSkip.Checked  = $true   # default: skip
    } else {
        $p2ExistingNotice.Visible = $false
        $chkSkip.Visible  = $false
        $lblSkip.Visible  = $false
    }

    $form.Refresh()
}

# ── installation logic ───────────────────────────────────────────────────────
function Start-Install {
    $installDir = $tbInstallPath.Text.Trim()
    $baseUrl    = $tbBaseUrl.Text.Trim()
    $apiKey     = $tbApiKey.Text.Trim()

    $btnNext.Enabled = $false
    $btnBack.Enabled = $false

    # 1. create install dir
    Set-Progress 5 'Creating installation directory...'
    Write-Log "Install dir: $installDir"
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null

    # 2. download Electron (skip if already cached)
    if (-not (Test-Path $ELECTRON_ZIP)) {
        Set-Progress 10 'Downloading Electron 41.5.0 (~95 MB)...'
        Write-Log 'Downloading Electron 41.5.0 win32-x64...' $CLR_DIM
        try {
            $wc = [System.Net.WebClient]::new()
            $wc.Headers.Add('User-Agent', 'Mozilla/5.0')
            $wc.DownloadFile($ELECTRON_URL, $ELECTRON_ZIP)
            Write-Log "  -> saved to $ELECTRON_ZIP" $CLR_OK
        } catch {
            Write-Log "  ERROR: $_" ([System.Drawing.Color]::FromArgb(248,113,113))
            [System.Windows.Forms.MessageBox]::Show("Failed to download Electron.`n$_", 'Error', 'OK', 'Error') | Out-Null
            return
        }
    } else {
        Write-Log "Electron zip found in cache, skipping download." $CLR_DIM
    }

    # 3. extract Electron
    Set-Progress 35 'Extracting Electron runtime...'
    Write-Log 'Extracting Electron...'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($ELECTRON_ZIP, $installDir)

    # rename electron.exe -> Claude.exe
    $electronExe = Join-Path $installDir 'electron.exe'
    $claudeExe   = Join-Path $installDir 'Claude.exe'
    if (Test-Path $electronExe) {
        if (Test-Path $claudeExe) { Remove-Item $claudeExe -Force }
        Rename-Item $electronExe 'Claude.exe'
        Write-Log '  -> renamed electron.exe to Claude.exe' $CLR_OK
    }

    # 4. copy prebuilt app.asar
    Set-Progress 55 'Copying app.asar...'
    Write-Log 'Copying prebuilt app.asar...'
    $resDir = Join-Path $installDir 'resources'
    New-Item -ItemType Directory -Path $resDir -Force | Out-Null

    $srcAsar = Join-Path $PREBUILT_DIR 'app.asar'
    Copy-Item $srcAsar (Join-Path $resDir 'app.asar') -Force
    Write-Log '  -> app.asar copied' $CLR_OK

    # 5. copy app.asar.unpacked (native modules)
    Set-Progress 60 'Copying native modules...'
    Write-Log 'Copying native modules (app.asar.unpacked)...'
    $srcUnpacked = Join-Path $PREBUILT_DIR 'app.asar.unpacked'
    $dstUnpacked = Join-Path $resDir 'app.asar.unpacked'
    if (Test-Path $dstUnpacked) { Remove-Item $dstUnpacked -Recurse -Force }
    Copy-Item $srcUnpacked $dstUnpacked -Recurse -Force
    Write-Log '  -> native modules copied' $CLR_OK

    # 5b. copy ion-dist (SPA UI assets served via app:// protocol)
    Set-Progress 70 'Copying SPA UI assets (ion-dist ~100 MB)...'
    Write-Log 'Copying ion-dist (SPA assets for app:// protocol)...'
    $srcIonDist = Join-Path $PREBUILT_DIR 'ion-dist'
    $dstIonDist = Join-Path $resDir 'ion-dist'
    if (-not (Test-Path $srcIonDist)) {
        Write-Log "  ERROR: ion-dist not found in prebuilt/. Without it the app will fail with 'app://localhost/ ERR_FILE_NOT_FOUND' on launch." ([System.Drawing.Color]::FromArgb(248,113,113))
        [System.Windows.Forms.MessageBox]::Show("Critical: prebuilt/ion-dist is missing.`nThe deploy kit is incomplete - reach out for an updated kit.", 'Missing UI assets', 'OK', 'Error') | Out-Null
        return
    }
    if (Test-Path $dstIonDist) { Remove-Item $dstIonDist -Recurse -Force }
    Copy-Item $srcIonDist $dstIonDist -Recurse -Force
    Write-Log '  -> ion-dist copied' $CLR_OK

    # 5c. create VM bundle placeholder files (HostBackend skips download)
    Set-Progress 72 'Creating VM bundle placeholders...'
    Write-Log 'Creating VM bundle placeholder files (HostBackend mode)...'
    $vmBundleDir = "$env:LOCALAPPDATA\Claude-3p\vm_bundles\claudevm.bundle"
    New-Item -ItemType Directory -Path $vmBundleDir -Force | Out-Null
    $bundleSHA = '5680b11bcdab215cccf07e0c0bd1bd9213b0c25d'
    @('rootfs.vhdx', 'vmlinuz', 'initrd') | ForEach-Object {
        $f = Join-Path $vmBundleDir $_
        if (-not (Test-Path $f)) { Set-Content $f 'placeholder' -Encoding ASCII }
        $o = Join-Path $vmBundleDir ".$_.origin"
        Set-Content $o $bundleSHA -Encoding ASCII
    }
    Write-Log '  -> VM bundle placeholders created' $CLR_OK

    # 6. write ~/.claude/settings.json (skip if user chose to keep existing)
    Set-Progress 75 'Writing gateway configuration...'
    if ($chkSkip.Checked -and $script:existingConfig) {
        Write-Log 'Keeping existing ~/.claude/settings.json' $CLR_DIM
    } else {
        Write-Log 'Writing ~/.claude/settings.json...'
        $claudeConfig = Join-Path $env:USERPROFILE '.claude'
        New-Item -ItemType Directory -Path $claudeConfig -Force | Out-Null
        $settings = @{
            env = @{
                ANTHROPIC_BASE_URL   = $baseUrl
                ANTHROPIC_AUTH_TOKEN = $apiKey
            }
        } | ConvertTo-Json -Depth 4
        Set-Content (Join-Path $claudeConfig 'settings.json') $settings -Encoding UTF8
        Write-Log '  -> settings.json written' $CLR_OK
    }

    # 7. determine TWO version numbers (they are NOT the same):
    #    - $asarVersion: directory name app.asar hard-codes when it spawns
    #      claude.exe (e.g. "2.1.128"). Used for the deploy PATH.
    #    - $binaryVersion: version of claude.exe we actually ship (= what
    #      `claude -v` would print, sourced from the user's npm install,
    #      possibly newer than asarVersion). Anthropic's CLI is backward
    #      compatible across patch versions, so a newer binary placed
    #      under the older directory name works fine.
    Set-Progress 78 'Resolving Claude Code versions...'
    $asarVersion = Get-AppAsarRequiredVersion (Join-Path $resDir 'app.asar')
    if ($asarVersion) {
        Write-Log "app.asar deploy dir: $asarVersion (path Claude Desktop spawns from)"
    } else {
        Write-Log "  WARNING: cannot read required version from app.asar; will fall back to npm version" $CLR_WARN
    }

    $binaryVersion = Get-NpmClaudeCodePackageVersion
    if (-not $binaryVersion) {
        Write-Log 'No global @anthropic-ai/claude-code found; installing via npmmirror...'
        Write-Log '  (this may take 1-2 minutes)' $CLR_DIM
        try {
            $npmOut = npm install -g '@anthropic-ai/claude-code' --registry=$NPMMIRROR_REGISTRY 2>&1
            Write-Log ($npmOut -join "`n") $CLR_DIM
            $binaryVersion = Get-NpmClaudeCodePackageVersion
        } catch {
            Write-Log "  WARNING: npm install failed - $_" $CLR_WARN
        }
    }

    # If we still can't read a version locally (e.g. npm prefix mismatch,
    # nvm shadowing, install raced with package.json flush), fall back to
    # asking npmmirror for the latest dist-tag — we only need a version
    # number to drive the tarball download in step 8.
    if (-not $binaryVersion) {
        Write-Log "  -> local npm version probe failed; querying npmmirror for latest..." $CLR_DIM
        try {
            $latest = Invoke-RestMethod -Uri "$NPMMIRROR_REGISTRY/$BINARY_PKG_NAME/latest" -UseBasicParsing -TimeoutSec 30
            if ($latest -and $latest.version) {
                $binaryVersion = $latest.version
                Write-Log "     using latest from npmmirror: v$binaryVersion" $CLR_DIM
            }
        } catch {
            Write-Log "     npmmirror query failed: $_" $CLR_WARN
        }
    }

    if ($binaryVersion) { Write-Log "Binary source version: v$binaryVersion" }

    # The deploy directory is the asar version; binary content is the npm version.
    # If asar is unreadable (shouldn't happen with our prebuilt), use binary version for both.
    $deployVersion = if ($asarVersion) { $asarVersion } else { $binaryVersion }
    $script:ccdVersion = $deployVersion

    # 8. deploy claude.exe (v$binaryVersion) into ...\claude-code\$deployVersion\
    #    Source priority: cache hit  ->  local npm platform package  ->  npmmirror tarball
    if (-not $deployVersion -or -not $binaryVersion) {
        Write-Log "  ERROR: cannot determine target version(s). Code tab will not work." ([System.Drawing.Color]::FromArgb(248,113,113))
    } else {
        Set-Progress 82 "Deploying claude.exe v$binaryVersion -> dir [$deployVersion]..."
        $cacheDir = "$env:LOCALAPPDATA\Claude-3p\claude-code\$deployVersion"
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
        $cacheExe = Join-Path $cacheDir 'claude.exe'

        if (Test-IsRealClaudeExe $cacheExe) {
            Write-Log "  -> already deployed: $cacheExe ($([math]::Round((Get-Item $cacheExe).Length/1MB,1)) MB)" $CLR_OK
        } else {
            # Remove stale junk: cmd shim renamed to .exe, or 0-byte placeholder
            # Claude Desktop creates when its own claude.exe.zst download fails.
            if (Test-Path $cacheExe) {
                $staleSize = (Get-Item $cacheExe).Length
                Write-Log "  -> removing stale claude.exe ($staleSize bytes)" $CLR_DIM
                Remove-Item $cacheExe -Force -EA SilentlyContinue
            }

            $localBin = Find-NpmClaudeCode
            if ($localBin) {
                Write-Log "Using local npm platform binary: $localBin"
                Copy-Item $localBin $cacheExe -Force
            } else {
                Write-Log "No local native binary; downloading v$binaryVersion from npmmirror..." $CLR_DIM
                $mirrorBin = Get-ClaudeBinaryFromMirror -version $binaryVersion
                if ($mirrorBin) { Copy-Item $mirrorBin $cacheExe -Force }
            }

            if (Test-IsRealClaudeExe $cacheExe) {
                New-Item -ItemType File -Path "$cacheDir\.verified" -Force | Out-Null
                Write-Log "  -> deployed: $cacheExe" $CLR_OK
                if ($asarVersion -and $binaryVersion -and $asarVersion -ne $binaryVersion) {
                    Write-Log "     (binary v$binaryVersion mounted at hard-coded path '$deployVersion')" $CLR_DIM
                }
            } else {
                Write-Log "  ERROR: claude.exe deployment failed. Code tab will report 'spawn UNKNOWN' until resolved." ([System.Drawing.Color]::FromArgb(248,113,113))
                Write-Log "  Manual fix: download from $NPMMIRROR_REGISTRY/$BINARY_PKG_NAME/$binaryVersion and place at $cacheExe" $CLR_DIM
            }
        }
    }

    # 8. ensure %LOCALAPPDATA%\Claude-3p\ exists (app userData dir)
    Set-Progress 93 'Creating app data directory...'
    $claude3pDir = "$env:LOCALAPPDATA\Claude-3p"
    New-Item -ItemType Directory -Path $claude3pDir -Force | Out-Null
    Write-Log "App userData: $claude3pDir" $CLR_DIM

    # 9. copy tray icon files to resources/ (app.asar loads them for system tray)
    Set-Progress 92 'Copying tray icons...'
    $trayIcons = @(
        'Tray-Win32.ico',
        'Tray-Win32-Dark.ico',
        'TrayIconTemplate.png',
        'TrayIconTemplate@2x.png',
        'TrayIconTemplate@3x.png',
        'TrayIconTemplate-Dark.png',
        'TrayIconTemplate-Dark@2x.png',
        'TrayIconTemplate-Dark@3x.png'
    )
    foreach ($trayIcon in $trayIcons) {
        $srcTray = Join-Path $PREBUILT_DIR $trayIcon
        $dstTray = Join-Path $resDir $trayIcon
        if (Test-Path $srcTray) {
            Copy-Item $srcTray $dstTray -Force
        } else {
            Write-Log "  WARNING: $trayIcon not found in prebuilt/" $CLR_WARN
        }
    }
    Write-Log '  -> tray icons copied' $CLR_OK

    # 10. inject icon into Claude.exe via rcedit
    Set-Progress 95 'Injecting icon...'
    $icoSrc = Join-Path $SCRIPT_DIR 'patches\icons\claude-logo.ico'
    $icoDst = Join-Path $installDir 'claude.ico'
    if (Test-Path $icoSrc) {
        Copy-Item $icoSrc $icoDst -Force
        try {
            $rceditOut = npx --yes rcedit $claudeExe --set-icon $icoDst 2>&1
            Write-Log '  -> icon injected into Claude.exe' $CLR_OK
        } catch {
            Write-Log "  WARNING: icon injection failed (rcedit): $_" $CLR_WARN
            Write-Log '  Shortcut will still use the .ico file.' $CLR_DIM
        }
    } else {
        Write-Log '  WARNING: claude-logo.ico not found, skipping icon injection.' $CLR_WARN
    }

    # 11. create desktop shortcut
    Set-Progress 97 'Creating desktop shortcut...'
    try {
        $shell    = New-Object -ComObject WScript.Shell
        $lnkPath  = Join-Path ([System.Environment]::GetFolderPath('Desktop')) 'Claude.lnk'
        $shortcut = $shell.CreateShortcut($lnkPath)
        $shortcut.TargetPath       = $claudeExe
        $shortcut.WorkingDirectory = $installDir
        $shortcut.Description      = 'Claude Desktop (3p Portable)'
        if (Test-Path $icoDst) {
            $shortcut.IconLocation = "$icoDst,0"
        }
        $shortcut.Save()
        Write-Log "Desktop shortcut: $lnkPath" $CLR_OK
    } catch {
        Write-Log "  WARNING: shortcut creation failed: $_" $CLR_WARN
    }

    # done
    Set-Progress 100 'Installation complete!'
    Write-Log ''
    Write-Log 'All done!' $CLR_OK
    Write-Log "Launch: $claudeExe"

    $donePath.Text = "Installed to: $installDir"
    $btnLaunch.Tag = $claudeExe
    Show-Page 4
}

# ── nav wiring ───────────────────────────────────────────────────────────────
$btnNext.Add_Click({
    switch ($script:currentStep) {
        0 {
            if (-not $script:vcOk -or -not $script:nodeOk) {
                [System.Windows.Forms.MessageBox]::Show('Please fix missing prerequisites first.', 'Prerequisites', 'OK', 'Warning') | Out-Null
                return
            }
            Show-Page 1
        }
        1 {
            $p = $tbInstallPath.Text.Trim()
            if (-not $p) {
                [System.Windows.Forms.MessageBox]::Show('Please enter an installation path.', 'Path required', 'OK', 'Warning') | Out-Null
                return
            }
            Show-Page 2
        }
        2 {
            if (-not $chkSkip.Checked) {
                if (-not $tbBaseUrl.Text.Trim()) {
                    [System.Windows.Forms.MessageBox]::Show('Please enter the API base URL.', 'Required', 'OK', 'Warning') | Out-Null
                    return
                }
                if (-not $tbApiKey.Text.Trim()) {
                    [System.Windows.Forms.MessageBox]::Show('Please enter the API key.', 'Required', 'OK', 'Warning') | Out-Null
                    return
                }
            }
            Show-Page 3
            Start-Install
        }
    }
})

$btnBack.Add_Click({
    if ($script:currentStep -gt 0) { Show-Page ($script:currentStep - 1) }
})

$btnLaunch.Add_Click({
    $exe = $btnLaunch.Tag
    if ($exe -and (Test-Path $exe)) {
        Start-Process $exe
        $form.Close()
    } else {
        [System.Windows.Forms.MessageBox]::Show("Executable not found: $exe", 'Error', 'OK', 'Error') | Out-Null
    }
})

# ── start ────────────────────────────────────────────────────────────────────
Show-Page 0
Invoke-CheckPrereqs
[System.Windows.Forms.Application]::Run($form)

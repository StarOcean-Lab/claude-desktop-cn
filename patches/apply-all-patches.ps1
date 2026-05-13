# apply-all-patches.ps1
# One-shot script: extract a fresh aaddrick app.asar, apply ALL Windows
# patches, and repack. Run this every time aaddrick releases a new version.
#
# Usage:
#   .\apply-all-patches.ps1 -asarPath .\fresh-app.asar
#
# What it does:
#   1. Extracts app.asar to a temp dir
#   2. Replaces claude-native stub (readRegistryValues fix)
#   3. Injects Cowork bypass snippet into frame-fix-wrapper.js
#   4. Injects CCD env passthrough into frame-fix-wrapper.js (optional)
#   5. Applies probe fix (.vite/build/index.js - gateway health check)
#   6. Repacks with npx asar
#
# Output: <asarPath>.patched (the repacked asar) + .unpacked directory
#
# Prerequisites: Node.js with npx on PATH

param(
    [Parameter(Mandatory=$true)]
    [string] $asarPath,

    [switch] $skipCcdPassthrough,

    [string] $outputPath,

    [string] $workDir
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Validate input
if (-not (Test-Path $asarPath)) {
    Write-Error "app.asar not found: $asarPath"
    exit 1
}

# Use a temp work directory if not specified
if (-not $workDir) {
    $workDir = Join-Path $env:TEMP "claude-asar-patch-$([Guid]::NewGuid().ToString().Substring(0,8))"
}

$extractDir = Join-Path $workDir 'extracted'

if (-not $outputPath) {
    $outputPath = "$asarPath.patched"
}

Write-Host "============================================" -ForegroundColor Cyan
Write-Host " Claude Desktop Windows Patch Pipeline" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Input:  $asarPath"
Write-Host "Work:   $workDir"
Write-Host "Output: $outputPath"
Write-Host ""

# ── Step 0: Prepare work directory ──────────────────────────────────
Write-Host "[0/6] Preparing work directory..." -ForegroundColor Yellow
New-Item -ItemType Directory -Path $workDir -Force | Out-Null
New-Item -ItemType Directory -Path $extractDir -Force | Out-Null

# ── Step 1: Extract app.asar ────────────────────────────────────────
Write-Host "[1/6] Extracting app.asar..." -ForegroundColor Yellow

# Handle missing pty.node (aaddrick Linux build may lack it)
$ptyPath = Join-Path $extractDir 'node_modules\node-pty\build\Release\pty.node'
$ptyDir = Split-Path $ptyPath -Parent
New-Item -ItemType Directory -Path $ptyDir -Force | Out-Null
New-Item -ItemType File -Path $ptyPath -Force | Out-Null

$extractResult = npx --yes asar extract $asarPath $extractDir 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "asar extract failed: $extractResult"
    exit $LASTEXITCODE
}
Write-Host "  -> Extracted to $extractDir" -ForegroundColor Green

# ── Step 2: Replace claude-native stub ──────────────────────────────
Write-Host "[2/6] Replacing claude-native stub..." -ForegroundColor Yellow
$stubSrc = Join-Path $scriptDir 'claude-native-stub.js'
$stubDst = Join-Path $extractDir 'node_modules\@ant\claude-native\index.js'

if (-not (Test-Path $stubSrc)) {
    Write-Error "claude-native-stub.js not found at $stubSrc"
    exit 1
}
Copy-Item $stubSrc $stubDst -Force
Write-Host "  -> Stub installed" -ForegroundColor Green

# ── Step 3: Inject Cowork bypass ────────────────────────────────────
Write-Host "[3/6] Injecting Cowork bypass..." -ForegroundColor Yellow
$wrapperPath = Join-Path $extractDir 'frame-fix-wrapper.js'
$bypassSrc = Join-Path $scriptDir 'cowork-bypass-snippet.js'

if (-not (Test-Path $wrapperPath)) {
    Write-Error "frame-fix-wrapper.js not found at $wrapperPath"
    exit 1
}
if (-not (Test-Path $bypassSrc)) {
    Write-Error "cowork-bypass-snippet.js not found at $bypassSrc"
    exit 1
}

$wrapper = Get-Content $wrapperPath -Raw
$bypass  = Get-Content $bypassSrc -Raw

# Inject after the first console.log line
$injectAfter = "[Frame Fix] Wrapper loaded"
$injectIdx = $wrapper.IndexOf($injectAfter)
if ($injectIdx -lt 0) {
    Write-Error "Could not find injection point in frame-fix-wrapper.js"
    exit 1
}
$lineEnd = $wrapper.IndexOf("`n", $injectIdx)
if ($lineEnd -lt 0) { $lineEnd = $wrapper.IndexOf("`r`n", $injectIdx) }
if ($lineEnd -lt 0) {
    Write-Error "Could not find end of injection line"
    exit 1
}

$wrapper = $wrapper.Insert($lineEnd + 1, "`r`n$bypass`r`n")
Set-Content $wrapperPath $wrapper -NoNewline
Write-Host "  -> Cowork bypass injected" -ForegroundColor Green

# ── Step 4: Inject CCD env passthrough (optional) ───────────────────
if (-not $skipCcdPassthrough) {
    Write-Host "[4/6] Injecting CCD env passthrough..." -ForegroundColor Yellow
    $ccdSrc = Join-Path $scriptDir 'ccd-env-passthrough.js'

    if (Test-Path $ccdSrc) {
        $ccd = Get-Content $ccdSrc -Raw
        $wrapper = Get-Content $wrapperPath -Raw

        # Inject after the Cowork bypass block
        # Look for the last line of the bypass snippet as injection point
        $bypassEnd = '// END cowork-bypass-snippet'
        $beIdx = $wrapper.IndexOf($bypassEnd)
        if ($beIdx -lt 0) {
            # Fallback: inject before the original wrapper code resumes
            $beIdx = $wrapper.IndexOf('// ===== END OF BYPASS')
            if ($beIdx -lt 0) {
                $beIdx = $wrapper.IndexOf('// original wrapper')
                if ($beIdx -lt 0) {
                    Write-Host "  -> Skipping CCD passthrough (injection point not found)" -ForegroundColor Yellow
                }
            }
        }

        if ($beIdx -ge 0) {
            $lineEnd = $wrapper.IndexOf("`n", $beIdx)
            if ($lineEnd -lt 0) { $lineEnd = $wrapper.IndexOf("`r`n", $beIdx) }
            $wrapper = $wrapper.Insert($lineEnd + 1, "`r`n$ccd`r`n")
            Set-Content $wrapperPath $wrapper -NoNewline
            Write-Host "  -> CCD env passthrough injected" -ForegroundColor Green
        }
    } else {
        Write-Host "  -> Skipping CCD passthrough (ccd-env-passthrough.js not found)" -ForegroundColor Yellow
    }
} else {
    Write-Host "[4/6] CCD env passthrough skipped (--skipCcdPassthrough)" -ForegroundColor Yellow
}

# ── Step 5: Apply probe fix ─────────────────────────────────────────
Write-Host "[5/6] Applying probe fix..." -ForegroundColor Yellow
$probeFixScript = Join-Path $scriptDir 'apply-probe-fix.cjs'

if (-not (Test-Path $probeFixScript)) {
    Write-Error "apply-probe-fix.cjs not found at $probeFixScript"
    exit 1
}

$probeResult = node $probeFixScript $extractDir 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Probe fix failed: $probeResult"
    exit $LASTEXITCODE
}
Write-Host "  -> $probeResult" -ForegroundColor Green

# ── Step 6: Copy Windows Cowork daemon ───────────────────────────────
Write-Host "[6/7] Copying Windows Cowork daemon..." -ForegroundColor Yellow
$daemonSrc = Join-Path $scriptDir 'cowork-vm-service-win.js'
$daemonDst = Join-Path $extractDir 'cowork-vm-service-win.js'
if (Test-Path $daemonSrc) {
    Copy-Item $daemonSrc $daemonDst -Force
    Write-Host "  -> cowork-vm-service-win.js installed" -ForegroundColor Green
} else {
    Write-Host "  -> Skipping (cowork-vm-service-win.js not found)" -ForegroundColor Yellow
}

# ── Step 7: Repack ──────────────────────────────────────────────────
Write-Host "[7/7] Repacking app.asar..." -ForegroundColor Yellow

# Clean previous outputs
Remove-Item -ErrorAction SilentlyContinue $outputPath
Remove-Item -ErrorAction SilentlyContinue -Recurse "$outputPath.unpacked"

$unpackPattern = '{*.node,*.exe,*.dll,cowork-vm-service.js,cowork-vm-service-win.js}'

$packResult = npx --yes asar pack $extractDir $outputPath --unpack $unpackPattern 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "asar pack failed: $packResult"
    exit $LASTEXITCODE
}

$asarSize = (Get-Item $outputPath).Length
Write-Host "  -> Packed: $outputPath ($([math]::Round($asarSize/1MB, 1)) MB)" -ForegroundColor Green

# ── Cleanup ─────────────────────────────────────────────────────────
Write-Host ""
Write-Host "Cleaning up work directory..." -ForegroundColor Yellow
Remove-Item -Recurse -Force $workDir -ErrorAction SilentlyContinue

# ── Done ────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " ALL PATCHES APPLIED SUCCESSFULLY" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Copy $outputPath → deploy-kit\prebuilt\app.asar"
Write-Host "  2. Copy $outputPath.unpacked → deploy-kit\prebuilt\app.asar.unpacked\"
Write-Host "  3. Update portable install: copy both to resources\"
Write-Host "  4. If ion-dist changed, update deploy-kit\prebuilt\ion-dist\ too"
Write-Host ""
Write-Host "Or use update-deploy-kit.ps1 to do steps 1-2 automatically."

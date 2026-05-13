# Re-pack a patched app.asar for Claude Desktop portable build.
# Usage:
#   1. Extract original app.asar to a folder (e.g., asar-extract\) using:
#        npx asar extract path\to\app.asar asar-extract
#      If extract fails with "ENOENT pty.node", run:
#        New-Item -ItemType File -Path 'asar-extract\node_modules\node-pty\build\Release\pty.node' -Force
#      then retry the extract.
#   2. Replace asar-extract\node_modules\@ant\claude-native\index.js
#      with the patched stub from this repo (claude-native-stub.js).
#   3. Run this script with $extractDir and $outputAsar.
#
# Requires Node.js with npx available on PATH.

param(
    [Parameter(Mandatory=$true)] [string] $extractDir,
    [Parameter(Mandatory=$true)] [string] $outputAsar
)

if (-not (Test-Path $extractDir)) {
    Write-Error "Extract dir not found: $extractDir"
    exit 1
}

# Clean previous outputs.
Remove-Item -ErrorAction SilentlyContinue $outputAsar
Remove-Item -ErrorAction SilentlyContinue -Recurse "$outputAsar.unpacked"

# The unpack pattern keeps native binaries and the cowork daemon source out
# of the asar archive, since Electron cannot dlopen .node files from inside
# an asar and the daemon source needs a real path on disk for child_process.fork.
$unpackPattern = '{*.node,*.exe,*.dll,cowork-vm-service.js,cowork-vm-service-win.js}'

Write-Host "Packing $extractDir -> $outputAsar (unpack: $unpackPattern)..."
& npx --yes asar pack $extractDir $outputAsar --unpack $unpackPattern

if ($LASTEXITCODE -ne 0) {
    Write-Error "asar pack failed with exit code $LASTEXITCODE"
    exit $LASTEXITCODE
}

$asarSize = (Get-Item $outputAsar).Length
$unpackedFiles = Get-ChildItem -Recurse -File "$outputAsar.unpacked" -ErrorAction SilentlyContinue
Write-Host "Done. asar=$asarSize bytes, unpacked files=$($unpackedFiles.Count)"
$unpackedFiles | Select-Object FullName, Length | Format-Table -AutoSize

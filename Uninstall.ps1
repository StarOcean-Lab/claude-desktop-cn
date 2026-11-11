#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$InstallDir = '',
    [switch]$PurgeData,
    [switch]$NonInteractive
)

. (Join-Path $PSScriptRoot 'lib\Common.ps1')

Initialize-Console
try {
    Assert-Windows

    $state = Read-InstallState
    if ($state) {
        if (-not $InstallDir -and $state.installDir) {
            $InstallDir = [string]$state.installDir
        }
    }
    if (-not $InstallDir -and $state -and $state.mode -eq 'Portable') {
        $InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\Claude-CN'
    }
    if (-not $InstallDir -and -not $state) {
        $defaultDir = Join-Path $env:LOCALAPPDATA 'Programs\Claude-CN'
        if (Test-Path -LiteralPath $defaultDir) { $InstallDir = $defaultDir }
    }

    $desktop = [Environment]::GetFolderPath('Desktop')
    if ($desktop) {
        $shortcut = Join-Path $desktop 'Claude Desktop CN.lnk'
        if (Test-Path -LiteralPath $shortcut) {
            Remove-Item -LiteralPath $shortcut -Force
            Write-Ok "Removed shortcut: $shortcut"
        }
    }

    if ($state -and $state.mode -eq 'Msix') {
        if ($state.msixInstalledByUs -eq $true) {
            $packages = Get-AppxPackage -Name 'Claude' -ErrorAction SilentlyContinue
            foreach ($package in @($packages)) {
                if ($package) {
                    Remove-AppxPackage -Package $package.PackageFullName `
                        -ErrorAction Stop
                    Write-Ok "Removed MSIX package: $($package.Version)"
                }
            }
        } else {
            Write-Host '  MSIX was already installed before this kit; leaving it in place.' `
                -ForegroundColor DarkGray
        }
    }

    if ($InstallDir -and (Test-Path -LiteralPath $InstallDir)) {
        $appDir = Join-Path $InstallDir 'app'
        if (Test-Path -LiteralPath $appDir) {
            Remove-Item -LiteralPath $appDir -Recurse -Force
            Write-Ok "Removed portable app: $appDir"
        }
        $launcher = Join-Path $InstallDir 'Launch-Claude.vbs'
        if (Test-Path -LiteralPath $launcher) {
            Remove-Item -LiteralPath $launcher -Force
        }

        $deleteData = $PurgeData
        if (-not $deleteData -and -not $NonInteractive) {
            $answer = Read-Host '  同时删除便携版聊天数据 data\ ? [y/N]'
            if ($answer -match '^[Yy]') { $deleteData = $true }
        }
        if ($deleteData) {
            $dataDir = Join-Path $InstallDir 'data'
            if (Test-Path -LiteralPath $dataDir) {
                Remove-Item -LiteralPath $dataDir -Recurse -Force
                Write-Ok "Removed portable data: $dataDir"
            }
        }

        $remaining = @(Get-ChildItem -LiteralPath $InstallDir -Force `
            -ErrorAction SilentlyContinue)
        if ($remaining.Count -eq 0) {
            Remove-Item -LiteralPath $InstallDir -Recurse -Force `
                -ErrorAction SilentlyContinue
        }
    }

    Restore-Policy
    Write-Ok 'Restored the previous HKCU 3P policy values.'

    if ($PurgeData) {
        foreach ($path in @(
            (Join-Path $env:LOCALAPPDATA 'Claude-3p')
            (Join-Path $env:APPDATA 'Claude-3p')
        )) {
            if (Test-Path -LiteralPath $path) {
                Remove-Item -LiteralPath $path -Recurse -Force
                Write-Ok "Removed app data: $path"
            }
        }
    }

    Remove-Item -LiteralPath $script:StateFile -Force `
        -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $script:StateDir 'cache') -Recurse `
        -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $script:StateDir 'claude.ico') -Force `
        -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $script:PolicyBackup -Force `
        -ErrorAction SilentlyContinue
    $remaining = @(Get-ChildItem -LiteralPath $script:StateDir -Force `
        -ErrorAction SilentlyContinue)
    if ($remaining.Count -eq 0) {
        Remove-Item -LiteralPath $script:StateDir -Recurse -Force `
            -ErrorAction SilentlyContinue
    }

    Write-Host ''
    Write-Host '  卸载完成。' -ForegroundColor Green
} catch {
    Write-Host ''
    Write-Fail $_.Exception.Message
    if (-not $NonInteractive) {
        Read-Host '  按 Enter 退出' | Out-Null
    }
    exit 1
}

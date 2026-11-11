#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Portable', 'Msix')]
    [string]$Mode = 'Portable',

    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\Claude-CN'),

    [string]$MsixPath = '',
    [string]$BaseUrl = '',
    [string]$ApiKey = '',
    [string]$AuthScheme = '',
    [string]$Models = '',

    [switch]$SkipHashCheck,
    [switch]$NonInteractive,
    [switch]$NoShortcut,
    [switch]$NoLaunch
)

. (Join-Path $PSScriptRoot 'lib\Common.ps1')

Initialize-Console
$transcript = $false
try {
    Start-Transcript -Path (Join-Path $PSScriptRoot 'install.log') -Append |
        Out-Null
    $transcript = $true
} catch {
}

try {
    Assert-Windows

    Write-Host ''
    Write-Host '  Claude Desktop CN - Windows installer' -ForegroundColor White
    Write-Host "  Official MSIX $($script:MsixVersion) + third-party inference" `
        -ForegroundColor DarkGray
    Write-Host ''

    if (-not (Test-VcRedist)) {
        Write-Warn ('未检测到 VC++ 2015-2022 x64 Redistributable。' +
            '如果启动时报缺少 vcruntime140.dll，请安装：' +
            'https://aka.ms/vs/17/release/vc_redist.x64.exe')
    }

    if (-not $PSBoundParameters.ContainsKey('Mode')) {
        if ($NonInteractive) {
            $Mode = 'Portable'
        } else {
            Write-Host '  1) 便携版  - 无需管理员，解压即用；Chat / Code，Cowork 不可用'
            Write-Host '  2) MSIX 版 - 官方包安装；支持 Cowork（需要 Hyper-V / 虚拟机平台）'
            $answer = Read-Host '  选择 [1/2]（默认 1）'
            if ($answer -eq '2') { $Mode = 'Msix' } else { $Mode = 'Portable' }
        }
    }

    if ($Mode -eq 'Portable') {
        if (-not $PSBoundParameters.ContainsKey('InstallDir') -and
            -not $NonInteractive) {
            $answer = Read-Host "  安装目录 [$InstallDir]"
            if ($answer) { $InstallDir = $answer }
        }
    } else {
        $InstallDir = ''
        if (Test-IsAdmin) {
            Write-Warn ('当前是管理员身份。MSIX 会安装到管理员账户；' +
                '建议用普通用户运行安装器。')
        }
    }

    $msix = Resolve-Msix -Path $MsixPath -SkipHashCheck:$SkipHashCheck
    $settings = Resolve-GatewaySettings -BaseUrl $BaseUrl -ApiKey $ApiKey `
        -AuthScheme $AuthScheme -Models $Models -NonInteractive:$NonInteractive

    $previousState = Read-InstallState
    $msixInstalledByUs = $false
    if ($previousState -and $previousState.msixInstalledByUs -eq $true) {
        $msixInstalledByUs = $true
    }

    if ($Mode -eq 'Msix') {
        $beforePackage = Get-AppxPackage -Name 'Claude' `
            -ErrorAction SilentlyContinue | Select-Object -First 1
        Install-MsixPackage -Msix $msix | Out-Null
        if (-not $beforePackage) { $msixInstalledByUs = $true }
    } else {
        Install-Portable -Msix $msix -InstallDir $InstallDir
    }

    Backup-Policy
    Write-GatewayPolicy -Settings $settings

    Save-InstallState -Mode $Mode -InstallDir $InstallDir `
        -MsixInstalledByUs $msixInstalledByUs

    if (-not $NoShortcut) {
        $icon = Copy-AppIcon -InstallDir $InstallDir -Msix $msix
        if ($Mode -eq 'Msix') {
            New-DesktopShortcut `
                -Target (Join-Path $env:SystemRoot 'explorer.exe') `
                -Arguments "shell:AppsFolder\$($script:PackageFamily)!$($script:PackageAppId)" `
                -IconPath $icon
        } else {
            New-DesktopShortcut `
                -Target (Join-Path $env:SystemRoot 'System32\wscript.exe') `
                -Arguments "`"$(Join-Path $InstallDir 'Launch-Claude.vbs')`"" `
                -WorkingDirectory $InstallDir `
                -IconPath $icon
        }
    }

    Test-Installation -Mode $Mode -InstallDir $InstallDir

    Write-Host ''
    Write-Host '  安装完成。' -ForegroundColor Green
    if ($Mode -eq 'Portable') {
        Write-Host "  程序: $(Join-Path $InstallDir 'app\claude.exe')" `
            -ForegroundColor DarkGray
        Write-Host "  数据: $(Join-Path $InstallDir 'data')" `
            -ForegroundColor DarkGray
        Write-Host '  Cowork 在便携版中不可用；需要 Cowork 请用 MSIX 版。' `
            -ForegroundColor Yellow
    } else {
        Write-Host '  已注册官方 MSIX。Cowork 需要 Hyper-V / 虚拟机平台。' `
            -ForegroundColor DarkGray
    }
    Write-Host '  3P 配置写入 HKCU\SOFTWARE\Policies\Claude。' `
        -ForegroundColor DarkGray
    Write-Host '  修改网关后运行 Set-Gateway.bat，然后重启 Claude。' `
        -ForegroundColor DarkGray

    if (-not $NoLaunch -and -not $NonInteractive) {
        Write-Host ''
        $answer = Read-Host '  现在启动 Claude? [Y/n]'
        if (-not $answer -or $answer -match '^[Yy]') {
            Start-Claude -Mode $Mode -InstallDir $InstallDir
        }
    }
} catch {
    Write-Host ''
    Write-Fail $_.Exception.Message
    if ($_.ScriptStackTrace) {
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    }
    if (-not $NonInteractive) {
        Write-Host ''
        Read-Host '  按 Enter 退出' | Out-Null
    }
    exit 1
} finally {
    if ($transcript) {
        try { Stop-Transcript | Out-Null } catch {}
    }
}

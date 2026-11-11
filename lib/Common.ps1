#Requires -Version 5.1
# Shared helpers for the Windows installer. Keep this file ASCII-safe except
# for user-facing strings; Windows PowerShell 5.1 needs a UTF-8 BOM to read
# them correctly.

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

$script:ProductName = 'Claude Desktop CN'
$script:MsixVersion = '5.1231.2'
$script:MsixUrl = 'https://downloads.claude.ai/releases/win32/x64/5.1231.2/Claude-26912242b6649f3e503e012d9b7b9367d09c68e4.msix'
$script:MsixSha256 = '49FBF2FC335A2CC19BBC8C7D22016F5EFFD5FB3D90F3F0EE60F5A912961AC97B'
$script:MsixSize = 297627772
$script:MsixMirrorUrl = 'https://github.com/Wangnov/claude-app-mirror/releases/download/claude-app-v5.1231.2/Claude-win-x64.msix'
$script:MsixMirrorProxyUrl = 'https://gh-proxy.com/https://github.com/Wangnov/claude-app-mirror/releases/download/claude-app-v5.1231.2/Claude-win-x64.msix'
$script:VmBundleSha = '072b6cbfe74f428a98bd86035f83b322b369d1f1'
$script:VmBundleFiles = @(
    @{
        Name = 'rootfs.vhdx.zst'
        Size = 1309889215
        Sha256 = 'c480f8a62d0d9be20e1a1ee31b9f25c73097f793127dcefa90b0c59ada0e12ad'
    }
    @{
        Name = 'vmlinuz.zst'
        Size = 14758684
        Sha256 = '3118616ef6ba3866652284b8b4c224a96876c56091724c35c93caf1ccb9b50a9'
    }
    @{
        Name = 'initrd.zst'
        Size = 28024101
        Sha256 = 'e3c5ce2b8e9e9adf67de7ec83cafa4a0c65fab8a22036a6b53f03c9765b3342a'
    }
)
$script:PackageFamily = 'Claude_pzs8sxrjxfjjc'
$script:PackageAppId = 'Claude'
$script:PolicyPath = 'HKCU:\SOFTWARE\Policies\Claude'
$script:StateDir = Join-Path $env:LOCALAPPDATA 'Claude-CN'
$script:StateFile = Join-Path $script:StateDir 'install.json'
$script:PolicyBackup = Join-Path $script:StateDir 'policy-backup.json'
$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:PolicyKeys = @(
    'inferenceProvider'
    'inferenceGatewayBaseUrl'
    'inferenceGatewayApiKey'
    'inferenceGatewayAuthScheme'
    'inferenceModels'
    'disableDeploymentModeChooser'
    'desktopHome'
    'disableAutoUpdates'
    'disableNonessentialTelemetry'
    'disableEssentialTelemetry'
)

function Initialize-Console {
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $script:OutputEncoding = [System.Text.Encoding]::UTF8
    } catch {
    }
}

function Write-Step {
    param([string]$Message)
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "  [OK] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "  [!!] $Message" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Message)
    Write-Host "  [XX] $Message" -ForegroundColor Red
}

function Assert-Windows {
    if ([Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
        throw 'This installer only runs on Windows.'
    }
    if (-not [Environment]::Is64BitOperatingSystem) {
        throw 'A 64-bit Windows installation is required.'
    }
}

function Test-IsAdmin {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Test-VcRedist {
    try {
        $key = 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64'
        return ((Get-ItemProperty -Path $key -ErrorAction Stop).Installed -eq 1)
    } catch {
        return $false
    }
}

function Get-MsixCachePath {
    return Join-Path $script:StateDir (
        "cache\Claude-$($script:MsixVersion)-x64.msix")
}

function Get-Sha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Assert-MsixFile {
    param(
        [string]$Path,
        [switch]$SkipHashCheck,
        [switch]$SkipSizeCheck
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "MSIX not found: $Path"
    }

    if (-not $SkipSizeCheck) {
        $size = (Get-Item -LiteralPath $Path).Length
        if ($size -ne $script:MsixSize) {
            throw ("MSIX size mismatch. Expected $($script:MsixSize) bytes, " +
                "got $size. Download the file again.")
        }
    }

    if ($SkipHashCheck) {
        Write-Warn 'Size and SHA-256 checks skipped by request.'
        return
    }

    $actual = Get-Sha256 -Path $Path
    if ($actual -ne $script:MsixSha256) {
        throw ("MSIX SHA-256 mismatch.`n  expected: $($script:MsixSha256)`n" +
            "  actual:   $actual`n" +
            'Anthropic may have replaced the file at this URL. Re-download it, ' +
            'or pass -SkipHashCheck -MsixPath only if you trust the file.')
    }
    Write-Ok "SHA-256 verified: $actual"
}

function Resolve-Msix {
    param(
        [string]$Path = '',
        [switch]$SkipHashCheck
    )

    if ($Path) {
        $full = (Resolve-Path -LiteralPath $Path).Path
        Write-Step "Checking local MSIX: $full"
        Assert-MsixFile -Path $full -SkipHashCheck:$SkipHashCheck `
            -SkipSizeCheck:$SkipHashCheck
        return $full
    }

    $searchDirs = @($script:RepoRoot)
    if ($env:USERPROFILE) {
        $searchDirs += (Join-Path $env:USERPROFILE 'Downloads')
        $searchDirs += (Join-Path $env:USERPROFILE '下载')
        $desktop = [Environment]::GetFolderPath('Desktop')
        if ($desktop) { $searchDirs += $desktop }
    }
    $candidates = @()
    foreach ($dir in $searchDirs) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        $candidates += @(Get-ChildItem -LiteralPath $dir -Filter 'Claude*.msix' `
            -File -ErrorAction SilentlyContinue)
    }
    foreach ($candidate in @($candidates | Sort-Object LastWriteTime -Descending)) {
        if ($candidate.Length -ne $script:MsixSize) { continue }
        try {
            Write-Step "Using local MSIX: $($candidate.FullName)"
            Assert-MsixFile -Path $candidate.FullName
            return $candidate.FullName
        } catch {
            Write-Warn $_.Exception.Message
        }
    }

    $cache = Get-MsixCachePath
    if (Test-Path -LiteralPath $cache) {
        try {
            Write-Step 'Checking cached MSIX'
            Assert-MsixFile -Path $cache
            return $cache
        } catch {
            Write-Warn $_.Exception.Message
            Remove-Item -LiteralPath $cache -Force -ErrorAction SilentlyContinue
        }
    }

    New-Item -ItemType Directory -Path (Split-Path -Parent $cache) -Force |
        Out-Null

    $sources = @(
        $script:MsixMirrorProxyUrl
        $script:MsixMirrorUrl
        $script:MsixUrl
    )
    foreach ($source in $sources) {
        Remove-Item -LiteralPath $cache -Force -ErrorAction SilentlyContinue
        Write-Step "Downloading MSIX $($script:MsixVersion)"
        Write-Host "  $source" -ForegroundColor DarkGray
        try {
            $downloaded = $false
            try {
                Import-Module BitsTransfer -ErrorAction Stop
                Start-BitsTransfer -Source $source -Destination $cache `
                    -DisplayName 'Claude Desktop CN' `
                    -Description "Claude Desktop $($script:MsixVersion) MSIX"
                $downloaded = $true
            } catch {
                Write-Warn 'BITS is unavailable; using a plain HTTP download.'
            }

            if (-not $downloaded) {
                [System.Net.ServicePointManager]::SecurityProtocol =
                    [System.Net.SecurityProtocolType]::Tls12
                $client = New-Object System.Net.WebClient
                $client.Headers.Add('User-Agent',
                    "Claude-Desktop-CN/$($script:MsixVersion)")
                $client.DownloadFile($source, $cache)
            }

            Assert-MsixFile -Path $cache
            return $cache
        } catch {
            Write-Warn "Source failed: $($_.Exception.Message)"
            Remove-Item -LiteralPath $cache -Force -ErrorAction SilentlyContinue
        }
    }

    throw ("All MSIX download sources failed.`n" +
        "  $($script:MsixMirrorProxyUrl)`n" +
        "  $($script:MsixMirrorUrl)`n" +
        "  $($script:MsixUrl)`n" +
        'Download the MSIX manually and pass -MsixPath.')
}

function Read-ClaudeSettings {
    $result = @{
        BaseUrl = ''
        ApiKey = ''
        AuthScheme = ''
        Models = @()
    }

    $paths = @(
        (Join-Path $env:USERPROFILE '.claude\settings.json')
        (Join-Path $env:USERPROFILE '.claude\settings.local.json')
    )
    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        try {
            $json = Get-Content -LiteralPath $path -Raw -Encoding UTF8 |
                ConvertFrom-Json
            $envBlock = $json.env
            if ($null -eq $envBlock) { continue }
            if ($envBlock.ANTHROPIC_BASE_URL) {
                $result.BaseUrl = [string]$envBlock.ANTHROPIC_BASE_URL
            }
            if ($envBlock.ANTHROPIC_AUTH_TOKEN) {
                $result.ApiKey = [string]$envBlock.ANTHROPIC_AUTH_TOKEN
                $result.AuthScheme = 'bearer'
            } elseif ($envBlock.ANTHROPIC_API_KEY) {
                $result.ApiKey = [string]$envBlock.ANTHROPIC_API_KEY
                $result.AuthScheme = 'x-api-key'
            }
            foreach ($name in @(
                'ANTHROPIC_DEFAULT_OPUS_MODEL'
                'ANTHROPIC_DEFAULT_SONNET_MODEL'
                'ANTHROPIC_DEFAULT_HAIKU_MODEL'
            )) {
                $value = $envBlock.$name
                if ($value -and ($result.Models -notcontains [string]$value)) {
                    $result.Models += [string]$value
                }
            }
        } catch {
            Write-Warn "Could not read $path; ignoring it."
        }
    }

    if (-not $result.BaseUrl) {
        $result.BaseUrl = [string]$env:ANTHROPIC_BASE_URL
    }
    if (-not $result.ApiKey -and $env:ANTHROPIC_AUTH_TOKEN) {
        $result.ApiKey = [string]$env:ANTHROPIC_AUTH_TOKEN
        $result.AuthScheme = 'bearer'
    }
    if (-not $result.ApiKey -and $env:ANTHROPIC_API_KEY) {
        $result.ApiKey = [string]$env:ANTHROPIC_API_KEY
        $result.AuthScheme = 'x-api-key'
    }
    foreach ($name in @(
        'ANTHROPIC_DEFAULT_OPUS_MODEL'
        'ANTHROPIC_DEFAULT_SONNET_MODEL'
        'ANTHROPIC_DEFAULT_HAIKU_MODEL'
    )) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($value -and ($result.Models -notcontains $value)) {
            $result.Models += $value
        }
    }

    return $result
}

function Resolve-GatewaySettings {
    param(
        [string]$BaseUrl = '',
        [string]$ApiKey = '',
        [string]$AuthScheme = '',
        [string]$Models = '',
        [switch]$NonInteractive
    )

    $existing = Read-ClaudeSettings
    if (-not $BaseUrl) { $BaseUrl = $existing.BaseUrl }
    if (-not $ApiKey) { $ApiKey = $existing.ApiKey }
    if (-not $AuthScheme) { $AuthScheme = $existing.AuthScheme }
    if (-not $AuthScheme) { $AuthScheme = 'bearer' }

    $modelList = @()
    if ($Models) {
        $modelList = @($Models.Split(',') |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ })
    } elseif (@($existing.Models).Count -gt 0) {
        $modelList = @($existing.Models)
    }

    if (-not $BaseUrl -or -not $ApiKey) {
        if ($NonInteractive) {
            throw 'Missing -BaseUrl or -ApiKey in non-interactive mode.'
        }
        Write-Host ''
        Write-Host '需要填写 Anthropic Messages API 网关信息。' -ForegroundColor Cyan
        Write-Host '地址填根地址，不要带 /v1/messages；例如 cc-switch 的 http://127.0.0.1:3000。' -ForegroundColor DarkGray
        if (-not $BaseUrl) {
            $answer = Read-Host '网关根地址'
            if ($answer) { $BaseUrl = $answer }
        }
        if (-not $ApiKey) {
            $answer = Read-Host 'API Key / Auth Token'
            if ($answer) { $ApiKey = $answer }
        }
        if (-not $Models -and @($existing.Models).Count -eq 0) {
            $answer = Read-Host '模型 ID（逗号分隔，可留空自动发现）'
            if ($answer) {
                $modelList = @($answer.Split(',') |
                    ForEach-Object { $_.Trim() } |
                    Where-Object { $_ })
            }
        }
    }

    if (-not $BaseUrl) { throw 'A gateway base URL is required.' }
    if (-not $ApiKey) { throw 'A gateway API key is required.' }

    $uri = $null
    if (-not [Uri]::TryCreate($BaseUrl, [UriKind]::Absolute, [ref]$uri)) {
        throw "Invalid gateway URL: $BaseUrl"
    }
    if ($uri.Scheme -ne 'http' -and $uri.Scheme -ne 'https') {
        throw "Gateway URL must use http or https: $BaseUrl"
    }
    if ($BaseUrl -match '/v1/?$') {
        Write-Warn 'URL ends with /v1. The app appends /v1/messages itself; use the root URL unless your gateway needs this prefix.'
    }
    if ($AuthScheme -ne 'bearer' -and $AuthScheme -ne 'x-api-key') {
        throw "Unknown auth scheme: $AuthScheme (use bearer or x-api-key)."
    }

    return @{
        BaseUrl = $BaseUrl.TrimEnd('/')
        ApiKey = $ApiKey
        AuthScheme = $AuthScheme
        Models = @($modelList)
    }
}

function Backup-Policy {
    New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null
    if (Test-Path -LiteralPath $script:PolicyBackup) { return }

    $values = @{}
    $props = Get-ItemProperty -Path $script:PolicyPath -ErrorAction SilentlyContinue
    if ($props) {
        foreach ($key in $script:PolicyKeys) {
            if ($props.PSObject.Properties.Name -contains $key) {
                $values[$key] = [string]$props.$key
            }
        }
    }

    $payload = [ordered]@{
        timestamp = (Get-Date).ToString('o')
        values = $values
    }
    $payload | ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath $script:PolicyBackup -Encoding UTF8
}

function ConvertTo-JsonStringArray {
    param([string[]]$Items)
    $escaped = @()
    foreach ($item in $Items) {
        $escaped += '"' + $item.Replace('\', '\\').Replace('"', '\"') + '"'
    }
    return '[' + ($escaped -join ',') + ']'
}

function Write-GatewayPolicy {
    param([hashtable]$Settings)

    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Policies\Claude') {
        Write-Warn ('HKLM\SOFTWARE\Policies\Claude exists; machine policy ' +
            'overrides this HKCU configuration. Remove the machine policy or ' +
            'write the same values there with administrator rights.')
    }

    New-Item -Path $script:PolicyPath -Force | Out-Null
    $values = [ordered]@{
        inferenceProvider = 'gateway'
        inferenceGatewayBaseUrl = $Settings.BaseUrl
        inferenceGatewayApiKey = $Settings.ApiKey
        inferenceGatewayAuthScheme = $Settings.AuthScheme
        disableDeploymentModeChooser = 'true'
        desktopHome = 'standard'
        disableAutoUpdates = 'true'
        disableNonessentialTelemetry = 'true'
        disableEssentialTelemetry = 'true'
    }
    if ($null -ne $Settings.Models -and @($Settings.Models).Count -gt 0) {
        $values['inferenceModels'] = ConvertTo-JsonStringArray `
            -Items ([string[]]$Settings.Models)
    }

    foreach ($key in $values.Keys) {
        Set-ItemProperty -Path $script:PolicyPath -Name $key `
            -Value ([string]$values[$key]) -Type String
    }

    $check = Get-ItemProperty -Path $script:PolicyPath
    foreach ($key in $values.Keys) {
        if ([string]$check.$key -ne [string]$values[$key]) {
            throw "Policy write verification failed for $key."
        }
    }
    Write-Ok "3P policy written to $($script:PolicyPath)"
}

function Restore-Policy {
    $values = $null
    if (Test-Path -LiteralPath $script:PolicyBackup) {
        try {
            $payload = Get-Content -LiteralPath $script:PolicyBackup -Raw `
                -Encoding UTF8 | ConvertFrom-Json
            $values = $payload.values
        } catch {
            Write-Warn "Could not read policy backup: $($_.Exception.Message)"
        }
    }

    if ($values) {
        New-Item -Path $script:PolicyPath -Force | Out-Null
    }
    foreach ($key in $script:PolicyKeys) {
        if ($values -and $values.PSObject.Properties.Name -contains $key) {
            Set-ItemProperty -Path $script:PolicyPath -Name $key `
                -Value ([string]$values.$key) -Type String
        } else {
            Remove-ItemProperty -Path $script:PolicyPath -Name $key `
                -ErrorAction SilentlyContinue
        }
    }
}

function Install-Portable {
    param(
        [string]$Msix,
        [string]$InstallDir
    )

    $appDir = Join-Path $InstallDir 'app'
    $dataDir = Join-Path $InstallDir 'data'
    $tmp = Join-Path $env:TEMP ('claude-cn-' + [Guid]::NewGuid().ToString('N'))

    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        Write-Step 'Extracting the official MSIX'
        $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
        $extracted = $false
        if (Test-Path -LiteralPath $tar) {
            & $tar -xf $Msix -C $tmp 2>$null
            if ($LASTEXITCODE -eq 0 -and
                (Test-Path -LiteralPath (Join-Path $tmp 'app'))) {
                $extracted = $true
            }
        }

        if (-not $extracted) {
            Write-Warn 'tar extraction failed; retrying with .NET ZipFile.'
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zip = Join-Path $tmp 'Claude.zip'
            $unzipped = Join-Path $tmp 'unzipped'
            Copy-Item -LiteralPath $Msix -Destination $zip -Force
            New-Item -ItemType Directory -Path $unzipped -Force | Out-Null
            [IO.Compression.ZipFile]::ExtractToDirectory($zip, $unzipped)
            $src = Join-Path $unzipped 'app'
            if (-not (Test-Path -LiteralPath $src)) {
                throw 'The MSIX does not contain an app/ directory.'
            }
            Remove-Item -LiteralPath (Join-Path $tmp 'app') -Recurse -Force `
                -ErrorAction SilentlyContinue
            Move-Item -LiteralPath $src -Destination (Join-Path $tmp 'app')
            $extracted = $true
        }

        $srcApp = Join-Path $tmp 'app'
        if (-not (Test-Path -LiteralPath (Join-Path $srcApp 'claude.exe'))) {
            throw 'The MSIX does not contain app\claude.exe.'
        }
        if (-not (Test-Path -LiteralPath (Join-Path $srcApp 'resources\app.asar'))) {
            throw 'The MSIX does not contain app\resources\app.asar.'
        }

        if (Test-Path -LiteralPath $appDir) {
            Write-Step 'Replacing the previous portable app'
            try {
                Remove-Item -LiteralPath $appDir -Recurse -Force
            } catch {
                throw ('Could not remove the old app directory. ' +
                    'Quit Claude Desktop and try again.')
            }
        }
        New-Item -ItemType Directory -Path $appDir -Force | Out-Null
        Get-ChildItem -LiteralPath $srcApp -Force |
            Copy-Item -Destination $appDir -Recurse -Force
        New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
        $launcherSrc = Join-Path $script:RepoRoot 'assets\Launch-Claude.vbs'
        if (-not (Test-Path -LiteralPath $launcherSrc)) {
            throw 'assets\Launch-Claude.vbs is missing.'
        }
        Copy-Item -LiteralPath $launcherSrc `
            -Destination (Join-Path $InstallDir 'Launch-Claude.vbs') -Force
        Write-Ok "Portable app installed: $appDir"
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Install-MsixPackage {
    param([string]$Msix)

    $expected = [Version]'5.1231.2.0'
    $package = Get-AppxPackage -Name 'Claude' -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending | Select-Object -First 1
    if ($package -and $package.Version -ge $expected) {
        Write-Ok "Claude MSIX already installed: $($package.Version)"
        return $package
    }

    Write-Step 'Installing the official MSIX'
    Add-AppxPackage -Path $Msix -ErrorAction Stop
    $package = Get-AppxPackage -Name 'Claude' -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending | Select-Object -First 1
    if (-not $package) {
        throw 'Add-AppxPackage finished but the Claude package was not found.'
    }
    Write-Ok "Claude MSIX installed: $($package.Version)"
    return $package
}

function Resolve-VmBundleSource {
    param([string]$Path = '')

    if ($Path -and -not (Test-Path -LiteralPath $Path)) {
        throw "VM bundle directory not found: $Path"
    }

    $dirs = @()
    if ($Path) {
        $dirs += $Path
    } else {
        $dirs += $script:RepoRoot
        if ($env:USERPROFILE) {
            $dirs += (Join-Path $env:USERPROFILE 'Downloads')
            $dirs += (Join-Path $env:USERPROFILE '下载')
        }
    }

    foreach ($dir in $dirs) {
        if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { continue }
        $files = @{}
        $complete = $true
        foreach ($spec in $script:VmBundleFiles) {
            $file = Join-Path $dir $spec.Name
            if (-not (Test-Path -LiteralPath $file)) {
                $complete = $false
                break
            }
            if ((Get-Item -LiteralPath $file).Length -ne $spec.Size) {
                if ($Path) {
                    throw "VM bundle size mismatch: $file"
                }
                $complete = $false
                break
            }
            $files[$spec.Name] = $file
        }
        if (-not $complete) {
            if ($Path) {
                throw "VM bundle directory is incomplete: $dir"
            }
            continue
        }

        Write-Step "Verifying local VM bundle ($($script:VmBundleSha))"
        foreach ($spec in $script:VmBundleFiles) {
            $actual = Get-Sha256 -Path $files[$spec.Name]
            if ($actual -ne $spec.Sha256) {
                $message = ("VM bundle SHA-256 mismatch for $($spec.Name):`n" +
                    "  expected: $($spec.Sha256)`n  actual:   $actual")
                if ($Path) { throw $message }
                Write-Warn $message
                $complete = $false
                break
            }
            Write-Ok "$($spec.Name) verified"
        }
        if (-not $complete) { continue }
        return @{ Dir = $dir; Files = $files }
    }
    return $null
}

function Install-VmBundle {
    param([hashtable]$Bundle)

    $dest = Join-Path $env:LOCALAPPDATA 'Claude-3p\vm_bundles\claudevm.bundle'
    New-Item -ItemType Directory -Path $dest -Force | Out-Null

    $root = [IO.Path]::GetPathRoot($dest)
    if ($root) {
        try {
            $driveName = $root.TrimEnd('\').TrimEnd(':')
            $free = (Get-PSDrive -Name $driveName -ErrorAction Stop).Free
            if ($free -lt 10GB) {
                Write-Warn ("Only $([math]::Round($free / 1GB, 1)) GB free on " +
                    "$root. Cowork needs about 10 GB for the staged copy and " +
                    'the decompressed rootfs.')
            }
        } catch {
        }
    }

    foreach ($spec in $script:VmBundleFiles) {
        $src = $Bundle.Files[$spec.Name]
        $dst = Join-Path $dest $spec.Name
        if (Test-Path -LiteralPath $dst) {
            if ((Get-Item -LiteralPath $dst).Length -eq $spec.Size) {
                Write-Ok "$($spec.Name) already staged"
                continue
            }
            Remove-Item -LiteralPath $dst -Force
        }
        Write-Step ("Staging $($spec.Name) " +
            "($([math]::Round($spec.Size / 1MB, 1)) MB)")
        Copy-Item -LiteralPath $src -Destination $dst -Force
        if ((Get-Item -LiteralPath $dst).Length -ne $spec.Size) {
            throw "Copy verification failed for $($spec.Name)"
        }
        Write-Ok "$($spec.Name) staged"
    }
    Write-Ok "Cowork VM bundle staged at $dest"
}

function Copy-AppIcon {
    param(
        [string]$InstallDir = '',
        [string]$Msix = ''
    )

    New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null
    $target = Join-Path $script:StateDir 'claude.ico'
    if (Test-Path -LiteralPath $target) { return $target }

    $candidates = @(
        (Join-Path $script:RepoRoot 'assets\claude-logo.ico')
    )
    if ($InstallDir) {
        $candidates += (Join-Path $InstallDir 'app\resources\Tray-Win32.ico')
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            Copy-Item -LiteralPath $candidate -Destination $target -Force
            return $target
        }
    }

    if ($Msix) {
        $tmp = Join-Path $env:TEMP ('claude-icon-' + [Guid]::NewGuid().ToString('N'))
        try {
            $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
            if (Test-Path -LiteralPath $tar) {
                New-Item -ItemType Directory -Path $tmp -Force | Out-Null
                & $tar -xf $Msix -C $tmp 'app/resources/Tray-Win32.ico' 2>$null
                $icon = Join-Path $tmp 'app\resources\Tray-Win32.ico'
                if (Test-Path -LiteralPath $icon) {
                    Copy-Item -LiteralPath $icon -Destination $target -Force
                    return $target
                }
            }
        } finally {
            Remove-Item -LiteralPath $tmp -Recurse -Force `
                -ErrorAction SilentlyContinue
        }
    }
    return ''
}

function New-DesktopShortcut {
    param(
        [string]$Target,
        [string]$Arguments = '',
        [string]$WorkingDirectory = '',
        [string]$IconPath = ''
    )

    $desktop = [Environment]::GetFolderPath('Desktop')
    if (-not $desktop) {
        Write-Warn 'Desktop folder not found; skipping shortcut.'
        return
    }
    $path = Join-Path $desktop 'Claude Desktop CN.lnk'
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($path)
    $shortcut.TargetPath = $Target
    if ($Arguments) { $shortcut.Arguments = $Arguments }
    if ($WorkingDirectory) { $shortcut.WorkingDirectory = $WorkingDirectory }
    if ($IconPath -and (Test-Path -LiteralPath $IconPath)) {
        $shortcut.IconLocation = "$IconPath,0"
    }
    $shortcut.Save()
    Write-Ok "Desktop shortcut: $path"
}

function Save-InstallState {
    param(
        [string]$Mode,
        [string]$InstallDir,
        [bool]$MsixInstalledByUs = $false
    )

    New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null
    $state = [ordered]@{
        version = $script:MsixVersion
        mode = $Mode
        installDir = $InstallDir
        installedAt = (Get-Date).ToString('o')
        packageFamily = $script:PackageFamily
        msixInstalledByUs = $MsixInstalledByUs
    }
    $state | ConvertTo-Json -Depth 4 |
        Set-Content -LiteralPath $script:StateFile -Encoding UTF8
}

function Read-InstallState {
    if (-not (Test-Path -LiteralPath $script:StateFile)) { return $null }
    try {
        return Get-Content -LiteralPath $script:StateFile -Raw -Encoding UTF8 |
            ConvertFrom-Json
    } catch {
        return $null
    }
}

function Get-PolicyValue {
    param([string]$Name)
    try {
        $props = Get-ItemProperty -Path $script:PolicyPath -ErrorAction Stop
        if ($props.PSObject.Properties.Name -contains $Name) {
            return [string]$props.$Name
        }
    } catch {
    }
    return ''
}

function Test-Installation {
    param(
        [string]$Mode,
        [string]$InstallDir
    )

    $script:CheckFailures = 0
    function Check-Item {
        param([bool]$Condition, [string]$Message)
        if ($Condition) {
            Write-Ok $Message
        } else {
            Write-Fail $Message
            $script:CheckFailures++
        }
    }

    Write-Step 'Verifying the installation'
    if ($Mode -eq 'Msix') {
        $package = Get-AppxPackage -Name 'Claude' -ErrorAction SilentlyContinue |
            Sort-Object Version -Descending | Select-Object -First 1
        Check-Item ([bool]$package) 'Claude MSIX package is registered'
    } else {
        Check-Item (Test-Path -LiteralPath (Join-Path $InstallDir 'app\claude.exe')) `
            'app\claude.exe exists'
        Check-Item (Test-Path -LiteralPath (Join-Path $InstallDir 'app\resources\app.asar')) `
            'app\resources\app.asar exists'
        $ionAsar = Join-Path $InstallDir 'app\resources\ion-dist.asar'
        $ionDir = Join-Path $InstallDir 'app\resources\ion-dist\index.html'
        Check-Item ((Test-Path -LiteralPath $ionAsar) -or
            (Test-Path -LiteralPath $ionDir)) `
            'UI assets exist (ion-dist.asar or ion-dist/index.html)'
        Check-Item (Test-Path -LiteralPath (Join-Path $InstallDir 'data')) `
            'portable data directory exists'
        Check-Item (Test-Path -LiteralPath (Join-Path $InstallDir 'Launch-Claude.vbs')) `
            'portable launcher exists'
    }
    Check-Item ((Get-PolicyValue 'inferenceProvider') -eq 'gateway') `
        '3P policy: inferenceProvider=gateway'
    Check-Item (-not [string]::IsNullOrWhiteSpace(
        (Get-PolicyValue 'inferenceGatewayBaseUrl'))) `
        '3P policy: gateway URL is set'
    Check-Item (-not [string]::IsNullOrWhiteSpace(
        (Get-PolicyValue 'inferenceGatewayApiKey'))) `
        '3P policy: gateway credential is set'
    Check-Item ((Get-PolicyValue 'disableDeploymentModeChooser') -eq 'true') `
        '3P policy: Claude.ai sign-in chooser is disabled'

    if ($script:CheckFailures -gt 0) {
        throw "$($script:CheckFailures) installation check(s) failed."
    }
}

function Start-Claude {
    param(
        [string]$Mode,
        [string]$InstallDir
    )

    if ($Mode -eq 'Msix') {
        Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') `
            -ArgumentList "shell:AppsFolder\$($script:PackageFamily)!$($script:PackageAppId)"
        return
    }

    $exe = Join-Path $InstallDir 'app\claude.exe'
    $data = Join-Path $InstallDir 'data'
    $env:CLAUDE_USER_DATA_DIR = $data
    Start-Process -FilePath $exe `
        -ArgumentList "--user-data-dir=`"$data`"" `
        -WorkingDirectory (Join-Path $InstallDir 'app')
}

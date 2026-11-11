#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$BaseUrl = '',
    [string]$ApiKey = '',
    [string]$AuthScheme = '',
    [string]$Models = '',
    [switch]$NonInteractive
)

. (Join-Path $PSScriptRoot 'lib\Common.ps1')

Initialize-Console
try {
    Assert-Windows
    Write-Host ''
    Write-Host '  Claude Desktop CN - refresh 3P gateway settings' `
        -ForegroundColor White
    Write-Host ''

    $settings = Resolve-GatewaySettings -BaseUrl $BaseUrl -ApiKey $ApiKey `
        -AuthScheme $AuthScheme -Models $Models -NonInteractive:$NonInteractive

    Backup-Policy
    Write-GatewayPolicy -Settings $settings

    Write-Host ''
    Write-Ok '网关配置已更新。'
    Write-Host '  完全退出并重新打开 Claude Desktop 后生效。' `
        -ForegroundColor DarkGray
} catch {
    Write-Host ''
    Write-Fail $_.Exception.Message
    if (-not $NonInteractive) {
        Read-Host '  按 Enter 退出' | Out-Null
    }
    exit 1
}

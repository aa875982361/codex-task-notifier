$ErrorActionPreference = "Stop"

$webhookUrl = [string] $env:CODEX_NOTIFY_WEBHOOK_URL
if ([string]::IsNullOrWhiteSpace($webhookUrl)) {
    $configPath = Join-Path ([Environment]::GetFolderPath("UserProfile")) ".codex\codex-task-notifier.url"
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { exit 0 }
    $webhookUrl = (Get-Content -LiteralPath $configPath -Raw -Encoding UTF8).Trim()
}
if ([string]::IsNullOrWhiteSpace($webhookUrl) -or $webhookUrl.TrimEnd("/").EndsWith("/private")) { exit 0 }

$agentPath = Join-Path $PSScriptRoot "start_agent.ps1"
$logDirectory = Join-Path ([Environment]::GetFolderPath("UserProfile")) ".codex\logs"
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
$logPath = Join-Path $logDirectory "codex-task-notifier-agent.log"
$comSpec = if ([string]::IsNullOrWhiteSpace($env:ComSpec)) { "cmd.exe" } else { $env:ComSpec }
$escapedAgentPath = $agentPath.Replace('"', '""')
$escapedLogPath = $logPath.Replace('"', '""')
$start = New-Object Diagnostics.ProcessStartInfo
$start.FileName = $comSpec
$start.Arguments = "/d /s /c `"powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"`"$escapedAgentPath`"`" >> `"`"$escapedLogPath`"`" 2>&1`""
$start.UseShellExecute = $true
$start.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
[Diagnostics.Process]::Start($start) | Out-Null

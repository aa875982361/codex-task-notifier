param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string] $WebhookUrl
)

$ErrorActionPreference = "Stop"
$uri = $null
if (-not [Uri]::TryCreate($WebhookUrl, [UriKind]::Absolute, [ref] $uri) -or $uri.Scheme -notin @("http", "https")) {
    throw "webhook URL must be an absolute http:// or https:// URL"
}

$configDirectory = Join-Path ([Environment]::GetFolderPath("UserProfile")) ".codex"
$configPath = Join-Path $configDirectory "codex-task-notifier.url"
New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
$utf8WithoutBom = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText($configPath, $WebhookUrl.Trim() + [Environment]::NewLine, $utf8WithoutBom)
Write-Output "Webhook URL saved to $configPath"

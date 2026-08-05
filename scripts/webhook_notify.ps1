$ErrorActionPreference = "Stop"

$pluginName = "codex-task-notifier"
$eventData = $null

function Write-HookResult {
    [Console]::Out.WriteLine('{"continue":true}')
}

function Read-Utf8StandardInput {
    # Console.In uses the active Windows console code page in Windows PowerShell
    # 5.1. Codex writes UTF-8 JSON bytes, so decoding through Console.In can turn
    # Chinese and other non-ASCII task results into mojibake before transmission.
    $stream = [Console]::OpenStandardInput()
    $memory = New-Object IO.MemoryStream
    try {
        $buffer = New-Object byte[] 8192
        while (($count = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $memory.Write($buffer, 0, $count)
        }
        $utf8 = New-Object Text.UTF8Encoding($false, $true)
        $text = $utf8.GetString($memory.ToArray())
        if ($text.Length -gt 0 -and $text[0] -eq [char] 0xFEFF) {
            return $text.Substring(1)
        }
        return $text
    }
    finally {
        $memory.Dispose()
    }
}

function Test-WebhookUrl([string] $Value) {
    $uri = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref] $uri)) {
        throw "webhook URL must be an absolute http:// or https:// URL"
    }
    if ($uri.Scheme -notin @("http", "https")) {
        throw "webhook URL must be an absolute http:// or https:// URL"
    }
    return $Value
}

function Get-ConfiguredUrl {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_NOTIFY_WEBHOOK_URL)) {
        return Test-WebhookUrl $env:CODEX_NOTIFY_WEBHOOK_URL.Trim()
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_NOTIFY_URL_FILE)) {
        $candidates.Add($env:CODEX_NOTIFY_URL_FILE.Trim())
    }
    if (-not [string]::IsNullOrWhiteSpace($env:PLUGIN_DATA)) {
        $candidates.Add((Join-Path $env:PLUGIN_DATA "webhook.url"))
    }
    $userProfile = [Environment]::GetFolderPath("UserProfile")
    $candidates.Add((Join-Path $userProfile ".codex\$pluginName.url"))

    foreach ($path in $candidates) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $value = (Get-Content -LiteralPath $path -Raw -Encoding UTF8).Trim()
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                return Test-WebhookUrl $value
            }
        }
    }
    return ""
}

function Write-DeliveryLog([string] $Status, $Event, [string] $Detail = "") {
    if ([string]::IsNullOrWhiteSpace($env:PLUGIN_DATA)) {
        return
    }
    try {
        New-Item -ItemType Directory -Path $env:PLUGIN_DATA -Force | Out-Null
        $record = [ordered]@{
            time = [DateTimeOffset]::Now.ToString("yyyy-MM-ddTHH:mm:sszzz")
            status = $Status
            session_id = $Event.session_id
            turn_id = $Event.turn_id
            detail = $Detail.Substring(0, [Math]::Min(300, $Detail.Length))
        }
        $line = $record | ConvertTo-Json -Compress
        Add-Content -LiteralPath (Join-Path $env:PLUGIN_DATA "deliveries.jsonl") -Value $line -Encoding UTF8
    }
    catch {
        # Delivery logging must never interfere with the Codex task result.
    }
}

try {
    $inputText = Read-Utf8StandardInput
    $eventData = $inputText | ConvertFrom-Json
    if ($eventData.hook_event_name -ne "Stop" -or [bool] $eventData.stop_hook_active) {
        return
    }

    $url = Get-ConfiguredUrl
    if ([string]::IsNullOrWhiteSpace($url)) {
        Write-DeliveryLog "skipped" $eventData "webhook URL is not configured"
        return
    }

    if ($url.StartsWith("https://", [StringComparison]::OrdinalIgnoreCase)) {
        # Windows PowerShell 5.1 can otherwise inherit an obsolete TLS default.
        [Net.ServicePointManager]::SecurityProtocol = `
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }

    $timeout = 7
    $parsedTimeout = 0
    if ([int]::TryParse($env:CODEX_NOTIFY_TIMEOUT, [ref] $parsedTimeout) -and $parsedTimeout -gt 0) {
        $timeout = $parsedTimeout
    }
    $attempts = 2
    $parsedAttempts = 0
    if ([int]::TryParse($env:CODEX_NOTIFY_ATTEMPTS, [ref] $parsedAttempts)) {
        $attempts = [Math]::Max(1, [Math]::Min(3, $parsedAttempts))
    }

    $lastError = $null
    for ($attempt = 1; $attempt -le $attempts; $attempt++) {
        try {
            $response = Invoke-WebRequest `
                -Uri $url `
                -Method Post `
                -Body ([Text.Encoding]::UTF8.GetBytes($inputText)) `
                -ContentType "application/json; charset=utf-8" `
                -Headers @{ Accept = "application/json"; "X-Codex-Event" = "codex.task.completed"; "X-Codex-Payload" = "hook-input" } `
                -UserAgent "$pluginName/0.1.0" `
                -TimeoutSec $timeout `
                -UseBasicParsing
            $statusCode = [int] $response.StatusCode
            if ($statusCode -lt 200 -or $statusCode -ge 300) {
                throw "webhook returned HTTP $statusCode"
            }
            Write-DeliveryLog "sent" $eventData "HTTP $statusCode"
            return
        }
        catch {
            $lastError = $_.Exception.Message
            if ($attempt -lt $attempts) {
                Start-Sleep -Milliseconds 500
            }
        }
    }
    throw "delivery failed after $attempts attempt(s): $lastError"
}
catch {
    $message = $_.Exception.Message
    Write-DeliveryLog "failed" $eventData $message
    [Console]::Error.WriteLine("Codex task notification failed: $message")
}
finally {
    Write-HookResult
}

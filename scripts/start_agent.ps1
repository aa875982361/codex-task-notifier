$ErrorActionPreference = "Stop"
$agentVersion = "0.1.0"

function Get-WebhookUrl {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_NOTIFY_WEBHOOK_URL)) { return $env:CODEX_NOTIFY_WEBHOOK_URL.Trim() }
    $path = Join-Path ([Environment]::GetFolderPath("UserProfile")) ".codex\codex-task-notifier.url"
    if (Test-Path -LiteralPath $path -PathType Leaf) { return (Get-Content -LiteralPath $path -Raw -Encoding UTF8).Trim() }
    throw "请先配置 codex-task-notifier Webhook URL"
}

function Get-AgentConfig([string] $WebhookUrl) {
    $uri = [Uri] $WebhookUrl
    $match = [Regex]::Match($uri.AbsolutePath, "^(.*)/hooks/codex/([^/]+)(?:/private)?/?$")
    if (-not $match.Success) { throw "Webhook URL 不包含 /hooks/codex/<token>" }
    return @{
        Base = "$($uri.Scheme)://$($uri.Authority)$($match.Groups[1].Value)/agent"
        Token = $match.Groups[2].Value
    }
}

function Invoke-AgentRequest([string] $Url, [string] $Token, $Payload) {
    $body = $Payload | ConvertTo-Json -Compress
    try {
        return Invoke-WebRequest -Uri $Url -Method Post -Headers @{ Authorization = "Bearer $Token" } `
            -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType "application/json; charset=utf-8" `
            -UserAgent "codex-hook-agent/$agentVersion" -UseBasicParsing -TimeoutSec 15
    }
    catch {
        $response = $_.Exception.Response
        if ($response -and [int] $response.StatusCode -eq 403) { throw "此配置未启用远程操作" }
        throw
    }
}

function Invoke-CodexJob($Config, $Job) {
    if ([string]::IsNullOrWhiteSpace([string] $Job.session_id) -or [string] $Job.session_id -notmatch '^[A-Za-z0-9._:-]+$') {
        throw "无效的 Codex 会话 ID"
    }
    if (-not (Test-Path -LiteralPath ([string] $Job.cwd) -PathType Container)) { throw "原任务工作目录不存在" }
    $codex = Get-Command codex -ErrorAction Stop
    $outputPath = Join-Path ([IO.Path]::GetTempPath()) ("codex-hook-agent-" + [Guid]::NewGuid().ToString("N") + ".txt")
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $codex.Source
    $escapedOutput = $outputPath.Replace('"', '\"')
    $start.Arguments = "exec resume $($Job.session_id) - --output-last-message `"$escapedOutput`""
    $start.WorkingDirectory = [string] $Job.cwd
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.EnvironmentVariables["CODEX_REMOTE_RESUME_REQUEST_ID"] = [string] $Job.id
    $start.EnvironmentVariables["CODEX_REMOTE_SOURCE_TASK_ID"] = [string] $Job.source_task_id
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw "无法启动 Codex CLI" }
        $process.StandardInput.Write([string] $Job.prompt)
        $process.StandardInput.Close()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw "Codex 退出码：$($process.ExitCode)" }
    }
    finally {
        $process.Dispose()
        Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue
    }
}

$config = Get-AgentConfig (Get-WebhookUrl)
$codexVersion = try { (& codex --version 2>&1 | Out-String).Trim() } catch { "unavailable" }
$metadata = @{ platform = "windows"; agent_version = $agentVersion; codex_version = $codexVersion }
Write-Host "Codex Hook Agent 已启动。关闭此窗口即可停止远程操作。"

while ($true) {
    try {
        Invoke-AgentRequest "$($config.Base)/heartbeat" $config.Token $metadata | Out-Null
        $response = Invoke-AgentRequest "$($config.Base)/jobs/claim" $config.Token $metadata
        if ([int] $response.StatusCode -eq 200 -and -not [string]::IsNullOrWhiteSpace($response.Content)) {
            $job = ($response.Content | ConvertFrom-Json).job
            if ($job) {
                Write-Host "正在执行请求 $($job.id)…"
                try { Invoke-CodexJob $config $job }
                catch {
                    Invoke-AgentRequest "$($config.Base)/jobs/$($job.id)/failed" $config.Token @{
                        failure_code = "codex_failed"; failure_message = $_.Exception.Message
                    } | Out-Null
                }
            }
        }
        Start-Sleep -Seconds 5
    }
    catch {
        Write-Warning $_.Exception.Message
        Start-Sleep -Seconds 10
    }
}

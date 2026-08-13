$ErrorActionPreference = "Stop"
$agentVersion = "0.1.0"

$instanceMutex = New-Object Threading.Mutex($false, "Local\CodexTaskNotifierAgent")
$ownsMutex = $false
try {
    try { $ownsMutex = $instanceMutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
    if (-not $ownsMutex) { exit 0 }

function Get-WebhookUrl {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_NOTIFY_WEBHOOK_URL)) { return $env:CODEX_NOTIFY_WEBHOOK_URL.Trim() }
    $path = Join-Path ([Environment]::GetFolderPath("UserProfile")) ".codex\codex-task-notifier.url"
    if (Test-Path -LiteralPath $path -PathType Leaf) { return (Get-Content -LiteralPath $path -Raw -Encoding UTF8).Trim() }
    throw "Configure the codex-task-notifier Webhook URL before starting the agent"
}

function Get-AgentConfig([string] $WebhookUrl) {
    $uri = [Uri] $WebhookUrl
    $match = [Regex]::Match($uri.AbsolutePath, "^(.*)/hooks/codex/([^/]+)(?:/private)?/?$")
    if (-not $match.Success) { throw "Webhook URL must contain /hooks/codex/<token>" }
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
        if ($response -and [int] $response.StatusCode -eq 403) {
            $error = New-Object InvalidOperationException("Remote control is not enabled for this configuration")
            $error.Data["RemoteControlDisabled"] = $true
            throw $error
        }
        throw
    }
}

function New-CodexStartInfo([string] $Arguments) {
    $codex = Get-Command codex -All -ErrorAction Stop |
        Where-Object { $_.CommandType -in @("Application", "ExternalScript") } |
        Select-Object -First 1
    if (-not $codex) { throw "Codex CLI executable was not found" }

    $source = [string] $codex.Source
    $extension = [IO.Path]::GetExtension($source).ToLowerInvariant()
    $start = New-Object Diagnostics.ProcessStartInfo
    if ($extension -in @(".cmd", ".bat")) {
        $start.FileName = if ([string]::IsNullOrWhiteSpace($env:ComSpec)) { "cmd.exe" } else { $env:ComSpec }
        $start.Arguments = "/d /s /c `"`"$source`" $Arguments`""
    }
    elseif ($extension -eq ".ps1") {
        $start.FileName = "powershell.exe"
        $start.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$source`" $Arguments"
    }
    else {
        $start.FileName = $source
        $start.Arguments = $Arguments
    }
    return $start
}

function Invoke-CodexJob($Config, $Job) {
    if ([string]::IsNullOrWhiteSpace([string] $Job.session_id) -or [string] $Job.session_id -notmatch '^[A-Za-z0-9._:-]+$') {
        throw "Invalid Codex session ID"
    }
    if (-not (Test-Path -LiteralPath ([string] $Job.cwd) -PathType Container)) { throw "The original task working directory does not exist" }
    $outputPath = Join-Path ([IO.Path]::GetTempPath()) ("codex-hook-agent-" + [Guid]::NewGuid().ToString("N") + ".txt")
    $escapedOutput = $outputPath.Replace('"', '\"')
    $start = New-CodexStartInfo "exec resume $($Job.session_id) - --output-last-message `"$escapedOutput`""
    $start.WorkingDirectory = [string] $Job.cwd
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.EnvironmentVariables["CODEX_REMOTE_RESUME_REQUEST_ID"] = [string] $Job.id
    $start.EnvironmentVariables["CODEX_REMOTE_SOURCE_TASK_ID"] = [string] $Job.source_task_id
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw "Unable to start Codex CLI" }
        # Write UTF-8 bytes directly for Windows PowerShell 5.1 compatibility.
        # Its .NET Framework may not expose ProcessStartInfo.StandardInputEncoding.
        $promptBytes = (New-Object Text.UTF8Encoding($false)).GetBytes([string] $Job.prompt)
        $inputStream = $process.StandardInput.BaseStream
        $inputStream.Write($promptBytes, 0, $promptBytes.Length)
        $inputStream.Close()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw "Codex exited with code $($process.ExitCode)" }
    }
    finally {
        $process.Dispose()
        Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue
    }
}

$config = Get-AgentConfig (Get-WebhookUrl)
$codexVersion = try { (& codex --version 2>&1 | Out-String).Trim() } catch { "unavailable" }
$metadata = @{ platform = "windows"; agent_version = $agentVersion; codex_version = $codexVersion }
Write-Host "Codex Hook Agent started. Close this window to stop remote operations."

    while ($true) {
        try {
            Invoke-AgentRequest "$($config.Base)/heartbeat" $config.Token $metadata | Out-Null
            $response = Invoke-AgentRequest "$($config.Base)/jobs/claim" $config.Token $metadata
            if ([int] $response.StatusCode -eq 200 -and -not [string]::IsNullOrWhiteSpace($response.Content)) {
                $job = ($response.Content | ConvertFrom-Json).job
                if ($job) {
                    Write-Host "Running request $($job.id)..."
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
            if ($_.Exception.Data["RemoteControlDisabled"] -eq $true) {
                Write-Warning "Remote control permission is disabled. Codex Hook Agent stopped."
                break
            }
            Write-Warning $_.Exception.Message
            Start-Sleep -Seconds 10
        }
    }
}
finally {
    if ($ownsMutex) { $instanceMutex.ReleaseMutex() }
    $instanceMutex.Dispose()
}

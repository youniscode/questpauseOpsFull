[CmdletBinding()]
param(
    [int]$StaleMinutes = 3,
    [int]$AlertCooldownMinutes = 15
)

# Bootstrap: resolve QuestPauseOps root paths from env.ps1
$__qpEnv = $null
foreach ($__qpRel in @('..\env.ps1', '..\..\env.ps1', '..\..\..\env.ps1')) {
    $__qpTest = Join-Path $PSScriptRoot $__qpRel
    if (Test-Path $__qpTest) { $__qpEnv = $__qpTest; break }
}
if (-not $__qpEnv) { throw "env.ps1 not found from $PSScriptRoot" }
. $__qpEnv
Remove-Variable __qpEnv, __qpRel, __qpTest -ErrorAction SilentlyContinue

[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$PSDefaultParameterValues['*:Encoding'] = 'utf8'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$OpsRoot   = $script:QPRoot
$StateRoot = Join-Path $OpsRoot 'state'
$ConfigPath = Join-Path $OpsRoot 'config\servers.json'
$LogsDir   = Join-Path $OpsRoot 'logs\status'
$AlertStateFile = Join-Path $StateRoot 'presence_heartbeat_alerts.json'

if (-not (Test-Path $LogsDir)) { New-Item -ItemType Directory -Path $LogsDir -Force | Out-Null }

function Write-Log([string]$Msg) {
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    "$ts  $Msg" | Add-Content -Path (Join-Path $LogsDir 'presence_heartbeat_monitor.log') -Encoding UTF8
    Write-Host $Msg
}

$cfg = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

# Get display name for a server key
function Get-ServerDisplayName([string]$Key, $Config) {
    if ($Config.servers.$Key.displayName) { return [string]$Config.servers.$Key.displayName }
    return $Key
}

# Get webhook URL for a server key
function Get-ServerWebhook([string]$Key, $Config) {
    if ($Config.servers.$Key.webhooks.status) { return [string]$Config.servers.$Key.webhooks.status }
    if ($Config.servers.$Key.webhooks.admin)  { return [string]$Config.servers.$Key.webhooks.admin }
    return $null
}

# Load alert cooldown state
$alerts = @{}
if (Test-Path $AlertStateFile) {
    try { $alerts = Get-Content $AlertStateFile -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable } catch {}
}

$now = [DateTime]::UtcNow
$staleThreshold = $now.AddMinutes(-$StaleMinutes)
$cooldownThreshold = $now.AddMinutes(-$AlertCooldownMinutes)
$staleServers = @()

# Scan state directories for presence heartbeat files
$stateDirs = Get-ChildItem -Path $StateRoot -Directory
foreach ($dir in $stateDirs) {
    $serverKey = $dir.Name
    $heartbeatFile = Join-Path $dir.FullName 'presence_heartbeat.txt'

    if (-not (Test-Path $heartbeatFile)) {
        if ($cfg.servers.$serverKey -and $cfg.servers.$serverKey.enabled -eq $true) {
            $staleServers += @{ Key = $serverKey; Reason = "no heartbeat file" }
        }
        continue
    }

    $heartbeatContent = Get-Content $heartbeatFile -Raw -Encoding UTF8
    $heartbeatTime = $null
    if (-not [DateTime]::TryParse($heartbeatContent, [ref]$heartbeatTime)) {
        $staleServers += @{ Key = $serverKey; Reason = "unparseable heartbeat timestamp" }
        continue
    }

    if ($heartbeatTime -lt $staleThreshold) {
        $minutesAgo = [math]::Round(($now - $heartbeatTime).TotalMinutes, 1)
        $staleServers += @{ Key = $serverKey; Reason = "last heartbeat $minutesAgo min ago" }
    }
}

$alerted = @()
foreach ($stale in $staleServers) {
    $key = $stale.Key
    $lastAlert = $null
    if ($alerts.ContainsKey($key)) { $lastAlert = [DateTime]$alerts[$key] }

    # Skip if we recently alerted
    if ($lastAlert -and $lastAlert -gt $cooldownThreshold) {
        Write-Log "SKIP $key (alerted recently at $($lastAlert.ToString('o')))"
        continue
    }

    $display = Get-ServerDisplayName $key $cfg
    $webhook = Get-ServerWebhook $key $cfg

    Write-Log "ALERT $key ($display) -- $($stale.Reason)"

    if ($webhook) {
        $payload = [ordered]@{
            embeds = @(
                [ordered]@{
                    title       = "[!] Presence Script Stale"
                    description = "The presence poller for **$display** (`$key`) has stopped."
                    color       = 0xE74C3C
                    fields      = @(
                        @{ name = "Server"; value = "$display (`$key`)"; inline = $true }
                        @{ name = "Reason"; value = $stale.Reason; inline = $true }
                        @{ name = "Time (UTC)"; value = $now.ToString('yyyy-MM-dd HH:mm:ss'); inline = $false }
                        @{ name = "Action"; value = "Check scheduled task for `$key`. Restart the presence script or reboot the server."; inline = $false }
                    )
                    footer = @{ text = "QUESTPAUSE - Presence Heartbeat Monitor" }
                    timestamp = $now.ToString('o')
                }
            )
        }

        try {
            $json = $payload | ConvertTo-Json -Depth 16
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
            Invoke-DiscordApiWithRetry -Method POST -Uri "$webhook?wait=true" -Body $bytes -ContentType 'application/json; charset=utf-8' | Out-Null
            Write-Log "Alert posted to Discord for $key"
        } catch {
            Write-Log ("Failed to post Discord alert for {0}: {1}" -f $key, $_.Exception.Message)
        }
    } else {
                Write-Log "No webhook configured for $key -- skipping Discord alert"
    }

    $alerts[$key] = $now.ToString('o')
    $alerted += $key
}

# Save alert state
$alerts | ConvertTo-Json | Set-Content -Path $AlertStateFile -Encoding UTF8

if ($alerted.Count -eq 0) { Write-Log "All presence heartbeats OK ($($stateDirs.Count) servers checked)" }

[CmdletBinding()]
param(
    [string]$ServerKey = "minecraft_survival",
    [switch]$RunOnce,
    [int]$PollSeconds = 60,
    [int]$DebugPulseMinutes = 5,
    [int]$MinPulseGapSeconds = 0
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
[Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
$PSDefaultParameterValues['*:Encoding'] = 'utf8'

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$ServerName = "QUESTPAUSE Minecraft Survival"
$ServerVersion = "Paper 1.21.10"
$MaxPlayers = 25

$OpsRoot = $script:QPRoot
$StateDir = Join-Path $OpsRoot "state\$ServerKey"
$LogsDir = Join-Path $OpsRoot "logs\status"

$StateFile = Join-Path $StateDir "mc_status_state.json"
$LastIdFile = Join-Path $StateDir "mc_last_message_id.txt"
$DebugLog = Join-Path $LogsDir "${ServerKey}_status.log"

$ConfigPath = "$script:QPConfigRoot\servers.json"
$WebhookUrl = $env:WEBHOOK_MC_STATUS

if (Test-Path $ConfigPath) {
    try {
        $cfg = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($cfg.servers.minecraft_survival.webhooks.status) {
            $WebhookUrl = $cfg.servers.minecraft_survival.webhooks.status
        }
    }
    catch {
        Write-Host "Could not read status webhook from servers.json, falling back to env var."
    }
}

function Ensure-Dir([string]$Path) {
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

Ensure-Dir $StateDir
Ensure-Dir $LogsDir

function Write-DebugLine([string]$Line) {
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    "$ts  $Line" | Add-Content -Path $DebugLog -Encoding UTF8
}

function Normalize-Webhook([string]$w) {
    if ([string]::IsNullOrWhiteSpace($w)) { return "" }
    $w = $w -replace '[\u200B-\u200F\u202A-\u202E\u2060\uFEFF]', ''
    $w = $w -replace '\s', ''
    return $w.Trim().TrimEnd('/')
}

$WebhookUrl = Normalize-Webhook $WebhookUrl

if ([string]::IsNullOrWhiteSpace($WebhookUrl)) {
    throw "WEBHOOK_MC_STATUS is not set."
}

if ($WebhookUrl -notmatch '^https://(canary\.|ptb\.)?discord\.com/api/webhooks/\d+/[^/]+$') {
    throw "Webhook format invalid."
}

$WebhookPostUri = [Uri]("${WebhookUrl}?wait=true")

function Get-WebhookParts([string]$webhookBase) {
    if ($webhookBase -match '^https://(canary\.|ptb\.)?discord\.com/api/webhooks/(?<id>\d+)/(?<token>[^/]+)$') {
        return @{ id = $Matches['id']; token = $Matches['token'] }
    }
    throw "Webhook format unexpected."
}

$WebhookParts = Get-WebhookParts $WebhookUrl

function EditUrl([string]$msgId) {
    "https://discord.com/api/webhooks/$($WebhookParts.id)/$($WebhookParts.token)/messages/$msgId"
}

function SendJsonUTF8([string]$method, [Uri]$uri, [hashtable]$payload) {
    $json = $payload | ConvertTo-Json -Depth 16
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)

    Invoke-DiscordApiWithRetry -Method $method -Uri $uri -Body $bytes -ContentType 'application/json; charset=utf-8'
}

function SendOrEdit([hashtable]$payload) {
    $msgId = ""

    if (Test-Path $LastIdFile) {
        try { $msgId = (Get-Content $LastIdFile -Raw -Encoding UTF8).Trim() } catch { $msgId = "" }
    }

    if ($msgId) {
        try {
            $editUri = [Uri](EditUrl $msgId)
            $r = SendJsonUTF8 -method "PATCH" -uri $editUri -payload $payload
            return $r.id
        }
        catch {
            Write-DebugLine "PATCH failed, posting new message: $($_.Exception.Message)"
            Remove-Item $LastIdFile -Force -ErrorAction SilentlyContinue
        }
    }

    $r = SendJsonUTF8 -method "POST" -uri $WebhookPostUri -payload $payload

    if (-not $r -or -not $r.id) {
        throw "Webhook POST did not return a message id."
    }

    return $r.id
}

function Test-MinecraftOnline {
    try {
        $tcp = Get-NetTCPConnection -LocalPort 25565 -State Listen -ErrorAction SilentlyContinue |
        Select-Object -First 1

        if ($tcp) { return $true }

        $proc = Get-CimInstance Win32_Process -Filter "Name='java.exe'" |
        Where-Object {
            $_.CommandLine -like "*paper.jar*" -or
            $_.CommandLine -like "*minecraft_server*" -or
            $_.CommandLine -like "*org.bukkit.craftbukkit.Main*"
        } |
        Select-Object -First 1

        return [bool]$proc
    }
    catch {
        return $false
    }
}

function Get-HostRamLine {
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $totalGB = [math]::Round(($os.TotalVisibleMemorySize * 1KB) / 1GB, 1)
        $freeGB = [math]::Round(($os.FreePhysicalMemory * 1KB) / 1GB, 1)
        $usedGB = [math]::Round($totalGB - $freeGB, 1)
        $pct = if ($totalGB -gt 0) { [math]::Round(($usedGB / $totalGB) * 100, 0) } else { 0 }
        return "$usedGB/$totalGB GB RAM ($pct%)"
    }
    catch {
        return "RAM unknown"
    }
}

function Get-MinecraftProcessHealthLine {
    param([bool]$online)

    if (-not $online) { return "Pending uplink" }

    try {
        $tcp = Get-NetTCPConnection -LocalPort 25565 -State Listen -ErrorAction SilentlyContinue |
        Select-Object -First 1

        if ($tcp -and $tcp.OwningProcess) {
            $p = Get-Process -Id $tcp.OwningProcess -ErrorAction Stop
            $ramGB = [math]::Round($p.WorkingSet64 / 1GB, 1)
            return "PID $($p.Id) | RAM ${ramGB} GB"
        }

        return "Online"
    }
    catch {
        return "Online"
    }
}

function Build-Payload {
    param(
        [bool]$online
    )

    $color = if ($online) { 0x2ECC71 } else { 0xE74C3C }

    $headline = if ($online) {
        "🟢 Uplink Online **Minecraft Survival** (Joinable)"
    }
    else {
        "🔴 Uplink Offline **Minecraft Survival** (Not Joinable)"
    }

    $flavor = if ($online) {
        "Signal locked. World persists."
    }
    else {
        "Radio silence. Server process not detected."
    }

    $directive = if ($online) {
        "Directive: **Survive / Build / Explore** the world persists."
    }
    else {
        "Directive: **Hold position** server offline or maintenance in progress."
    }

    $joinabilityLine = if ($online) { "✅ Joinable" } else { "⛔ Not joinable" }
    $uplinkLine = if ($online) { "🟢 Systems green" } else { "🔴 No uplink" }
    $healthLine = Get-MinecraftProcessHealthLine -online $online
    $hostRam = Get-HostRamLine
    $pulseUtc = (Get-Date).ToUniversalTime().ToString("HH:mm")
    $lastChangeUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm") + " UTC"

    $desc = @(
        $headline,
        "",
        $flavor,
        "",
        $directive,
        "Times in **UTC**."
    ) -join "`n"

    return [ordered]@{
        content          = ""
        embeds           = @(
            [ordered]@{
                title       = "MC Server Status"
                description = $desc
                color       = $color
                fields      = @(
                    @{ name = "🧭 World"; value = $ServerName; inline = $false },
                    @{ name = "🧩 ServerKey"; value = $ServerKey; inline = $true },
                    @{ name = "👥 Slots"; value = "$MaxPlayers max"; inline = $true },
                    @{ name = "🚦 Joinability"; value = $joinabilityLine; inline = $true },
                    @{ name = "🧱 Version"; value = $ServerVersion; inline = $true },
                    @{ name = "🖥️ Host Load"; value = $hostRam; inline = $true },
                    @{ name = "🛰️ Uplink"; value = $uplinkLine; inline = $true },
                    @{ name = "🛠️ Server Health"; value = $healthLine; inline = $false },
                    @{ name = "Last change (UTC)"; value = $lastChangeUtc; inline = $false }
                )
                footer      = @{ text = "QUESTPAUSE • Minecraft • $ServerKey • Pulse $pulseUtc UTC" }
                timestamp   = (Get-Date).ToUniversalTime().ToString("o")
            }
        )
        allowed_mentions = @{ parse = @() }
    }
}

$online = Test-MinecraftOnline
$payload = Build-Payload -online $online

$id = SendOrEdit $payload
if ($id) {
    Set-Content -Path $LastIdFile -Value $id -Encoding UTF8
}

Set-Content -Path $StateFile -Value (($payload | ConvertTo-Json -Depth 16)) -Encoding UTF8

Write-DebugLine "MC status updated. online=$online msgId=$id"
Write-Host "$ServerName status checked: $(if ($online) { 'ONLINE' } else { 'OFFLINE' })"

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$ServerKey,

  [switch]$RunOnce,

  [int]$PollSeconds = 15,
  [int]$OfflineAfterSeconds = 5,
  [int]$DebugPulseMinutes = 1,
  [int]$MinPulseGapSeconds = 0,

  # Optional overrides
  [string]$WebhookUrl = '',
  [string]$WorldName = '',
  [int]$GamePort = 0,
  [int]$QueryPort = 0,
  [int]$MaxPlayers = 0,
  [string]$MaintenanceFlagPath = '',
  [string]$ProcessName = '',
  [string]$ExePath = ''
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

<#
  C:\QuestPauseOps\scripts\status\windrose_server_status.ps1
  QUESTPAUSEOPS — Windrose Live Status

  What it does:
  - Loads C:\QuestPauseOps\config\servers.json
  - Uses -ServerKey to target ONE Windrose server
  - Stores per-server state in C:\QuestPauseOps\state\<ServerKey>\
  - Stores debug logs in C:\QuestPauseOps\logs\status\
  - Posts once then PATCH edits same Discord message forever
  - Supports RunOnce mode or watcher mode

  QuestPauseOps conventions:
  - Per-server state separation
  - Config-driven process / ports / world / webhook / max players
#>

# =========================
# UTF-8 / PowerShell 5.1 safe
# =========================
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
[Console]::InputEncoding  = New-Object System.Text.UTF8Encoding($false)
$PSDefaultParameterValues['*:Encoding'] = 'utf8'

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# =========================
# ROOT / PATHS
# =========================
$OpsRoot    = $script:QPRoot
$ConfigPath = Join-Path $OpsRoot 'config\servers.json'
$LibPath    = Join-Path $OpsRoot 'lib\QuestPause.Ops.psm1'
$LogsDir    = Join-Path $OpsRoot 'logs\status'
$StateDir   = Join-Path $OpsRoot ("state\" + $ServerKey)

$StateFile  = Join-Path $StateDir 'windrose_status_state.json'
$DebugLog   = Join-Path $LogsDir  ("{0}_windrose_server_status.log" -f $ServerKey)
$LastIdFile = Join-Path $StateDir 'windrose_last_message_id.txt'

function Ensure-Dir([string]$Path) {
  if (-not (Test-Path $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

Ensure-Dir $LogsDir
Ensure-Dir $StateDir

function Write-DebugLine([string]$Line) {
  Ensure-Dir $LogsDir
  Ensure-Dir $StateDir
  $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  "$ts  $Line" | Add-Content -Path $DebugLog -Encoding UTF8
}

# =========================
# OPTIONAL MODULE IMPORT
# =========================
if (Test-Path $LibPath) {
  try {
    Import-Module $LibPath -Force -ErrorAction Stop
    Write-DebugLine "Imported module: $LibPath"
  } catch {
    Write-DebugLine "Module import failed: $($_.Exception.Message)"
  }
}

# =========================
# LOAD CONFIG
# =========================
if (-not (Test-Path $ConfigPath)) {
  throw "servers.json not found: $ConfigPath"
}

try {
  $cfgText = Get-Content $ConfigPath -Raw -Encoding UTF8
  $cfg = $cfgText | ConvertFrom-Json
} catch {
  throw "Failed to parse servers.json: $($_.Exception.Message)"
}

$server = $null
if ($cfg.servers.PSObject.Properties.Name -contains $ServerKey) {
  $server = $cfg.servers.$ServerKey
}
if (-not $server) {
  throw "ServerKey '$ServerKey' not found under servers.* in $ConfigPath"
}

# =========================
# RESOLVE CONFIG VALUES
# =========================
function Get-FirstValue {
  param($Primary, $Fallback)
  if ($null -ne $Primary -and "$Primary".Trim() -ne '') { return $Primary }
  return $Fallback
}

$WorldNameFallback = 'Windrose World'
if ($server.worldName) {
  $WorldNameFallback = $server.worldName
} elseif ($server.displayName) {
  $WorldNameFallback = $server.displayName
}
$ResolvedWorldName = Get-FirstValue $WorldName $WorldNameFallback

if ($MaxPlayers -gt 0) {
  $ResolvedMaxPlayers = $MaxPlayers
} elseif ($server.maxPlayers) {
  $ResolvedMaxPlayers = [int]$server.maxPlayers
} else {
  $ResolvedMaxPlayers = 4
}

if ($GamePort -gt 0) {
  $ResolvedGamePort = $GamePort
} elseif ($server.gamePort) {
  $ResolvedGamePort = [int]$server.gamePort
} elseif ($server.port) {
  $ResolvedGamePort = [int]$server.port
} else {
  $ResolvedGamePort = 7777
}

if ($QueryPort -gt 0) {
  $ResolvedQueryPort = $QueryPort
} elseif ($server.queryPort) {
  $ResolvedQueryPort = [int]$server.queryPort
} else {
  $ResolvedQueryPort = 27015
}

$MaintenanceFlagFallback = Join-Path $StateDir 'maintenance.on'
if ($server.maintenanceFlagPath) {
  $MaintenanceFlagFallback = $server.maintenanceFlagPath
}
$ResolvedMaintenanceFlagPath = Get-FirstValue $MaintenanceFlagPath $MaintenanceFlagFallback

$ProcessNameFallback = 'WindroseServer-Win64-Shipping'
if ($server.processName) {
  $ProcessNameFallback = $server.processName
}
$ResolvedProcessName = Get-FirstValue $ProcessName $ProcessNameFallback

$ExePathFallback = ''
if ($server.exePath) {
  $ExePathFallback = $server.exePath
}
$ResolvedExePath = Get-FirstValue $ExePath $ExePathFallback

$WebhookFallback = ''
if ($server.PSObject.Properties['webhooks'] -and $server.webhooks -and $server.webhooks.PSObject.Properties['status']) {
  $WebhookFallback = $server.webhooks.status
} elseif ($server.webhookUrl) {
  $WebhookFallback = $server.webhookUrl
}
$ResolvedWebhookUrl = Get-FirstValue $WebhookUrl $WebhookFallback

if ([string]::IsNullOrWhiteSpace($ResolvedWebhookUrl)) {
  throw "No webhook found for $ServerKey. Add servers.$ServerKey.webhooks.status or pass -WebhookUrl."
}

$ExpectedUdpPorts = @()
if ($ResolvedGamePort -gt 0)  { $ExpectedUdpPorts += $ResolvedGamePort }
if ($ResolvedQueryPort -gt 0) { $ExpectedUdpPorts += $ResolvedQueryPort }
$ExpectedUdpPorts = @($ExpectedUdpPorts | Sort-Object -Unique)

Write-DebugLine "Resolved config for $ServerKey"
Write-DebugLine "ConfigPath=$ConfigPath"
Write-DebugLine "WorldName=$ResolvedWorldName"
Write-DebugLine "GamePort=$ResolvedGamePort QueryPort=$ResolvedQueryPort MaxPlayers=$ResolvedMaxPlayers"
Write-DebugLine "ProcessName=$ResolvedProcessName"
Write-DebugLine "ExePath=$ResolvedExePath"
Write-DebugLine "MaintenanceFlagPath=$ResolvedMaintenanceFlagPath"

# =========================
# FLAVORS
# =========================
$OnlineFlavors = @(
  "Sea lanes open. Crew may deploy.",
  "Wind is favorable. The world is reachable.",
  "Harbor stable. Ready for boarding.",
  "Server currents steady. Sail on.",
  "All core systems green. Set course."
)

$OfflineFlavors = @(
  "No signal from the harbor. Stand by.",
  "Sea is dark. Server not responding.",
  "The world is out of range right now.",
  "No heartbeat detected from Windrose.",
  "Contact lost. Await further orders."
)

$MaintenanceFlavors = @(
  "Dockyard maintenance underway.",
  "Shipyard locked for tuning and checks.",
  "Controlled downtime in progress.",
  "Harbor crew is making adjustments.",
  "Repairs underway. Reopening soon."
)

# =========================
# HELPERS
# =========================
function Normalize-Webhook([string]$w) {
  if ([string]::IsNullOrWhiteSpace($w)) { return "" }
  $w = $w -replace '[\u200B-\u200F\u202A-\u202E\u2060\uFEFF]',''
  $w = $w -replace '[“”„‟]','"'
  $w = $w -replace "[‘’‚‛]","'"
  $w = $w -replace '\s',''
  $w = $w.Trim().TrimEnd('/')
  $w = -join ($w.ToCharArray() | Where-Object { [int]$_ -ge 32 -and [int]$_ -le 126 })
  return $w
}

function Ensure-Prop([object]$obj, [string]$name, $defaultValue) {
  if ($null -eq $obj.PSObject.Properties[$name]) {
    $obj | Add-Member -NotePropertyName $name -NotePropertyValue $defaultValue -Force
  }
}

function Load-State {
  $s = $null
  if (Test-Path $StateFile) {
    try { $s = Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $s = $null }
  }
  if (-not $s) { $s = [pscustomobject]@{} }

  Ensure-Prop $s 'online' $false
  Ensure-Prop $s 'maintenance' $false
  Ensure-Prop $s 'last_seen_online_utc' $null
  Ensure-Prop $s 'online_since_utc' $null
  Ensure-Prop $s 'last_state_change_utc' $null
  Ensure-Prop $s 'last_debug_pulse_utc' $null
  Ensure-Prop $s 'last_any_pulse_utc' $null

  return $s
}

function Save-State($s) {
  ($s | ConvertTo-Json -Depth 10) | Set-Content -Path $StateFile -Encoding UTF8
}

function Try-ParseUtc([string]$iso) {
  if ([string]::IsNullOrWhiteSpace($iso)) { return $null }
  try { return ([DateTime]::Parse($iso)).ToUniversalTime() } catch { return $null }
}

function UtcNowObj { (Get-Date).ToUniversalTime() }

function Format-Duration([TimeSpan]$ts) {
  if ($ts.TotalSeconds -lt 0) { return '0m' }
  if ($ts.TotalHours -ge 24)  { return "{0}d {1}h" -f [int]$ts.TotalDays, $ts.Hours }
  if ($ts.TotalHours -ge 1)   { return "{0}h {1}m" -f [int]$ts.TotalHours, $ts.Minutes }
  return "{0}m" -f [int]$ts.TotalMinutes
}

function Is-MaintenanceOn {
  Test-Path $ResolvedMaintenanceFlagPath
}

function Pick-FlavorByMode([string]$mode) {
  switch ($mode) {
    'maintenance' { return $MaintenanceFlavors | Get-Random }
    'online'      { return $OnlineFlavors | Get-Random }
    default       { return $OfflineFlavors | Get-Random }
  }
}

function Has-Command([string]$name) {
  try { return [bool](Get-Command $name -ErrorAction Stop) } catch { return $false }
}

# =========================
# WEBHOOK SETUP
# =========================
$ResolvedWebhookUrl = Normalize-Webhook $ResolvedWebhookUrl

if ($ResolvedWebhookUrl -notmatch '^https://(canary\.|ptb\.)?discord\.com/api/webhooks/\d+/[^/]+$') {
  throw "Webhook format invalid for ${ServerKey}: '$ResolvedWebhookUrl'"
}

try {
  $baseUri = [Uri]$ResolvedWebhookUrl
  $ub = [System.UriBuilder]::new($baseUri)
  $ub.Query = "wait=true"
  $WebhookPostUri = $ub.Uri
  $WebhookPostUrl = $WebhookPostUri.AbsoluteUri
  Write-DebugLine "Webhook post url: $WebhookPostUrl"
} catch {
  throw "Webhook URI build failed: $($_.Exception.Message)"
}

function Get-WebhookParts([string]$webhookBase) {
  if ($webhookBase -match '^https://(canary\.|ptb\.)?discord\.com/api/webhooks/(?<id>\d+)/(?<token>[^/]+)$') {
    return @{ id = $Matches['id']; token = $Matches['token'] }
  }
  throw "Webhook format unexpected."
}
$WebhookParts = Get-WebhookParts $ResolvedWebhookUrl

function EditUrl([string]$msgId) {
  "https://discord.com/api/webhooks/$($WebhookParts.id)/$($WebhookParts.token)/messages/$msgId"
}

# =========================
# HOST / HEALTH
# =========================
function Get-HostRamLine {
  try {
    $os = Get-CimInstance Win32_OperatingSystem
    $totalGB = [math]::Round(($os.TotalVisibleMemorySize * 1KB) / 1GB, 1)
    $freeGB  = [math]::Round(($os.FreePhysicalMemory * 1KB) / 1GB, 1)
    $usedGB  = [math]::Round($totalGB - $freeGB, 1)
    $pct = if ($totalGB -gt 0) { [math]::Round(($usedGB / $totalGB) * 100, 0) } else { 0 }
    return "$usedGB/$totalGB GB RAM ($pct%)"
  } catch {
    return "RAM unknown"
  }
}

function Get-WindroseProcess {
  try {
    $procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
      $_.Name -eq $ResolvedProcessName -or $_.Name -eq ($ResolvedProcessName -replace '\.exe$','')
    })

    if ($ResolvedExePath -and $procs.Count -gt 0) {
      $normalizedExe = $ResolvedExePath.Trim().ToLowerInvariant()
      $matched = @()

      foreach ($p in $procs) {
        try {
          if ($p.Path -and $p.Path.ToLowerInvariant() -eq $normalizedExe) {
            $matched += $p
          }
        } catch {}
      }

      if ($matched.Count -gt 0) {
        return ($matched | Select-Object -First 1)
      }
    }

    if ($procs.Count -gt 0) {
      return ($procs | Select-Object -First 1)
    }

    return $null
  } catch {
    return $null
  }
}

function Get-WindroseHealthLine {
  param([bool]$online)

  if (-not $online) { return "Pending harbor uplink" }

  try {
    $p = Get-WindroseProcess
    if ($p) {
      $ramGB = [math]::Round($p.WorkingSet64 / 1GB, 1)
      return "PID $($p.Id) | RAM ${ramGB} GB"
    }

    return "Online"
  } catch {
    return "Online"
  }
}

# =========================
# ONLINE CHECK
# =========================
function Test-WindroseOnline {
  try {
    $proc = Get-WindroseProcess
    if (-not $proc) {
      Write-DebugLine "Test-WindroseOnline: process not found"
      return $false
    }

    if (Has-Command "Get-NetUDPEndpoint" -and $ExpectedUdpPorts.Count -gt 0) {
      $eps = @(Get-NetUDPEndpoint -OwningProcess $proc.Id -ErrorAction SilentlyContinue | Where-Object {
        $ExpectedUdpPorts -contains $_.LocalPort
      })

      if ($eps.Count -gt 0) {
        $present = @($eps | Select-Object -ExpandProperty LocalPort | Sort-Object -Unique)
        $allFound = $true
        foreach ($need in $ExpectedUdpPorts) {
          if ($present -notcontains $need) {
            $allFound = $false
            break
          }
        }

        if ($allFound) {
          return $true
        }

        Write-DebugLine "Test-WindroseOnline: process found but not all expected ports found. Present=$($present -join ',') Expected=$($ExpectedUdpPorts -join ',')"
      } else {
        Write-DebugLine "Test-WindroseOnline: process found but no matching UDP endpoints yet"
      }
    }

    return $true
  } catch {
    Write-DebugLine "Test-WindroseOnline error: $($_.Exception.Message)"
    return $false
  }
}

# =========================
# DISCORD SEND
# =========================
function SendJsonUTF8([string]$method, [Uri]$uri, [hashtable]$payload) {
  $json  = $payload | ConvertTo-Json -Depth 16
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)

  Invoke-DiscordApiWithRetry -Method $method -Uri $uri -Body $bytes -ContentType 'application/json; charset=utf-8'
}

function TryEditMessage([string]$msgId, [hashtable]$payload) {
  $editUri = [Uri](EditUrl $msgId)
  for ($attempt = 1; $attempt -le 2; $attempt++) {
    try {
      return (SendJsonUTF8 -method 'PATCH' -uri $editUri -payload $payload)
    } catch {
      Write-DebugLine "PATCH failed attempt $attempt for msg $msgId : $($_.Exception.Message)"
      if ($attempt -ge 2) { throw }
      Start-Sleep -Milliseconds 350
    }
  }
}

function SendOrEdit([hashtable]$payload) {
  $msgId = ''
  if (Test-Path $LastIdFile) {
    try { $msgId = (Get-Content $LastIdFile -Raw -Encoding UTF8).Trim() } catch { $msgId = '' }
  }

  if ($msgId) {
    try {
      $r = TryEditMessage -msgId $msgId -payload $payload
      return $r.id
    } catch {
      Write-DebugLine "Edit failed; falling back to POST."
      try { Remove-Item $LastIdFile -Force -ErrorAction SilentlyContinue } catch {}
    }
  }

  $r = SendJsonUTF8 -method 'POST' -uri $WebhookPostUri -payload $payload
  if (-not $r -or -not $r.id) {
    throw "Webhook POST did not return a message id."
  }
  return $r.id
}

# =========================
# PAYLOAD
# =========================
function Build-Payload {
  param(
    [bool]$online,
    [bool]$maintenance,
    [string]$mode,
    [string]$uptimeText,
    [string]$lastChangeUtc
  )

  $joinable = ($online -and -not $maintenance)

  $color = if ($joinable) { 0x2ECC71 }
           elseif ($maintenance) { 0xF1C40F }
           else { 0xE74C3C }

  $flavor = Pick-FlavorByMode -mode $mode
  $directive = if ($joinable) {
    "Directive: **Sail / Build / Explore** the world is reachable."
  } else {
    "Directive: **Hold position** maintenance / downtime in progress."
  }

  $uplinkLine = if ($joinable) { "🟢 Harbor open" } else { "🟠 Harbor restricted" }
  $joinabilityLine = if ($joinable) { "✅ Joinable" } else { "⛔ Not joinable" }
  $slotsLine = "$ResolvedMaxPlayers max"
  $hostRam = Get-HostRamLine
  $procHealth = Get-WindroseHealthLine -online $online

  $headline = if ($joinable) {
    "🟢 Uplink Online **Windrose** (Joinable)"
  } else {
    "🟠 Maintenance **Not Joinable** (Stand by)"
  }

  $pulseUtc = (Get-Date).ToUniversalTime().ToString('HH:mm')
  $footerText = "QUESTPAUSE • Windrose • $ServerKey • Pulse $pulseUtc UTC"

  $desc = @(
    $headline,
    "",
    $flavor,
    "",
    $directive,
    "Times in **UTC**."
  ) -join "`n"

  return [ordered]@{
    content = ""
    embeds = @(
      [ordered]@{
        title       = "Windrose Server Status"
        description = $desc
        color       = $color
        fields      = @(
          @{ name = "🧭 World"; value = $ResolvedWorldName; inline = $false },
          @{ name = "🧩 ServerKey"; value = $ServerKey; inline = $true },
          @{ name = "👥 Slots"; value = $slotsLine; inline = $true },
          @{ name = "🚦 Joinability"; value = $joinabilityLine; inline = $true },
          @{ name = "🕒 Uptime"; value = $uptimeText; inline = $true },
          @{ name = "🖥️ Host Load"; value = $hostRam; inline = $true },
          @{ name = "🛰️ Uplink"; value = $uplinkLine; inline = $true },
          @{ name = "🛠️ Server Health"; value = $procHealth; inline = $false },
          @{ name = "Last change (UTC)"; value = $lastChangeUtc; inline = $false }
        )
        footer    = @{ text = $footerText }
        timestamp = (Get-Date).ToUniversalTime().ToString('o')
      }
    )
    allowed_mentions = @{ parse = @() }
  }
}

# =========================
# COOLDOWN
# =========================
function Can-PostPulse([ref]$state, [DateTime]$nowUtcObj) {
  if ($MinPulseGapSeconds -le 0) { return $true }
  $lastAny = Try-ParseUtc $state.Value.last_any_pulse_utc
  if (-not $lastAny) { return $true }
  return ((($nowUtcObj - $lastAny).TotalSeconds) -ge $MinPulseGapSeconds)
}

function Mark-PulsePosted([ref]$state, [string]$nowIso) {
  $state.Value.last_any_pulse_utc = $nowIso
}

# =========================
# MAIN
# =========================
$state = Load-State
Write-DebugLine "Script start for $ServerKey. RunOnce=$($RunOnce.IsPresent)"

if ($RunOnce) {
  $nowUtcObj = UtcNowObj
  $nowIso = $nowUtcObj.ToString('o')

  $maintenanceNow = Is-MaintenanceOn
  $onlineNow = Test-WindroseOnline

  $effectiveMaintenance = $maintenanceNow
  if (-not $onlineNow) { $effectiveMaintenance = $true }

  $state.online = $onlineNow
  $state.maintenance = $effectiveMaintenance
  $state.last_state_change_utc = $nowIso
  if ($onlineNow) {
    $state.online_since_utc = $nowIso
    $state.last_seen_online_utc = $nowIso
  } else {
    $state.online_since_utc = $null
  }

  Save-State $state

  $lastChangeText = $nowUtcObj.ToString('yyyy-MM-dd HH:mm') + ' UTC'
  $mode = if ($onlineNow) { 'online' } else { 'maintenance' }
  $uptimeText = if ($onlineNow) { '0m' } else { 'Maintenance' }

  $payload = Build-Payload -online $onlineNow -maintenance $effectiveMaintenance -mode $mode -uptimeText $uptimeText -lastChangeUtc $lastChangeText
  $id = SendOrEdit $payload
  if ($id) { Set-Content -Path $LastIdFile -Value $id -Encoding UTF8 }

  Write-DebugLine "RunOnce OK. online=$onlineNow maintenance=$effectiveMaintenance msgId=$id"
  return
}

Write-Host "QuestPauseOps Windrose watcher started for $ServerKey"
Write-Host "GamePort=$ResolvedGamePort QueryPort=$ResolvedQueryPort PollSeconds=$PollSeconds"
Write-Host "ProcessName=$ResolvedProcessName"
Write-Host "StateDir=$StateDir"
Write-Host "ConfigPath=$ConfigPath"
Write-Host "DebugLog=$DebugLog"

$debugPulseSpan = [TimeSpan]::FromMinutes($DebugPulseMinutes)

try {
  $nowUtcObj = UtcNowObj
  $nowIso = $nowUtcObj.ToString('o')

  $maintenanceNow = Is-MaintenanceOn
  $targetOnline = Test-WindroseOnline

  $effectiveMaintenance = $maintenanceNow
  if (-not $targetOnline) { $effectiveMaintenance = $true }

  $mode = if ($targetOnline) { 'online' } else { 'maintenance' }
  $state.last_state_change_utc = $nowIso

  if ($targetOnline) {
    $state.online_since_utc = $nowIso
    $state.last_seen_online_utc = $nowIso
  } else {
    $state.online_since_utc = $null
  }

  $lastChangeText = $nowUtcObj.ToString('yyyy-MM-dd HH:mm') + ' UTC'
  $uptimeText = if ($targetOnline) { '0m' } else { 'Maintenance' }

  $payload = Build-Payload -online $targetOnline -maintenance $effectiveMaintenance -mode $mode -uptimeText $uptimeText -lastChangeUtc $lastChangeText
  $id = SendOrEdit $payload
  if ($id) { Set-Content -Path $LastIdFile -Value $id -Encoding UTF8 }

  $state.last_debug_pulse_utc = $nowIso
  $state.last_any_pulse_utc   = $nowIso
  $state.online = $targetOnline
  $state.maintenance = $effectiveMaintenance
  Save-State $state

  Write-DebugLine "Startup post OK. online=$targetOnline maintenance=$effectiveMaintenance msgId=$id"
} catch {
  Write-DebugLine "Startup post ERROR: $($_.Exception.Message)"
}

while ($true) {
  try {
    $nowUtcObj = UtcNowObj
    $nowIso = $nowUtcObj.ToString('o')

    $maintenanceNow = Is-MaintenanceOn
    $rawOnline = Test-WindroseOnline
    $targetOnline = $rawOnline

    if (-not $maintenanceNow) {
      if (-not $rawOnline -and $state.online -and $state.last_seen_online_utc) {
        $lastSeen = Try-ParseUtc $state.last_seen_online_utc
        if ($lastSeen) {
          $since = ($nowUtcObj - $lastSeen).TotalSeconds
          if ($since -le $OfflineAfterSeconds) { $targetOnline = $true }
        }
      }
    }

    if ($targetOnline) { $state.last_seen_online_utc = $nowIso }

    $effectiveMaintenance = $maintenanceNow
    if (-not $targetOnline) { $effectiveMaintenance = $true }

    $mode = if ($targetOnline) { 'online' } else { 'maintenance' }

    $stateChanged = ($targetOnline -ne $state.online)
    $maintChanged = ($effectiveMaintenance -ne $state.maintenance)

    if ($stateChanged -or $maintChanged -or -not $state.last_state_change_utc) {
      $state.last_state_change_utc = $nowIso
      if ($stateChanged) {
        if ($targetOnline) {
          $state.online_since_utc = $nowIso
        } else {
          $state.online_since_utc = $null
        }
      }
    }

    $dbgDue = $false
    $lastDbg = Try-ParseUtc $state.last_debug_pulse_utc
    if (-not $lastDbg) { $dbgDue = $true }
    elseif (($nowUtcObj - $lastDbg) -ge $debugPulseSpan) { $dbgDue = $true }

    $lastChange = Try-ParseUtc $state.last_state_change_utc
    if (-not $lastChange) { $lastChange = $nowUtcObj }
    $lastChangeText = $lastChange.ToString('yyyy-MM-dd HH:mm') + ' UTC'

    $uptimeText = if ($targetOnline) {
      $since = Try-ParseUtc $state.online_since_utc
      if (-not $since) { $since = Try-ParseUtc $state.last_state_change_utc }
      if ($since) { Format-Duration ($nowUtcObj - $since) } else { 'Online' }
    } else {
      'Maintenance'
    }

    if ($dbgDue -or $stateChanged -or $maintChanged) {
      $forcePost = ($stateChanged -or $maintChanged)

      if (-not $forcePost) {
        if (-not (Can-PostPulse -state ([ref]$state) -nowUtcObj $nowUtcObj)) {
          $state.online = $targetOnline
          $state.maintenance = $effectiveMaintenance
          Save-State $state
          Start-Sleep -Seconds $PollSeconds
          continue
        }
      }

      $payload = Build-Payload -online $targetOnline -maintenance $effectiveMaintenance -mode $mode -uptimeText $uptimeText -lastChangeUtc $lastChangeText
      $id = SendOrEdit $payload
      if ($id) { Set-Content -Path $LastIdFile -Value $id -Encoding UTF8 }

      $state.last_debug_pulse_utc = $nowIso
      Mark-PulsePosted -state ([ref]$state) -nowIso $nowIso
      $state.online = $targetOnline
      $state.maintenance = $effectiveMaintenance
      Save-State $state

      Write-DebugLine "Watcher updated OK. online=$targetOnline maintenance=$effectiveMaintenance msgId=$id"
    } else {
      $needsSave = $false
      if ($targetOnline -ne $state.online) { $state.online = $targetOnline; $needsSave = $true }
      if ($effectiveMaintenance -ne $state.maintenance) { $state.maintenance = $effectiveMaintenance; $needsSave = $true }
      if ($needsSave) { Save-State $state }
    }

  } catch {
    Write-DebugLine "LOOP ERROR: $($_.Exception.Message)"
    Write-Host "[LOOP ERROR] $($_.Exception.Message)" -ForegroundColor DarkYellow
  }

  Start-Sleep -Seconds $PollSeconds
}

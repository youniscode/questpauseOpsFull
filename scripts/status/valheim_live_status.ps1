[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$ServerKey,

  [switch]$RunOnce,

  [int]$PollSeconds = 5,
  [int]$OfflineAfterSeconds = 0,
  [int]$DebugPulseMinutes = 1,
  [int]$MinPulseGapSeconds = 30,

  # Optional overrides
  [string]$WebhookUrl = '',
  [string]$WorldName = '',
  [int]$GamePort = 0,
  [int]$QueryPort = 0,
  [int]$MaxPlayers = 0,
  [string]$MaintenanceFlagPath = '',
  [int]$DailySummaryHourUtc = 9,
  [bool]$EnableDailySummary = $true
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
  C:\QuestPauseOps\scripts\status\valheim_live_status.ps1
  QUESTPAUSEOPS — Valheim Live Status

  What it does:
  - Loads C:\QuestPauseOps\config\servers.json
  - Uses -ServerKey to target ONE Valheim server
  - Stores per-server state in C:\QuestPauseOps\state\<ServerKey>\
  - Stores debug logs in C:\QuestPauseOps\logs\status\
  - Posts once then PATCH edits same Discord message forever
  - Supports RunOnce mode or watcher mode

  QuestPauseOps conventions:
  - Per-server state separation
  - No hardcoded C:\valheim_panel paths
  - Config-driven ports / world / webhook / max players
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

$StateFile  = Join-Path $StateDir 'valheim_status_state.json'
$DebugLog   = Join-Path $LogsDir  ("{0}_valheim_live_status.log" -f $ServerKey)
$LastIdFile = Join-Path $StateDir 'valheim_last_message_id.txt'

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

if ($server.product -and $server.product -ne 'valheim') {
  Write-DebugLine "Warning: server.product is '$($server.product)' for $ServerKey"
}

# =========================
# RESOLVE CONFIG VALUES
# =========================
function Get-FirstValue {
  param(
    $Primary,
    $Fallback
  )
  if ($null -ne $Primary -and "$Primary".Trim() -ne '') { return $Primary }
  return $Fallback
}

$WorldNameFallback = 'Valheim Realm'
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
  $ResolvedMaxPlayers = 30
}

if ($GamePort -gt 0) {
  $ResolvedGamePort = $GamePort
} elseif ($server.gamePort) {
  $ResolvedGamePort = [int]$server.gamePort
} elseif ($server.port) {
  $ResolvedGamePort = [int]$server.port
} else {
  $ResolvedGamePort = 0
}

if ($QueryPort -gt 0) {
  $ResolvedQueryPort = $QueryPort
} elseif ($server.queryPort) {
  $ResolvedQueryPort = [int]$server.queryPort
} else {
  $ResolvedQueryPort = 0
}

$MaintenanceFlagFallback = Join-Path $StateDir 'maintenance.on'
if ($server.maintenanceFlagPath) {
  $MaintenanceFlagFallback = $server.maintenanceFlagPath
}
$ResolvedMaintenanceFlagPath = Get-FirstValue $MaintenanceFlagPath $MaintenanceFlagFallback

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

if ($ResolvedGamePort -le 0) {
  throw "GamePort missing for $ServerKey. Resolved GamePort=$ResolvedGamePort"
}

$ExpectedUdpPorts = @($ResolvedGamePort)
if ($ResolvedQueryPort -gt 0) { $ExpectedUdpPorts += $ResolvedQueryPort }

Write-DebugLine "Resolved config for $ServerKey"
Write-DebugLine "ConfigPath=$ConfigPath"
Write-DebugLine "WorldName=$ResolvedWorldName"
Write-DebugLine "GamePort=$ResolvedGamePort QueryPort=$ResolvedQueryPort MaxPlayers=$ResolvedMaxPlayers"
Write-DebugLine "MaintenanceFlagPath=$ResolvedMaintenanceFlagPath"

# =========================
# FLAVORS
# =========================
$OnlineFlavors = @(
  "Yggdrasil hums. The realm link holds.",
  "Fires burn steady. The world persists.",
  "The veil is thin paths are open.",
  "Skies calm. Safe to venture and build.",
  "Rune-signal locked. Realm stands ready."
)

$OfflineFlavors = @(
  "Signal lost. The realm is unreachable.",
  "The gate is quiet. No response from the far shore.",
  "The link fades. Stand by, Viking.",
  "Storm in the void. Realm connection down.",
  "No heartbeat. Waiting for the realm to awaken."
)

$MaintenanceFlavors = @(
  "Maintenance active. Tending the realm.",
  "Hammer time. Updates and fixes underway.",
  "Tuning the realm link. Back soon.",
  "Testing runes. Reopening shortly.",
  "Controlled downtime. The world returns stronger."
)

# =========================
# HELPERS
# =========================
function Normalize-Webhook([string]$w) {
  if ([string]::IsNullOrWhiteSpace($w)) { return "" }
  $w = ($w -replace '\s','') -replace '[\u200B-\u200D\uFEFF]',''
  return $w.TrimEnd('/')
}

function Ensure-Prop([object]$obj, [string]$name, $defaultValue) {
  if ($null -eq $obj.PSObject.Properties[$name]) {
    $obj | Add-Member -NotePropertyName $name -NotePropertyValue $defaultValue -Force
  }
}

function Load-State {
  $s = $null
  if (Test-Path $StateFile) {
    try { $s = (Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { $s = $null }
  }
  if (-not $s) { $s = [pscustomobject]@{} }

  Ensure-Prop $s 'online' $false
  Ensure-Prop $s 'maintenance' $false
  Ensure-Prop $s 'last_seen_online_utc' $null
  Ensure-Prop $s 'online_since_utc' $null
  Ensure-Prop $s 'last_state_change_utc' $null
  Ensure-Prop $s 'restart_count' 0
  Ensure-Prop $s 'last_debug_pulse_utc' $null
  Ensure-Prop $s 'last_any_pulse_utc' $null
  Ensure-Prop $s 'last_daily_summary_date_utc' $null
  Ensure-Prop $s 'restart_count_at_last_summary' 0

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

function Get-UtcDayRolloverLine {
  $nowUtc = (Get-Date).ToUniversalTime()
  $next = [DateTime]::new($nowUtc.Year, $nowUtc.Month, $nowUtc.Day, 0, 0, 0, [DateTimeKind]::Utc).AddDays(1)
  $ts = $next - $nowUtc
  if ($ts.TotalSeconds -lt 0) { $ts = [TimeSpan]::Zero }
  if ($ts.TotalHours -ge 1) { return ("{0:D2}h {1:D2}m" -f [int]$ts.TotalHours, $ts.Minutes) }
  return ("{0:D2}m" -f $ts.Minutes)
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
# ONLINE CHECK (VALHEIM)
# =========================
function CommandLineHasPort([string]$cmd, [int]$port) {
  if ([string]::IsNullOrWhiteSpace($cmd)) { return $false }
  $p = [string]$port
  return ($cmd -match "(?i)(^|\s)-port(?:\s+|=)$p(\s|$)")
}

function Get-ValheimProcessByPort {
  try {
    $targetPort = [int]$ResolvedGamePort
    $procs = Get-CimInstance Win32_Process -Filter "Name='valheim_server.exe'" -ErrorAction SilentlyContinue
    if (-not $procs) { return $null }

    foreach ($p in $procs) {
      $cmd = $p.CommandLine
      if (CommandLineHasPort -cmd $cmd -port $targetPort) {
        Write-DebugLine "MATCH by cmdline: PID $($p.ProcessId) | $cmd"
        return $p
      }
    }

    foreach ($p in $procs) {
      if ($p.CommandLine) { Write-DebugLine "VALHEIM cmdline (no match): PID $($p.ProcessId) | $($p.CommandLine)" }
      else { Write-DebugLine "VALHEIM cmdline empty/unreadable: PID $($p.ProcessId)" }
    }

    return $null
  } catch {
    Write-DebugLine "Get-ValheimProcessByPort ERROR: $($_.Exception.Message)"
    return $null
  }
}

function Get-ValheimProcessByUdpOwnership {
  try {
    if (-not (Has-Command "Get-NetUDPEndpoint")) { return $null }

    $eps = Get-NetUDPEndpoint -ErrorAction SilentlyContinue | Where-Object { $ExpectedUdpPorts -contains $_.LocalPort }
    if (-not $eps) { return $null }

    foreach ($g in ($eps | Group-Object OwningProcess)) {
      $pid = [int]$g.Name
      if ($pid -le 0) { continue }

      $ports = @($g.Group | Select-Object -ExpandProperty LocalPort | Sort-Object -Unique)
      $allFound = $true
      foreach ($need in $ExpectedUdpPorts) {
        if ($ports -notcontains $need) { $allFound = $false; break }
      }
      if (-not $allFound) { continue }

      $gp = Get-Process -Id $pid -ErrorAction SilentlyContinue
      if ($gp -and ($gp.ProcessName -like '*valheim*')) {
        Write-DebugLine "MATCH by UDP ownership: PID $pid | ports=$($ports -join ',')"
        return [pscustomobject]@{ ProcessId = $pid; CommandLine = $null }
      }
    }

    return $null
  } catch {
    Write-DebugLine "Get-ValheimProcessByUdpOwnership ERROR: $($_.Exception.Message)"
    return $null
  }
}

function Get-ValheimIdentityProcess {
  $p = Get-ValheimProcessByPort
  if ($p) { return $p }

  $p2 = Get-ValheimProcessByUdpOwnership
  if ($p2) { return $p2 }

  try {
    $gps = Get-Process -Name 'valheim_server' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($gps) {
      Write-DebugLine "FALLBACK: valheim_server process exists but identity checks failed. PID $($gps.Id)"
      return [pscustomobject]@{ ProcessId = $gps.Id; CommandLine = $null }
    }
  } catch {}

  return $null
}

function Test-ValheimOnline {
  return [bool](Get-ValheimIdentityProcess)
}

function Get-ValheimHealthLine {
  param([bool]$online)

  if (-not $online) { return "Pending uplink" }

  try {
    $p = Get-ValheimIdentityProcess
    if (-not $p) { return "Online (process not detected)" }

    $pid = [int]$p.ProcessId
    $gp = Get-Process -Id $pid -ErrorAction SilentlyContinue
    $ramGB = if ($gp) { [math]::Round($gp.WorkingSet64 / 1GB, 1) } else { 0 }

    return "Online | PID $pid | RAM ${ramGB} GB | target -port $ResolvedGamePort"
  } catch {
    return "Online (telemetry limited)"
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

  $color = if ($joinable) { 3066993 }
           elseif ($maintenance) { 15105570 }
           else { 15105570 }

  $flavor = Pick-FlavorByMode -mode $mode

  $directive = if ($joinable) {
    "Directive: **Build / Survive / Explore** world persists."
  } elseif ($maintenance) {
    "Directive: **Hold position** maintenance window active."
  } else {
    "Directive: **Watch this status** next launch time not posted yet."
  }

  $headline = if ($joinable) {
    "🟢 Uplink online **Valheim** now joinable."
  } elseif ($maintenance) {
    "🟠 Maintenance (Not joinable) Stand by."
  } else {
    "🔴 Offline (Not joinable) Stand by."
  }

  $systems = if ($joinable) { "🟢 Systems green" } else { "🟠 Systems amber" }
  $joinabilityLine = if ($joinable) { "✅ Joinable" } else { "⛔ Not joinable" }

  $utcRollover = Get-UtcDayRolloverLine
  $hostRam = Get-HostRamLine
  $healthLine = Get-ValheimHealthLine -online $online

  $pulseUtc = (Get-Date).ToUniversalTime().ToString('HH:mm')
  $footerText = "QUESTPAUSE Valheim • $ServerKey • Pulse $pulseUtc UTC"

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
        title       = "VALHEIM Server Status"
        description = $desc
        color       = $color
        fields      = @(
          @{ name = "🧭 World"; value = $ResolvedWorldName; inline = $false },
          @{ name = "🧩 ServerKey"; value = $ServerKey; inline = $true },
          @{ name = "👥 Slots"; value = "$ResolvedMaxPlayers"; inline = $true },
          @{ name = "🚦 Joinability"; value = $joinabilityLine; inline = $true },
          @{ name = "🕒 Uptime"; value = $uptimeText; inline = $true },
          @{ name = "⏳ UTC day rollover"; value = $utcRollover; inline = $true },
          @{ name = "🧠 Host"; value = $hostRam; inline = $true },
          @{ name = "📊 Status"; value = $systems; inline = $true },
          @{ name = "🛠️ Server Health"; value = $healthLine; inline = $false },
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
# DAILY SUMMARY
# =========================
function Build-DailySummaryPayload {
  param(
    [bool]$online,
    [bool]$maintenance,
    [int]$restarts24h,
    [int]$restartsTotal,
    [string]$lastChangeUtc,
    [string]$summaryDateUtc
  )

  $joinable = ($online -and -not $maintenance)
  $color = if ($joinable) { 3066993 } else { 15105570 }
  $statusLine = if ($joinable) { "🟢 Online (Joinable)" } elseif ($maintenance) { "🟠 Maintenance (Not joinable)" } else { "🔴 Offline (Not joinable)" }

  return [ordered]@{
    content = ""
    embeds = @(
      [ordered]@{
        title       = "📊 QUESTPAUSE Valheim Daily Summary (UTC $summaryDateUtc)"
        description = $statusLine
        color       = $color
        fields      = @(
          @{ name = '🧩 ServerKey'; value = $ServerKey; inline = $true },
          @{ name = 'Restarts (24h)'; value = "$restarts24h"; inline = $true },
          @{ name = 'Restarts (total)'; value = "$restartsTotal"; inline = $true },
          @{ name = 'Host'; value = (Get-HostRamLine); inline = $false },
          @{ name = 'Last change (UTC)'; value = $lastChangeUtc; inline = $false }
        )
        footer    = @{ text = "QUESTPAUSE Valheim | Daily systems check" }
        timestamp = (Get-Date).ToUniversalTime().ToString('o')
      }
    )
    allowed_mentions = @{ parse = @() }
  }
}

function Post-DailySummary {
  param(
    [bool]$online,
    [bool]$maintenance,
    [int]$restarts24h,
    [int]$restartsTotal,
    [string]$lastChangeUtc,
    [string]$summaryDateUtc
  )

  $payload = Build-DailySummaryPayload `
    -online $online `
    -maintenance $maintenance `
    -restarts24h $restarts24h `
    -restartsTotal $restartsTotal `
    -lastChangeUtc $lastChangeUtc `
    -summaryDateUtc $summaryDateUtc

  SendJsonUTF8 -method 'POST' -uri $WebhookPostUri -payload $payload | Out-Null
}

function Should-PostDailySummary([ref]$state, [DateTime]$nowUtcObj) {
  if (-not $EnableDailySummary) { return $false }

  $today = $nowUtcObj.ToString('yyyy-MM-dd')
  if ($state.Value.last_daily_summary_date_utc -eq $today) { return $false }

  $trigger = [DateTime]::new($nowUtcObj.Year, $nowUtcObj.Month, $nowUtcObj.Day, $DailySummaryHourUtc, 0, 0, [DateTimeKind]::Utc)
  return ($nowUtcObj -ge $trigger)
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

  $onlineNow = Test-ValheimOnline
  $manualMaintenance = Is-MaintenanceOn
  $maintenanceNow = $manualMaintenance -or (-not $onlineNow)

  $state.maintenance = $maintenanceNow
  $state.online = $onlineNow
  $state.last_state_change_utc = $nowIso

  if ($onlineNow) {
    $state.last_seen_online_utc = $nowIso
    if (-not $state.online_since_utc) { $state.online_since_utc = $nowIso }
  } else {
    $state.online_since_utc = $null
  }

  Save-State $state

  $lastChangeText = $nowUtcObj.ToString('yyyy-MM-dd HH:mm') + ' UTC'
  $mode = if ($onlineNow) { 'online' } elseif ($maintenanceNow) { 'maintenance' } else { 'offline' }
  $uptimeText = if ($maintenanceNow) { 'Maintenance' } elseif ($onlineNow) { '0m' } else { 'Offline' }

  $payload = Build-Payload -online $onlineNow -maintenance $maintenanceNow -mode $mode -uptimeText $uptimeText -lastChangeUtc $lastChangeText
  $id = SendOrEdit $payload
  if ($id) { Set-Content -Path $LastIdFile -Value $id -Encoding UTF8 }

  Write-DebugLine "RunOnce OK. online=$onlineNow maintenance=$maintenanceNow msgId=$id"
  return
}

Write-Host "QuestPauseOps Valheim watcher started for $ServerKey"
Write-Host "GamePort=$ResolvedGamePort QueryPort=$ResolvedQueryPort PollSeconds=$PollSeconds"
Write-Host "StateDir=$StateDir"
Write-Host "ConfigPath=$ConfigPath"
Write-Host "DebugLog=$DebugLog"

$debugPulseSpan = [TimeSpan]::FromMinutes($DebugPulseMinutes)

try {
  $nowUtcObj = UtcNowObj
  $nowIso = $nowUtcObj.ToString('o')

  $onlineNow = Test-ValheimOnline
  $manualMaintenance = Is-MaintenanceOn
  $maintenanceNow = $manualMaintenance -or (-not $onlineNow)

  $state.maintenance = $maintenanceNow
  $state.online = $onlineNow
  $state.last_state_change_utc = $nowIso

  if ($onlineNow) {
    $state.last_seen_online_utc = $nowIso
    if (-not $state.online_since_utc) { $state.online_since_utc = $nowIso }
  } else {
    $state.online_since_utc = $null
  }

  $lastChangeText = $nowUtcObj.ToString('yyyy-MM-dd HH:mm') + ' UTC'
  $mode = if ($onlineNow) { 'online' } elseif ($maintenanceNow) { 'maintenance' } else { 'offline' }
  $uptimeText = if ($maintenanceNow) { 'Maintenance' } elseif ($onlineNow) { '0m' } else { 'Offline' }

  $payload = Build-Payload -online $onlineNow -maintenance $maintenanceNow -mode $mode -uptimeText $uptimeText -lastChangeUtc $lastChangeText
  $id = SendOrEdit $payload
  if ($id) { Set-Content -Path $LastIdFile -Value $id -Encoding UTF8 }

  $state.last_debug_pulse_utc = $nowIso
  $state.last_any_pulse_utc   = $nowIso
  Save-State $state

  Write-DebugLine "Startup post OK. online=$onlineNow maintenance=$maintenanceNow msgId=$id"
} catch {
  Write-DebugLine "Startup post ERROR: $($_.Exception.Message)"
}

while ($true) {
  try {
    $nowUtcObj = UtcNowObj
    $nowIso = $nowUtcObj.ToString('o')

    $rawOnline = Test-ValheimOnline
    $targetOnline = $rawOnline

    $manualMaintenance = Is-MaintenanceOn
    $maintenanceNow = $manualMaintenance -or (-not $rawOnline)

    if (-not $maintenanceNow -and $OfflineAfterSeconds -gt 0) {
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

    $stateChanged = ($targetOnline -ne $state.online)
    $maintChanged = ($effectiveMaintenance -ne $state.maintenance)

    if ($stateChanged -or $maintChanged) {
      $state.last_state_change_utc = $nowIso

      if ($stateChanged) {
        if ($targetOnline) {
          $state.online_since_utc = $nowIso
          if (-not $effectiveMaintenance) {
            $state.restart_count = [int]$state.restart_count + 1
          }
        } else {
          $state.online_since_utc = $null
        }
      }
    }

    $dbgDue = $false
    $lastDbg = Try-ParseUtc $state.last_debug_pulse_utc
    if (-not $lastDbg) { $dbgDue = $true }
    elseif (($nowUtcObj - $lastDbg) -ge $debugPulseSpan) { $dbgDue = $true }

    $summaryDue = Should-PostDailySummary -state ([ref]$state) -nowUtcObj $nowUtcObj

    $lastChange = Try-ParseUtc $state.last_state_change_utc
    if (-not $lastChange) { $lastChange = $nowUtcObj }
    $lastChangeText = $lastChange.ToString('yyyy-MM-dd HH:mm') + ' UTC'

    $mode = if ($targetOnline) { 'online' } elseif ($effectiveMaintenance) { 'maintenance' } else { 'offline' }

    $uptimeText = if ($effectiveMaintenance) {
      'Maintenance'
    } elseif ($targetOnline) {
      $since = Try-ParseUtc $state.online_since_utc
      if ($since) { Format-Duration ($nowUtcObj - $since) } else { '0m' }
    } else {
      'Offline'
    }

    if ($summaryDue) {
      try {
        $today = $nowUtcObj.ToString('yyyy-MM-dd')
        $restarts24h = [int]$state.restart_count - [int]$state.restart_count_at_last_summary
        if ($restarts24h -lt 0) { $restarts24h = 0 }

        Post-DailySummary `
          -online $targetOnline `
          -maintenance $effectiveMaintenance `
          -restarts24h $restarts24h `
          -restartsTotal ([int]$state.restart_count) `
          -lastChangeUtc $lastChangeText `
          -summaryDateUtc $today

        $state.last_daily_summary_date_utc = $today
        $state.restart_count_at_last_summary = [int]$state.restart_count
        Save-State $state

        Write-DebugLine "Daily summary posted for $today (UTC)."
      } catch {
        Write-DebugLine "Daily summary error: $($_.Exception.Message)"
      }
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

  if ($RunOnce) { break }
  Start-Sleep -Seconds $PollSeconds
}

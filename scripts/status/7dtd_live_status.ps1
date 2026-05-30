[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$ServerKey,

  [switch]$RunOnce,

  [int]$PollSeconds = 10,
  [int]$PulseMinutes = 1,

  # Optional overrides
  [string]$WorldName = '',
  [int]$MaxPlayers = 0,
  [string]$MaintenanceFlagPath = '',
  [string]$WebhookUrl = '',
  [int[]]$ExpectedUdpPorts = @()
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
  C:\QuestPauseOps\scripts\status\7dtd_live_status.ps1
  QUESTPAUSEOPS — 7DTD Live Status

  What it does:
  - Loads C:\QuestPauseOps\config\servers.json
  - Uses -ServerKey to target ONE 7DTD server
  - Stores per-server state in C:\QuestPauseOps\state\<ServerKey>\
  - Stores debug logs in C:\QuestPauseOps\logs\status\
  - POST once then PATCH same Discord message forever
  - Supports RunOnce mode or watcher mode
  - Uptime based on process StartTime of the PID owning expected UDP ports
  - maintenance.on forces Maintenance / Not joinable
#>

# =========================
# UTF-8 + reliability (PS 5.1)
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

$StateFile  = Join-Path $StateDir '7dtd_status_state.json'
$DebugLog   = Join-Path $LogsDir  ("{0}_7dtd_live_status.log" -f $ServerKey)
$LastIdFile = Join-Path $StateDir '7dtd_last_message_id.txt'

function Ensure-Dir([string]$p) {
  if (-not (Test-Path $p)) {
    New-Item -ItemType Directory -Path $p -Force | Out-Null
  }
}

function Write-DebugLine([string]$line) {
  Ensure-Dir $StateDir
  Ensure-Dir $LogsDir
  $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  "$ts  $line" | Add-Content -Path $DebugLog -Encoding UTF8
}

Ensure-Dir $StateDir
Ensure-Dir $LogsDir

# =========================
# OPTIONAL MODULE IMPORT
# =========================
if (Test-Path $LibPath) {
  try {
    Import-Module $LibPath -Force -ErrorAction Stop 3>$null
    Write-DebugLine "Imported module: $LibPath"
  } catch {
    Write-DebugLine "Module import failed: $($_.Exception.Message)"
  }
}

# =========================
# UTIL / TIME
# =========================
function UtcNowObj { (Get-Date).ToUniversalTime() }

function Try-ParseUtc([string]$iso) {
  if ([string]::IsNullOrWhiteSpace($iso)) { return $null }
  try { return ([DateTime]::Parse($iso)).ToUniversalTime() } catch { return $null }
}

function Format-Duration([TimeSpan]$ts) {
  if ($ts.TotalSeconds -lt 0) { return '0m' }
  if ($ts.TotalHours -ge 24)  { return "{0}d {1}h" -f [int]$ts.TotalDays, $ts.Hours }
  if ($ts.TotalHours -ge 1)   { return "{0}h {1}m" -f [int]$ts.TotalHours, $ts.Minutes }
  return "{0}m" -f [int]$ts.TotalMinutes
}

function Get-UtcDayRolloverLine {
  $nowUtc = UtcNowObj
  $next = [DateTime]::new($nowUtc.Year, $nowUtc.Month, $nowUtc.Day, 0,0,0,[DateTimeKind]::Utc).AddDays(1)
  $ts = $next - $nowUtc
  if ($ts.TotalSeconds -lt 0) { $ts = [TimeSpan]::Zero }
  if ($ts.TotalHours -ge 1) { return ("{0:D2}h {1:D2}m" -f [int]$ts.TotalHours, $ts.Minutes) }
  return ("{0:D2}m" -f $ts.Minutes)
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

if ($server.product -and $server.product -ne '7dtd') {
  Write-DebugLine "Warning: server.product is '$($server.product)' for $ServerKey"
}

function Get-FirstValue {
  param($Primary, $Fallback)
  if ($null -ne $Primary -and "$Primary".Trim() -ne '') { return $Primary }
  return $Fallback
}

$WorldNameFallback = 'Navezgane'
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
  $ResolvedMaxPlayers = 8
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

if ($ExpectedUdpPorts -and $ExpectedUdpPorts.Count -gt 0) {
  $ResolvedExpectedUdpPorts = @($ExpectedUdpPorts | Where-Object { $_ -gt 0 } | Select-Object -Unique)
} elseif ($server.expectedUdpPorts) {
  $ResolvedExpectedUdpPorts = @($server.expectedUdpPorts | ForEach-Object { [int]$_ } | Where-Object { $_ -gt 0 } | Select-Object -Unique)
} else {
  $ResolvedExpectedUdpPorts = @()
  if ($server.gamePort)  { $ResolvedExpectedUdpPorts += [int]$server.gamePort }
  if ($server.queryPort) { $ResolvedExpectedUdpPorts += [int]$server.queryPort }
  $ResolvedExpectedUdpPorts = @($ResolvedExpectedUdpPorts | Select-Object -Unique)
}

if (-not $ResolvedExpectedUdpPorts -or $ResolvedExpectedUdpPorts.Count -eq 0) {
  throw "Expected UDP ports missing for $ServerKey. Add expectedUdpPorts or gamePort/queryPort in servers.json."
}

Write-DebugLine "Resolved config for $ServerKey"
Write-DebugLine "ConfigPath=$ConfigPath"
Write-DebugLine "WorldName=$ResolvedWorldName"
Write-DebugLine "MaxPlayers=$ResolvedMaxPlayers"
Write-DebugLine "ExpectedUdpPorts=$($ResolvedExpectedUdpPorts -join ',')"
Write-DebugLine "MaintenanceFlagPath=$ResolvedMaintenanceFlagPath"

function Is-MaintenanceOn { Test-Path $ResolvedMaintenanceFlagPath }

# =========================
# WEBHOOK SANITIZE/VALIDATE
# =========================
function Normalize-Webhook([string]$w) {
  if ([string]::IsNullOrWhiteSpace($w)) { return "" }
  $w = ($w -replace '\s','') -replace '[\u200B-\u200D\uFEFF]',''
  return $w.Trim().TrimEnd('/')
}

$ResolvedWebhookUrl = Normalize-Webhook $ResolvedWebhookUrl

if ([string]::IsNullOrWhiteSpace($ResolvedWebhookUrl)) { throw "Webhook is empty." }

if ($ResolvedWebhookUrl -notmatch '^https://(canary\.|ptb\.)?discord\.com/api/webhooks/\d+/[^/]+$') {
  throw "Webhook format invalid for ${ServerKey}: '$ResolvedWebhookUrl'"
}

function Get-WebhookParts([string]$webhookBase) {
  if ($webhookBase -match '^https://(canary\.|ptb\.)?discord\.com/api/webhooks/(?<id>\d+)/(?<token>[^/]+)$') {
    return @{ id = $Matches['id']; token = $Matches['token'] }
  }
  throw "Webhook format unexpected."
}

$WebhookParts = Get-WebhookParts $ResolvedWebhookUrl
$WebhookUri = [Uri]::new($ResolvedWebhookUrl)

function Get-PostWaitUri {
  $b = [System.UriBuilder]::new($WebhookUri)
  $b.Query = 'wait=true'
  return $b.Uri
}

function Get-EditUri([string]$msgId) {
  $raw = "https://discord.com/api/webhooks/$($WebhookParts.id)/$($WebhookParts.token)/messages/$msgId"
  return [Uri]::new($raw)
}

function SendJsonUTF8 {
  param(
    [ValidateSet('POST','PATCH')]
    [string]$Method,
    [Uri]$Uri,
    [hashtable]$Payload
  )
  $json  = $Payload | ConvertTo-Json -Depth 16
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)

  Invoke-DiscordApiWithRetry -Method $Method -Uri $Uri -Body $bytes -ContentType 'application/json; charset=utf-8'
}

function TryEditMessage([string]$msgId, [hashtable]$payload) {
  $editUri = Get-EditUri $msgId
  for ($attempt=1; $attempt -le 2; $attempt++) {
    try {
      if ($attempt -gt 1) { Write-DebugLine "PATCH retry #$attempt for message $msgId" }
      return (SendJsonUTF8 -Method 'PATCH' -Uri $editUri -Payload $payload)
    } catch {
      Write-DebugLine ("PATCH failed (attempt {0}) msg {1}: {2} | url={3}" -f $attempt, $msgId, $_.Exception.Message, $editUri.AbsoluteUri)
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
      Write-DebugLine "Editing message $msgId"
      $r = TryEditMessage -msgId $msgId -payload $payload
      return $r.id
    } catch {
      Write-DebugLine "Edit failed; falling back to POST and resetting stored message id."
      try { Remove-Item -Path $LastIdFile -Force -ErrorAction SilentlyContinue } catch {}
    }
  }

  $postUri = Get-PostWaitUri
  Write-DebugLine "Posting new status message | url=$($postUri.AbsoluteUri)"
  $r = SendJsonUTF8 -Method 'POST' -Uri $postUri -Payload $payload
  return $r.id
}

# =========================
# ONLINE CHECK (ports + PID + StartTime)
# =========================
function Get-UdpRowsForPorts {
  @(Get-NetUDPEndpoint -ErrorAction SilentlyContinue | Where-Object { $ResolvedExpectedUdpPorts -contains $_.LocalPort })
}

function Test-Online {
  $gamePort = [int]$server.gamePort
  $rows = Get-NetUDPEndpoint -ErrorAction SilentlyContinue |
    Where-Object { $_.LocalPort -eq $gamePort }

  return ($rows | Measure-Object).Count -ge 1
}

function Get-7dtdPortOwnerPid {
  $gamePort = [int]$server.gamePort
  $row = Get-NetUDPEndpoint -ErrorAction SilentlyContinue |
    Where-Object { $_.LocalPort -eq $gamePort } |
    Select-Object -First 1

  if ($row) { return [int]$row.OwningProcess }
  return $null
}

function Get-ServerStartUtcFromPid([int]$serverPid) {
  try {
    $p = Get-Process -Id $serverPid -ErrorAction Stop
    return ($p.StartTime).ToUniversalTime()
  } catch {
    return $null
  }
}

function Get-ServerHealthLine([bool]$onlineNow) {
  if (-not $onlineNow) { return "Maintenance" }

  $serverPid = Get-7dtdPortOwnerPid
  if (-not $serverPid) { return "Online (ports detected)" }

  try {
    $p = Get-Process -Id $serverPid -ErrorAction Stop
    $ramGB = [math]::Round($p.WorkingSet64 / 1GB, 1)
    return "PID $serverPid | RAM ${ramGB} GB"
  } catch {
    return "PID $serverPid"
  }
}

# =========================
# STATE
# =========================
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
  Ensure-Prop $s 'online_since_utc' $null
  Ensure-Prop $s 'last_change_utc' $null
  Ensure-Prop $s 'last_pulse_utc' $null
  Ensure-Prop $s 'last_server_pid' $null

  return $s
}

function Save-State($s) {
  Ensure-Dir $StateDir
  ($s | ConvertTo-Json -Depth 8) | Set-Content -Path $StateFile -Encoding UTF8
}

# =========================
# EMBED PAYLOAD
# =========================
function Build-EmbedPayload {
  param(
    [bool]$onlineNow,
    [bool]$maintenanceNow,
    [string]$uptimeText,
    [string]$lastChangeUtc
  )

  $joinable = ($onlineNow -and -not $maintenanceNow)
  $color = if ($joinable) { 0x2ECC71 } else { 0xF1C40F }

  $headline = if ($joinable) {
    "🟢 Uplink Online **7 Days to Die** (Joinable)"
  } else {
    "🟠 Maintenance **Not Joinable**"
  }

  $desc = @(
    $headline,
    "",
    "The wasteland is waiting.",
    "",
    "Directive: **Loot / Build / Survive** world persists.",
    "Times in **UTC**."
  ) -join "`n"

  $joinLine = if ($joinable) { "✅ Joinable" } else { "⛔ Not joinable" }
  $uplink   = if ($joinable) { "🟢 Systems green" } else { "🟠 Maintenance" }

  $pulseUtc = (UtcNowObj).ToString('HH:mm')
  $footerText = "QUESTPAUSE • 7DTD • $ServerKey • Pulse $pulseUtc UTC"

  return [ordered]@{
    content = ""
    embeds  = @(
      [ordered]@{
        title       = "7DTD Server Status"
        description = $desc
        color       = $color
        fields      = @(
          @{ name = "🧭 World"; value = $ResolvedWorldName; inline = $false },
          @{ name = "🧩 ServerKey"; value = $ServerKey; inline = $true },
          @{ name = "👥 Slots"; value = "$ResolvedMaxPlayers max"; inline = $true },
          @{ name = "🚦 Joinability"; value = $joinLine; inline = $true },
          @{ name = "🕒 Uptime"; value = $uptimeText; inline = $true },
          @{ name = "⏳ UTC day rollover"; value = (Get-UtcDayRolloverLine); inline = $true },
          @{ name = "🖥️ Host Load"; value = (Get-HostRamLine); inline = $true },
          @{ name = "🛰️ Uplink"; value = $uplink; inline = $true },
          @{ name = "🛠️ Server Health"; value = (Get-ServerHealthLine -onlineNow:$onlineNow); inline = $false },
          @{ name = "Last change (UTC)"; value = $lastChangeUtc; inline = $false }
        )
        footer    = @{ text = $footerText }
        timestamp = (UtcNowObj).ToString('o')
      }
    )
    allowed_mentions = @{ parse = @() }
  }
}

function Compute-UptimeText {
  param(
    [bool]$onlineNow,
    [bool]$maintenanceNow,
    [object]$stateObj,
    [DateTime]$nowUtc
  )

  if ($maintenanceNow -or -not $onlineNow) { return "Maintenance" }

  $serverPid = Get-7dtdPortOwnerPid
  if ($serverPid) {
    $startUtc = Get-ServerStartUtcFromPid -serverPid $serverPid
    if ($startUtc) {
      if ($stateObj.last_server_pid -ne "$serverPid") {
        $stateObj.last_server_pid = "$serverPid"
        $stateObj.online_since_utc = $startUtc.ToString('o')
      } elseif (-not $stateObj.online_since_utc) {
        $stateObj.online_since_utc = $startUtc.ToString('o')
      }
      return "" + (Format-Duration ($nowUtc - $startUtc))
    }
  }

  if (-not $stateObj.online_since_utc) { $stateObj.online_since_utc = $nowUtc.ToString('o') }
  $since = Try-ParseUtc $stateObj.online_since_utc
  if ($since) { return "" + (Format-Duration ($nowUtc - $since)) }
  return "Online"
}

# =========================
# MAIN
# =========================
$state = Load-State

Write-Host "QuestPauseOps 7DTD watcher started for $ServerKey."
Write-Host "ExpectedUdpPorts=$($ResolvedExpectedUdpPorts -join ',')"
Write-Host "StateDir=$StateDir"
Write-Host "ConfigPath=$ConfigPath"
Write-Host "DebugLog=$DebugLog"

Write-DebugLine "Start. ServerKey=$ServerKey RunOnce=$($RunOnce.IsPresent) | Webhook='$ResolvedWebhookUrl'"

$pulseSpan = [TimeSpan]::FromMinutes($PulseMinutes)

$state.last_pulse_utc = $null
Save-State $state

function Do-PostUpdate([bool]$onlineNow, [bool]$maintenanceNow, [DateTime]$nowUtc) {
  $nowIso = $nowUtc.ToString('o')

  $stateChanged = ($onlineNow -ne [bool]$state.online) -or ($maintenanceNow -ne [bool]$state.maintenance) -or (-not $state.last_change_utc)
  if ($stateChanged) {
    $state.last_change_utc = $nowIso
    if (-not $onlineNow) {
      $state.online_since_utc = $null
      $state.last_server_pid  = $null
    }
  }

  $uptimeText = Compute-UptimeText -onlineNow $onlineNow -maintenanceNow $maintenanceNow -stateObj $state -nowUtc $nowUtc

  $lc = Try-ParseUtc $state.last_change_utc
  if (-not $lc) { $lc = $nowUtc }
  $lastChangeText = ($lc.ToString('yyyy-MM-dd HH:mm') + ' UTC')

  $payload = Build-EmbedPayload -onlineNow $onlineNow -maintenanceNow $maintenanceNow -uptimeText $uptimeText -lastChangeUtc $lastChangeText

  try {
    $msgId = SendOrEdit $payload
    if ($msgId) { Set-Content -Path $LastIdFile -Value $msgId -Encoding UTF8 }
    $state.last_pulse_utc = $nowIso
    $state.online = $onlineNow
    $state.maintenance = $maintenanceNow
    Save-State $state
    Write-DebugLine "OK. online=$onlineNow maintenance=$maintenanceNow msgId=$msgId uptime='$uptimeText'"
  } catch {
    $m = $_.Exception.Message
    Write-Host "DISCORD POST FAILED: $m" -ForegroundColor Red
    Write-DebugLine "DISCORD POST FAILED: $m"
  }
}

if ($RunOnce) {
  $nowUtc = UtcNowObj
  $maintenanceNow = Is-MaintenanceOn
  $onlineNow = Test-Online
  if ($maintenanceNow) { $onlineNow = $false }
  Do-PostUpdate -onlineNow:$onlineNow -maintenanceNow:$maintenanceNow -nowUtc:$nowUtc
  return
}

$nowUtc0 = UtcNowObj
$maintenance0 = Is-MaintenanceOn
$online0 = Test-Online
if ($maintenance0) { $online0 = $false }
Do-PostUpdate -onlineNow:$online0 -maintenanceNow:$maintenance0 -nowUtc:$nowUtc0

while ($true) {
  $nowUtc = UtcNowObj
  $maintenanceNow = Is-MaintenanceOn
  $onlineNow = Test-Online
  if ($maintenanceNow) { $onlineNow = $false }

  $lp = Try-ParseUtc $state.last_pulse_utc
  $pulseDue = (-not $lp) -or (($nowUtc - $lp).TotalSeconds -ge ($PulseMinutes * 60))

  $changed = ($onlineNow -ne [bool]$state.online) -or ($maintenanceNow -ne [bool]$state.maintenance)

  if ($changed -or $pulseDue) {
    Do-PostUpdate -onlineNow:$onlineNow -maintenanceNow:$maintenanceNow -nowUtc:$nowUtc
  } else {
    $state.online = $onlineNow
    $state.maintenance = $maintenanceNow
    Save-State $state
  }

  Start-Sleep -Seconds $PollSeconds
}

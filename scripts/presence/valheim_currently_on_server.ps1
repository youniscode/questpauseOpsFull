[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$ServerKey,

  [switch]$RunOnce,

  [int]$PollSeconds = 2,
  [int]$PulseMinutes = 1,

  [int]$RosterRefreshSeconds = 10,
  [int]$A2STimeoutMs = 1200,
  [bool]$AutoDetectQueryPort = $true,

  [int]$BootstrapLines = 2000,
  [int]$JoinCooldownSecondsPerSteam = 120,
  [int]$LeaveCooldownSecondsPerSteam = 25,

  # Optional overrides
  [string]$LogPath = '',
  [string]$WebhookUrl = '',
  [string]$WorldName = '',
  [string]$ServerHost = '',
  [int]$QueryPort = 0,
  [int[]]$QueryPortCandidates = @(),
  [int]$MaxPlayers = 0
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
  C:\QuestPauseOps\scripts\presence\valheim_currently_on_server.ps1
  QUESTPAUSEOPS — Valheim Presence Card

  What it does:
  - Loads C:\QuestPauseOps\config\servers.json
  - Uses -ServerKey to target ONE Valheim server
  - Uses Steam A2S query as roster truth when available
  - Watches Valheim log as fallback / name learning
  - Maintains one live Discord card edited in place
  - Stores per-server state in C:\QuestPauseOps\state\<ServerKey>\
  - Stores debug logs in C:\QuestPauseOps\logs\presence\

  Notes:
  - This is a PRESENCE script (player truth), not a server health script
  - A2S roster is primary truth
  - Log parsing helps learn names and catch transitions
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
$LogsDir    = Join-Path $OpsRoot 'logs\presence'
$StateDir   = Join-Path $OpsRoot ("state\" + $ServerKey)

$StateFile      = Join-Path $StateDir 'valheim_presence_state.json'
$DebugLog       = Join-Path $LogsDir  ("{0}_valheim_currently_on_server.log" -f $ServerKey)
$LastIdFile     = Join-Path $StateDir 'valheim_presence_last_message_id.txt'
$RosterCache    = Join-Path $StateDir 'valheim_presence_roster.json'
$CursorFile     = Join-Path $StateDir 'valheim_presence_cursor.json'

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
    Import-Module $LibPath -Force -ErrorAction Stop 3>$null
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

function Get-FirstValue {
  param($Primary, $Fallback)
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

$HostFallback = '127.0.0.1'
if ($server.host) {
  $HostFallback = $server.host
}
$ResolvedHost = Get-FirstValue $ServerHost $HostFallback

$QueryPortFallback = 0
if ($server.queryPort) {
  $QueryPortFallback = [int]$server.queryPort
} elseif ($server.gamePort) {
  $QueryPortFallback = [int]$server.gamePort
}
if ($QueryPort -gt 0) {
  $ResolvedQueryPort = $QueryPort
} else {
  $ResolvedQueryPort = $QueryPortFallback
}

$CandidatesFallback = @()
if ($server.PSObject.Properties['valheim'] -and $server.valheim -and $server.valheim.PSObject.Properties['queryPortCandidates']) {
  $CandidatesFallback = @($server.valheim.queryPortCandidates | ForEach-Object { [int]$_ })
} elseif ($ResolvedQueryPort -gt 0) {
  $CandidatesFallback = @($ResolvedQueryPort)
}

if ($QueryPortCandidates -and $QueryPortCandidates.Count -gt 0) {
  $ResolvedQueryPortCandidates = @($QueryPortCandidates | ForEach-Object { [int]$_ })
} else {
  $ResolvedQueryPortCandidates = $CandidatesFallback
}

$LogPathFallback = ''
if ($server.PSObject.Properties['valheim'] -and $server.valheim -and $server.valheim.PSObject.Properties['logPath']) {
  $LogPathFallback = $server.valheim.logPath
} elseif ($server.logPath) {
  $LogPathFallback = $server.logPath
}
$ResolvedLogPath = Get-FirstValue $LogPath $LogPathFallback

$WebhookFallback = ''
if ($server.PSObject.Properties['webhooks'] -and $server.webhooks -and $server.webhooks.PSObject.Properties['presence']) {
  $WebhookFallback = $server.webhooks.presence
} elseif ($server.PSObject.Properties['webhooks'] -and $server.webhooks -and $server.webhooks.PSObject.Properties['status']) {
  $WebhookFallback = $server.webhooks.status
} elseif ($server.webhookUrl) {
  $WebhookFallback = $server.webhookUrl
}
$ResolvedWebhookUrl = Get-FirstValue $WebhookUrl $WebhookFallback

if ([string]::IsNullOrWhiteSpace($ResolvedWebhookUrl)) {
  throw "No webhook found for $ServerKey. Add servers.$ServerKey.webhooks.presence or pass -WebhookUrl."
}

if ($ResolvedQueryPort -le 0 -and (-not $ResolvedQueryPortCandidates -or $ResolvedQueryPortCandidates.Count -eq 0)) {
  throw "No query port found for $ServerKey. Add queryPort or valheim.queryPortCandidates."
}

Write-DebugLine "Resolved config for $ServerKey"
Write-DebugLine "ConfigPath=$ConfigPath"
Write-DebugLine "WorldName=$ResolvedWorldName"
Write-DebugLine "Host=$ResolvedHost"
Write-DebugLine "QueryPort=$ResolvedQueryPort"
Write-DebugLine "QueryPortCandidates=$($ResolvedQueryPortCandidates -join ',')"
Write-DebugLine "MaxPlayers=$ResolvedMaxPlayers"
Write-DebugLine "LogPath=$ResolvedLogPath"

# =========================
# WEBHOOK SETUP
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
# HELPERS
# =========================
function Ensure-Prop([object]$obj, [string]$name, $defaultValue) {
  if ($null -eq $obj.PSObject.Properties[$name]) {
    $obj | Add-Member -NotePropertyName $name -NotePropertyValue $defaultValue -Force
  }
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

function Format-OnlineLine {
  param([int]$Online, [int]$Max)
  if ($Max -gt 0) { return "$Online/$Max" }
  return "$Online"
}

function Clamp([int]$v,[int]$min,[int]$max){ [Math]::Max($min,[Math]::Min($max,$v)) }

# =========================
# STATE
# =========================
function Load-State {
  $s = $null
  if (Test-Path $StateFile) {
    try { $s = Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $s = $null }
  }
  if (-not $s) { $s = [pscustomobject]@{} }

  Ensure-Prop $s 'last_event_utc' $null
  Ensure-Prop $s 'last_event_text' 'Watcher started'
  Ensure-Prop $s 'last_pulse_utc' $null
  Ensure-Prop $s 'online_since_utc' $null

  Ensure-Prop $s 'watch_log' $null
  Ensure-Prop $s 'watch_log_length' 0
  Ensure-Prop $s 'watch_log_lastwrite_utc' $null

  Ensure-Prop $s 'last_roster_refresh_utc' $null
  Ensure-Prop $s 'last_a2s_ok' $false
  Ensure-Prop $s 'last_a2s_error' ''
  Ensure-Prop $s 'active_query_port' $null
  Ensure-Prop $s 'recent_events' @()

  return $s
}

function Save-State($s) {
  ($s | ConvertTo-Json -Depth 12) | Set-Content -Path $StateFile -Encoding UTF8
}

function Load-Roster {
  if (Test-Path $RosterCache) {
    try {
      $raw = Get-Content $RosterCache -Raw -Encoding UTF8 | ConvertFrom-Json
      $h = @{}
      foreach ($p in $raw.PSObject.Properties) {
        $h[$p.Name] = [string]$p.Value
      }
      return $h
    } catch {
      return @{}
    }
  }
  return @{}
}

function Save-Roster([hashtable]$roster) {
  $obj = [ordered]@{}
  foreach ($k in ($roster.Keys | Sort-Object)) {
    $obj[$k] = $roster[$k]
  }
  ($obj | ConvertTo-Json -Depth 8) | Set-Content -Path $RosterCache -Encoding UTF8
}

function Load-Cursor {
  if (Test-Path $CursorFile) {
    try { return (Get-Content $CursorFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch {}
  }
  return [pscustomobject]@{
    path = $null
    position = 0
    length = 0
    lastwrite_utc = $null
  }
}

function Save-Cursor($cursor) {
  ($cursor | ConvertTo-Json -Depth 8) | Set-Content -Path $CursorFile -Encoding UTF8
}

$script:state = Load-State

# Truth roster (A2S) / known names
$script:activeBySteam = Load-Roster

if ($script:activeBySteam.Count -gt 0 -and -not $script:state.online_since_utc) {
  $script:state.online_since_utc = (UtcNowObj).ToString('o')
}

$script:playerTimestamps = @{}
$script:lastJoinFiredBySteam  = @{}
$script:lastLeaveFiredBySteam = @{}
$script:KnownNameToSteam      = @{}
$script:KnownSteamToName      = @{}
$script:PendingJoinSteam      = $null

# =========================
# TIPS
# =========================
$RealmTips = @(
  "Always keep 10 resin. Torches and lights solve many problems.",
  "Rested buff means faster stamina and health recovery.",
  "Portals can’t move ore, so plan boats and forward bases.",
  "A bed, a fire, and food matter more than one extra chest.",
  "Build fallback storage before long exploration runs.",
  "Repair gear before sailing, not after landing in danger.",
  "Daylight shortens mistakes. Night travel multiplies them.",
  "A portal home is stronger than carrying too much loot.",
  "Keep one emergency food stack in base at all times.",
  "A calm retreat beats a messy last stand."
)

function Pick-RealmTip {
  return ($RealmTips | Get-Random)
}

# =========================
# EMBED CONTENT
# =========================
function Get-RosterLines {
  param([hashtable]$Roster)

  if (-not $Roster -or $Roster.Count -eq 0) {
    return "No vikings currently detected."
  }

  $names = @($Roster.GetEnumerator() | ForEach-Object { $_.Value } | Select-Object -Unique | Sort-Object)
  $lines = @()
  foreach ($n in $names) {
    $lines += "• $n"
  }
  return ($lines -join "`n")
}

function Get-RelativeTime([string]$isoUtc) {
  $dt = Try-ParseUtc $isoUtc
  if (-not $dt) { return "?" }
  return Format-Duration ((UtcNowObj) - $dt)
}

function Format-RecentEvents([array]$events) {
  if (-not $events -or $events.Count -eq 0) { return "No recent activity." }
  $lines = @()
  $maxShow = [Math]::Min(8, $events.Count)
  for ($i = 0; $i -lt $maxShow; $i++) {
    $e = $events[$i]
    $rel = Get-RelativeTime $e.timestamp
    if ($e.type -eq 'join') {
      $lines += "[+] $($e.username)  ($rel ago)"
    } else {
      $line = "[-] $($e.username)  ($rel ago)"
      if ($e.duration) { $line += "  [online $($e.duration)]" }
      $lines += $line
    }
  }
  return $lines -join "`n"
}

function Build-Payload {
  param(
    [hashtable]$Roster,
    [string]$LastEventText,
    [string]$LastEventUtc
  )

  $onlineCount = if ($Roster) { $Roster.Count } else { 0 }
  $presenceState = if ($onlineCount -gt 0) { "🟢 Vikings detected" } else { "⚫ Quiet realm" }
  $onlineLine = Format-OnlineLine -Online $onlineCount -Max $ResolvedMaxPlayers
  $rosterLines = Get-RosterLines -Roster $Roster

  $uptimeText = "No vikings online"
  if ($onlineCount -gt 0) {
    $since = Try-ParseUtc $script:state.online_since_utc
    if ($since) { $uptimeText = Format-Duration ((UtcNowObj) - $since) }
    else { $uptimeText = "Online" }
  }

  $queryLine = "Unknown"
  if ($script:state.active_query_port) {
    $queryLine = "${ResolvedHost}:$($script:state.active_query_port)"
  } elseif ($ResolvedQueryPort -gt 0) {
    $queryLine = "${ResolvedHost}:$ResolvedQueryPort"
  }

  $a2sLine = if ($script:state.last_a2s_ok) { "✅ A2S truth active" } else { "⚠️ Log fallback only" }

  $pulseUtc = (Get-Date).ToUniversalTime().ToString('HH:mm')
  $color = if ($onlineCount -gt 0) { 0x2ECC71 } else { 0x95A5A6 }

  $desc = @(
    "**Valheim player presence**",
    "",
    $presenceState,
    "",
    "Live roster tracked from Steam query truth with log learning fallback.",
    "Times in **UTC**."
  ) -join "`n"

  return [ordered]@{
    content = ""
    embeds = @(
      [ordered]@{
        title       = "Valheim Currently On Server"
        description = $desc
        color       = $color
        fields      = @(
          @{ name = "🧭 World"; value = $ResolvedWorldName; inline = $false },
          @{ name = "🧩 ServerKey"; value = $ServerKey; inline = $true },
          @{ name = "👥 Online"; value = $onlineLine; inline = $true },
          @{ name = "📡 Presence"; value = $presenceState; inline = $true },
          @{ name = "🕒 Online since"; value = $uptimeText; inline = $true },
          @{ name = "🌐 Query"; value = $queryLine; inline = $true },
          @{ name = "🛡️ Truth Source"; value = $a2sLine; inline = $true },
          @{ name = "🪓 Vikings"; value = $rosterLines; inline = $false },
          @{ name = "Last event (UTC)"; value = $LastEventUtc; inline = $false },
          @{ name = "📝 Last event"; value = $LastEventText; inline = $false },
          @{ name = "🔄 Recent Activity"; value = (Format-RecentEvents $script:state.recent_events); inline = $false },
          @{ name = "💡 Realm Tip"; value = (Pick-RealmTip); inline = $false }
        )
        footer    = @{ text = "QUESTPAUSE • Valheim • $ServerKey • Pulse $pulseUtc UTC" }
        timestamp = (Get-Date).ToUniversalTime().ToString('o')
      }
    )
    allowed_mentions = @{ parse = @() }
  }
}

# =========================
# A2S (STEAM QUERY)
# =========================
function New-UdpClient([int]$timeoutMs) {
  $c = New-Object System.Net.Sockets.UdpClient
  $c.Client.ReceiveTimeout = [Math]::Max(200, $timeoutMs)
  $c.Client.SendTimeout    = [Math]::Max(200, $timeoutMs)
  return $c
}

function Bytes-FromAscii([string]$s) { [System.Text.Encoding]::ASCII.GetBytes($s) }

function Read-NullTerminatedString([byte[]]$buf, [ref]$idx) {
  $start = $idx.Value
  while ($idx.Value -lt $buf.Length -and $buf[$idx.Value] -ne 0) { $idx.Value++ }
  $len = $idx.Value - $start
  $str = ""
  if ($len -gt 0) { $str = [System.Text.Encoding]::UTF8.GetString($buf, $start, $len) }
  if ($idx.Value -lt $buf.Length -and $buf[$idx.Value] -eq 0) { $idx.Value++ }
  return $str
}

function Get-A2SInfo {
  param([string]$ServerHost,[int]$Port,[int]$TimeoutMs)
  $client = $null
  try {
    $client = New-UdpClient -timeoutMs $TimeoutMs
    $client.Connect($ServerHost, $Port)
    $header  = [byte[]](0xFF,0xFF,0xFF,0xFF)
    $payload = $header + (Bytes-FromAscii "TSource Engine Query`0")
    [void]$client.Send($payload, $payload.Length)
    $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any,0)
    $resp = $client.Receive([ref]$remote)
    if (-not $resp -or $resp.Length -lt 6) { return $null }
    if ($resp[4] -ne 0x49) { return $null }
    return $resp
  } catch {
    return $null
  } finally { try { if ($client) { $client.Close() } } catch {} }
}

function Get-A2SPlayers {
  param([string]$ServerHost,[int]$Port,[int]$TimeoutMs)

  $client = $null
  try {
    $client = New-UdpClient -timeoutMs $TimeoutMs
    $client.Connect($ServerHost, $Port)

    $hdr = [byte[]](0xFF,0xFF,0xFF,0xFF)

    $req1 = $hdr + [byte[]](0x55,0xFF,0xFF,0xFF,0xFF)
    [void]$client.Send($req1, $req1.Length)

    $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any,0)
    $resp1 = $client.Receive([ref]$remote)
    if (-not $resp1 -or $resp1.Length -lt 9) { return $null }
    if ($resp1[4] -ne 0x41) { return $null }

    $challenge = $resp1[5..8]

    $req2 = $hdr + [byte[]](0x55) + $challenge
    [void]$client.Send($req2, $req2.Length)

    $resp2 = $client.Receive([ref]$remote)
    if (-not $resp2 -or $resp2.Length -lt 6) { return $null }
    if ($resp2[4] -ne 0x44) { return $null }

    $idx = 5
    $numPlayers = [int]$resp2[$idx]; $idx++

    $names = New-Object System.Collections.Generic.List[string]
    for ($i=0; $i -lt $numPlayers; $i++) {
      if ($idx -ge $resp2.Length) { break }
      $idx++
      $nm = Read-NullTerminatedString -buf $resp2 -idx ([ref]$idx)
      if ($idx + 4 -le $resp2.Length) { $idx += 4 } else { break }
      if ($idx + 4 -le $resp2.Length) { $idx += 4 } else { break }
      if (-not [string]::IsNullOrWhiteSpace($nm)) { [void]$names.Add($nm.Trim()) }
    }

    return @($names.ToArray())
  } catch {
    return $null
  } finally { try { if ($client) { $client.Close() } } catch {} }
}

function Detect-QueryPort {
  param([string]$ServerHost,[int[]]$Ports,[int]$TimeoutMs)

  foreach ($p in $Ports) {
    $info = Get-A2SInfo -ServerHost $ServerHost -Port $p -TimeoutMs $TimeoutMs
    if ($info) { return $p }
  }
  return $null
}

function Refresh-RosterTruth {
  param([switch]$Force)

  $now = UtcNowObj

  if (-not $Force -and $script:state.last_roster_refresh_utc) {
    $last = Try-ParseUtc $script:state.last_roster_refresh_utc
    if ($last -and (($now - $last).TotalSeconds -lt [Math]::Max(2,$RosterRefreshSeconds))) {
      return [bool]$script:state.last_a2s_ok
    }
  }

  $portToUse = $null
  if ($AutoDetectQueryPort -and $ResolvedQueryPortCandidates -and $ResolvedQueryPortCandidates.Count -gt 0) {
    $portToUse = Detect-QueryPort -ServerHost $ResolvedHost -Ports $ResolvedQueryPortCandidates -TimeoutMs $A2STimeoutMs
    if ($portToUse) {
      $script:state.active_query_port = [int]$portToUse
    }
  }

  if (-not $portToUse) {
    if ($script:state.active_query_port) {
      $portToUse = [int]$script:state.active_query_port
    } elseif ($ResolvedQueryPort -gt 0) {
      $portToUse = [int]$ResolvedQueryPort
    }
  }

  if (-not $portToUse -or $portToUse -le 0) {
    $script:state.last_roster_refresh_utc = $now.ToString('o')
    $script:state.last_a2s_ok = $false
    $script:state.last_a2s_error = "No query port available."
    Save-State $script:state
    return $false
  }

  $players = Get-A2SPlayers -ServerHost $ResolvedHost -Port $portToUse -TimeoutMs $A2STimeoutMs

  if ($null -eq $players) {
    $script:state.last_roster_refresh_utc = $now.ToString('o')
    $script:state.last_a2s_ok = $false
    $script:state.last_a2s_error = "A2S query failed on ${ResolvedHost}:$portToUse"
    Save-State $script:state
    Write-DebugLine $script:state.last_a2s_error
    return $false
  }

  $newRoster = @{}
  foreach ($n in @($players)) {
    if ([string]::IsNullOrWhiteSpace($n)) { continue }
    $key = "name::$n"
    $newRoster[$key] = [string]$n
  }

  # Preserve SteamID-keyed entries from log parsing so name-learning
  # (ZDOID, Admin found, etc.) can still update the roster later.
  foreach ($kv in $script:activeBySteam.GetEnumerator()) {
    if ($kv.Name -notmatch '^name::') {
      $newRoster[$kv.Name] = $kv.Value
    }
  }

  $script:activeBySteam = $newRoster

  if ($script:activeBySteam.Count -gt 0 -and -not $script:state.online_since_utc) {
    $script:state.online_since_utc = $now.ToString('o')
  }
  if ($script:activeBySteam.Count -eq 0) {
    $script:state.online_since_utc = $null
  }

  $script:state.last_roster_refresh_utc = $now.ToString('o')
  $script:state.last_a2s_ok = $true
  $script:state.last_a2s_error = ''
  $script:state.active_query_port = [int]$portToUse

  Save-Roster $script:activeBySteam
  Save-State $script:state

  return $true
}

# =========================
# LOG PARSING (FALLBACK / NAME LEARNING)
# =========================
function Apply-LogJoin {
  param([string]$Steam, [string]$User, [datetime]$EventTime)

  if ([string]::IsNullOrWhiteSpace($Steam)) { return $false }

  if ([string]::IsNullOrWhiteSpace($User)) { $User = 'Viking' }

  if ($script:KnownNameToSteam.ContainsKey($User)) {
    $script:KnownNameToSteam[$User] = $Steam
  } else {
    $script:KnownNameToSteam.Add($User, $Steam)
  }

  if ($script:KnownSteamToName.ContainsKey($Steam)) {
    $script:KnownSteamToName[$Steam] = $User
  } else {
    $script:KnownSteamToName.Add($Steam, $User)
  }

  $script:activeBySteam[$Steam] = $User
  $script:playerTimestamps[$Steam] = $EventTime
  Save-Roster $script:activeBySteam

  if (-not $script:state.online_since_utc) {
    $script:state.online_since_utc = ($EventTime.ToUniversalTime()).ToString('o')
  }

  $script:state.last_event_utc  = ($EventTime.ToUniversalTime()).ToString('o')
  $script:state.last_event_text = "JOIN • $User"

  $evt = [pscustomobject]@{ type = "join"; username = $User; timestamp = ($EventTime.ToUniversalTime()).ToString('o') }
  $arr = @($script:state.recent_events)
  $script:state.recent_events = @($evt) + $arr | Select-Object -First 10

  Save-State $script:state
  return $true
}

function Apply-LogLeave {
  param([string]$Steam, [datetime]$EventTime)

  $name = ''
  if (-not [string]::IsNullOrWhiteSpace($Steam) -and $script:KnownSteamToName.ContainsKey($Steam)) {
    $name = $script:KnownSteamToName[$Steam]
  }
  if ([string]::IsNullOrWhiteSpace($name)) {
    $name = "Viking"
  }

  $durationStr = ""
  if ($script:playerTimestamps.ContainsKey($Steam)) {
    $durationStr = Format-Duration ($EventTime.ToUniversalTime() - $script:playerTimestamps[$Steam].ToUniversalTime())
    $script:playerTimestamps.Remove($Steam) | Out-Null
  }

  if (-not [string]::IsNullOrWhiteSpace($Steam) -and $script:activeBySteam.ContainsKey($Steam)) {
    $script:activeBySteam.Remove($Steam)
    Save-Roster $script:activeBySteam
  }

  if ($script:activeBySteam.Count -eq 0) {
    $script:state.online_since_utc = $null
  }

  $script:state.last_event_utc  = ($EventTime.ToUniversalTime()).ToString('o')
  $script:state.last_event_text = "LEAVE • $name ($durationStr)"

  $evt = [pscustomobject]@{ type = "leave"; username = $name; timestamp = ($EventTime.ToUniversalTime()).ToString('o'); duration = $durationStr }
  $arr = @($script:state.recent_events)
  $script:state.recent_events = @($evt) + $arr | Select-Object -First 10

  Save-State $script:state
  return $true
}

function Parse-ValheimLogLine {
  param([string]$line)

  if ([string]::IsNullOrWhiteSpace($line)) { return $false }

  $now = Get-Date

  if ($line -match 'Sending ward permission to\s+(?<name>.+?)\((?<steam>\d{16,20})\)') {
    $nm  = $Matches.name.Trim()
    $sid = $Matches.steam.Trim()

    if (-not [string]::IsNullOrWhiteSpace($nm) -and -not [string]::IsNullOrWhiteSpace($sid)) {
      $script:KnownSteamToName[$sid] = $nm
      $script:KnownNameToSteam[$nm] = $sid

      $script:activeBySteam[$sid] = $nm
      Save-Roster $script:activeBySteam

      Write-DebugLine "Name learned: $nm <$sid>"
    }
    return $false
  }

  if ($line -match 'Got character ZDOID from\s+(?<name>.+?)\s*:') {
    $nm = $Matches.name.Trim()

    if (-not [string]::IsNullOrWhiteSpace($nm)) {
      if ($script:PendingJoinSteam) {
        $sid = $script:PendingJoinSteam

        $script:KnownSteamToName[$sid] = $nm
        $script:KnownNameToSteam[$nm]  = $sid

        $script:activeBySteam[$sid] = $nm
        Save-Roster $script:activeBySteam

        $script:state.last_event_utc  = ($now.ToUniversalTime()).ToString('o')
        $script:state.last_event_text = "JOIN • $nm"
        Save-State $script:state

        $script:PendingJoinSteam = $null
        Write-DebugLine "Join name linked: $nm <$sid>"
        return $true
      }

      Write-DebugLine "Character seen without pending join: $nm"
    }

    return $false
  }

  if ($line -match 'Admin found:\s+(?<name>.+?)\s+\(Steam_(?<steam>\d{16,20})\)') {
    $nm  = $Matches.name.Trim()
    $sid = $Matches.steam.Trim()

    if (-not [string]::IsNullOrWhiteSpace($nm) -and -not [string]::IsNullOrWhiteSpace($sid)) {
      $script:KnownSteamToName[$sid] = $nm
      $script:KnownNameToSteam[$nm]  = $sid

      $script:activeBySteam[$sid] = $nm
      Save-Roster $script:activeBySteam

      $script:state.last_event_utc  = ($now.ToUniversalTime()).ToString('o')
      $script:state.last_event_text = "JOIN • $nm"
      Save-State $script:state

      Write-DebugLine "Admin-found name linked: $nm <$sid>"
      return $true
    }

    return $false
  }

  if ($line -match 'Got handshake from client\s+(?<steam>\d{16,20})') {
    $sid = $Matches.steam.Trim()

    if ($script:lastJoinFiredBySteam.ContainsKey($sid)) {
      if ((($now) - $script:lastJoinFiredBySteam[$sid]).TotalSeconds -lt $JoinCooldownSecondsPerSteam) {
        return $false
      }
    }

    $script:lastJoinFiredBySteam[$sid] = $now
    $script:PendingJoinSteam = $sid

    $nm = 'Viking'
    if ($script:KnownSteamToName.ContainsKey($sid)) { $nm = $script:KnownSteamToName[$sid] }

    return (Apply-LogJoin -Steam $sid -User $nm -EventTime $now)
  }

  $leaveSid = ''
  if ($line -match 'Peer\s*\((?<steam>\d{16,20})\)\s*disconnected') {
    $leaveSid = $Matches.steam.Trim()
  } elseif ($line -match 'Closing socket\s+(?<steam>\d{16,20})') {
    $leaveSid = $Matches.steam.Trim()
  }

  if (-not [string]::IsNullOrWhiteSpace($leaveSid)) {
    if ($script:lastLeaveFiredBySteam.ContainsKey($leaveSid)) {
      if ((($now) - $script:lastLeaveFiredBySteam[$leaveSid]).TotalSeconds -lt $LeaveCooldownSecondsPerSteam) {
        return $false
      }
    }

    $script:lastLeaveFiredBySteam[$leaveSid] = $now

    if ($script:PendingJoinSteam -eq $leaveSid) {
      $script:PendingJoinSteam = $null
    }

    return (Apply-LogLeave -Steam $leaveSid -EventTime $now)
  }

  return $false
}

# =========================
# LOG STREAM
# =========================
function Open-LogStreamAt {
  param(
    [string]$Path,
    [int64]$Position
  )

  $fsLocal = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
  if ($Position -gt 0 -and $Position -le $fsLocal.Length) {
    $fsLocal.Seek($Position, [System.IO.SeekOrigin]::Begin) | Out-Null
  } elseif ($Position -gt $fsLocal.Length) {
    $fsLocal.Seek(0, [System.IO.SeekOrigin]::End) | Out-Null
  }
  $srLocal = New-Object System.IO.StreamReader($fsLocal, [System.Text.Encoding]::UTF8, $true)
  return @{ fs = $fsLocal; sr = $srLocal }
}

function Get-FileMeta([string]$Path) {
  $fi = Get-Item -LiteralPath $Path -ErrorAction Stop
  return [pscustomobject]@{
    length = [int64]$fi.Length
    lastwrite_utc = $fi.LastWriteTimeUtc.ToString('o')
  }
}

# =========================
# POST / EDIT
# =========================
function Post-CurrentCard {
  $lastEventUtcText = 'No events yet'
  if ($script:state.last_event_utc) {
    $tmp = Try-ParseUtc $script:state.last_event_utc
    if ($tmp) { $lastEventUtcText = $tmp.ToString('yyyy-MM-dd HH:mm:ss') + ' UTC' }
  }

  $payload = Build-Payload -Roster $script:activeBySteam -LastEventText $script:state.last_event_text -LastEventUtc $lastEventUtcText
  $id = SendOrEdit $payload
  if ($id) { Set-Content -Path $LastIdFile -Value $id -Encoding UTF8 }

  $script:state.last_pulse_utc = (UtcNowObj).ToString('o')
  Save-State $script:state
}

function Pulse-Due {
  if ($PulseMinutes -le 0) { return $true }
  if (-not $script:state.last_pulse_utc) { return $true }

  $last = Try-ParseUtc $script:state.last_pulse_utc
  if (-not $last) { return $true }

  return (((UtcNowObj) - $last).TotalSeconds -ge ($PulseMinutes * 60))
}

# =========================
# OPTIONAL BOOTSTRAP
# =========================
function Bootstrap-FromLog {
  if ([string]::IsNullOrWhiteSpace($ResolvedLogPath)) { return }
  if (-not (Test-Path -LiteralPath $ResolvedLogPath)) { return }
  if ($BootstrapLines -le 0) { return }

  try {
    Write-DebugLine "Bootstrap: reading last $BootstrapLines lines from $ResolvedLogPath"
    $lines = Get-Content -LiteralPath $ResolvedLogPath -Tail $BootstrapLines -Encoding UTF8 -ErrorAction Stop
    foreach ($l in $lines) {
      Parse-ValheimLogLine -line $l | Out-Null
    }
  } catch {
    Write-DebugLine "Bootstrap failed: $($_.Exception.Message)"
  }
}

# =========================
# INITIAL SETUP
# =========================
$cursor = Load-Cursor
$WatchedLog = $null
$fs = $null
$sr = $null

if (-not [string]::IsNullOrWhiteSpace($ResolvedLogPath) -and (Test-Path -LiteralPath $ResolvedLogPath)) {
  $WatchedLog = (Resolve-Path -LiteralPath $ResolvedLogPath).Path

  $fileMeta = Get-FileMeta -Path $WatchedLog
  $startPos = 0

  if ($cursor.path -eq $WatchedLog -and $cursor.position -ge 0) {
    if ($fileMeta.length -ge $cursor.position) {
      $startPos = [int64]$cursor.position
    }
  }

  if (-not $RunOnce -and $startPos -eq 0) {
    $startPos = $fileMeta.length
  }

  $stream = Open-LogStreamAt -Path $WatchedLog -Position $startPos
  $fs = $stream.fs
  $sr = $stream.sr

  $cursor.path = $WatchedLog
  $cursor.position = $startPos
  $cursor.length = $fileMeta.length
  $cursor.lastwrite_utc = $fileMeta.lastwrite_utc
  Save-Cursor $cursor

  $script:state.watch_log = $WatchedLog
  $script:state.watch_log_length = $fileMeta.length
  $script:state.watch_log_lastwrite_utc = $fileMeta.lastwrite_utc
  Save-State $script:state
}

Bootstrap-FromLog | Out-Null
[void](Refresh-RosterTruth -Force)

Write-DebugLine "Script start for $ServerKey. RunOnce=$($RunOnce.IsPresent)"
Write-DebugLine "ResolvedHost=$ResolvedHost"
Write-DebugLine "WatchedLog=$WatchedLog"

if ($RunOnce) {
  Post-CurrentCard
  try { if ($sr) { $sr.Close() } } catch {}
  try { if ($fs) { $fs.Close() } } catch {}
  return
}

Write-Host "QuestPauseOps Valheim presence watcher started for $ServerKey"
Write-Host "Host=$ResolvedHost"
Write-Host "QueryPort=$ResolvedQueryPort"
Write-Host "Candidates=$($ResolvedQueryPortCandidates -join ',')"
Write-Host "WatchedLog=$WatchedLog"
Write-Host "StateDir=$StateDir"
Write-Host "ConfigPath=$ConfigPath"
Write-Host "DebugLog=$DebugLog"

try {
  Post-CurrentCard

  while ($true) {
    $changed = $false
    [DateTime]::UtcNow.ToString('o') | Set-Content (Join-Path $OpsRoot "state\$ServerKey\presence_heartbeat.txt") -Encoding UTF8

    try {
      $a2sWasOk = [bool]$script:state.last_a2s_ok
      [void](Refresh-RosterTruth)
      if ([bool]$script:state.last_a2s_ok -ne $a2sWasOk) { $changed = $true }

      if ($WatchedLog -and $sr -and $fs) {
        $metaNow = Get-FileMeta -Path $WatchedLog

        if ($metaNow.length -lt $cursor.position) {
          Write-DebugLine "Log rotated or truncated. Reopening from start."
          try { $sr.Close() } catch {}
          try { $fs.Close() } catch {}

          $stream = Open-LogStreamAt -Path $WatchedLog -Position 0
          $fs = $stream.fs
          $sr = $stream.sr
          $cursor.position = 0
        }

        while (-not $sr.EndOfStream) {
          $line = $sr.ReadLine()
          $cursor.position = $fs.Position
          if (Parse-ValheimLogLine -line $line) {
            $changed = $true
          }
        }

        $cursor.path = $WatchedLog
        $cursor.length = $metaNow.length
        $cursor.lastwrite_utc = $metaNow.lastwrite_utc
        Save-Cursor $cursor

        $script:state.watch_log = $WatchedLog
        $script:state.watch_log_length = $metaNow.length
        $script:state.watch_log_lastwrite_utc = $metaNow.lastwrite_utc
        Save-State $script:state
      }

      if ($script:activeBySteam.Count -gt 0 -and -not $script:state.online_since_utc) {
        $script:state.online_since_utc = (UtcNowObj).ToString('o')
        Save-State $script:state
        $changed = $true
      } elseif ($script:activeBySteam.Count -eq 0 -and $script:state.online_since_utc) {
        $script:state.online_since_utc = $null
        Save-State $script:state
        $changed = $true
      }

      if ($changed -or (Pulse-Due)) {
        Post-CurrentCard
      }

    } catch {
      Write-DebugLine "LOOP ERROR: $($_.Exception.Message)"
      Write-Host "[LOOP ERROR] $($_.Exception.Message)" -ForegroundColor DarkYellow
    }

    Start-Sleep -Seconds (Clamp $PollSeconds 1 10)
  }
}
finally {
  try { if ($sr) { $sr.Close() } } catch {}
  try { if ($fs) { $fs.Close() } } catch {}
}

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$ServerKey,

  [switch]$RunOnce,

  [int]$PollMs = 500,
  [int]$PulseMinutes = 1,
  [int]$SteamIdCooldownSeconds = 45,
  [int]$StaleMinutes = 5,

  # Optional overrides
  [string]$LogDir = '',
  [string]$ConsoleLog = '',
  [string]$LogFile = '',
  [string]$WebhookUrl = '',
  [string]$WorldName = '',
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
  C:\QuestPauseOps\scripts\presence\pz_currently_on_server.ps1
  QUESTPAUSEOPS — Project Zomboid Presence Card

  What it does:
  - Loads C:\QuestPauseOps\config\servers.json
  - Uses -ServerKey to target ONE PZ server
  - Watches PZ console/debug log
  - Tracks survivor join/leave from log events
  - Maintains one live Discord card edited in place
  - Stores per-server state in C:\QuestPauseOps\state\<ServerKey>\
  - Stores debug logs in C:\QuestPauseOps\logs\presence\

  Notes:
  - This is a PRESENCE script (player truth), not a server health script
  - Best-effort log parsing for PZ connection events
#>

# =========================
# UTF-8 / PowerShell 5.1 safe
# =========================
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
[Console]::InputEncoding  = New-Object System.Text.UTF8Encoding($false)
$PSDefaultParameterValues['*:Encoding'] = 'utf8'

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$PSDefaultParameterValues['Invoke-RestMethod:TimeoutSec'] = 15

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# =========================
# ROOT / PATHS
# =========================
$OpsRoot    = $script:QPRoot
$ConfigPath = Join-Path $OpsRoot 'config\servers.json'
$LibPath    = Join-Path $OpsRoot 'lib\QuestPause.Ops.psm1'
$LogsDir    = Join-Path $OpsRoot 'logs\presence'
$StateDir   = Join-Path $OpsRoot ("state\" + $ServerKey)

$StateFile      = Join-Path $StateDir 'pz_presence_state.json'
$DebugLog       = Join-Path $LogsDir  ("{0}_pz_currently_on_server.log" -f $ServerKey)
$LastIdFile     = Join-Path $StateDir 'pz_presence_last_message_id.txt'
$RosterCache    = Join-Path $StateDir 'pz_presence_roster.json'
$CursorFile     = Join-Path $StateDir 'pz_presence_cursor.json'
$MappingFile    = Join-Path $OpsRoot  'scripts\presence\player_mapping.json'

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

function Get-FirstValue {
  param($Primary, $Fallback)
  if ($null -ne $Primary -and "$Primary".Trim() -ne '') { return $Primary }
  return $Fallback
}

$WorldNameFallback = 'Project Zomboid World'
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
  $ResolvedMaxPlayers = 32
}

$LogDirFallback = ''
if ($server.logDir) {
  $LogDirFallback = $server.logDir
}
$ResolvedLogDir = Get-FirstValue $LogDir $LogDirFallback

$ConsoleLogFallback = ''
if ($server.consoleLog) {
  $ConsoleLogFallback = $server.consoleLog
}
$ResolvedConsoleLog = Get-FirstValue $ConsoleLog $ConsoleLogFallback

$LogFileFallback = ''
if ($server.logFile) {
  $LogFileFallback = $server.logFile
}
$ResolvedLogFile = Get-FirstValue $LogFile $LogFileFallback

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

Write-DebugLine "Resolved config for $ServerKey"
Write-DebugLine "ConfigPath=$ConfigPath"
Write-DebugLine "WorldName=$ResolvedWorldName"
Write-DebugLine "MaxPlayers=$ResolvedMaxPlayers"
Write-DebugLine "LogDir=$ResolvedLogDir"
Write-DebugLine "ConsoleLog=$ResolvedConsoleLog"
Write-DebugLine "LogFile=$ResolvedLogFile"

# Resolve heartbeat log directory for stale detection
# PZ continuously writes *_cmd.txt and *_item.txt, but main log only flushes on connections
$HeartbeatDir = $null
if ($ResolvedLogDir -and (Test-Path -LiteralPath $ResolvedLogDir)) {
  try {
    $HeartbeatDir = (Resolve-Path -LiteralPath $ResolvedLogDir -ErrorAction Stop).Path
    Write-DebugLine "HeartbeatDir=$HeartbeatDir"
  } catch {
    Write-DebugLine "HeartbeatDir resolution failed: $($_.Exception.Message)"
  }
}

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

function Try-GetLogDate {
  param([string]$Line)
  if ($Line -match '\[(?<dt>\d{2}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})\]') {
    try {
      return [datetime]::ParseExact($Matches.dt, "dd-MM-yy HH:mm:ss.fff", [System.Globalization.CultureInfo]::InvariantCulture)
    } catch { return $null }
  }
  return $null
}

function Resolve-WatchLog {
  param([string]$ConsoleLog, [string]$LogDir, [string]$LogFile)

  if (-not [string]::IsNullOrWhiteSpace($LogFile)) {
    if (Test-Path -LiteralPath $LogFile) { return (Resolve-Path -LiteralPath $LogFile).Path }
    throw "LogFile not found: $LogFile"
  }

  if (-not [string]::IsNullOrWhiteSpace($ConsoleLog)) {
    if (Test-Path -LiteralPath $ConsoleLog) {
      return (Resolve-Path -LiteralPath $ConsoleLog).Path
    }
  }

  if ([string]::IsNullOrWhiteSpace($LogDir)) {
    throw "LogDir is empty. Set servers.$ServerKey.logDir or pass -LogDir."
  }

  if (-not (Test-Path -LiteralPath $LogDir)) {
    throw "LogDir not found: $LogDir"
  }

  $dbg = Get-ChildItem -LiteralPath $LogDir -File -ErrorAction Stop |
    Where-Object { $_.Name -match 'DebugLog-server\.txt$' -and $_.Length -gt 0 } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

  if ($dbg) { return $dbg.FullName }

  throw "No suitable log file found. ConsoleLog missing and no DebugLog-server.txt in $LogDir"
}

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
  Ensure-Prop $s 'watch_log' $null
  Ensure-Prop $s 'watch_log_length' 0
  Ensure-Prop $s 'watch_log_lastwrite_utc' $null
  Ensure-Prop $s 'online_since_utc' $null
  Ensure-Prop $s 'recent_events' @()

  return $s
}

function Save-State($s) {
  ($s | ConvertTo-Json -Depth 10) | Set-Content -Path $StateFile -Encoding UTF8
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

$state = Load-State
$activeBySteam = Load-Roster
$lastSent = @{}

$playerTimestamps = @{}

if ($activeBySteam.Count -gt 0 -and -not $state.online_since_utc) {
  $state.online_since_utc = (UtcNowObj).ToString('o')
}

function InCooldown {
  param([string]$SteamId, [string]$Type, [datetime]$Now)

  if (-not $SteamId) { return $false }
  if (-not $lastSent.ContainsKey($SteamId)) { return $false }
  if (-not $lastSent[$SteamId].ContainsKey($Type)) { return $false }

  $prev = $lastSent[$SteamId][$Type]
  if (-not $prev -or $prev -isnot [datetime]) { return $false }

  return (( $Now - $prev ).TotalSeconds -lt $SteamIdCooldownSeconds)
}

function MarkSent {
  param([string]$SteamId, [string]$Type, [datetime]$Now)
  if (-not $SteamId) { return }
  if (-not $lastSent.ContainsKey($SteamId)) { $lastSent[$SteamId] = @{} }
  $lastSent[$SteamId][$Type] = $Now
}

# =========================
# EMBED CONTENT
# =========================
$PzTips = @(
  "Start with one safehouse, not a whole neighborhood.",
  "Short loot runs beat greedy loot runs.",
  "Always keep a retreat path before committing to a fight.",
  "Fight in open space whenever possible.",
  "Doors, corners, and fences decide who survives.",
  "Exhaustion kills runs faster than empty backpacks.",
  "If visibility is bad, your plan should get simpler, not bolder.",
  "A parked car facing out is half an escape plan.",
  "A safehouse matters more than one extra bag of loot.",
  "Never enter a building without thinking about the exit first.",
  "If a house alarm triggers, leave the area fast.",
  "Push and reposition beats panic swinging.",
  "One bandage is not a medical plan.",
  "Keep food, water, and a backup weapon at base.",
  "A heavy inventory is a slow death in the wrong fight.",
  "Night looting is riskier than it feels.",
  "If your character is tired, end the run early.",
  "Broken line of sight saves more lives than brute force.",
  "Cars are escape tools first, storage second.",
  "Do not fight next to windows or door frames if you can avoid it.",
  "A second floor with sheets can become an emergency exit.",
  "You do not need every item in the building.",
  "Clear your immediate perimeter before sorting loot.",
  "A clean fallback route matters more than one extra kill.",
  "Sound discipline matters: sprinting and smashing attract problems.",
  "Carry only what supports survival, not what feeds greed.",
  "Separate essentials in your bag so panic looting stays organized.",
  "A good run ends before the situation feels dangerous.",
  "Treat every blind corner like something is waiting there.",
  "If the horde grows, stop winning and start escaping."
)

function Pick-PzTip {
  return ($PzTips | Get-Random)
}

function Get-DiscordName {
  param([string]$SteamId, [string]$FallbackName)
  if (Test-Path $MappingFile) {
    try {
      $mapping = Get-Content $MappingFile -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($mapping.PSObject.Properties[$SteamId]) {
        return $mapping.$SteamId
      }
    } catch {
      Write-DebugLine "Failed to parse player_mapping.json: $($_.Exception.Message)"
    }
  }
  return $FallbackName
}

function Get-RosterLines {
  param([hashtable]$Roster, [int]$OnlineCount, [int]$MaxPlayers)

  if (-not $Roster -or $Roster.Count -eq 0) {
    return "No survivors currently detected."
  }

  $header = "**Online: {0}**" -f (Format-OnlineLine -Online $OnlineCount -Max $MaxPlayers)
  $lines = @($header, "")
  $sortedKeys = $Roster.Keys | Sort-Object { $Roster[$_] }
  foreach ($steamId in $sortedKeys) {
    $inGameName = $Roster[$steamId]
    $discordName = Get-DiscordName -SteamId $steamId -FallbackName ""
    
    if ($discordName) {
      $lines += "• **$inGameName** (@$discordName)"
    } else {
      $lines += "• $inGameName"
    }
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
  $presenceState = if ($onlineCount -gt 0) { "🟢 Survivors detected" } else { "⚫ Quiet perimeter" }
  $onlineLine = Format-OnlineLine -Online $onlineCount -Max $ResolvedMaxPlayers
  $rosterLines = Get-RosterLines -Roster $Roster -OnlineCount $onlineCount -MaxPlayers $ResolvedMaxPlayers

  $uptimeText = "No survivors online"
  if ($onlineCount -gt 0) {
    $since = Try-ParseUtc $state.online_since_utc
    if ($since) { $uptimeText = Format-Duration ((UtcNowObj) - $since) }
    else { $uptimeText = "Online" }
  }

  $pulseUtc = (Get-Date).ToUniversalTime().ToString('HH:mm')
  $color = if ($onlineCount -gt 0) { 0x2ECC71 } else { 0x95A5A6 }

  $desc = @(
    "**Project Zomboid survivor presence**",
    "",
    $presenceState,
    "",
    "Live survivor roster tracked from server log events.",
    "Times in **UTC**."
  ) -join "`n"

  return [ordered]@{
    content = ""
    embeds = @(
      [ordered]@{
        title       = "PZ Currently On Server"
        description = $desc
        color       = $color
        fields      = @(
          @{ name = "🧭 World"; value = $ResolvedWorldName; inline = $false },
          @{ name = "🧩 ServerKey"; value = $ServerKey; inline = $true },
          @{ name = "👥 Online"; value = $onlineLine; inline = $true },
          @{ name = "📡 Presence"; value = $presenceState; inline = $true },
          @{ name = "🕒 Online since"; value = $uptimeText; inline = $true },
          @{ name = "🧟 Survivors"; value = $rosterLines; inline = $false },
          @{ name = "Last event (UTC)"; value = $LastEventUtc; inline = $false },
          @{ name = "📝 Last event"; value = $LastEventText; inline = $false },
          @{ name = "🔄 Recent Activity"; value = (Format-RecentEvents $state.recent_events); inline = $false },
          @{ name = "💡 Field Tip"; value = (Pick-PzTip); inline = $false }
        )
        footer    = @{ text = "QUESTPAUSE • Project Zomboid • $ServerKey • Pulse $pulseUtc UTC" }
        timestamp = (Get-Date).ToUniversalTime().ToString('o')
      }
    )
    allowed_mentions = @{ parse = @() }
  }
}

# =========================
# LOG PARSING
# =========================
function Apply-Join {
  param([string]$Steam, [string]$User, [datetime]$EventTime, [string]$EventName)

  if ([string]::IsNullOrWhiteSpace($Steam) -or [string]::IsNullOrWhiteSpace($User)) { return $false }

  $alreadyOnline = $activeBySteam.ContainsKey($Steam)
  $activeBySteam[$Steam] = $User
  $playerTimestamps[$Steam] = $EventTime

  if (-not $alreadyOnline) {
    if ($activeBySteam.Count -eq 1) {
      $state.online_since_utc = ($EventTime.ToUniversalTime()).ToString('o')
    }
    $state.last_event_utc  = ($EventTime.ToUniversalTime()).ToString('o')
    $state.last_event_text = "JOIN • $User • $EventName"

    # Push to recent activity
    $evt = [pscustomobject]@{ type = "join"; username = $User; timestamp = ($EventTime.ToUniversalTime()).ToString('o') }
    $arr = @($state.recent_events)
    $state.recent_events = @($evt) + $arr | Select-Object -First 10

    Save-Roster $activeBySteam
    Save-State $state
    return $true
  }

  return $false
}

function Apply-Leave {
  param([string]$Steam, [string]$User, [datetime]$EventTime, [string]$Reason)

  if ([string]::IsNullOrWhiteSpace($Steam)) { return $false }

  $name = $User
  if ([string]::IsNullOrWhiteSpace($name) -and $activeBySteam.ContainsKey($Steam)) {
    $name = $activeBySteam[$Steam]
  }
  if ([string]::IsNullOrWhiteSpace($name)) {
    $name = "Unknown survivor"
  }

  # Calculate session duration
  $durationStr = ""
  if ($playerTimestamps.ContainsKey($Steam)) {
    $durationStr = Format-Duration ($EventTime.ToUniversalTime() - $playerTimestamps[$Steam].ToUniversalTime())
    $playerTimestamps.Remove($Steam) | Out-Null
  }

  $removed = $false
  if ($activeBySteam.ContainsKey($Steam)) {
    $activeBySteam.Remove($Steam) | Out-Null
    $removed = $true
  }

  if ($removed) {
    if ($activeBySteam.Count -eq 0) {
      $state.online_since_utc = $null
    }
    $state.last_event_utc  = ($EventTime.ToUniversalTime()).ToString('o')
    $state.last_event_text = "LEAVE • $name • $Reason ($durationStr)"

    # Push to recent activity
    $evt = [pscustomobject]@{ type = "leave"; username = $name; timestamp = ($EventTime.ToUniversalTime()).ToString('o'); duration = $durationStr }
    $arr = @($state.recent_events)
    $state.recent_events = @($evt) + $arr | Select-Object -First 10

    Save-Roster $activeBySteam
    Save-State $state
    return $true
  }

  return $false
}

function Parse-Line {
  param([string]$line)

  if ([string]::IsNullOrWhiteSpace($line)) { return $false }

  $logDt = Try-GetLogDate -Line $line
  if (-not $logDt) { $logDt = [datetime]::Now }

  $isJoin = $false
  $joinEvent = $null
  $steam = $null
  $user = $null

  if ($line -match 'ConnectionManager:.*"(?<evt>client-connect|login-queue-done|player-connect)".*steam-id=(?<steam>\d+).*username="(?<user>[^"]+)"') {
    $joinEvent = $Matches.evt
    $steam = $Matches.steam
    $user  = $Matches.user
    $isJoin = $true
  }
  elseif ($line -match 'ConnectionManager:.*\[fully-connected\].*steam-id=(?<steam>\d+).*username="(?<user>[^"]+)"') {
    $joinEvent = 'fully-connected'
    $steam = $Matches.steam
    $user  = $Matches.user
    $isJoin = $true
  }
  elseif ($line -match 'ConnectionManager:.*\("(?<evt>[^"]+)"\).*user="(?<user>[^"]+)".*id=(?<steam>\d+)') {
    $joinEvent = $Matches.evt
    $steam = $Matches.steam
    $user  = $Matches.user
    $isJoin = $true
  }
  elseif ($line -match 'General\s+ConnectionManager:\s+(?<evt>connected|disconnected)\s+user\s+(?<user>\S+)\s+id\s+(?<steam>\d+)') {
    $joinEvent = $Matches.evt
    $steam = $Matches.steam
    $user  = $Matches.user
    $isJoin = ($joinEvent -eq 'connected')
  }

  if ($isJoin) {
    if (-not (InCooldown -SteamId $steam -Type 'join' -Now $logDt)) {
      $changed = Apply-Join -Steam $steam -User $user -EventTime $logDt -EventName $joinEvent
      MarkSent -SteamId $steam -Type 'join' -Now $logDt
      return $changed
    }
    return $false
  }

  if ($line -match 'ConnectionManager:.*"(?<evt>receive-disconnect|connection-lost|disconnection-notification)".*steam-id=(?<steam>\d+).*username="(?<user>[^"]+)"') {
    $reason = $Matches.evt
    $steam  = $Matches.steam
    $user   = $Matches.user

    if (InCooldown -SteamId $steam -Type 'leave' -Now $logDt) { return $false }

    $changed = Apply-Leave -Steam $steam -User $user -EventTime $logDt -Reason $reason
    MarkSent -SteamId $steam -Type 'leave' -Now $logDt
    return $changed
  }

  # Alternative disconnect formats
  if ($line -match 'ConnectionManager:.*"(?<evt>receive-disconnect|connection-lost|disconnection-notification)".*user="(?<user>[^"]+)".*id=(?<steam>\d+)') {
    $reason = $Matches.evt
    $steam  = $Matches.steam
    $user   = $Matches.user
    if (-not (InCooldown -SteamId $steam -Type 'leave' -Now $logDt)) {
      $changed = Apply-Leave -Steam $steam -User $user -EventTime $logDt -Reason $reason
      MarkSent -SteamId $steam -Type 'leave' -Now $logDt
      return $changed
    }
    return $false
  }

  if ($line -match '(?<evt>QUIT|DISCONNECT)\s+user\s+(?<user>\S+)\s+id\s+(?<steam>\d+)') {
    $reason = $Matches.evt
    $steam  = $Matches.steam
    $user   = $Matches.user
    if (-not (InCooldown -SteamId $steam -Type 'leave' -Now $logDt)) {
      $changed = Apply-Leave -Steam $steam -User $user -EventTime $logDt -Reason $reason
      MarkSent -SteamId $steam -Type 'leave' -Now $logDt
      return $changed
    }
    return $false
  }

  return $false
}

# =========================
# CURSOR / FILE REOPEN
# =========================
function Get-FileMeta([string]$Path) {
  $fi = Get-Item -LiteralPath $Path -ErrorAction Stop
  return [pscustomobject]@{
    length = [int64]$fi.Length
    lastwrite_utc = $fi.LastWriteTimeUtc.ToString('o')
  }
}

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

function Get-A2SPlayerCount {
  $hostAddr = $server.host
  $qPort = if ($server.queryPort) { [int]$server.queryPort } else { 0 }
  if ([string]::IsNullOrWhiteSpace($hostAddr) -or $qPort -le 0) { return -1 }
  try {
    $endpoint = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($hostAddr), $qPort)
    $udp = New-Object System.Net.Sockets.UdpClient
    $udp.Client.ReceiveTimeout = 2000
    $req = [byte[]](0xFF,0xFF,0xFF,0xFF,0x54) + ([System.Text.Encoding]::ASCII.GetBytes("Source Engine Query")) + 0x00
    [void]$udp.Send($req, $req.Length, $endpoint)
    $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
    $resp = $udp.Receive([ref]$remote)
    if ($resp[4] -eq 0x41) {
      $challenge = $resp[5..8]
      $req2 = $req + $challenge
      [void]$udp.Send($req2, $req2.Length, $endpoint)
      $resp = $udp.Receive([ref]$remote)
    }
    if ($resp[4] -ne 0x49) { $udp.Close(); return -1 }
    $i = 5; $ri = [ref]$i
    $ri.Value++
    for ($skip = 0; $skip -lt 4; $skip++) { while ($ri.Value -lt $resp.Length -and $resp[$ri.Value] -ne 0) { $ri.Value++ }; $ri.Value++ }
    $ri.Value += 2
    $players = [int]$resp[$ri.Value]
    $udp.Close()
    return $players
  }
  catch { return -1 }
}

$WatchedLog = Resolve-WatchLog -ConsoleLog $ResolvedConsoleLog -LogDir $ResolvedLogDir -LogFile $ResolvedLogFile
$state.watch_log = $WatchedLog

$fileMeta = Get-FileMeta -Path $WatchedLog
$cursor = Load-Cursor

$startPos = 0
if ($cursor.path -eq $WatchedLog -and $cursor.position -ge 0) {
  if ($fileMeta.length -ge $cursor.position) {
    $startPos = [int64]$cursor.position
  }
}

if ($startPos -eq 0 -and ($null -ne $cursor.path -and $cursor.path -ne "" -and $cursor.path -ne $WatchedLog)) {
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

$state.watch_log = $WatchedLog
$state.watch_log_length = $fileMeta.length
$state.watch_log_lastwrite_utc = $fileMeta.lastwrite_utc
Save-State $state

# =========================
# POST / EDIT
# =========================
function Post-CurrentCard {
  $lastEventUtcText = 'No events yet'
  if ($state.last_event_utc) {
    $tmp = Try-ParseUtc $state.last_event_utc
    if ($tmp) { $lastEventUtcText = $tmp.ToString('yyyy-MM-dd HH:mm:ss') + ' UTC' }
  }

  $payload = Build-Payload -Roster $activeBySteam -LastEventText $state.last_event_text -LastEventUtc $lastEventUtcText
  $id = SendOrEdit $payload
  if ($id) { Set-Content -Path $LastIdFile -Value $id -Encoding UTF8 }

  $state.last_pulse_utc = (UtcNowObj).ToString('o')
  Save-State $state
}

function Pulse-Due {
  if ($PulseMinutes -le 0) { return $true }
  if (-not $state.last_pulse_utc) { return $true }

  $last = Try-ParseUtc $state.last_pulse_utc
  if (-not $last) { return $true }

  return (((UtcNowObj) - $last).TotalSeconds -ge ($PulseMinutes * 60))
}

Write-DebugLine "Script start for $ServerKey. RunOnce=$($RunOnce.IsPresent)"
Write-DebugLine "Watching log: $WatchedLog"

if ($RunOnce) {
  Post-CurrentCard
  try { $sr.Close() } catch {}
  try { $fs.Close() } catch {}
  return
}

Write-DebugLine "QuestPauseOps PZ presence watcher started for $ServerKey"
Write-DebugLine "WatchedLog=$WatchedLog"
Write-DebugLine "StateDir=$StateDir"
Write-DebugLine "ConfigPath=$ConfigPath"
Write-DebugLine "DebugLog=$DebugLog"

# Reopen log stream to ensure clean handles before entering loop
try { $sr.Close() } catch {}
try { $fs.Close() } catch {}
if ($WatchedLog -and (Test-Path -LiteralPath $WatchedLog)) {
  $stream = Open-LogStreamAt -Path $WatchedLog -Position $cursor.position
  $fs = $stream.fs
  $sr = $stream.sr
}

# One-time A2S safeguard: if A2S shows more players than the roster, rescan
# from position 0 to pick up join events the cursor may have skipped
$a2sInitial = Get-A2SPlayerCount
if ($a2sInitial -gt $activeBySteam.Count) {
  Write-DebugLine "A2S shows $a2sInitial players but roster has $($activeBySteam.Count). Rescanning from position 0."
  try { $sr.Close() } catch {}
  try { $fs.Close() } catch {}
  $cursor.position = 0
  $stream = Open-LogStreamAt -Path $WatchedLog -Position 0
  $fs = $stream.fs
  $sr = $stream.sr
  Save-Cursor $cursor
  # Read through the entire file to backfill join events
  while (-not $sr.EndOfStream) {
    $line = $sr.ReadLine()
    $cursor.position = $fs.Position
    [void](Parse-Line -line $line)
  }
  Save-Roster $activeBySteam
  Save-State $state
  Write-DebugLine "Rescan complete. Roster now has $($activeBySteam.Count) player(s)."
}

try {
  while ($true) {
    $changed = $false
    [DateTime]::UtcNow.ToString('o') | Set-Content (Join-Path $OpsRoot "state\$ServerKey\presence_heartbeat.txt") -Encoding UTF8

    try {
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
        if (Parse-Line -line $line) {
          $changed = $true
        }
      }

      $cursor.path = $WatchedLog
      $cursor.length = $metaNow.length
      $cursor.lastwrite_utc = $metaNow.lastwrite_utc
      Save-Cursor $cursor

      $state.watch_log = $WatchedLog
      $state.watch_log_length = $metaNow.length
      $state.watch_log_lastwrite_utc = $metaNow.lastwrite_utc
      Save-State $state

      $staleCutoff = (UtcNowObj).AddMinutes(-$StaleMinutes)
      $lastWrite = Try-ParseUtc $metaNow.lastwrite_utc

      # Prefer heartbeat file (cmd.txt updates continuously) over main log (only on connections)
      $hbLastWrite = $null
      if ($HeartbeatDir) {
        try {
          $hbFile = Get-ChildItem -LiteralPath $HeartbeatDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '_cmd\.txt$' -and $_.Length -gt 0 } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
          if ($hbFile) {
            $hbLastWrite = $hbFile.LastWriteTime.ToUniversalTime()
            if ($null -eq $lastWrite -or $hbLastWrite -gt $lastWrite) {
              $lastWrite = $hbLastWrite
            }
          }
        } catch {
          Write-DebugLine "Heartbeat file check failed: $($_.Exception.Message)"
        }
      }

      if ($lastWrite -and $lastWrite -lt $staleCutoff -and $activeBySteam.Count -gt 0) {
        $a2sCount = Get-A2SPlayerCount
        if ($a2sCount -ge 0) {
          Write-DebugLine "Stale log (>${StaleMinutes}m) but A2S responds (players=$a2sCount). Keeping roster."
        } else {
          Write-DebugLine "Server offline (log stale > ${StaleMinutes}m, A2S: $a2sCount). Clearing $($activeBySteam.Count) stale player(s)."
          $activeBySteam.Clear()
          $state.online_since_utc = $null
          $state.last_event_utc = (UtcNowObj).ToString('o')
          $state.last_event_text = "SERVER OFFLINE • Log stale — roster cleared"
          Save-Roster $activeBySteam
          Save-State $state
          $changed = $true
        }
      }

      if ($changed -or (Pulse-Due)) {
        Post-CurrentCard
      }

    } catch {
      Write-DebugLine "LOOP ERROR: $($_.Exception.Message)"
    }

    Start-Sleep -Milliseconds $PollMs
  }
}
finally {
  try { $sr.Close() } catch {}
  try { $fs.Close() } catch {}
}

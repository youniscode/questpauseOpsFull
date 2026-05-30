[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$ServerKey,

  [switch]$RunOnce,

  [int]$PollMs = 500,
  [int]$PulseMinutes = 1,
  [int]$SessionStaleSeconds = 1800,
  [int]$SteamIdCooldownSeconds = 45,

  # Windrose-specific: keep disabled unless you really want timeout cleanup
  [switch]$DisableStaleRemoval = $true,

  # Optional overrides
  [string]$LogDir = '',
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
  C:\QuestPauseOps\scripts\presence\windrose_currently_on_server.ps1
  QUESTPAUSEOPS — Windrose Presence Card

  What it does:
  - Loads C:\QuestPauseOps\config\servers.json
  - Uses -ServerKey to target ONE Windrose server
  - Watches Windrose log
  - Tracks active player sessions from Windrose account/session lines
  - Reconciles roster from Windrose account dump blocks
  - Maintains one live Discord card edited in place
  - Stores per-server state in C:\QuestPauseOps\state\<ServerKey>\
  - Stores debug logs in C:\QuestPauseOps\logs\presence\

  Notes:
  - This is a PRESENCE script, not a server health script
  - Windrose logs are sparse and not perfectly event-driven
  - This script supports:
      1) explicit account-state join lines
      2) explicit disconnect/leave lines
      3) snapshot reconciliation from account dump blocks
      4) optional stale removal if you ever want it
#>

[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
[Console]::InputEncoding  = New-Object System.Text.UTF8Encoding($false)
$PSDefaultParameterValues['*:Encoding'] = 'utf8'

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$OpsRoot    = $script:QPRoot
$ConfigPath = Join-Path $OpsRoot 'config\servers.json'
$LibPath    = Join-Path $OpsRoot 'lib\QuestPause.Ops.psm1'
$LogsDir    = Join-Path $OpsRoot 'logs\presence'
$StateDir   = Join-Path $OpsRoot ("state\" + $ServerKey)

$StateFile      = Join-Path $StateDir 'windrose_presence_state.json'
$DebugLog       = Join-Path $LogsDir  ("{0}_windrose_currently_on_server.log" -f $ServerKey)
$LastIdFile     = Join-Path $StateDir 'windrose_presence_last_message_id.txt'
$RosterCache    = Join-Path $StateDir 'windrose_presence_roster.json'
$CursorFile     = Join-Path $StateDir 'windrose_presence_cursor.json'

function Ensure-Dir([string]$Path) {
  if (-not (Test-Path $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

Ensure-Dir $LogsDir
Ensure-Dir $StateDir

function Write-DebugLine([string]$Line) {
  $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  "$ts  $Line" | Add-Content -Path $DebugLog -Encoding UTF8
}

if (Test-Path $LibPath) {
  try {
    Import-Module $LibPath -Force -ErrorAction Stop 3>$null
    Write-DebugLine "Imported module: $LibPath"
  } catch {
    Write-DebugLine "Module import failed: $($_.Exception.Message)"
  }
}

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

$LogDirFallback = ''
if ($server.logDir) { $LogDirFallback = $server.logDir }
$ResolvedLogDir = Get-FirstValue $LogDir $LogDirFallback

$LogFileFallback = ''
if ($server.logFile) {
  $LogFileFallback = $server.logFile
} elseif ($server.logPath) {
  $LogFileFallback = $server.logPath
}
$ResolvedLogFile = Get-FirstValue $LogFile $LogFileFallback

$ServerDescriptionPath = ''
if ($server.serverDescriptionPath) { $ServerDescriptionPath = [string]$server.serverDescriptionPath }

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
Write-DebugLine "LogFile=$ResolvedLogFile"
Write-DebugLine "ServerDescriptionPath=$ServerDescriptionPath"
Write-DebugLine "DisableStaleRemoval=$($DisableStaleRemoval.IsPresent)"
Write-DebugLine "SessionStaleSeconds=$SessionStaleSeconds"

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

function Try-GetWindroseDate {
  param([string]$Line)
  if ($Line -match '\[(?<dt>\d{4}\.\d{2}\.\d{2}-\d{2}\.\d{2}\.\d{2}:\d{3})\]') {
    try {
      return [datetime]::ParseExact(
        $Matches.dt,
        "yyyy.MM.dd-HH.mm.ss:fff",
        [System.Globalization.CultureInfo]::InvariantCulture
      )
    } catch { return $null }
  }
  return $null
}

function Resolve-WatchLog {
  param([string]$LogDir, [string]$LogFile)

  if (-not [string]::IsNullOrWhiteSpace($LogFile)) {
    if (Test-Path -LiteralPath $LogFile) { return (Resolve-Path -LiteralPath $LogFile).Path }
    throw "LogFile not found: $LogFile"
  }

  if ([string]::IsNullOrWhiteSpace($LogDir)) {
    throw "LogDir is empty. Set servers.$ServerKey.logDir or pass -LogDir."
  }

  if (-not (Test-Path -LiteralPath $LogDir)) {
    throw "LogDir not found: $LogDir"
  }

  $latest = Get-ChildItem -LiteralPath $LogDir -File -ErrorAction Stop |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

  if ($latest) { return $latest.FullName }

  throw "No suitable log file found in $LogDir"
}

function Get-ServerDescriptionData {
  if ([string]::IsNullOrWhiteSpace($ServerDescriptionPath)) { return $null }
  if (-not (Test-Path -LiteralPath $ServerDescriptionPath)) { return $null }

  try {
    return (Get-Content -LiteralPath $ServerDescriptionPath -Raw -Encoding UTF8 | ConvertFrom-Json)
  } catch {
    Write-DebugLine "Failed reading ServerDescription.json: $($_.Exception.Message)"
    return $null
  }
}

function Get-InviteCode {
  $sd = Get-ServerDescriptionData
  if ($sd -and $sd.ServerDescription_Persistent -and $sd.ServerDescription_Persistent.InviteCode) {
    return [string]$sd.ServerDescription_Persistent.InviteCode
  }
  return "Unknown"
}

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
        $val = $p.Value

        if ($val -is [pscustomobject]) {
          $entry = @{}
          foreach ($sp in $val.PSObject.Properties) {
            $entry[$sp.Name] = $sp.Value
          }
          $h[$p.Name] = $entry
        }
        else {
          $h[$p.Name] = $val
        }
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
  ($obj | ConvertTo-Json -Depth 10) | Set-Content -Path $RosterCache -Encoding UTF8
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
$activeSessions = Load-Roster

if ($activeSessions.Count -gt 0 -and -not $state.online_since_utc) {
  $state.online_since_utc = (UtcNowObj).ToString('o')
}

$WindroseTips = @(
  "Keep your ship repaired before long runs.",
  "A quiet crew is better than a reckless crew.",
  "Use the server invite code to verify you are on the right world.",
  "Leave with supplies, not just confidence.",
  "A prepared retreat saves more runs than a risky push."
)

function Pick-WindroseTip {
  return ($WindroseTips | Get-Random)
}

function Get-RosterLines {
  param([hashtable]$Roster)

  if (-not $Roster -or $Roster.Count -eq 0) {
    return "No sailors currently detected."
  }

  $names = @(
    $Roster.GetEnumerator() |
      Sort-Object {
        if ($_.Value -is [hashtable] -and $_.Value.ContainsKey('name')) { $_.Value.name } else { $_.Key }
      } |
      ForEach-Object {
        if ($_.Value -is [hashtable] -and $_.Value.ContainsKey('name') -and -not [string]::IsNullOrWhiteSpace($_.Value.name)) {
          $_.Value.name
        } else {
          $_.Name
        }
      }
  )

  $lines = @()
  foreach ($n in $names) {
    $lines += "• $n"
  }
  return ($lines -join "`n")
}

function Build-Payload {
  param(
    [hashtable]$Roster,
    [string]$LastEventText,
    [string]$LastEventUtc
  )

  $onlineCount = if ($Roster) { $Roster.Count } else { 0 }
  $presenceState = if ($onlineCount -gt 0) { "🟢 Sailors detected" } else { "⚫ Quiet seas" }
  $onlineLine = Format-OnlineLine -Online $onlineCount -Max $ResolvedMaxPlayers
  $rosterLines = Get-RosterLines -Roster $Roster
  $inviteCode = Get-InviteCode

  $uptimeText = "No sailors online"
  if ($onlineCount -gt 0) {
    $since = Try-ParseUtc $state.online_since_utc
    if ($since) { $uptimeText = Format-Duration ((UtcNowObj) - $since) }
    else { $uptimeText = "Online" }
  }

  $pulseUtc = (Get-Date).ToUniversalTime().ToString('HH:mm')
  $color = if ($onlineCount -gt 0) { 0x2ECC71 } else { 0x95A5A6 }

  $desc = @(
    "**Windrose crew presence**",
    "",
    $presenceState,
    "",
    "Live crew roster tracked from Windrose server activity.",
    "Times in **UTC**."
  ) -join "`n"

  return [ordered]@{
    content = ""
    embeds = @(
      [ordered]@{
        title       = "Windrose Currently On Server"
        description = $desc
        color       = $color
        fields      = @(
          @{ name = "🧭 World"; value = $ResolvedWorldName; inline = $false },
          @{ name = "🧩 ServerKey"; value = $ServerKey; inline = $true },
          @{ name = "👥 Online"; value = $onlineLine; inline = $true },
          @{ name = "🎟 Invite"; value = $inviteCode; inline = $true },
          @{ name = "🕒 Online since"; value = $uptimeText; inline = $true },
          @{ name = "🏴 Crew"; value = $rosterLines; inline = $false },
          @{ name = "Last event (UTC)"; value = $LastEventUtc; inline = $false },
          @{ name = "📝 Last event"; value = $LastEventText; inline = $false },
          @{ name = "💡 Captain Tip"; value = (Pick-WindroseTip); inline = $false }
        )
        footer    = @{ text = "QUESTPAUSE • Windrose • $ServerKey • Pulse $pulseUtc UTC" }
        timestamp = (Get-Date).ToUniversalTime().ToString('o')
      }
    )
    allowed_mentions = @{ parse = @() }
  }
}

function Apply-Join {
  param(
    [string]$SessionId,
    [string]$User,
    [datetime]$EventTime,
    [string]$EventName
  )

  if ([string]::IsNullOrWhiteSpace($SessionId)) { return $false }
  if ([string]::IsNullOrWhiteSpace($User)) {
    $User = "Sailor $($SessionId.Substring(0, [Math]::Min(8, $SessionId.Length)))"
  }

  $dupeKeys = @()
  foreach ($key in @($activeSessions.Keys)) {
    if ($key -eq $SessionId) { continue }

    $entry = $activeSessions[$key]
    $existingName = $null

    if ($entry -is [hashtable] -and $entry.ContainsKey('name')) {
      $existingName = [string]$entry.name
    } elseif ($entry) {
      $existingName = [string]$entry
    }

    if (-not [string]::IsNullOrWhiteSpace($existingName) -and $existingName -eq $User) {
      $dupeKeys += $key
    }
  }

  foreach ($k in $dupeKeys) {
    Write-DebugLine "JOIN dedupe removing old session key=$k for user=$User newSession=$SessionId"
    $activeSessions.Remove($k) | Out-Null
  }

  $alreadyOnline = $activeSessions.ContainsKey($SessionId)
  $activeSessions[$SessionId] = @{
    name = $User
    lastSeenUtc = ($EventTime.ToUniversalTime()).ToString('o')
  }

  if (-not $alreadyOnline) {
    if ($activeSessions.Count -eq 1) {
      $state.online_since_utc = ($EventTime.ToUniversalTime()).ToString('o')
    }
    $state.last_event_utc  = ($EventTime.ToUniversalTime()).ToString('o')
    $state.last_event_text = "JOIN • $User • $EventName"
    Save-Roster $activeSessions
    Save-State $state
    return $true
  }

  Save-Roster $activeSessions
  return $false
}

function Touch-Session {
  param(
    [string]$SessionId,
    [datetime]$EventTime
  )

  if ([string]::IsNullOrWhiteSpace($SessionId)) { return $false }
  if (-not $activeSessions.ContainsKey($SessionId)) { return $false }

  $entry = $activeSessions[$SessionId]
  if ($entry -isnot [hashtable]) {
    $entry = @{ name = [string]$entry; lastSeenUtc = $null }
  }

  $entry.lastSeenUtc = ($EventTime.ToUniversalTime()).ToString('o')
  if (-not $entry.ContainsKey('name') -or [string]::IsNullOrWhiteSpace($entry.name)) {
    $entry.name = "Sailor $($SessionId.Substring(0, [Math]::Min(8, $SessionId.Length)))"
  }
  $activeSessions[$SessionId] = $entry
  Save-Roster $activeSessions
  return $false
}

function Apply-Leave {
  param(
    [string]$SessionId,
    [string]$User,
    [datetime]$EventTime,
    [string]$Reason
  )

  if ([string]::IsNullOrWhiteSpace($SessionId)) { return $false }

  $name = $User
  if ([string]::IsNullOrWhiteSpace($name) -and $activeSessions.ContainsKey($SessionId)) {
    $entry = $activeSessions[$SessionId]
    if ($entry -is [hashtable] -and $entry.ContainsKey('name')) {
      $name = [string]$entry.name
    }
  }
  if ([string]::IsNullOrWhiteSpace($name)) {
    $name = "Unknown sailor"
  }

  $removed = $false
  if ($activeSessions.ContainsKey($SessionId)) {
    $activeSessions.Remove($SessionId) | Out-Null
    $removed = $true
  }

  if ($removed) {
    if ($activeSessions.Count -eq 0) {
      $state.online_since_utc = $null
    }
    $state.last_event_utc  = ($EventTime.ToUniversalTime()).ToString('o')
    $state.last_event_text = "LEAVE • $name • $Reason"
    Save-Roster $activeSessions
    Save-State $state
    return $true
  }

  return $false
}

function Replace-RosterFromSnapshot {
  param(
    [hashtable]$SnapshotRoster,
    [datetime]$EventTime
  )

  if ($null -eq $SnapshotRoster) { return $false }

  $oldJson = (@($activeSessions.GetEnumerator() | Sort-Object Name | ForEach-Object {
    [ordered]@{
      key = $_.Key
      name = if ($_.Value -is [hashtable] -and $_.Value.ContainsKey('name')) { $_.Value.name } else { [string]$_.Value }
    }
  }) | ConvertTo-Json -Depth 8)

  $newJson = (@($SnapshotRoster.GetEnumerator() | Sort-Object Name | ForEach-Object {
    [ordered]@{
      key = $_.Key
      name = if ($_.Value -is [hashtable] -and $_.Value.ContainsKey('name')) { $_.Value.name } else { [string]$_.Value }
    }
  }) | ConvertTo-Json -Depth 8)

  if ($oldJson -eq $newJson) {
    foreach ($sid in @($SnapshotRoster.Keys)) {
      if ($activeSessions.ContainsKey($sid)) {
        Touch-Session -SessionId $sid -EventTime $EventTime | Out-Null
      }
    }
    return $false
  }

  $activeSessions.Clear()
  foreach ($sid in $SnapshotRoster.Keys) {
    $activeSessions[$sid] = $SnapshotRoster[$sid]
  }

  if ($activeSessions.Count -gt 0 -and -not $state.online_since_utc) {
    $state.online_since_utc = ($EventTime.ToUniversalTime()).ToString('o')
  }
  if ($activeSessions.Count -eq 0) {
    $state.online_since_utc = $null
  }

  $state.last_event_utc  = ($EventTime.ToUniversalTime()).ToString('o')
  $state.last_event_text = "SYNC • roster snapshot • $($activeSessions.Count) online"

  Save-Roster $activeSessions
  Save-State $state
  Write-DebugLine "SNAPSHOT applied. online=$($activeSessions.Count)"
  return $true
}

function Remove-StaleSessions {
  param([datetime]$Now)

  if ($DisableStaleRemoval) {
    return $false
  }

  $changed = $false
  $toRemove = @()

  foreach ($key in @($activeSessions.Keys)) {
    $entry = $activeSessions[$key]
    $lastSeen = $null

    if ($entry -is [hashtable] -and $entry.ContainsKey('lastSeenUtc')) {
      $lastSeen = Try-ParseUtc $entry.lastSeenUtc
    }

    if ($lastSeen) {
      $age = ($Now.ToUniversalTime() - $lastSeen).TotalSeconds
      if ($age -ge $SessionStaleSeconds) {
        $toRemove += $key
      }
    }
  }

  foreach ($sid in $toRemove) {
    $name = ''
    if ($activeSessions[$sid] -is [hashtable] -and $activeSessions[$sid].ContainsKey('name')) {
      $name = [string]$activeSessions[$sid].name
    }
    if ([string]::IsNullOrWhiteSpace($name)) {
      $name = "Unknown sailor"
    }

    $activeSessions.Remove($sid) | Out-Null
    $state.last_event_utc  = ($Now.ToUniversalTime()).ToString('o')
    $state.last_event_text = "LEAVE • $name • stale-timeout"
    $changed = $true
  }

  if ($toRemove.Count -gt 0) {
    if ($activeSessions.Count -eq 0) {
      $state.online_since_utc = $null
    }
    Save-Roster $activeSessions
    Save-State $state
  }

  return $changed
}

$lastSent = @{}

function InCooldown {
  param(
    [string]$SteamId,
    [string]$Type,
    [datetime]$Now
  )

  if (-not $SteamId) { return $false }
  if (-not $lastSent) { return $false }
  if (-not $lastSent.ContainsKey($SteamId)) { return $false }
  if (-not $lastSent[$SteamId]) { return $false }
  if (-not $lastSent[$SteamId].ContainsKey($Type)) { return $false }

  $prev = $lastSent[$SteamId][$Type]
  if (-not $prev -or $prev -isnot [datetime]) { return $false }

  return (( $Now - $prev ).TotalSeconds -lt $SteamIdCooldownSeconds)
}

function MarkSent {
  param(
    [string]$SteamId,
    [string]$Type,
    [datetime]$Now
  )

  if (-not $SteamId) { return }
  if (-not $lastSent.ContainsKey($SteamId)) {
    $lastSent[$SteamId] = @{}
  }

  $lastSent[$SteamId][$Type] = $Now
}

function Parse-Line {
  param([string]$line)

  if ([string]::IsNullOrWhiteSpace($line)) { return $false }

  $logDt = Try-GetWindroseDate -Line $line
  if (-not $logDt) { $logDt = [datetime]::Now }

  if ($line -match "Name\s+'(?<name>[^']+)'.*State\s+'(?<state>[^']+)'.*NetAddress\s+'R5:(?<sid>[A-Fa-f0-9]{16,})'") {
    $name = $Matches.name.Trim()
    $sid  = $Matches.sid.Trim()
    $stateText = $Matches.state.Trim()

    Write-DebugLine "MATCH account-line name=$name sid=$sid state=$stateText"

    if ($stateText -match 'WaitingForClientIsReady|ReadyToPlay|UeLoggedIn|UePreloginVerified|BLConnected|Connected') {
      if (-not (InCooldown -SteamId $sid -Type 'join' -Now $logDt)) {
        $changed = Apply-Join -SessionId $sid -User $name -EventTime $logDt -EventName "account-state:$stateText"
        MarkSent -SteamId $sid -Type 'join' -Now $logDt
        return $changed
      }
      else {
        Touch-Session -SessionId $sid -EventTime $logDt | Out-Null
      }
      return $false
    }

    if ($stateText -match 'SaidFarewell|Disconnected') {
      if (-not (InCooldown -SteamId $sid -Type 'leave' -Now $logDt)) {
        $changed = Apply-Leave -SessionId $sid -User $name -EventTime $logDt -Reason "account-state:$stateText"
        MarkSent -SteamId $sid -Type 'leave' -Now $logDt
        return $changed
      }
      return $false
    }
  }

  if ($line -match 'Player disconnected\. BLPlayerSessionId (?<sid>[A-Fa-f0-9]{16,})') {
    $sid = $Matches.sid.Trim()

    Write-DebugLine "MATCH player-disconnected sid=$sid"

    if (-not (InCooldown -SteamId $sid -Type 'leave' -Now $logDt)) {
      $changed = Apply-Leave -SessionId $sid -User '' -EventTime $logDt -Reason 'player-disconnected'
      MarkSent -SteamId $sid -Type 'leave' -Now $logDt
      return $changed
    }
    return $false
  }

  if ($line -match 'LogNet:\s+Join succeeded:\s+(?<name>.+)$') {
    $name = $Matches.name.Trim()
    $state.last_event_utc  = ($logDt.ToUniversalTime()).ToString('o')
    $state.last_event_text = "JOIN • $name • join-succeeded"
    Save-State $state
    Write-DebugLine "MATCH join-succeeded name=$name (info only)"
    return $true
  }

  if ($line -match "OnAccountFarewell\s+Account farewell received\..*Reason '(?<reason>[^']+)'") {
    $reason = $Matches.reason.Trim()
    $state.last_event_utc  = ($logDt.ToUniversalTime()).ToString('o')
    $state.last_event_text = "LEAVE • Unknown sailor • $reason"
    Save-State $state
    Write-DebugLine "MATCH farewell reason=$reason"
    return $true
  }

  return $false
}

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

  $fsLocal = New-Object System.IO.FileStream(
    $Path,
    [System.IO.FileMode]::Open,
    [System.IO.FileAccess]::Read,
    [System.IO.FileShare]::ReadWrite
  )

  if ($Position -gt 0 -and $Position -le $fsLocal.Length) {
    $fsLocal.Seek($Position, [System.IO.SeekOrigin]::Begin) | Out-Null
  }
  elseif ($Position -gt $fsLocal.Length) {
    $fsLocal.Seek(0, [System.IO.SeekOrigin]::End) | Out-Null
  }

  $srLocal = New-Object System.IO.StreamReader($fsLocal, [System.Text.Encoding]::UTF8, $true)
  return @{ fs = $fsLocal; sr = $srLocal }
}

function New-SnapshotState {
  return [pscustomobject]@{
    inBlock = $false
    section = ''
    lines = (New-Object System.Collections.ArrayList)
    startedUtc = $null
  }
}

function Finalize-SnapshotBlock {
  param(
    [pscustomobject]$SnapshotState,
    [datetime]$EventTime
  )

  if (-not $SnapshotState.inBlock) { return $false }

  $snapshotRoster = @{}
  $currentSection = ''

  foreach ($snapLine in $SnapshotState.lines) {
    if ($snapLine -match '^\s*Connected Accounts\s*$') {
      $currentSection = 'connected'
      continue
    }
    if ($snapLine -match '^\s*Reserved Accounts\s*$') {
      $currentSection = 'reserved'
      continue
    }
    if ($snapLine -match '^\s*Disconnected Accounts\s*$') {
      $currentSection = 'disconnected'
      continue
    }

    if ($currentSection -in @('connected','reserved')) {
      if ($snapLine -match "Name\s+'(?<name>[^']+)'.*State\s+'(?<state>[^']+)'.*NetAddress\s+'R5:(?<sid>[A-Fa-f0-9]{16,})'") {
        $snapName  = $Matches.name.Trim()
        $snapState = $Matches.state.Trim()
        $snapSid   = $Matches.sid.Trim()

        if ($snapState -match 'WaitingForClientIsReady|ReadyToPlay|UeLoggedIn|UePreloginVerified|BLConnected|Connected') {
          $snapshotRoster[$snapSid] = @{
            name = $snapName
            lastSeenUtc = ($EventTime.ToUniversalTime()).ToString('o')
          }
        }
      }
    }
  }

  Write-DebugLine "SNAPSHOT finalize connected=$($snapshotRoster.Count)"
  $SnapshotState.inBlock = $false
  $SnapshotState.section = ''
  $SnapshotState.lines = (New-Object System.Collections.ArrayList)
  $SnapshotState.startedUtc = $null

  return (Replace-RosterFromSnapshot -SnapshotRoster $snapshotRoster -EventTime $EventTime)
}

$WatchedLog = Resolve-WatchLog -LogDir $ResolvedLogDir -LogFile $ResolvedLogFile
$state.watch_log = $WatchedLog

$fileMeta = Get-FileMeta -Path $WatchedLog
$cursor = Load-Cursor

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

$state.watch_log = $WatchedLog
$state.watch_log_length = $fileMeta.length
$state.watch_log_lastwrite_utc = $fileMeta.lastwrite_utc
Save-State $state

function Post-CurrentCard {
  $lastEventUtcText = 'No events yet'
  if ($state.last_event_utc) {
    $tmp = Try-ParseUtc $state.last_event_utc
    if ($tmp) { $lastEventUtcText = $tmp.ToString('yyyy-MM-dd HH:mm:ss') + ' UTC' }
  }

  $payload = Build-Payload -Roster $activeSessions -LastEventText $state.last_event_text -LastEventUtc $lastEventUtcText
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

Write-Host "QuestPauseOps Windrose presence watcher started for $ServerKey"
Write-Host "WatchedLog=$WatchedLog"
Write-Host "StateDir=$StateDir"
Write-Host "ConfigPath=$ConfigPath"
Write-Host "DebugLog=$DebugLog"

$snapshotState = New-SnapshotState

try {
  Post-CurrentCard

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
        $snapshotState = New-SnapshotState
      }

      while (-not $sr.EndOfStream) {
        $line = $sr.ReadLine()
        $cursor.position = $fs.Position

        if ($line -match '^\s*Connected Accounts\s*$') {
          if ($snapshotState.inBlock) {
            $blockTime = Get-Date
            if (Finalize-SnapshotBlock -SnapshotState $snapshotState -EventTime $blockTime) {
              $changed = $true
            }
          }

          $snapshotState.inBlock = $true
          $snapshotState.section = 'connected'
          $snapshotState.lines = (New-Object System.Collections.ArrayList)
          $snapshotState.startedUtc = (Get-Date).ToUniversalTime().ToString('o')
          [void]$snapshotState.lines.Add($line)
          Write-DebugLine "SNAPSHOT begin"
          continue
        }

        if ($snapshotState.inBlock) {
          if ($line -match '^\[\d{4}\.\d{2}\.\d{2}-\d{2}\.\d{2}\.\d{2}:\d{3}\]') {
            $blockTime = Try-GetWindroseDate -Line $line
            if (-not $blockTime) { $blockTime = Get-Date }

            if (Finalize-SnapshotBlock -SnapshotState $snapshotState -EventTime $blockTime) {
              $changed = $true
            }

            if (Parse-Line -line $line) {
              $changed = $true
            }
            continue
          }
          else {
            [void]$snapshotState.lines.Add($line)
            continue
          }
        }

        if (Parse-Line -line $line) {
          $changed = $true
        }
      }

      if ($snapshotState.inBlock -and $snapshotState.lines.Count -gt 0) {
        $blockTime = Get-Date
        if (Finalize-SnapshotBlock -SnapshotState $snapshotState -EventTime $blockTime) {
          $changed = $true
        }
      }

      if (Remove-StaleSessions -Now (Get-Date)) {
        $changed = $true
      }

      $cursor.path = $WatchedLog
      $cursor.length = $metaNow.length
      $cursor.lastwrite_utc = $metaNow.lastwrite_utc
      Save-Cursor $cursor

      $state.watch_log = $WatchedLog
      $state.watch_log_length = $metaNow.length
      $state.watch_log_lastwrite_utc = $metaNow.lastwrite_utc
      Save-State $state

      if ($changed -or (Pulse-Due)) {
        Post-CurrentCard
      }

    } catch {
      Write-DebugLine "LOOP ERROR: $($_.Exception.Message)"
      Write-Host "[LOOP ERROR] $($_.Exception.Message)" -ForegroundColor DarkYellow
    }

    Start-Sleep -Milliseconds $PollMs
  }
}
finally {
  try { $sr.Close() } catch {}
  try { $fs.Close() } catch {}
}

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$ServerKey,

  [switch]$RunOnce,

  [int]$PollSeconds = 5,
  [int]$PulseMinutes = 1,

  # Optional overrides
  [string]$WebhookUrl = '',
  [string]$LogDir = '',
  [string]$StateDirOverride = '',
  [int]$MaxPlayers = 0,
  [bool]$AutoDetectMaxSlots = $true,
  [string]$ServerConfigPath = ''
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
  C:\QuestPauseOps\scripts\presence\7dtd_currently_on_server.ps1
  QUESTPAUSEOPS — 7DTD Current Survivors Card

  What it does:
  - Loads C:\QuestPauseOps\config\servers.json
  - Uses -ServerKey to target ONE 7DTD server
  - Watches output_log_dedi__*.txt
  - Tracks survivor join/leave from log events
  - Maintains ONE live Discord card edited in place
  - Auto-detects max slots from serverconfig.xml when enabled
  - Stores per-server state in C:\QuestPauseOps\state\<ServerKey>\
  - Stores debug logs in C:\QuestPauseOps\logs\presence\
#>

# =========================
# UTF-8 (PowerShell 5.1 safe)
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
$StateDir   = if (-not [string]::IsNullOrWhiteSpace($StateDirOverride)) { $StateDirOverride } else { Join-Path $OpsRoot ("state\" + $ServerKey) }

$StateFile      = Join-Path $StateDir '7dtd_presence_state.json'
$DebugLog       = Join-Path $LogsDir  ("{0}_7dtd_currently_on_server.log" -f $ServerKey)
$LastIdFile     = Join-Path $StateDir '7dtd_presence_last_message_id.txt'
$RosterCache    = Join-Path $StateDir '7dtd_presence_roster.json'

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
if ($server.worldName) { $WorldNameFallback = $server.worldName }
elseif ($server.displayName) { $WorldNameFallback = $server.displayName }
$ResolvedWorldName = $WorldNameFallback

$LogDirFallback = ''
if ($server.logDir) { $LogDirFallback = $server.logDir }
$ResolvedLogDir = Get-FirstValue $LogDir $LogDirFallback

$ServerConfigFallback = ''
if ($server.serverConfigPath) { $ServerConfigFallback = $server.serverConfigPath }
$ResolvedServerConfigPath = Get-FirstValue $ServerConfigPath $ServerConfigFallback

if ($MaxPlayers -gt 0) {
  $ResolvedMaxPlayers = $MaxPlayers
} elseif ($server.maxPlayers) {
  $ResolvedMaxPlayers = [int]$server.maxPlayers
} else {
  $ResolvedMaxPlayers = 8
}

$WebhookFallback = ''
if ($server.PSObject.Properties['webhooks'] -and $server.webhooks) {
  if ($server.webhooks.PSObject.Properties['presence']) {
    $WebhookFallback = $server.webhooks.presence
  } elseif ($server.webhooks.PSObject.Properties['activity']) {
    $WebhookFallback = $server.webhooks.activity
  } elseif ($server.webhooks.PSObject.Properties['status']) {
    $WebhookFallback = $server.webhooks.status
  }
}
if (-not $WebhookFallback -and $server.webhookUrl) {
  $WebhookFallback = $server.webhookUrl
}
$ResolvedWebhookUrl = Get-FirstValue $WebhookUrl $WebhookFallback

if ([string]::IsNullOrWhiteSpace($ResolvedWebhookUrl)) {
  throw "No webhook found for $ServerKey. Add webhooks.presence/activity/status or pass -WebhookUrl."
}

if ([string]::IsNullOrWhiteSpace($ResolvedLogDir)) {
  throw "No logDir found for $ServerKey. Add servers.$ServerKey.logDir or pass -LogDir."
}

Write-DebugLine "Resolved config for $ServerKey"
Write-DebugLine "ConfigPath=$ConfigPath"
Write-DebugLine "LogDir=$ResolvedLogDir"
Write-DebugLine "ServerConfigPath=$ResolvedServerConfigPath"
Write-DebugLine "MaxPlayers=$ResolvedMaxPlayers"
Write-DebugLine "AutoDetectMaxSlots=$AutoDetectMaxSlots"

# =========================
# WEBHOOK SANITIZE / VALIDATE
# =========================
function Normalize-Webhook([string]$w) {
  if ([string]::IsNullOrWhiteSpace($w)) { return "" }
  $w = ($w -replace '\s','') -replace '[\u200B-\u200D\uFEFF]',''
  return $w.Trim().TrimEnd('/')
}

$ResolvedWebhookUrl = Normalize-Webhook $ResolvedWebhookUrl

if ([string]::IsNullOrWhiteSpace($ResolvedWebhookUrl)) {
  throw "Webhook is empty."
}

if ($ResolvedWebhookUrl -notmatch '^https://(canary\.|ptb\.)?discord\.com/api/webhooks/\d+/[^/]+$') {
  throw "Webhook format invalid for ${ServerKey}: '$ResolvedWebhookUrl'"
}

$ResolvedWebhookUri = [Uri]::new($ResolvedWebhookUrl)

function Get-WebhookParts([string]$webhookBase) {
  if ($webhookBase -match '^https://(canary\.|ptb\.)?discord\.com/api/webhooks/(?<id>\d+)/(?<token>[^/]+)$') {
    return @{ id = $Matches['id']; token = $Matches['token'] }
  }
  throw "Webhook format unexpected."
}

$WebhookParts = Get-WebhookParts $ResolvedWebhookUrl

function Get-PostWaitUri {
  $b = [System.UriBuilder]::new($ResolvedWebhookUri)
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
  for ($attempt = 1; $attempt -le 2; $attempt++) {
    try {
      return (SendJsonUTF8 -Method 'PATCH' -Uri $editUri -Payload $payload)
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

  $postUri = Get-PostWaitUri
  $r = SendJsonUTF8 -Method 'POST' -Uri $postUri -Payload $payload
  if (-not $r -or -not $r.id) {
    throw "Webhook POST did not return a message id."
  }
  return $r.id
}

# =========================
# SLOTS
# =========================
function Get-MaxPlayersFromServerConfigXml {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
  if (-not (Test-Path -LiteralPath $Path)) { return $null }

  try {
    [xml]$xml = Get-Content -Path $Path -Raw -Encoding UTF8

    $node = $xml.SelectSingleNode("//property[@name='ServerMaxPlayerCount']")
    if ($node -and $node.value) {
      $v = 0
      if ([int]::TryParse([string]$node.value, [ref]$v) -and $v -gt 0) { return $v }
    }

    $node2 = $xml.SelectSingleNode("//property[@name='MaxPlayerCount']")
    if ($node2 -and $node2.value) {
      $v2 = 0
      if ([int]::TryParse([string]$node2.value, [ref]$v2) -and $v2 -gt 0) { return $v2 }
    }

    return $null
  } catch {
    Write-DebugLine ("Slots autodetect failed: " + $_.Exception.Message + " | path=" + $Path)
    return $null
  }
}

function Resolve-MaxPlayers {
  if ($AutoDetectMaxSlots) {
    $auto = Get-MaxPlayersFromServerConfigXml -Path $ResolvedServerConfigPath
    if ($auto) { return [int]$auto }
  }
  return [int]$ResolvedMaxPlayers
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

  Ensure-Prop $s 'log_file' $null
  Ensure-Prop $s 'log_pos' 0
  Ensure-Prop $s 'players' @()
  Ensure-Prop $s 'player_join_utc' @{}
  Ensure-Prop $s 'last_event_utc' $null
  Ensure-Prop $s 'last_event_text' 'Watcher started'
  Ensure-Prop $s 'last_pulse_utc' $null
  Ensure-Prop $s 'online_since_utc' $null

  return $s
}

function Save-State($s) {
  Ensure-Dir $StateDir
  ($s | ConvertTo-Json -Depth 12) | Set-Content -Path $StateFile -Encoding UTF8
}

function Try-ParseUtc([string]$iso) {
  if ([string]::IsNullOrWhiteSpace($iso)) { return $null }
  try { return ([DateTime]::Parse($iso)).ToUniversalTime() } catch { return $null }
}

function UtcNowObj { (Get-Date).ToUniversalTime() }

function Format-DurationShort([TimeSpan]$ts) {
  if ($ts.TotalSeconds -lt 0) { return '0m' }
  if ($ts.TotalDays -ge 1) {
    return ("{0}d {1}h" -f [int]$ts.TotalDays, $ts.Hours)
  }
  if ($ts.TotalHours -ge 1) {
    return ("{0}h {1}m" -f [int]$ts.TotalHours, $ts.Minutes)
  }
  if ($ts.TotalMinutes -ge 1) {
    return ("{0}m" -f [int]$ts.TotalMinutes)
  }
  return ("{0}s" -f [int]$ts.TotalSeconds)
}

# =========================
# ROSTER PERSIST
# =========================
function Ensure-Hashtable {
  param(
    [ref]$state,
    [string]$propName
  )

  $v = $state.Value.$propName

  if ($null -eq $v) {
    $state.Value.$propName = @{}
    return
  }

  if ($v -is [hashtable]) { return }

  if ($v -is [pscustomobject]) {
    $h = @{}
    foreach ($p in $v.PSObject.Properties) { $h[$p.Name] = $p.Value }
    $state.Value.$propName = $h
    return
  }

  $state.Value.$propName = @{}
}

function Add-Player {
  param([ref]$state, [string]$name)
  $arr = @($state.Value.players)
  if ($arr -notcontains $name) {
    $state.Value.players = @($arr + @($name))
  }
}

function Remove-Player {
  param([ref]$state, [string]$name)
  $arr = @($state.Value.players) | Where-Object { $_ -ne $name }
  $state.Value.players = @($arr)
}

function Get-PlayerCount([ref]$state) {
  return @($state.Value.players).Count
}

# =========================
# LOG TAIL
# =========================
function Get-LatestLogFile {
  if (-not (Test-Path -LiteralPath $ResolvedLogDir)) { return $null }
  $f = Get-ChildItem -LiteralPath $ResolvedLogDir -Filter "output_log_dedi__*.txt" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
  if ($f) { return $f.FullName }
  return $null
}

function Read-NewLogLines {
  param([ref]$state)

  $path = Get-LatestLogFile
  if (-not $path) {
    Write-DebugLine "No log file found in LogDir: $ResolvedLogDir"
    return @()
  }

  if ($state.Value.log_file -ne $path) {
    Write-DebugLine "Log file changed -> reset cursor. New: $path"
    $state.Value.log_file = $path
    $state.Value.log_pos  = 0
    Save-State $state.Value
  }

  try {
    $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
      $fs.Seek([int64]$state.Value.log_pos, [System.IO.SeekOrigin]::Begin) | Out-Null
      $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8, $true)
      $text = $sr.ReadToEnd()
      $state.Value.log_pos = $fs.Position
      if ($text) { return ($text -split "`r?`n") }
      return @()
    } finally {
      $fs.Dispose()
    }
  } catch {
    Write-DebugLine ("Log read error: " + $_.Exception.Message)
    return @()
  }
}

# =========================
# FIELD TIPS
# =========================
$D7Tips = @(
  "Always keep a fallback chest near your base entrance.",
  "Repair kits save runs that brute force ruins.",
  "Night is for preparation if your gear is weak.",
  "A clear exit route matters more than one extra loot crate.",
  "Do not overstay a POI once your inventory is already good.",
  "A vehicle facing outward is an escape plan.",
  "Food, water, and bandages are worth more than risky greed.",
  "Fighting on your terms beats reacting in panic.",
  "If stamina drops, reset the fight before the fight resets you.",
  "Base ammo and medical supplies in separate boxes for speed.",
  "Roofs can save lives, but bad drops kill fast.",
  "One good melee weapon is better than three broken backups.",
  "Clear nearby threats before sorting loot.",
  "A safe return is part of the run, not the end of it.",
  "Horde prep starts long before horde night.",
  "Use elevation wisely, but never trust one ladder alone.",
  "A short loot run completed beats a perfect one abandoned.",
  "Do not turn noise into chaos unless you planned the exit.",
  "Keep fuel, repair tools, and meds stocked before long trips.",
  "When in doubt, survive first and optimize later."
)

function Pick-D7Tip {
  return ($D7Tips | Get-Random)
}

# =========================
# CARD BUILD
# =========================
function Get-RosterLines {
  param([string[]]$Players)

  $arr = @($Players | Sort-Object -Unique)
  if ($arr.Count -eq 0) {
    return "No survivors currently detected."
  }

  $lines = @()
  foreach ($p in $arr) {
    $lines += "• $p"
  }
  return ($lines -join "`n")
}

function Build-Payload {
  param(
    [ref]$state
  )

  $onlineCount = Get-PlayerCount -state $state
  $maxSlots = Resolve-MaxPlayers
  $presenceState = if ($onlineCount -gt 0) { "🟢 Survivors detected" } else { "⚫ Quiet wasteland" }

  $onlineSinceText = "No survivors online"
  if ($onlineCount -gt 0 -and $state.Value.online_since_utc) {
    $since = Try-ParseUtc $state.Value.online_since_utc
    if ($since) {
      $onlineSinceText = Format-DurationShort ((UtcNowObj) - $since)
    } else {
      $onlineSinceText = "Online"
    }
  }

  $lastEventUtcText = "No events yet"
  if ($state.Value.last_event_utc) {
    $tmp = Try-ParseUtc $state.Value.last_event_utc
    if ($tmp) {
      $lastEventUtcText = $tmp.ToString('yyyy-MM-dd HH:mm:ss') + ' UTC'
    }
  }

  $pulseUtc = (UtcNowObj).ToString('HH:mm')
  $color = if ($onlineCount -gt 0) { 0x2ECC71 } else { 0x95A5A6 }

  $desc = @(
    "**7 Days to Die survivor presence**",
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
        title       = "7DTD Currently On Server"
        description = $desc
        color       = $color
        fields      = @(
          @{ name = "🧭 World"; value = $ResolvedWorldName; inline = $false },
          @{ name = "🧩 ServerKey"; value = $ServerKey; inline = $true },
          @{ name = "👥 Online"; value = "$onlineCount/$maxSlots"; inline = $true },
          @{ name = "📡 Presence"; value = $presenceState; inline = $true },
          @{ name = "🕒 Online since"; value = $onlineSinceText; inline = $true },
          @{ name = "🧟 Survivors"; value = (Get-RosterLines -Players @($state.Value.players)); inline = $false },
          @{ name = "Last event (UTC)"; value = $lastEventUtcText; inline = $false },
          @{ name = "📝 Last event"; value = $state.Value.last_event_text; inline = $false },
          @{ name = "💡 Field Tip"; value = (Pick-D7Tip); inline = $false }
        )
        footer    = @{ text = "QUESTPAUSE • 7DTD • $ServerKey • Pulse $pulseUtc UTC" }
        timestamp = (UtcNowObj).ToString('o')
      }
    )
    allowed_mentions = @{ parse = @() }
  }
}

function Post-CurrentCard {
  param([ref]$state)

  $payload = Build-Payload -state $state
  $id = SendOrEdit $payload
  if ($id) { Set-Content -Path $LastIdFile -Value $id -Encoding UTF8 }

  $state.Value.last_pulse_utc = (UtcNowObj).ToString('o')
  Save-State $state.Value
}

function Pulse-Due {
  param([ref]$state)

  if ($PulseMinutes -le 0) { return $true }
  if (-not $state.Value.last_pulse_utc) { return $true }

  $last = Try-ParseUtc $state.Value.last_pulse_utc
  if (-not $last) { return $true }

  return (((UtcNowObj) - $last).TotalSeconds -ge ($PulseMinutes * 60))
}

# =========================
# PARSE
# =========================
function Mark-LastEvent {
  param(
    [ref]$state,
    [string]$text,
    [DateTime]$whenUtc
  )
  $state.Value.last_event_text = $text
  $state.Value.last_event_utc = $whenUtc.ToString('o')
}

function Mark-PlayerJoined {
  param([ref]$state, [string]$player, [DateTime]$nowUtcObj)
  Ensure-Hashtable -state $state -propName 'player_join_utc'
  $state.Value.player_join_utc[$player] = $nowUtcObj.ToString('o')
}

function Get-SessionLengthTextAndClear {
  param([ref]$state, [string]$player, [DateTime]$nowUtcObj)

  Ensure-Hashtable -state $state -propName 'player_join_utc'

  if (-not $state.Value.player_join_utc.ContainsKey($player)) {
    return "Unknown"
  }

  $joinIso = [string]$state.Value.player_join_utc[$player]
  $joinUtc = Try-ParseUtc $joinIso

  try { $null = $state.Value.player_join_utc.Remove($player) } catch { $state.Value.player_join_utc[$player] = $null }

  if (-not $joinUtc) { return "Unknown" }

  return (Format-DurationShort ($nowUtcObj - $joinUtc))
}

function Parse-JoinLeave {
  param([ref]$state, [string[]]$lines)

  $changed = $false

  foreach ($line in $lines) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }

    if ($line -match "GMSG:\s*Player\s*'([^']+)'\s*joined\s*the\s*game") {
      $player = $Matches[1].Trim()
      $now = UtcNowObj

      if (@($state.Value.players) -notcontains $player) {
        Write-DebugLine "DETECTED JOIN: $player"
        Add-Player -state $state -name $player
        Mark-PlayerJoined -state $state -player $player -nowUtcObj $now

        if ((Get-PlayerCount -state $state) -eq 1 -or -not $state.Value.online_since_utc) {
          $state.Value.online_since_utc = $now.ToString('o')
        }

        Mark-LastEvent -state $state -text ("JOIN • " + $player) -whenUtc $now
        $changed = $true
      }
      continue
    }

    if ($line -match "GMSG:\s*Player\s*'([^']+)'\s*left\s*the\s*game") {
      $player = $Matches[1].Trim()
      $now = UtcNowObj

      if (@($state.Value.players) -contains $player) {
        Write-DebugLine "DETECTED LEAVE: $player"
        $sessionLen = Get-SessionLengthTextAndClear -state $state -player $player -nowUtcObj $now

        Remove-Player -state $state -name $player

        if ((Get-PlayerCount -state $state) -eq 0) {
          $state.Value.online_since_utc = $null
        }

        $eventText = "LEAVE • $player"
        if ($sessionLen -and $sessionLen -ne 'Unknown') {
          $eventText = "LEAVE • $player • survived for $sessionLen"
        }

        Mark-LastEvent -state $state -text $eventText -whenUtc $now
        $changed = $true
      }
      continue
    }
  }

  if ($changed) {
    Save-State $state.Value
  }

  return $changed
}

# =========================
# MAIN
# =========================
$script:state = Load-State
Ensure-Hashtable -state ([ref]$script:state) -propName 'player_join_utc'
Save-State $script:state

Write-Host "QuestPauseOps 7DTD presence watcher started for $ServerKey."
Write-Host "Webhook           : $ResolvedWebhookUrl"
Write-Host "LogDir            : $ResolvedLogDir"
Write-Host "PollSeconds       : $PollSeconds"
Write-Host "PulseMinutes      : $PulseMinutes"
Write-Host "AutoDetectMaxSlots: $AutoDetectMaxSlots"
Write-Host "ServerConfigPath  : $ResolvedServerConfigPath"
Write-Host "Fallback MaxPlayers: $ResolvedMaxPlayers"
Write-Host "State             : $StateFile"
Write-Host "Debug log         : $DebugLog"
Write-DebugLine "Watcher started for $ServerKey."

if ($RunOnce) {
  Post-CurrentCard -state ([ref]$script:state)
  return
}

Post-CurrentCard -state ([ref]$script:state)

while ($true) {
  [DateTime]::UtcNow.ToString('o') | Set-Content (Join-Path $OpsRoot "state\$ServerKey\presence_heartbeat.txt") -Encoding UTF8
  try {
    $lines = Read-NewLogLines -state ([ref]$script:state)
    $changed = $false

    if ($lines.Count -gt 0) {
      Write-DebugLine ("Read {0} new lines" -f $lines.Count)
      $changed = Parse-JoinLeave -state ([ref]$script:state) -lines $lines
    }

    if ($changed -or (Pulse-Due -state ([ref]$script:state))) {
      Post-CurrentCard -state ([ref]$script:state)
    }

  } catch {
    Write-DebugLine ("LOOP ERROR: " + $_.Exception.Message)
  }

  Start-Sleep -Seconds $PollSeconds
}

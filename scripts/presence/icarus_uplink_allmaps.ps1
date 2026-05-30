[CmdletBinding()]
param(
  [int]$IntervalSeconds = 30,
  [switch]$Once
)

# Bootstrap: resolve QuestPauseOps root paths from env.ps1
$__qpEnv = $null
foreach ($__qpRel in @('..\env.ps1', '..\..\env.ps1', '..\..\..\env.ps1', '..\..\..\..\env.ps1')) {
    $__qpTest = Join-Path $PSScriptRoot $__qpRel
    if (Test-Path $__qpTest) { $__qpEnv = $__qpTest; break }
}
if (-not $__qpEnv) { throw "env.ps1 not found from $PSScriptRoot" }
. $__qpEnv
Remove-Variable __qpEnv, __qpRel, __qpTest -ErrorAction SilentlyContinue

<#
  C:\QuestPauseOps\scripts\uplink\icarus_uplink_allmaps.ps1
  QUESTPAUSEOPS — ICARUS Uplink (SINGLE SCRIPT, ALL MAPS, ONE EMBED)

  What it does:
  - Loads C:\QuestPauseOps\config\servers.json
  - Uses servers.icarus_combined.combined.includeServerKeys as the map list
  - For each map serverKey:
      - Process check (optional command-line match)
      - A2S info query for player count + max players
      - A2S player query for current player names (best-effort)
      - Weather state from latest log (best-effort)
      - Stale detection using last successful A2S timestamp cache
      - Stability layer (retry/flicker guard)
      - Log-tail authoritative join/leave tracking per map
  - Builds ONE embed (OLYMPUS, STYX, PROMETHEUS, ELYSIUM locked order)
      - ✅ Online
      - ⚠ No response / Process down / Stale telemetry
      - 📡 Retrying (transient)
      - Recent activity section (only when needed)
          🟢 online roster / 🔴 recent leaves
  - Footer includes "last updated"
  - Adds "Degraded:" summary line ONLY when needed
  - Creates or PATCHes one Discord message in-place via icarus_combined.discordWebhook.status
  - Stores message_id in: C:\QuestPauseOps\state\icarus\uplink_combined_state.json
  - Writes debug telemetry in: C:\QuestPauseOps\state\icarus\uplink_allmaps.json
  - Persistent activity state:
      C:\QuestPauseOps\state\icarus\uplink_players_state.json

  PATCH:
  - ONLY count JOIN from logs when ICARUS confirms a fully connected player:
      LogConnectedPlayers: Display: AddConnectedPlayer ... UserId: X | PlayerName: Y
  - IGNORE FinaliseConnectedPlayerInitialisation as a join source
  - ONLY count LEAVE from logs when Steam says "<steamId> has been removed"
    AND that steamId was previously seen as online for this map
    AND they were online longer than a grace window
  - ALSO reconcile current online names from A2S player query when available
    so stale/wrong names are removed even if a log leave is missed
  - Online player names are shown ONLY under Recent activity
  - Main map lines show only deployment/weather/uptime
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ================== PATHS ==================
$QP_ROOT = $script:QPRoot
$CFG_PATH = Join-Path $QP_ROOT 'config\servers.json'
$STATE_ALLMAPS = Join-Path $QP_ROOT 'state\icarus\uplink_allmaps.json'
$STATE_COMBINED = Join-Path $QP_ROOT 'state\icarus\uplink_combined_state.json'
$STATE_MAPCACHE = Join-Path $QP_ROOT 'state\icarus\uplink_allmaps_cache.json'
$STATE_PLAYERS = Join-Path $QP_ROOT 'state\icarus\uplink_players_state.json'
# ===========================================

# UTF-8 (no BOM)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$Utf8NoBOM = New-Object System.Text.UTF8Encoding($false)
$Utf8 = New-Object System.Text.UTF8Encoding($false)

# ================== EMOJI ==================
$E_Satellite = [char]::ConvertFromUtf32(0x1F6F0)   # 🛰
$E_Antenna = [char]::ConvertFromUtf32(0x1F4E1)     # 📡
$E_Warning = [char]::ConvertFromUtf32(0x26A0)      # ⚠
$E_Check = [char]::ConvertFromUtf32(0x2705)        # ✅
$E_Wrench = [char]::ConvertFromUtf32(0x1F6E0)      # 🛠
$E_Rain = [char]::ConvertFromUtf32(0x1F327)        # 🌧
$E_Storm = [char]::ConvertFromUtf32(0x26C8)        # ⛈
$E_Wind = [char]::ConvertFromUtf32(0x1F4A8)        # 💨
$E_Snow = [char]::ConvertFromUtf32(0x1F328)        # 🌨
$E_Tornado = [char]::ConvertFromUtf32(0x1F32A)     # 🌪
$E_SunBehind = [char]::ConvertFromUtf32(0x1F324)   # 🌤
$E_GreenCircle = [char]::ConvertFromUtf32(0x1F7E2) # 🟢
$E_RedCircle = [char]::ConvertFromUtf32(0x1F534)   # 🔴
$E_ROTATE = [char]::ConvertFromUtf32(0x1F501)       # 🔁
# ===========================================

# Colors
$ColorHealthy = 0x22AA66
$ColorDegraded = 0xD9A441
$ColorCritical = 0xCC3333

# ================== STATUS / TIMING ==================
$StaleSeconds = [Math]::Max(60, ($IntervalSeconds * 3))
$FailStreakToDown = 2
$SuccessStreakToHealthy = 1

$ActivityWindowMinutes = 30
$LeaveDisplaySeconds = 120
$MaxEventsPerMap = 60
$RenderEventsPerMap = 2
$JoinLeaveGraceSeconds = 90
$PlayerDebounceSeconds = 8

# Locked display order for the combined ICARUS embed.
# Keep values uppercase because sorting compares against key.ToUpperInvariant().
$preferredOrder = @('OLYMPUS', 'STYX', 'PROMETHEUS', 'ELYSUIM')
# =====================================================

# ========= Tips =========
$TipsVariants = @(
  "Carry a **bedroll + campfire kit** early fast respawn, fast reset.",
  "Before long runs: **repair pickaxe/knife**, then craft the next tier at base.",
  "Storm inbound? **Pause travel** and do a quick base pass: water, food, arrows, meds.",
  "Keep one slot as a **panic slot**: bandage, splint, antibiotic, or anti-poison.",
  "If you’re weight-capped, ditch **stone/wood** first keep exotics + mission items.",
  "Mark your base with a **beacon** so extraction routes stay clean.",
  "Hunting tip: crouch, wait for the turn, then hit the **head/neck** for clean kills.",
  "Carry **two oxygen bladders** if you’re cave-diving it saves runs back to daylight.",
  "When in doubt: craft **one extra shelter tile** storms love the moment you ignore them.",
  "If the server feels laggy, avoid mass builds and do **short objectives** until stable."
)
# ========================

function Status-Emoji([string]$status, [bool]$processOk, [bool]$isStale) {
  if ($status -eq 'MAINTENANCE') { return $E_Wrench }
  if ($isStale) { return $E_Warning }
  if ($status -eq 'ONLINE') { return $E_Check }
  if (-not $processOk) { return $E_Warning }
  return $E_Warning
}

function Status-Label([string]$status, [bool]$processOk, [bool]$isStale, [string]$staleAgeTxt) {
  if ($isStale) {
    if ([string]::IsNullOrWhiteSpace($staleAgeTxt)) { return "stale" }
    return ("stale ({0})" -f $staleAgeTxt)
  }
  if ($status -eq 'ONLINE') { return "online" }
  if (-not $processOk) { return "process down" }
  return "no response"
}

function Log([string]$msg) {
  $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  $line = "[$ts] $msg"
  Write-Host $line
  try {
    $logDir = Join-Path $QP_ROOT 'logs'
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $logFile = Join-Path $logDir 'icarus_uplink_allmaps.log'

    # --- LOG ROTATION (10MB) ---
    if (Test-Path $logFile) {
      $size = (Get-Item $logFile).Length
      if ($size -gt 10MB) {
        $oldFile = "$logFile.old"
        Move-Item -Path $logFile -Destination $oldFile -Force
        "[$ts] Log rotated (exceeded 10MB)" | Out-File -FilePath $logFile -Encoding utf8
      }
    }

    $line | Out-File -FilePath $logFile -Append -Encoding utf8
  }
  catch {}
}

function Ensure-Dir([string]$filePath) {
  $dir = Split-Path $filePath
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
}

function Read-Json([string]$path) {
  try {
    if (-not (Test-Path $path)) { return $null }
    $raw = Get-Content $path -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return ($raw | ConvertFrom-Json -ErrorAction Stop)
  }
  catch {
    try { Log ("Read-Json failed for {0}: {1}" -f $path, $_.Exception.Message) } catch {}
    return $null
  }
}

function Write-JsonAtomic([string]$path, [object]$obj, [int]$depth = 10) {
  Ensure-Dir $path

  $tmp = "{0}.{1}.tmp" -f $path, ([guid]::NewGuid().ToString("N"))

  try {
    # Use a reasonable depth and ensure it's a single string
    $json = $obj | ConvertTo-Json -Depth $depth
    $bytes = $Utf8NoBOM.GetBytes($json)

    [IO.File]::WriteAllBytes($tmp, $bytes)
    Move-Item -Path $tmp -Destination $path -Force
  }
  finally {
    try {
      if (Test-Path $tmp) { Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue }
    }
    catch {}
  }
}

function Clean-Key([string]$k) {
  if ([string]::IsNullOrWhiteSpace($k)) { return "" }
  return ((($k -replace '[\*\`_]', '') -replace '\s+', ' ').Trim())
}

function Build-WebhookUrl([string]$id, [string]$token) {
  if ([string]::IsNullOrWhiteSpace($id) -or [string]::IsNullOrWhiteSpace($token)) { return "" }
  return ("https://discord.com/api/webhooks/{0}/{1}" -f $id.Trim(), $token.Trim())
}

function Add-QueryParam([string]$uri, [string]$k, [string]$v) {
  if ([string]::IsNullOrWhiteSpace($uri)) { return $uri }
  if ($uri -match ([regex]::Escape($k) + "=")) { return $uri }
  if ($uri -match "\?") { return ($uri + "&$k=$v") }
  return ($uri + "?$k=$v")
}

function Post-Discord([string]$webhook, [object]$payload, [switch]$Wait) {
  if ([string]::IsNullOrWhiteSpace($webhook)) { return $null }

  $uri = [string]$webhook
  if ($Wait) { $uri = Add-QueryParam $uri "wait" "true" }

  if (-not [uri]::IsWellFormedUriString($uri, [System.UriKind]::Absolute)) {
    Log ("Discord post aborted: malformed URI -> {0}" -f $uri)
    return $null
  }

  $json = $payload | ConvertTo-Json -Depth 16
  $bytes = $Utf8NoBOM.GetBytes($json)
  $headers = @{ 'Content-Type' = 'application/json; charset=utf-8' }

  $maxRetries = 5
  $attempt = 0
  $baseDelaySec = 1
  while ($true) {
    $attempt++
    try {
      return Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body $bytes -TimeoutSec 20
    }
    catch {
      $ex = $_.Exception
      $statusCode = 0
      $retryAfter = $null
      $is429 = $false

      if ($ex.Response -and $ex.Response.StatusCode) {
        $statusCode = [int]$ex.Response.StatusCode
      } elseif ($ex.InnerException -and $ex.InnerException.Response -and $ex.InnerException.Response.StatusCode) {
        $statusCode = [int]$ex.InnerException.Response.StatusCode
      }

      if ($statusCode -eq 429) {
        $is429 = $true
        try {
          if ($ex.Response -and $ex.Response.Headers) {
            $h = $ex.Response.Headers
            if ($h.Contains('Retry-After')) {
              $retryAfter = [int]($h['Retry-After'] | Select-Object -First 1)
            }
          }
        } catch {}
        if (-not $retryAfter -or $retryAfter -lt 1) { $retryAfter = 10 }
      }

      if ($is429) {
        if ($attempt -ge $maxRetries) { Log ("Discord post rate limited after $maxRetries retries"); return $null }
        Log ("Discord post rate limited (attempt $attempt), retrying in ${retryAfter}s")
        Start-Sleep -Seconds $retryAfter
        continue
      }

      if ($attempt -ge $maxRetries -or ($statusCode -ge 400 -and $statusCode -lt 500 -and $statusCode -ne 429)) {
        $errBody = ""
        try {
          $resp = $ex.Response
          if ($resp) {
            $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
            $errBody = $reader.ReadToEnd()
            $reader.Close()
          }
        } catch {}
        if ([string]::IsNullOrWhiteSpace($errBody)) {
          Log ("Discord post failed: {0}" -f $ex.Message)
        } else {
          Log ("Discord post failed: {0} :: {1}" -f $ex.Message, $errBody)
        }
        return $null
      }

      $delay = [Math]::Min($baseDelaySec * [Math]::Pow(2, $attempt - 1), 30)
      Log ("Discord post transient error (attempt $attempt), retrying in ${delay}s: {0}" -f $ex.Message)
      Start-Sleep -Seconds $delay
    }
  }
}

function Patch-DiscordMessage([string]$webhook, [string]$messageId, [object]$payload) {
  if ([string]::IsNullOrWhiteSpace($webhook)) { throw "PATCH: webhook empty" }
  if ([string]::IsNullOrWhiteSpace($messageId)) { throw "PATCH: messageId empty" }

  $uri = ("{0}/messages/{1}" -f $webhook.TrimEnd('/'), $messageId.Trim())
  $json = $payload | ConvertTo-Json -Depth 16
  $bytes = $Utf8NoBOM.GetBytes($json)
  $headers = @{ 'Content-Type' = 'application/json; charset=utf-8' }

  $maxRetries = 5
  $attempt = 0
  $baseDelaySec = 1
  while ($true) {
    $attempt++
    try {
      return Invoke-RestMethod -Method Patch -Uri $uri -Headers $headers -Body $bytes -TimeoutSec 20
    }
    catch {
      $ex = $_.Exception
      $statusCode = 0
      $retryAfter = $null
      $is429 = $false

      if ($ex.Response -and $ex.Response.StatusCode) {
        $statusCode = [int]$ex.Response.StatusCode
      } elseif ($ex.InnerException -and $ex.InnerException.Response -and $ex.InnerException.Response.StatusCode) {
        $statusCode = [int]$ex.InnerException.Response.StatusCode
      }

      if ($statusCode -eq 429) {
        $is429 = $true
        try {
          if ($ex.Response -and $ex.Response.Headers) {
            $h = $ex.Response.Headers
            if ($h.Contains('Retry-After')) {
              $retryAfter = [int]($h['Retry-After'] | Select-Object -First 1)
            }
          }
        } catch {}
        if (-not $retryAfter -or $retryAfter -lt 1) { $retryAfter = 10 }
      }

      if ($is429) {
        if ($attempt -ge $maxRetries) {
          Log ("Discord PATCH rate limited after $maxRetries retries for message $messageId")
          return $null
        }
        Start-Sleep -Seconds $retryAfter
        continue
      }

      if ($attempt -ge $maxRetries -or ($statusCode -ge 400 -and $statusCode -lt 500 -and $statusCode -ne 429)) {
        $errBody = ""
        try {
          $resp = $ex.Response
          if ($resp) {
            $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
            $errBody = $reader.ReadToEnd()
            $reader.Close()
          }
        } catch {}
        if ([string]::IsNullOrWhiteSpace($errBody)) {
          throw ("PATCH failed: {0}" -f $ex.Message)
        } else {
          throw ("PATCH failed: {0} :: {1}" -f $ex.Message, $errBody)
        }
      }

      $delay = [Math]::Min($baseDelaySec * [Math]::Pow(2, $attempt - 1), 30)
      Start-Sleep -Seconds $delay
    }
  }
}

function Get-Sha256Hex([string]$text) {
  try {
    if ($null -eq $text) { $text = "" }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
      $b = $Utf8NoBOM.GetBytes($text)
      $h = $sha.ComputeHash($b)
      return (([BitConverter]::ToString($h) -replace '-', '').ToLowerInvariant())
    }
    finally { $sha.Dispose() }
  }
  catch { return "" }
}

function Normalize-Slash([string]$s) {
  if ([string]::IsNullOrWhiteSpace($s)) { return "" }
  $s = $s -replace '\\\\', '\'
  $s = $s -replace '/', '\'
  return $s.Trim()
}

function Convert-ToHashtableSafe([object]$obj) {
  $out = @{}

  if ($null -eq $obj) { return $out }

  if ($obj -is [hashtable]) {
    foreach ($k in $obj.Keys) {
      $out[[string]$k] = $obj[$k]
    }
    return $out
  }

  if ($obj -is [System.Collections.IDictionary]) {
    foreach ($k in $obj.Keys) {
      $out[[string]$k] = $obj[$k]
    }
    return $out
  }

  try {
    if ($obj.PSObject -and $obj.PSObject.Properties) {
      foreach ($p in $obj.PSObject.Properties) {
        if ($null -ne $p.Name) {
          $out[[string]$p.Name] = $p.Value
        }
      }
    }
  }
  catch {}

  return $out
}

# ================== MAP CACHE ==================
function Load-MapCache {
  $c = Read-Json $STATE_MAPCACHE
  if (-not $c) { return [pscustomobject]@{ updated_at = ""; maps = @{} } }

  if (-not ($c.PSObject.Properties.Name -contains 'maps') -or -not $c.maps) {
    $c | Add-Member -NotePropertyName maps -NotePropertyValue @{} -Force
    return $c
  }

  if ($c.maps -isnot [hashtable]) {
    $c.maps = Convert-ToHashtableSafe $c.maps
  }

  return $c
}

function Save-MapCache([object]$cache) {
  if (-not $cache) { return }
  $cache.updated_at = (Get-Date).ToString("o")
  Write-JsonAtomic $STATE_MAPCACHE $cache
}

function Cache-UpdateLastOk([object]$cache, [string]$mapKey, [int]$a2sPlayers, [int]$maxPlayers) {
  if (-not $cache.maps -or $cache.maps -isnot [hashtable]) {
    $cache | Add-Member -NotePropertyName maps -NotePropertyValue @{} -Force
    if ($cache.maps -isnot [hashtable]) { $cache.maps = @{} }
  }

  $prev = $null
  if ($cache.maps.ContainsKey($mapKey)) { $prev = $cache.maps[$mapKey] }

  $prevOk = 0
  try { if ($prev -and $prev.ok_streak -ge 0) { $prevOk = [int]$prev.ok_streak } } catch {}

  $firstOk = $(if ($prev -and $prev.first_ok_at) { [string]$prev.first_ok_at } else { (Get-Date).ToString("o") })

  $cache.maps[$mapKey] = [pscustomobject]@{
    last_ok_at   = (Get-Date).ToString("o")
    first_ok_at  = $firstOk
    a2s_players  = $a2sPlayers
    max_players  = $maxPlayers
    fail_streak  = 0
    ok_streak    = ($prevOk + 1)
    last_fail_at = $(if ($prev -and $prev.last_fail_at) { [string]$prev.last_fail_at } else { "" })
  }
}

function Cache-UpdateFail([object]$cache, [string]$mapKey) {
  if (-not $cache.maps -or $cache.maps -isnot [hashtable]) {
    $cache | Add-Member -NotePropertyName maps -NotePropertyValue @{} -Force
    if ($cache.maps -isnot [hashtable]) { $cache.maps = @{} }
  }

  $prev = $null
  if ($cache.maps.ContainsKey($mapKey)) { $prev = $cache.maps[$mapKey] }

  $prevFail = 0
  try { if ($prev -and $prev.fail_streak -ge 0) { $prevFail = [int]$prev.fail_streak } } catch {}

  $lastOkAt = ""
  $lastA2S = -1
  $lastMax = -1
  try { if ($prev -and $prev.last_ok_at) { $lastOkAt = [string]$prev.last_ok_at } } catch {}
  try { if ($prev -and $prev.a2s_players -ge 0) { $lastA2S = [int]$prev.a2s_players } } catch {}
  try { if ($prev -and $prev.max_players -gt 0) { $lastMax = [int]$prev.max_players } } catch {}

  $cache.maps[$mapKey] = [pscustomobject]@{
    last_ok_at   = $lastOkAt
    a2s_players  = $lastA2S
    max_players  = $lastMax
    fail_streak  = ($prevFail + 1)
    ok_streak    = 0
    last_fail_at = (Get-Date).ToString("o")
  }
}
# ==============================================

function Weather-Emoji([string]$state) {
  switch ($state) {
    'rain' { $E_Rain }
    'thunderstorm' { $E_Storm }
    'storm' { $E_Storm }
    'wind' { $E_Wind }
    'snow' { $E_Snow }
    'sandstorm' { $E_Tornado }
    'clear' { $E_SunBehind }
    default { $E_Satellite }
  }
}

function Get-LastWeatherState([string]$dir) {
  try {
    if ([string]::IsNullOrWhiteSpace($dir)) { return $null }
    if (-not (Test-Path $dir)) { return $null }

    $latest = Get-ChildItem -Path $dir -Filter *.log -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) { return $null }

    $lines = Get-Content -Path $latest.FullName -Tail 2500 -ErrorAction SilentlyContinue
    if (-not $lines) { return $null }

    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
      $ln = $lines[$i]
      if ($ln.ToLowerInvariant() -notmatch 'logweathercontroller: display:') { continue }

      $eventName = $null
      if ($ln -match 'ENTERING RAIN/STORM \((?<ev>[^)]+)\)') { $eventName = $Matches['ev'] }
      elseif ($ln -match 'new local weather event:\s*(?<ev>\S+)') { $eventName = $Matches['ev'] }
      elseif ($ln -match 'switching local weather events:\s*\S+\s*--->\s*(?<ev>\S+)') { $eventName = $Matches['ev'] }
      else { continue }

      $ev = ([string]$eventName).ToLowerInvariant()
      if ($ev -eq 'none' -or $ev -like '*clear*') { return 'clear' }

      $tier = $null
      if ($ev -match '^t(?<t>\d+)_') { $tier = [int]$Matches['t'] }
      if ($tier -ge 4) { return 'thunderstorm' }

      if ($ev -like '*sand*' -or $ev -like '*desert*') { return 'sandstorm' }
      elseif ($ev -like '*snow*' -or $ev -like '*arctic*') { return 'snow' }
      elseif ($ev -like '*wind*') { return 'wind' }
      elseif ($ev -like '*lightning*' -or $ev -like '*thunder*') { return 'thunderstorm' }
      elseif ($ev -like '*rain*') { return 'rain' }
      else { return 'storm' }
    }
    return $null
  }
  catch {
    try { Log ("Get-LastWeatherState failed for {0}: {1}" -f $dir, $_.Exception.Message) } catch {}
    return $null
  }
}

function Get-ServerProcessOk([string]$processName, [string]$mustContain) {
  try {
    if ([string]::IsNullOrWhiteSpace($processName)) { return $false }

    $mustContain = Normalize-Slash $mustContain

    if ([string]::IsNullOrWhiteSpace($mustContain)) {
      $procs = Get-CimInstance Win32_Process -Filter ("Name LIKE '{0}%'" -f $processName) -ErrorAction SilentlyContinue
      return [bool]($procs | Select-Object -First 1)
    }

    $procs = Get-CimInstance Win32_Process -Filter ("Name LIKE '{0}%'" -f $processName) -ErrorAction SilentlyContinue
    foreach ($pr in $procs) {
      $cmd = Normalize-Slash ([string]$pr.CommandLine)
      if ($cmd -and ($cmd -like "*$mustContain*")) { return $true }
    }
    return $false
  }
  catch { return $false }
}

function Get-ServerProcessStartTimeRelaxed([string]$processName, [string]$mustContain, [string]$wgsmFolder = "") {
  try {
    if ([string]::IsNullOrWhiteSpace($processName)) { return $null }

    $mustContain = Normalize-Slash $mustContain
    $wgsmFolder = ([string]$wgsmFolder).Trim()

    $procs = Get-CimInstance Win32_Process -Filter ("Name LIKE '{0}%'" -f $processName) -ErrorAction SilentlyContinue
    if (-not $procs) { return $null }

    if (-not [string]::IsNullOrWhiteSpace($mustContain)) {
      foreach ($pr in $procs) {
        $cmd = Normalize-Slash ([string]$pr.CommandLine)
        if ($cmd -and ($cmd -like "*$mustContain*")) {
          return [System.Management.ManagementDateTimeConverter]::ToDateTime($pr.CreationDate)
        }
      }
    }

    if (-not [string]::IsNullOrWhiteSpace($wgsmFolder)) {
      $needle1 = Normalize-Slash ("\servers\{0}\" -f $wgsmFolder)
      $needle2 = Normalize-Slash ("\servers\{0}\serverfiles" -f $wgsmFolder)

      foreach ($pr in $procs) {
        $cmd = Normalize-Slash ([string]$pr.CommandLine)
        if ($cmd -and (($cmd -like "*$needle1*") -or ($cmd -like "*$needle2*"))) {
          return [System.Management.ManagementDateTimeConverter]::ToDateTime($pr.CreationDate)
        }
      }
    }

    if (@($procs).Count -eq 1) {
      return [System.Management.ManagementDateTimeConverter]::ToDateTime($procs[0].CreationDate)
    }

    return $null
  }
  catch { return $null }
}

function Get-ProcStartTimeFromPidFile([object]$serverEntry) {
  try {
    $pidFile = $null
    try {
      if ($serverEntry -and ($serverEntry.PSObject.Properties.Name -contains 'ops') -and $serverEntry.ops) {
        if ($serverEntry.ops.PSObject.Properties.Name -contains 'pidFile') { $pidFile = [string]$serverEntry.ops.pidFile }
      }
    }
    catch {}

    if ([string]::IsNullOrWhiteSpace($pidFile)) { return $null }
    if (-not (Test-Path $pidFile)) { return $null }

    $pidText = (Get-Content $pidFile -Raw -ErrorAction SilentlyContinue).Trim()
    if ($pidText -notmatch '^\d+$') { return $null }
    $procId = [int]$pidText

    $p = Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f $procId) -ErrorAction SilentlyContinue
    if (-not $p) { return $null }

    $cd = $null
    try { $cd = $p.CreationDate } catch { $cd = $null }
    if (-not $cd) { return $null }

    if ($cd -is [datetime]) { return $cd }
    return [System.Management.ManagementDateTimeConverter]::ToDateTime([string]$cd)
  }
  catch { return $null }
}

function Get-A2SPlayers([string]$ip, [int]$port, [ref]$maxPlayers) {
  $client = $null
  try {
    $maxPlayers.Value = -1
    $client = New-Object System.Net.Sockets.UdpClient
    $client.Client.ReceiveTimeout = 1500
    $client.Connect($ip, $port)

    $base = [byte[]](0xFF, 0xFF, 0xFF, 0xFF, 0x54) + ([System.Text.Encoding]::ASCII.GetBytes("Source Engine Query")) + 0x00
    [void]$client.Send($base, $base.Length)

    $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
    $resp = $client.Receive([ref]$remote)
    if (-not $resp -or $resp.Length -lt 5) { return -1 }

    if ($resp[4] -eq 0x41) {
      if ($resp.Length -lt 9) { return -1 }
      $challenge = $resp[5..8]
      $req2 = $base + $challenge
      [void]$client.Send($req2, $req2.Length)
      $resp = $client.Receive([ref]$remote)
    }

    if (-not $resp -or $resp.Length -lt 12 -or $resp[4] -ne 0x49) { return -1 }

    function ReadZ([byte[]]$bytes, [ref]$idx) {
      $start = $idx.Value
      while ($idx.Value -lt $bytes.Length -and $bytes[$idx.Value] -ne 0) { $idx.Value++ }
      if ($idx.Value -ge $bytes.Length) { return $null }
      $str = [System.Text.Encoding]::UTF8.GetString($bytes, $start, $idx.Value - $start)
      $idx.Value++
      return $str
    }

    function ReadUInt16LE([byte[]]$bytes, [ref]$idx) {
      if ($idx.Value + 1 -ge $bytes.Length) { throw "OOB UInt16" }
      $v = [int]($bytes[$idx.Value] -bor ($bytes[$idx.Value + 1] -shl 8))
      $idx.Value += 2
      return $v
    }

    function ReadByte([byte[]]$bytes, [ref]$idx) {
      if ($idx.Value -ge $bytes.Length) { throw "OOB byte" }
      $v = [int]$bytes[$idx.Value]
      $idx.Value++
      return $v
    }

    $i = 5
    $ri = [ref]$i

    $null = ReadByte $resp $ri
    $null = ReadZ $resp $ri
    $null = ReadZ $resp $ri
    $null = ReadZ $resp $ri
    $null = ReadZ $resp $ri
    $null = ReadUInt16LE $resp $ri
    $players = ReadByte $resp $ri
    $maxp = ReadByte $resp $ri

    $maxPlayers.Value = $maxp
    return $players
  }
  catch {
    $maxPlayers.Value = -1
    return -1
  }
  finally {
    if ($client) { $client.Close() }
  }
}

function Get-A2SPlayerNames([string]$ip, [int]$port) {
  $client = $null
  try {
    $client = New-Object System.Net.Sockets.UdpClient
    $client.Client.ReceiveTimeout = 1500
    $client.Connect($ip, $port)

    $challengeReq = [byte[]](0xFF, 0xFF, 0xFF, 0xFF, 0x55, 0xFF, 0xFF, 0xFF, 0xFF)
    [void]$client.Send($challengeReq, $challengeReq.Length)

    $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
    $resp = $client.Receive([ref]$remote)
    if (-not $resp -or $resp.Length -lt 9) { return $null }
    if ($resp[4] -ne 0x41) { return $null }

    $challenge = $resp[5..8]
    $playerReq = [byte[]](0xFF, 0xFF, 0xFF, 0xFF, 0x55) + $challenge
    [void]$client.Send($playerReq, $playerReq.Length)

    $resp2 = $client.Receive([ref]$remote)
    if (-not $resp2 -or $resp2.Length -lt 6) { return $null }
    if ($resp2[4] -ne 0x44) { return $null }

    $count = [int]$resp2[5]
    $i = 6
    $names = New-Object System.Collections.Generic.List[string]

    for ($p = 0; $p -lt $count; $p++) {
      if ($i -ge $resp2.Length) { break }

      $i++ # index

      $start = $i
      while ($i -lt $resp2.Length -and $resp2[$i] -ne 0) { $i++ }
      if ($i -ge $resp2.Length) { break }

      $rawName = [System.Text.Encoding]::UTF8.GetString($resp2, $start, $i - $start)
      $i++

      if ($i + 3 -ge $resp2.Length) { break }
      $i += 4

      if ($i + 3 -ge $resp2.Length) { break }
      $i += 4

      $nm = Normalize-PlayerName $rawName
      if ($nm) { $names.Add($nm) | Out-Null }
    }

    return @($names | Select-Object -Unique)
  }
  catch {
    return $null
  }
  finally {
    if ($client) { $client.Close() }
  }
}

# ================== PLAYERS / ACTIVITY STATE ==================
function Load-PlayersState {
  $st = Read-Json $STATE_PLAYERS
  if (-not $st) {
    return [pscustomobject]@{
      updated_at = ""
      maps       = @{}
      tip_bag    = @()
      last_tip   = ""
      debounce   = @{}
    }
  }

  if (-not ($st.PSObject.Properties.Name -contains 'maps') -or -not $st.maps) {
    $st | Add-Member -NotePropertyName maps -NotePropertyValue @{} -Force
  }
  if (-not ($st.PSObject.Properties.Name -contains 'tip_bag') -or -not $st.tip_bag) {
    $st | Add-Member -NotePropertyName tip_bag -NotePropertyValue @() -Force
  }
  if (-not ($st.PSObject.Properties.Name -contains 'debounce') -or -not $st.debounce) {
    $st | Add-Member -NotePropertyName debounce -NotePropertyValue @{} -Force
  }

  if ($st.maps -isnot [hashtable]) {
    $st.maps = Convert-ToHashtableSafe $st.maps
  }
  if ($st.debounce -isnot [hashtable]) {
    $st.debounce = Convert-ToHashtableSafe $st.debounce
  }

  return $st
}

function Save-PlayersState([object]$st) {
  if (-not $st) { return }

  # --- PRUNE DEBOUNCE (limit to recent events) ---
  if ($st.debounce -and $st.debounce.Count -gt 1000) {
    $now = Get-Date
    $toRemove = @()
    foreach ($k in $st.debounce.Keys) {
      try {
        $dt = [DateTime]::Parse([string]$st.debounce[$k])
        if (($now - $dt).TotalHours -gt 48) { $toRemove += $k }
      }
      catch { $toRemove += $k }
    }
    foreach ($k in $toRemove) { [void]$st.debounce.Remove($k) }
  }

  # --- PRUNE STEAM MAPPINGS (limit to 5000 entries) ---
  if ($st.maps) {
    $now = Get-Date
    foreach ($mk in $st.maps.Keys) {
      $ms = $st.maps[$mk]

      # --- 4-HOUR ROSTER CLEANUP ---
      if ($ms.online) {
        $toRemove = @()
        foreach ($name in $ms.online.Keys) {
          try {
            $since = [DateTime]::Parse([string]$ms.online[$name])
            if (($now - $since).TotalHours -gt 4) { $toRemove += $name }
          }
          catch { $toRemove += $name }
        }
        foreach ($name in $toRemove) { [void]$ms.online.Remove($name) }
      }
      if ($ms.onlineSteam) {
        $toRemove = @()
        foreach ($id in $ms.onlineSteam.Keys) {
          try {
            $since = [DateTime]::Parse([string]$ms.onlineSteam[$id])
            if (($now - $since).TotalHours -gt 4) { $toRemove += $id }
          }
          catch { $toRemove += $id }
        }
        foreach ($id in $toRemove) { [void]$ms.onlineSteam.Remove($id) }
      }

      if ($ms.steam -and $ms.steam.Count -gt 5000) {
        $ms.steam = @{}
      }
    }
  }

  $st.updated_at = (Get-Date).ToString("o")
  Write-JsonAtomic $STATE_PLAYERS $st 10
}

function Ensure-MapPlayersState([object]$st, [string]$mapKey) {
  if (-not $st.maps) { $st | Add-Member -NotePropertyName maps -NotePropertyValue @{} -Force }
  if ($st.maps -isnot [hashtable]) { $st.maps = Convert-ToHashtableSafe $st.maps }

  if (-not $st.maps.ContainsKey($mapKey)) {
    $st.maps[$mapKey] = [pscustomobject]@{
      logtail     = [pscustomobject]@{
        file   = ""
        offset = 0
        carry  = ""
      }
      online      = @{}
      onlineSteam = @{}
      events      = @()
      steam       = @{}
    }
  }

  $ms = $st.maps[$mapKey]

  if (-not ($ms.PSObject.Properties.Name -contains 'online') -or -not $ms.online) {
    $ms | Add-Member -NotePropertyName online -NotePropertyValue @{} -Force
  }
  if ($ms.online -isnot [hashtable]) {
    $ms.online = Convert-ToHashtableSafe $ms.online
  }

  if (-not ($ms.PSObject.Properties.Name -contains 'onlineSteam') -or -not $ms.onlineSteam) {
    $ms | Add-Member -NotePropertyName onlineSteam -NotePropertyValue @{} -Force
  }
  if ($ms.onlineSteam -isnot [hashtable]) {
    $ms.onlineSteam = Convert-ToHashtableSafe $ms.onlineSteam
  }

  if (-not ($ms.PSObject.Properties.Name -contains 'events') -or -not $ms.events) {
    $ms | Add-Member -NotePropertyName events -NotePropertyValue @() -Force
  }

  if (-not ($ms.PSObject.Properties.Name -contains 'logtail') -or -not $ms.logtail) {
    $ms | Add-Member -NotePropertyName logtail -NotePropertyValue ([pscustomobject]@{ file = ""; offset = 0; carry = "" }) -Force
  }
  else {
    if (-not ($ms.logtail.PSObject.Properties.Name -contains 'file')) { $ms.logtail | Add-Member -NotePropertyName file   -NotePropertyValue "" -Force }
    if (-not ($ms.logtail.PSObject.Properties.Name -contains 'offset')) { $ms.logtail | Add-Member -NotePropertyName offset -NotePropertyValue 0  -Force }
    if (-not ($ms.logtail.PSObject.Properties.Name -contains 'carry')) { $ms.logtail | Add-Member -NotePropertyName carry  -NotePropertyValue "" -Force }
  }

  if (-not ($ms.PSObject.Properties.Name -contains 'steam') -or -not $ms.steam) {
    $ms | Add-Member -NotePropertyName steam -NotePropertyValue @{} -Force
  }
  if ($ms.steam -isnot [hashtable]) {
    $ms.steam = Convert-ToHashtableSafe $ms.steam
  }

  $st.maps[$mapKey] = $ms
  return $ms
}

function Normalize-PlayerName([string]$name) {
  if ([string]::IsNullOrWhiteSpace($name)) { return $null }
  $n = $name.Trim()
  $n = $n -replace '\[HOST\]', ''
  $n = [regex]::Replace($n, '\s+', ' ')
  $n = $n.Trim()
  $n = ($n -replace '[\[\]\(\),"]', '').Trim()
  $n = $n.TrimEnd('.', ':', ';', '!', '?', '#', '-', '_')
  if ($n -eq '' -or $n -eq '(unknown)' -or $n -eq '(null)') { return $null }
  if ($n -match '^[\-_]?\d{6,}$') { return $null }

  $parts = $n.Split(' ')
  if ($parts.Count -gt 1) {
    $withUnderscore = $parts | Where-Object { $_ -like '*_*' }
    if ($withUnderscore.Count -eq 1) { $n = $withUnderscore[0] }
  }

  $n = $n.Trim()
  $n = $n.TrimEnd('.', ':', ';', '!', '?', '#', '-', '_')
  if ($n -match '^[\-_]?\d{6,}$') { return $null }
  return $n
}

function Get-LatestLogFilePath([string]$dir) {
  try {
    if ([string]::IsNullOrWhiteSpace($dir)) { return $null }
    if (-not (Test-Path $dir)) { return $null }
    $f = Get-ChildItem -Path $dir -Filter *.log -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $f) { return $null }
    return $f.FullName
  }
  catch { return $null }
}

function Read-AppendedLinesFromTail([object]$tail, [string]$path) {
  $lines = New-Object System.Collections.Generic.List[string]
  $fs = $null

  try {
    $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')

    if ([long]$tail.offset -gt $fs.Length) {
      $tail.offset = $fs.Length
      $tail.carry = ""
      return @()
    }

    if ($fs.Length -eq [long]$tail.offset) { return @() }
    [void]$fs.Seek([long]$tail.offset, 'Begin')

    $bufSize = 65536
    $buf = New-Object byte[] $bufSize
    $ms = New-Object System.IO.MemoryStream

    while ($true) {
      $read = $fs.Read($buf, 0, $buf.Length)
      if ($read -le 0) { break }
      $ms.Write($buf, 0, $read)
    }

    $tail.offset = $fs.Position
    $rawBytes = $ms.ToArray()
    if (-not $rawBytes -or $rawBytes.Length -eq 0) { return @() }

    $encoding = $null

    if ($rawBytes.Length -ge 3 -and $rawBytes[0] -eq 0xEF -and $rawBytes[1] -eq 0xBB -and $rawBytes[2] -eq 0xBF) {
      $encoding = [System.Text.UTF8Encoding]::new($true)
    }
    elseif ($rawBytes.Length -ge 2 -and $rawBytes[0] -eq 0xFF -and $rawBytes[1] -eq 0xFE) {
      $encoding = [System.Text.Encoding]::Unicode
    }
    elseif ($rawBytes.Length -ge 2 -and $rawBytes[0] -eq 0xFE -and $rawBytes[1] -eq 0xFF) {
      $encoding = [System.Text.Encoding]::BigEndianUnicode
    }
    else {
      $encoding = [System.Text.UTF8Encoding]::new($false, $false)
    }

    $chunk = $encoding.GetString($rawBytes)
    if ([string]::IsNullOrEmpty($chunk)) { return @() }

    # Cap carry buffer to prevent memory bloat from malformed logs
    if ($tail.carry -and $tail.carry.Length -gt 10000) { $tail.carry = "" }

    $text = (($tail.carry) + $chunk) -replace "`r", ""
    $parts = $text -split "`n", -1
    if ($parts.Count -eq 0) { return @() }

    if (-not $text.EndsWith("`n")) {
      $tail.carry = $parts[$parts.Count - 1]
      if ($parts.Count -ge 2) { $parts = $parts[0..($parts.Count - 2)] } else { $parts = @() }
    }
    else {
      $tail.carry = ""
    }

    foreach ($p in $parts) {
      $l = $p.TrimEnd()
      if ($l -ne "") { $lines.Add($l) | Out-Null }
    }

    return $lines.ToArray()
  }
  catch {
    return @()
  }
  finally {
    if ($fs) { $fs.Dispose() }
  }
}

function Parse-LogEvents([string[]]$newLines) {
  $events = New-Object System.Collections.Generic.List[object]

  foreach ($l in $newLines) {
    if ([string]::IsNullOrWhiteSpace($l)) { continue }

    if ($l -match 'LogConnectedPlayers:\s*Display:\s*AddConnectedPlayer\s*-\s*UserId:\s*(?<id>\d{6,20})\s*\|\s*PlayerName:\s*(?<p>.+)$') {
      $p = Normalize-PlayerName $Matches.p
      $id = [string]$Matches.id
      if ($p -and $id) {
        $events.Add([pscustomobject]@{
            type   = 'join'
            player = $p
            steam  = $id
            raw    = $l
          }) | Out-Null
      }
      continue
    }

    if ($l -match 'LogConnectedPlayers:\s*Verbose:\s*OnRep_ConnectedPlayers ConnectedPlayer at index \[\d+\] - PlayerID:\s*(?<id>\d{6,20})_\d+\s*\|\s*Initialised:\s*true') {
      $id = [string]$Matches.id
      if ($id) {
        $events.Add([pscustomobject]@{
            type  = 'join_id_only'
            steam = $id
            raw   = $l
          }) | Out-Null
      }
      continue
    }

    if ($l -match 'LogNet:\s*Join succeeded:\s*(?<p>.+)$') {
      $p = Normalize-PlayerName $Matches.p
      if ($p) {
        $events.Add([pscustomobject]@{
            type   = 'join_name_only'
            player = $p
            raw    = $l
          }) | Out-Null
      }
      continue
    }

    if ($l -match 'LogNet:\s*Login request:\s*.*\?Name=(?<p>[^?\s]+)') {
      $p = Normalize-PlayerName $Matches.p
      if ($p) {
        $events.Add([pscustomobject]@{
            type   = 'join_name_only'
            player = $p
            raw    = $l
          }) | Out-Null
      }
      continue
    }

    if ($l -match 'LogOnline:\s*STEAM:\s*(?<id>\d{6,20})\s+has been removed\.') {
      $id = [string]$Matches.id
      if ($id) {
        $events.Add([pscustomobject]@{
            type  = 'leave'
            steam = $id
            raw   = $l
          }) | Out-Null
      }
      continue
    }
  }

  return $events.ToArray()
}

function Debounce-PlayerEvent([object]$st, [string]$mapKey, [string]$player, [string]$type) {
  try {
    if (-not $st.debounce) { $st.debounce = @{} }
    if ($st.debounce -isnot [hashtable]) {
      $st.debounce = Convert-ToHashtableSafe $st.debounce
    }

    $now = Get-Date
    $k = "{0}|{1}|{2}" -f $mapKey, $player, $type
    if ($st.debounce.ContainsKey($k)) {
      $prev = $null
      try { $prev = [DateTime]::Parse([string]$st.debounce[$k]) } catch { $prev = $null }
      if ($prev) {
        $gap = ($now - $prev).TotalSeconds
        if ($gap -lt $PlayerDebounceSeconds) { return $false }
      }
    }

    $st.debounce[$k] = $now.ToString("o")
    return $true
  }
  catch { return $true }
}

function Apply-SyntheticLeavesOnA2SDrop([object]$st, [string]$mapKey, [int]$prevA2S, [int]$currA2S) {
  try {
    if ($prevA2S -le 0) { return }
    if ($currA2S -ne 0) { return }

    $ms = Ensure-MapPlayersState $st $mapKey
    if (-not $ms -or -not $ms.onlineSteam -or $ms.onlineSteam.Count -eq 0) { return }

    $now = Get-Date
    $steamIds = @($ms.onlineSteam.Keys)

    foreach ($steam in $steamIds) {
      if ([string]::IsNullOrWhiteSpace([string]$steam)) { continue }

      $sinceSteam = $null
      try { $sinceSteam = [DateTime]::Parse([string]$ms.onlineSteam[$steam]) } catch { $sinceSteam = $null }
      if ($sinceSteam) {
        if ((($now - $sinceSteam).TotalSeconds) -lt $JoinLeaveGraceSeconds) { continue }
      }

      $p = $null
      try {
        if ($ms.steam.ContainsKey($steam)) { $p = Normalize-PlayerName ([string]$ms.steam[$steam]) }
      }
      catch {}

      if (-not $p) { continue }

      if (-not (Debounce-PlayerEvent $st $mapKey $p 'leave')) { continue }

      $dur = Get-PlayerDuration $ms $p $steam $now
      try { $ms.onlineSteam.Remove($steam) | Out-Null } catch {}
      try { if ($ms.online.ContainsKey($p)) { $ms.online.Remove($p) | Out-Null } } catch {}

      $ms.events += @([pscustomobject]@{
          ts       = $now.ToString("o")
          type     = "leave"
          name     = ("{0} (timeout)" -f $p)
          duration = $dur
        })
    }

    if ($ms.events.Count -gt $MaxEventsPerMap) {
      $ms.events = @($ms.events | Select-Object -Last $MaxEventsPerMap)
    }

    $st.maps[$mapKey] = $ms
  }
  catch { return }
}

function Get-PlayerDuration([object]$ms, [string]$name, [string]$steam, [datetime]$now) {
  $since = $null
  if ($steam -and $ms.onlineSteam -and $ms.onlineSteam.ContainsKey($steam)) {
    try { $since = [DateTime]::Parse([string]$ms.onlineSteam[$steam]) } catch {}
  }
  if (-not $since -and $name -and $ms.online -and $ms.online.ContainsKey($name)) {
    try { $since = [DateTime]::Parse([string]$ms.online[$name]) } catch {}
  }
  if ($since) {
    $ts = $now - $since
    if ($ts.TotalSeconds -ge 0) { return (Format-Duration $ts) }
  }
  return $null
}

function Apply-MapEvents([object]$st, [string]$mapKey, [object[]]$events) {
  $ms = Ensure-MapPlayersState $st $mapKey
  $now = Get-Date

  foreach ($ev in $events) {
    $type = [string]$ev.type

    $p = $null
    $steam = $null
    try { if ($ev.PSObject.Properties.Name -contains 'steam') { $steam = [string]$ev.steam } } catch { $steam = $null }

    if ($ev.PSObject.Properties.Name -contains 'player') {
      $p = Normalize-PlayerName ([string]$ev.player)
    }

    if ($type -eq 'join') {
      if ($steam -and $p) {
        $ms.steam[$steam] = $p
        $ms.onlineSteam[$steam] = $now.ToString("o")
      }

      if (-not $p) { continue }
      if (-not (Debounce-PlayerEvent $st $mapKey $p $type)) { continue }

      $alreadyOnline = $false
      if ($ms.online.ContainsKey($p)) {
        try {
          $since = [DateTime]::Parse([string]$ms.online[$p])
          if ((($now - $since).TotalSeconds) -lt 300) { $alreadyOnline = $true }
        }
        catch {}
      }

      if (-not $alreadyOnline) {
        $ms.online[$p] = $now.ToString("o")
        $ms.events += @([pscustomobject]@{
            ts   = $now.ToString("o")
            type = "join"
            name = $p
          })
      }

      continue
    }

    if ($type -eq 'join_id_only') {
      if ($steam) {
        $ms.onlineSteam[$steam] = $now.ToString("o")
      }
      continue
    }

    if ($type -eq 'join_name_only') {
      if (-not $p) { continue }
      if (-not (Debounce-PlayerEvent $st $mapKey $p $type)) { continue }

      $alreadyOnline = $false
      if ($ms.online.ContainsKey($p)) {
        try {
          $since = [DateTime]::Parse([string]$ms.online[$p])
          if ((($now - $since).TotalSeconds) -lt 300) { $alreadyOnline = $true }
        }
        catch {}
      }

      if (-not $alreadyOnline) {
        $ms.online[$p] = $now.ToString("o")
        $ms.events += @([pscustomobject]@{
            ts   = $now.ToString("o")
            type = "join"
            name = $p
          })
      }

      continue
    }

    if ($type -eq 'leave') {
      if (-not $steam) { continue }
      if (-not $ms.onlineSteam.ContainsKey($steam)) { continue }

      $sinceSteam = $null
      try { $sinceSteam = [DateTime]::Parse([string]$ms.onlineSteam[$steam]) } catch { $sinceSteam = $null }
      if ($sinceSteam) {
        if ((($now - $sinceSteam).TotalSeconds) -lt $JoinLeaveGraceSeconds) {
          continue
        }
      }

      if (-not $p) {
        try {
          if ($ms.steam.ContainsKey($steam)) { $p = Normalize-PlayerName ([string]$ms.steam[$steam]) }
        }
        catch {}
      }
      if (-not $p) { continue }

      if (-not (Debounce-PlayerEvent $st $mapKey $p 'leave')) { continue }

      $dur = Get-PlayerDuration $ms $p $steam $now
      $ms.onlineSteam.Remove($steam) | Out-Null
      if ($ms.online.ContainsKey($p)) { $ms.online.Remove($p) | Out-Null }

      $ms.events += @([pscustomobject]@{
          ts       = $now.ToString("o")
          type     = "leave"
          name     = $p
          duration = $dur
        })

      continue
    }
  }

  if ($ms.events.Count -gt $MaxEventsPerMap) {
    $ms.events = @($ms.events | Select-Object -Last $MaxEventsPerMap)
  }

  $st.maps[$mapKey] = $ms
}

function Sync-OnlineRosterFromA2SNames([object]$st, [string]$mapKey, [string[]]$a2sNames) {
  try {
    if ($null -eq $a2sNames) { return }

    $ms = Ensure-MapPlayersState $st $mapKey
    $now = Get-Date

    $normalized = @()
    foreach ($nm in @($a2sNames)) {
      $n = Normalize-PlayerName ([string]$nm)
      if ($n) { $normalized += $n }
    }
    $normalized = @($normalized | Select-Object -Unique)

    $currentSet = @{}
    foreach ($n in $normalized) { $currentSet[$n] = $true }

    foreach ($n in $normalized) {
      if (-not $ms.online.ContainsKey($n)) {
        $ms.online[$n] = $now.ToString("o")
      }
    }

    $toRemove = @()
    foreach ($name in @($ms.online.Keys)) {
      if (-not $currentSet.ContainsKey([string]$name)) {
        $toRemove += [string]$name
      }
    }

    foreach ($name in $toRemove) {
      $clean = Normalize-PlayerName $name
      if ($clean -and (Debounce-PlayerEvent $st $mapKey $clean 'leave_a2s')) {
        $dur = Get-PlayerDuration $ms $clean $null $now
        $ms.events += @([pscustomobject]@{
            ts       = $now.ToString("o")
            type     = "leave"
            name     = $clean
            duration = $dur
          })
      }
      try { $ms.online.Remove($name) | Out-Null } catch {}
    }

    $steamToRemove = @()
    foreach ($steamId in @($ms.onlineSteam.Keys)) {
      $mapped = $null
      try {
        if ($ms.steam.ContainsKey($steamId)) {
          $mapped = Normalize-PlayerName ([string]$ms.steam[$steamId])
        }
      }
      catch {}
      if ($mapped -and -not $currentSet.ContainsKey($mapped)) {
        $steamToRemove += [string]$steamId
      }
    }

    foreach ($steamId in $steamToRemove) {
      try { $ms.onlineSteam.Remove($steamId) | Out-Null } catch {}
    }

    if ($ms.events.Count -gt $MaxEventsPerMap) {
      $ms.events = @($ms.events | Select-Object -Last $MaxEventsPerMap)
    }

    $st.maps[$mapKey] = $ms
  }
  catch { return }
}

function Get-RotatingTip([object]$st) {
  try {
    if (-not $TipsVariants -or $TipsVariants.Count -eq 0) { return $null }

    if (-not $st.tip_bag -or $st.tip_bag.Count -eq 0) {
      $st.tip_bag = @($TipsVariants | Sort-Object { Get-Random })
    }

    $tip = $st.tip_bag[0]
    if ($st.tip_bag.Count -gt 1) {
      $st.tip_bag = @($st.tip_bag[1..($st.tip_bag.Count - 1)])
    }
    else {
      $st.tip_bag = @()
    }

    if ([string]::IsNullOrWhiteSpace($tip)) { return $null }
    $st.last_tip = [string]$tip
    return ("**Tip:** {0}" -f $tip)
  }
  catch { return $null }
}

function Reconcile-OnlineRosterToA2S([object]$playersState, [string]$mapKey, [int]$a2sPlayersNow) {
  try {
    if ($a2sPlayersNow -lt 0) { return }

    $ms = Ensure-MapPlayersState $playersState $mapKey
    if (-not $ms) { return }

    # If server says nobody is online, do not clear here.
    # Synthetic leave generation and A2S-name reconciliation need the previous roster/Steam mapping.
    # Display code already hides online names when A2S count is 0.
    if ($a2sPlayersNow -eq 0) {
      $playersState.maps[$mapKey] = $ms
      return
    }

    # Do NOT trim named roster by count alone.
    # If A2S names/log leaves are missing, trimming by timestamp can keep the wrong player online.
    # Let Sync-OnlineRosterFromA2SNames or log-based leave events handle identity.
    $playersState.maps[$mapKey] = $ms
  }
  catch { return }
}

function Build-RecentActivityLines([object]$playersState, [object[]]$rows, [datetime]$now) {
  $cutLeave = $now.AddSeconds(-1 * $LeaveDisplaySeconds)
  $perMapLines = New-Object System.Collections.Generic.List[string]
  $anyRecent = $false

  foreach ($r in $rows) {
    $mapKey = Clean-Key ([string]$r.key)
    if ([string]::IsNullOrWhiteSpace($mapKey)) { continue }

    $a2sPlayersNow = -1
    try { $a2sPlayersNow = [int]$r.a2s_players } catch { $a2sPlayersNow = -1 }

    $ms = $null
    try {
      if ($playersState.maps -and $playersState.maps.ContainsKey($mapKey)) { $ms = $playersState.maps[$mapKey] }
    }
    catch { $ms = $null }

    if (-not $ms) { continue }

    $onlineBits = New-Object System.Collections.Generic.List[string]
    try {
      if ($a2sPlayersNow -gt 0) {
        $knownNames = @()
        if ($ms.online -and $ms.online.Count -gt 0) {
          $knownNames = @($ms.online.Keys) | Sort-Object
        }

        $showCount = [Math]::Min($knownNames.Count, [Math]::Max(0, $a2sPlayersNow))

        if ($showCount -gt 0) {
          foreach ($name in ($knownNames | Select-Object -First $showCount)) {
            $since = $null
            try { $since = [DateTime]::Parse([string]$ms.online[$name]) } catch { $since = $null }
            $dur = if ($since) { Format-Duration ($now - $since) } else { "" }
            $nm = Clean-Key ([string]$name)
            if ([string]::IsNullOrWhiteSpace($nm)) { continue }

            if ([string]::IsNullOrWhiteSpace($dur)) {
              $onlineBits.Add(("[+] {0}" -f $nm)) | Out-Null
            }
            else {
              $onlineBits.Add(("[+] {0} ({1})" -f $nm, $dur)) | Out-Null
            }
          }
        }

        $unknownCount = $a2sPlayersNow - $showCount
        if ($unknownCount -gt 0) {
          $onlineBits.Add(("[+] {0} unknown" -f $unknownCount)) | Out-Null
        }
      }
    }
    catch {}

    $leaveBits = New-Object System.Collections.Generic.List[string]
    try {
      if ($ms.events -and $ms.events.Count -gt 0) {
        foreach ($e in @($ms.events | Select-Object -Last 25)) {
          if ($e.type -ne 'leave') { continue }
          $dt = $null
          try { $dt = [DateTime]::Parse([string]$e.ts) } catch { $dt = $null }
          if (-not $dt -or $dt -lt $cutLeave) { continue }

          $nm = Clean-Key ([string]$e.name)
          if ([string]::IsNullOrWhiteSpace($nm)) { continue }

          $rel = Format-RelativeTime $dt
          $durStr = ""
          if ($e.duration) { $durStr = " [online {0}]" -f $e.duration }
          $leaveBits.Add(("[-] {0} ({1}){2}" -f $nm, $rel, $durStr)) | Out-Null
        }
      }
    }
    catch {}

    if (($onlineBits.Count -eq 0) -and ($leaveBits.Count -eq 0)) { continue }

    $anyRecent = $true

    $showOnlineMax = 6
    $showLeaveMax = 3

    $onlineShown = @($onlineBits | Select-Object -First $showOnlineMax)
    $leaveShown = @($leaveBits | Select-Object -Last $showLeaveMax)

    $bits = @()
    $header = @("**{0}:**" -f $mapKey)
    if ($onlineShown.Count -gt 0) { $bits += $onlineShown }
    if ($leaveShown.Count -gt 0) { $bits += $leaveShown }

    if ($onlineBits.Count -gt $showOnlineMax) {
      $bits += ("+{0} more" -f ($onlineBits.Count - $showOnlineMax))
    }

    $perMapLines.Add(("{0} {1}" -f ($header -join " "), ($bits -join " · "))) | Out-Null
  }

  return [pscustomobject]@{
    any_recent = [bool]$anyRecent
    lines      = @($perMapLines)
  }
}

function Get-CombinedState([object]$combinedEntry) {
  $st = Read-Json $STATE_COMBINED

  if (-not $st) {
    $seed = ""
    try { if ($combinedEntry.discordMessageId) { $seed = [string]$combinedEntry.discordMessageId } } catch {}

    return [pscustomobject]@{
      message_id        = $seed
      last_payload_hash = ""
      updated_at        = ""
    }
  }

  if (-not ($st.PSObject.Properties.Name -contains 'message_id')) {
    $legacy = ""
    try {
      if ($st.PSObject.Properties.Name -contains 'messageId') {
        $legacy = [string]$st.messageId
      }
    }
    catch {}

    $st | Add-Member -NotePropertyName message_id -NotePropertyValue $legacy -Force
  }

  if (-not ($st.PSObject.Properties.Name -contains 'last_payload_hash')) {
    $st | Add-Member -NotePropertyName last_payload_hash -NotePropertyValue "" -Force
  }

  if (-not ($st.PSObject.Properties.Name -contains 'updated_at')) {
    $st | Add-Member -NotePropertyName updated_at -NotePropertyValue "" -Force
  }

  return $st
}

function Save-CombinedState([object]$state) {
  try {
    $state.updated_at = (Get-Date).ToString("o")
    Write-JsonAtomic $STATE_COMBINED $state
    Log ("Saved combined state -> {0}" -f $STATE_COMBINED)
  }
  catch {
    Log ("Save-CombinedState failed -> {0}" -f $_.Exception.Message)
    throw
  }
}

function Ensure-MessageIdAndPatch([string]$webhook, [object]$state, [object]$payload) {
  if ($state -and -not [string]::IsNullOrWhiteSpace([string]$state.message_id)) {
    try {
      Patch-DiscordMessage $webhook ([string]$state.message_id) $payload | Out-Null
      Log ("PATCH ok -> message_id={0}" -f [string]$state.message_id)
      return [string]$state.message_id
    }
    catch {
      Log ("PATCH failed for message_id={0} :: {1}" -f [string]$state.message_id, $_.Exception.Message)
    }
  }
  else {
    Log "No stored message_id found -> POST new message"
  }

  $resp = Post-Discord $webhook $payload -Wait
  if ($resp -and $resp.id) {
    $state.message_id = [string]$resp.id
    Log ("POST created new message_id={0}" -f [string]$state.message_id)
    Save-CombinedState $state
    return [string]$state.message_id
  }

  throw "Ensure-MessageIdAndPatch: could not POST message (no response id)"
}

function Format-RelativeTime([datetime]$dt) {
  try {
    $ts = ((Get-Date) - $dt)
    if ($ts.TotalSeconds -lt 0) { $ts = -$ts }
    if ($ts.TotalMinutes -lt 1) { return "just now" }
    if ($ts.TotalHours -lt 1) { return ("{0}m ago" -f [int]$ts.TotalMinutes) }
    if ($ts.TotalDays -lt 1) { return ("{0}h {1}m ago" -f [int]$ts.TotalHours, $ts.Minutes) }
    return ("{0}d {1}h ago" -f [int]$ts.TotalDays, $ts.Hours)
  } catch { return "" }
}

function Format-Duration([TimeSpan]$ts) {
  if ($ts.TotalSeconds -lt 0) { $ts = -$ts }
  if ($ts.TotalHours -ge 24) { return ("{0}d {1}h" -f [int]$ts.TotalDays, $ts.Hours) }
  if ($ts.TotalHours -ge 1) { return ("{0}h {1}m" -f [int]$ts.TotalHours, $ts.Minutes) }
  if ($ts.TotalMinutes -ge 1) { return ("{0}m" -f [int]$ts.TotalMinutes) }
  return ("{0}s" -f [int]$ts.TotalSeconds)
}

function Build-EmbedPayload([object[]]$rows, [object]$playersState) {
  $lastUpdated = $null
  $now = Get-Date
  foreach ($r in $rows) {
    try {
      if ($r.updated_at) {
        $dt = [DateTime]::Parse([string]$r.updated_at)
        if (-not $lastUpdated -or $dt -gt $lastUpdated) { $lastUpdated = $dt }
      }
    }
    catch {}
  }
  $lastUpdatedTxt = $(if ($lastUpdated) { $lastUpdated.ToString("yyyy-MM-dd HH:mm:ss") } else { $now.ToString("yyyy-MM-dd HH:mm:ss") })

  $lines = New-Object System.Collections.Generic.List[string]
  $anyPlayers = $false
  $totalPlayers = 0
  $pausedBits = New-Object System.Collections.Generic.List[string]
  $activeWorlds = New-Object System.Collections.Generic.List[string]
  $degradedBits = New-Object System.Collections.Generic.List[string]

  $mapRows = @($rows | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.key) })
  $script:__mapCount = $mapRows.Count
  $script:__mapIdx = 0

  foreach ($m in $mapRows) {
    $k = Clean-Key ([string]$m.key)
    if ([string]::IsNullOrWhiteSpace($k)) { continue }

    $rotationState = [string]$m.rotationState
    $st = [string]$m.status
    $procOk = [bool]$m.process_ok

    $isStale = $false
    try { $isStale = [bool]$m.is_stale } catch { $isStale = $false }

    $staleAgeTxt = ""
    try { if ($m.stale_age) { $staleAgeTxt = [string]$m.stale_age } } catch { $staleAgeTxt = "" }

    $transient = $false
    try { if ($m.transient_retry) { $transient = [bool]$m.transient_retry } } catch {}

    $a2sNow = -1
    try { $a2sNow = [int]$m.a2s_players } catch { $a2sNow = -1 }
    $maxp = -1
    try { $maxp = [int]$m.max_players } catch { $maxp = -1 }

    if ($transient -and -not $isStale -and $procOk) {
      $emo = $E_Antenna
    }
    else {
      $emo = Status-Emoji $st $procOk $isStale
    }

    $w = if ($m.weather) { [string]$m.weather } else { "none" }
    $we = Weather-Emoji $w

    $players = "n/a"
    if ($a2sNow -ge 0 -and $maxp -gt 0) { $players = ("{0}/{1}" -f $a2sNow, $maxp) }
    elseif ($a2sNow -ge 0) { $players = ("{0}" -f $a2sNow) }

    $lastKnownA2S = -1
    $lastKnownMax = -1
    try { $lastKnownA2S = [int]$m.last_known_a2s } catch { $lastKnownA2S = -1 }
    try { $lastKnownMax = [int]$m.last_known_max } catch { $lastKnownMax = -1 }

    $upt = if ($m.uptime) { [string]$m.uptime } else { "n/a" }

    if ($a2sNow -gt 0) { $anyPlayers = $true; $totalPlayers += $a2sNow }

    # Rotation-paused world (only when truly offline)
      if ($rotationState -eq 'paused' -and $a2sNow -lt 0 -and -not $procOk) {
      $emo = $E_ROTATE
      $line = ("{0} **{1}**  ·  Rotation Paused  ·  {2} {3}  ·  uptime {4}" -f $emo, $k, $we, $w, $upt)
      $lines.Add($line) | Out-Null
      $pausedBits.Add($k) | Out-Null

      $script:__mapIdx++
      if ($script:__mapIdx -lt $script:__mapCount) { $lines.Add("") | Out-Null }
      continue
    }

    if ($st -eq 'MAINTENANCE') {
      $line = ("{0} **{1}**  ·  maintenance mode  ·  {2} {3}  ·  uptime {4}" -f $E_Wrench, $k, $we, $w, $upt)
      $lines.Add($line) | Out-Null
      $degradedBits.Add(("{0} maintenance" -f $k)) | Out-Null

      $script:__mapIdx++
      if ($script:__mapIdx -lt $script:__mapCount) { $lines.Add("") | Out-Null }
      continue
    }

    $isHealthy = (-not $isStale -and $st -eq 'ONLINE' -and ($procOk -or $a2sNow -ge 0) -and -not $transient)

    if ($isHealthy) {
      $line = ("{0} **{1}**  ·  {2} deployed  ·  {3} {4}  ·  uptime {5}" -f $emo, $k, $players, $we, $w, $upt)
      $lines.Add($line) | Out-Null
      $activeWorlds.Add($k) | Out-Null

      $script:__mapIdx++
      if ($script:__mapIdx -lt $script:__mapCount) { $lines.Add("") | Out-Null }
      continue
    }

    $why =
    if ($transient) { "retrying" }
    elseif ($isStale) { ("stale {0}" -f $staleAgeTxt).Trim() }
    elseif ($a2sNow -ge 0) { "a2s ok, no process" }
    elseif (-not $procOk) { "process down" }
    else { "no response" }

    if ([string]::IsNullOrWhiteSpace($why)) { $why = "degraded" }
    $degradedBits.Add(("{0} {1}" -f $k, $why)) | Out-Null

    $players2 = $players

    $stateTag =
    if ($transient) { "RETRYING" }
    elseif ($isStale) { ("STALE {0}" -f $staleAgeTxt).Trim() }
    elseif ($a2sNow -ge 0) { "ONLINE" }
    elseif (-not $procOk) { "PROCESS DOWN" }
    else { "NO RESPONSE" }

    $line = ("*{0} **{1}**  ·  {2}  ·  {3}  ·  {4} {5}  ·  uptime {6}*" -f $emo, $k, $players2, $stateTag, $we, $w, $upt)
    $lines.Add($line) | Out-Null

    $script:__mapIdx++
    if ($script:__mapIdx -lt $script:__mapCount) { $lines.Add("") | Out-Null }
  }

  if ($lines.Count -eq 0) { $lines.Add("No map telemetry yet. Waiting for uplink signals…") | Out-Null }

  $summaryParts = New-Object System.Collections.Generic.List[string]
  if ($pausedBits.Count -gt 0) {
    $summaryParts.Add(("{0} **Rotation paused:** {1}" -f $E_ROTATE, ($pausedBits -join ", "))) | Out-Null
  }
  if ($activeWorlds.Count -gt 0) {
    $summaryParts.Add(("{0} **Active world:** {1}" -f $E_Check, ($activeWorlds -join ", "))) | Out-Null
  }
  if ($degradedBits.Count -gt 0) {
    $max = [Math]::Min(3, $degradedBits.Count)
    $summary = ($degradedBits | Select-Object -First $max) -join " · "
    if ($degradedBits.Count -gt $max) { $summary = $summary + (" · +{0} more" -f ($degradedBits.Count -$max)) }
    $summaryParts.Add(("{0} **Degraded:** {1}" -f $E_Warning, $summary)) | Out-Null
  }
  if ($summaryParts.Count -gt 0) {
    $lines.Insert(0, ($summaryParts -join "`n")) | Out-Null
  }

  # Player presence line
  if ($anyPlayers) {
    $presenceEmoji = $E_Check
    $presenceLine = ("{0} **Players online:** {1} across {2} map(s)" -f $presenceEmoji, $totalPlayers, ($mapRows | Where-Object { $_.a2s_players -gt 0 } | Measure-Object).Count)
    $lines.Add("") | Out-Null
    $lines.Add($presenceLine) | Out-Null
  }

  $activityBlock = $null
  try { $activityBlock = Build-RecentActivityLines $playersState $rows $now } catch { $activityBlock = $null }

  if ($activityBlock -and $activityBlock.lines -and $activityBlock.lines.Count -gt 0) {
    $lines.Add("") | Out-Null
    $lines.Add("**Recent activity**") | Out-Null
    foreach ($al in $activityBlock.lines) { $lines.Add($al) | Out-Null }

    $tip = Get-RotatingTip $playersState
    if ($tip) {
      $lines.Add("") | Out-Null
      $lines.Add($tip) | Out-Null
    }
  }

  $color =
  if ($anyPlayers) { 0x2ECC71 }
  elseif ($degradedBits.Count -gt 0) { $ColorDegraded }
  elseif ($activeWorlds.Count -gt 0) { $ColorHealthy }
  elseif ($pausedBits.Count -gt 0) { $ColorHealthy }
  else { $ColorCritical }

  $desc = ($lines -join "`n")
  if ($desc.Length -gt 4096) {
    $desc = $desc.Substring(0, 4090) + "…"
  }

  return @{
    embeds           = @(
      @{
        title       = ("{0} ICARUS Uplink · Player Activity" -f $E_Satellite)
        description = $desc
        color       = $color
        footer      = @{ text = ("QUESTPAUSE Ops · Uplink · last updated {0}" -f $lastUpdatedTxt) }
      }
    )
    allowed_mentions = @{ parse = @() }
  }
}

Log ("ICARUS Uplink ALLMAPS starting: Interval={0}s Once={1} (stale>{2}s) LeaveGrace={3}s" -f $IntervalSeconds, [bool]$Once, $StaleSeconds, $JoinLeaveGraceSeconds)

try {
  $script:InstanceMutex = New-Object System.Threading.Mutex($false, "Local\QuestPauseOps_Icarus_Uplink_AllMaps")
  if (-not $script:InstanceMutex.WaitOne(0)) {
    Log "Another ICARUS Uplink instance is already running. Exiting to avoid duplicate Discord PATCH/state writes."
    return
  }
}
catch {
  Log ("Single-instance guard failed, continuing without mutex: {0}" -f $_.Exception.Message)
}

$playersState = Load-PlayersState
$currentInterval = $IntervalSeconds

while ($true) {
  try {
    # --- HOT-RELOAD CONFIG ---
    $cfg = Read-Json $CFG_PATH
    if (-not $cfg -or -not $cfg.servers) { throw "servers.json missing/unreadable at $CFG_PATH" }

    $combined = $cfg.servers.icarus_combined
    if (-not $combined) { throw "servers.json: missing servers.icarus_combined" }

    $include = @()
    try { if ($combined.combined -and $combined.combined.includeServerKeys) { $include = @($combined.combined.includeServerKeys) } } catch {}
    if (-not $include -or $include.Count -eq 0) { throw "servers.icarus_combined.combined.includeServerKeys is empty" }

    # (Self-Correction for Elysium if missing from combined list)
    try {
      if ($cfg.servers.PSObject.Properties.Name -contains 'icarus_elysium') {
        if (@($include) -notcontains 'icarus_elysium') { $include += 'icarus_elysium' }
      }
    }
    catch {}

    $webhookId = [string]$combined.discordWebhook.status.id
    $webhookToken = [string]$combined.discordWebhook.status.token
    $webhook = Build-WebhookUrl $webhookId $webhookToken
    if ([string]::IsNullOrWhiteSpace($webhook)) { throw "icarus_combined.discordWebhook.status is empty (id/token)" }

    $orderIndex = @{}
    for ($i = 0; $i -lt $preferredOrder.Count; $i++) { $orderIndex[$preferredOrder[$i]] = $i }

    $now = Get-Date
    $rows = @()
    $cache = Load-MapCache
    $anyPlayerOnline = $false

    foreach ($sk in $include) {
      $sk = [string]$sk
      $e = $cfg.servers.$sk
      if (-not $e) { continue }

      $rotationState = if ($e.PSObject.Properties.Name -contains 'rotationState') { [string]$e.rotationState } else { "" }

      $mapKey = Clean-Key $(if ($e.world) { [string]$e.world } else { $sk.ToUpperInvariant() })

      $ip = if ($e.host) { [string]$e.host } else { "127.0.0.1" }
      $qport = if ($e.queryPort) { [int]$e.queryPort } else { 0 }

      $procName = if ($e.processNamePattern) { [string]$e.processNamePattern } else { "IcarusServer-Win64-Shipping" }

      $mustContain = ""
      try { if ($e.processCommandLineMustContain) { $mustContain = [string]$e.processCommandLineMustContain } } catch {}
      $mustContain = Normalize-Slash $mustContain

      if ([string]::IsNullOrWhiteSpace($mustContain)) {
        try {
          if ($e.wgsmServerFolder) {
            $folder = [string]$e.wgsmServerFolder
            if (-not [string]::IsNullOrWhiteSpace($folder)) {
              $mustContain = Normalize-Slash ("\servers\{0}\" -f $folder.Trim())
            }
          }
        }
        catch {}
      }

      # --- MAINTENANCE MODE ---
      $isMaintenance = $false
      try {
        if ($e.ops -and $e.ops.maintenanceFlag) {
          if (Test-Path ([string]$e.ops.maintenanceFlag)) { $isMaintenance = $true }
        }
      }
      catch {}

            $processOk = if ($isMaintenance) {
        $true
      }
      else {
        $pidStart = Get-ProcStartTimeFromPidFile $e
        if ($null -ne $pidStart) {
          $true
        }
        else {
          Get-ServerProcessOk $procName $mustContain
        }
      }

      $resolvedMaxPlayers = -1
      $maxpRef = -1
      $maxp = [ref]$maxpRef
      $a2s = -1
      $a2sNames = $null

      if ($isMaintenance) {
        $status = "MAINTENANCE"
      }
      elseif ($qport -gt 0) {
        $a2s = Get-A2SPlayers $ip $qport $maxp
        if ($a2s -ge 0) {
          if ($a2s -gt 0) {
            $a2sNames = Get-A2SPlayerNames $ip $qport
            $anyPlayerOnline = $true
          }
          else {
            $a2sNames = @()
          }
        }
      }

      if ($maxp.Value -gt 0) { $resolvedMaxPlayers = [int]$maxp.Value }
      elseif ($e.maxPlayers) { $resolvedMaxPlayers = [int]$e.maxPlayers }

      $lastKnown = $null
      $lastOkAt = $null
      $firstOkAt = $null
      $lastKnownA2S = -1
      $lastKnownMax = -1
      $failStreak = 0
      $okStreak = 0

      try {
        if ($cache.maps -and $cache.maps.ContainsKey($mapKey)) {
          $lastKnown = $cache.maps[$mapKey]
          if ($lastKnown -and $lastKnown.last_ok_at) { $lastOkAt = [DateTime]::Parse([string]$lastKnown.last_ok_at) }
          if ($lastKnown -and $lastKnown.first_ok_at) { $firstOkAt = [DateTime]::Parse([string]$lastKnown.first_ok_at) }
          if ($lastKnown -and $lastKnown.a2s_players -ge 0) { $lastKnownA2S = [int]$lastKnown.a2s_players }
          if ($lastKnown -and $lastKnown.max_players -gt 0) { $lastKnownMax = [int]$lastKnown.max_players }
          if ($lastKnown -and $lastKnown.fail_streak -ge 0) { $failStreak = [int]$lastKnown.fail_streak }
          if ($lastKnown -and $lastKnown.ok_streak -ge 0) { $okStreak = [int]$lastKnown.ok_streak }
        }
      }
      catch {}

      $previousKnownA2S = $lastKnownA2S

      if ($isMaintenance) {
        # Planned maintenance should not poison A2S fail streaks or stale telemetry.
        # Keep last known A2S baseline untouched.
        $failStreak = 0
        $okStreak = 0
      }
      elseif ($a2s -ge 0) {
        Cache-UpdateLastOk $cache $mapKey $a2s $resolvedMaxPlayers
        $lastOkAt = $now
        $lastKnownA2S = $a2s
        $lastKnownMax = $resolvedMaxPlayers
        $failStreak = 0
        try { $okStreak = [int]$cache.maps[$mapKey].ok_streak } catch { $okStreak = 1 }
      }
      else {
        Cache-UpdateFail $cache $mapKey
        try { $failStreak = [int]$cache.maps[$mapKey].fail_streak } catch { $failStreak = 1 }
        $okStreak = 0
      }

      $transientRetry = $false
      $effectiveA2S = $a2s
      $effectiveMax = $resolvedMaxPlayers

      if ($a2s -lt 0) {
        $recentOk = $false
        if ($lastOkAt) {
          $ageOk = $now - $lastOkAt
          if ($ageOk.TotalSeconds -le $StaleSeconds) { $recentOk = $true }
        }

        if ($recentOk -and $failStreak -gt 0 -and $failStreak -lt $FailStreakToDown -and $lastKnownA2S -ge 0 -and $lastKnownMax -gt 0) {
          $transientRetry = $true
          $effectiveA2S = $lastKnownA2S
          $effectiveMax = $lastKnownMax
        }
      }

      if ($isMaintenance) {
        $status = 'MAINTENANCE'
        $effectiveA2S = -1
        $effectiveMax = $resolvedMaxPlayers
        $transientRetry = $false
      }
      else {
        $status = if ($effectiveA2S -ge 0) { 'ONLINE' } else { 'OFFLINE / NO RESPONSE' }
      }

      try { Reconcile-OnlineRosterToA2S $playersState $mapKey $effectiveA2S } catch {}

      $isStale = $false
      $staleAgeTxt = ""
      if (-not $isMaintenance) {
        if ($lastOkAt) {
          $age = $now - $lastOkAt
          if ($age.TotalSeconds -gt $StaleSeconds) {
            $isStale = $true
            if ($age.TotalMinutes -lt 60) { $staleAgeTxt = ("{0}m ago" -f [int]$age.TotalMinutes) }
            else { $staleAgeTxt = ("{0}h ago" -f [int]$age.TotalHours) }
          }
        }
        elseif ($a2s -lt 0) {
          $isStale = $true
          $staleAgeTxt = "no baseline"
        }
      }

      $upt = "n/a"
      try {
        if ($processOk) {
          $st = Get-ProcStartTimeFromPidFile $e
          if (-not $st) {
            $folder = ""
            try { if ($e.wgsmServerFolder) { $folder = [string]$e.wgsmServerFolder } } catch {}
            $st = Get-ServerProcessStartTimeRelaxed $procName $mustContain $folder
          }

          if ($st) {
            $ts = (Get-Date) - $st
            if ($ts.TotalDays -ge 1) { $upt = ("{0}d {1}h {2}m" -f $ts.Days, $ts.Hours, $ts.Minutes) }
            elseif ($ts.TotalHours -ge 1) { $upt = ("{0}h {1}m" -f $ts.Hours, $ts.Minutes) }
            else { $upt = ("{0}m" -f [int]$ts.TotalMinutes) }
          }
        }

        if ($upt -eq "n/a" -and $a2s -ge 0 -and $firstOkAt) {
          $ts = (Get-Date) - $firstOkAt
          if ($ts.TotalDays -ge 1) { $upt = ("{0}d {1}h {2}m" -f $ts.Days, $ts.Hours, $ts.Minutes) }
          elseif ($ts.TotalHours -ge 1) { $upt = ("{0}h {1}m" -f $ts.Hours, $ts.Minutes) }
          else { $upt = ("{0}m" -f [int]$ts.TotalMinutes) }
        }
      }
      catch { $upt = "n/a" }

      $logDir = ""
      try { if ($e.icarus -and $e.icarus.logDir) { $logDir = [string]$e.icarus.logDir } } catch {}
      if ([string]::IsNullOrWhiteSpace($logDir)) {
        try {
          if ($e.wgsmRoot -and $e.wgsmServerFolder) {
            $logDir = Join-Path ([string]$e.wgsmRoot) ("servers\{0}\serverfiles\Icarus\Saved\Logs" -f ([string]$e.wgsmServerFolder))
          }
        }
        catch {}
      }

      $weather = Get-LastWeatherState $logDir
      if (-not $weather) { $weather = "none" }

      try {
        $ms = Ensure-MapPlayersState $playersState $mapKey

        $latestLog = Get-LatestLogFilePath $logDir
        if ($latestLog) {
          if ([string]$ms.logtail.file -ne [string]$latestLog) {
            [string]$oldFile = [string]$ms.logtail.file
            $ms.logtail.file = [string]$latestLog
            $ms.logtail.offset = 0
            $ms.logtail.carry = ""
          }

          $newLines = Read-AppendedLinesFromTail $ms.logtail $ms.logtail.file
          if ($newLines -and $newLines.Count -gt 0) {
            $evs = Parse-LogEvents $newLines
            if ($evs -and $evs.Count -gt 0) {
              Apply-MapEvents $playersState $mapKey $evs
            }
          }

          $playersState.maps[$mapKey] = $ms
        }
      }
      catch {}

      try {
        if ($previousKnownA2S -gt 0 -and $effectiveA2S -eq 0) {
          Apply-SyntheticLeavesOnA2SDrop $playersState $mapKey $previousKnownA2S $effectiveA2S
        }
      }
      catch {}

      try {
        if ($a2sNames -ne $null) {
          Sync-OnlineRosterFromA2SNames $playersState $mapKey $a2sNames
        }
      }
      catch {}

      $rows += [pscustomobject]@{
        key             = $mapKey
        server_key      = $sk
        ip              = $ip
        query_port      = $qport
        status          = $status
        a2s_players     = $effectiveA2S
        max_players     = $effectiveMax
        process_ok      = [bool]$processOk
        uptime          = $upt
        weather         = $weather
        updated_at      = $now.ToString("o")
        rotationState   = $rotationState
        node            = [string]$env:COMPUTERNAME
        transient_retry = [bool]$transientRetry
        is_stale        = [bool]$isStale
        stale_age       = $staleAgeTxt
        last_ok_at      = $(if ($lastOkAt) { $lastOkAt.ToString("o") } else { "" })
        last_known_a2s  = $lastKnownA2S
        last_known_max  = $lastKnownMax
        pid_file        = $(try { if ($e.ops -and $e.ops.pidFile) { [string]$e.ops.pidFile } else { "" } } catch { "" })
        pid_value       = $(try { if ($e.ops -and $e.ops.pidFile -and (Test-Path ([string]$e.ops.pidFile))) { (Get-Content ([string]$e.ops.pidFile) -Raw).Trim() } else { "" } } catch { "" })
        fail_streak     = $failStreak
        ok_streak       = $okStreak
        a2s_names       = $(if ($a2sNames -ne $null) { @($a2sNames) } else { @() })
      }
    }

    Save-MapCache $cache
    Save-PlayersState $playersState

    $rows = $rows | Sort-Object `
    @{ Expression = {
        $k = ([string]$_.key).ToUpperInvariant()
        if ($orderIndex.ContainsKey($k)) { $orderIndex[$k] } else { 999 }
      }
    }, `
    @{ Expression = { ([string]$_.key).ToUpperInvariant() } }

    $telemetry = [pscustomobject]@{
      updated_at = $now.ToString("o")
      maps       = @{}
      recent     = @()
    }
    foreach ($r in $rows) { $telemetry.maps.($r.key) = $r }

    try {
      foreach ($r in $rows) {
        $mk = [string]$r.key
        if ($playersState.maps.ContainsKey($mk)) {
          $ms = $playersState.maps[$mk]
          if ($ms.events -and $ms.events.Count -gt 0) {
            $lastFew = @($ms.events | Select-Object -Last 4)
            foreach ($ev in $lastFew) {
              $telemetry.recent += [pscustomobject]@{
                map  = $mk
                ts   = [string]$ev.ts
                type = [string]$ev.type
                name = [string]$ev.name
              }
            }
          }
        }
      }
      if ($telemetry.recent.Count -gt 40) { $telemetry.recent = @($telemetry.recent | Select-Object -Last 40) }
    }
    catch {}

    Write-JsonAtomic $STATE_ALLMAPS $telemetry 32

    $payload = Build-EmbedPayload $rows $playersState

    $combinedState = Get-CombinedState $combined
    $payloadJson = ($payload | ConvertTo-Json -Depth 16)
    $newHash = Get-Sha256Hex $payloadJson
    $oldHash = $(if ($combinedState -and $combinedState.last_payload_hash) { [string]$combinedState.last_payload_hash } else { "" })

    if (-not [string]::IsNullOrWhiteSpace($newHash) -and $newHash -eq $oldHash) {
      Log "No change (hash match) — skipping PATCH"
      if ($Once) { break }

      if ($anyPlayerOnline) {
        $currentInterval = $IntervalSeconds
      }
      else {
        $currentInterval = [Math]::Min(($IntervalSeconds * 2), ($currentInterval + ($IntervalSeconds * 0.2)))
      }

      Log ("Sleeping for {0}s (anyOnline={1}, no-change)" -f [int]$currentInterval, $anyPlayerOnline)
      Start-Sleep -Seconds ([int]$currentInterval)
      continue
    }

    $payloadDescLen = 0
    try { $payloadDescLen = ([string]$payload.embeds[0].description).Length } catch {}
    Log ("Payload debug: descLen={0}, rows={1}" -f $payloadDescLen, @($rows).Count)

    $mid = Ensure-MessageIdAndPatch $webhook $combinedState $payload
    $combinedState.last_payload_hash = $newHash
    Save-CombinedState $combinedState

    $summary = (($rows | ForEach-Object {
          $flag = $(if ($_.transient_retry) { "retry" } elseif ($_.is_stale) { "stale" } elseif ($_.a2s_players -lt 0) { "off" } else { "ok" })
          "$($_.key)=$($_.a2s_players)[$flag]"
        }) -join ", ")

    Log ("Updated All-Maps Uplink (message_id={0}) :: {1}" -f $mid, $summary)
  }
  catch {
    Log ("Loop error: {0}" -f $_.Exception.Message)
  }

  if ($Once) { break }

  # --- ADAPTIVE POLLING ---
  if ($anyPlayerOnline) {
    $currentInterval = $IntervalSeconds
  }
  else {
    # Slow down by 20% each empty loop, up to 2x base interval
    $currentInterval = [Math]::Min(($IntervalSeconds * 2), ($currentInterval + ($IntervalSeconds * 0.2)))
  }

  Log ("Sleeping for {0}s (anyOnline={1})" -f [int]$currentInterval, $anyPlayerOnline)
  Start-Sleep -Seconds ([int]$currentInterval)
}



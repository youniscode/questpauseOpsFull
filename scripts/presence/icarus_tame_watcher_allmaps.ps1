<# 
QuestPauseOps — ICARUS Tame Watcher (All Maps)
- Watches logs for multiple ICARUS servers (Olympus / Styx / Prometheus / ELYSIUM)
- Keeps per-server cursor + carry buffer (no spam on restart)
- Keeps per-server persistent "seen tamed" store
- Posts to per-server Discord webhooks (or one override webhook)

PATCH (Reboot spam fix):
- Do NOT post tame/death/cleared events when the server is empty (A2S players == 0)
- Still "learns" those events into seen stores so they won't post later.

Run:
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\\QuestPauseOps\\scripts\\watchers\\icarus_tame_watcher_allmaps.ps1 -Tick
#>

[CmdletBinding()]
param(
  [int]$IntervalSeconds = 30,

  # Scheduler-friendly: one cycle then exit
  [switch]$Tick,

  # Send one test embed and exit (no log reading)
  [switch]$TestPost,

  # Optional override; if omitted, auto-picks all ICARUS servers on this node (tameWatcher.enabled=true)
  [string[]]$ServerKeys = @(),

  # Optional override webhook (forces ALL servers to use this one)
  [string]$WebhookUrl = ""
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------- Paths ----------
$Root = "C:\\QuestPauseOps"
$CfgPath = Join-Path $Root "config\\servers.json"
$StateRoot = Join-Path $Root "state"
$ScriptName = Split-Path -Leaf $MyInvocation.MyCommand.Path

# ---------- UTF-8 JSON bytes (prevents emoji ???) ----------
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$Utf8NoBOM = New-Object System.Text.UTF8Encoding($false)

function Log([string]$msg) {
  $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  Write-Host "[$ts][$ScriptName] $msg"
}

function Ensure-Dir([string]$p) {
  if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
}

function Load-Json([string]$path) {
  if (-not (Test-Path $path)) { return $null }
  try { return ((Get-Content -Raw -Path $path) | ConvertFrom-Json) }
  catch { return $null }
}

function Post-Discord([string]$url, [hashtable]$embed) {
  if ([string]::IsNullOrWhiteSpace($url)) { return $false }
  $payload = @{ embeds = @($embed); allowed_mentions = @{ parse = @() } }
  $json = $payload | ConvertTo-Json -Depth 12
  $bytes = $Utf8NoBOM.GetBytes($json)
  $headers = @{ 'Content-Type' = 'application/json; charset=utf-8' }

  $maxRetries = 5
  $attempt = 0
  $baseDelaySec = 1
  while ($true) {
    $attempt++
    try {
      Invoke-RestMethod -Uri $url -Method Post -Body $bytes -Headers $headers -TimeoutSec 8 | Out-Null
      return $true
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
          Log ("Discord post rate limited after $maxRetries retries")
          return $false
        }
        Start-Sleep -Seconds $retryAfter
        continue
      }

      if ($attempt -ge $maxRetries -or ($statusCode -ge 400 -and $statusCode -lt 500 -and $statusCode -ne 429)) {
        Log ("Discord post error: {0}" -f $ex.Message)
        return $false
      }

      $delay = [Math]::Min($baseDelaySec * [Math]::Pow(2, $attempt - 1), 30)
      Start-Sleep -Seconds $delay
    }
  }
}

# ---------- Parsing helpers ----------
function Get-ActorId([string]$line) {
  if ($line -match 'BP_(?:Mount_|Tame_|Tamed_)?[A-Za-z0-9]+(?:_(?:Mount_)?Corpse)?_C[_-](?<id>\d+)') { return $Matches['id'] }
  if ($line -match 'BP_[A-Za-z0-9]+_Corpse_C[_-](?<id>\d+)') { return $Matches['id'] }
  return ''
}
function Get-EntityKind([string]$line) {
  if ($line -match '\bBP_Mount_') { return 'mount' }
  if ($line -match '\bBP_Tame_' -or $line -match '\bBP_Tamed_') { return 'pet' }
  return 'unknown'
}
function Get-MountType([string]$line) {
  if ($line -match 'BP_Mount_([A-Za-z0-9]+)_C') { return $Matches[1] }
  if ($line -match 'BP_Tame_([A-Za-z0-9]+)_C') { return $Matches[1] }
  if ($line -match 'BP_Tamed_([A-Za-z0-9]+)_C') { return $Matches[1] }

  if ($line -match 'BP_([A-Za-z0-9]+)_(?:Mount_)?Corpse_C') { return $Matches[1] }
  if ($line -match 'BP_Tame_([A-Za-z0-9]+)_Corpse_C') { return $Matches[1] }
  if ($line -match 'BP_Tamed_([A-Za-z0-9]+)_Corpse_C') { return $Matches[1] }
  if ($line -match 'BP_([A-Za-z0-9]+)_Corpse_C') { return $Matches[1] }
  return 'UnknownMount'
}
function Get-LogStamp([string]$line) {
  if ($line -match '^\[(?<stamp>[^\]]+)\]') { return $Matches['stamp'] }
  return 'Unknown'
}
function Get-ActorToken([string]$line) {
  if ($line -match '(BP_(?:Mount_|Tame_|Tamed_)?[A-Za-z0-9]+_C[_-]\d+)') { return $Matches[1] }
  if ($line -match '(BP_[A-Za-z0-9]+_Corpse_C[_-]\d+)') { return $Matches[1] }
  return ''
}
function Is-TameWakeLine([string]$line) {
  return [bool](
    $line -match 'BeginRecording\s*-\s*OwningActor:\s*BP_(Mount_|Tame_|Tamed_)'
  )
}

# ---------- Wording pools ----------
$FooterPool = @(
  "QuestPause Network • Hunt | Build | Survive",
  "Icarus Prospect Command • Expedition Uplink 🛰️",
  "Frontier Telemetry • Live Sector Feed",
  "QuestPauseOps • Watcher Node"
)

$WorkshopPetTypes = @('Cat', 'Dog', 'Chicken', 'Cow', 'Horse', 'Pig')
$TamePostableTypes = @('Wolf', 'Buffalo', 'Moa', 'ArcticMoa', 'Tusker', 'Terrenus', 'Zebra', 'ShaggyZebra', 'Ubis')

$LinesTamed = @(
  "New tame confirmed: **{0}** registered to this prospector. 🪶",
  "Containment successful — **{0}** bonded and responding. 🧬",
  "Frontier log update: **{0}** domesticated and ready. 📜"
)
$LinesDown = @(
  "Telemetry lost — **{0}** has fallen in the field. 💀",
  "Critical failure detected. **{0}** terminated by hazards. ⚠️",
  "Bio-link disconnected — **{0}** lost to the wilderness. 🌒"
)
$LinesCleared = @(
  "Remains cleared — **{0}** reclaimed by the frontier. 🧹",
  "Cleanup complete. No trace of **{0}** remains. 🌫️"
)
$LinesWorkshopPet = @(
  "Workshop drop confirmed: **{0}** has arrived planetside. 📦",
  "Orbital delivery complete: **{0}** now active in this sector. 🛰️"
)

function Pick([object[]]$pool, [string]$t) { ((Get-Random -InputObject $pool) -f $t) }

function Build-Embed {
  param(
    [string]$ServerLabel,
    [string]$EventType,       # tamed | mount_death | corpse_cleared
    [string]$ActorLine,
    [string]$Source = 'tamed' # tamed | workshop
  )

  $kind = Get-EntityKind $ActorLine
  $mountType = Get-MountType $ActorLine
  $stamp = Get-LogStamp $ActorLine

  $titleEmoji = '🟦'; $color = 3447003
  switch ($EventType) {
    'tamed'          { $titleEmoji = '🟢'; $color = 3066993 }
    'mount_death'    { $titleEmoji = '🔴'; $color = 15158332 }
    'corpse_cleared' { $titleEmoji = '⚪'; $color = 9807270 }
  }

  $label =
  if ($kind -eq 'pet') {
    if ($Source -eq 'workshop') { 'WORKSHOP COMPANION' } else { 'TAMED COMPANION' }
  }
  elseif ($kind -eq 'mount') { 'TAMED MOUNT' }
  else { 'ENTITY' }

  $title = switch ($EventType) {
    'tamed'          { "$titleEmoji [$ServerLabel] ${label}: New $mountType" }
    'mount_death'    { "$titleEmoji [$ServerLabel] ${label} lost: $mountType" }
    'corpse_cleared' { "$titleEmoji [$ServerLabel] Remains cleared: $mountType" }
    default          { "$titleEmoji [$ServerLabel] ${label} activity: $mountType" }
  }

  $desc = switch ($EventType) {
    'tamed' {
      if ($kind -eq 'pet' -and $Source -eq 'workshop') { Pick $LinesWorkshopPet $mountType }
      else { Pick $LinesTamed $mountType }
    }
    'mount_death'    { Pick $LinesDown $mountType }
    'corpse_cleared' { Pick $LinesCleared $mountType }
    default          { "Telemetry recorded mount activity." }
  }

  return @{
    title       = $title
    description = $desc
    color       = $color
    timestamp   = (Get-Date).ToString('o')
    footer      = @{ text = (Get-Random -InputObject $FooterPool) }
    fields      = @(
      @{ name = 'Event'; value = $EventType;          inline = $true },
      @{ name = 'Type';  value = $mountType;          inline = $true },
      @{ name = 'Log';   value = ("🕰️  " + $stamp); inline = $false }
    )
  }
}

# ---------- File tail (cursor) ----------
function Read-AppendedLines {
  param([string]$path, [ref]$offset, [ref]$carry)

  $out = New-Object System.Collections.Generic.List[string]
  try {
    $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
    try {
      if ($fs.Length -lt $offset.Value) {
        $offset.Value = [int64]$fs.Length
        $carry.Value = ""
        return $out
      }
      if ($fs.Length -eq $offset.Value) { return $out }

      [void]$fs.Seek($offset.Value, 'Begin')
      $toRead = [int]([math]::Min([int64]2147483647, ($fs.Length - $offset.Value)))
      $buf = New-Object byte[] $toRead
      $read = $fs.Read($buf, 0, $toRead)
      if ($read -le 0) { return $out }

      $offset.Value += $read

      $chunk = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
      $text = $carry.Value + $chunk
      $parts = $text -split "`n", -1

      $carry.Value = ($parts[$parts.Count - 1] -replace "`r$", "")
      for ($i = 0; $i -lt ($parts.Count - 1); $i++) {
        $ln = ($parts[$i] -replace "`r$", "")
        if ($ln.Length -gt 0) { $out.Add($ln) }
      }
      return $out
    }
    finally { $fs.Close() }
  }
  catch {
    Log ("Read error: {0}" -f $_.Exception.Message)
    return $out
  }
}

# ---------- A2S (player online gate) ----------
function Get-A2SPlayersQuick([string]$ip, [int]$port) {
  $client = $null
  try {
    if ([string]::IsNullOrWhiteSpace($ip) -or $port -le 0) { return -1 }

    $client = New-Object System.Net.Sockets.UdpClient
    $client.Client.ReceiveTimeout = 1200
    $client.Connect($ip, $port)

    $base = [byte[]](0xFF, 0xFF, 0xFF, 0xFF, 0x54) + ([System.Text.Encoding]::ASCII.GetBytes("Source Engine Query")) + 0x00
    [void]$client.Send($base, $base.Length)

    $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
    $resp = $client.Receive([ref]$remote)
    if (-not $resp -or $resp.Length -lt 5) { return -1 }

    # Challenge?
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
      $s = [System.Text.Encoding]::UTF8.GetString($bytes, $start, $idx.Value - $start)
      $idx.Value++
      return $s
    }
    function ReadUInt16LE([byte[]]$bytes, [ref]$idx) {
      $v = [int]($bytes[$idx.Value] -bor ($bytes[$idx.Value + 1] -shl 8))
      $idx.Value += 2
      return $v
    }
    function ReadByte([byte[]]$bytes, [ref]$idx) {
      $v = [int]$bytes[$idx.Value]
      $idx.Value++
      return $v
    }

    $i = 5; $ri = [ref]$i
    $null = ReadByte $resp $ri
    $null = ReadZ $resp $ri
    $null = ReadZ $resp $ri
    $null = ReadZ $resp $ri
    $null = ReadZ $resp $ri
    $null = ReadUInt16LE $resp $ri
    $players = ReadByte $resp $ri

    return $players
  }
  catch { return -1 }
  finally { if ($client) { $client.Close() } }
}

function Get-LatestLogFile([string]$dir) {
  Get-ChildItem -Path $dir -Filter '*.log' -File |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1
}

# ---------- Persistent seen store (per server) ----------
function Load-Seen([string]$path) {
  $t = @{}
  if (Test-Path $path) {
    foreach ($ln in (Get-Content -Path $path -ErrorAction SilentlyContinue)) {
      $k = ($ln -replace '^\uFEFF', '').Trim()
      if ($k) { $t[$k] = $true }
    }
  }
  return $t
}
function Save-Seen([hashtable]$t, [string]$path) {
  $MaxSeenEntries = 5000
  try {
    $keys = $t.Keys | Sort-Object
    if ($keys.Count -gt $MaxSeenEntries) {
      $keys = $keys | Select-Object -Last $MaxSeenEntries
      $t.Clear()
      foreach ($k in $keys) { $t[$k] = $true }
      Log "Save-Seen: pruned to $MaxSeenEntries entries in $path"
    }
    $keys | Set-Content -Path $path -Encoding UTF8
  }
  catch { Log "Save-Seen: failed to write $path : $($_.Exception.Message)" }
}

# ================== LOAD CONFIG + PICK SERVERS ==================
$cfg = Load-Json $CfgPath
if (-not $cfg) { Log "Failed to load servers.json from $CfgPath"; exit 0 }

$node = $env:QP_NODE
if ([string]::IsNullOrWhiteSpace($node)) { $node = $env:COMPUTERNAME }

# Build server inventory (NULL-SAFE) so ELYSIUM + future entries don't break parsing
$allServers = $cfg.servers.PSObject.Properties | ForEach-Object {
  $k = $_.Name
  $v = $_.Value

  $logDir = ""
  try { if ($v -and $v.icarus -and $v.icarus.logDir) { $logDir = [string]$v.icarus.logDir } } catch {}

  $tw = $null
  try { if ($v -and ($v.PSObject.Properties.Name -contains 'tameWatcher')) { $tw = $v.tameWatcher } } catch {}

  $twEnabled = $false
  try { if ($tw -and ($tw.PSObject.Properties.Name -contains 'enabled')) { $twEnabled = [bool]$tw.enabled } } catch { $twEnabled = $false }

  [pscustomobject]@{
    key         = $k
    product     = $(try { [string]$v.product } catch { "" })
    world       = $(try { [string]$v.world } catch { "" })
    node        = $(try { [string]$v.node } catch { "" })
    logDir      = $logDir
    tameWatcher = $tw
    tameEnabled = $twEnabled
    displayName = $(try { [string]$v.displayName } catch { "" })
  }
}

# Auto-pick servers (PATCH: only those with tameWatcher.enabled=true)
if (-not $ServerKeys -or $ServerKeys.Count -eq 0) {
  $ServerKeys = $allServers |
  Where-Object {
    $_.product -eq 'ICARUS' -and
    $_.node -eq $node -and
    $_.key -match '^icarus_' -and
    $_.key -ne 'icarus_combined' -and
    $_.tameEnabled -eq $true
  } |
  Select-Object -ExpandProperty key
}

if (-not $ServerKeys -or $ServerKeys.Count -eq 0) {
  Log "No ICARUS servers found for node '$node' with tameWatcher.enabled=true in servers.json"
  exit 0
}

Log ("Node=$node; watching: " + ($ServerKeys -join ", "))

# Determine override webhook (optional)
$resolvedWebhook = $WebhookUrl
if ([string]::IsNullOrWhiteSpace($resolvedWebhook)) { $resolvedWebhook = "" }

# ================== PER-SERVER RUNTIME STATE ==================
$Runtime = @{}

foreach ($sk in $ServerKeys) {
  $s = $cfg.servers.$sk
  if (-not $s) { continue }

  $logDir = ""
  try { if ($s.icarus -and $s.icarus.logDir) { $logDir = [string]$s.icarus.logDir } } catch {}
  if ([string]::IsNullOrWhiteSpace($logDir) -or -not (Test-Path $logDir)) {
    Log "SKIP $sk (logDir missing or not found): $logDir"
    continue
  }

  $serverStateDir = Join-Path $StateRoot $sk
  Ensure-Dir $serverStateDir

  $cursorPath = Join-Path $serverStateDir "tame_cursor.json"
  $seenPath   = Join-Path $serverStateDir "tame_seen_tamed.txt"

  $cursor = $null
  if (Test-Path $cursorPath) {
    try { $cursor = (Get-Content -Raw $cursorPath) | ConvertFrom-Json } catch { $cursor = $null }
  }

  $latest = Get-LatestLogFile $logDir
  if (-not $latest) {
    Log "SKIP $sk (no .log files in $logDir)"
    continue
  }

  if (-not $cursor -or -not $cursor.logPath) {
    $cursor = [pscustomobject]@{
      logPath = $latest.FullName
      offset  = (Get-Item $latest.FullName).Length
      carry   = ""
    }
    try { ($cursor | ConvertTo-Json -Depth 4) | Set-Content -Path $cursorPath -Encoding UTF8 } catch { Log "Failed to write cursor for $sk : $($_.Exception.Message)" }
    Log "Init cursor for $sk => EOF of $(Split-Path -Leaf $latest.FullName)"
  }

  $hook = ""
  try { if ($s.tameWatcher -and $s.tameWatcher.discordWebhook) { $hook = [string]$s.tameWatcher.discordWebhook } } catch { $hook = "" }

  $Runtime[$sk] = @{
    serverKey      = $sk
    displayName    = ([string]$s.displayName)
    world          = ([string]$s.world)
    logDir         = $logDir
    cursorPath     = $cursorPath
    webhook        = $hook
    cursor         = $cursor
    seenPath       = $seenPath
    seenTamed      = (Load-Seen $seenPath)
    seenBurst      = @{}
    recentTameType = @{}
    suppressUntil  = (Get-Date).AddSeconds(-1)  # join suppression window end
    wakeUntil      = (Get-Date).AddSeconds(-1)  # wake-storm suppression window end
    wakeHits       = (New-Object System.Collections.Generic.Queue[datetime]) # burst detector
    host           = ([string]$s.host)
    queryPort      = ([int]$s.queryPort)
  }
}

if ($Runtime.Keys.Count -eq 0) { Log "Nothing to watch (all servers skipped)."; exit 0 }

# ================== TESTPOST (AFTER RUNTIME EXISTS) ==================
if ($TestPost) {
  foreach ($entry in $Runtime.GetEnumerator()) {
    $rt = $entry.Value

    $hook = $resolvedWebhook
    if ([string]::IsNullOrWhiteSpace($hook)) { $hook = [string]$rt.webhook }

    if ([string]::IsNullOrWhiteSpace($hook)) {
      Log "TestPost: SKIP $($rt.serverKey) (no webhook)."
      continue
    }

    $embed = @{
      title       = "[TEST] ICARUS Tame Watcher • $($rt.world)"
      description = "Discord posting OK. Node=$node. Server=$($rt.serverKey)."
      color       = 3447003
      timestamp   = (Get-Date).ToString('o')
      footer      = @{ text = "QuestPauseOps • TestPost" }
    }

    [void](Post-Discord -url $hook -embed $embed)
    Log "TestPost: sent => $($rt.serverKey)"
  }

  Log "TestPost done. Exiting."
  return
}

# ================== SCRIPT-SCOPE HELPERS ==================
function Is-JoinLine([string]$line) {
  return (
    $line -match 'LogNet:\s+Join request:' -or
    $line -match 'LogNet:\s+Join succeeded:' -or
    $line -match 'LogConnectedPlayers:\s+Display:\s+AddConnectedPlayer' -or
    $line -match 'LogNet:\s+Accepted connection' -or
    $line -match 'LogNet:\s+NotifyAcceptedConnection'
  )
}
function Extend-Suppress([hashtable]$rt, [int]$seconds, [string]$reason) {
  $rt.suppressUntil = (Get-Date).AddSeconds($seconds)
  Log "[$($rt.serverKey)] $reason -> suppress until $($rt.suppressUntil)"
}

# ================== PROCESS ONE SERVER ==================
function Process-Server([hashtable]$rt) {
  # ---- Anti-join spam tuning ----
  $LoginSuppressSeconds        = 120   # how long after join we suppress posting
  $WakeStormSeconds            = 120   # how long after a wake burst we suppress posting
  $WakeStormWindowSeconds      = 4     # burst window
  $WakeStormThreshold          = 8     # how many wake hits triggers suppression
  $SameTypeTameCooldownSeconds = 3600

  $sk    = $rt.serverKey
  $label = $rt.world

  # Gate: do not POST tame/death/cleared events when server is empty (prevents reboot spam)
  $playersNow = -1
  try {
    $ip = if ([string]::IsNullOrWhiteSpace([string]$rt.host)) { "127.0.0.1" } else { [string]$rt.host }
    $qp = 0
    try { $qp = [int]$rt.queryPort } catch { $qp = 0 }
    if ($qp -gt 0) { $playersNow = Get-A2SPlayersQuick $ip $qp }
  }
  catch { $playersNow = -1 }

  $hook = $resolvedWebhook
  if ([string]::IsNullOrWhiteSpace($hook)) { $hook = [string]$rt.webhook }
  if ([string]::IsNullOrWhiteSpace($hook)) { return }

  $latest = Get-LatestLogFile $rt.logDir
  if ($latest -and $latest.FullName -ne $rt.cursor.logPath) {
    $rt.cursor.logPath = $latest.FullName
    $rt.cursor.offset  = (Get-Item $latest.FullName).Length
    $rt.cursor.carry   = ""
    Log "[$sk] Switched log => $(Split-Path -Leaf $latest.FullName) (baseline EOF)"
  }

  $logPath = [string]$rt.cursor.logPath
  if (-not (Test-Path $logPath)) { return }

  $offsetRef = [ref]([int64]$rt.cursor.offset)
  $carryRef  = [ref]([string]$rt.cursor.carry)

  $lines = Read-AppendedLines -path $logPath -offset $offsetRef -carry $carryRef

  $rt.cursor.offset = $offsetRef.Value
  $rt.cursor.carry  = $carryRef.Value
  ($rt.cursor | ConvertTo-Json -Depth 4) | Set-Content -Path $rt.cursorPath -Encoding UTF8

  if ($lines.Count -eq 0) { return }

  $now = Get-Date
  foreach ($bk in @($rt.seenBurst.Keys)) {
    if ((($now - $rt.seenBurst[$bk]).TotalSeconds) -gt 600) { $rt.seenBurst.Remove($bk) | Out-Null }
  }
  foreach ($tk in @($rt.recentTameType.Keys)) {
    if ((($now - $rt.recentTameType[$tk]).TotalSeconds) -gt $SameTypeTameCooldownSeconds) {
      $rt.recentTameType.Remove($tk) | Out-Null
    }
  }

  foreach ($line in $lines) {
    $now = Get-Date

    # Join detected -> suppress spam window
    if (Is-JoinLine $line) {
      Extend-Suppress $rt $LoginSuppressSeconds "Join detected"
      continue
    }

    # Wake-storm detection (mass tame actor stream-in on join/load/sleep wake)
    if (Is-TameWakeLine $line) {
      $rt.wakeHits.Enqueue($now)
      while ($rt.wakeHits.Count -gt 0 -and (($now - $rt.wakeHits.Peek()).TotalSeconds -gt $WakeStormWindowSeconds)) {
        [void]$rt.wakeHits.Dequeue()
      }
      if ($rt.wakeHits.Count -ge $WakeStormThreshold) {
        $rt.wakeUntil = $now.AddSeconds($WakeStormSeconds)
        $rt.wakeHits.Clear()
        Log "[$($rt.serverKey)] Wake-storm detected -> suppress until $($rt.wakeUntil)"
      }
    }

    $suppressed = ($now -lt $rt.suppressUntil) -or ($now -lt $rt.wakeUntil)

    # IMPORTANT:
    # BeginRecording on tame actors is not a perfect true-tame signal.
    # It can also happen when existing tames stream in on join/load/wake.
    # We reduce false positives with:
    # - join suppression
    # - wake-storm suppression
    # - first-seen actor learning
    # If the actor is first-seen and matches an allowed workshop pet or tame mount,
    # we allow a tame embed.
    if (Is-TameWakeLine $line) {
      $mt    = Get-MountType $line
      $id    = Get-ActorId $line
      $stamp = Get-LogStamp $line
      $tok   = Get-ActorToken $line
      $kind  = Get-EntityKind $line
      if ($kind -in @('mount', 'pet')) {
        Log "[$sk] DEBUG TAME CANDIDATE => kind=$kind type=$mt line=$line"
      }
      $idPart = if ($id) { "id:$id" } elseif ($tok) { "tok:$tok" } else { "mt:$mt|s:$stamp" }
      $key    = "seen_actor|$idPart"

      $isFirstSeen = (-not $rt.seenTamed.ContainsKey($key))

      if ($isFirstSeen) {
        $rt.seenTamed[$key] = $true
        Log "[$sk] LEARN wake actor => $mt"
      }

      $isWorkshopPet    = (($kind -eq 'pet')   -and ($WorkshopPetTypes   -contains $mt))
      $isTamedMount     = (($kind -eq 'mount') -and ($TamePostableTypes  -contains $mt))
      $typeCooldownKey  = ("tamedtype|{0}" -f $mt)
      $typeRecentlyPosted = $false

      if ($isTamedMount -and $rt.recentTameType.ContainsKey($typeCooldownKey)) {
        $typeRecentlyPosted = $true
      }
      if (
        $isFirstSeen -and
        -not $suppressed -and
        $playersNow -gt 0 -and
        ($isWorkshopPet -or $isTamedMount) -and
        -not $typeRecentlyPosted
      ) {
        $source = if ($isWorkshopPet) { 'workshop' } else { 'tamed' }
        $embed = Build-Embed -ServerLabel $label -EventType 'tamed' -ActorLine $line -Source $source
        [void](Post-Discord -url $hook -embed $embed)
        if ($isTamedMount) { $rt.recentTameType[$typeCooldownKey] = Get-Date }
        Log "[$sk] TAMED => $mt (kind=$kind source=$source)"
      }
      elseif ($isFirstSeen -and $isTamedMount -and $typeRecentlyPosted) {
        Log "[$sk] SUPPRESSED same-type tame cooldown => $mt"
      }

      continue
    }

    # --- Death: ONLY tame-related corpses (prevents wild animals)
    if ($line -match 'BeginRecording\s*-\s*OwningActor:\s*BP_(?:Mount_|Tame_|Tamed_)[A-Za-z0-9]+_(?:Mount_)?Corpse_C[_-]\d+') {
      $mt     = Get-MountType $line
      $id     = Get-ActorId $line
      $stamp  = Get-LogStamp $line
      $tok    = Get-ActorToken $line
      $idPart = if ($id) { "id:$id" } elseif ($tok) { "tok:$tok" } else { "mt:$mt|s:$stamp" }
      $dk     = "death|$idPart"
      if (-not $rt.seenBurst.ContainsKey($dk)) {
        $rt.seenBurst[$dk] = Get-Date

        if ($suppressed) {
          Log "[$sk] SUPPRESSED down => $mt"
          continue
        }
        if ($playersNow -le 0) {
          Log "[$sk] NO-POST (empty/unreachable server) down => $mt"
          continue
        }

        $embed = Build-Embed -ServerLabel $label -EventType 'mount_death' -ActorLine $line -Source 'tamed'
        [void](Post-Discord -url $hook -embed $embed)
        Log "[$sk] DOWN => $mt"
      }
      continue
    }

    # --- Cleared: ONLY tame-related corpses (prevents wild animals)
    if ($line -match 'EndRecording\s*-\s*OwningActor:\s*BP_(?:Mount_|Tame_|Tamed_)[A-Za-z0-9]+_(?:Mount_)?Corpse_C[_-]\d+') {
      $mt     = Get-MountType $line
      $id     = Get-ActorId $line
      $stamp  = Get-LogStamp $line
      $tok    = Get-ActorToken $line
      $idPart = if ($id) { "id:$id" } elseif ($tok) { "tok:$tok" } else { "mt:$mt|s:$stamp" }
      $ck     = "cleared|$idPart"
      if (-not $rt.seenBurst.ContainsKey($ck)) {
        $rt.seenBurst[$ck] = Get-Date

        if ($suppressed) {
          Log "[$sk] SUPPRESSED cleared => $mt"
          continue
        }
        if ($playersNow -le 0) {
          Log "[$sk] NO-POST (empty/unreachable server) cleared => $mt"
          continue
        }

        $embed = Build-Embed -ServerLabel $label -EventType 'corpse_cleared' -ActorLine $line -Source 'tamed'
        [void](Post-Discord -url $hook -embed $embed)
        Log "[$sk] CLEARED => $mt"
      }
      continue
    }
  }

  Save-Seen $rt.seenTamed $rt.seenPath
}

# ================== MAIN LOOP ==================
do {
  foreach ($sk in @($Runtime.Keys)) {
    try { Process-Server $Runtime[$sk] } catch { Log "[$sk] error: $($_.Exception.Message)" }
  }
  if ($Tick) { break }
  Start-Sleep -Seconds $IntervalSeconds
} while ($true)
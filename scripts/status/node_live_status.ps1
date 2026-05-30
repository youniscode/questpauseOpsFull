<#
QuestPauseOps — Node Live Status
- Monitors the BMAX node (CPU, GPU, RAM, Disk, Network, Temps)
- Uses LibreHardwareMonitorLib for rich hardware sensor data
- Creates one Discord embed, updates it in-place every cycle (no spam)
- Designed for scheduled task use: -Tick runs one cycle then exits
#>

[CmdletBinding()]
param(
  [string]$WebhookUrl = "",
  [switch]$Tick
)

# ---------- Bootstrap ----------
$__qpEnv = $null
foreach ($__qpRel in @('..\env.ps1', '..\..\env.ps1', '..\..\..\env.ps1')) {
  $__qpTest = Join-Path $PSScriptRoot $__qpRel
  if (Test-Path $__qpTest) { $__qpEnv = $__qpTest; break }
}
if (-not $__qpEnv) { throw "env.ps1 not found from $PSScriptRoot" }
. $__qpEnv
Remove-Variable __qpEnv, __qpRel, __qpTest -ErrorAction SilentlyContinue

[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
[Console]::InputEncoding = [System.Text.UTF8Encoding]::new()
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$PSDefaultParameterValues['Invoke-RestMethod:TimeoutSec'] = 15

$modulePath = Join-Path $script:QPRoot 'lib\QuestPause.Ops.psm1'
Import-Module $modulePath -Force -DisableNameChecking

$ScriptName = Split-Path -Leaf $MyInvocation.MyCommand.Path

function Log([string]$msg) {
  $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  Write-Host "[$ts][$ScriptName] $msg"
}

# ---------- Webhook ----------
if ([string]::IsNullOrWhiteSpace($WebhookUrl)) {
  $webhookCfg = Join-Path $script:QPConfigRoot "node_monitor_webhook.txt"
  if (Test-Path $webhookCfg) { $WebhookUrl = (Get-Content $webhookCfg -Raw).Trim() }
}
if ([string]::IsNullOrWhiteSpace($WebhookUrl)) {
  Log "No webhook URL. Pass -WebhookUrl or create config\node_monitor_webhook.txt"
  exit 0
}

# ---------- State ----------
$stateDir = Join-Path $script:QPStateRoot "node_monitor"
if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Force -Path $stateDir | Out-Null }
$stateFile = Join-Path $stateDir "message.json"

# ---------- Helpers ----------
function Bar([int]$pct) {
  $filled = [Math]::Min(10, [Math]::Max(0, [Math]::Round($pct / 10)))
  return ("#" * $filled) + ("-" * (10 - $filled))
}

function Format-Bytes($bytes) {
  if (-not $bytes -or $bytes -lt 0) { return "0 B" }
  if ($bytes -gt 1GB) { return "$([math]::Round($bytes / 1GB, 2)) GB" }
  if ($bytes -gt 1MB) { return "$([math]::Round($bytes / 1MB, 1)) MB" }
  if ($bytes -gt 1KB) { return "$([math]::Round($bytes / 1KB, 0)) KB" }
  return "$([math]::Round($bytes, 0)) B"
}

# ---------- LHM hardware polling ----------
$LibreHardwareMonitorLib = Join-Path $script:QPRoot "lib\LibreHardwareMonitorLib.dll"
if (-not (Test-Path $LibreHardwareMonitorLib)) {
  $lhmDir = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\LibreHardwareMonitor.LibreHardwareMonitor_Microsoft.Winget.Source_8wekyb3d8bbwe"
  $LibreHardwareMonitorLib = Join-Path $lhmDir "LibreHardwareMonitorLib.dll"
}

$lhmLoaded = $false
$lhm = @{ cpuLoad = -1; gpuTemp = -1; gpuLoad = -1; gpuMemUsed = -1; gpuMemTotal = -1; gpuCoreClock = -1; gpuPower = -1 }

function Read-LhmSensors {
  foreach ($hw in $script:lhmComputer.Hardware) {
    foreach ($s in $hw.Sensors) {
      if ($s.Value -eq $null) { continue }
      $v = [double]$s.Value
      $n = $s.Name.ToLowerInvariant()
      switch ($s.SensorType.ToString()) {
        'Load'        { if ($n -eq 'cpu total') { $script:lhm.cpuLoad = [math]::Round($v) }; if ($n -eq 'gpu core') { $script:lhm.gpuLoad = [math]::Round($v) } }
        'Temperature' { if ($n -match 'gpu') { $script:lhm.gpuTemp = [math]::Round($v) } }
        'SmallData'   { if ($n -eq 'gpu memory used') { $script:lhm.gpuMemUsed = $v }; if ($n -eq 'gpu memory total') { $script:lhm.gpuMemTotal = $v } }
        'Clock'       { if ($n -eq 'gpu core') { $script:lhm.gpuCoreClock = [math]::Round($v) } }
        'Power'       { if ($n -eq 'gpu core') { $script:lhm.gpuPower = [math]::Round($v, 1) } }
      }
    }
  }
}

if (Test-Path $LibreHardwareMonitorLib) {
  try {
    Add-Type -Path $LibreHardwareMonitorLib -ErrorAction Stop
    $script:lhmComputer = New-Object LibreHardwareMonitor.Hardware.Computer
    $script:lhmComputer.IsCpuEnabled = $true
    $script:lhmComputer.IsGpuEnabled = $true
    $script:lhmComputer.IsMemoryEnabled = $true
    $script:lhmComputer.IsMotherboardEnabled = $true
    $script:lhmComputer.IsNetworkEnabled = $true
    $script:lhmComputer.Open()

    foreach ($hw in $script:lhmComputer.Hardware) { $hw.Update() }
    Start-Sleep -Milliseconds 500
    foreach ($hw in $script:lhmComputer.Hardware) { $hw.Update(); $hw.Update() }

    Read-LhmSensors

    $lhmLoaded = $true
    Log "LHM sensors loaded (GPU temp $($lhm.gpuTemp)C, CPU $($lhm.cpuLoad)%)"
  } catch { Log "LHM library error: $($_.Exception.Message)" }
}

# ---------- WMI fallback data ----------
function Get-WmiMetrics {
  $os = $null; $disk = $null
  try { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop } catch {}
  try { $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop } catch {}

  $memPct = 0; $memUsed = ""; $memTotal = ""
  if ($os) {
    $totalKB = [double]$os.TotalVisibleMemorySize
    $freeKB = [double]$os.FreePhysicalMemory
    $usedKB = $totalKB - $freeKB
    $memPct = if ($totalKB -gt 0) { [math]::Round(($usedKB / $totalKB) * 100, 0) } else { 0 }
    $memUsed = "$([math]::Round($usedKB / 1MB, 1)) GB"
    $memTotal = "$([math]::Round($totalKB / 1MB, 1)) GB"

    # Uptime
    $diff = (Get-Date) - $os.LastBootUpTime
    $uptime = "$($diff.Days)d $($diff.Hours)h $($diff.Minutes)m"
  } else { $uptime = "N/A" }

  $diskPct = 0; $diskUsed = ""; $diskTotal = ""
  if ($disk) {
    $dTotal = [math]::Round($disk.Size / 1GB, 1)
    $dUsed = [math]::Round(($disk.Size - $disk.FreeSpace) / 1GB, 1)
    $diskPct = if ($dTotal -gt 0) { [math]::Round(($dUsed / $dTotal) * 100, 0) } else { 0 }
    $diskUsed = "$dUsed GB"
    $diskTotal = "$dTotal GB"
  }

  return @{ memPct = $memPct; memUsed = $memUsed; memTotal = $memTotal; uptime = $uptime; diskPct = $diskPct; diskUsed = $diskUsed; diskTotal = $diskTotal }
}

# ---------- Game server status ----------
function Get-GameServerStats {
  try {
    $cfgPath = Join-Path $script:QPConfigRoot "servers.json"
    if (-not (Test-Path $cfgPath)) { return @{ running = 0; total = 0; detail = "No config" } }
    $raw = Get-Content -Raw $cfgPath -ErrorAction SilentlyContinue
    if (-not $raw) { return @{ running = 0; total = 0; detail = "No config" } }
    $cfg = $raw | ConvertFrom-Json
    if (-not $cfg -or -not $cfg.servers) { return @{ running = 0; total = 0; detail = "No servers" } }

    $total = 0; $running = 0; $groups = @{}
    foreach ($prop in $cfg.servers.PSObject.Properties) {
      $key = $prop.Name
      $s = $prop.Value
      if (-not $s.enabled) { continue }
      if ($key -eq "icarus_combined") { continue }
      $total++

      $isRunning = $false
      try {
        # Port-based detection: check if game or query port is bound locally
        $gp = 0; $qp = 0
        try { $gp = [int]$s.gamePort } catch {}
        try { $qp = [int]$s.queryPort } catch {}

        if ($gp -gt 0) {
          $tcp = @(Get-NetTCPConnection -LocalPort $gp -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Listen' })
          if ($tcp.Count -gt 0) { $isRunning = $true }
        }

        if (-not $isRunning -and $qp -gt 0) {
          $udp = @(Get-NetUDPEndpoint -LocalPort $qp -ErrorAction SilentlyContinue)
          if ($udp.Count -gt 0) { $isRunning = $true }
        }

        # PZ fallback: console log freshness if port check fails
        if (-not $isRunning -and [string]$s.product -eq "projectzomboid") {
          $consolePath = $null
          try { $consolePath = [string]$s.consoleLog } catch {}
          if (-not $consolePath) { try { $consolePath = [string]$s.logFile } catch {} }
          if ($consolePath -and (Test-Path $consolePath)) {
            $lastWrite = (Get-Item $consolePath).LastWriteTime
            if ((Get-Date) - $lastWrite -le [TimeSpan]::FromMinutes(2)) { $isRunning = $true }
          }
        }

        # Minecraft fallback: command-line matching for java processes
        if (-not $isRunning -and [string]$s.product -eq "minecraft") {
          $procs = @(Get-CimInstance Win32_Process -Filter "Name LIKE 'java%'" -ErrorAction SilentlyContinue)
          foreach ($p in $procs) {
            $cmdLine = if ($p.CommandLine) { [string]$p.CommandLine } else { "" }
            if ($cmdLine -match 'paper\.jar') { $isRunning = $true; break }
          }
        }
      } catch { }

      # Build short name and group
      $shortName = $null
      if ($key -like "icarus_*") {
        $world = $null; try { $world = [string]$s.world } catch {}
        $shortName = if ($world) { $world.Substring(0, [Math]::Min(4, $world.Length)).ToUpperInvariant() } else { $key }
      } elseif ($key -like "valheim_*") {
        $shortName = if ($key -eq "valheim_main") { "Main" } else { "Pro" }
      } elseif ($key -eq "projectzomboid_main") { $shortName = "PZ" }
      elseif ($key -eq "7dtd_main") { $shortName = "7DTD" }
      elseif ($key -eq "windrose_main") { $shortName = "Wind" }
      elseif ($key -eq "minecraft_survival") { $shortName = "MC" }
      else { $shortName = $s.displayName }

      $icon = if ($isRunning) { $true } else { $false }
      if ($isRunning) { $running++ }

      # Group by game
      $g = "Other"
      if ($key -like "icarus_*") { $g = "ICARUS" }
      elseif ($key -like "valheim_*") { $g = "Valheim" }

      if (-not $groups.ContainsKey($g)) { $groups[$g] = @() }
      $groups[$g] += @{ name = $shortName; on = $isRunning }
    }

    $detailLines = @()
    foreach ($g in @("ICARUS", "Valheim", "Other")) {
      if ($groups.ContainsKey($g) -and $groups[$g].Count -gt 0) {
        $entries = $groups[$g] | ForEach-Object { if ($_.on) { "**$($_.name)**" } else { $_.name } }
        $detailLines += "**$g** :: $($entries -join ' | ')"
      }
    }
    $detail = $detailLines -join "`n"
    return @{ running = $running; total = $total; detail = $detail }
  } catch { return @{ running = 0; total = 0; detail = "Error" } }
}

# ================== COLLECT ==================
$wmi = Get-WmiMetrics
$games = Get-GameServerStats
$sw = [System.Diagnostics.Stopwatch]::StartNew()

# Build CPU value
if ($lhm.cpuLoad -ge 0) { $cpuVal = "$(Bar $lhm.cpuLoad)  **$($lhm.cpuLoad)%**" }
else { $cpuVal = "**N/A**" }

# Build memory value
$memVal = "$(Bar $wmi.memPct)  **$($wmi.memUsed)/$($wmi.memTotal)**  ($($wmi.memPct)%)"

# Build GPU value
if ($lhm.gpuTemp -ge 0) {
  $gpuParts = @()
  $gpuParts += "**$($lhm.gpuTemp)C**"
  if ($lhm.gpuLoad -ge 0) { $gpuParts += "$($lhm.gpuLoad)% load" }
  if ($lhm.gpuMemTotal -gt 0) { $gpuParts += "$(Format-Bytes $lhm.gpuMemUsed)/$(Format-Bytes $lhm.gpuMemTotal)" }
  $gpuVal = $gpuParts -join " · "
} else { $gpuVal = "**N/A**" }

# Build disk value
$diskVal = "$(Bar $wmi.diskPct)  **$($wmi.diskUsed)/$($wmi.diskTotal)**  ($($wmi.diskPct)%)"

# Health calculation
$maxPct = 0
if ($lhm.cpuLoad -gt 0) { $maxPct = [Math]::Max($maxPct, $lhm.cpuLoad) }
$maxPct = [Math]::Max($maxPct, $wmi.memPct)
$maxPct = [Math]::Max($maxPct, $wmi.diskPct)

$color = if ($maxPct -ge 90) { 0xCC3333 }
  elseif ($maxPct -ge 75) { 0xF28C28 }
  else { 0x23D18B }

# Rotating descriptions
$descPool = @(
  "All systems operational"
  "Node is stable and responsive"
  "Hardware telemetry nominal"
  "Sector clean - all metrics within range"
  "Server room conditions normal"
  "System resources reporting healthy"
  "No anomalies detected"
  "All subsystems running within spec"
)
$desc = $descPool | Get-Random

# ================== BUILD EMBED ==================
$fields = @()
$fields += @{ name = "CPU"; value = $cpuVal; inline = $true }
$fields += @{ name = "Memory"; value = $memVal; inline = $true }
$fields += @{ name = "GPU"; value = $gpuVal; inline = $true }
$fields += @{ name = "Disk (C:)"; value = $diskVal; inline = $true }
$fields += @{ name = "Uptime"; value = "**$($wmi.uptime)**"; inline = $true }
$fields += @{ name = "Game Servers"; value = "**$($games.running)/$($games.total)** running"; inline = $true }
$fields += @{ name = "Server Detail"; value = $games.detail; inline = $false }

$embed = @{
  title       = "BMAX Node Status"
  description = $desc
  color       = $color
  fields      = $fields
  footer      = @{ text = "QuestPauseOps . Node Monitor . $(Get-Date -Format 'HH:mm')" }
}

$payload = @{
  embeds           = @($embed)
  allowed_mentions = @{ parse = @() }
}

# ================== POST / PATCH ==================
$messageId = $null
try {
  if (Test-Path $stateFile) {
    $raw = Get-Content -Raw $stateFile -ErrorAction SilentlyContinue
    if ($raw) {
      $state = $raw | ConvertFrom-Json
      if ($state -and $state.id) { $messageId = [string]$state.id }
    }
  }
} catch { $messageId = $null }

if ($messageId) {
  try {
    Send-JsonUtf8 -Method PATCH -Url "$WebhookUrl/messages/$messageId" -Payload $payload
    Log "Updated embed (message $messageId)"
  } catch {
    Log "PATCH failed (may be deleted), recreating..."
    $messageId = $null
  }
}

if (-not $messageId) {
  try {
    $result = Send-JsonUtf8 -Method POST -Url "$WebhookUrl`?wait=true" -Payload $payload
    if ($result -and $result.id) {
      $messageId = [string]$result.id
      @{ id = $messageId } | ConvertTo-Json | Set-Content -Path $stateFile -Encoding UTF8
      Log "Created embed (message $messageId)"
    }
  } catch {
    Log "Failed to create embed: $($_.Exception.Message)"
  }
}

$sw.Stop()
Log "Cycle complete in $($sw.ElapsedMilliseconds)ms"

if ($Tick) { return }

# Continuous live mode: loop every 3 seconds with rate limit safety
$mutexName = "Local\QuestPauseOps_NodeLiveStatus"
$mutex = $null
try {
  $mutex = New-Object System.Threading.Mutex($false, $mutexName)
  if (-not $mutex.WaitOne(0)) {
    Log "Another instance already running in LIVE mode. Exiting."
    return
  }
} catch { }

Log "Entering LIVE mode (2s interval). Press Ctrl+C to stop."

while ($true) {
  $sw.Restart()
  $now = Get-Date

  try {
    # Refresh LHM sensors every cycle — keep Computer open persistently
    if ($lhmLoaded) {
      try {
        foreach ($hw in $script:lhmComputer.Hardware) { $hw.Update() }
        Start-Sleep -Milliseconds 100
        foreach ($hw in $script:lhmComputer.Hardware) { $hw.Update(); $hw.Update() }
        Read-LhmSensors
      } catch { }
    }
    $wmi = Get-WmiMetrics
    $games = Get-GameServerStats

    # Build values
    if ($lhm.cpuLoad -ge 0) { $cpuVal = "$(Bar $lhm.cpuLoad)  **$($lhm.cpuLoad)%**" }
    else { $cpuVal = "**N/A**" }
    $memVal = "$(Bar $wmi.memPct)  **$($wmi.memUsed)/$($wmi.memTotal)**  ($($wmi.memPct)%)"
    if ($lhm.gpuTemp -ge 0) {
      $gpuParts = @()
      $gpuParts += "**$($lhm.gpuTemp)C**"
      if ($lhm.gpuLoad -ge 0) { $gpuParts += "$($lhm.gpuLoad)% load" }
      if ($lhm.gpuMemTotal -gt 0) { $gpuParts += "$(Format-Bytes $lhm.gpuMemUsed)/$(Format-Bytes $lhm.gpuMemTotal)" }
      $gpuVal = $gpuParts -join " · "
    } else { $gpuVal = "**N/A**" }
    $diskVal = "$(Bar $wmi.diskPct)  **$($wmi.diskUsed)/$($wmi.diskTotal)**  ($($wmi.diskPct)%)"

    $maxPct = 0
    if ($lhm.cpuLoad -gt 0) { $maxPct = [Math]::Max($maxPct, $lhm.cpuLoad) }
    $maxPct = [Math]::Max($maxPct, $wmi.memPct)
    $maxPct = [Math]::Max($maxPct, $wmi.diskPct)
    $color = if ($maxPct -ge 90) { 0xCC3333 } elseif ($maxPct -ge 75) { 0xF28C28 } else { 0x23D18B }

    $desc = $descPool | Get-Random
    $fields = @()
    $fields += @{ name = "CPU"; value = $cpuVal; inline = $true }
    $fields += @{ name = "Memory"; value = $memVal; inline = $true }
    $fields += @{ name = "GPU"; value = $gpuVal; inline = $true }
    $fields += @{ name = "Disk (C:)"; value = $diskVal; inline = $true }
    $fields += @{ name = "Uptime"; value = "**$($wmi.uptime)**"; inline = $true }
    $fields += @{ name = "Game Servers"; value = "**$($games.running)/$($games.total)** running"; inline = $true }
    $fields += @{ name = "Server Detail"; value = $games.detail; inline = $false }

    $embed = @{
      title       = "BMAX Node Status"
      description = $desc
      color       = $color
      fields      = $fields
      footer      = @{ text = "QuestPauseOps . Node Monitor . $(Get-Date -Format 'HH:mm:ss')" }
    }

    $payload = @{ embeds = @($embed); allowed_mentions = @{ parse = @() } }

    if ($messageId) {
      try { Send-JsonUtf8 -Method PATCH -Url "$WebhookUrl/messages/$messageId" -Payload $payload }
      catch { $messageId = $null }
    }

    if (-not $messageId) {
      try {
        $result = Send-JsonUtf8 -Method POST -Url "$WebhookUrl`?wait=true" -Payload $payload
        if ($result -and $result.id) { $messageId = [string]$result.id; @{ id = $messageId } | ConvertTo-Json | Set-Content -Path $stateFile -Encoding UTF8 }
      } catch { }
    }
  } catch { Log "Live cycle error: $($_.Exception.Message)" }

  $sw.Stop()
  $elapsed = $sw.ElapsedMilliseconds
  $sleep = [Math]::Max(100, 2000 - $elapsed)
  Start-Sleep -Milliseconds $sleep
}

[CmdletBinding()]
param(
  [int]$TimeoutSecPerServer = 25
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

# C:\QuestPauseOps\scripts\status\node_status_dispatch.ps1
# QUESTPAUSEOPS — Node Status Dispatcher (Senior Architect: config-driven + auto-discovery)
# PATCH: includes ICARUS ELYSIUM automatically (no hardcoding needed) — as long as servers.json has ops.statusScript for icarus_elysium
# PATCH: runs ICARUS PID writer first (so uptime works everywhere, incl. uplink)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ---- Ops root ----
$opsRoot = $env:QP_OPS_ROOT
if ([string]::IsNullOrWhiteSpace($opsRoot)) { $opsRoot = $script:QPRoot }

# ---- Lock (prevents overlap) ----
$lockDir = Join-Path $opsRoot "state\.locks"
$lockFile = Join-Path $lockDir "node_status_dispatch.lock"
if (-not (Test-Path $lockDir)) { New-Item -ItemType Directory -Force -Path $lockDir | Out-Null }

if (Test-Path $lockFile) {
  try {
    $age = (Get-Date) - (Get-Item $lockFile).LastWriteTime
    if ($age.TotalSeconds -lt 45) {
      Write-Host ("[DISPATCH] Lock exists ({0}s old). Skipping." -f [int]$age.TotalSeconds)
      exit 0
    }
  }
  catch {}
}
Set-Content -Path $lockFile -Value (Get-Date).ToString("o") -Encoding ASCII

try {
  # ---- Node-awareness ----
  $nodeNow = $env:QP_NODE
  if ([string]::IsNullOrWhiteSpace($nodeNow)) { $nodeNow = $env:COMPUTERNAME }

  # ---- Config ----
  $cfgPath = Join-Path $opsRoot "config\servers.json"
  if (-not (Test-Path $cfgPath)) { throw "Config not found: $cfgPath" }

  $cfg = (Get-Content $cfgPath -Raw) | ConvertFrom-Json

  $psExe = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
  $logDir = Join-Path $opsRoot "logs\dispatch"
  if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }

  # ==========================================================
  # PATCH: Run ICARUS PID writer first (best-effort)
  # ==========================================================
  $pidWriter = Join-Path $opsRoot "scripts\status\icarus_pid_writer.ps1"
  if (Test-Path $pidWriter) {
    try {
      $pwOut = Join-Path $logDir "icarus_pid_writer_out.log"
      $pwErr = Join-Path $logDir "icarus_pid_writer_err.log"

      Write-Host "[DISPATCH] Running ICARUS PID writer ..."

      $argsPw = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$pidWriter`"",
        "-Tick"
      )

      $ppw = Start-Process -FilePath $psExe -ArgumentList $argsPw -NoNewWindow -PassThru `
        -RedirectStandardOutput $pwOut -RedirectStandardError $pwErr

      if (-not $ppw.WaitForExit(15 * 1000)) {
        try { $ppw.Kill() } catch {}
        Write-Host "[DISPATCH] PID writer TIMEOUT (killed after 15s)"
      }
      else {
        $pwCode = 0
        try { if ($null -ne $ppw.ExitCode) { $pwCode = [int]$ppw.ExitCode } } catch { $pwCode = 0 }
        if ($pwCode -ne 0) {
          Write-Host ("[DISPATCH] PID writer non-zero exit: {0}" -f $pwCode)
        }
        else {
          Write-Host "[DISPATCH] PID writer OK"
        }
      }
    }
    catch {
      Write-Host ("[DISPATCH] PID writer error: {0}" -f $_.Exception.Message)
      # best-effort: do not fail dispatch
    }
  }
  else {
    Write-Host "[DISPATCH] PID writer not found (skipping)."
  }
  # ==========================================================

  # ---- Auto-discovery: servers on this node with ops.statusScript ----
  $serverPairs = @()
  foreach ($p in $cfg.servers.PSObject.Properties) {
    $key = $p.Name
    $s = $p.Value
    if ($null -eq $s) { continue }

    # --- SKIP combined card (do not update Unified Ops View embed) ---
    if ($key -eq "icarus_combined") { continue }
    # extra safety: skip any entry that has a "combined" block
    if ($s -and ($s.PSObject.Properties.Name -contains "combined")) { continue }

    # node filter
    $n = $null
    if ($s.PSObject.Properties.Name -contains 'node') { $n = [string]$s.node }
    if (-not [string]::IsNullOrWhiteSpace($n) -and $n.Trim() -ne $nodeNow.Trim()) { continue }

    # must have ops.statusScript
    $hasOps = ($s.PSObject.Properties.Name -contains 'ops' -and $s.ops)
    if (-not $hasOps) { continue }

    $hasStatusScript = ($s.ops.PSObject.Properties.Name -contains 'statusScript' -and -not [string]::IsNullOrWhiteSpace([string]$s.ops.statusScript))
    if (-not $hasStatusScript) { continue }

    $serverPairs += @{ key = $key; server = $s }
  }

  if (-not $serverPairs -or $serverPairs.Count -eq 0) {
    Write-Host ("[DISPATCH] No status-capable servers found for node [{0}]." -f $nodeNow)
    exit 0
  }

  # ---- Order: ICARUS shards first (incl. ELYSIUM), others next; combined last (already skipped) ----
  $serverPairs = $serverPairs | Sort-Object `
  @{ Expression = {
      $k = $_.key
      if ($k -like "icarus_*") { 1 } else { 5 }
    }
  }, `
  @{ Expression = { $_.key } }

  # ---- Set SkipDiscord env var for ICARUS shards (suppress individual embeds) ----
  # The combined card script will post a single embed covering all ICARUS maps.
  foreach ($item in $serverPairs) {
    $key = $item.key
    $s = $item.server

    if ($key -like "icarus_*") {
      $env:QP_SKIP_DISCORD = "true"
    } else {
      Remove-Item Env:QP_SKIP_DISCORD -ErrorAction SilentlyContinue
    }

    # ---- Determine script path (ops.statusScript is the source of truth) ----
    $raw = [string]$s.ops.statusScript
    $scriptPath = if ([System.IO.Path]::IsPathRooted($raw)) { $raw } else { Join-Path $opsRoot $raw }

    if (-not $scriptPath -or -not (Test-Path $scriptPath)) {
      Write-Host ("[DISPATCH] Missing status script for {0} => {1} (skipped)" -f $key, $scriptPath)
      continue
    }

    $outLog = Join-Path $logDir ("{0}_out.log" -f $key)
    $errLog = Join-Path $logDir ("{0}_err.log" -f $key)

    Write-Host ("[DISPATCH] Running {0} ..." -f $key)

    # Runner is optional — if it exists, use it; otherwise run the status script directly.
    $runner = Join-Path $opsRoot "scripts\status\qp_status_run.ps1"
    $args = @(
      "-NoProfile",
      "-ExecutionPolicy", "Bypass"
    )

    if (Test-Path $runner) {
      $args += @(
        "-File", "`"$runner`"",
        "-ServerKey", $key
      )
    }
    else {
      $args += @(
        "-File", "`"$scriptPath`"",
        "-ServerKey", $key
      )
    }

    $p = Start-Process -FilePath $psExe -ArgumentList $args -NoNewWindow -PassThru `
      -RedirectStandardOutput $outLog -RedirectStandardError $errLog

    if (-not $p.WaitForExit($TimeoutSecPerServer * 1000)) {
      try { $p.Kill() } catch {}
      Write-Host ("[DISPATCH] TIMEOUT for {0} (killed after {1}s)" -f $key, $TimeoutSecPerServer)
      continue
    }

    $code = 0
    try { if ($null -ne $p.ExitCode) { $code = [int]$p.ExitCode } } catch { $code = 0 }

    if ($code -ne 0) {
      Write-Host ("[DISPATCH] Non-zero exit for {0}: {1}" -f $key, $code)
    }
    else {
      Write-Host ("[DISPATCH] OK {0}" -f $key)
    }
  }

  # ==========================================================
  # Run combined ICARUS status card (1 embed for all maps)
  # ==========================================================
  Remove-Item Env:QP_SKIP_DISCORD -ErrorAction SilentlyContinue
  $combinedCard = Join-Path $opsRoot "scripts\status\icarus_server_status_card.ps1"
  if (Test-Path $combinedCard) {
    Write-Host "[DISPATCH] Running ICARUS combined status card ..."
    $ccOut = Join-Path $logDir "icarus_combined_card_out.log"
    $ccErr = Join-Path $logDir "icarus_combined_card_err.log"
    $argsCc = @(
      "-NoProfile",
      "-ExecutionPolicy", "Bypass",
      "-File", "`"$combinedCard`""
    )
    $pCc = Start-Process -FilePath $psExe -ArgumentList $argsCc -NoNewWindow -PassThru `
      -RedirectStandardOutput $ccOut -RedirectStandardError $ccErr
    if (-not $pCc.WaitForExit(30 * 1000)) {
      try { $pCc.Kill() } catch {}
      Write-Host "[DISPATCH] Combined card TIMEOUT (killed after 30s)"
    } else {
      $ccCode = 0
      try { if ($null -ne $pCc.ExitCode) { $ccCode = [int]$pCc.ExitCode } } catch { $ccCode = 0 }
      if ($ccCode -ne 0) {
        Write-Host "[DISPATCH] Combined card non-zero exit: $ccCode"
      } else {
        Write-Host "[DISPATCH] Combined card OK"
      }
    }
  } else {
    Write-Host "[DISPATCH] Combined card not found (skipping): $combinedCard"
  }
}
finally {
  try { Remove-Item $lockFile -Force -ErrorAction SilentlyContinue } catch {}
}

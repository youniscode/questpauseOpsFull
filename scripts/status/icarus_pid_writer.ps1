[CmdletBinding()]
param(
  [switch]$Tick
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

# C:\QuestPauseOps\scripts\status\icarus_pid_writer.ps1

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$opsRoot = $env:QP_OPS_ROOT
if ([string]::IsNullOrWhiteSpace($opsRoot)) { $opsRoot = $script:QPRoot }

$cfgPath = Join-Path $opsRoot "config\servers.json"
if (-not (Test-Path $cfgPath)) { throw "Missing config: $cfgPath" }
$cfg = (Get-Content $cfgPath -Raw) | ConvertFrom-Json

$nodeNow = $env:QP_NODE
if ([string]::IsNullOrWhiteSpace($nodeNow)) { $nodeNow = $env:COMPUTERNAME }

function Say([string]$msg) { Write-Host ("[PIDWRITER] {0}" -f $msg) }

function Ensure-DirForFile([string]$filePath) {
  $dir = Split-Path $filePath
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

function Normalize-Slash([string]$s) {
  if ([string]::IsNullOrWhiteSpace($s)) { return "" }
  $s = $s -replace '\\\\', '\'
  $s = $s -replace '/', '\'
  return $s.Trim()
}

function Resolve-PidFromQueryPort([int]$port) {
  try {
    if ($port -le 0) { return $null }
    # UDP listener for A2S
    $ep = Get-NetUDPEndpoint -LocalPort $port -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($ep -and $ep.OwningProcess) { return [int]$ep.OwningProcess }
    return $null
  }
  catch { return $null }
}

function Resolve-PidFromCmdline([string]$procPattern, [string]$mustContain) {
  try {
    $mustContain = Normalize-Slash $mustContain
    $procs = Get-CimInstance Win32_Process -Filter ("Name LIKE '{0}%'" -f $procPattern) -ErrorAction SilentlyContinue
    if (-not $procs) { return $null }

    if ([string]::IsNullOrWhiteSpace($mustContain)) {
      if (@($procs).Count -eq 1) { return [int]$procs[0].ProcessId }
      return $null
    }

    foreach ($p in $procs) {
      $cmd = Normalize-Slash ([string]$p.CommandLine)
      if ($cmd -and ($cmd -like "*$mustContain*")) { return [int]$p.ProcessId }
    }
    return $null
  }
  catch { return $null }
}

$wrote = 0
$missed = 0

foreach ($p in $cfg.servers.PSObject.Properties) {
  $key = $p.Name
  $s = $p.Value
  if (-not $s) { continue }
  if ($key -eq "icarus_combined") { continue }
  if ($s.product -ne "ICARUS") { continue }

  # node filter
  $n = ""
  try { if ($s.node) { $n = [string]$s.node } } catch {}
  if (-not [string]::IsNullOrWhiteSpace($n) -and $n.Trim() -ne $nodeNow.Trim()) { continue }

  # pidFile target
  $pidFile = $null
  try { if ($s.ops -and $s.ops.pidFile) { $pidFile = [string]$s.ops.pidFile } } catch {}
  if ([string]::IsNullOrWhiteSpace($pidFile)) { continue }

  $procPattern = "IcarusServer-Win64-Shipping"
  try { if ($s.processNamePattern) { $procPattern = [string]$s.processNamePattern } } catch {}

  $queryPort = 0
  try { if ($s.queryPort) { $queryPort = [int]$s.queryPort } } catch { $queryPort = 0 }

  # mustContain fallback
  $mustContain = ""
  try { if ($s.processCommandLineMustContain) { $mustContain = [string]$s.processCommandLineMustContain } } catch {}
  $mustContain = Normalize-Slash $mustContain

  if ([string]::IsNullOrWhiteSpace($mustContain)) {
    try {
      if ($s.wgsmServerFolder) {
        $folder = [string]$s.wgsmServerFolder
        if (-not [string]::IsNullOrWhiteSpace($folder)) {
          $mustContain = Normalize-Slash ("\servers\{0}\" -f $folder.Trim())
        }
      }
    }
    catch {}
  }

  # 1) Best: port -> PID
  $procId = Resolve-PidFromQueryPort $queryPort

  # 2) Fallback: cmdline match
  if (-not $procId) {
    $procId = Resolve-PidFromCmdline $procPattern $mustContain
  }

  if ($procId) {
    Ensure-DirForFile $pidFile
    Set-Content -Path $pidFile -Value $procId -Encoding ASCII
    $wrote++
    Say ("{0} => PID {1} (queryPort={2})" -f $key, $procId, $queryPort)
  }
  else {
    $missed++
    Say ("MISS {0} (queryPort={1}, mustContain='{2}')" -f $key, $queryPort, $mustContain)
    try { if (Test-Path $pidFile) { Remove-Item $pidFile -Force -ErrorAction SilentlyContinue } } catch {}
  }
}

Say ("Done. wrote={0} missed={1}" -f $wrote, $missed)
exit 0


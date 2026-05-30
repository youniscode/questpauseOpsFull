[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)]
  [ValidateNotNullOrEmpty()]
  [string]$ServerKey
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

# C:\QuestPauseOps\scripts\status\qp_status_run.ps1
# QUESTPAUSEOPS — Status Runner (contract layer)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$opsRoot = $env:QP_OPS_ROOT
if ([string]::IsNullOrWhiteSpace($opsRoot)) { $opsRoot = $script:QPRoot }

# Load config (no module dependency)
$cfgPath = Join-Path $opsRoot "config\servers.json"
if (-not (Test-Path $cfgPath)) { throw "Config not found: $cfgPath" }
$cfg = (Get-Content $cfgPath -Raw) | ConvertFrom-Json
if (-not $cfg.servers -or -not $cfg.servers.$ServerKey) { throw "ServerKey not found: $ServerKey" }
$s = $cfg.servers.$ServerKey

# Node guard
$nodeNow = $env:QP_NODE
if ([string]::IsNullOrWhiteSpace($nodeNow)) { $nodeNow = $env:COMPUTERNAME }
$cfgNode = $null
if ($s.PSObject.Properties.Name -contains 'node') { $cfgNode = [string]$s.node }
if (-not [string]::IsNullOrWhiteSpace($cfgNode) -and $cfgNode.Trim() -ne $nodeNow.Trim()) {
  Write-Host ("[RUNNER] {0} belongs to node [{1}], current node is [{2}] (skipped)" -f $ServerKey, $cfgNode, $nodeNow)
  exit 0
}

# Maintenance flag (optional)
$maintFlag = $null
if ($s.PSObject.Properties.Name -contains 'ops' -and $s.ops) {
  if ($s.ops.PSObject.Properties.Name -contains 'maintenanceFlag' -and $s.ops.maintenanceFlag) {
    $maintFlag = [string]$s.ops.maintenanceFlag
  }
}
if (-not $maintFlag -and $s.PSObject.Properties.Name -contains 'paths' -and $s.paths) {
  if ($s.paths.PSObject.Properties.Name -contains 'maintenanceFlag' -and $s.paths.maintenanceFlag) {
    $maintFlag = [string]$s.paths.maintenanceFlag
  }
}
if (-not [string]::IsNullOrWhiteSpace($maintFlag) -and (Test-Path $maintFlag)) {
  Write-Host ("[RUNNER] Maintenance flag ON for {0} ({1})" -f $ServerKey, $maintFlag)
  # We still RUN the underlying script (so it can show orange/maintenance),
  # but the runner itself will always exit 0.
}

# Resolve status script (ops.statusScript > conventions)
$scriptPath = $null
if ($s.PSObject.Properties.Name -contains 'ops' -and $s.ops) {
  if ($s.ops.PSObject.Properties.Name -contains 'statusScript' -and $s.ops.statusScript) {
    $raw = [string]$s.ops.statusScript
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
      $scriptPath = if ([System.IO.Path]::IsPathRooted($raw)) { $raw } else { Join-Path $opsRoot $raw }
    }
  }
}
if (-not $scriptPath) {
  $candidate = Join-Path $opsRoot ("scripts\status\{0}.ps1" -f $ServerKey)
  if (Test-Path $candidate) { $scriptPath = $candidate }
}
if (-not $scriptPath -and $ServerKey -like "icarus_*") {
  $suffix = $ServerKey.Substring("icarus_".Length)
  $candidate = Join-Path $opsRoot ("scripts\status\icarus_server_status_{0}.ps1" -f $suffix)
  if (Test-Path $candidate) { $scriptPath = $candidate }
}

if (-not $scriptPath -or -not (Test-Path $scriptPath)) {
  Write-Host ("[RUNNER] No status script for {0} (skipped)" -f $ServerKey)
  exit 0
}

# Run in a clean child PowerShell so execution policy never blocks
$psExe = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"

try {
  & $psExe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -ServerKey $ServerKey | Out-Host
  exit 0
}
catch {
  # Contract: never break the dispatcher; log and exit 0
  Write-Host ("[RUNNER] ERROR for {0}: {1}" -f $ServerKey, $_.Exception.Message)
  exit 0
}

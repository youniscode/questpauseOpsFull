param(
  [ValidateSet("valheim_main", "valheim_pro")]
  [string]$ServerKey = "valheim_main"
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
$ErrorActionPreference = "Stop"

$sourceWatcher = Join-Path $script:QPRoot 'scripts\valheim\valheim_progression_trust_watcher.ps1'

if (-not (Test-Path $sourceWatcher)) {
  throw "Source watcher not found: $sourceWatcher"
}

$reportDir = Join-Path $script:QPReportsRoot $ServerKey
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null

$label = if ($ServerKey -eq 'valheim_main') { 'Valheim Main' } else { 'Valheim Pro' }

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $sourceWatcher -ServerKey $ServerKey

Write-Host "[$label] Progression trust watcher complete."

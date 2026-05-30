[CmdletBinding()]
param()

$genericScript = Join-Path $PSScriptRoot 'register_backup_tasks.ps1'
if (-not (Test-Path -LiteralPath $genericScript)) {
  Write-Host "ERROR: Generic registration script not found: $genericScript"
  exit 1
}

Write-Host "Delegating to generic register_backup_tasks.ps1 for projectzomboid_main..."
& $genericScript -ServerKey 'projectzomboid_main'

[CmdletBinding()]
param(
  [int]$IntervalSeconds = 30
)

$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot
$uplinkScript = Join-Path $scriptDir "icarus_uplink_allmaps.ps1"

if (-not (Test-Path $uplinkScript)) {
    throw "Uplink script not found: $uplinkScript"
}

# Loop continuously — scheduled task starts once at logon, this keeps running
while ($true) {
    try {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $uplinkScript -IntervalSeconds $IntervalSeconds -Once
    }
    catch {
        Write-Warning "Uplink run failed: $($_.Exception.Message)"
    }
    Start-Sleep -Seconds $IntervalSeconds
}
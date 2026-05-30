[CmdletBinding()]
param(
  [int]$IntervalSeconds = 60
)

$ErrorActionPreference = 'Stop'

# Bootstrap
$__qpEnv = $null
foreach ($__qpRel in @('..\env.ps1', '..\..\env.ps1')) {
    $__qpTest = Join-Path $PSScriptRoot $__qpRel
    if (Test-Path $__qpTest) { $__qpEnv = $__qpTest; break }
}
if (-not $__qpEnv) { throw "env.ps1 not found from $PSScriptRoot" }
. $__qpEnv
Remove-Variable __qpEnv, __qpRel, __qpTest -ErrorAction SilentlyContinue

$scriptDir = $PSScriptRoot

# Ordered calls to each per-map status script
$maps = @(
    @{ Key = "icarus_olympus";    Name = "olympus" }
    @{ Key = "icarus_styx";       Name = "styx" }
    @{ Key = "icarus_prometheus"; Name = "prometheus" }
    @{ Key = "icarus_elysium";    Name = "elysium" }
)

# Loop continuously so the task only needs to start once at logon
while ($true) {
    foreach ($m in $maps) {
        $scriptPath = Join-Path $scriptDir "icarus_server_status_$($m.Name).ps1"
        if (-not (Test-Path $scriptPath)) {
            Write-Warning "Status script not found: $scriptPath"
            continue
        }

        try {
            & powershell -NoProfile -ExecutionPolicy Bypass -File $scriptPath -ServerKey $m.Key
        } catch {
            Write-Warning "Failed to run status for $($m.Key): $($_.Exception.Message)"
        }
    }

    Start-Sleep -Seconds $IntervalSeconds
}
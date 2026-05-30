[CmdletBinding()]
param(
    [int]$SleepSeconds = 0
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

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$opsRoot = $env:QP_OPS_ROOT
if ([string]::IsNullOrWhiteSpace($opsRoot)) { $opsRoot = $script:QPRoot }

# Load module for logging + config helpers
Import-Module (Join-Path $opsRoot 'lib\QuestPause.Ops.psm1') -Force -DisableNameChecking

# Resolve node name
$node = $env:COMPUTERNAME
if ([string]::IsNullOrWhiteSpace($node)) { $node = "BMAX" }

# Read servers.json to find enabled servers on this node
$cfgPath = Join-Path $opsRoot 'config\servers.json'
if (-not (Test-Path $cfgPath)) { throw "Config not found: $cfgPath" }
$cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json

$keys = $cfg.servers.PSObject.Properties.Name
$enabledServers = foreach ($k in $keys) {
    $s = $cfg.servers.$k
    if (-not $s) { continue }
    if ($s.PSObject.Properties.Name -contains 'enabled' -and -not $s.enabled) { continue }
    $sn = if ($s.PSObject.Properties.Name -contains 'node') { [string]$s.node } else { "" }
    if ([string]::IsNullOrWhiteSpace($sn) -or $sn -ieq $node) { $k }
}

if ($enabledServers.Count -eq 0) {
    Write-Host "No enabled servers found for node '$node' in $cfgPath"
    exit 0
}

foreach ($key in $enabledServers) {
    try {
        Write-QPLog -ServerKey $key -Message "RUN status (batch)"
        & powershell -ExecutionPolicy Bypass -File (Join-Path $opsRoot 'qp.ps1') status $key
    }
    catch {
        try { Write-QPLog -ServerKey $key -Message ("RUN status FAILED: {0}" -f $_.Exception.Message) } catch {}
    }

    if ($SleepSeconds -gt 0) { Start-Sleep -Seconds $SleepSeconds }
}

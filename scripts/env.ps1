$script:QPRoot = $PSScriptRoot
while ($script:QPRoot -and -not (Test-Path (Join-Path $script:QPRoot 'config\servers.json'))) {
    $script:QPRoot = Split-Path $script:QPRoot -Parent
}
if (-not $script:QPRoot) { throw "Cannot resolve QuestPauseOps root from $PSScriptRoot" }

$script:QPConfigRoot  = Join-Path $script:QPRoot 'config'
$script:QPStateRoot   = Join-Path $script:QPRoot 'state'
$script:QPLogsRoot    = Join-Path $script:QPRoot 'logs'
$script:QPReportsRoot = Join-Path $script:QPRoot 'reports'
$script:QPBackupsRoot = Join-Path $script:QPRoot 'backups'
$script:QPScriptsRoot = Join-Path $script:QPRoot 'scripts'

$__qpModule = Join-Path $script:QPRoot 'lib\QuestPause.Ops.psm1'
if (Test-Path $__qpModule) { Import-Module $__qpModule -DisableNameChecking -ErrorAction SilentlyContinue }
Remove-Variable __qpModule -ErrorAction SilentlyContinue

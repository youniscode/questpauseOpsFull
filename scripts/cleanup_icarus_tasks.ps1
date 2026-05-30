[CmdletBinding()]
param([switch]$WhatIf)

$taskPath = '\QuestPauseOps\'

$toRemove = @(
    'QP ICARUS World Status Uplink'
    'QP ICARUS World Status Runner'
    'QP ICARUS Olympus Server Status'
    'QP ICARUS Styx Server Status'
    'QP ICARUS Prometheus Server Status'
    'QP ICARUS Elysium Server Status'
    'QP ICARUS Heartbeat Writer'
    'QP ICARUS PID Writer'
    'icarus_log_watcher'
)

if ($WhatIf) {
    Write-Host 'Would REMOVE 9 old ICARUS tasks:' -ForegroundColor Cyan
    foreach ($n in $toRemove) { Write-Host "  - $n" }
    Write-Host ''
    Write-Host 'Then deploy will register 3 new tasks:' -ForegroundColor Green
    Write-Host '  - QP ICARUS Uplink'
    Write-Host '  - QP ICARUS Server Status'
    Write-Host '  - QP ICARUS Tame Watcher'
    return
}

Write-Host '=== Removing old ICARUS tasks ===' -ForegroundColor Cyan
$removed = 0
foreach ($name in $toRemove) {
    $t = Get-ScheduledTask -TaskPath $taskPath -TaskName $name -ErrorAction SilentlyContinue
    if ($t) {
        $t | Unregister-ScheduledTask -Confirm:$false
        Write-Host "[Removed] $name" -ForegroundColor Red
        $removed++
    } else {
        Write-Host "[SKIP]    $name (not found)" -ForegroundColor DarkGray
    }
}

Write-Host "`nRemoved $removed tasks." -ForegroundColor Cyan
Write-Host "`nNow register the new tasks:" -ForegroundColor Yellow
Write-Host '  .\scripts\deploy_scheduled_tasks.ps1 -TaskName "*ICARUS*"' -ForegroundColor Green

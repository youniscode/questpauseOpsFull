[CmdletBinding()]
param([switch]$WhatIf)

$rules = @(
    @{Port=48187; Name='ICARUS STYX Game'}
    @{Port=48188; Name='ICARUS STYX Query'}
    @{Port=48189; Name='ICARUS Prometheus Game'}
    @{Port=48190; Name='ICARUS Prometheus Query'}
    @{Port=48191; Name='ICARUS Elysium Game'}
    @{Port=48192; Name='ICARUS Elysium Query'}
)

$created = 0
$skipped = 0
foreach ($r in $rules) {
    $ruleName = "QuestPauseOps - $($r.Name) ($($r.Port))"
    $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "[SKIP]  $ruleName (already exists)" -ForegroundColor DarkGray
        $skipped++
        continue
    }
    if ($WhatIf) {
        Write-Host "[WhatIf] Would create: $ruleName" -ForegroundColor DarkYellow
        continue
    }
    try {
        New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol UDP -LocalPort $r.Port -Action Allow -Profile Any | Out-Null
        Write-Host "[OK]    $ruleName" -ForegroundColor Green
        $created++
    } catch {
        Write-Host "[ERROR] $ruleName : $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host "`nCreated: $created  Skipped: $skipped" -ForegroundColor Cyan
if ($created -gt 0) {
    Write-Host "Run this from an admin prompt (or use the batch file)" -ForegroundColor Yellow
}

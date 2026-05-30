param([switch]$WhatIf)
$ErrorActionPreference = 'Stop'
$root = "C:\QuestPauseOps"

$bootstrap = @'
# Bootstrap: resolve QuestPauseOps root paths from env.ps1
$__qpEnv = $null
foreach ($__qpRel in @('..\env.ps1', '..\..\env.ps1', '..\..\..\env.ps1', '..\..\..\..\env.ps1')) {
    $__qpTest = Join-Path $PSScriptRoot $__qpRel
    if (Test-Path $__qpTest) { $__qpEnv = $__qpTest; break }
}
if (-not $__qpEnv) { throw "env.ps1 not found from $PSScriptRoot" }
. $__qpEnv
Remove-Variable __qpEnv, __qpRel, __qpTest -ErrorAction SilentlyContinue

'@

# Path replacement map with continuation variants
$reps = @(
    # Longest paths first
    @{o = '"C:\QuestPauseOps\config\servers.json"'; n = '"$script:QPConfigRoot\servers.json"'}
    @{o = "'C:\QuestPauseOps\config\servers.json'"; n = '"$script:QPConfigRoot\servers.json"'}
    @{o = '"C:\QuestPauseOps\config\pz_conflict_rules.json"'; n = '"$script:QPConfigRoot\pz_conflict_rules.json"'}
    @{o = "'C:\QuestPauseOps\config\pz_conflict_rules.json'"; n = '"$script:QPConfigRoot\pz_conflict_rules.json"'}
    @{o = '"C:\QuestPauseOps\config\watchdog.servers.json"'; n = '"$script:QPConfigRoot\watchdog.servers.json"'}
    @{o = "'C:\QuestPauseOps\config\watchdog.servers.json'"; n = '"$script:QPConfigRoot\watchdog.servers.json"'}
    @{o = '"C:\QuestPauseOps\logs\suspicious"'; n = '"$script:QPLogsRoot\suspicious"'}
    @{o = "'C:\QuestPauseOps\logs\suspicious'"; n = '"$script:QPLogsRoot\suspicious"'}
    @{o = '"C:\QuestPauseOps\logs\suspicious\'; n = '"$($script:QPRoot)\logs\suspicious\'}
    @{o = "'C:\QuestPauseOps\logs\suspicious\'"; n = '"$($script:QPRoot)\logs\suspicious\"'}
    @{o = '"C:\QuestPauseOps\config"'; n = '"$script:QPConfigRoot"'}
    @{o = "'C:\QuestPauseOps\config'"; n = '"$script:QPConfigRoot"'}
    @{o = '"C:\QuestPauseOps\reports"'; n = '"$script:QPReportsRoot"'}
    @{o = "'C:\QuestPauseOps\reports'"; n = '"$script:QPReportsRoot"'}
    @{o = '"C:\QuestPauseOps\state"'; n = '"$script:QPStateRoot"'}
    @{o = "'C:\QuestPauseOps\state'"; n = '"$script:QPStateRoot"'}
    @{o = '"C:\QuestPauseOps\logs"'; n = '"$script:QPLogsRoot"'}
    @{o = "'C:\QuestPauseOps\logs'"; n = '"$script:QPLogsRoot"'}
    @{o = '"C:\QuestPauseOps\backups"'; n = '"$script:QPBackupsRoot"'}
    @{o = "'C:\QuestPauseOps\backups'"; n = '"$script:QPBackupsRoot"'}
    @{o = '"C:\QuestPauseOps\scripts"'; n = '"$script:QPScriptsRoot"'}
    @{o = "'C:\QuestPauseOps\scripts'"; n = '"$script:QPScriptsRoot"'}
    # Continuation variants (no closing quote after dir name — path continues)
    @{o = '"C:\QuestPauseOps\config\'; n = '"$($script:QPRoot)\config\'}
    @{o = "'C:\QuestPauseOps\config\"; n = '"$($script:QPRoot)\config\'}
    @{o = '"C:\QuestPauseOps\reports\'; n = '"$($script:QPRoot)\reports\'}
    @{o = "'C:\QuestPauseOps\reports\"; n = '"$($script:QPRoot)\reports\'}
    @{o = '"C:\QuestPauseOps\state\'; n = '"$($script:QPRoot)\state\'}
    @{o = "'C:\QuestPauseOps\state\"; n = '"$($script:QPRoot)\state\'}
    @{o = '"C:\QuestPauseOps\logs\'; n = '"$($script:QPRoot)\logs\'}
    @{o = "'C:\QuestPauseOps\logs\"; n = '"$($script:QPRoot)\logs\'}
    @{o = '"C:\QuestPauseOps\backups\'; n = '"$($script:QPRoot)\backups\'}
    @{o = "'C:\QuestPauseOps\backups\"; n = '"$($script:QPRoot)\backups\'}
    @{o = '"C:\QuestPauseOps\scripts\'; n = '"$($script:QPRoot)\scripts\'}
    @{o = "'C:\QuestPauseOps\scripts\"; n = '"$($script:QPRoot)\scripts\'}
    # Bare root (last, shortest)
    @{o = '"C:\QuestPauseOps"'; n = '$script:QPRoot'}
    @{o = "'C:\QuestPauseOps'"; n = '$script:QPRoot'}
)

# Find all .ps1 files EXCLUDING backups and already-processed files
$processedDirs = @('\presence\', '\status\', '\live_watchers\')
$files = Get-ChildItem "$root\scripts" -Recurse -Filter *.ps1 | Where-Object {
    $_.FullName -notmatch '\.bak_' -and
    $_.FullName -notmatch '_transform'
}

foreach ($file in $files) {
    $rel = $file.FullName.Replace("$root\scripts\", '')
    $original = Get-Content $file.FullName -Raw -Encoding UTF8
    $content = $original

    # Skip if no hardcoded paths AND already has bootstrap
    $hasPaths = $content -match [regex]::Escape('C:\QuestPauseOps')
    $hasBootstrap = $content -match 'Bootstrap: resolve QuestPauseOps'
    
    if (-not $hasPaths -and $hasBootstrap) {
        Write-Host "SKIP (clean): $rel" -ForegroundColor DarkGray
        continue
    }
    if (-not $hasPaths -and -not $hasBootstrap) {
        Write-Host "SKIP (no paths): $rel" -ForegroundColor DarkGray
        continue
    }

    Write-Host "=== $rel ===" -ForegroundColor Cyan

    # 1. Add bootstrap if not present
    if (-not $hasBootstrap) {
        if ($content.TrimStart().StartsWith('param(')) {
            $parenDepth = 0; $paramEnd = -1
            for ($i = 0; $i -lt $content.Length; $i++) {
                $c = $content[$i]
                if ($c -eq '(') { $parenDepth++ }
                elseif ($c -eq ')') { $parenDepth--; if ($parenDepth -eq 0) { $paramEnd = $i; break } }
            }
            if ($paramEnd -ge 0) {
                $insertAt = $paramEnd + 1
                while ($insertAt -lt $content.Length -and $content[$insertAt] -match '\s') { $insertAt++ }
                $content = $content.Substring(0, $insertAt) + "`r`n" + $bootstrap + $content.Substring($insertAt)
            }
        } else {
            $content = $bootstrap + "`r`n" + $content
        }
    }

    # 2. Replace all hardcoded paths
    $changed = $false
    foreach ($r in $reps) {
        if ($content.IndexOf($r.o) -ge 0) {
            Write-Host "  $($r.o)" -ForegroundColor DarkGray
            $content = $content.Replace($r.o, $r.n)
            $changed = $true
        }
    }

    if ($changed) {
        $backup = $file.FullName + '.bak_' + (Get-Date -Format 'yyyyMMdd_HHmmss')
        Copy-Item $file.FullName $backup -Force
        Write-Host "  Backup: $(Split-Path $backup -Leaf)" -ForegroundColor Gray
        Set-Content -Path $file.FullName -Value $content -Encoding UTF8 -NoNewline
        Write-Host "  UPDATED" -ForegroundColor Green
    } elseif (-not $hasBootstrap) {
        $backup = $file.FullName + '.bak_' + (Get-Date -Format 'yyyyMMdd_HHmmss')
        Copy-Item $file.FullName $backup -Force
        Write-Host "  Backup (bootstrap only): $(Split-Path $backup -Leaf)" -ForegroundColor Gray
        Set-Content -Path $file.FullName -Value $content -Encoding UTF8 -NoNewline
        Write-Host "  UPDATED (bootstrap only)" -ForegroundColor Green
    } else {
        Write-Host "  No changes" -ForegroundColor Yellow
    }
}
Write-Host "`nDone." -ForegroundColor Cyan

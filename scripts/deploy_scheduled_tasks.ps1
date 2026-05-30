[CmdletBinding()]
param(
    [switch]$WhatIf,
    [switch]$Enable,
    [switch]$Disable,
    [switch]$Remove,
    [switch]$Status,
    [string]$TaskName = "*"
)

$ErrorActionPreference = 'Stop'

# Bootstrap paths (env.ps1 lives in the same scripts directory)
$__qpEnv = Join-Path $PSScriptRoot 'env.ps1'
if (-not (Test-Path $__qpEnv)) { throw "env.ps1 not found at $__qpEnv" }
. $__qpEnv
Remove-Variable __qpEnv -ErrorAction SilentlyContinue

$taskPath = "\QuestPauseOps\"
$opsRoot = $script:QPRoot

# ---- Task definitions ----

$tasks = @(

    # ── 1-min pollers (LogonTrigger + PT1M repetition) ──

    @{ Name = "pz_server_status";       Type = "poller";  Script = "scripts\status\pz_live_status.ps1";                    Args = "-ServerKey projectzomboid_main";        Wd = "scripts\status" }
    @{ Name = "pz_online_presence";      Type = "poller";  Script = "scripts\presence\pz_currently_on_server.ps1";         Args = "-ServerKey projectzomboid_main";        Wd = "scripts\presence" }
    @{ Name = "7dtd_server_status";      Type = "poller";  Script = "scripts\status\7dtd_live_status.ps1";                 Args = "-ServerKey 7dtd_main";                  Wd = "scripts\status" }
    @{ Name = "7dtd_online_presence";    Type = "poller";  Script = "scripts\presence\7dtd_currently_on_server.ps1";       Args = "-ServerKey 7dtd_main";                  Wd = "scripts\presence" }
    @{ Name = "valheim server status";   Type = "poller";  Script = "scripts\status\valheim_live_status.ps1";              Args = "-ServerKey valheim_main";               Wd = "scripts\status" }
    @{ Name = "valheim currently online";Type = "poller";  Script = "scripts\presence\valheim_currently_on_server.ps1";    Args = "-ServerKey valheim_main";               Wd = "scripts\presence" }
    @{ Name = "valheim pro server staus";Type = "poller";  Script = "scripts\status\valheim_live_pro_status.ps1";          Args = "-ServerKey valheim_pro";                Wd = "scripts\status" }
    @{ Name = "valheim pro currently online"; Type="poller";Script ="scripts\presence\valheim_pro_currently_on_server.ps1";Args = "-ServerKey valheim_pro";                Wd = "scripts\presence" }
    @{ Name = "windrose_server_status";  Type = "poller";  Script = "scripts\status\windrose_server_status.ps1";           Args = "-ServerKey windrose_main";              Wd = "scripts\status" }
    @{ Name = "windrose_online_players"; Type = "poller";  Script = "scripts\presence\windrose_currently_on_server.ps1";   Args = "-ServerKey windrose_main";              Wd = "scripts\presence" }
    @{ Name = "MC - Server Status";      Type = "poller";  Script = "scripts\status\minecraft_server_status.ps1";          Args = "-ServerKey minecraft_survival";         Wd = "scripts\status" }
    @{ Name = "MC - Online Players";     Type = "poller";  Script = "scripts\presence\minecraft_currently_on_server.ps1";  Args = "-ServerKey minecraft_survival";         Wd = "scripts\presence" }

    # ── Continuous log watchers (LogonTrigger, no repetition) ──

    @{ Name = "pz_log_watcher";         Type = "watcher"; Script = "scripts\watchdog\live_watchers\pz_log_watcher.ps1";            Args = "-ServerKey projectzomboid_main";  Wd = "scripts\watchdog\live_watchers" }
    @{ Name = "pz_mod_watcher";         Type = "watcher"; Script = "scripts\watchdog\live_watchers\pz_mod_admin_watcher.ps1";     Args = "-ServerKey projectzomboid_main";  Wd = "scripts\watchdog\live_watchers" }
    @{ Name = "valheim_log_watcher";    Type = "watcher"; Script = "scripts\watchdog\live_watchers\valheim_server_log_watcher.ps1";Args = "-ServerKey valheim_main";         Wd = "scripts\watchdog\live_watchers" }
    @{ Name = "valheim_mod_watcher";    Type = "watcher"; Script = "scripts\watchdog\live_watchers\valheim_mod_admin_watcher.ps1"; Args = "-ServerKey valheim_main";         Wd = "scripts\watchdog\live_watchers" }
    @{ Name = "windrose_log_watcher";   Type = "watcher"; Script = "scripts\watchdog\live_watchers\windrose_suspicious_activity.ps1"; Args = "-ServerKey windrose_main";     Wd = "scripts\watchdog\live_watchers" }
    # ── ICARUS tasks (3 total) ──

    @{ Name = "QP ICARUS Uplink";          Type = "timer"; Script = "scripts\presence\icarus_uplink_allmaps.ps1";            Args = "-Once";                                        Wd = "scripts\presence" }
    @{ Name = "QP ICARUS Server Status";   Type = "timer"; Script = "scripts\status\icarus_server_status_all.ps1";           Args = "";                                              Wd = "scripts\status" }
    @{ Name = "QP ICARUS Tame Watcher";    Type = "timer"; Script = "scripts\presence\icarus_tame_watcher_allmaps.ps1";      Args = "-Tick";                                        Wd = "scripts\presence" }
    @{ Name = "QP Node Live Status";             Type = "poller";Script = "scripts\status\node_live_status.ps1";                       Args = "";                                              Wd = "scripts\status" }

    # ── PZ debugging tool timers ──

    @{ Name = "pz_self_heal";              Type = "timer"; Script = "scripts\watchdog\tools\pz\watchdog_pz_self_heal.ps1";           Args = "-ServerKey projectzomboid_main";                Wd = "scripts\watchdog\tools\pz"; Interval = "PT5M" }
    @{ Name = "pz_trend_dashboard";        Type = "timer"; Script = "scripts\watchdog\tools\pz\watchdog_pz_trend_dashboard.ps1";     Args = "-ServerKey projectzomboid_main -HistoryDays 14";  Wd = "scripts\watchdog\tools\pz"; Interval = "PT1H" }
    @{ Name = "pz_alert_correlation";      Type = "timer"; Script = "scripts\watchdog\tools\pz\watchdog_pz_alert_correlation.ps1";   Args = "-ServerKey projectzomboid_main -TailLines 3000";  Wd = "scripts\watchdog\tools\pz"; Interval = "PT15M" }

    # ── Heartbeat monitor (1-min timer) ──

    @{ Name = "presence_heartbeat_monitor";      Type = "timer"; Script = "scripts\status\presence_heartbeat_monitor.ps1";       Args = "-StaleMinutes 3 -AlertCooldownMinutes 15";       Wd = "scripts\status" }

    # ── Daily backup (CalendarTrigger) ──

    @{ Name = "minecraft_survival_backup"; Type = "backup"; Script = "scripts\backup\minecraft_survival_backup.ps1"; Args = ""; Wd = "scripts\backup" }
)

# ── Status mode ──

if ($Status) {
    Write-Host "`n=== QuestPauseOps Scheduled Tasks ===`n" -ForegroundColor Cyan
    $existing = @(Get-ScheduledTask -TaskPath $taskPath -ErrorAction SilentlyContinue)
    if ($existing.Count -eq 0) { Write-Host "No tasks found under $taskPath" -ForegroundColor Yellow; return }
    $existing | Select-Object TaskName, @{N='State';E={$_.State}}, @{N='Enabled';E={$_.Enabled}} | Format-Table -AutoSize
    return
}

# ── Filter ──

$selected = if ($TaskName -eq '*') { $tasks } else { @($tasks | Where-Object { $_['Name'] -like $TaskName }) }
if ($selected.Count -eq 0) { Write-Host "No tasks match '$TaskName'." -ForegroundColor Yellow; return }

# ── XML templates ──

$xmlPoller = @'
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <URI>\QuestPauseOps\__NAME__</URI>
  </RegistrationInfo>
  <Principals>
    <Principal id="Author">
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
    <AllowHardTerminate>true</AllowHardTerminate>
    <ExecutionTimeLimit>PT72H</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Triggers>
    <LogonTrigger>
      <Repetition>
        <Interval>__INTERVAL__</Interval>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
    </LogonTrigger>
  </Triggers>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -ExecutionPolicy Bypass -WindowStyle Minimized -File "__SCRIPT__" __ARGS__</Arguments>
      <WorkingDirectory>__WORKDIR__</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
'@

$xmlWatcher = @'
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <URI>\QuestPauseOps\__NAME__</URI>
  </RegistrationInfo>
  <Principals>
    <Principal id="Author">
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
    <AllowHardTerminate>true</AllowHardTerminate>
    <ExecutionTimeLimit>PT72H</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Triggers>
    <LogonTrigger />
  </Triggers>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -ExecutionPolicy Bypass -WindowStyle Minimized -File "__SCRIPT__" __ARGS__</Arguments>
      <WorkingDirectory>__WORKDIR__</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
'@

$xmlTimer = @'
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.3" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <URI>\QuestPauseOps\__NAME__</URI>
  </RegistrationInfo>
  <Principals>
    <Principal id="Author">
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
    <AllowHardTerminate>true</AllowHardTerminate>
    <ExecutionTimeLimit>PT72H</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Triggers>
    <TimeTrigger>
      <Repetition>
        <Interval>__INTERVAL__</Interval>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
      <StartBoundary>__START__</StartBoundary>
      <Enabled>true</Enabled>
    </TimeTrigger>
  </Triggers>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -ExecutionPolicy Bypass -WindowStyle Minimized -File "__SCRIPT__" __ARGS__</Arguments>
      <WorkingDirectory>__WORKDIR__</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
'@

$xmlBackup = @'
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.3" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <URI>\QuestPauseOps\__NAME__</URI>
  </RegistrationInfo>
  <Principals>
    <Principal id="Author">
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
    <AllowHardTerminate>true</AllowHardTerminate>
    <UseUnifiedSchedulingEngine>true</UseUnifiedSchedulingEngine>
    <ExecutionTimeLimit>PT72H</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Triggers>
    <CalendarTrigger>
      <StartBoundary>__START__</StartBoundary>
      <Enabled>true</Enabled>
      <ScheduleByDay>
        <DaysInterval>1</DaysInterval>
      </ScheduleByDay>
    </CalendarTrigger>
  </Triggers>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -ExecutionPolicy Bypass -WindowStyle Minimized -File "__SCRIPT__" __ARGS__</Arguments>
      <WorkingDirectory>__WORKDIR__</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
'@

$templateMap = @{ poller = $xmlPoller; watcher = $xmlWatcher; timer = $xmlTimer; backup = $xmlBackup }

# ── Action ──

$now = (Get-Date).AddMinutes(1).ToString('yyyy-MM-ddTHH:mm:ss')
$backupStart = (Get-Date).Date.AddHours(4).ToString('yyyy-MM-ddTHH:mm:ss')

foreach ($t in $selected) {
    $name = $t['Name']
    $type = $t['Type']
    $scriptRel = $t['Script']
    $scriptAbs = Join-Path $opsRoot $scriptRel
    $workDir = Join-Path $opsRoot $t['Wd']
    $args = $t['Args']

    if ($Remove) {
        $existing = Get-ScheduledTask -TaskPath $taskPath -TaskName $name -ErrorAction SilentlyContinue
        if ($existing) {
            if ($WhatIf) { Write-Host "[WhatIf]  Unregister $name" -ForegroundColor DarkYellow; continue }
            $existing | Unregister-ScheduledTask -Confirm:$false
            Write-Host "[Removed] $name" -ForegroundColor Red
        } else {
            Write-Host "[SKIP]    $name (not found)" -ForegroundColor DarkGray
        }
        continue
    }

    $xml = $templateMap[$type]
    if (-not $xml) { Write-Host "[ERROR]   $name unknown type: $type" -ForegroundColor Red; continue }

    $start = if ($type -eq 'backup') { $backupStart } else { $now }

    # Custom repetition interval (default PT1M for pollers and timers)
    $interval = if ($t['Interval']) { $t['Interval'] } elseif ($type -eq 'poller' -or $type -eq 'timer') { 'PT1M' } else { '' }
    $xml = $xml -replace '__INTERVAL__', $interval

    $xml = $xml -replace '__NAME__', $name
    $xml = $xml -replace '__SCRIPT__', $scriptAbs
    $xml = $xml -replace '__WORKDIR__', $workDir
    $xml = $xml -replace '__ARGS__', $args
    $xml = $xml -replace '__START__', $start

    if ($Disable -or $Enable) {
        $existing = Get-ScheduledTask -TaskPath $taskPath -TaskName $name -ErrorAction SilentlyContinue
        if (-not $existing) {
            Write-Host "[SKIP]    $name (not found, register first)" -ForegroundColor DarkGray
            continue
        }
        if ($WhatIf) { Write-Host "[WhatIf]  $(if($Enable){'Enable'}else{'Disable'}) $name" -ForegroundColor DarkYellow; continue }
        if ($Enable) { $existing | Enable-ScheduledTask; Write-Host "[Enabled] $name" -ForegroundColor Green }
        else { $existing | Disable-ScheduledTask; Write-Host "[Disabled] $name" -ForegroundColor Yellow }
        continue
    }

    if ($WhatIf) {
        Write-Host "[WhatIf]  Register $name ($type)" -ForegroundColor DarkYellow
        continue
    }

    try {
        Register-ScheduledTask -TaskName $name -TaskPath $taskPath -Xml $xml -Force
        Write-Host "[Created] $name ($type)" -ForegroundColor Green
    } catch {
        Write-Host "[ERROR]   $name : $($_.Exception.Message)" -ForegroundColor Red
    }
}

if ($WhatIf -and $selected.Count -gt 0) {
    Write-Host "`nRun without -WhatIf to deploy." -ForegroundColor Cyan
}

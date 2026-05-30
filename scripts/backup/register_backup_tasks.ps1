[CmdletBinding()]
param(
  [string]$ServerKey,
  [switch]$All
)

$ErrorActionPreference = 'Stop'
$configPath = Join-Path $PSScriptRoot 'qp_backup_config.json'
$taskPath = '\QuestPauseOps\'
$liveScript = Join-Path $PSScriptRoot 'qp_backup_live.ps1'

$created = @()
$updated = @()
$removed = @()
$skippedDisabled = @()
$errors = @()

function Remove-ServerTasks {
  param([string]$Key)
  foreach ($suffix in @('hourly', 'daily')) {
    $name = "qp_backup_${Key}_${suffix}"
    $full = "${taskPath}${name}"
    try {
      $t = Get-ScheduledTask -TaskName $name -TaskPath $taskPath -ErrorAction SilentlyContinue
      if ($t) {
        Unregister-ScheduledTask -TaskName $name -TaskPath $taskPath -Confirm:$false -ErrorAction Stop
        $script:removed += $full
      }
    } catch {
      $script:errors += "Failed to remove $full : $($_.Exception.Message)"
    }
  }
}

function Register-ServerTasks {
  param([object]$Server)
  $key = $Server.serverKey
  $hourInterval = $Server.defaultHourlyIntervalHours
  $dailyTime = $Server.defaultDailyTime
  $hourlyName = "qp_backup_${key}_hourly"
  $dailyName = "qp_backup_${key}_daily"

  $hourlyArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$liveScript`" -ServerKey `"$key`" -Type `"hourly`" -Quiet"
  $dailyArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$liveScript`" -ServerKey `"$key`" -Type `"daily`" -Quiet"

  # Hourly
  try {
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $hourlyArgs
    $trigger = New-ScheduledTaskTrigger -Once -At "00:00" -RepetitionInterval (New-TimeSpan -Hours $hourInterval)
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1) -StartWhenAvailable
    $full = "${taskPath}${hourlyName}"
    $existing = Get-ScheduledTask -TaskName $hourlyName -TaskPath $taskPath -ErrorAction SilentlyContinue
    Register-ScheduledTask -TaskName $hourlyName -TaskPath $taskPath -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
    if ($existing) { $script:updated += $full } else { $script:created += $full }
  } catch { $script:errors += "hourly $key : $($_.Exception.Message)" }

  # Daily
  try {
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $dailyArgs
    $trigger = New-ScheduledTaskTrigger -Daily -At $dailyTime
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1) -StartWhenAvailable
    $full = "${taskPath}${dailyName}"
    $existing = Get-ScheduledTask -TaskName $dailyName -TaskPath $taskPath -ErrorAction SilentlyContinue
    Register-ScheduledTask -TaskName $dailyName -TaskPath $taskPath -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
    if ($existing) { $script:updated += $full } else { $script:created += $full }
  } catch { $script:errors += "daily $key : $($_.Exception.Message)" }
}

# --- main ---

if (-not (Test-Path -LiteralPath $configPath)) {
  $err = @{ operation = 'register'; success = $false; error = "Config not found: $configPath" }
  $err | ConvertTo-Json -Compress
  exit 1
}

$config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json

$targets = @()
if ($All) {
  $targets = @($config.servers)
} elseif ($ServerKey) {
  $match = @($config.servers | Where-Object { $_.serverKey -eq $ServerKey })
  if ($match.Count -eq 0) {
    $err = @{ operation = 'register'; success = $false; error = "ServerKey not found in config: $ServerKey" }
    $err | ConvertTo-Json -Compress
    exit 1
  }
  $targets = $match
} else {
  $err = @{ operation = 'register'; success = $false; error = 'Specify -ServerKey or -All' }
  $err | ConvertTo-Json -Compress
  exit 1
}

foreach ($srv in $targets) {
  $key = $srv.serverKey
  $enabled = [bool]$srv.enabled

  if ($enabled) {
    Register-ServerTasks -Server $srv
  } else {
    $skippedDisabled += $key
    Remove-ServerTasks -Key $key
  }
}

$output = @{
  operation        = 'register'
  success          = $true
  timestamp        = (Get-Date -Format 'o')
  created          = $created
  updated          = $updated
  removed          = $removed
  skipped_disabled = $skippedDisabled
  errors           = $errors
}
$output | ConvertTo-Json -Depth 3 -Compress

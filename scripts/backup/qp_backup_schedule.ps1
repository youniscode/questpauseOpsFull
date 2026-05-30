[CmdletBinding(DefaultParameterSetName='Get')]
param(
  [Parameter(ParameterSetName='Get')]
  [Parameter(ParameterSetName='SetHourly')]
  [Parameter(ParameterSetName='SetDaily')]
  [switch]$Get,

  [Parameter(ParameterSetName='SetHourly', Mandatory=$true)]
  [string]$SetHourly,

  [Parameter(ParameterSetName='SetDaily', Mandatory=$true)]
  [string]$SetDaily,

  [Parameter(ParameterSetName='Enable', Mandatory=$true)]
  [string]$EnableTask,

  [Parameter(ParameterSetName='Disable', Mandatory=$true)]
  [string]$DisableTask,

  [string]$ServerKey
)

$taskPath = '\QuestPauseOps\'
$ErrorActionPreference = 'Stop'

function Out-JsonResult {
  param(
    [string]$Operation,
    [bool]$Success,
    [object]$Data = $null,
    [string]$ErrorMessage = ''
  )
  $obj = [PSCustomObject]@{
    operation = $Operation
    success = $Success
    timestamp = (Get-Date -Format 'o')
  }
  if ($Data) { Add-Member -InputObject $obj -MemberType NoteProperty -Name 'data' -Value $Data }
  if ($ErrorMessage) { Add-Member -InputObject $obj -MemberType NoteProperty -Name 'error' -Value $ErrorMessage }
  return ($obj | ConvertTo-Json -Depth 5 -Compress)
}

function Get-TaskNames {
  param([string]$Key)
  $h = if ($Key) { "qp_backup_${Key}_hourly" } else { 'qp_backup_pz_hourly' }
  $d = if ($Key) { "qp_backup_${Key}_daily" } else { 'qp_backup_pz_daily' }
  return @{ hourly = $h; daily = $d }
}

function Get-TaskInfo {
  param([string]$Name)
  try {
    $t = Get-ScheduledTask -TaskName $Name -TaskPath $taskPath -ErrorAction Stop
    $triggerInfo = @()
    foreach ($trig in $t.Triggers) {
      $tInfo = @{
        type = "$($trig.CimClass.CimSystemProperties.ClassName)"
        enabled = $trig.Enabled
      }
      if ($trig.Repetition) {
        $tInfo.repetitionInterval = $trig.Repetition.Interval
        $tInfo.repetitionDuration = $trig.Repetition.Duration
      }
      if ($trig.StartBoundary) { $tInfo.startBoundary = $trig.StartBoundary }
      $triggerInfo += $tInfo
    }
    return @{
      taskName = $Name
      exists = $true
      enabled = [bool]$t.Enabled
      state = "$($t.State)"
      lastRunTime = if ($t.LastRunTime -and $t.LastRunTime.Year -gt 2000) { $t.LastRunTime.ToString('o') } else { $null }
      nextRunTime = if ($t.NextRunTime -and $t.NextRunTime.Year -gt 2000) { $t.NextRunTime.ToString('o') } else { $null }
      lastTaskResult = $t.LastTaskResult
      executionTimeLimit = $t.Settings.ExecutionTimeLimit
      triggers = $triggerInfo
    }
  } catch {
    return @{ taskName = $Name; exists = $false }
  }
}

switch ($PSCmdlet.ParameterSetName) {
  'Get' {
    $names = Get-TaskNames -Key $ServerKey
    $data = @{
      hourly = Get-TaskInfo -Name $names.hourly
      daily = Get-TaskInfo -Name $names.daily
    }
    Out-JsonResult -Operation 'get' -Success $true -Data $data
  }

  'SetHourly' {
    $valid = @('PT1H','PT2H','PT3H','PT6H','PT12H')
    if ($valid -notcontains $SetHourly) {
      Out-JsonResult -Operation 'setHourly' -Success $false -ErrorMessage "Invalid interval '$SetHourly'. Valid: $($valid -join ', ')"
      return
    }
    try {
      $names = Get-TaskNames -Key $ServerKey
      $name = $names.hourly
      $t = Get-ScheduledTask -TaskName $name -TaskPath $taskPath -ErrorAction Stop
      $t.Triggers[0].Repetition.Interval = $SetHourly
      Register-ScheduledTask -TaskName $name -Action $t.Actions -Trigger $t.Triggers -Settings $t.Settings -Principal $t.Principal -TaskPath $taskPath -Force | Out-Null
      Out-JsonResult -Operation 'setHourly' -Success $true -Data @{ taskName = $name; interval = $SetHourly; serverKey = $ServerKey }
    } catch {
      Out-JsonResult -Operation 'setHourly' -Success $false -ErrorMessage $_.Exception.Message
    }
  }

  'SetDaily' {
    if ($SetDaily -notmatch '^\d{2}:\d{2}$') {
      Out-JsonResult -Operation 'setDaily' -Success $false -ErrorMessage "Invalid time '$SetDaily'. Use HH:mm format (e.g. '04:00')."
      return
    }
    try {
      $names = Get-TaskNames -Key $ServerKey
      $name = $names.daily
      $t = Get-ScheduledTask -TaskName $name -TaskPath $taskPath -ErrorAction Stop
      $trigger = New-ScheduledTaskTrigger -Daily -At $SetDaily
      Register-ScheduledTask -TaskName $name -Action $t.Actions -Trigger $trigger -Settings $t.Settings -Principal $t.Principal -TaskPath $taskPath -Force | Out-Null
      Out-JsonResult -Operation 'setDaily' -Success $true -Data @{ taskName = $name; time = $SetDaily; serverKey = $ServerKey }
    } catch {
      Out-JsonResult -Operation 'setDaily' -Success $false -ErrorMessage $_.Exception.Message
    }
  }

  'EnableTask' {
    try {
      $t = Get-ScheduledTask -TaskName $EnableTask -TaskPath $taskPath -ErrorAction Stop
      if ($t.Enabled) {
        Out-JsonResult -Operation 'enable' -Success $true -Data @{ taskName = $EnableTask; alreadyEnabled = $true }
      } else {
        schtasks /Change /TN "$taskPath$EnableTask" /ENABLE 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "schtasks /ENABLE returned exit code $LASTEXITCODE" }
        Out-JsonResult -Operation 'enable' -Success $true -Data @{ taskName = $EnableTask }
      }
    } catch {
      Out-JsonResult -Operation 'enable' -Success $false -ErrorMessage $_.Exception.Message
    }
  }

  'DisableTask' {
    try {
      $t = Get-ScheduledTask -TaskName $DisableTask -TaskPath $taskPath -ErrorAction Stop
      if (-not $t.Enabled) {
        Out-JsonResult -Operation 'disable' -Success $true -Data @{ taskName = $DisableTask; alreadyDisabled = $true }
      } else {
        schtasks /Change /TN "$taskPath$DisableTask" /DISABLE 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "schtasks /DISABLE returned exit code $LASTEXITCODE" }
        Out-JsonResult -Operation 'disable' -Success $true -Data @{ taskName = $DisableTask }
      }
    } catch {
      Out-JsonResult -Operation 'disable' -Success $false -ErrorMessage $_.Exception.Message
    }
  }
}

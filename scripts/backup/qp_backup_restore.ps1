[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$ServerKey,

  [Parameter(Mandatory = $true)]
  [string]$BackupPath,

  [switch]$DryRun,
  [switch]$ConfirmRestore,
  [switch]$JsonOnly
)

$ErrorActionPreference = 'Continue'
$scriptStart = [DateTime]::UtcNow

$configPath = Join-Path $PSScriptRoot 'qp_backup_config.json'
$backupRoot = "C:\QuestPauseOps\backups"
$stateRoot = "C:\QuestPauseOps\state\backup"
$logRoot = "C:\QuestPauseOps\logs\backup"

function Write-Message {
  param([string]$Message, [string]$Level = 'INFO')
  if ($JsonOnly) { return }
  Write-Host "${Level}: ${Message}"
}

function Write-LogLine {
  param([string]$LogPath, [string]$Message)
  $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  "$ts  $Message" | Add-Content -Path $LogPath -Encoding UTF8
}

function Out-JsonRestore {
  param(
    [string]$Status,
    [bool]$DryRunMode,
    [string]$Message = '',
    [int]$RestoredItems = 0,
    [int]$Warnings = 0,
    [int]$Errors = 0,
    [string]$PreBackupPath = ''
  )
  $scriptEnd = [DateTime]::UtcNow
  $dur = [int]($scriptEnd - $scriptStart).TotalSeconds
  $result = [ordered]@{
    serverKey = $ServerKey
    status = $Status
    dryRun = $DryRunMode
    backupPath = $BackupPath
    startedAt = $scriptStart.ToString('o')
    finishedAt = $scriptEnd.ToString('o')
    durationSeconds = $dur
    preRestoreBackupPath = $PreBackupPath
    restoredItemCount = $RestoredItems
    warningCount = $Warnings
    errorCount = $Errors
    message = $Message
  }
  $resultJson = $result | ConvertTo-Json -Depth 8
  $resultLine = $result | ConvertTo-Json -Depth 8 -Compress
  $stateDir = Join-Path $stateRoot $ServerKey
  if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
  $resultJson | Set-Content -Path (Join-Path $stateDir 'last-restore.json') -Encoding UTF8 -Force
  $resultLine | Add-Content -Path (Join-Path $stateDir 'restore-history.jsonl') -Encoding UTF8
  if ($JsonOnly) { Write-Output $resultJson }
  return $result
}

# --- Load config ---
if (-not (Test-Path $configPath)) { Out-JsonRestore 'failed' $DryRun.IsPresent "Config not found: $configPath"; exit 1 }
$config = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
$serverCfg = $null
foreach ($s in $config.servers) { if ($s.serverKey -eq $ServerKey) { $serverCfg = $s; break } }
if (-not $serverCfg) { Out-JsonRestore 'failed' $DryRun.IsPresent "ServerKey '$ServerKey' not found in config"; exit 1 }

$logPath = Join-Path $logRoot "${ServerKey}-restore-$(Get-Date -Format 'yyyy-MM-dd').log"
$logDir = Split-Path $logPath -Parent
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

$displayName = $serverCfg.displayName
$sourcePaths = @($serverCfg.sourcePaths | ForEach-Object { [System.Environment]::ExpandEnvironmentVariables($_) })

$resolvedBackupPath = [System.Environment]::ExpandEnvironmentVariables($BackupPath)

# --- Safety 1: validate backup path is within allowed root ---
$allowedRoot = (Resolve-Path "$backupRoot\$ServerKey\" -ErrorAction SilentlyContinue).Path
if (-not $allowedRoot) { Out-JsonRestore 'failed' $DryRun.IsPresent "Backup root for $ServerKey does not exist: $backupRoot\$ServerKey"; exit 1 }
if ($resolvedBackupPath -notlike "$allowedRoot*") { Out-JsonRestore 'failed' $DryRun.IsPresent "BackupPath must be under $allowedRoot. Got: $resolvedBackupPath"; exit 1 }

# --- Safety 2: backup path must exist ---
if (-not (Test-Path $resolvedBackupPath)) { Out-JsonRestore 'failed' $DryRun.IsPresent "Backup path does not exist: $resolvedBackupPath"; exit 1 }

# --- Safety 3: check for manifest ---
$isFolder = (Get-Item -LiteralPath $resolvedBackupPath).PSIsContainer
$manifestPath = $null
if ($isFolder) {
  $manifestPath = Join-Path $resolvedBackupPath 'backup-manifest.json'
} else {
  $parentDir = Split-Path $resolvedBackupPath -Parent
  $stem = [System.IO.Path]::GetFileNameWithoutExtension($resolvedBackupPath)
  $manifestPath = Join-Path $parentDir "${stem}.manifest.json"
}
if (-not (Test-Path $manifestPath)) { Out-JsonRestore 'failed' $DryRun.IsPresent "Backup manifest not found: $manifestPath"; exit 1 }
$manifest = Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json

# --- Safety 4: check server is not running ---
$isRunning = $false
$runningMsg = ''
$game = $serverCfg.game
if ($game -eq 'projectzomboid') {
  $proc = Get-Process -Name 'ProjectZomboidServer*','Zomboid*' -ErrorAction SilentlyContinue
  if ($proc) { $isRunning = $true; $runningMsg = 'Project Zomboid server process is running.' }
} elseif ($game -eq 'valheim') {
  $proc = Get-Process -Name 'valheim_server*' -ErrorAction SilentlyContinue
  if ($proc) { $isRunning = $true; $runningMsg = 'Valheim server process is running.' }
} elseif ($game -eq 'minecraft') {
  $proc = Get-Process -Name 'java*' -ErrorAction SilentlyContinue
  if ($proc) { 
    $mcDir = "C:\QuestPauseOps\servers\${ServerKey}"
    $isRunning = ($proc | Where-Object { $_.CommandLine -match [regex]::Escape($mcDir) -or $_.MainWindowTitle -match 'minecraft' }).Count -gt 0
    if (-not $isRunning) { $proc = $null }
    if ($proc) { $isRunning = $true; $runningMsg = 'Minecraft server (java) process is running.' }
  }
}
if ($isRunning) {
  Write-LogLine -LogPath $logPath -Message "RESTORE REFUSED: $runningMsg Stop the server first."
  Out-JsonRestore 'failed' $DryRun.IsPresent "Restore refused: $runningMsg Stop the server and try again."; exit 1
}

# --- DryRun mode ---
if ($DryRun -or -not $ConfirmRestore) {
  Write-Message "=== DRY RUN ==="
  Write-Message "Server: $displayName ($ServerKey)"
  Write-Message "Backup: $resolvedBackupPath"
  Write-Message "Manifest: $manifestPath"
  $restoreTargets = @()
  foreach ($sp in $sourcePaths) {
    $spLeaf = Split-Path $sp -Leaf
    $isSrcFile = -not (Get-Item -LiteralPath $sp -ErrorAction SilentlyContinue).PSIsContainer
    if ($isSrcFile) {
      $restoreTargets += "  FILE: $sp <- backup/$spLeaf"
      if (Test-Path $sp) { $restoreTargets += "    (would overwrite existing file)" }
    } else {
      $restoreTargets += "  DIR:  $sp <- backup/$spLeaf"
      if (Test-Path $sp) { $restoreTargets += "    (would overwrite existing files)" }
    }
  }
  foreach ($t in $restoreTargets) { Write-Message $t }
  Write-Message "Pre-restore safety backup: $backupRoot\$ServerKey\pre_restore\"
  if (-not $JsonOnly) {
    Write-Host "`nTo proceed, run with -ConfirmRestore:"
    Write-Host "powershell -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -ServerKey $ServerKey -BackupPath `"$BackupPath`" -ConfirmRestore"
  }
  Out-JsonRestore 'dry_run' $true "Dry run completed. $($sourcePaths.Count) source paths would be restored." -RestoredItems $sourcePaths.Count
  exit 0
}

# --- Full restore ---
Write-Message "Starting restore for $displayName ($ServerKey)"
Write-LogLine -LogPath $logPath -Message "Restore start | ServerKey=$ServerKey | BackupPath=$resolvedBackupPath"

# Pre-restore safety backup
$preRestoreRoot = Join-Path $backupRoot "$ServerKey\pre_restore"
$preTimestamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$preBackupPath = Join-Path $preRestoreRoot $preTimestamp
Write-Message "Creating pre-restore safety backup: $preBackupPath"
Write-LogLine -LogPath $logPath -Message "Pre-restore backup start: $preBackupPath"

$preCopied = 0
$preErrors = 0
foreach ($sp in $sourcePaths) {
  if (Test-Path $sp) {
    $leaf = Split-Path $sp -Leaf
    $preDest = Join-Path $preBackupPath $leaf
    $isSrcFile = -not (Get-Item -LiteralPath $sp).PSIsContainer
    $parentDir = Split-Path $preDest -Parent
    if (-not (Test-Path $parentDir)) { New-Item -ItemType Directory -Path $parentDir -Force | Out-Null }
    if ($isSrcFile) {
      try { Copy-Item -LiteralPath $sp -Destination $preDest -Force -ErrorAction Stop; $preCopied++ } catch { $preErrors++ }
    } else {
      New-Item -ItemType Directory -Path $preDest -Force | Out-Null
      try { & robocopy $sp $preDest /E /R:2 /W:2 /COPY:DAT /DCOPY:DAT /XJ /NDL /NFL /NJH /NJS 2>&1 | Out-Null; $preCopied++ } catch { $preErrors++ }
    }
  }
}

Write-LogLine -LogPath $logPath -Message "Pre-restore backup done: ${preCopied} saved, ${preErrors} errors"

# Perform restore
$restoreErrors = 0
$restoreWarnings = 0
$restoreCount = 0
foreach ($sp in $sourcePaths) {
  $leaf = Split-Path $sp -Leaf
  $backupItem = Join-Path $resolvedBackupPath $leaf
  if (-not (Test-Path $backupItem)) {
    Write-Message "Backup item not found, skipping: $backupItem" 'WARN'
    Write-LogLine -LogPath $logPath -Message "WARNING: Backup item missing: $backupItem"
    $restoreWarnings++
    continue
  }
  $isSrcFile = -not (Get-Item -LiteralPath $sp -ErrorAction SilentlyContinue).PSIsContainer
  if ($isSrcFile) {
    try {
      Copy-Item -LiteralPath $backupItem -Destination $sp -Force -ErrorAction Stop
      $restoreCount++
      Write-Message "Restored file: $backupItem -> $sp"
      Write-LogLine -LogPath $logPath -Message "Restored file: $sp"
    } catch {
      $restoreErrors++
      Write-Message "Restore file failed for $sp : $($_.Exception.Message)" 'ERROR'
      Write-LogLine -LogPath $logPath -Message "ERROR: Restore file $sp - $($_.Exception.Message)"
    }
  } else {
    try {
      & robocopy $backupItem $sp /E /R:2 /W:2 /COPY:DAT /DCOPY:DAT /XJ /NDL /NFL /NJH /NJS 2>&1 | Out-Null
      $rc = $LASTEXITCODE
      if ($rc -ge 8) { $hadCopies = ($rc -band 1) -eq 1; if ($hadCopies) { $restoreWarnings++; $restoreCount++ } else { $restoreErrors++ } }
      elseif ($rc -ge 2) { $restoreWarnings++; $restoreCount++ }
      else { $restoreCount++ }
      Write-Message "Restored directory: $backupItem -> $sp (robocopy exit $rc)"
      Write-LogLine -LogPath $logPath -Message "Restored directory: $sp (robocopy exit $rc)"
    } catch {
      $restoreErrors++
      Write-Message "Restore directory failed for $sp : $($_.Exception.Message)" 'ERROR'
      Write-LogLine -LogPath $logPath -Message "ERROR: Restore directory $sp - $($_.Exception.Message)"
    }
  }
}

$status = if ($restoreErrors -gt 0) { 'failed' } elseif ($restoreWarnings -gt 0) { 'warning' } else { 'success' }
Write-Message "Restore $status : $restoreCount restored, $restoreWarnings warnings, $restoreErrors errors"
Write-LogLine -LogPath $logPath -Message "Restore end | Status=$status | Items=$restoreCount | Warnings=$restoreWarnings | Errors=$restoreErrors"
Out-JsonRestore $status $false "Restore $status : $restoreCount items restored." -RestoredItems $restoreCount -Warnings $restoreWarnings -Errors $restoreErrors -PreBackupPath $preBackupPath

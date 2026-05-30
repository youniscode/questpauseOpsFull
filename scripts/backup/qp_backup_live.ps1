[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$ServerKey,

  [Parameter(Mandatory = $true)]
  [ValidateSet('hourly', 'daily', 'manual')]
  [string]$Type,

  [switch]$JsonOnly,
  [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$configPath = Join-Path $PSScriptRoot 'qp_backup_config.json'
$scriptStart = [DateTime]::UtcNow

function Write-Message {
  param([string]$Message, [string]$Level = 'INFO')
  if ($JsonOnly) { return }
  if ($Quiet -and $Level -ne 'ERROR' -and $Level -ne 'WARN') { return }
  Write-Host "${Level}: ${Message}"
}

function Write-LogLine {
  param([string]$LogPath, [string]$Message)
  $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  "$ts  $Message" | Add-Content -Path $LogPath -Encoding UTF8
}

function Get-DiscordWebhookUrl {
  param([string]$EnvName)
  if ([string]::IsNullOrWhiteSpace($EnvName)) { return '' }
  try { return [Environment]::GetEnvironmentVariable($EnvName) } catch { return '' }
}

function Send-DiscordBackupAlert {
  param(
    [string]$WebhookUrl,
    [string]$ServerDisplayName,
    [string]$BackupType,
    [string]$Status,
    [int]$WarningCount,
    [int]$ErrorCount,
    [int]$DurationSec,
    [string]$LogFilePath,
    [string]$DestPath
  )
  if ([string]::IsNullOrWhiteSpace($WebhookUrl)) { return }
  $color = switch ($Status) { 'failed' { 0xE74C3C } 'warning' { 0xE67E22 } default { 0x2ECC71 } }
  $admonition = switch ($Status) {
    'failed' { 'Action required: Check the backup log and resolve errors. If robocopy exit code 8+, locked files or permissions may be the cause.' }
    'warning' { 'Review warnings. Locked files during live server operation are normal for Minecraft/Valheim.' }
    default { '' }
  }
  $embed = @{
    title = "Backup $Status - $ServerDisplayName"
    color = $color
    timestamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
    fields = @(
      @{ name = 'Server'; value = $ServerDisplayName; inline = $true }
      @{ name = 'Type'; value = $BackupType; inline = $true }
      @{ name = 'Status'; value = $Status; inline = $true }
      @{ name = 'Warnings'; value = "$WarningCount"; inline = $true }
      @{ name = 'Errors'; value = "$ErrorCount"; inline = $true }
      @{ name = 'Duration'; value = "${DurationSec}s"; inline = $true }
      @{ name = 'Destination'; value = $DestPath; inline = $false }
      @{ name = 'Log'; value = $LogFilePath; inline = $false }
    )
  }
  if ($admonition) { $embed.fields += @{ name = 'Recommendation'; value = $admonition; inline = $false } }
  $payload = @{ embeds = @($embed) }
  try {
    $body = $payload | ConvertTo-Json -Depth 6 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    Invoke-RestMethod -Uri $WebhookUrl -Method Post -Body $bytes -ContentType 'application/json' -ErrorAction SilentlyContinue | Out-Null
  } catch { Write-Message "Discord alert send failed (non-fatal)" 'WARN' }
}

function New-BackupManifest {
  param(
    [string]$ServerKey,
    [string]$DisplayName,
    [string]$Game,
    [string]$BackupType,
    [string]$Destination,
    [bool]$Compressed,
    [string[]]$SourcePaths,
    [int]$FileCount,
    [long]$TotalBytes,
    [string[]]$Warnings,
    [string[]]$Errors
  )
  $manifest = [ordered]@{
    serverKey = $ServerKey
    displayName = $DisplayName
    game = $Game
    backupType = $BackupType
    createdAt = (Get-Date -Format 'o')
    sourcePaths = $SourcePaths
    destinationPath = $Destination
    compressed = $Compressed
    fileCount = $FileCount
    totalBytes = $TotalBytes
    warnings = $Warnings
    errors = $Errors
  }
  return $manifest
}

function Invoke-RemoteReplication {
  param(
    [object]$ReplicationCfg,
    [string]$LocalDest,
    [string]$ServerKey,
    [string]$Type,
    [string]$BackupRoot,
    [string]$LogPath
  )
  $result = @{ remoteReplicationStatus = 'none'; remoteDestinationPath = ''; remoteWarningCount = 0; remoteErrorCount = 0 }
  if (-not $ReplicationCfg -or -not $ReplicationCfg.enabled) { return $result }
  if ($ReplicationCfg.copyTypes -notcontains $Type) { return $result }

  $targetPath = [System.Environment]::ExpandEnvironmentVariables($ReplicationCfg.targetPath)
  if ([string]::IsNullOrWhiteSpace($targetPath)) { return $result }
  $dangerous = @('C:\', 'C:\QuestPauseOps', "C:\QuestPauseOps\backups", "C:\QuestPauseOps\servers", "C:\QuestPauseOps\scripts")
  $resolvedTarget = Resolve-Path $targetPath -ErrorAction SilentlyContinue
  if (-not $resolvedTarget) { $resolvedTarget = $targetPath }
  foreach ($danger in $dangerous) {
    if ($resolvedTarget -eq (Resolve-Path $danger -ErrorAction SilentlyContinue).Path) {
      Write-LogLine -LogPath $logPath -Message "REMOTE REPLICATION REFUSED: dangerous target path $targetPath"
      return @{ remoteReplicationStatus = 'refused'; remoteDestinationPath = $targetPath; remoteWarningCount = 1; remoteErrorCount = 1 }
    }
  }
  if ($resolvedTarget -like "$BackupRoot*") {
    $srKey = Split-Path $resolvedTarget -Leaf
    if ($srKey -eq $ServerKey) {
      Write-LogLine -LogPath $logPath -Message "REMOTE REPLICATION REFUSED: target is same server backup dir"
      return @{ remoteReplicationStatus = 'refused'; remoteDestinationPath = $targetPath; remoteWarningCount = 1; remoteErrorCount = 1 }
    }
  }

  $remoteServerDir = Join-Path $resolvedTarget $ServerKey
  $remoteTypeDir = Join-Path $remoteServerDir $Type
  $remoteDest = Join-Path $remoteTypeDir (Split-Path $LocalDest -Leaf)
  Write-Message "Replicating to remote: $remoteDest"
  Write-LogLine -LogPath $logPath -Message "Remote replication start: $LocalDest -> $remoteDest"

  $rWarn = 0; $rErr = 0
  try {
    $isFile = -not (Get-Item -LiteralPath $LocalDest -ErrorAction Stop).PSIsContainer
    if ($isFile) {
      $parentDir = Split-Path $remoteDest -Parent
      if (-not (Test-Path $parentDir)) { New-Item -ItemType Directory -Path $parentDir -Force | Out-Null }
      Copy-Item -LiteralPath $LocalDest -Destination $remoteDest -Force -ErrorAction Stop
      $manifestFile = [System.IO.Path]::ChangeExtension($LocalDest, '.manifest.json')
      if (Test-Path $manifestFile) { Copy-Item -LiteralPath $manifestFile -Destination (Join-Path $parentDir (Split-Path $manifestFile -Leaf)) -Force -ErrorAction SilentlyContinue }
    } else {
      if (-not (Test-Path $remoteTypeDir)) { New-Item -ItemType Directory -Path $remoteTypeDir -Force | Out-Null }
      & robocopy $LocalDest $remoteDest /E /R:2 /W:2 /COPY:DAT /DCOPY:DAT /XJ /NDL /NFL /NJH /NJS 2>&1 | Out-Null
      $rc = $LASTEXITCODE
      if ($rc -ge 8) { $rErr++ } elseif ($rc -ge 2) { $rWarn++ }
      $mSrc = Join-Path $LocalDest 'backup-manifest.json'
      if (Test-Path $mSrc) { Copy-Item -LiteralPath $mSrc -Destination $remoteDest -Force -ErrorAction SilentlyContinue }
    }
    Write-LogLine -LogPath $logPath -Message "Remote replication done: $remoteDest (warn=$rWarn err=$rErr)"
  } catch {
    $rErr++; Write-LogLine -LogPath $logPath -Message "Remote replication error: $($_.Exception.Message)"
  }

  # Retention on remote
  if ($ReplicationCfg.keepRemoteDaily -gt 0 -and $Type -eq 'daily' -and (Test-Path $remoteTypeDir)) {
    $all = Get-ChildItem -LiteralPath $remoteTypeDir -ErrorAction SilentlyContinue | Sort-Object Name -Descending
    if ($all.Count -gt $ReplicationCfg.keepRemoteDaily) {
      $toDel = $all | Select-Object -Skip $ReplicationCfg.keepRemoteDaily
      foreach ($d in $toDel) {
        try { if ($d.PSIsContainer) { Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction Stop } else { Remove-Item -LiteralPath $d.FullName -Force -ErrorAction Stop } } catch {}
      }
    }
  }
  return @{ remoteReplicationStatus = 'done'; remoteDestinationPath = $remoteDest; remoteWarningCount = $rWarn; remoteErrorCount = $rErr }
}

# --- Load config ---
if (-not (Test-Path $configPath)) {
  $errMsg = "Config not found: $configPath"
  if ($JsonOnly) { Write-Output (ConvertTo-Json @{ status = 'failed'; error = $errMsg }) }
  else { Write-Message $errMsg 'ERROR' }
  exit 1
}

try { $config = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json }
catch {
  $errMsg = "Failed to parse config: $($_.Exception.Message)"
  if ($JsonOnly) { Write-Output (ConvertTo-Json @{ status = 'failed'; error = $errMsg }) }
  else { Write-Message $errMsg 'ERROR' }
  exit 1
}

# Find server config
$serverCfg = $null
foreach ($s in $config.servers) { if ($s.serverKey -eq $ServerKey) { $serverCfg = $s; break } }
if (-not $serverCfg) {
  $errMsg = "ServerKey '$ServerKey' not found in config"
  if ($JsonOnly) { Write-Output (ConvertTo-Json @{ status = 'failed'; error = $errMsg }) }
  else { Write-Message $errMsg 'ERROR' }
  exit 1
}
if (-not $serverCfg.enabled) {
  $errMsg = "Server '$ServerKey' is disabled in backup config"
  if ($JsonOnly) { Write-Output (ConvertTo-Json @{ status = 'failed'; error = $errMsg }) }
  else { Write-Message $errMsg 'ERROR' }
  exit 1
}

# Resolve paths
$backupRoot = [System.Environment]::ExpandEnvironmentVariables($config.backupRoot)
$logRoot = [System.Environment]::ExpandEnvironmentVariables($config.logRoot)
$stateRoot = [System.Environment]::ExpandEnvironmentVariables($config.stateRoot)

$sourcePaths = @()
foreach ($sp in $serverCfg.sourcePaths) { $sourcePaths += [System.Environment]::ExpandEnvironmentVariables($sp) }

$displayName = $serverCfg.displayName
$game = $serverCfg.game

# Config flags
$backupMode = if ($serverCfg.PSObject.Properties.Name -contains 'backupMode') { [string]$serverCfg.backupMode } else { 'robocopy' }
$vssFallback = if ($serverCfg.PSObject.Properties.Name -contains 'vssFallbackToRobocopy') { [bool]$serverCfg.vssFallbackToRobocopy } else { $false }
$compressDaily = if ($serverCfg.PSObject.Properties.Name -contains 'compressDaily') { [bool]$serverCfg.compressDaily } else { $false }
$compressManual = if ($serverCfg.PSObject.Properties.Name -contains 'compressManual') { [bool]$serverCfg.compressManual } else { $false }
$compressThis = ($Type -eq 'daily' -and $compressDaily) -or ($Type -eq 'manual' -and $compressManual)
$compressionLevel = if ($serverCfg.PSObject.Properties.Name -contains 'compressionLevel') { [string]$serverCfg.compressionLevel } else { 'Optimal' }
$verifyAfter = if ($serverCfg.PSObject.Properties.Name -contains 'verifyAfterBackup') { [bool]$serverCfg.verifyAfterBackup } else { $false }
$discordCfg = if ($serverCfg.PSObject.Properties.Name -contains 'discordAlerts') { $serverCfg.discordAlerts } else { $null }
$remoteCfg = if ($serverCfg.PSObject.Properties.Name -contains 'remoteReplication') { $serverCfg.remoteReplication } else { $null }

# Setup paths
$logPath = Join-Path $logRoot "${ServerKey}-$(Get-Date -Format 'yyyy-MM-dd').log"
$stateDir = Join-Path $stateRoot $ServerKey
$lastResultPath = Join-Path $stateDir 'last-result.json'
$historyPath = Join-Path $stateDir 'history.jsonl'

$backupTypeDir = Join-Path (Join-Path $backupRoot $ServerKey) $Type
$timestamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$stagingRoot = Join-Path $backupTypeDir "${timestamp}_staging"
$destRoot = $stagingRoot

Write-LogLine -LogPath $logPath -Message "Backup start | ServerKey=$ServerKey | DisplayName=$displayName | Type=$Type | Mode=$backupMode"

# Ensure directories
foreach ($d in @($stagingRoot, $stateDir, (Split-Path $logPath -Parent))) {
  if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

$folderNames = @()
foreach ($sp in $sourcePaths) { $folderNames += (Split-Path $sp -Leaf) }

Write-Message "Starting $Type backup for $displayName ($ServerKey)"
Write-Message "Staging: $stagingRoot"
Write-LogLine -LogPath $logPath -Message "Destination (staging): $stagingRoot"

$robocopyMaxExit = 0
$copiedCount = 0
$missingCount = 0
$warningCount = 0
$errorCount = 0
$robocopyResults = @()
$manifestWarnings = @()
$manifestErrors = @()

# --- VSS snapshot setup ---
$vssShadowPath = $null
$vssCreated = $false
if ($backupMode -eq 'vss') {
  try {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { throw 'VSS requires Administrator privileges.' }
    $sourceDrive = (Get-Item $sourcePaths[0]).PSDrive.Root.TrimEnd('\')
    Write-Message "Creating VSS shadow copy for $sourceDrive"
    Write-LogLine -LogPath $logPath -Message "VSS: Creating shadow copy for $sourceDrive"
    $vssScript = Join-Path $env:TEMP "qp_vss_$(Get-Random).txt"
    @"
begin backup
add volume $sourceDrive alias QPBackup
create
end backup
"@ | Out-File -FilePath $vssScript -Encoding ASCII
    $vssOutput = & diskshadow /s $vssScript 2>&1 | Out-String
    Remove-Item $vssScript -Force -ErrorAction SilentlyContinue
    $vssPathLine = $vssOutput | Select-String -Pattern 'Shadow Copy Device:\\s+(.*)'
    if ($vssPathLine) { $vssShadowPath = $vssPathLine.Matches[0].Groups[1].Value.Trim() }
    if (-not $vssShadowPath) { throw 'VSS shadow copy created but path could not be resolved.' }
    $vssCreated = $true
    Write-Message "VSS shadow path: $vssShadowPath"
    Write-LogLine -LogPath $logPath -Message "VSS: Shadow copy at $vssShadowPath"
  } catch {
    Write-Message "VSS failed: $($_.Exception.Message)" 'WARN'
    Write-LogLine -LogPath $logPath -Message "VSS error: $($_.Exception.Message)"
    if ($vssFallback) {
      Write-Message "VSS fallback: using robocopy directly"
      Write-LogLine -LogPath $logPath -Message "VSS fallback to robocopy"
    } else {
      $errorCount++
      $manifestErrors += "VSS failed: $($_.Exception.Message)"
    }
  }
}

# --- Copy loop ---
for ($i = 0; $i -lt $sourcePaths.Count; $i++) {
  $src = $sourcePaths[$i]
  if ($vssShadowPath -and $vssCreated) {
    $relative = $src.Substring((Get-Item $src).PSDrive.Root.Length).TrimStart('\')
    $effectiveSrc = Join-Path $vssShadowPath $relative
    if (-not (Test-Path $effectiveSrc)) { $effectiveSrc = $src }
  } else {
    $effectiveSrc = $src
  }
  $folderLabel = $folderNames[$i]
  $subDest = Join-Path $stagingRoot $folderLabel

  if (-not (Test-Path $effectiveSrc)) {
    $srcDisplay = if ($effectiveSrc -ne $src) { "$src (VSS: $effectiveSrc)" } else { $src }
    Write-Message "Source not found, skipping: $srcDisplay" 'WARN'
    Write-LogLine -LogPath $logPath -Message "WARNING: Source not found: $srcDisplay"
    $missingCount++; $warningCount++
    $manifestWarnings += "Source not found: $src"
    $robocopyResults += @{ source = $src; destination = $subDest; exitCode = -1; status = 'missing' }
    continue
  }

  $isFile = -not (Get-Item -LiteralPath $effectiveSrc).PSIsContainer

  if ($isFile) {
    $destFileDir = Split-Path $subDest -Parent
    if (-not (Test-Path $destFileDir)) { New-Item -ItemType Directory -Path $destFileDir -Force | Out-Null }
    Write-Message "Copying file: $effectiveSrc -> $subDest"
    Write-LogLine -LogPath $logPath -Message "Copy-Item start: $effectiveSrc -> $subDest"
    try {
      Copy-Item -LiteralPath $effectiveSrc -Destination $subDest -Force -ErrorAction Stop
      $rcExit = 0; $copiedCount++
      Write-Message "Copied file: ${folderLabel}"
      Write-LogLine -LogPath $logPath -Message "OK: Copy-Item for ${folderLabel}"
    } catch {
      $rcExit = 8; $errorCount++
      Write-Message "Copy-Item failed for ${folderLabel}: $($_.Exception.Message)" 'ERROR'
      Write-LogLine -LogPath $logPath -Message "ERROR: Copy-Item for ${folderLabel} - $($_.Exception.Message)"
      $manifestErrors += "Copy-Item failed for ${folderLabel}: $($_.Exception.Message)"
    }
  } else {
    New-Item -ItemType Directory -Path $subDest -Force | Out-Null
    Write-Message "Copying directory: $effectiveSrc -> $subDest"
    Write-LogLine -LogPath $logPath -Message "Robocopy start: $effectiveSrc -> $subDest"

    & robocopy $effectiveSrc $subDest /E /R:2 /W:2 /COPY:DAT /DCOPY:DAT /XJ /NDL /NFL /NJH /NJS 2>&1 | Out-Null
    $rcExit = $LASTEXITCODE

    if ($rcExit -ge 8) {
      $hadCopies = ($rcExit -band 1) -eq 1
      if ($hadCopies) {
        $copiedCount++; $warningCount++
        Write-Message "Robocopy partial for ${folderLabel} (exit $rcExit, some files locked)" 'WARN'
        Write-LogLine -LogPath $logPath -Message "WARNING: Robocopy exit $rcExit for ${folderLabel} (partial, locked files)"
        $manifestWarnings += "Robocopy partial ${folderLabel} (exit $rcExit): some files locked"
      } else {
        $errorCount++
        Write-Message "Robocopy failed for ${folderLabel} (exit $rcExit)" 'ERROR'
        Write-LogLine -LogPath $logPath -Message "ERROR: Robocopy exit $rcExit for ${folderLabel}"
        $manifestErrors += "Robocopy failed for ${folderLabel} (exit $rcExit)"
      }
    } elseif ($rcExit -ge 2) {
      $warningCount++
      Write-Message "Robocopy warnings for ${folderLabel} (exit $rcExit)" 'WARN'
      Write-LogLine -LogPath $logPath -Message "WARNING: Robocopy exit $rcExit for ${folderLabel}"
      $manifestWarnings += "Robocopy warnings ${folderLabel} (exit $rcExit)"
    } else {
      $copiedCount++
      Write-Message "Copied directory: ${folderLabel}"
      Write-LogLine -LogPath $logPath -Message "OK: Robocopy exit $rcExit for ${folderLabel}"
    }
  }

  if ($rcExit -gt $robocopyMaxExit) { $robocopyMaxExit = $rcExit }
  $robocopyResults += @{ source = $src; destination = $subDest; exitCode = $rcExit; status = 'ok' }
}

# --- Cleanup VSS ---
if ($vssCreated) {
  try { & diskshadow /s "delete shadows volume $((Get-Item $sourcePaths[0]).PSDrive.Root.TrimEnd('\'))" 2>&1 | Out-Null } catch {}
  Write-LogLine -LogPath $logPath -Message "VSS: shadow copy deleted"
}

$scriptEnd = [DateTime]::UtcNow
$durationSeconds = [int]($scriptEnd - $scriptStart).TotalSeconds

# Determine overall status
$status = 'success'
$fatalRobocopy = ($robocopyMaxExit -ge 8) -and (($robocopyMaxExit -band 1) -eq 0)
if ($errorCount -gt 0 -or $fatalRobocopy) { $status = 'failed' }
elseif ($warningCount -gt 0 -or $missingCount -gt 0 -or ($robocopyMaxExit -ge 8)) { $status = 'warning' }

if ($sourcePaths.Count -gt 0 -and $missingCount -eq $sourcePaths.Count) {
  $status = 'failed'
  Write-Message "All source paths missing - backup failed" 'ERROR'
  Write-LogLine -LogPath $logPath -Message "FATAL: All source paths missing"
}

Write-Message "Backup copy ${status}: ${copiedCount} copied, ${missingCount} missing, ${warningCount} warnings, ${errorCount} errors, ${durationSeconds}s"

# --- Build manifest ---
# If this is not compressible or if status is failed (all missing), skip compression
$finalDestPath = $stagingRoot
$isCompressed = $false
$zipPath = $null

# Count files in staging
$stagingFileCount = 0
$stagingTotalBytes = 0
if ($status -ne 'failed' -and (Test-Path $stagingRoot)) {
  $allStagingFiles = Get-ChildItem -LiteralPath $stagingRoot -Recurse -File -ErrorAction SilentlyContinue
  $stagingFileCount = $allStagingFiles.Count
  $stagingTotalBytes = ($allStagingFiles | Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
}

# --- Compression ---
if ($compressThis -and $status -ne 'failed' -and (Test-Path $stagingRoot) -and $stagingFileCount -gt 0) {
  $zipName = "${timestamp}.zip"
  $zipPath = Join-Path $backupTypeDir $zipName
  Write-Message "Compressing to zip: $zipPath"
  Write-LogLine -LogPath $logPath -Message "Compression start: $stagingRoot -> $zipPath"
  $compressOk = $false
  try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $compressionLevelEnum = if ($compressionLevel -eq 'Optimal') { [System.IO.Compression.CompressionLevel]::Optimal } else { [System.IO.Compression.CompressionLevel]::Fastest }
    if (-not (Test-Path $backupTypeDir)) { New-Item -ItemType Directory -Path $backupTypeDir -Force | Out-Null }
    [System.IO.Compression.ZipFile]::CreateFromDirectory($stagingRoot, $zipPath, $compressionLevelEnum, $false)
    if (Test-Path $zipPath) { $compressOk = $true }
  } catch {
    Write-Message "Compression failed: $($_.Exception.Message)" 'ERROR'
    Write-LogLine -LogPath $logPath -Message "ERROR: Compression failed: $($_.Exception.Message)"
    $manifestErrors += "Compression failed: $($_.Exception.Message)"
  }
  if ($compressOk) {
    $finalDestPath = $zipPath
    $isCompressed = $true
    Write-Message "Compressed: $zipPath"
    Write-LogLine -LogPath $logPath -Message "OK: Compression created $zipPath"
    # Write manifest side-by-side with zip
    $manifest = New-BackupManifest -ServerKey $ServerKey -DisplayName $displayName -Game $game -BackupType $Type -Destination $zipPath -Compressed $true -SourcePaths $sourcePaths -FileCount $stagingFileCount -TotalBytes $stagingTotalBytes -Warnings $manifestWarnings -Errors $manifestErrors
    $manifestJson = $manifest | ConvertTo-Json -Depth 6
    $manifestSidecar = [System.IO.Path]::ChangeExtension($zipPath, '.manifest.json')
    $manifestJson | Set-Content -Path $manifestSidecar -Encoding UTF8 -Force
    # Clean up staging
    try { Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction Stop } catch { Write-Message "Staging cleanup warning: $($_.Exception.Message)" 'WARN' }
  }
}

# --- Write manifest for folder backup ---
if (-not $isCompressed -and $status -ne 'failed' -and (Test-Path $stagingRoot)) {
  $manifest = New-BackupManifest -ServerKey $ServerKey -DisplayName $displayName -Game $game -BackupType $Type -Destination $stagingRoot -Compressed $false -SourcePaths $sourcePaths -FileCount $stagingFileCount -TotalBytes $stagingTotalBytes -Warnings $manifestWarnings -Errors $manifestErrors
  $manifest | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $stagingRoot 'backup-manifest.json') -Encoding UTF8 -Force
}

# --- Verification ---
$verifyStatus = $null
if ($verifyAfter -and $status -ne 'failed' -and $finalDestPath -and (Test-Path $finalDestPath)) {
  Write-Message "Running backup verification..."
  Write-LogLine -LogPath $logPath -Message "Verification start"
  $verifyResult = & powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\qp_backup_verify.ps1" -ServerKey $ServerKey -BackupPath $finalDestPath -JsonOnly 2>&1 | Out-String
  try { $verifyParsed = $verifyResult | ConvertFrom-Json } catch { $verifyParsed = $null }
  if ($verifyParsed) {
    $verifyStatus = $verifyParsed.status
    Write-Message "Verification: $verifyStatus (files=$($verifyParsed.checkedFileCount), missing=$($verifyParsed.missingItemCount))"
    Write-LogLine -LogPath $logPath -Message "Verification result: status=$verifyStatus checked=$($verifyParsed.checkedFileCount) missing=$($verifyParsed.missingItemCount)"
    if ($verifyStatus -eq 'failed') {
      $errorCount++; $status = 'failed'
      $manifestErrors += "Verification failed: $($verifyParsed.message)"
    } elseif ($verifyStatus -eq 'warning') {
      $warningCount++
      if ($status -eq 'success') { $status = 'warning' }
      $manifestWarnings += "Verification warning: $($verifyParsed.message)"
    }
  } else {
    Write-Message "Verification output unparseable" 'WARN'
    Write-LogLine -LogPath $logPath -Message "Verification output could not be parsed"
  }
}

# --- Remote replication ---
$remoteResult = Invoke-RemoteReplication -ReplicationCfg $remoteCfg -LocalDest $finalDestPath -ServerKey $ServerKey -Type $Type -BackupRoot $backupRoot -LogPath $logPath

$scriptEndFinal = [DateTime]::UtcNow
$durationSecondsFinal = [int]($scriptEndFinal - $scriptStart).TotalSeconds

# --- Discord alert ---
$discordEnabled = $discordCfg -and $discordCfg.enabled -and $discordCfg.alertOn -contains $status
if ($discordEnabled) {
  $webhookEnvName = [string]$discordCfg.webhookEnv
  if (-not [string]::IsNullOrWhiteSpace($webhookEnvName)) {
    $whUrl = Get-DiscordWebhookUrl -EnvName $webhookEnvName
    if (-not [string]::IsNullOrWhiteSpace($whUrl)) {
      Send-DiscordBackupAlert -WebhookUrl $whUrl -ServerDisplayName $displayName -BackupType $Type -Status $status -WarningCount $warningCount -ErrorCount $errorCount -DurationSec $durationSecondsFinal -LogFilePath $logPath -DestPath $finalDestPath
      Write-LogLine -LogPath $logPath -Message "Discord alert sent for status=$status"
    }
  }
}

# Build result object
$result = [ordered]@{
  serverKey = $ServerKey
  displayName = $displayName
  game = $game
  backupType = $Type
  status = $status
  startedAt = $scriptStart.ToString('o')
  finishedAt = $scriptEndFinal.ToString('o')
  durationSeconds = $durationSecondsFinal
  destinationPath = $finalDestPath
  sourceCount = $sourcePaths.Count
  copiedSourceCount = $copiedCount
  missingSourceCount = $missingCount
  warningCount = $warningCount
  errorCount = $errorCount
  robocopyMaxExitCode = $robocopyMaxExit
  logPath = $logPath
  compressed = $isCompressed
  verified = $verifyStatus
  restoreReady = $true
  restoreImplemented = $true
  remoteReplicationStatus = $remoteResult.remoteReplicationStatus
  remoteDestinationPath = $remoteResult.remoteDestinationPath
  remoteWarningCount = $remoteResult.remoteWarningCount
  remoteErrorCount = $remoteResult.remoteErrorCount
}

Write-LogLine -LogPath $logPath -Message "Status: $status | Duration: ${durationSecondsFinal}s | Sources: $($sourcePaths.Count) | Copied: ${copiedCount} | Missing: ${missingCount} | Warnings: ${warningCount} | Errors: ${errorCount} | Compressed: ${isCompressed} | Verify: $(if($verifyStatus){$verifyStatus}else{'none'})"
Write-LogLine -LogPath $logPath -Message "Backup end"

# Write state files
$resultJson = $result | ConvertTo-Json -Depth 8
$resultLine = $result | ConvertTo-Json -Depth 8 -Compress
$resultJson | Set-Content -Path $lastResultPath -Encoding UTF8 -Force
$resultLine | Add-Content -Path $historyPath -Encoding UTF8

# --- Retention (after state written) ---
if ($status -ne 'failed') {
  $retainCount = 0
  if ($Type -eq 'hourly') { $retainCount = [int]$serverCfg.keepHourly }
  elseif ($Type -eq 'daily') { $retainCount = [int]$serverCfg.keepDaily }
  elseif ($Type -eq 'manual') { $retainCount = [int]$serverCfg.keepManual }

  if ($retainCount -gt 0 -and (Test-Path $backupTypeDir)) {
    $allItems = Get-ChildItem -LiteralPath $backupTypeDir -ErrorAction SilentlyContinue | Sort-Object Name -Descending
    if ($allItems.Count -gt $retainCount) {
      $toDelete = $allItems | Select-Object -Skip $retainCount
      foreach ($bd in $toDelete) {
        try {
          if ($bd.PSIsContainer) { Remove-Item -LiteralPath $bd.FullName -Recurse -Force -ErrorAction Stop }
          else { Remove-Item -LiteralPath $bd.FullName -Force -ErrorAction Stop }
          Write-Message "Retention: removed old backup $($bd.Name)"
          Write-LogLine -LogPath $logPath -Message "Retention deleted: $($bd.FullName)"
        } catch {
          Write-Message "Retention: failed to remove $($bd.Name)" 'WARN'
          Write-LogLine -LogPath $logPath -Message ("Retention error: {0} - {1}" -f $bd.FullName, $_.Exception.Message)
        }
      }
    }
  }
}

# Output
if ($JsonOnly) {
  Write-Output $resultJson
} else {
  Write-Message "Log: $logPath"
  Write-Message "Result: $lastResultPath"
}

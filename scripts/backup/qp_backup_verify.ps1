[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$ServerKey,

  [Parameter(Mandatory = $true)]
  [string]$BackupPath,

  [switch]$JsonOnly
)

Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
$ErrorActionPreference = 'Continue'

function Out-JsonVerify {
  param(
    [string]$Status,
    [int]$Checked = 0,
    [int]$Missing = 0,
    [bool]$Corrupt = $false,
    [string]$Message = ''
  )
  $output = [ordered]@{
    status = $Status
    serverKey = $ServerKey
    backupPath = $BackupPath
    checkedFileCount = $Checked
    missingItemCount = $Missing
    corruptArchive = $Corrupt
    message = $Message
  }
  if ($JsonOnly) { Write-Output ($output | ConvertTo-Json -Depth 3) }
  else {
    Write-Host "Status: $Status"
    Write-Host "Files checked: $Checked"
    Write-Host "Missing: $Missing"
    Write-Host "Corrupt: $Corrupt"
    Write-Host "Message: $Message"
  }
}

$resolvedPath = [System.Environment]::ExpandEnvironmentVariables($BackupPath)

if (-not (Test-Path $resolvedPath)) {
  Out-JsonVerify 'failed' 0 0 $false "Backup path does not exist: $resolvedPath"; exit 1
}

$isFolder = (Get-Item -LiteralPath $resolvedPath).PSIsContainer
$corrupt = $false
$missingItems = 0
$checkedCount = 0

if ($isFolder) {
  $manifestPath = Join-Path $resolvedPath 'backup-manifest.json'
  if (Test-Path $manifestPath) {
    $manifest = Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.sourcePaths) {
      foreach ($sp in $manifest.sourcePaths) {
        $leaf = Split-Path $sp -Leaf
        $expected = Join-Path $resolvedPath $leaf
        if (Test-Path $expected) {
          $items = @(Get-ChildItem -LiteralPath $expected -Recurse -ErrorAction SilentlyContinue)
          $checkedCount += $items.Count
        } else {
          $missingItems++
        }
      }
    }
    if ($manifest.fileCount -and $checkedCount -lt $manifest.fileCount) { $missingItems += ($manifest.fileCount - $checkedCount) }
    $status = if ($missingItems -gt 0) { 'warning' } else { 'success' }
    Out-JsonVerify $status $checkedCount $missingItems $corrupt "Folder backup verified. $checkedCount files present, $missingItems missing."
  } else {
    $items = @(Get-ChildItem -LiteralPath $resolvedPath -Recurse -File -ErrorAction SilentlyContinue)
    $checkedCount = $items.Count
    Out-JsonVerify 'warning' $checkedCount 0 $corrupt "No manifest found. $checkedCount files found."
  }
} else {
  try {
    $zip = [System.IO.Compression.ZipFile]::OpenRead($resolvedPath)
    $checkedCount = $zip.Entries.Count
    $zip.Dispose()
    $parentDir = Split-Path $resolvedPath -Parent
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($resolvedPath)
    $manifestPath = Join-Path $parentDir "${stem}.manifest.json"
    if (Test-Path $manifestPath) {
      $manifest = Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($manifest.fileCount -and $checkedCount -lt $manifest.fileCount) { $missingItems = $manifest.fileCount - $checkedCount }
    }
    Out-JsonVerify 'success' $checkedCount $missingItems $corrupt "Zip backup verified. $checkedCount entries in archive."
  } catch {
    $corrupt = $true
    Out-JsonVerify 'failed' 0 0 $corrupt "Cannot open zip archive: $($_.Exception.Message)"
  }
}

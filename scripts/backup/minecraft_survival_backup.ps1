# Bootstrap: resolve QuestPauseOps root paths from env.ps1
$__qpEnv = $null
foreach ($__qpRel in @('..\env.ps1', '..\..\env.ps1', '..\..\..\env.ps1', '..\..\..\..\env.ps1')) {
    $__qpTest = Join-Path $PSScriptRoot $__qpRel
    if (Test-Path $__qpTest) { $__qpEnv = $__qpTest; break }
}
if (-not $__qpEnv) { throw "env.ps1 not found from $PSScriptRoot" }
. $__qpEnv
Remove-Variable __qpEnv, __qpRel, __qpTest -ErrorAction SilentlyContinue

$ServerRoot = "$script:QPRoot\servers\minecraft_survival"
$BackupRoot = "$($script:QPRoot)\backups\minecraft_survival"

$Stamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$BackupFile = Join-Path $BackupRoot "minecraft_survival_$Stamp.zip"

New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null

$Items = @(
    "world",
    "world_nether",
    "world_the_end",
    "plugins",
    "server.properties",
    "ops.json",
    "whitelist.json",
    "banned-players.json",
    "banned-ips.json"
)

$Paths = foreach ($Item in $Items) {
    $Path = Join-Path $ServerRoot $Item
    if (Test-Path $Path) { $Path }
}

Compress-Archive -Path $Paths -DestinationPath $BackupFile -Force

Get-ChildItem $BackupRoot -Filter "*.zip" |
Sort-Object LastWriteTime -Descending |
Select-Object -Skip 10 |
Remove-Item -Force

Write-Host "Minecraft backup created: $BackupFile"
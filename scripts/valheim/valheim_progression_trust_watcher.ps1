param(
  [string]$ServerKey = "valheim_main",
  [string]$LogPath = "",
  [string]$ReportPath = "",
  [int]$TailLines = 2500
)


# Bootstrap: resolve QuestPauseOps root paths from env.ps1
$__qpEnv = $null
foreach ($__qpRel in @('..\env.ps1', '..\..\env.ps1', '..\..\..\env.ps1', '..\..\..\..\env.ps1')) {
    $__qpTest = Join-Path $PSScriptRoot $__qpRel
    if (Test-Path $__qpTest) { $__qpEnv = $__qpTest; break }
}
if (-not $__qpEnv) { throw "env.ps1 not found from $PSScriptRoot" }
. $__qpEnv
Remove-Variable __qpEnv, __qpRel, __qpTest -ErrorAction SilentlyContinue
$ErrorActionPreference = "Stop"

# Resolve paths from servers.json if not explicitly provided
if ([string]::IsNullOrWhiteSpace($LogPath) -or [string]::IsNullOrWhiteSpace($ReportPath)) {
    $cfgPath = Join-Path $script:QPConfigRoot 'servers.json'
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    $svr = $cfg.servers.$ServerKey
    if (-not $svr) { throw "ServerKey '$ServerKey' not found in servers.json" }
    if ([string]::IsNullOrWhiteSpace($LogPath)) {
        $LogPath = [string]$svr.logPath
        if ([string]::IsNullOrWhiteSpace($LogPath)) { throw "logPath not configured for $ServerKey in servers.json" }
    }
    if ([string]::IsNullOrWhiteSpace($ReportPath)) {
        $ReportPath = Join-Path $script:QPReportsRoot "$ServerKey\valheim_progression_trust_latest.txt"
    }
}

function Add-Finding {
  param(
    [System.Collections.ArrayList]$List,
    [string]$Severity,
    [string]$Category,
    [string]$Title,
    [string]$Detail,
    [string]$Evidence
  )

  [void]$List.Add([pscustomobject]@{
    severity = $Severity
    category = $Category
    title    = $Title
    detail   = $Detail
    evidence = $Evidence
  })
}

if (-not (Test-Path $LogPath)) {
  throw "Log file not found: $LogPath"
}

$reportDir = Split-Path $ReportPath -Parent
New-Item -ItemType Directory -Path $reportDir -Force | Out-Null

$lines = Get-Content $LogPath -Tail $TailLines
$findings = New-Object System.Collections.ArrayList
$players = @{}
$currentClient = $null
$currentSteam = $null
$currentCharacter = $null
$currentMods = New-Object System.Collections.ArrayList

$requiredProgressionMods = @(
  "WorldAdvancementProgression",
  "ZenBossStone",
  "AzuAntiCheat"
)

$lineNumberBase = 0
try {
  $totalLines = (Get-Content $LogPath | Measure-Object -Line).Lines
  $lineNumberBase = [Math]::Max(0, $totalLines - $lines.Count)
} catch {
  $lineNumberBase = 0
}

for ($i = 0; $i -lt $lines.Count; $i++) {
  $line = [string]$lines[$i]
  $lineNo = $lineNumberBase + $i + 1

  if ($line -match "Got connection SteamID\s+(\d+)") {
    $currentSteam = $matches[1]
    if (-not $players.ContainsKey($currentSteam)) {
      $players[$currentSteam] = [pscustomobject]@{
        steamId = $currentSteam
        clientName = ""
        characterName = ""
        connects = 0
        disconnects = 0
        mismatches = 0
        emergencyRestores = 0
        mods = New-Object System.Collections.ArrayList
        lastEvidence = ""
      }
    }
    $players[$currentSteam].connects++
    $players[$currentSteam].lastEvidence = ("Line {0}: {1}" -f $lineNo, $line)
  }

  if ($line -match "client\s+(.+?)\s+a\.k\.a\s+(.+?)\s+\(Steam_(\d+)\)\s+-> list of mods running on client side") {
    $clientName = $matches[1].Trim()
    $characterName = $matches[2].Trim()
    $steamId = $matches[3].Trim()

    $currentSteam = $steamId
    $currentClient = $clientName
    $currentCharacter = $characterName
    $currentMods = New-Object System.Collections.ArrayList

    if (-not $players.ContainsKey($steamId)) {
      $players[$steamId] = [pscustomobject]@{
        steamId = $steamId
        clientName = ""
        characterName = ""
        connects = 0
        disconnects = 0
        mismatches = 0
        emergencyRestores = 0
        mods = New-Object System.Collections.ArrayList
        lastEvidence = ""
      }
    }

    $players[$steamId].clientName = $clientName
    $players[$steamId].characterName = $characterName
    $players[$steamId].lastEvidence = ("Line {0}: {1}" -f $lineNo, $line)
  }

  if ($currentSteam -and $line -match "^([A-Za-z0-9_\- ]+)\s+v\d") {
    $modName = $matches[1].Trim()
    if ($modName.Length -gt 0) {
      [void]$players[$currentSteam].mods.Add($modName)
    }
  }

  if ($line -match "Missing/Mismatched Mod\(s\) Found") {
    $steamId = $null
    $name = "Unknown player"

    if ($line -match "client\s+(.+?)\s+a\.k\.a\s+(.+?)\s+\(Steam_(\d+)\)") {
      $name = "$($matches[1]) / $($matches[2])"
      $steamId = $matches[3]
    } elseif ($currentSteam) {
      $steamId = $currentSteam
    }

    if ($steamId -and $players.ContainsKey($steamId)) {
      $players[$steamId].mismatches++
    }

    Add-Finding $findings "warning" "Mod Compliance" "Missing or mismatched client mods" "$name had a mod mismatch and may not be using the approved QUESTPAUSE Valheim profile." ("Line {0}: {1}" -f $lineNo, $line)
  }

  if ($line -match "(?i)(successfully|succesfully)\s+restored\s+an\s+emergency\s+backup") {
    $steamId = $null
    $name = "Unknown player"

    if ($line -match "Client Steam_(\d+).+for Steam_\d+_(.+?)\.") {
      $steamId = $matches[1]
      $name = $matches[2]
    }

    if ($steamId -and $players.ContainsKey($steamId)) {
      $players[$steamId].emergencyRestores++
      $p = $players[$steamId]
      $name = "$($p.clientName) / $($p.characterName) / Steam_$steamId"
    }

    Add-Finding $findings "review" "Character Safety" "Emergency backup restored" "$name restored an emergency backup. This is not automatically bad, but should be reviewed if it happens often, especially together with mod mismatch or reconnect loops." ("Line {0}: {1}" -f $lineNo, $line)
  }

  if ($line -match "Peer \((\d+)\) disconnected") {
    $steamId = $matches[1]

    if ($players.ContainsKey($steamId)) {
      $p = $players[$steamId]

      if (-not ($p.PSObject.Properties.Name -contains 'rawDisconnectEvents')) {
        Add-Member -InputObject $p -NotePropertyName rawDisconnectEvents -NotePropertyValue 0 -Force
      }

      if (-not ($p.PSObject.Properties.Name -contains 'lastDisconnectLine')) {
        Add-Member -InputObject $p -NotePropertyName lastDisconnectLine -NotePropertyValue 0 -Force
      }

      $p.rawDisconnectEvents++

      # Debounce plugin cleanup spam:
      # Valheim/BepInEx writes one "Peer disconnected" line per validated plugin.
      # Count only one real disconnect session when several lines happen close together.
      $lastDisconnectLine = [int]$p.lastDisconnectLine
      if ($lastDisconnectLine -eq 0 -or (($lineNo - $lastDisconnectLine) -gt 12)) {
        $p.disconnects++
      }

      $p.lastDisconnectLine = $lineNo
    }
  }

  if ($line -match "Random event set:(.+)$") {
    $eventName = $matches[1].Trim()

    $meaning = switch -Regex ($eventName) {
      "army_bonemass" { "Swamp-tier raid/event signal detected. This usually means Elder-cleared / Swamp-stage progression is active or exposed by player/world events. This is NOT proof that Bonemass was killed and NOT proof that a player skipped progression."; break }
      "army_moder" { "Moder-tier world event detected. This suggests later-game progression signals."; break }
      "army_goblin|goblin" { "Plains-tier event detected. This suggests Yagluth/plains-era pressure may be active."; break }
      "army_eikthyr" { "Early boss-tier world event detected."; break }
      default { "World event detected. Review against your intended server progression."; break }
    }

    Add-Finding $findings "review" "World Event Signal" "Raid/event detected: $eventName" $meaning ("Line {0}: {1}" -f $lineNo, $line)
  }
}

foreach ($steamId in $players.Keys) {
  $p = $players[$steamId]

  if ($p.connects -ge 3 -and $p.disconnects -ge 2) {
    Add-Finding $findings "review" "Connection Pattern" "Reconnect loop detected" "$($p.clientName) / $($p.characterName) connected $($p.connects) time(s) and disconnected $($p.disconnects) time(s) in the scanned log window." $p.lastEvidence
  }

  foreach ($required in $requiredProgressionMods) {
    $hasMod = $false
    foreach ($m in $p.mods) {
      if ([string]$m -like "*$required*") {
        $hasMod = $true
        break
      }
    }

    if (-not $hasMod -and $p.clientName) {
      Add-Finding $findings "warning" "Progression Mod Trust" "Required progression/security mod not seen in client list" "$($p.clientName) / $($p.characterName) did not show $required in the captured client mod list. This may be incomplete logging, but it is worth reviewing." "SteamID: $steamId"
    }
  }
}

$critical = @($findings | Where-Object { $_.severity -eq "critical" }).Count
$warning  = @($findings | Where-Object { $_.severity -eq "warning" }).Count
$review   = @($findings | Where-Object { $_.severity -eq "review" }).Count

$out = New-Object System.Collections.ArrayList

[void]$out.Add("QUESTPAUSE VALHEIM PROGRESSION TRUST WATCHER")
[void]$out.Add("")
[void]$out.Add("Log: $LogPath")
[void]$out.Add("Scanned tail lines: $TailLines")
[void]$out.Add("Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
[void]$out.Add("")
[void]$out.Add("SUMMARY")
[void]$out.Add("Critical: $critical | Warning: $warning | Review: $review | Players seen: $($players.Count)")
[void]$out.Add("")
[void]$out.Add("IMPORTANT LIMITATION")
[void]$out.Add("This report can detect trust/progression signals from logs, but it cannot yet prove item pickup, crafting, biome entry, or boss kill abuse unless another mod writes those events to the log.")
[void]$out.Add("")
[void]$out.Add("PLAYERS SEEN")
[void]$out.Add("")

foreach ($steamId in ($players.Keys | Sort-Object)) {
  $p = $players[$steamId]
  [void]$out.Add("- $($p.clientName) / $($p.characterName) / Steam_$steamId")
  $rawDisconnectEvents = 0
  if ($p.PSObject.Properties.Name -contains 'rawDisconnectEvents') {
    $rawDisconnectEvents = [int]$p.rawDisconnectEvents
  }

  [void]$out.Add("  Connects: $($p.connects) | Disconnect sessions: $($p.disconnects) | Raw disconnect plugin events: $rawDisconnectEvents | Mod mismatches: $($p.mismatches) | Emergency restores: $($p.emergencyRestores)")
  if ($p.mods.Count -gt 0) {
    $uniqueMods = @($p.mods | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    $keyMods = @($uniqueMods | Where-Object { $_ -match 'AzuAntiCheat|WorldAdvancementProgression|ZenBossStone|Server Characters|TargetPortal|ComfyGizmo' })

    [void]$out.Add("  Mods captured: $($uniqueMods.Count) total")
    if ($keyMods.Count -gt 0) {
      [void]$out.Add("  Key mods: " + ($keyMods -join ", "))
    }
  }
  [void]$out.Add("")
}

[void]$out.Add('')
[void]$out.Add('PLAYER TRUST FLAGS')
$flaggedPlayers = 0

foreach ($steamId in ($players.Keys | Sort-Object)) {
  $p = $players[$steamId]
  $signals = New-Object System.Collections.ArrayList

  if ([int]$p.mismatches -gt 0) {
    [void]$signals.Add("mod mismatch: $($p.mismatches)")
  }

  if ([int]$p.emergencyRestores -gt 0) {
    [void]$signals.Add("emergency restore: $($p.emergencyRestores)")
  }

  if ([int]$p.connects -ge 3 -and [int]$p.disconnects -ge 10) {
    [void]$signals.Add("reconnect loop: $($p.connects) connects / $($p.disconnects) disconnects")
  }

  if ($signals.Count -ge 2) {
    $flaggedPlayers++
    $level = 'REVIEW'

    if ($signals.Count -ge 3) {
      $level = 'ELEVATED REVIEW'
    }

    [void]$out.Add(("- [{0}] {1} / {2} / Steam_{3}" -f $level, $p.clientName, $p.characterName, $steamId))
    [void]$out.Add(("  Signals: " + (($signals | ForEach-Object { [string]$_ }) -join "; ")))
    [void]$out.Add("  Operator note: review context before taking action. This is a trust signal, not proof of abuse.")
  }
}

if ($flaggedPlayers -eq 0) {
  [void]$out.Add('No player currently has multiple trust signals in the scanned log window.')
}

[void]$out.Add("FINDINGS")
[void]$out.Add("")

if ($findings.Count -eq 0) {
  [void]$out.Add("No major findings in this scan window.")
} else {
  foreach ($f in $findings) {
    [void]$out.Add("[$($f.severity.ToUpper())] $($f.category) - $($f.title)")
    [void]$out.Add("Detail: $($f.detail)")
    [void]$out.Add("Evidence: $($f.evidence)")
    [void]$out.Add("")
  }
}

[void]$out.Add("NEXT ACTION")
[void]$out.Add("Use this as watch/report mode only. Do not punish players from this alone. For real progression abuse detection, add a logging source for pickup/craft/boss/biome events or enable verbose logging in the progression mods if available.")

$out | Set-Content -Path $ReportPath -Encoding UTF8

Write-Host ""
Write-Host "Valheim Progression Trust report created:"
Write-Host $ReportPath
Write-Host ""
Get-Content $ReportPath -Tail 120








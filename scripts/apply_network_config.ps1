param(
  [switch]$WhatIf
)

$__qpEnv = $null
foreach ($__qpRel in @('env.ps1', '..\env.ps1', '..\..\env.ps1', '..\..\..\env.ps1')) {
  $__qpTest = Join-Path $PSScriptRoot $__qpRel
  if (Test-Path $__qpTest) { $__qpEnv = $__qpTest; break }
}
if (-not $__qpEnv) { throw "env.ps1 not found from $PSScriptRoot" }
. $__qpEnv
Remove-Variable __qpEnv, __qpRel, __qpTest -ErrorAction SilentlyContinue
$ErrorActionPreference = 'Stop'

$networkPath = Join-Path $script:QPConfigRoot 'server_network.json'
$serversJsonPath = Join-Path $script:QPConfigRoot 'servers.json'

if (-not (Test-Path $networkPath)) { Write-Host "server_network.json not found at $networkPath"; exit 1 }
if (-not (Test-Path $serversJsonPath)) { Write-Host "servers.json not found at $serversJsonPath"; exit 1 }

$netCfg = Get-Content -Raw -Encoding UTF8 $networkPath | ConvertFrom-Json
$svrCfg = Get-Content -Raw -Encoding UTF8 $serversJsonPath | ConvertFrom-Json

$publicIp = if ($netCfg.publicIp) { [string]$netCfg.publicIp } else { Write-Host "publicIp not set in server_network.json"; exit 1 }

$changes = New-Object System.Collections.ArrayList
$errors = New-Object System.Collections.ArrayList

# ── Section 0: Update servers.json with ports from server_network.json ──

$netServers = if ($netCfg.PSObject.Properties['servers']) { $netCfg.servers } else { $null }
if ($netServers) {
  $svrJsonUpdated = $false
  foreach ($svrProp in $netServers.PSObject.Properties) {
    $serverKey = $svrProp.Name
    $netSvr = $svrProp.Value
    $svrEntry = if ($svrCfg.servers.PSObject.Properties[$serverKey]) { $svrCfg.servers.$serverKey } else { $null }
    if (-not $svrEntry) { continue }

    $portFields = @('gamePort', 'queryPort', 'rconPort')
    $svrDirty = $false
    foreach ($field in $portFields) {
      $netVal = if ($netSvr.PSObject.Properties[$field]) { [int]($netSvr.$field) } else { $null }
      if ($null -ne $netVal) {
        $currentVal = if ($svrEntry.PSObject.Properties[$field]) { [int]($svrEntry.$field) } else { $null }
        if ($null -eq $currentVal -or $currentVal -ne $netVal) {
          $svrEntry | Add-Member -NotePropertyName $field -NotePropertyValue $netVal -Force
          $svrDirty = $true
        }
      }
    }
    if ($svrDirty) { $svrJsonUpdated = $true }
  }

  if ($svrJsonUpdated) {
    if ($WhatIf) {
      [void]$changes.Add("servers.json: would update ports from server_network.json")
    } else {
      $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
      $json = $svrCfg | ConvertTo-Json -Depth 16
      [System.IO.File]::WriteAllText($serversJsonPath, $json, $utf8NoBom)
      [void]$changes.Add("servers.json: ports synced from server_network.json")
    }
  } else {
    [void]$changes.Add("servers.json: ports already up to date")
  }
} else {
  [void]$changes.Add("servers.json: no 'servers' section in server_network.json, skipping")
}

# ── Section 1: FastLink YAML files ──

if ($netServers) {
  $fastLinkFound = $false
  foreach ($svrProp in $netServers.PSObject.Properties) {
    $serverKey = $svrProp.Name
    $netSvr = $svrProp.Value
    $flCfg = if ($netSvr.PSObject.Properties['fastLink']) { $netSvr.fastLink } else { $null }
    if (-not $flCfg) { continue }
    $fastLinkFound = $true

    $svrEntry = if ($svrCfg.servers.PSObject.Properties[$serverKey]) { $svrCfg.servers.$serverKey } else { $null }
    $display = if ($svrEntry -and $svrEntry.displayName) { $svrEntry.displayName } else { $serverKey }
    $svrName = if ($flCfg.serverName) { [string]$flCfg.serverName } else { $display }

    # externalPort from server-level config, fallback to gamePort
    $extPort = if ($netSvr.externalPort) { [int]$netSvr.externalPort } `
      elseif ($netSvr.gamePort) { [int]$netSvr.gamePort } `
      elseif ($svrEntry.gamePort) { [int]$svrEntry.gamePort } `
      else { Write-Host "No port for $serverKey FastLink"; continue }

    $password = if ($flCfg.password) { [string]$flCfg.password } else { '' }

    # Find FastLink YAML locations
    $fastLinkPaths = @()
    $possibleRoots = @(
      if ($svrEntry -and $svrEntry.wgsmRoot) { Join-Path $svrEntry.wgsmRoot "servers\$($svrEntry.wgsmServerFolder)" }
      Join-Path $script:QPRoot "servers\$serverKey"
    )
    foreach ($root in $possibleRoots) {
      if (Test-Path $root) {
        $found = Get-ChildItem -LiteralPath $root -Recurse -Filter "*FastLink_servers.yml" -ErrorAction SilentlyContinue
        foreach ($f in $found) { $fastLinkPaths += $f.FullName }
      }
    }

    if ($fastLinkPaths.Count -eq 0) {
      [void]$changes.Add("FastLink: no YAML files found for $serverKey -- skipping")
      continue
    }

    $yamlLines = @(
      "# Configure your servers for Azumatt's FastLink mod in this file.",
      "# Servers are automatically sorted alphabetically when shown in the list.",
      "# This file live updates the in-game listing. Feel free to change it while in the main menu.",
      "",
      "$($svrName):",
      "  address: $publicIp",
      "  port: $extPort"
    )
    if ($password) { $yamlLines += "  password: $password" }
    $yamlContent = ($yamlLines -join "`r`n") + "`r`n"

    foreach ($path in $fastLinkPaths) {
      if ($WhatIf) {
        [void]$changes.Add("FastLink: would update $path (address=$publicIp, port=$extPort)")
      } else {
        try {
          [System.IO.File]::WriteAllText($path, $yamlContent, [System.Text.UTF8Encoding]::new($false))
          [void]$changes.Add(("FastLink: updated ${path} (${publicIp}:${extPort})"))
        } catch {
          $emsg = $_.Exception.Message
          [void]$errors.Add("FastLink: failed to write ${path} -- $emsg")
        }
      }
    }
  }
  if (-not $fastLinkFound) { [void]$changes.Add("FastLink: no servers with fastLink config, skipping") }
} else {
  [void]$changes.Add("FastLink: no 'servers' section in server_network.json, skipping")
}

# ── Section 2: WindowsGSM .cfg files ──

$wgsmEnabled = $netCfg.windowsGSM -and $netCfg.windowsGSM.enabled
if ($wgsmEnabled) {
  $wgsmServers = @($netCfg.windowsGSM.servers)
  foreach ($serverKey in $wgsmServers) {
    $svrEntry = $svrCfg.servers.$serverKey
    if (-not $svrEntry) { [void]$changes.Add("WGSM: $serverKey not found in servers.json, skipping"); continue }

    # Prefer ports from server_network.json, fall back to servers.json
    $netSvr = if ($netServers -and $netServers.PSObject.Properties[$serverKey]) { $netServers.$serverKey } else { $null }
    $gamePort = if ($netSvr -and $netSvr.gamePort) { [int]$netSvr.gamePort } elseif ($svrEntry.gamePort) { [int]$svrEntry.gamePort } else { continue }
    $queryPort = if ($netSvr -and $netSvr.queryPort) { [int]$netSvr.queryPort } elseif ($svrEntry.queryPort) { [int]$svrEntry.queryPort } else { $gamePort }
    $lanIp = if ($netCfg.windowsGSM.lanIp) { [string]$netCfg.windowsGSM.lanIp } else { $null }
    $wgsmRoot = if ($svrEntry.wgsmRoot) { [string]$svrEntry.wgsmRoot } else { continue }
    $wgsmFolder = if ($svrEntry.wgsmServerFolder) { [string]$svrEntry.wgsmServerFolder } else { continue }

    $cfgPath = Join-Path $wgsmRoot "servers\$wgsmFolder\WindowsGSM.cfg"
    if (-not (Test-Path $cfgPath)) {
      $cfgPath = Join-Path $script:QPRoot "servers\$serverKey\configs\WindowsGSM.cfg"
    }
    if (-not (Test-Path $cfgPath)) {
      [void]$changes.Add("WGSM: no .cfg found for $serverKey, skipping")
      continue
    }

    try {
      $cfgContent = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8
      $original = $cfgContent

      if ($lanIp) {
        $cfgContent = $cfgContent -replace '(?m)^(serverip=)"[^"]*"', "`$1`"$lanIp`""
      }
      $cfgContent = $cfgContent -replace '(?m)^(serverport=)"[^"]*"', "`$1`"$gamePort`""
      $cfgContent = $cfgContent -replace '(?m)^(serverqueryport=)"[^"]*"', "`$1`"$queryPort`""

      if ($cfgContent -ne $original) {
        if ($WhatIf) {
          $changesDetail = "WGSM: would update $cfgPath (port=$gamePort, qport=$queryPort)"
          if ($lanIp) { $changesDetail += ", ip=$lanIp" }
          [void]$changes.Add($changesDetail)
        } else {
          [System.IO.File]::WriteAllText($cfgPath, $cfgContent, [System.Text.UTF8Encoding]::new($false))
          [void]$changes.Add("WGSM: updated $cfgPath (port=$gamePort, qport=$queryPort)")
        }
      } else {
        [void]$changes.Add("WGSM: $cfgPath already up to date")
      }
    } catch {
      $emsg = $_.Exception.Message
      [void]$errors.Add("WGSM: failed to update $cfgPath -- $emsg")
    }
  }
} else {
  [void]$changes.Add("WGSM: disabled in server_network.json, skipping")
}

# ── Summary ──

Write-Host "=== Network Config Propagation ===" -ForegroundColor Cyan
if ($WhatIf) { Write-Host "Mode: WHAT-IF (no changes made)" -ForegroundColor Yellow }
Write-Host "Public IP: $publicIp"
Write-Host ""
Write-Host "--- Changes ---"
foreach ($c in $changes) { Write-Host "- $c" }
if ($errors.Count -gt 0) {
  Write-Host ""
  Write-Host "--- Errors ---" -ForegroundColor Red
  foreach ($e in $errors) { Write-Host "- ERROR: $e" -ForegroundColor Red }
}
Write-Host ""
Write-Host "Done. $($changes.Count) action(s), $($errors.Count) error(s)."

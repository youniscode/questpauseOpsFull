# C:\QuestPauseOps\qp.ps1
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('status', 'status-reset', 'status-all', 'list', 'list-actions', 'tame-watch', 'presence')]
    [string]$cmd = 'status',

    [Parameter(Position = 1)]
    [string]$ServerKey,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

. "$PSScriptRoot\scripts\env.ps1"
$opsRoot = $env:QP_OPS_ROOT
if ([string]::IsNullOrWhiteSpace($opsRoot)) { $opsRoot = $script:QPRoot }

Import-Module (Join-Path $opsRoot 'lib\QuestPause.Ops.psm1') -Force -DisableNameChecking

function Get-ServersConfig {
    $cfgPath = Join-Path $opsRoot 'config\servers.json'
    if (-not (Test-Path $cfgPath)) { throw "Config not found: $cfgPath" }

    $raw = Get-Content $cfgPath -Raw
    $cfg = $raw | ConvertFrom-Json
    if (-not $cfg.servers) { throw "Invalid config: missing .servers" }

    return $cfg
}

function Get-LocalNode {
    $n = $env:QP_NODE
    if ([string]::IsNullOrWhiteSpace($n)) { $n = $env:COMPUTERNAME }
    return ([string]$n).Trim()
}

function Get-ServerKeys {
    $cfg = Get-ServersConfig
    $node = Get-LocalNode

    $keys = $cfg.servers.PSObject.Properties.Name

    $filtered = foreach ($k in $keys) {
        $s = $cfg.servers.$k
        $sn = $null
        if ($s -and $s.PSObject.Properties.Name -contains 'node') { $sn = [string]$s.node }
        $sn = if ($sn) { $sn.Trim() } else { "" }

        if ($Force) { $k }
        else {
            if ([string]::IsNullOrWhiteSpace($sn) -or $sn -ieq $node) { $k }
        }
    }

    return $filtered | Sort-Object
}

function Assert-ServerOnThisNode([string]$ServerKey) {
    if ($Force) { return }

    $cfg = Get-ServersConfig
    $node = Get-LocalNode

    if (-not $cfg.servers.$ServerKey) { throw "ServerKey not found in config: $ServerKey" }

    $sn = $null
    if ($cfg.servers.$ServerKey.PSObject.Properties.Name -contains 'node') {
        $sn = [string]$cfg.servers.$ServerKey.node
    }
    $sn = if ($sn) { $sn.Trim() } else { "" }

    if (-not [string]::IsNullOrWhiteSpace($sn) -and ($sn -ine $node)) {
        throw "ServerKey '$ServerKey' is assigned to node '$sn' but you are running on '$node'. Use -Force to override."
    }
}

function Get-StatusScriptPath([string]$ServerKey) {
    $cfg = Get-QPServerConfig $ServerKey
    $product = ([string]$cfg.product).ToLowerInvariant().Trim()
    $world = ""
    if ($cfg.PSObject.Properties.Name -contains 'world' -and $cfg.world) {
        $world = ([string]$cfg.world).ToLowerInvariant().Trim()
    }

    switch ($product) {
        'icarus' {
            if ($world -in @('', 'combined')) { throw "No status script mapped for ICARUS combined (uplink). Use individual map keys (e.g. icarus_olympus)." }
            $scriptName = "icarus_server_status_${world}.ps1"
            $scriptPath = Join-Path $opsRoot "scripts\status\$scriptName"
            if (-not (Test-Path $scriptPath)) { throw "ICARUS status script not found: $scriptPath (world=$world)" }
            return $scriptPath
        }

        'valheim' {
            switch ($world) {
                'pro' { return Join-Path $opsRoot 'scripts\status\valheim_live_pro_status.ps1' }
                'vanilla' { throw "Valheim vanilla status script not yet implemented" }
                default { return Join-Path $opsRoot 'scripts\status\valheim_live_status.ps1' }
            }
        }

        'pz' { return Join-Path $opsRoot 'scripts\status\pz_live_status.ps1' }
        '7dtd' { return Join-Path $opsRoot 'scripts\status\7dtd_live_status.ps1' }
        'windrose' { return Join-Path $opsRoot 'scripts\status\windrose_server_status.ps1' }
        'minecraft' { return Join-Path $opsRoot 'scripts\status\minecraft_server_status.ps1' }
        default { throw "No status script mapped for product='$product' (ServerKey=$ServerKey)" }
    }
}

function Get-TameWatcherScriptPath([string]$ServerKey) {
    $cfg = Get-QPServerConfig $ServerKey
    $product = ([string]$cfg.product).ToLowerInvariant().Trim()

    switch ($product) {
        'icarus' { return Join-Path $opsRoot 'scripts\uplink\icarus_tame_watcher_allmaps.ps1' }
        default { return $null }
    }
}

function Get-PresenceScriptPath([string]$ServerKey) {
    $cfg = Get-QPServerConfig $ServerKey
    $product = ([string]$cfg.product).ToLowerInvariant().Trim()
    $world = ""
    if ($cfg.PSObject.Properties.Name -contains 'world' -and $cfg.world) {
        $world = ([string]$cfg.world).ToLowerInvariant().Trim()
    }

    switch ($product) {
        'valheim' {
            switch ($world) {
                'pro' { return Join-Path $opsRoot 'scripts\presence\valheim_pro_currently_on_server.ps1' }
                default { return Join-Path $opsRoot 'scripts\presence\valheim_currently_on_server.ps1' }
            }
        }
        'pz' { return Join-Path $opsRoot 'scripts\presence\pz_currently_on_server.ps1' }
        '7dtd' { return Join-Path $opsRoot 'scripts\presence\7dtd_currently_on_server.ps1' }
        'windrose' { return Join-Path $opsRoot 'scripts\presence\windrose_currently_on_server.ps1' }
        'minecraft' { return Join-Path $opsRoot 'scripts\presence\minecraft_currently_on_server.ps1' }
        default { return $null }
    }
}

function Reset-StatusState([string]$ServerKey) {
    $stateDir = Join-Path (Join-Path $opsRoot 'state') $ServerKey
    $stateFile = Join-Path $stateDir 'status_message.json'

    if (Test-Path $stateFile) {
        Remove-Item $stateFile -Force
        Write-Host "State reset: deleted $stateFile"
    }
    else {
        Write-Host "State reset: no state file at $stateFile"
    }
}

function List-Actions([string]$ServerKey) {
    if ([string]::IsNullOrWhiteSpace($ServerKey)) { throw "Usage: qp.ps1 list-actions <ServerKey>" }

    $status = $null
    $tames = $null
    $presence = $null

    $cfg = Get-QPServerConfig $ServerKey
    $product = ([string]$cfg.product).ToLowerInvariant().Trim()

    try { $status = Get-StatusScriptPath $ServerKey } catch { $status = $null }

    # Only ICARUS can ever show tame-watch
    if ($product -eq 'icarus') {
        try { $tames = Get-TameWatcherScriptPath $ServerKey } catch { $tames = $null }
    }

    try { $presence = Get-PresenceScriptPath $ServerKey } catch { $presence = $null }

    Write-Host "Node     : $(Get-LocalNode)"
    Write-Host "ServerKey: $ServerKey"
    Write-Host ("status       : {0}" -f $(if ($status) { $status } else { "(not mapped)" }))
    Write-Host ("status-reset  : uses same status script + state reset")

    # Only show tame-watch if mapped (so Valheim doesn't show it)
    if ($tames) {
        Write-Host ("tame-watch    : {0}" -f $tames)
        if (-not (Test-Path $tames)) { Write-Host "tame-watch note: script path is mapped but file does not exist yet." }
    }

    if ($presence) {
        Write-Host ("presence      : {0}" -f $presence)
        if (-not (Test-Path $presence)) { Write-Host "presence note: script path is mapped but file does not exist yet." }
    }
}

switch ($cmd) {

    'list' {
        Write-Host ("Node: {0}" -f (Get-LocalNode))
        Get-ServerKeys
        break
    }

    'list-actions' {
        Assert-ServerOnThisNode $ServerKey
        List-Actions $ServerKey
        break
    }

    'status' {
        if ([string]::IsNullOrWhiteSpace($ServerKey)) { throw "Usage: qp.ps1 status <ServerKey>" }
        Assert-ServerOnThisNode $ServerKey
        $scriptPath = Get-StatusScriptPath $ServerKey
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -ServerKey $ServerKey
        break
    }

    'status-reset' {
        if ([string]::IsNullOrWhiteSpace($ServerKey)) { throw "Usage: qp.ps1 status-reset <ServerKey>" }
        Assert-ServerOnThisNode $ServerKey
        Reset-StatusState $ServerKey
        $scriptPath = Get-StatusScriptPath $ServerKey
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -ServerKey $ServerKey
        break
    }

    'tame-watch' {
        if ([string]::IsNullOrWhiteSpace($ServerKey)) { throw "Usage: qp.ps1 tame-watch <ServerKey>" }
        Assert-ServerOnThisNode $ServerKey
        $scriptPath = Get-TameWatcherScriptPath $ServerKey
        if ([string]::IsNullOrWhiteSpace($scriptPath)) { throw "No tame watcher mapped for ServerKey=$ServerKey" }
        if (-not (Test-Path $scriptPath)) { throw "Tame watcher script not found: $scriptPath" }
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -ServerKey $ServerKey
        break
    }

    'presence' {
        if ([string]::IsNullOrWhiteSpace($ServerKey)) { throw "Usage: qp.ps1 presence <ServerKey>" }
        Assert-ServerOnThisNode $ServerKey

        $cfg = Get-QPServerConfig $ServerKey
        $product = ([string]$cfg.product).ToLowerInvariant().Trim()
        if ($product -notin @('valheim', 'pz', '7dtd', 'windrose', 'minecraft')) {
            throw "presence is only mapped for VALHEIM, PZ, 7DTD, WINDROSE, and MINECRAFT (ServerKey=$ServerKey, product=$product)"
        }

        $scriptPath = Get-PresenceScriptPath $ServerKey
        if ([string]::IsNullOrWhiteSpace($scriptPath)) { throw "No presence watcher mapped for ServerKey=$ServerKey" }
        if (-not (Test-Path $scriptPath)) { throw "Presence script not found: $scriptPath" }

        # Presence script is ServerKey-driven (node-safe, config-driven)
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath `
            -ServerKey $ServerKey

        break
    }

    'status-all' {
        $keys = Get-ServerKeys
        if (-not $keys -or $keys.Count -eq 0) {
            Write-Host "No servers mapped to this node."
            break
        }

        foreach ($k in $keys) {
            try {
                $scriptPath = Get-StatusScriptPath $k
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -ServerKey $k
            }
            catch {
                Write-Host ("[status-all] {0} failed: {1}" -f $k, $_.Exception.Message)
            }
        }
        break
    }
}
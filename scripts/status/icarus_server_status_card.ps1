[CmdletBinding()]
param()

# Bootstrap
$__qpEnv = $null
foreach ($__qpRel in @('..\env.ps1', '..\..\env.ps1', '..\..\..\env.ps1')) {
    $__qpTest = Join-Path $PSScriptRoot $__qpRel
    if (Test-Path $__qpTest) { $__qpEnv = $__qpTest; break }
}
if (-not $__qpEnv) { throw "env.ps1 not found from $PSScriptRoot" }
. $__qpEnv
Remove-Variable __qpEnv, __qpRel, __qpTest -ErrorAction SilentlyContinue

[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
[Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function E([int]$codePoint) { [System.Char]::ConvertFromUtf32($codePoint) }

$E_MAP = E 0x1F5FA
$E_SLOTS = E 0x1F465
$E_UPTIME = E 0x1F552
$E_HOURGLASS = E 0x23F3
$E_ROTATE = E 0x1F501
$E_PROSPECT = E 0x1F9ED
$E_PULSE = E 0x1F4E1
$E_JOIN = E 0x1F6A6
$E_HOST = E 0x1F9E0
$E_STATUS = E 0x1F7E2
$E_A2S = E 0x1F6F0
$E_TOOL = E 0x1F6E0

$opsRoot = $env:QP_OPS_ROOT
if ([string]::IsNullOrWhiteSpace($opsRoot)) { $opsRoot = $script:QPRoot }

$modulePath = Join-Path $opsRoot "lib\QuestPause.Ops.psm1"
Import-Module $modulePath -Force -DisableNameChecking

function Fail([string]$msg) {
    Write-QPLog -ServerKey "icarus_combined" -Message $msg
    throw $msg
}

$cfgPath = Join-Path $opsRoot "config\servers.json"
if (-not (Test-Path $cfgPath)) { Fail "Config not found: $cfgPath" }
$cfg = (Get-Content $cfgPath -Raw) | ConvertFrom-Json

$combined = $cfg.servers.icarus_combined
if (-not $combined) { Fail "servers.json: missing servers.icarus_combined" }

$includeKeys = @()
if ($combined.combined -and $combined.combined.includeServerKeys) {
    $includeKeys = @($combined.combined.includeServerKeys)
}
if ($includeKeys.Count -eq 0) { Fail "icarus_combined.combined.includeServerKeys is empty" }

# Auto-include icarus_elysium if missing
if ($cfg.servers.PSObject.Properties.Name -contains 'icarus_elysium') {
    if (@($includeKeys) -notcontains 'icarus_elysium') { $includeKeys += 'icarus_elysium' }
}

# Use the first individual server's webhook (same webhook the individual scripts used)
$firstKey = $includeKeys[0]
$firstCfg = Get-QPServerConfig $firstKey
$WebhookBase = [string]$firstCfg.webhookUrl
if ([string]::IsNullOrWhiteSpace($WebhookBase)) {
    Fail "Cannot resolve webhookUrl from $firstKey"
}

$ServerTitle = if ($combined.serverTitle) { [string]$combined.serverTitle } else { "QUESTPAUSE ICARUS" }

$stateDir = Get-QPStateDir "icarus_combined"
if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Force -Path $stateDir | Out-Null }
$stateFile = Join-Path $stateDir "status_message.json"

function Get-State {
    if (-not (Test-Path $stateFile)) { return @{} }
    try { return (Get-Content $stateFile -Raw | ConvertFrom-Json -ErrorAction Stop) }
    catch { return @{} }
}
function Save-State([hashtable]$h) {
    $h | ConvertTo-Json -Depth 8 | Set-Content -Path $stateFile -Encoding UTF8
}
function Sanitize-MessageId([string]$id) {
    if ([string]::IsNullOrWhiteSpace($id)) { return $null }
    $clean = ($id -replace '\D', '')
    if ($clean.Length -lt 10) { return $null }
    return $clean
}

function Build-WebhookUrl {
    param(
        [Parameter(Mandatory)] [string]$Base,
        [string]$Path = '',
        [hashtable]$Query = $null
    )
    $u = $Base.Trim()
    $qIndex = $u.IndexOf('?')
    if ($qIndex -gt 0) { $u = $u.Substring(0, $qIndex) }
    $builder = New-Object System.UriBuilder($u)
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $builder.Path = ($builder.Path.TrimEnd('/') + '/' + $Path.TrimStart('/'))
    }
    if ($Query) {
        $pairs = @()
        foreach ($k in $Query.Keys) {
            if ($null -ne $Query[$k] -and "$($Query[$k])" -ne '') {
                $pairs += ("{0}={1}" -f $k, [uri]::EscapeDataString([string]$Query[$k]))
            }
        }
        $builder.Query = ($pairs -join '&')
    }
    return $builder.Uri.AbsoluteUri
}

function Get-DiscordMessageIdFromResponse($resp) {
    if ($null -eq $resp) { return $null }
    try {
        if ($resp.PSObject -and ($resp.PSObject.Properties.Name -contains 'id')) { return [string]$resp.id }
    } catch {}
    try {
        if ($resp.PSObject -and ($resp.PSObject.Properties.Name -contains 'Content') -and $resp.Content) {
            $obj = $resp.Content | ConvertFrom-Json -ErrorAction Stop
            if ($obj -and $obj.id) { return [string]$obj.id }
        }
    } catch {}
    try {
        if ($resp -is [string]) {
            $obj = $resp | ConvertFrom-Json -ErrorAction Stop
            if ($obj -and $obj.id) { return [string]$obj.id }
        }
    } catch {}
    return $null
}

function Discord-CreateMessage([hashtable]$embed) {
    $q = @{ wait = 'true' }
    $url = Build-WebhookUrl -Base $WebhookBase -Query $q
    $payload = @{ content = ""; embeds = @($embed); allowed_mentions = @{ parse = @() } }
    try { return (Send-JsonUtf8 -Method POST -Url $url -Payload $payload) }
    catch { Fail "Discord create failed: $($_.Exception.Message)" }
}

function Discord-PatchMessage([string]$messageId, [hashtable]$embed) {
    $q = @{}
    $url = Build-WebhookUrl -Base $WebhookBase -Path ("messages/$messageId") -Query $q
    $payload = @{ content = ""; embeds = @($embed); allowed_mentions = @{ parse = @() } }
    try {
        Send-JsonUtf8 -Method PATCH -Url $url -Payload $payload | Out-Null
        return $true
    } catch {
        $err = $_.Exception.Message
        try {
            $resp = $_.Exception.Response
            if ($resp -and $resp.StatusCode) {
                $code = [int]$resp.StatusCode
                Write-QPLog -ServerKey "icarus_combined" -Message "PATCH error for messageId=${messageId}: HTTP $code ($err)"
                if ($code -eq 404) { return $false }
                return $true
            }
        } catch {}
        Write-QPLog -ServerKey "icarus_combined" -Message "PATCH error for messageId=${messageId}: $err"
        return $true
    }
}

# Read status_state.json from each included server
$serverStates = @()
foreach ($sk in $includeKeys) {
    $skDir = Get-QPStateDir $sk
    $snapFile = Join-Path $skDir "status_state.json"
    $state = if (Test-Path $snapFile) { try { Get-Content $snapFile -Raw | ConvertFrom-Json -ErrorAction Stop } catch { $null } } else { $null }

    $world = if ($cfg.servers.$sk.world) { [string]$cfg.servers.$sk.world } else { $sk.ToUpper() }
    $maxPlayers = if ($cfg.servers.$sk.maxPlayers) { [int]$cfg.servers.$sk.maxPlayers } else { 0 }

    if ($state) {
        $serverStates += @{
            serverKey     = $sk
            world         = if ($state.world) { [string]$state.world } else { $world }
            isOnline      = [bool]$state.isOnline
            a2sOk         = [bool]$state.a2sOk
            hostRam       = if ($state.hostRam) { [string]$state.hostRam } else { "n/a" }
            rotationState = if ($state.rotationState) { [string]$state.rotationState } else { "" }
            maxPlayers    = $maxPlayers
            hasData       = $true
        }
    } else {
        $serverStates += @{
            serverKey     = $sk
            world         = $world
            isOnline      = $false
            a2sOk         = $false
            hostRam       = "n/a"
            rotationState = ""
            maxPlayers    = $maxPlayers
            hasData       = $false
        }
    }
}

$anyOnline = ($serverStates | Where-Object { $_.isOnline }).Count -gt 0
$hasAnyData = ($serverStates | Where-Object { $_.hasData }).Count -gt 0
$allPaused = $hasAnyData -and ($serverStates | Where-Object { $_.hasData -and $_.rotationState -ne 'paused' }).Count -eq 0 -and -not $anyOnline
$pulse = (Get-Date -Format 'HH:mm dd/MM')

$color = if ($anyOnline) { 0x23D18B } else { 0xF28C28 }

$descLines = if ($allPaused) {
    @(
        "Rotation paused - worlds are saved and not joinable right now.",
        "Saved in rotation. Wait for next active window.",
        "Times in **UTC**."
    )
} elseif ($anyOnline) {
    @(
        "Uplink steady - good window for contracts and base work.",
        "Times in **UTC**."
    )
} else {
    @(
        "Servers are **not joinable** right now.",
        "Times in **UTC**."
    )
}

$pulseLine = "$E_PULSE Pulse $pulse"

$fields = @()
foreach ($ss in $serverStates) {
    $joinIcon = if ($ss.isOnline) { "✅" } else { "⛔" }
    $joinText = if ($ss.isOnline) { "Joinable" } else { "Not joinable" }
    $statusIcon = if ($ss.rotationState -eq 'paused') { "🟠" } elseif ($ss.isOnline) { "🟢" } else { "🔴" }
    $statusText = if ($ss.rotationState -eq 'paused') { "Rotation Paused" } elseif ($ss.isOnline) { "Stable" } else { "Maintenance" }
    $a2sText = if ($ss.a2sOk) { "OK" } else { "FAIL" }

    $fields += @{
        name = "$E_MAP $($ss.world)"
        value = "👥 $($ss.maxPlayers) | $joinIcon $joinText | $statusIcon $statusText | 🛰 A2S: $a2sText"
        inline = $true
    }
}

$hostRam = if ($serverStates.Count -gt 0 -and $serverStates[0].hostRam -ne "n/a") { $serverStates[0].hostRam } else { "n/a" }
$fields += @{ name = "$E_HOST Host"; value = $hostRam; inline = $true }

$embed = @{
    title       = "ICARUS Server Status"
    description = ($descLines -join "`n")
    color       = $color
    fields      = $fields
    footer      = @{ text = "$ServerTitle - $pulseLine" }
}

# Create or patch the combined message
$state = Get-State
$messageId = $null
if ($state -and $state.messageId) {
    $messageId = Sanitize-MessageId ([string]$state.messageId)
}

if ([string]::IsNullOrWhiteSpace($messageId)) {
    Write-QPLog -ServerKey "icarus_combined" -Message "No messageId found. Creating new combined status message..."
    $created = Discord-CreateMessage $embed
    $newId = Get-DiscordMessageIdFromResponse $created
    if ([string]::IsNullOrWhiteSpace($newId)) {
        $t = $(if ($created) { $created.GetType().FullName } else { "null" })
        Write-QPLog -ServerKey "icarus_combined" -Message "Discord create response type: $t"
        try {
            if ($created -and ($created.PSObject.Properties.Name -contains 'StatusCode')) {
                Write-QPLog -ServerKey "icarus_combined" -Message "Discord create HTTP: $($created.StatusCode)"
            }
            if ($created -and ($created.PSObject.Properties.Name -contains 'Content')) {
                Write-QPLog -ServerKey "icarus_combined" -Message "Discord create Content: $($created.Content)"
            }
        } catch {}
        Fail "Discord create did not return message id"
    }
    Save-State @{ messageId = $newId; createdAt = (Get-Date).ToString("o") }
    Write-QPLog -ServerKey "icarus_combined" -Message "Created combined status message id=$newId"
} else {
    $ok = Discord-PatchMessage -messageId $messageId -embed $embed
    if (-not $ok) {
        Write-QPLog -ServerKey "icarus_combined" -Message "PATCH failed (messageId=$messageId). Recreating..."
        $created = Discord-CreateMessage $embed
        $newId = Get-DiscordMessageIdFromResponse $created
        if (-not [string]::IsNullOrWhiteSpace($newId)) {
            Save-State @{ messageId = (Sanitize-MessageId $newId); createdAt = (Get-Date).ToString("o") }
            Write-QPLog -ServerKey "icarus_combined" -Message "Recreated combined status message id=$newId"
        } else { Fail "Recreate failed too (no message id)." }
    } else {
        Write-QPLog -ServerKey "icarus_combined" -Message "Patched combined status message id=$messageId"
    }
}

exit 0

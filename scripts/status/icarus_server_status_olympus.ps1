[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ServerKey
)

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
    Write-QPLog -ServerKey $ServerKey -Message $msg
    throw $msg
}

$cfg = Get-QPServerConfig $ServerKey

$rotationState = if ($cfg.PSObject.Properties.Name -contains 'rotationState') { [string]$cfg.rotationState } else { "" }

$ThreadId = $null
if ($cfg.PSObject.Properties.Name -contains 'discordWebhook' -and $cfg.discordWebhook) {
    if ($cfg.discordWebhook.PSObject.Properties.Name -contains 'threadId') {
        $ThreadId = [string]$cfg.discordWebhook.threadId
    }
}
if ([string]::IsNullOrWhiteSpace($ThreadId) -and ($cfg.PSObject.Properties.Name -contains 'threadId')) {
    $ThreadId = [string]$cfg.threadId
}
if (-not [string]::IsNullOrWhiteSpace($ThreadId)) { $ThreadId = $ThreadId.Trim() }

$WebhookBase = ([string]$cfg.webhookUrl) -replace [char]0xFEFF, '' -replace '[\u0000-\u001F\u007F]', '' -replace '\s+', ''
$WebhookBase = $WebhookBase.Trim()
if ([string]::IsNullOrWhiteSpace($WebhookBase)) { Fail "Config missing webhookUrl for $ServerKey" }

$ServerTitle = if ($cfg.serverTitle) { [string]$cfg.serverTitle }  else { "QUESTPAUSE Server" }
$DisplayName = if ($cfg.displayName) { [string]$cfg.displayName } else { "$ServerKey Server Status" }

$world = if ($cfg.world) { [string]$cfg.world }      else { "" }
$maxPlayers = if ($cfg.maxPlayers) { [int]$cfg.maxPlayers }    else { 0 }

$procPattern = if ($cfg.processNamePattern) { [string]$cfg.processNamePattern } else { "IcarusServer-Win64-Shipping" }

$TargetHost = [string]$cfg.host
$QueryPort = if ($cfg.queryPort) { [int]$cfg.queryPort } else { 0 }
$Must = if ($cfg.a2sMustContain) { [string]$cfg.a2sMustContain } else { "" }

$nextStartFile = if ($cfg.nextStartFile) { [string]$cfg.nextStartFile } else { "" }

$stateDir = Get-QPStateDir $ServerKey
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

function Get-ServerProcess {
    try {
        $cmdMust = ""
        if ($cfg.PSObject.Properties.Name -contains 'processCommandLineMustContain') {
            $cmdMust = [string]$cfg.processCommandLineMustContain
            $cmdMust = $cmdMust -replace '\\\\', '\'
        }

        $filter = "Name LIKE '$($procPattern)%'"
        $procs = Get-CimInstance -ClassName Win32_Process -Filter $filter -ErrorAction SilentlyContinue
        if (-not $procs) { return $null }

        if (-not [string]::IsNullOrWhiteSpace($cmdMust)) {
            $procs = $procs | Where-Object { $_.CommandLine -and $_.CommandLine -like "*$cmdMust*" }
        }

        return ($procs | Select-Object -First 1)
    }
    catch { return $null }
}

function Span([TimeSpan]$ts) {
    if ($ts -lt [TimeSpan]::Zero) { $ts = - $ts }
    $d = if ($ts.Days) { '{0:00}d ' -f $ts.Days } else { '' }
    $h = if ($ts.Hours) { '{0:00}h ' -f $ts.Hours } else { '' }
    $m = '{0:00}m' -f $ts.Minutes
    ($d + $h + $m).Trim()
}

function Get-ProcUptime {
    try {
        $p = Get-ServerProcess
        if (-not $p) { return [TimeSpan]::Zero }

        $start = $null

        try { $start = [System.Management.ManagementDateTimeConverter]::ToDateTime($p.CreationDate) } catch { $start = $null }

        if (-not $start) {
            try { $start = (Get-Process -Id $p.ProcessId -ErrorAction Stop).StartTime } catch { $start = $null }
        }

        if (-not $start) { return [TimeSpan]::Zero }
        return ((Get-Date) - $start)
    }
    catch { return [TimeSpan]::Zero }
}

function TimeUntilMidnightUtc {
    $nowUtc = [DateTime]::UtcNow
    $nextUtcMidnight = [DateTime]::new($nowUtc.Year, $nowUtc.Month, $nowUtc.Day, 0, 0, 0, [DateTimeKind]::Utc).AddDays(1)
    $nextUtcMidnight - $nowUtc
}

function Get-HostRamText {
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $freeGB = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
        $totalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
        $usedGB = [math]::Round($totalGB - $freeGB, 1)
        $pct = if ($totalGB -gt 0) { [math]::Round(($usedGB / $totalGB) * 100, 0) } else { 0 }
        return "$usedGB/$totalGB GB RAM ($pct%)"
    }
    catch { return "n/a" }
}

function Read-NextStart {
    if ([string]::IsNullOrWhiteSpace($nextStartFile)) { return "TBA" }
    try {
        if (-not (Test-Path $nextStartFile)) { return "TBA" }
        $raw = (Get-Content -Path $nextStartFile -Raw -ErrorAction SilentlyContinue).Trim()
        if ([string]::IsNullOrWhiteSpace($raw) -or $raw -match '^(TBA|tba)$') { return "TBA" }
        $dt = [DateTime]::Parse($raw)
        return $dt.ToString('HH:mm dd/MM')
    }
    catch { return "TBA" }
}

function Get-A2SOk {
    if ([string]::IsNullOrWhiteSpace($TargetHost) -or $QueryPort -le 0) { return $false }
    try {
        $mc = $Must
        if ($null -eq $mc) { $mc = "" }
        return [bool](Test-A2SQueryStrict -TargetHost $TargetHost -Port $QueryPort -MustContain $mc -TimeoutMs 1500)
    }
    catch { return $false }
}

function Get-MaintenanceLabel([TimeSpan]$t2c) {
    if ($t2c.TotalMinutes -le 60) { return "$E_HOURGLASS UTC day rollover soon" }
    if ($t2c.TotalHours -le 6) { return "$E_HOURGLASS UTC day rollover window" }
    return "$E_HOURGLASS UTC day rollover"
}

function Build-Embed([hashtable]$snap) {
    $online = [bool]$snap.isOnline
    $rotationState = [string]$snap.rotationState

    if ($rotationState -eq 'paused' -and -not $online) {
        $color = 0xF28C28
        $descLines = @(
            "Rotation paused - this world is saved and not joinable right now.",
            "Saved in rotation. Wait for next active window.",
            "Times in **UTC**."
        )

        $pulse = "$E_PULSE Pulse $($snap.pulse)"

        $fields = @(
            @{ name = "$E_PROSPECT Prospect"; value = $(if ($world) { $world } else { "n/a" }); inline = $true }
            @{ name = "$E_SLOTS Slots"; value = $(if ($maxPlayers -gt 0) { "$maxPlayers" } else { "n/a" }); inline = $true }
            @{ name = "$E_JOIN Joinability"; value = "⛔ Not joinable"; inline = $true }
            @{ name = "$E_UPTIME Uptime"; value = "n/a"; inline = $true }
            @{ name = "$E_HOST Host"; value = $snap.hostRam; inline = $true }
            @{ name = "$E_STATUS Status"; value = "Rotation Paused"; inline = $true }
            @{ name = "$E_A2S A2S"; value = $(if ($snap.a2sOk) { "OK" } else { "FAIL" }); inline = $true }
        )

        return @{
            title       = $DisplayName
            description = ($descLines -join "`n")
            color       = $color
            fields      = $fields
            footer      = @{ text = "$ServerTitle - $pulse" }
        }
    }

    $color = if ($online) { 0x23D18B } else { 0xF28C28 }

    $rotLine = if ($online) { "$E_ROTATE Rotation uplink synced." } else { "" }
    $dirLine = if ($online) {
        "Directive: **Deploy / Extract freely** world persists."
    }
    else {
        "Directive: **Stand by** uplink will return when ready."
    }

    $descLines = @()
    if ($online) {
        $descLines += "Uplink steady - good window for contracts and base work."
        if ($rotLine) { $descLines += $rotLine }
        $descLines += $dirLine
        $descLines += "Times in **UTC**."
    }
    else {
        $descLines += "Maintenance active, server is **not joinable** right now."
        $descLines += $dirLine
        $descLines += "Times in **UTC**."
    }

    $pulse = "$E_PULSE Pulse $($snap.pulse)"
    $maintLabel = Get-MaintenanceLabel $snap.t2c

    $fields = @(
        @{ name = "$E_PROSPECT Prospect"; value = $(if ($world) { $world } else { "n/a" }); inline = $true }
        @{ name = "$E_SLOTS Slots"; value = $(if ($maxPlayers -gt 0) { "$maxPlayers" } else { "n/a" }); inline = $true }
        @{ name = "$E_JOIN Joinability"; value = $(if ($online) { "✅ Joinable" } else { "⛔ Not joinable" }); inline = $true }

        @{ name = "$E_UPTIME Uptime"; value = $(if ($online) { (Span $snap.uptime) } else { "n/a" }); inline = $true }
        @{ name = $maintLabel; value = (Span $snap.t2c); inline = $true }
        @{ name = "$E_HOST Host"; value = $snap.hostRam; inline = $true }

        @{ name = "$E_STATUS Status"; value = $(if ($online) { "Stable" } else { "Maintenance" }); inline = $true }
        @{ name = "$E_A2S A2S"; value = $(if ($snap.a2sOk) { "OK" } else { "FAIL" }); inline = $true }
    )

    if (-not $online) {
        $fields += @{ name = "$E_TOOL Next Start"; value = $snap.nextStart; inline = $true }
    }

    return @{
        title       = $DisplayName
        description = ($descLines -join "`n")
        color       = $color
        fields      = $fields
        footer      = @{ text = "$ServerTitle - $pulse" }
    }
}

function Get-DiscordMessageIdFromResponse($resp) {
    if ($null -eq $resp) { return $null }

    try {
        if ($resp.PSObject -and ($resp.PSObject.Properties.Name -contains 'id')) {
            return [string]$resp.id
        }
    }
    catch {}

    try {
        if ($resp.PSObject -and ($resp.PSObject.Properties.Name -contains 'Content') -and $resp.Content) {
            $obj = $resp.Content | ConvertFrom-Json -ErrorAction Stop
            if ($obj -and $obj.id) { return [string]$obj.id }
        }
    }
    catch {}

    try {
        if ($resp -is [string]) {
            $obj = $resp | ConvertFrom-Json -ErrorAction Stop
            if ($obj -and $obj.id) { return [string]$obj.id }
        }
    }
    catch {}

    return $null
}

function Discord-CreateMessage([hashtable]$embed) {
    $q = @{ wait = 'true' }
    if ($ThreadId) { $q.thread_id = $ThreadId }

    $url = Build-WebhookUrl -Base $WebhookBase -Query $q
    $payload = @{ content = ""; embeds = @($embed); allowed_mentions = @{ parse = @() } }

    try { return (Send-JsonUtf8 -Method POST -Url $url -Payload $payload) }
    catch { Fail ("Discord create failed: {0}" -f $_.Exception.Message) }
}

function Discord-PatchMessage([string]$messageId, [hashtable]$embed) {
    $q = @{}
    if ($ThreadId) { $q.thread_id = $ThreadId }

    $url = Build-WebhookUrl -Base $WebhookBase -Path ("messages/$messageId") -Query $q
    $payload = @{ content = ""; embeds = @($embed); allowed_mentions = @{ parse = @() } }

    try {
        Send-JsonUtf8 -Method PATCH -Url $url -Payload $payload | Out-Null
        return $true
    }
    catch {
        $err = $_.Exception.Message
        try {
            $resp = $_.Exception.Response
            if ($resp -and $resp.StatusCode) {
                $code = [int]$resp.StatusCode
                Write-QPLog -ServerKey $ServerKey -Message ("PATCH error for messageId=${messageId}: HTTP $code ($err)")
                if ($code -eq 404) { return $false }
                return $true
            }
        }
        catch {}
        Write-QPLog -ServerKey $ServerKey -Message ("PATCH error for messageId=${messageId}: $err")
        return $true
    }
}

$a2sOk = Get-A2SOk

$procOk = $false

try {
    $pidFile = $null

    if ($cfg.PSObject.Properties.Name -contains 'ops' -and $cfg.ops) {
        if ($cfg.ops.PSObject.Properties.Name -contains 'pidFile' -and $cfg.ops.pidFile) {
            $pidFile = [string]$cfg.ops.pidFile
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($pidFile) -and (Test-Path $pidFile)) {
        $serverPidText = (Get-Content $pidFile -Raw -ErrorAction SilentlyContinue).Trim()
        if ($serverPidText -match '^\d+$') {
            $p = Get-Process -Id ([int]$serverPidText) -ErrorAction SilentlyContinue
            if ($p) { $procOk = $true }
        }
    }

    if (-not $procOk) {
        $procOk = [bool](Get-ServerProcess)
    }
}
catch {
    $procOk = $false
}

$isOnline = ($a2sOk -or $procOk)
$maintOn = -not $isOnline

$uptime = Get-ProcUptime
$hostRam = Get-HostRamText
$nextStart = Read-NextStart
$t2c = TimeUntilMidnightUtc
$pulse = (Get-Date -Format 'HH:mm dd/MM')

$snap = @{
    isOnline      = $isOnline
    a2sOk         = $a2sOk
    uptime        = $uptime
    hostRam       = $hostRam
    nextStart     = $nextStart
    t2c           = $t2c
    pulse         = $pulse
    rotationState = $rotationState
}

$embed = Build-Embed $snap

try {
    $stateDir2 = Get-QPStateDir $ServerKey
    $snapFile = Join-Path $stateDir2 "status_state.json"
    $snapOut = @{
        serverKey     = $ServerKey
        world         = $world
        isOnline      = [bool]$snap.isOnline
        a2sOk         = [bool]$snap.a2sOk
        pulse         = [string]$snap.pulse
        hostRam       = [string]$snap.hostRam
        rotationState = $rotationState
        updatedAt     = (Get-Date).ToString("o")
    }
    $snapOut | ConvertTo-Json -Depth 6 | Set-Content -Path $snapFile -Encoding UTF8
}
catch {}

$skipDiscord = ([string]$env:QP_SKIP_DISCORD) -eq "true"
if ($skipDiscord) {
    Write-QPLog -ServerKey $ServerKey -Message "QP_SKIP_DISCORD=true, skipping Discord message"
    exit 0
}

$state = Get-State
$messageId = $null
if ($state -and $state.messageId) {
    $messageId = Sanitize-MessageId ([string]$state.messageId)
}

if ([string]::IsNullOrWhiteSpace($messageId)) {
    Write-QPLog -ServerKey $ServerKey -Message "No messageId found. Creating new status message..."
    $created = Discord-CreateMessage $embed
    $newId = Get-DiscordMessageIdFromResponse $created

    if ([string]::IsNullOrWhiteSpace($newId)) {
        $t = $(if ($created) { $created.GetType().FullName } else { "null" })
        Write-QPLog -ServerKey $ServerKey -Message ("Discord create response type: {0}" -f $t)

        try {
            if ($created -and ($created.PSObject.Properties.Name -contains 'StatusCode')) {
                Write-QPLog -ServerKey $ServerKey -Message ("Discord create HTTP: {0}" -f $created.StatusCode)
            }
            if ($created -and ($created.PSObject.Properties.Name -contains 'Content')) {
                Write-QPLog -ServerKey $ServerKey -Message ("Discord create Content: {0}" -f $created.Content)
            }
        }
        catch {}

        Fail "Discord create did not return message id (response was not Discord JSON)."
    }

    Save-State @{ messageId = $newId; createdAt = (Get-Date).ToString("o") }
    Write-QPLog -ServerKey $ServerKey -Message ("Created status message id={0}" -f $newId)
}
else {
    $ok = Discord-PatchMessage -messageId $messageId -embed $embed
    if (-not $ok) {
        Write-QPLog -ServerKey $ServerKey -Message "PATCH failed (messageId=$messageId). Recreating message..."
        $created = Discord-CreateMessage $embed
        $newId = Get-DiscordMessageIdFromResponse $created

        if (-not [string]::IsNullOrWhiteSpace($newId)) {
            Save-State @{ messageId = (Sanitize-MessageId $newId); createdAt = (Get-Date).ToString("o") }
            Write-QPLog -ServerKey $ServerKey -Message ("Recreated status message id={0}" -f $newId)
        }
        else {
            $t = $(if ($created) { $created.GetType().FullName } else { "null" })
            Write-QPLog -ServerKey $ServerKey -Message ("Recreate response type: {0}" -f $t)
            try {
                if ($created -and ($created.PSObject.Properties.Name -contains 'Content')) {
                    Write-QPLog -ServerKey $ServerKey -Message ("Recreate Content: {0}" -f $created.Content)
                }
            }
            catch {}
            Fail "Recreate failed too (no message id)."
        }
    }
    else {
        Write-QPLog -ServerKey $ServerKey -Message ("Patched status message id={0} ({1})" -f $messageId, $(if ($isOnline) { "ONLINE" } else { "OFFLINE" }))
    }
}
exit 0

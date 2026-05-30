[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ServerKey,

    [switch]$RunOnce,
    [int]$PollSeconds = 5,
    [int]$PulseMinutes = 1,
    [int]$A2STimeoutMs = 1500,
    [int]$RosterRefreshSeconds = 30
)

# Bootstrap: resolve QuestPauseOps root paths from env.ps1
$__qpEnv = $null
foreach ($__qpRel in @('..\env.ps1', '..\..\env.ps1', '..\..\..\env.ps1')) {
    $__qpTest = Join-Path $PSScriptRoot $__qpRel
    if (Test-Path $__qpTest) { $__qpEnv = $__qpTest; break }
}
if (-not $__qpEnv) { throw "env.ps1 not found from $PSScriptRoot" }
. $__qpEnv
Remove-Variable __qpEnv, __qpRel, __qpTest -ErrorAction SilentlyContinue

<#
    C:\QuestPauseOps\scripts\presence\presence_main.ps1
    QUESTPAUSEOPS — Universal Presence Engine

    A unified, scalable engine to handle player presence for multiple game types.
    Usage: .\presence_main.ps1 -ServerKey "valheim_main"
#>

# =========================
# GLOBAL SETUP
# =========================
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$PSDefaultParameterValues['*:Encoding'] = 'utf8'
$ErrorActionPreference = 'Stop'

$OpsRoot    = $script:QPRoot
$ConfigPath = Join-Path $OpsRoot 'config\servers.json'
$LogsDir    = Join-Path $OpsRoot 'logs\presence'
$StateRoot  = Join-Path $OpsRoot 'state'

# =========================
# PROVIDER DEFINITIONS
# =========================
$Providers = @{
    'valheim' = @{
        DisplayName = "Valheim"
        Icon        = "$([char]0x2694)$([char]0xFE0F)"
        Color       = 0x2ECC71
        UseA2S      = $true
        LogFilter   = "*.log"
        JoinRegex   = 'Got handshake from client\s+(?<id>\d{16,20})'
        LeaveRegex  = 'Closing socket\s+(?<id>\d{16,20})|Peer\s*\((?<id>\d{16,20})\)\s*disconnected'
        Tips        = @("Rested buff is key.", "Repair gear often.", "Keep 10 resin.")
    }
    '7dtd' = @{
        DisplayName = "7 Days to Die"
        Icon        = "$([char]0xD83E)$([char]0xDDDF)"
        Color       = 0xE67E22
        UseA2S      = $true
        LogFilter   = "output_log_dedi__*.txt"
        JoinRegex   = "GMSG:\s*Player\s*'(?<name>[^']+)'\s*joined"
        LeaveRegex  = "GMSG:\s*Player\s*'(?<name>[^']+)'\s*left"
        Tips        = @("Night is for prep.", "Repair kits save runs.", "Always have a fallback.")
    }
    'pz' = @{
        DisplayName = "Project Zomboid"
        Icon        = "$([char]0xD83D)$([char]0xDC80)"
        Color       = 0x95A5A6
        UseA2S      = $false
        LogFilter   = "DebugLog-server.txt"
        JoinRegex   = 'fully-connected\].*steam-id=(?<id>\d+).*username="(?<name>[^"]+)"'
        LeaveRegex  = 'disconnection-notification".*steam-id=(?<id>\d+)'
        Tips        = @("Don't be greedy.", "Exhaustion kills.", "Cars are escape tools.")
    }
    'windrose' = @{
        DisplayName = "Windrose"
        Icon        = "$([char]0x26F5)"
        Color       = 0x3498DB
        UseA2S      = $false
        LogFilter   = "*.log"
        Tips        = @("Repair ship often.", "Supplies matter.", "A prepared retreat.")
    }
}

$MappingPath = Join-Path $OpsRoot 'scripts\presence\player_mapping.json'

# =========================
# INFRASTRUCTURE FUNCTIONS
# =========================

function Get-DiscordName {
    param([string]$Id, [string]$Fallback)
    if (Test-Path $MappingPath) {
        try {
            $mapping = Get-Content $MappingPath -Raw | ConvertFrom-Json
            if ($mapping.PSObject.Properties[$Id]) { return $mapping.$Id }
        } catch { }
    }
    return $Fallback
}

function Write-OpsLog([string]$Msg, [string]$Level = "INFO") {
    if (-not (Test-Path $LogsDir)) { New-Item -ItemType Directory -Path $LogsDir -Force | Out-Null }
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $logLine = "[$ts] [$Level] [$ServerKey] $Msg"
    $cc = switch($Level) { "ERROR" { "Red" } "WARN" { "Yellow" } default { "Gray" } }
    Write-Host $logLine -ForegroundColor $cc
    $engineLog = Join-Path $LogsDir "presence_engine.log"
    $logLine | Add-Content -Path $engineLog -Encoding UTF8
}

function Load-State {
    if (Test-Path $StateFile) {
        try { 
            $s = Get-Content $StateFile -Raw | ConvertFrom-Json 
            $roster = @{}
            if ($s.roster) {
                foreach ($prop in $s.roster.PSObject.Properties) {
                    $roster[$prop.Name] = $prop.Value
                }
            }
            $s.roster = $roster
            return $s
        } catch { }
    }
    return [pscustomobject]@{
        roster = @{}
        online_since_utc = $null
        last_event_text = "Watcher started"
        last_event_utc = (Get-Date).ToUniversalTime().ToString('o')
        cursor_pos = 0
        cursor_path = $null
    }
}

function Save-State($s) {
    ($s | ConvertTo-Json -Depth 10) | Set-Content -Path $StateFile -Encoding UTF8
}

function New-UdpClient([int]$timeoutMs) {
    $c = New-Object System.Net.Sockets.UdpClient
    $c.Client.ReceiveTimeout = [Math]::Max(200, $timeoutMs)
    $c.Client.SendTimeout    = [Math]::Max(200, $timeoutMs)
    return $c
}

function Get-A2SPlayers {
    param([string]$TargetHost, [int]$Port, [int]$TimeoutMs)
    $client = $null
    try {
        $client = New-UdpClient -timeoutMs $TimeoutMs
        $client.Connect($TargetHost, $Port)
        $hdr = [byte[]](0xFF,0xFF,0xFF,0xFF)
        $req1 = $hdr + [byte[]](0x55,0xFF,0xFF,0xFF,0xFF)
        [void]$client.Send($req1, $req1.Length)
        $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any,0)
        $resp1 = $client.Receive([ref]$remote)
        if ($resp1[4] -ne 0x41) { return $null }
        $req2 = $hdr + [byte[]](0x55) + $resp1[5..8]
        [void]$client.Send($req2, $req2.Length)
        $resp2 = $client.Receive([ref]$remote)
        if ($resp2[4] -ne 0x44) { return $null }
        $idx = 5
        $count = [int]$resp2[$idx]; $idx++
        $names = @()
        for ($i=0; $i -lt $count; $i++) {
            $idx++
            $start = $idx
            while ($idx -lt $resp2.Length -and $resp2[$idx] -ne 0) { $idx++ }
            $names += [System.Text.Encoding]::UTF8.GetString($resp2, $start, $idx - $start)
            $idx += 9
        }
        return @($names | Where-Object { $_.Trim() -ne '' })
    } catch { return $null }
    finally { if ($client) { $client.Close() } }
}

function Invoke-PresenceWebhook {
    param([string]$Method, [Uri]$Uri, [hashtable]$Payload, [string]$IdFile)
    $json = $Payload | ConvertTo-Json -Depth 16
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    try {
        $r = Invoke-DiscordApiWithRetry -Method $Method -Uri $Uri -Body $bytes -ContentType 'application/json; charset=utf-8'
        if ($Method -eq 'POST' -and $r -and $r.id) { Set-Content -Path $IdFile -Value $r.id -Encoding UTF8 }
        return $r
    } catch {
        $statusCode = 0
        if ($_.Exception.Response) { $statusCode = [int]$_.Exception.Response.StatusCode }
        elseif ($_.Exception.InnerException -and $_.Exception.InnerException.Response) { $statusCode = [int]$_.Exception.InnerException.Response.StatusCode }
        if ($statusCode -eq 404 -and $Method -eq 'PATCH') {
            Write-OpsLog "Discord message 404'd." "WARN"
            if (Test-Path $IdFile) { Remove-Item $IdFile -Force }
            return $null
        }
        throw $_
    }
}

function Get-WebhookUri {
    param([string]$Url)
    $ub = [System.UriBuilder]::new($Url)
    $ub.Query = "wait=true"
    return $ub.Uri
}

function Get-LatestLogFile {
    param([string]$Dir, [string]$Filter)
    if (-not [string]::IsNullOrWhiteSpace($Dir) -and (Test-Path $Dir)) {
        return Get-ChildItem -Path $Dir -Filter $Filter | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    return $null
}

function Format-Duration([TimeSpan]$ts) {
    if ($ts.TotalSeconds -lt 0) { return '0m' }
    if ($ts.TotalHours -ge 24)  { return "{0}d {1}h" -f [int]$ts.TotalDays, $ts.Hours }
    if ($ts.TotalHours -ge 1)   { return "{0}h {1}m" -f [int]$ts.TotalHours, $ts.Minutes }
    return "{0}m" -f [int]$ts.TotalMinutes
}

function Build-Payload {
    param($State, $Provider, $Server)
    $onlineCount = 0
    if ($State.roster) { $onlineCount = ($State.roster.Keys).Count }
    
    $maxPlayers = 30
    if ($Server.maxPlayers) { $maxPlayers = $Server.maxPlayers }
    
    $statusEmoji = "Quiet"
    if ($onlineCount -gt 0) { $statusEmoji = "Online" }
    
    $color = 0x95A5A6
    if ($onlineCount -gt 0) { $color = $Provider.Color }
    
    $rosterLines = "No activity detected."
    if ($onlineCount -gt 0) { 
        $lines = @()
        foreach ($id in ($State.roster.Keys | Sort-Object { $State.roster[$_] })) {
            $name = $State.roster[$id]
            $dName = Get-DiscordName -Id $id -Fallback ""
            if ($dName) { $lines += "o **$name** (@$dName)" }
            else { $lines += "o $name" }
        }
        $rosterLines = $lines -join "`n"
    }
    
    $uptime = "No activity"
    if ($onlineCount -gt 0 -and $State.online_since_utc) { $uptime = Format-Duration ((Get-Date).ToUniversalTime() - ([DateTime]$State.online_since_utc)) }
    
    $pulseUtc = (Get-Date).ToUniversalTime().ToString('HH:mm')
    
    $tip = "Stay safe."
    if ($Provider.Tips) { $tip = $Provider.Tips | Get-Random }

    $wName = "QuestPause Realm"
    if ($Server.worldName) { $wName = $Server.worldName }
    
    $fields = New-Object System.Collections.ArrayList
    [void]$fields.Add(@{ name = "World"; value = $wName; inline = $false })
    [void]$fields.Add(@{ name = "Uptime"; value = $uptime; inline = $true })
    [void]$fields.Add(@{ name = "Roster"; value = $rosterLines; inline = $false })
    [void]$fields.Add(@{ name = "Last Event"; value = $State.last_event_text; inline = $false })
    [void]$fields.Add(@{ name = "Field Tip"; value = $tip; inline = $false })

    $embed = [ordered]@{
        title       = "$($Provider.Icon) $($Provider.DisplayName) Presence"
        color       = $color
        description = "**$statusEmoji Online: $onlineCount/$maxPlayers**"
        fields      = $fields
        footer    = @{ text = "QUESTPAUSE • $ServerKey • Pulse $pulseUtc UTC" }
        timestamp = (Get-Date).ToUniversalTime().ToString('o')
    }

    return [ordered]@{
        embeds = @($embed)
    }
}

function Update-Roster {
    param($State, $Line, $Provider)
    $changed = $false
    $now = (Get-Date).ToUniversalTime().ToString('o')
    if ($Line -match $Provider.JoinRegex) {
        $id = $Matches.id
        if (-not $id) { $id = $Matches.name }
        
        $name = $Matches.name
        if (-not $name) { $name = "Viking" }
        
        if (-not $State.roster.ContainsKey($id)) {
            $State.roster[$id] = $name
            $dName = Get-DiscordName -Id $id -Fallback ""
            $evtName = if ($dName) { "$name (@$dName)" } else { $name }
            $State.last_event_text = "JOIN: $evtName"
            $State.last_event_utc  = $now
            if ($State.roster.Count -eq 1) { $State.online_since_utc = $now }
            $changed = $true
        }
    }
    elseif ($Line -match $Provider.LeaveRegex) {
        $id = $Matches.id
        if (-not $id) { $id = $Matches.name }
        
        if ($State.roster.ContainsKey($id)) {
            $name = $State.roster[$id]
            $dName = Get-DiscordName -Id $id -Fallback ""
            $evtName = if ($dName) { "$name (@$dName)" } else { $name }
            $State.roster.Remove($id)
            $State.last_event_text = "LEAVE: $evtName"
            $State.last_event_utc  = $now
            if ($State.roster.Count -eq 0) { $State.online_since_utc = $null }
            $changed = $true
        }
    }
    return $changed
}

# =========================
# MAIN LOOP
# =========================

try {
    Write-OpsLog "Initializing..."
    $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    $server = $cfg.servers.$ServerKey
    $product = $server.product
    $provider = $Providers[$product]
    $StateDir = Join-Path $StateRoot $ServerKey
    if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
    $IdFile = Join-Path $StateDir "message_id.txt"; $StateFile = Join-Path $StateDir "engine_state.json"
    
    $webhookUrl = ""
    if ($server.webhooks.presence) { $webhookUrl = $server.webhooks.presence }
    else { $webhookUrl = $server.webhookUrl }
    
    $WebhookUri = Get-WebhookUri -Url $webhookUrl
    $script:state = Load-State
    $lastPulse = [DateTime]::MinValue; $lastA2S = [DateTime]::MinValue
    
    $logDir = ""
    if ($server.logDir) { $logDir = $server.logDir }
    elseif ($server.valheim.logPath) { $logDir = Split-Path $server.valheim.logPath }
    
    $logPath = ""
    if (-not $logDir -and $server.valheim.logPath) { $logPath = $server.valheim.logPath }
    else { $logPath = Get-LatestLogFile -Dir $logDir -Filter $provider.LogFilter }
    
    $windroseBlock = @{ inBlock = $false; lines = @() }

    while ($true) {
        $changed = $false; $now = Get-Date
        [DateTime]::UtcNow.ToString('o') | Set-Content (Join-Path $StateRoot "$ServerKey\presence_heartbeat.txt") -Encoding UTF8
        if ($logPath -and (Test-Path $logPath)) {
            try {
                $fs = [System.IO.File]::Open($logPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                if ($fs.Length -lt $script:state.cursor_pos -or $logPath -ne $script:state.cursor_path) { $script:state.cursor_pos = 0; $script:state.cursor_path = $logPath; $windroseBlock.inBlock = $false }
                $fs.Seek($script:state.cursor_pos, [System.IO.SeekOrigin]::Begin) | Out-Null
                $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
                while (-not $sr.EndOfStream) {
                    $line = $sr.ReadLine()
                    if ($product -eq 'windrose') {
                        if ($line -match '^\s*Connected Accounts\s*$') { $windroseBlock.inBlock = $true; $windroseBlock.lines = @(); continue }
                        if ($windroseBlock.inBlock) {
                            if ($line -match '^\[\d{4}\.\d{2}\.\d{2}-\d{2}\.\d{2}\.\d{2}:\d{3}\]') {
                                $windroseBlock.inBlock = $false; $newRoster = @{}
                                foreach ($bLine in $windroseBlock.lines) { 
                                    if ($bLine -match "Name\s+'(?<name>[^']+)'.*State\s+'(?<state>WaitingForClientIsReady|ReadyToPlay|UeLoggedIn|UePreloginVerified|BLConnected|Connected)'.*NetAddress\s+'R5:(?<sid>[A-Fa-f0-9]{16,})'") { $newRoster[$Matches.sid] = $Matches.name.Trim() } 
                                }
                                $oldKeys = ($script:state.roster.Keys | Sort-Object) -join ','
                                $newKeys = ($newRoster.Keys | Sort-Object) -join ','
                                if ($oldKeys -ne $newKeys) { 
                                    $script:state.roster = $newRoster
                                    $script:state.last_event_text = "SYNC Snapshot"
                                    if ($newRoster.Count -gt 0) { $script:state.online_since_utc = $now.ToUniversalTime().ToString('o') }
                                    else { $script:state.online_since_utc = $null }
                                    $changed = $true 
                                }
                            } else { $windroseBlock.lines += $line; continue }
                        }
                    }
                    if (Update-Roster -State $script:state -Line $line -Provider $provider) { $changed = $true }
                }
                $script:state.cursor_pos = $fs.Position; $sr.Close(); $fs.Close()
            } catch { Write-OpsLog "Log error: $($_.Exception.Message)" "WARN" }
        }
        if ($provider.UseA2S -and ($now - $lastA2S).TotalSeconds -ge $RosterRefreshSeconds) {
            $lastA2S = $now
            $thost = "127.0.0.1"
            if ($server.host) { $thost = $server.host }
            $port = 0
            if ($server.queryPort) { $port = $server.queryPort }
            elseif ($server.gamePort) { $port = $server.gamePort }
            
            if ($port) { 
                $actual = Get-A2SPlayers -TargetHost $thost -Port $port -TimeoutMs $A2STimeoutMs
                if ($null -ne $actual -and $actual.Count -eq 0 -and ($script:state.roster.Keys).Count -gt 0) { 
                    $script:state.roster = @{}
                    $script:state.last_event_text = "SYNC (A2S 0)"
                    $script:state.online_since_utc = $null
                    $changed = $true 
                } 
            }
        }
        if ($changed -or ($now - $lastPulse).TotalMinutes -ge $PulseMinutes) {
            $lastPulse = $now
            $payload = Build-Payload -State $script:state -Provider $provider -Server $server
            $msgId = ""
            if (Test-Path $IdFile) { $msgId = Get-Content $IdFile -Raw }
            if ($msgId) { 
                $editUrl = $WebhookUri.AbsoluteUri.TrimEnd('/') + "/messages/" + $msgId
                $res = Invoke-PresenceWebhook -Method 'PATCH' -Uri $editUrl -Payload $payload -IdFile $IdFile
                if ($null -eq $res) { Invoke-PresenceWebhook -Method 'POST' -Uri $WebhookUri -Payload $payload -IdFile $IdFile | Out-Null } 
            }
            else { Invoke-PresenceWebhook -Method 'POST' -Uri $WebhookUri -Payload $payload -IdFile $IdFile | Out-Null }
            Save-State $script:state
        }
        if ($RunOnce) { break }; Start-Sleep -Seconds $PollSeconds
        $newLog = Get-LatestLogFile -Dir $logDir -Filter $provider.LogFilter
        if ($newLog -and $newLog -ne $logPath) { $logPath = $newLog }
    }
} catch { Write-OpsLog "FATAL: $($_.Exception.Message)" "ERROR"; exit 1 }

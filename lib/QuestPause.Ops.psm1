# C:\QuestPauseOps\lib\QuestPause.Ops.psm1
Set-StrictMode -Version Latest

function Get-QPOpsRoot {
    $root = $env:QP_OPS_ROOT
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = $PSScriptRoot
        while ($root -and -not (Test-Path (Join-Path $root 'config\servers.json'))) {
            $root = Split-Path $root -Parent
        }
        if (-not $root) { throw "Cannot resolve QuestPauseOps root from module path" }
    }
    return $root
}

function Get-QPConfigPath {
    $root = Get-QPOpsRoot
    return Join-Path $root "config\servers.json"
}

function Get-QPStateDir([string]$ServerKey) {
    $root = Get-QPOpsRoot
    $dir = Join-Path $root ("state\{0}" -f $ServerKey)
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    return $dir
}

function Get-QPLogDir {
    $root = Get-QPOpsRoot
    $dir = Join-Path $root "logs"
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    return $dir
}

function Write-QPLog {
    param(
        [string]$ServerKey,
        [string]$Message
    )
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[{0}] [{1}] {2}" -f $ts, $ServerKey, $Message
    Write-Host $line

    $logDir = Get-QPLogDir
    $logFile = Join-Path $logDir ("{0}.log" -f $ServerKey)
    $line | Out-File -FilePath $logFile -Append -Encoding utf8
}

# --- HARD NORMALIZER (fixes hidden unicode whitespace / ZWSP / NBSP) ---
function Normalize-QPString([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }

    # remove BOM + control chars first
    $t = [string]$s
    $t = $t -replace [char]0xFEFF, ''                 # BOM
    $t = $t -replace '[\u0000-\u001F\u007F]', ''      # ASCII controls

    # remove common invisible unicode troublemakers
    $t = $t -replace '[\u200B\u200C\u200D\u2060]', '' # zero-width
    $t = $t -replace [char]0x00A0, ''                 # NBSP

    # remove ANY unicode whitespace (category separators etc.)
    $chars = $t.ToCharArray() | Where-Object { -not [char]::IsWhiteSpace($_) }
    $t = -join $chars

    # final trim + strip wrapping quotes
    $t = $t.Trim().Trim('"').Trim("'").Trim()
    if ($t.Length -eq 0) { return $null }
    return $t
}

function Resolve-QPWebhookUrl {
    param([object]$cfg)

    if (-not $cfg) { return $null }

    # 1) Prefer explicit webhookUrl if present
    if ($cfg.PSObject.Properties.Name -contains 'webhookUrl') {
        $u = Normalize-QPString ([string]$cfg.webhookUrl)
        if (-not [string]::IsNullOrWhiteSpace($u)) { return $u }
    }

    # 2) Otherwise build from discordWebhook.id + token (legacy)
    if ($cfg.PSObject.Properties.Name -contains 'discordWebhook' -and $cfg.discordWebhook) {
        $id = Normalize-QPString ([string]$cfg.discordWebhook.id)
        $token = Normalize-QPString ([string]$cfg.discordWebhook.token)

        if (-not [string]::IsNullOrWhiteSpace($id) -and -not [string]::IsNullOrWhiteSpace($token)) {
            return "https://discord.com/api/webhooks/$id/$token"
        }
    }

    return $null
}

# --- Named webhooks: discordWebhooks.<name>.id/token ---
function Resolve-QPWebhookUrlNamed {
    param(
        [object]$cfg,
        [string]$Name
    )

    if (-not $cfg) { return $null }
    $Name = ([string]$Name).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }

    # Support: discordWebhooks.<name>.id/token
    if ($cfg.PSObject.Properties.Name -contains 'discordWebhooks' -and $cfg.discordWebhooks) {
        $bucket = $cfg.discordWebhooks.$Name
        if ($bucket) {
            # optional direct webhookUrl inside named bucket (future-proof)
            if ($bucket.PSObject.Properties.Name -contains 'webhookUrl') {
                $u = Normalize-QPString ([string]$bucket.webhookUrl)
                if (-not [string]::IsNullOrWhiteSpace($u)) { return $u }
            }

            $id = Normalize-QPString ([string]$bucket.id)
            $token = Normalize-QPString ([string]$bucket.token)
            if (-not [string]::IsNullOrWhiteSpace($id) -and -not [string]::IsNullOrWhiteSpace($token)) {
                return "https://discord.com/api/webhooks/$id/$token"
            }
        }
    }

    return $null
}

function Get-QPServerConfig([string]$ServerKey) {
    $path = Get-QPConfigPath
    if (-not (Test-Path $path)) { throw "Config not found: $path" }

    $raw = Get-Content -Path $path -Raw -ErrorAction Stop
    $cfg = $raw | ConvertFrom-Json -ErrorAction Stop

    if (-not $cfg.servers) { throw "Invalid config: missing .servers" }
    if (-not $cfg.servers.$ServerKey) { throw "ServerKey not found in config: $ServerKey" }

    # Work with the server object (NOT the top-level cfg)
    $server = $cfg.servers.$ServerKey

    # Normalize / derive default webhookUrl onto the server object (backwards compatible)
    $resolved = Resolve-QPWebhookUrl $server
    if ($resolved) {
        $resolved = ($resolved -replace "`r", "" -replace "`n", "").Trim()
        $server | Add-Member -NotePropertyName 'webhookUrl' -NotePropertyValue $resolved -Force
    }

    # Also derive named webhooks (status/presence) if present
    foreach ($n in @('status', 'presence')) {
        $u = Resolve-QPWebhookUrlNamed -cfg $server -Name $n
        if ($u) {
            $u = ($u -replace "`r", "" -replace "`n", "").Trim()
            $server | Add-Member -NotePropertyName ("webhookUrl_{0}" -f $n) -NotePropertyValue $u -Force
        }
    }

    return $server
}

function New-DiscordWebhookBase([string]$Id, [string]$Token) {
    if ([string]::IsNullOrWhiteSpace($Id) -or [string]::IsNullOrWhiteSpace($Token)) {
        throw "discordWebhook.id or discordWebhook.token missing in config"
    }

    $safeId = Normalize-QPString $Id
    $safeToken = Normalize-QPString $Token

    if ([string]::IsNullOrWhiteSpace($safeId) -or [string]::IsNullOrWhiteSpace($safeToken)) {
        throw "discordWebhook.id or discordWebhook.token missing/invalid after normalization"
    }

    $base = "https://discord.com/api/webhooks/$safeId/$safeToken"
    try { [void]([uri]$base) } catch { throw "Invalid webhook base URI: $base" }
    return $base
}

function Send-JsonUtf8 {
    param(
        [ValidateSet('POST', 'PATCH')][string]$Method,
        [string]$Url,
        [hashtable]$Payload
    )

    if ([string]::IsNullOrWhiteSpace($Url)) { throw "Invalid URI: <empty>" }

    # normalize URL hard (fixes hidden chars -> hostname parse errors)
    $cleanUrl = Normalize-QPString $Url
    if ([string]::IsNullOrWhiteSpace($cleanUrl)) { throw "Invalid URI: <empty-after-normalize>" }

    $uriObj = $null
    if (-not [uri]::TryCreate($cleanUrl, [System.UriKind]::Absolute, [ref]$uriObj)) {
        # show debug-friendly representation
        $dbg = $cleanUrl -replace "`t", "<TAB>" -replace " ", "<SPACE>"
        throw "Invalid URI: $dbg"
    }

    $json = $Payload | ConvertTo-Json -Depth 16
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)

    Invoke-DiscordApiWithRetry -Method $Method -Uri $uriObj -Body $bytes -ContentType 'application/json; charset=utf-8'
}

function Invoke-DiscordApiWithRetry {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('POST', 'PATCH')]
        [string]$Method,

        [Parameter(Mandatory)]
        [Uri]$Uri,

        [Parameter(Mandatory)]
        [byte[]]$Body,

        [string]$ContentType = 'application/json; charset=utf-8'
    )

    $maxRetries = 5
    $attempt = 0
    $baseDelaySec = 1

    while ($true) {
        $attempt++
        try {
            return Invoke-RestMethod -Method $Method -Uri $Uri -ContentType $ContentType -Body $Body -TimeoutSec 15
        }
        catch {
            $ex = $_.Exception
            $statusCode = 0
            $retryAfter = $null
            $is429 = $false

            if ($ex.Response -and $ex.Response.StatusCode) {
                $statusCode = [int]$ex.Response.StatusCode
            } elseif ($ex.InnerException -and $ex.InnerException.Response -and $ex.InnerException.Response.StatusCode) {
                $statusCode = [int]$ex.InnerException.Response.StatusCode
            }

            if ($statusCode -eq 429) {
                $is429 = $true
                try {
                    if ($ex.Response -and $ex.Response.Headers) {
                        $h = $ex.Response.Headers
                        if ($h.Contains('Retry-After')) {
                            $retryAfter = [int]($h['Retry-After'] | Select-Object -First 1)
                        }
                    }
                } catch {}
                if (-not $retryAfter -or $retryAfter -lt 1) { $retryAfter = 10 }
            }

            if ($is429) {
                if ($attempt -ge $maxRetries) { throw }
                Start-Sleep -Seconds $retryAfter
                continue
            }

            if ($attempt -ge $maxRetries -or ($statusCode -ge 400 -and $statusCode -lt 500 -and $statusCode -ne 429)) {
                throw
            }

            $delay = [Math]::Min($baseDelaySec * [Math]::Pow(2, $attempt - 1), 30)
            Start-Sleep -Seconds $delay
        }
    }
}

function Read-NullTerminatedString([byte[]]$buf, [ref]$idx) {
    $start = $idx.Value
    while ($idx.Value -lt $buf.Length -and $buf[$idx.Value] -ne 0) { $idx.Value++ }
    $len = $idx.Value - $start
    $s = ""
    if ($len -gt 0) { $s = [System.Text.Encoding]::UTF8.GetString($buf, $start, $len) }
    if ($idx.Value -lt $buf.Length -and $buf[$idx.Value] -eq 0) { $idx.Value++ }
    return $s
}

function Parse-A2SInfo([byte[]]$resp) {
    $out = @{ ok = $false; name = ""; map = "" }
    try {
        if (-not $resp -or $resp.Length -lt 10) { return $out }
        if (!($resp[0] -eq 0xFF -and $resp[1] -eq 0xFF -and $resp[2] -eq 0xFF -and $resp[3] -eq 0xFF)) { return $out }

        $idx = 4
        $type = $resp[$idx]; $idx++
        if ($type -ne 0x49 -and $type -ne 0x6D) { return $out }

        $idx++ # protocol
        $name = Read-NullTerminatedString -buf $resp -idx ([ref]$idx)
        $map = Read-NullTerminatedString -buf $resp -idx ([ref]$idx)

        $out.ok = $true
        $out.name = $name
        $out.map = $map
        return $out
    }
    catch {
        return @{ ok = $false; name = ""; map = "" }
    }
}

function Test-A2SQueryStrict {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TargetHost,
        [Parameter(Mandatory = $true)][int]$Port,
        [string]$MustContain = "",
        [int]$TimeoutMs = 1500
    )

    try {
        $udp = New-Object System.Net.Sockets.UdpClient
        $udp.Client.ReceiveTimeout = $TimeoutMs
        $udp.Connect($TargetHost, $Port)

        # Base A2S_INFO request: 0xFFFFFFFF + "TSource Engine Query\0"
        $base = [System.Text.Encoding]::ASCII.GetBytes(
            ([char]0xFF + [char]0xFF + [char]0xFF + [char]0xFF + "TSource Engine Query" + [char]0x00)
        )

        # Send initial request
        [void]$udp.Send($base, $base.Length)

        $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $resp1 = $udp.Receive([ref]$remote)

        if (-not $resp1 -or $resp1.Length -lt 5) { return $false }

        # If challenge (0x41 'A'), resend with challenge bytes
        if ($resp1.Length -ge 9 -and $resp1[4] -eq 0x41) {
            $challenge = $resp1[5..8]
            $req2 = $base + $challenge
            [void]$udp.Send($req2, $req2.Length)

            $remote2 = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
            $resp2 = $udp.Receive([ref]$remote2)

            if (-not $resp2 -or $resp2.Length -lt 5) { return $false }

            # 0x49 'I' = A2S_INFO response
            if ($resp2[4] -ne 0x49) { return $false }

            if ([string]::IsNullOrWhiteSpace($MustContain)) { return $true }

            $txt = [System.Text.Encoding]::UTF8.GetString($resp2)
            return ($txt -match [regex]::Escape($MustContain))
        }

        # Non-challenge path: accept only if it is INFO
        if ($resp1[4] -ne 0x49) { return $false }

        if ([string]::IsNullOrWhiteSpace($MustContain)) { return $true }

        $txt1 = [System.Text.Encoding]::UTF8.GetString($resp1)
        return ($txt1 -match [regex]::Escape($MustContain))
    }
    catch {
        return $false
    }
    finally {
        try { if ($udp) { $udp.Close() } } catch {}
    }
}

function Get-QPWebhookUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ServerKey,
        [ValidateSet('default', 'status', 'presence')][string]$Name = 'default'
    )

    $s = Get-QPServerConfig $ServerKey

    switch ($Name) {
        'status' {
            if ($s.PSObject.Properties.Name -contains 'webhookUrl_status') { return [string]$s.webhookUrl_status }
            return $null
        }
        'presence' {
            if ($s.PSObject.Properties.Name -contains 'webhookUrl_presence') { return [string]$s.webhookUrl_presence }
            return $null
        }
        default {
            if ($s.PSObject.Properties.Name -contains 'webhookUrl') { return [string]$s.webhookUrl }
            return $null
        }
    }
}

Export-ModuleMember -Function *-QP*, Write-QPLog, Send-JsonUtf8, Invoke-DiscordApiWithRetry, Test-A2SQueryStrict, New-DiscordWebhookBase
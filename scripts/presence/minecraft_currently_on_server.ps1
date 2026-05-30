[CmdletBinding()]
param(
  [string]$ServerKey = "minecraft_survival",
  [string]$HostName = "127.0.0.1",
  [int]$Port = 25565,
  [int]$MaxPlayers = 25
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

[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
[Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
$PSDefaultParameterValues['*:Encoding'] = 'utf8'

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$ServerName = "QUESTPAUSE Minecraft Survival"
$OpsRoot = $script:QPRoot
$StateDir = Join-Path $OpsRoot "state\$ServerKey"
$LogsDir = Join-Path $OpsRoot "logs\presence"
$StateFile = Join-Path $StateDir "mc_presence_state.json"
$LastIdFile = Join-Path $StateDir "mc_presence_last_message_id.txt"
$DebugLog = Join-Path $LogsDir "${ServerKey}_presence.log"

$ConfigPath = "$script:QPConfigRoot\servers.json"
$WebhookUrl = $env:WEBHOOK_MC_PRESENCE

if (Test-Path $ConfigPath) {
  try {
    $cfg = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($cfg.servers.minecraft_survival.webhooks.presence) {
      $WebhookUrl = $cfg.servers.minecraft_survival.webhooks.presence
    }
  }
  catch {
    Write-Host "Could not read presence webhook from servers.json, falling back to env var."
  }
}

function Ensure-Dir([string]$Path) {
  if (-not (Test-Path $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

Ensure-Dir $StateDir
Ensure-Dir $LogsDir

function Write-DebugLine([string]$Line) {
  $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
  "$ts  $Line" | Add-Content -Path $DebugLog -Encoding UTF8
}

function Normalize-Webhook([string]$w) {
  if ([string]::IsNullOrWhiteSpace($w)) { return "" }
  $w = $w -replace '[\u200B-\u200F\u202A-\u202E\u2060\uFEFF]', ''
  $w = $w -replace '\s', ''
  return $w.Trim().TrimEnd('/')
}

$WebhookUrl = Normalize-Webhook $WebhookUrl

if ([string]::IsNullOrWhiteSpace($WebhookUrl)) {
  throw "WEBHOOK_MC_PRESENCE is not set."
}

if ($WebhookUrl -notmatch '^https://(canary\.|ptb\.)?discord\.com/api/webhooks/\d+/[^/]+$') {
  throw "Webhook format invalid."
}

$WebhookPostUri = [Uri]("${WebhookUrl}?wait=true")

function Get-WebhookParts([string]$webhookBase) {
  if ($webhookBase -match '^https://(canary\.|ptb\.)?discord\.com/api/webhooks/(?<id>\d+)/(?<token>[^/]+)$') {
    return @{ id = $Matches['id']; token = $Matches['token'] }
  }
  throw "Webhook format unexpected."
}

$WebhookParts = Get-WebhookParts $WebhookUrl

function EditUrl([string]$msgId) {
  "https://discord.com/api/webhooks/$($WebhookParts.id)/$($WebhookParts.token)/messages/$msgId"
}

function SendJsonUTF8([string]$method, [Uri]$uri, [hashtable]$payload) {
  $json = $payload | ConvertTo-Json -Depth 16
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)

  Invoke-DiscordApiWithRetry -Method $method -Uri $uri -Body $bytes -ContentType 'application/json; charset=utf-8'
}

function SendOrEdit([hashtable]$payload) {
  $msgId = ""

  if (Test-Path $LastIdFile) {
    try { $msgId = (Get-Content $LastIdFile -Raw -Encoding UTF8).Trim() } catch { $msgId = "" }
  }

  if ($msgId) {
    try {
      $editUri = [Uri](EditUrl $msgId)
      $r = SendJsonUTF8 -method "PATCH" -uri $editUri -payload $payload
      return $r.id
    }
    catch {
      Write-DebugLine "PATCH failed, posting new message: $($_.Exception.Message)"
      Remove-Item $LastIdFile -Force -ErrorAction SilentlyContinue
    }
  }

  $r = SendJsonUTF8 -method "POST" -uri $WebhookPostUri -payload $payload

  if (-not $r -or -not $r.id) {
    throw "Webhook POST did not return a message id."
  }

  return $r.id
}

function Read-VarInt {
  param([System.IO.Stream]$Stream)

  $numRead = 0
  $result = 0
  do {
    $read = $Stream.ReadByte()
    if ($read -eq -1) { throw "Unexpected end of stream while reading VarInt." }

    $value = ($read -band 0x7F)
    $result = $result -bor ($value -shl (7 * $numRead))

    $numRead++
    if ($numRead -gt 5) { throw "VarInt too big." }
  } while (($read -band 0x80) -ne 0)

  return $result
}

function Write-VarInt {
  param(
    [System.IO.Stream]$Stream,
    [int]$Value
  )

  do {
    $temp = $Value -band 0x7F
    $Value = $Value -shr 7
    if ($Value -ne 0) { $temp = $temp -bor 0x80 }
    $Stream.WriteByte([byte]$temp)
  } while ($Value -ne 0)
}

function Write-McString {
  param(
    [System.IO.Stream]$Stream,
    [string]$Text
  )

  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
  Write-VarInt -Stream $Stream -Value $bytes.Length
  $Stream.Write($bytes, 0, $bytes.Length)
}

function Get-MinecraftStatus {
  param(
    [string]$HostName,
    [int]$Port
  )

  $client = New-Object System.Net.Sockets.TcpClient
  $client.ReceiveTimeout = 3000
  $client.SendTimeout = 3000
  $client.Connect($HostName, $Port)

  $stream = $client.GetStream()

  $packet = New-Object System.IO.MemoryStream
  Write-VarInt -Stream $packet -Value 0
  Write-VarInt -Stream $packet -Value 767
  Write-McString -Stream $packet -Text $HostName

  $portBytes = [System.BitConverter]::GetBytes([UInt16]$Port)
  [Array]::Reverse($portBytes)
  $packet.Write($portBytes, 0, 2)

  Write-VarInt -Stream $packet -Value 1

  $packetBytes = $packet.ToArray()
  Write-VarInt -Stream $stream -Value $packetBytes.Length
  $stream.Write($packetBytes, 0, $packetBytes.Length)

  $request = New-Object System.IO.MemoryStream
  Write-VarInt -Stream $request -Value 0
  $requestBytes = $request.ToArray()
  Write-VarInt -Stream $stream -Value $requestBytes.Length
  $stream.Write($requestBytes, 0, $requestBytes.Length)

  [void](Read-VarInt -Stream $stream)
  [void](Read-VarInt -Stream $stream)
  $jsonLength = Read-VarInt -Stream $stream

  $buffer = New-Object byte[] $jsonLength
  $offset = 0
  while ($offset -lt $jsonLength) {
    $read = $stream.Read($buffer, $offset, $jsonLength - $offset)
    if ($read -le 0) { throw "Unexpected end of stream while reading JSON." }
    $offset += $read
  }

  $json = [System.Text.Encoding]::UTF8.GetString($buffer)

  $stream.Close()
  $client.Close()

  return ($json | ConvertFrom-Json)
}

function Get-PlayerListText {
  param($Status)

  if (-not $Status -or -not $Status.players) {
    return "No players currently detected."
  }

  $online = [int]$Status.players.online

  if ($online -le 0) {
    return "No players currently detected."
  }

  if ($Status.players.sample) {
    $names = @($Status.players.sample | ForEach-Object { $_.name }) | Where-Object { $_ }
    if ($names.Count -gt 0) {
      return (($names | Sort-Object | ForEach-Object { "• **$_**" }) -join "`n")
    }
  }

  return "$online player(s) online, names hidden by server query."
}

function Build-Payload {
  param(
    [bool]$Online,
    [int]$OnlineCount,
    [int]$MaxCount,
    [string]$PlayersText,
    [string]$LastEvent
  )

  $presenceState = if ($OnlineCount -gt 0) { "🟢 Players detected" } elseif ($Online) { "⚫ Quiet realm" } else { "🔴 Server offline" }
  $color = if ($OnlineCount -gt 0) { 0x2ECC71 } elseif ($Online) { 0x95A5A6 } else { 0xE74C3C }
  $pulseUtc = (Get-Date).ToUniversalTime().ToString("HH:mm")
  $lastUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss") + " UTC"

  $desc = @(
    "**Minecraft player presence**",
    "",
    $presenceState,
    "",
    "Live player roster queried from the Minecraft server.",
    "Times in **UTC**."
  ) -join "`n"

  return [ordered]@{
    content          = ""
    embeds           = @(
      [ordered]@{
        title       = "MC Currently On Server"
        description = $desc
        color       = $color
        fields      = @(
          @{ name = "🧭 World"; value = $ServerName; inline = $false },
          @{ name = "🧩 ServerKey"; value = $ServerKey; inline = $true },
          @{ name = "👥 Online"; value = "$OnlineCount/$MaxCount"; inline = $true },
          @{ name = "📡 Presence"; value = $presenceState; inline = $true },
          @{ name = "🧍 Players"; value = $PlayersText; inline = $false },
          @{ name = "Last check (UTC)"; value = $lastUtc; inline = $false },
          @{ name = "📝 Last event"; value = $LastEvent; inline = $false },
          @{ name = "💡 Realm Tip"; value = "Build first, expand later. A safe base beats a rushed base."; inline = $false }
        )
        footer      = @{ text = "QUESTPAUSE • Minecraft • $ServerKey • Pulse $pulseUtc UTC" }
        timestamp   = (Get-Date).ToUniversalTime().ToString("o")
      }
    )
    allowed_mentions = @{ parse = @() }
  }
}

try {
  $mc = Get-MinecraftStatus -HostName $HostName -Port $Port
  $online = $true
  $onlineCount = [int]$mc.players.online
  $maxCount = if ($mc.players.max) { [int]$mc.players.max } else { $MaxPlayers }
  $playersText = Get-PlayerListText -Status $mc
  $lastEvent = if ($onlineCount -gt 0) { "Players online" } else { "No players online" }
}
catch {
  $online = $false
  $onlineCount = 0
  $maxCount = $MaxPlayers
  $playersText = "Server query unavailable."
  $lastEvent = "Server offline or query failed"
  Write-DebugLine "Query failed: $($_.Exception.Message)"
}

$payload = Build-Payload -Online $online -OnlineCount $onlineCount -MaxCount $maxCount -PlayersText $playersText -LastEvent $lastEvent

$id = SendOrEdit $payload
if ($id) {
  Set-Content -Path $LastIdFile -Value $id -Encoding UTF8
}

Set-Content -Path $StateFile -Value (($payload | ConvertTo-Json -Depth 16)) -Encoding UTF8

Write-DebugLine "MC presence updated. online=$online players=$onlineCount msgId=$id"
Write-Host "$ServerName presence checked: $onlineCount/$maxCount"

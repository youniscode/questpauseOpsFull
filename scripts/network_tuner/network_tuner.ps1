# C:\QuestPauseOps\scripts\network_tuner.ps1
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$opsRoot = if (Test-Path "C:\QuestPauseOps") { "C:\QuestPauseOps" } else { Split-Path -Parent $PSScriptRoot }

function Get-AdapterInfo {
    $a = Get-NetAdapter -Name "Ethernet" -ErrorAction SilentlyContinue
    if (-not $a) { $a = Get-NetAdapter | Where-Object { $_.Status -eq "Up" -and $_.Name -ne "Tailscale" } | Select-Object -First 1 }
    return $a
}

function Get-NetworkSummary {
    $a = Get-AdapterInfo
    if (-not $a) { return "No active Ethernet adapter found" }
    $ip = (Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
    $gw = (Get-NetRoute -InterfaceIndex $a.ifIndex -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue).NextHop
    $dns = (Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
    $tcpDelay = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\*" -Name TCPNoDelay -ErrorAction SilentlyContinue | Select-Object -First 1
    $gameMode = Get-ItemProperty "HKCU:\Software\Microsoft\GameBar" -Name AutoGameModeEnabled -ErrorAction SilentlyContinue

    $lines = @(
        "Adapter : $($a.Name)",
        "Speed   : $($a.LinkSpeed)",
        "Status  : $($a.Status)",
        "MAC     : $($a.MacAddress)",
        "IPv4    : $ip",
        "Gateway : $gw",
        "DNS     : $($dns -join ', ')"
        "TCPNoDelay: $(if ($tcpDelay -and $tcpDelay.TCPNoDelay -eq 1) { 'Enabled' } else { 'Disabled (Nagle ON)' })",
        "Game Mode : $(if ($gameMode -and $gameMode.AutoGameModeEnabled -eq 1) { 'Enabled' } else { 'Disabled' })"
    )
    return $lines -join "`r`n"
}

function Get-ServerPorts {
    $cfgPath = Join-Path $opsRoot "config\servers.json"
    if (-not (Test-Path $cfgPath)) { return @() }
    try {
        $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
        $servers = $cfg.servers.PSObject.Properties | ForEach-Object {
            [PSCustomObject]@{
                Name = $_.Name
                DisplayName = $_.Value.displayName
                GamePort = $_.Value.gamePort
                QueryPort = $_.Value.queryPort
                Product = $_.Value.product
            }
        }
        return $servers
    } catch { return @() }
}

function Get-ListeningPorts {
    $serverPorts = Get-ServerPorts
    $results = @()
    foreach ($s in $serverPorts) {
        $gp = $s.GamePort
        $qp = $s.QueryPort
        $gCheck = netstat -an 2>$null | Select-String ":$gp\s" | Where-Object { $_ -match "LISTENING" }
        $qCheck = netstat -an 2>$null | Select-String ":$qp\s" | Where-Object { $_ -match "LISTENING" }
        $results += [PSCustomObject]@{
            Server = $s.DisplayName
            GamePort = $gp
            GameListening = if ($gCheck) { $true } else { $false }
            QueryPort = $qp
            QueryListening = if ($qCheck) { $true } else { $false }
            Product = $s.Product
        }
    }
    return $results
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "QuestPause Network Tuner"
$form.Size = New-Object Drawing.Size(700, 620)
$form.StartPosition = "CenterScreen"
$form.Font = New-Object Drawing.Font("Segoe UI", 9)
$form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon((Get-Command powershell.exe).Source)
if (-not $script:IsAdmin) { $form.Text = "QuestPause Network Tuner (NOT ADMIN - some features disabled)" }

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Size = New-Object Drawing.Size(680, 560)
$tabs.Location = New-Object Drawing.Point(10, 10)

# Tab 1: Dashboard
$tab1 = New-Object System.Windows.Forms.TabPage
$tab1.Text = "Dashboard"

$summaryBox = New-Object System.Windows.Forms.TextBox
$summaryBox.Multiline = $true
$summaryBox.ReadOnly = $true
$summaryBox.Size = New-Object Drawing.Size(640, 200)
$summaryBox.Location = New-Object Drawing.Point(10, 10)
$summaryBox.Font = New-Object Drawing.Font("Consolas", 9)
$summaryBox.BackColor = [Drawing.Color]::FromArgb(30, 30, 30)
$summaryBox.ForeColor = [Drawing.Color]::LimeGreen
$summaryBox.Text = Get-NetworkSummary

$refreshBtn = New-Object System.Windows.Forms.Button
$refreshBtn.Text = "Refresh Network Info"
$refreshBtn.Size = New-Object Drawing.Size(160, 28)
$refreshBtn.Location = New-Object Drawing.Point(10, 220)
$refreshBtn.Add_Click({ $summaryBox.Text = Get-NetworkSummary })

$script:PublicIP = & { try { (Invoke-WebRequest -Uri "https://api.ipify.org" -UseBasicParsing -TimeoutSec 5).Content.Trim() } catch { "unknown" } }

$pingTargets = @(
    @{Label="My Server ($script:PublicIP)"; Host=$script:PublicIP}
    @{Label="France (Free)"; Host="free.fr"}
    @{Label="France (Paris)"; Host="8.8.8.8"}
    @{Label="Germany (Frankfurt)"; Host="google.de"}
    @{Label="UK (London)"; Host="bbc.co.uk"}
    @{Label="Netherlands (Amsterdam)"; Host="cloudflare.com"}
    @{Label="Poland (Warsaw)"; Host="8.8.8.8"}
    @{Label="Spain (Madrid)"; Host="google.es"}
    @{Label="Italy (Milan)"; Host="google.it"}
    @{Label="Sweden (Stockholm)"; Host="google.se"}
    @{Label="US East (NY/VA)"; Host="1.1.1.1"}
    @{Label="US West (CA)"; Host="8.8.8.8"}
    @{Label="US Central (IL)"; Host="google.com"}
    @{Label="Canada (Toronto)"; Host="google.ca"}
    @{Label="Brazil (Sao Paulo)"; Host="google.com.br"}
    @{Label="Japan (Tokyo)"; Host="google.co.jp"}
    @{Label="South Korea (Seoul)"; Host="google.co.kr"}
    @{Label="Singapore"; Host="google.sg"}
    @{Label="Australia (Sydney)"; Host="google.com.au"}
    @{Label="South Africa (Johannesburg)"; Host="google.co.za"}
    @{Label="Custom (enter below)..."; Host=""}
)

$labelPingCountry = New-Object System.Windows.Forms.Label
$labelPingCountry.Text = "Test ping by region:"
$labelPingCountry.Location = New-Object Drawing.Point(10, 258)
$labelPingCountry.Size = New-Object Drawing.Size(130, 20)

$pingCountry = New-Object System.Windows.Forms.ComboBox
$pingCountry.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$pingCountry.Size = New-Object Drawing.Size(180, 22)
$pingCountry.Location = New-Object Drawing.Point(140, 256)
$pingTargets | ForEach-Object { $pingCountry.Items.Add($_.Label) } | Out-Null
$pingCountry.SelectedIndex = 0
$pingInput.Text = $pingTargets[0].Host

$pingInput = New-Object System.Windows.Forms.TextBox
$pingInput.Size = New-Object Drawing.Size(200, 22)
$pingInput.Location = New-Object Drawing.Point(330, 256)
$pingInput.Enabled = $false
$pingInput.Text = ""

$pingBtn = New-Object System.Windows.Forms.Button
$pingBtn.Text = "Ping"
$pingBtn.Size = New-Object Drawing.Size(60, 24)
$pingBtn.Location = New-Object Drawing.Point(540, 254)

$pingCountry.Add_SelectedIndexChanged({
    $target = $pingTargets[$pingCountry.SelectedIndex]
    if ($target.Label -eq "Custom (enter below)...") {
        $pingInput.Enabled = $true
        $pingInput.Text = ""
    } else {
        $pingInput.Enabled = $false
        $pingInput.Text = $target.Host
    }
})

$pingBtn.Add_Click({
    $hostToPing = $pingInput.Text
    if ([string]::IsNullOrWhiteSpace($hostToPing)) { $pingResult.Text = "Select a country or enter a custom host."; return }
    $pingBtn.Enabled = $false
    $regionLabel = $pingTargets[$pingCountry.SelectedIndex].Label
    $pingResult.Text = "Pinging $regionLabel ($hostToPing)..."
    $form.Refresh()
    try {
        $result = Test-Connection -ComputerName $hostToPing -Count 4 -ErrorAction Stop
        $avg = ($result | Measure-Object -Property ResponseTime -Average).Average
        $min = ($result | Measure-Object -Property ResponseTime -Minimum).Minimum
        $max = ($result | Measure-Object -Property ResponseTime -Maximum).Maximum
        $loss = 0
        $pingResult.Text = "$regionLabel  |  Avg: ${avg}ms  Min: ${min}ms  Max: ${max}ms  Loss: ${loss}%"
    } catch {
        $pingResult.Text = "$regionLabel  |  Failed: $_"
    } finally { $pingBtn.Enabled = $true }
})

$pingResult = New-Object System.Windows.Forms.Label
$pingResult.Size = New-Object Drawing.Size(630, 40)
$pingResult.Location = New-Object Drawing.Point(10, 290)
$pingResult.Font = New-Object Drawing.Font("Consolas", 10, [Drawing.FontStyle]::Bold)

$portGrid = New-Object System.Windows.Forms.DataGridView
$portGrid.Size = New-Object Drawing.Size(640, 180)
$portGrid.Location = New-Object Drawing.Point(10, 340)
$portGrid.ReadOnly = $true
$portGrid.AllowUserToAddRows = $false
$portGrid.RowHeadersVisible = $false
$portGrid.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
$portGrid.BackgroundColor = [Drawing.SystemColors]::Window
$listening = Get-ListeningPorts
$portGrid.DataSource = if ($listening) { $listening | Select-Object Server, GamePort, @{N="Game";E={if($_.GameListening){"YES"}else{"no"}}}, QueryPort, @{N="Query";E={if($_.QueryListening){"YES"}else{"no"}}} } else { @() }

$tab1.Controls.AddRange(@($summaryBox, $refreshBtn, $labelPingCountry, $pingCountry, $pingInput, $pingBtn, $pingResult, $portGrid))
$tabs.Controls.Add($tab1)

# Tab 2: Toggles
$tab2 = New-Object System.Windows.Forms.TabPage
$tab2.Text = "Toggles"

$y = 15
$labelToggle = New-Object System.Windows.Forms.Label
$labelToggle.Text = "Toggle network settings:"
$labelToggle.Location = New-Object Drawing.Point(10, $y)
$labelToggle.Size = New-Object Drawing.Size(300, 20)
$labelToggle.Font = New-Object Drawing.Font("Segoe UI", 10, [Drawing.FontStyle]::Bold)
$tab2.Controls.Add($labelToggle)

$y += 35

function Add-Toggle {
    param([int]$x, [string]$Name, [string]$Label, [string]$RegPath, [string]$RegValue, [int]$RegType, [scriptblock]$StatusCheck, [scriptblock]$ApplyOn)
    $toggle = New-Object System.Windows.Forms.CheckBox
    $toggle.Text = $Label
    $toggle.Size = New-Object Drawing.Size(300, 24)
    $toggle.Location = New-Object Drawing.Point(10, $x)
    $toggle.Font = New-Object Drawing.Font("Segoe UI", 9.5)

    try { $toggle.Checked = & $StatusCheck } catch {}
    $curr = $Name

    $info = New-Object System.Windows.Forms.Label
    $info.Size = New-Object Drawing.Size(300, 20)
    $info.Location = New-Object Drawing.Point(320, $x)
    $info.Font = New-Object Drawing.Font("Segoe UI", 8)
    $info.ForeColor = [Drawing.Color]::Gray

    if ($toggle.Checked) { $info.Text = "ON" } else { $info.Text = "OFF" }

    $toggle.Add_CheckedChanged({
        if (-not $script:IsAdmin -and $curr -ne "GameMode") { return }
        try { & $ApplyOn $toggle.Checked } catch { $info.Text = "Error: $_" }
        if ($toggle.Checked) { $info.Text = "ON" } else { $info.Text = "OFF" }
    })

    return $toggle, $info
}

$tcpDelayToggle = New-Object System.Windows.Forms.CheckBox
$tcpDelayToggle.Text = "TCPNoDelay (Disable Nagle)"
$tcpDelayToggle.Size = New-Object Drawing.Size(300, 24)
$tcpDelayToggle.Location = New-Object Drawing.Point(10, $y)
$tcpDelayToggle.Font = New-Object Drawing.Font("Segoe UI", 9.5)
$adapterGuid = $null
try {
    $iface = Get-NetAdapter -Name "Ethernet" -ErrorAction SilentlyContinue
    $guid = (Get-NetIPAddress -InterfaceIndex $iface.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).InterfaceGuid
    if (-not $guid) { $guid = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\*" -Name DhcpIPAddress -ErrorAction SilentlyContinue | Where-Object { $_.DhcpIPAddress -ne "0.0.0.0" } | Select-Object -First 1).PSChildName }
    $adapterGuid = $guid
    $currentVal = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$guid" -Name TCPNoDelay -ErrorAction SilentlyContinue).TCPNoDelay
    $tcpDelayToggle.Checked = ($currentVal -eq 1)
} catch { $adapterGuid = $null }
$tcpDelayToggle.Add_CheckedChanged({
    if (-not $script:IsAdmin) { return }
    if ($adapterGuid) {
        $val = if ($tcpDelayToggle.Checked) { 1 } else { 0 }
        reg add "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$adapterGuid" /v TCPNoDelay /t REG_DWORD /d $val /f | Out-Null
        $tcpDelayStatus.Text = if ($tcpDelayToggle.Checked) { "ON" } else { "OFF" }
    }
})
$tcpDelayStatus = New-Object System.Windows.Forms.Label
$tcpDelayStatus.Size = New-Object Drawing.Size(300, 20)
$tcpDelayStatus.Location = New-Object Drawing.Point(320, $y)
$tcpDelayStatus.Font = New-Object Drawing.Font("Segoe UI", 8)
$tcpDelayStatus.ForeColor = [Drawing.Color]::Gray
$tcpDelayStatus.Text = if ($tcpDelayToggle.Checked) { "ON" } else { "OFF" }

$y += 30

$gameModeToggle = New-Object System.Windows.Forms.CheckBox
$gameModeToggle.Text = "Game Mode"
$gameModeToggle.Size = New-Object Drawing.Size(300, 24)
$gameModeToggle.Location = New-Object Drawing.Point(10, $y)
$gameModeToggle.Font = New-Object Drawing.Font("Segoe UI", 9.5)
try {
    $gm = Get-ItemProperty "HKCU:\Software\Microsoft\GameBar" -Name AutoGameModeEnabled -ErrorAction SilentlyContinue
    $gameModeToggle.Checked = ($gm.AutoGameModeEnabled -eq 1)
} catch {}
$gameModeToggle.Add_CheckedChanged({
    $val = if ($gameModeToggle.Checked) { 1 } else { 0 }
    reg add "HKCU\Software\Microsoft\GameBar" /v AutoGameModeEnabled /t REG_DWORD /d $val /f | Out-Null
    reg add "HKCU\Software\Microsoft\GameBar" /v AllowAutoGameMode /t REG_DWORD /d $val /f | Out-Null
    $gameModeStatus.Text = if ($gameModeToggle.Checked) { "ON" } else { "OFF" }
})
$gameModeStatus = New-Object System.Windows.Forms.Label
$gameModeStatus.Size = New-Object Drawing.Size(300, 20)
$gameModeStatus.Location = New-Object Drawing.Point(320, $y)
$gameModeStatus.Font = New-Object Drawing.Font("Segoe UI", 8)
$gameModeStatus.ForeColor = [Drawing.Color]::Gray
$gameModeStatus.Text = if ($gameModeToggle.Checked) { "ON" } else { "OFF" }

$y += 30

$dvrToggle = New-Object System.Windows.Forms.CheckBox
$dvrToggle.Text = "Game DVR (Xbox Game Bar)"
$dvrToggle.Size = New-Object Drawing.Size(300, 24)
$dvrToggle.Location = New-Object Drawing.Point(10, $y)
$dvrToggle.Font = New-Object Drawing.Font("Segoe UI", 9.5)
try {
    $dvr = Get-ItemProperty "HKCU:\System\GameConfigStore" -Name GameDVR_Enabled -ErrorAction SilentlyContinue
    $dvrToggle.Checked = ($dvr.GameDVR_Enabled -eq 1)
} catch {}
$dvrToggle.Add_CheckedChanged({
    $val = if ($dvrToggle.Checked) { 1 } else { 0 }
    reg add "HKCU\System\GameConfigStore" /v GameDVR_Enabled /t REG_DWORD /d $val /f | Out-Null
    $dvrStatus.Text = if ($dvrToggle.Checked) { "ON (recording enabled)" } else { "OFF (reduced overhead)" }
})
$dvrStatus = New-Object System.Windows.Forms.Label
$dvrStatus.Size = New-Object Drawing.Size(300, 20)
$dvrStatus.Location = New-Object Drawing.Point(320, $y)
$dvrStatus.Font = New-Object Drawing.Font("Segoe UI", 8)
$dvrStatus.ForeColor = [Drawing.Color]::Gray
$dvrStatus.Text = if ($dvrToggle.Checked) { "ON (recording enabled)" } else { "OFF (reduced overhead)" }

$y += 30

$defenderToggle = New-Object System.Windows.Forms.CheckBox
$defenderToggle.Text = "Real-time Protection (Defender)"
$defenderToggle.Size = New-Object Drawing.Size(300, 24)
$defenderToggle.Location = New-Object Drawing.Point(10, $y)
$defenderToggle.Font = New-Object Drawing.Font("Segoe UI", 9.5)
if ($script:IsAdmin) {
    try {
        $def = Get-MpPreference
        $defenderToggle.Checked = (-not $def.DisableRealtimeMonitoring)
    } catch {}
}
$defenderToggle.Add_CheckedChanged({
    if (-not $script:IsAdmin) { return }
    try {
        if ($defenderToggle.Checked) {
            Set-MpPreference -DisableRealtimeMonitoring $false
        } else {
            Set-MpPreference -DisableRealtimeMonitoring $true
        }
        $defenderStatus.Text = if ($defenderToggle.Checked) { "ON (scanning)" } else { "OFF (faster I/O)" }
    } catch { $defenderStatus.Text = "Error: $_" }
})
$defenderStatus = New-Object System.Windows.Forms.Label
$defenderStatus.Size = New-Object Drawing.Size(300, 20)
$defenderStatus.Location = New-Object Drawing.Point(320, $y)
$defenderStatus.Font = New-Object Drawing.Font("Segoe UI", 8)
$defenderStatus.ForeColor = [Drawing.Color]::Gray
$defenderStatus.Text = if ($defenderToggle.Checked) { "ON (scanning)" } else { "OFF (faster I/O)" }

$y += 40

$restartBtn = New-Object System.Windows.Forms.Button
$restartBtn.Text = "Restart Network Adapter"
$restartBtn.Size = New-Object Drawing.Size(200, 30)
$restartBtn.Location = New-Object Drawing.Point(10, $y)
$restartBtn.BackColor = [Drawing.Color]::OrangeRed
$restartBtn.ForeColor = [Drawing.Color]::White
$restartBtn.Add_Click({
    if (-not $script:IsAdmin) { [System.Windows.Forms.MessageBox]::Show("Requires Administrator!","Error") | Out-Null; return }
    $r = [System.Windows.Forms.MessageBox]::Show("Restart Ethernet adapter? Connection will drop briefly.","Confirm",[System.Windows.Forms.MessageBoxButtons]::YesNo)
    if ($r -eq "Yes") {
        Restart-NetAdapter -Name "Ethernet" -Confirm:$false
        Start-Sleep 5
        $summaryBox.Text = Get-NetworkSummary
    }
})

$y += 40

$notAdminLabel = New-Object System.Windows.Forms.Label
$notAdminLabel.Size = New-Object Drawing.Size(620, 40)
$notAdminLabel.Location = New-Object Drawing.Point(10, $y)
$notAdminLabel.ForeColor = [Drawing.Color]::Red
if (-not $script:IsAdmin) {
    $notAdminLabel.Text = "NOTE: Run as Administrator to use TCPNoDelay, Defender, and Restart NIC toggles."
}

$tab2.Controls.AddRange(@($tcpDelayToggle, $tcpDelayStatus, $gameModeToggle, $gameModeStatus, $dvrToggle, $dvrStatus, $defenderToggle, $defenderStatus, $restartBtn, $notAdminLabel))
$tabs.Controls.Add($tab2)

# Tab 3: Adapter Details
$tab3 = New-Object System.Windows.Forms.TabPage
$tab3.Text = "Adapter"

$adapterTree = New-Object System.Windows.Forms.RichTextBox
$adapterTree.Size = New-Object Drawing.Size(640, 460)
$adapterTree.Location = New-Object Drawing.Point(10, 10)
$adapterTree.ReadOnly = $true
$adapterTree.Font = New-Object Drawing.Font("Consolas", 9)
$adapterTree.BackColor = [Drawing.Color]::White

$infoLines = @()
try {
    $a = Get-AdapterInfo
    if ($a) {
        $infoLines += "=== Network Adapter ==="
        $infoLines += "Name:           $($a.Name)"
        $infoLines += "InterfaceIndex: $($a.ifIndex)"
        $infoLines += "InterfaceGuid:  $($a.InterfaceGuid)"
        $infoLines += "Status:         $($a.Status)"
        $infoLines += "LinkSpeed:      $($a.LinkSpeed)"
        $infoLines += "MacAddress:     $($a.MacAddress)"
        $infoLines += "MediaType:      $($a.MediaType)"
        $infoLines += "AdminStatus:    $($a.AdminStatus)"
        $infoLines += "Driver:         $($a.DriverInformation)"
        $infoLines += ""
        $infoLines += "=== IP Configuration ==="
        $ipInfo = Get-NetIPConfiguration -InterfaceIndex $a.ifIndex -ErrorAction SilentlyContinue
        if ($ipInfo) {
            $infoLines += "IPv4 Address:   $($ipInfo.IPv4Address.IPAddress)"
            $infoLines += "Subnet Mask:    $($ipInfo.IPv4Address.PrefixLength)"
            $infoLines += "Default GW:     $($ipInfo.IPv4DefaultGateway.NextHop)"
            $infoLines += "DNS Servers:    $(($ipInfo.DNSServer.ServerAddresses) -join ', ')"
        }
        $infoLines += ""
        $infoLines += "=== TCP/IP Parameters ==="
        $params = netsh int tcp show global
        $infoLines += $params
        $infoLines += ""
        $infoLines += "=== Registry (TCP/IP Interfaces) ==="
        Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($a.InterfaceGuid)" -ErrorAction SilentlyContinue | Format-List | Out-String | ForEach-Object { $infoLines += $_ }
    }
} catch { $infoLines += "Error retrieving adapter info: $_" }

$adapterTree.Text = ($infoLines -join "`r`n")
$tab3.Controls.Add($adapterTree)
$tabs.Controls.Add($tab3)

$form.Controls.Add($tabs)
$form.ShowDialog() | Out-Null

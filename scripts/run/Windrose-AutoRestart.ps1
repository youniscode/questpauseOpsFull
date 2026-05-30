# Bootstrap: resolve QuestPauseOps root paths from env.ps1
$__qpEnv = $null
foreach ($__qpRel in @('..\env.ps1', '..\..\env.ps1', '..\..\..\env.ps1', '..\..\..\..\env.ps1')) {
    $__qpTest = Join-Path $PSScriptRoot $__qpRel
    if (Test-Path $__qpTest) { $__qpEnv = $__qpTest; break }
}
if (-not $__qpEnv) { throw "env.ps1 not found from $PSScriptRoot" }
. $__qpEnv
Remove-Variable __qpEnv, __qpRel, __qpTest -ErrorAction SilentlyContinue

# Resolve Windrose server path from servers.json
$windroseCfgPath = Join-Path $script:QPConfigRoot 'servers.json'
$windroseCfg = Get-Content $windroseCfgPath -Raw | ConvertFrom-Json
$ServerBat = if ($windroseCfg.servers.windrose_main.startScriptPath) { [string]$windroseCfg.servers.windrose_main.startScriptPath } else { throw "startScriptPath not found for windrose_main in servers.json" }

$LogDir = "$script:QPLogsRoot"
if (!(Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

$LogFile = Join-Path $LogDir "windrose-auto-restart.log"
$WorkingDir = Split-Path $ServerBat

$RestartDelaySeconds = 15
$StartupGraceSeconds = 40

function Write-Log {
    param([string]$Message)
    Add-Content -Path $LogFile -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
}

while ($true) {
    Write-Log "Checking for leftover Windrose server processes..."

    Get-CimInstance Win32_Process |
        Where-Object {
            $_.Name -match "^WindroseServer.*\.exe$|^WindroseServer.*$"
        } |
        ForEach-Object {
            Write-Log "Killing leftover PID $($_.ProcessId) Name=$($_.Name)"
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }

    Write-Log "Launching server: $ServerBat"
    Start-Process -FilePath $ServerBat -WorkingDirectory $WorkingDir

    Start-Sleep -Seconds $StartupGraceSeconds

    $windroseProcess = Get-CimInstance Win32_Process |
        Where-Object {
            $_.Name -match "^WindroseServer.*\.exe$|^WindroseServer.*$"
        }

    if ($windroseProcess) {
        $pidList = ($windroseProcess | Select-Object -ExpandProperty ProcessId) -join ", "
        Write-Log "Server is running. PID(s): $pidList"

        while ($true) {
            Start-Sleep -Seconds 10

            $stillRunning = Get-CimInstance Win32_Process |
                Where-Object {
                    $_.Name -match "^WindroseServer.*\.exe$|^WindroseServer.*$"
                }

            if (-not $stillRunning) {
                Write-Log "Server process disappeared. Crash or exit detected."
                break
            }
        }
    }
    else {
        Write-Log "Server failed to stay up after startup grace period."
    }

    Write-Log "Restarting in $RestartDelaySeconds seconds..."
    Start-Sleep -Seconds $RestartDelaySeconds
}
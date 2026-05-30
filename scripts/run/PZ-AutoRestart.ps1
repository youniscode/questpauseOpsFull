# Bootstrap: resolve QuestPauseOps root paths from env.ps1
$__qpEnv = $null
foreach ($__qpRel in @('..\env.ps1', '..\..\env.ps1', '..\..\..\env.ps1', '..\..\..\..\env.ps1')) {
    $__qpTest = Join-Path $PSScriptRoot $__qpRel
    if (Test-Path $__qpTest) { $__qpEnv = $__qpTest; break }
}
if (-not $__qpEnv) { throw "env.ps1 not found from $PSScriptRoot" }
. $__qpEnv
Remove-Variable __qpEnv, __qpRel, __qpTest -ErrorAction SilentlyContinue

$ServerBat = "$script:QPRoot\servers\projectzomboid_main\serverfiles\StartServer64.bat"

$LogDir = "$script:QPLogsRoot"
if (!(Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

$LogFile = Join-Path $LogDir "pz-auto-restart.log"
$WorkingDir = Split-Path $ServerBat

$RestartDelaySeconds = 15
$StartupGraceSeconds = 40

function Write-Log {
    param([string]$Message)
    Add-Content -Path $LogFile -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
}

while ($true) {
    Write-Log "Checking for leftover Project Zomboid server processes..."

    Get-CimInstance Win32_Process |
        Where-Object {
            $_.Name -match "java.exe" -and
            $_.CommandLine -match "zombie.network.GameServer"
        } |
        ForEach-Object {
            Write-Log "Killing leftover PID $($_.ProcessId)"
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }

    Write-Log "Launching server: $ServerBat"
    Start-Process -FilePath $ServerBat -WorkingDirectory $WorkingDir

    Start-Sleep -Seconds $StartupGraceSeconds

    $pzProcess = Get-CimInstance Win32_Process |
        Where-Object {
            $_.Name -match "java.exe" -and
            $_.CommandLine -match "zombie.network.GameServer"
        }

    if ($pzProcess) {
        $pidList = ($pzProcess | Select-Object -ExpandProperty ProcessId) -join ", "
        Write-Log "Server is running. PID(s): $pidList"

        while ($true) {
            Start-Sleep -Seconds 10

            $stillRunning = Get-CimInstance Win32_Process |
                Where-Object {
                    $_.Name -match "java.exe" -and
                    $_.CommandLine -match "zombie.network.GameServer"
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
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$ServerKey
)

$statePath = "C:\QuestPauseOps\state\backup\$ServerKey\last-result.json"

if (Test-Path $statePath) {
  try {
    $content = Get-Content $statePath -Raw -Encoding UTF8
    Write-Output $content
  } catch {
    Write-Output (ConvertTo-Json @{
      serverKey = $ServerKey
      status = 'unknown'
      message = "Failed to read last result: $($_.Exception.Message)"
    })
  }
} else {
  Write-Output (ConvertTo-Json @{
    serverKey = $ServerKey
    status = 'unknown'
    message = 'No backup result found yet.'
  })
}

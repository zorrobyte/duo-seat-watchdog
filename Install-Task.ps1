<#
.SYNOPSIS
    Registers Duo-Seat-Watchdog.ps1 as a SYSTEM scheduled task that runs at
    startup and restarts on failure. Run this from an elevated PowerShell.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install-Task.ps1
#>
[CmdletBinding()]
param(
    [string] $TaskName = 'DuoSeatWatchdog',
    [int]    $GraceMinutes = 5
)

$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot 'Duo-Seat-Watchdog.ps1'
if (-not (Test-Path $script)) { throw "Cannot find Duo-Seat-Watchdog.ps1 next to this installer." }

$arg = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden ' +
       "-File `"$script`" -GraceMinutes $GraceMinutes"

$action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
$trigger = New-ScheduledTaskTrigger -AtStartup
$set     = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
             -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Settings $set -User 'SYSTEM' -RunLevel Highest -Force | Out-Null

Start-ScheduledTask -TaskName $TaskName
Write-Host "Registered and started scheduled task '$TaskName' (grace = $GraceMinutes min)." -ForegroundColor Green
Write-Host "Log: $env:ProgramData\DuoSeatWatchdog\watchdog.log"

<#
.SYNOPSIS
    Logs off idle DuoStream seats to save power once their Moonlight client
    has disconnected.

.DESCRIPTION
    DuoStream (https://github.com/DuoStream/Duo) runs each streaming user as a
    real Windows RDP session with its own Sunshine instance. Sunshine has no
    idle/disconnect timeout, so a seat left by a disconnected client keeps the
    game running and the GPU busy indefinitely.

    This watchdog auto-discovers Duo seats from Duo's own *.conf files, watches
    each seat's Sunshine ports for an active stream, and logs the seat's RDP
    session off after $GraceMinutes with no client. Logging off terminates the
    game and frees the virtual display / GPU.

    Safety: it ONLY logs off RDP sessions whose username matches a discovered
    Duo account. It never touches the console session (physical / Parsec,
    session 1), session 0, or any non-Duo RDP session.

    Run elevated / as SYSTEM -- logging off another user's session needs admin.

.PARAMETER GraceMinutes
    Minutes with no active stream before a seat is logged off. Default 30.

.PARAMETER PollSeconds
    Seconds between checks. Default 60.

.PARAMETER ConfigDir
    Duo config directory holding the per-account *.conf files.
    Default 'C:\Program Files\Duo\config'.

.PARAMETER LogFile
    Path to the watchdog's activity log.
    Default "$env:ProgramData\DuoSeatWatchdog\watchdog.log".

.PARAMETER WhatIf
    Log what it *would* do without actually logging anyone off.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Duo-Seat-Watchdog.ps1

.EXAMPLE
    .\Duo-Seat-Watchdog.ps1 -GraceMinutes 15 -WhatIf
#>
[CmdletBinding()]
param(
    [int]    $GraceMinutes = 30,
    [int]    $PollSeconds  = 60,
    [string] $ConfigDir    = 'C:\Program Files\Duo\config',
    [string] $LogFile      = "$env:ProgramData\DuoSeatWatchdog\watchdog.log",
    [switch] $WhatIf
)

$logDir = Split-Path -Parent $LogFile
if ($logDir -and -not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

function Write-Log($msg) {
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line  = "$stamp  $msg"
    Add-Content -Path $LogFile -Value $line
    Write-Verbose $line
}

# Discover Duo seats (account name + Sunshine base port) from each *.conf
function Get-DuoSeats {
    Get-ChildItem $ConfigDir -Filter *.conf -ErrorAction SilentlyContinue | ForEach-Object {
        $c    = Get-Content $_.FullName
        $name = ($c | Where-Object { $_ -match '^\s*sunshine_name\s*=' }) -replace '.*=\s*',''
        $port = ($c | Where-Object { $_ -match '^\s*port\s*=' })          -replace '.*=\s*',''
        if ($name -and $port) {
            [pscustomobject]@{ Account = $name.Trim(); Base = [int]$port.Trim() }
        }
    }
}

# Is this seat's Sunshine instance currently carrying a live stream?
# Active = remote (non-loopback) TCP established on a control port, or UDP
# video/audio/control endpoints bound (Sunshine binds these only while streaming).
function Test-SeatActive($base) {
    $tcpPorts = @(($base - 5), $base, ($base + 1), ($base + 21))
    $tcp = Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalPort -in $tcpPorts -and
                       $_.RemoteAddress -notin @('127.0.0.1','::1','0.0.0.0') }
    if ($tcp) { return $true }
    $udpLo = $base + 5; $udpHi = $base + 15
    $udp = Get-NetUDPEndpoint -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalPort -ge $udpLo -and $_.LocalPort -le $udpHi }
    return [bool]$udp
}

# Resolve a Duo account name to its Windows RDP session id.
# Returns $null unless it is an rdp-* session with id > 1 (never console/services).
function Get-SeatSessionId($account) {
    $line = (quser 2>$null) | Where-Object {
        $_ -match "(?i)^\s*>?\s*$([regex]::Escape($account))\s"
    }
    if (-not $line) { return $null }
    if ($line -match '\s(\d+)\s+(Active|Disc)\b') {
        $id = [int]$matches[1]
        if ($id -gt 1 -and $line -match 'rdp') { return $id }
    }
    return $null
}

Write-Log "Watchdog started (grace=$GraceMinutes min, poll=$PollSeconds s, whatif=$($WhatIf.IsPresent))."
$lastActive = @{}

while ($true) {
    foreach ($seat in Get-DuoSeats) {
        if (Test-SeatActive $seat.Base) {
            $lastActive[$seat.Account] = Get-Date
        }
        else {
            if (-not $lastActive.ContainsKey($seat.Account)) {
                $lastActive[$seat.Account] = Get-Date
            }
            $idleMin = (New-TimeSpan -Start $lastActive[$seat.Account] -End (Get-Date)).TotalMinutes
            if ($idleMin -ge $GraceMinutes) {
                $sid = Get-SeatSessionId $seat.Account
                if ($sid) {
                    if ($WhatIf) {
                        Write-Log "[WhatIf] Seat '$($seat.Account)' idle $([int]$idleMin) min -> would logoff session $sid."
                    }
                    else {
                        Write-Log "Seat '$($seat.Account)' idle $([int]$idleMin) min -> logoff session $sid."
                        logoff $sid 2>$null
                    }
                }
                $lastActive.Remove($seat.Account) | Out-Null
            }
        }
    }
    Start-Sleep -Seconds $PollSeconds
}

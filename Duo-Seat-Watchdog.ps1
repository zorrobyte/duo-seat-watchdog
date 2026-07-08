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
    session off after $GraceMinutes with no client.

    Seats are re-discovered every poll cycle, so accounts added later are picked
    up automatically without a restart.

    Logging is durable and self-documenting: it records seat discovery/removal,
    stream start/stop transitions, every logoff, and -- importantly -- a WARN
    with the raw `quser` row whenever it wants to log a seat off but cannot
    resolve an RDP session (name mismatch, truncation, non-rdp session, etc.).
    Watch the log in real use to see which edge cases actually occur.

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

.PARAMETER LogFile
    Path to the watchdog's activity log.

.PARAMETER MaxLogMB
    Rotate the log (to <log>.1) once it exceeds this size. Default 5.

.PARAMETER WhatIf
    Log what it *would* do without actually logging anyone off.

.EXAMPLE
    .\Duo-Seat-Watchdog.ps1 -GraceMinutes 30 -WhatIf -Verbose
#>
[CmdletBinding()]
param(
    [int]    $GraceMinutes = 30,
    [int]    $PollSeconds  = 60,
    [string] $ConfigDir    = 'C:\Program Files\Duo\config',
    [string] $LogFile      = "$env:ProgramData\DuoSeatWatchdog\watchdog.log",
    [int]    $MaxLogMB     = 5,
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

function Rotate-LogIfNeeded {
    if (Test-Path $LogFile) {
        $mb = (Get-Item $LogFile).Length / 1MB
        if ($mb -ge $MaxLogMB) {
            Move-Item -Path $LogFile -Destination "$LogFile.1" -Force
            Write-Log "Log rotated (previous kept as $LogFile.1)."
        }
    }
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

# Is this seat's Sunshine instance carrying a live stream? Returns Active + Reason.
function Test-SeatActive($base) {
    $tcpPorts = @(($base - 5), $base, ($base + 1), ($base + 21))
    $tcp = Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalPort -in $tcpPorts -and
                       $_.RemoteAddress -notin @('127.0.0.1','::1','0.0.0.0') } |
        Select-Object -First 1
    if ($tcp) {
        return [pscustomobject]@{ Active = $true; Reason = "TCP $($tcp.LocalPort)<-$($tcp.RemoteAddress):$($tcp.RemotePort)" }
    }
    $udpLo = $base + 5; $udpHi = $base + 15
    $udp = Get-NetUDPEndpoint -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalPort -ge $udpLo -and $_.LocalPort -le $udpHi }
    if ($udp) {
        return [pscustomobject]@{ Active = $true; Reason = "UDP $((($udp.LocalPort | Sort-Object) -join ','))" }
    }
    return [pscustomobject]@{ Active = $false; Reason = 'no stream ports bound' }
}

# Resolve a Duo account name to its Windows RDP session id.
# Returns Id (or $null), a human Reason, and the raw quser Dump for the log.
# Refuses the console (id<=1) and non-rdp sessions.
function Resolve-SeatSession($account) {
    $all = quser 2>$null
    if (-not $all) {
        return [pscustomobject]@{ Id = $null; Reason = 'quser returned nothing (unavailable or no sessions)'; Dump = '' }
    }
    $line = $all | Where-Object { $_ -match "(?i)^\s*>?\s*$([regex]::Escape($account))\s" }
    if (-not $line) {
        # quser truncates long usernames; try a prefix match as a fallback.
        $trunc = if ($account.Length -gt 20) { $account.Substring(0, 20) } else { $account }
        $line  = $all | Where-Object { $_ -match "(?i)^\s*>?\s*$([regex]::Escape($trunc))" } | Select-Object -First 1
        if ($line) {
            return (New-SessionResult $line "matched via truncated-name fallback ('$trunc')")
        }
        return [pscustomobject]@{ Id = $null; Reason = "no quser row matched account '$account'"; Dump = ($all | Select-Object -Skip 1) -join ' || ' }
    }
    return (New-SessionResult ($line | Select-Object -First 1) 'exact name match')
}

function New-SessionResult($line, $how) {
    $dump = $line.Trim()
    if ($line -match '\s(\d+)\s+(Active|Disc)\b') {
        $id = [int]$matches[1]
        if ($id -le 1)            { return [pscustomobject]@{ Id = $null; Reason = "REFUSED: session id $id is console/services ($how)"; Dump = $dump } }
        if ($line -notmatch 'rdp'){ return [pscustomobject]@{ Id = $null; Reason = "REFUSED: session $id is not an rdp session ($how)"; Dump = $dump } }
        return [pscustomobject]@{ Id = $id; Reason = "rdp session $id ($how)"; Dump = $dump }
    }
    return [pscustomobject]@{ Id = $null; Reason = "could not parse session id/state ($how)"; Dump = $dump }
}

Rotate-LogIfNeeded
Write-Log "Watchdog started (grace=$GraceMinutes min, poll=$PollSeconds s, whatif=$($WhatIf.IsPresent))."
if (-not (Get-Command quser -ErrorAction SilentlyContinue)) {
    Write-Log "WARN: 'quser' not found -- seats can be detected but NOT logged off on this host."
}

$lastActive = @{}   # account -> last time a stream was seen active
$state      = @{}   # account -> 'active' | 'idle' | 'handled'
$known      = @{}   # account -> base port (previous cycle's seat set)
$cycle      = 0
$HeartbeatEvery = [Math]::Max(1, [int](3600 / [Math]::Max(1, $PollSeconds)))  # ~hourly

while ($true) {
    $cycle++
    $seats   = @(Get-DuoSeats)
    $current = @{}; foreach ($s in $seats) { $current[$s.Account] = $s.Base }

    # Log newly discovered / removed seats.
    foreach ($a in $current.Keys) {
        if (-not $known.ContainsKey($a)) { Write-Log "Seat discovered: '$a' (Sunshine base port $($current[$a]))." }
    }
    foreach ($a in @($known.Keys)) {
        if (-not $current.ContainsKey($a)) {
            Write-Log "Seat removed from config: '$a'."
            $lastActive.Remove($a) | Out-Null; $state.Remove($a) | Out-Null
        }
    }

    # Warn on port-range overlap (only when the seat set changes).
    $setChanged = ($current.Count -ne $known.Count) -or
                  (@($current.Keys | Where-Object { $known[$_] -ne $current[$_] }).Count -gt 0)
    if ($setChanged -and $seats.Count -gt 1) {
        $sorted = $seats | Sort-Object Base
        for ($i = 1; $i -lt $sorted.Count; $i++) {
            if (($sorted[$i].Base - 5) -le ($sorted[$i-1].Base + 21)) {
                Write-Log "WARN: port ranges of seats '$($sorted[$i-1].Account)' (base $($sorted[$i-1].Base)) and '$($sorted[$i].Account)' (base $($sorted[$i].Base)) overlap -- detection may cross-trigger."
            }
        }
    }
    $known = $current

    foreach ($seat in $seats) {
        $acct  = $seat.Account
        $probe = Test-SeatActive $seat.Base

        if ($probe.Active) {
            if ($state[$acct] -ne 'active') { Write-Log "Seat '$acct' stream ACTIVE ($($probe.Reason))." }
            $state[$acct] = 'active'
            $lastActive[$acct] = Get-Date
            continue
        }

        # No active stream.
        if ($state[$acct] -eq 'handled') { continue }   # already acted; wait for a new stream

        if (-not $lastActive.ContainsKey($acct)) { $lastActive[$acct] = Get-Date }
        if ($state[$acct] -ne 'idle') {
            Write-Log "Seat '$acct' no client ($($probe.Reason)); grace countdown started ($GraceMinutes min)."
            $state[$acct] = 'idle'
        }

        $idleMin = [int](New-TimeSpan -Start $lastActive[$acct] -End (Get-Date)).TotalMinutes
        if ($idleMin -ge $GraceMinutes) {
            $r = Resolve-SeatSession $acct
            if ($r.Id) {
                if ($WhatIf) {
                    Write-Log "[WhatIf] Seat '$acct' idle $idleMin min -> would logoff $($r.Reason). Row: $($r.Dump)"
                } else {
                    Write-Log "Seat '$acct' idle $idleMin min -> logoff $($r.Reason). Row: $($r.Dump)"
                    logoff $r.Id 2>$null
                }
            } else {
                Write-Log "WARN: Seat '$acct' idle $idleMin min but NOT logged off -- $($r.Reason). quser: $($r.Dump)"
            }
            $state[$acct] = 'handled'
            $lastActive.Remove($acct) | Out-Null
        }
    }

    if ($cycle % $HeartbeatEvery -eq 0) {
        Rotate-LogIfNeeded
        $summary = ($seats | ForEach-Object { "$($_.Account)=$($state[$_.Account])" }) -join ', '
        if (-not $summary) { $summary = '(no seats found)' }
        Write-Log "Heartbeat: $($seats.Count) seat(s): $summary"
    }

    Start-Sleep -Seconds $PollSeconds
}

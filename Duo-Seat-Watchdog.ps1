<#
.SYNOPSIS
    Stops the idle game on a DuoStream seat once its Moonlight client has
    disconnected -- reclaiming the GPU without tearing down Sunshine.

.DESCRIPTION
    DuoStream (https://github.com/DuoStream/Duo) runs each streaming user as a
    real Windows RDP session with its own Sunshine instance. Sunshine has no
    idle/disconnect timeout, so a disconnected seat keeps the game running and
    the GPU busy indefinitely.

    This watchdog auto-discovers Duo seats from Duo's own *.conf files, watches
    each seat's Sunshine ports for an active stream, and when a seat has had no
    client for $GraceMinutes it acts according to -Mode:

      KillGpuApp (default) : use `nvidia-smi pmon` to find the high-GPU process
                             running IN THAT SEAT'S session and kill it, leaving
                             Sunshine (and the session) alive for an instant
                             reconnect. "Stop the game, keep the seat warm."
      Logoff               : log the seat's whole RDP session off (kills the game
                             AND that seat's Sunshine/desktop; Duo rebuilds it on
                             the next connect). Maximum power reclaimed.

    The seat's session is resolved by finding which process owns the seat's
    Sunshine port (robust; no dependency on quser or username matching). GPU load
    comes from nvidia-smi, so the AMD iGPU is ignored automatically. On this host
    the seat renders on the RTX 4090 and the console/Parsec desktop on the RTX
    5090, but the watchdog keys off the SESSION, not a fixed GPU index, so it
    stays correct regardless.

    Seats are re-discovered every poll cycle. Logging is durable and
    self-documenting: seat discovery, stream start/stop, every action, and WARN
    lines for edge cases. Watch the log to tune $GpuThreshold / $InfraNames.

    SAFETY: all actions are scoped to the seat's own RDP session (id > 1). The
    console session (physical monitor / Parsec, session 1) and any non-Duo
    session are never touched -- a game played locally or over Parsec (on the
    5090) is never killed.

    Run elevated / as SYSTEM.

.PARAMETER Mode
    'KillGpuApp' (default) or 'Logoff'.

.PARAMETER GraceMinutes
    Minutes with no active stream before acting. Default 5.

.PARAMETER GpuThreshold
    nvidia-smi sm% above which a seat-session process is treated as a game to
    kill. Default 15. Desktop idle reads 0 / '-'.

.PARAMETER InfraNames
    Process names never killed even if they use the GPU. Extend from the log.

.PARAMETER PollSeconds   Seconds between checks. Default 60.
.PARAMETER ConfigDir     Duo config dir with per-account *.conf files.
.PARAMETER LogFile       Activity log path.
.PARAMETER MaxLogMB      Rotate the log past this size. Default 5.
.PARAMETER WhatIf        Log intended actions without performing them.

.EXAMPLE
    .\Duo-Seat-Watchdog.ps1 -WhatIf -Verbose
.EXAMPLE
    .\Duo-Seat-Watchdog.ps1 -Mode Logoff -GraceMinutes 20
#>
[CmdletBinding()]
param(
    [ValidateSet('KillGpuApp','Logoff')]
    [string]   $Mode         = 'KillGpuApp',
    [int]      $GraceMinutes = 5,
    [int]      $GpuThreshold = 15,
    [string[]] $InfraNames   = @(
        'sunshine','Duo','DuoRdp','DuoManager','nvcontainer','NVDisplay.Container',
        'NVIDIA Overlay','NVIDIA Share','dwm','explorer','csrss','winlogon','fontdrvhost',
        'sihost','ctfmon','taskhostw','svchost','RuntimeBroker','SearchHost','ShellHost',
        'ShellExperienceHost','StartMenuExperienceHost','WWAHost','rdpclip','conhost',
        'dllhost','CrossDeviceResume','amd3dvcacheUser','tailscale-ipn','msedgewebview2',
        'TextInputHost','ApplicationFrameHost','SystemSettings','WidgetService','Widgets',
        'WmiPrvSE','WUDFHost','steam','steamwebhelper','chrome','msedge','RazerAppEngine'
    ),
    [int]      $PollSeconds  = 60,
    [string]   $ConfigDir    = 'C:\Program Files\Duo\config',
    [string]   $LogFile      = "$env:ProgramData\DuoSeatWatchdog\watchdog.log",
    [int]      $MaxLogMB     = 5,
    [switch]   $WhatIf
)

$logDir = Split-Path -Parent $LogFile
if ($logDir -and -not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

function Write-Log($msg) {
    $line = "{0}  {1}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $msg
    Add-Content -Path $LogFile -Value $line
    Write-Verbose $line
}

function Rotate-LogIfNeeded {
    if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length / 1MB -ge $MaxLogMB)) {
        Move-Item -Path $LogFile -Destination "$LogFile.1" -Force
        Write-Log "Log rotated (previous kept as $LogFile.1)."
    }
}

# Discover Duo seats (account name + Sunshine base port) from each *.conf
function Get-DuoSeats {
    Get-ChildItem $ConfigDir -Filter *.conf -ErrorAction SilentlyContinue | ForEach-Object {
        $c    = Get-Content $_.FullName
        $name = ($c | Where-Object { $_ -match '^\s*sunshine_name\s*=' }) -replace '.*=\s*',''
        $port = ($c | Where-Object { $_ -match '^\s*port\s*=' })          -replace '.*=\s*',''
        if ($name -and $port) { [pscustomobject]@{ Account = $name.Trim(); Base = [int]$port.Trim() } }
    }
}

# Live stream on this seat? Returns Active + Reason.
function Test-SeatActive($base) {
    $tcpPorts = @(($base - 5), $base, ($base + 1), ($base + 21))
    $tcp = Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalPort -in $tcpPorts -and $_.RemoteAddress -notin @('127.0.0.1','::1','0.0.0.0') } |
        Select-Object -First 1
    if ($tcp) { return [pscustomobject]@{ Active = $true; Reason = "TCP $($tcp.LocalPort)<-$($tcp.RemoteAddress):$($tcp.RemotePort)" } }
    $udp = Get-NetUDPEndpoint -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalPort -ge ($base + 5) -and $_.LocalPort -le ($base + 15) }
    if ($udp) { return [pscustomobject]@{ Active = $true; Reason = "UDP $((($udp.LocalPort | Sort-Object) -join ','))" } }
    return [pscustomobject]@{ Active = $false; Reason = 'no stream ports bound' }
}

# Resolve the seat's Windows session by finding who owns its Sunshine base port.
# Robust: no quser / no username matching. Refuses console/services (id <= 1).
function Get-SeatSession($base) {
    $conn = Get-NetTCPConnection -State Listen -LocalPort $base -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $conn) { return [pscustomobject]@{ Id = $null; Reason = "nothing listening on base port $base (Sunshine down?)"; Owner = '' } }
    $p = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
    if (-not $p) { return [pscustomobject]@{ Id = $null; Reason = "port $base owner pid $($conn.OwningProcess) not found"; Owner = '' } }
    $owner = "$($p.ProcessName)#$($p.Id)"
    $sid   = [int]$p.SessionId
    if ($sid -le 1) { return [pscustomobject]@{ Id = $null; Reason = "REFUSED: base-port owner $owner is in session $sid (console/services)"; Owner = $owner } }
    return [pscustomobject]@{ Id = $sid; Reason = "session $sid via $owner owning port $base"; Owner = $owner }
}

# Per-process NVIDIA sm% (max across GPUs and samples) via nvidia-smi pmon.
function Get-NvidiaSmLoad([int]$samples = 2) {
    $load  = @{}
    $lines = & nvidia-smi pmon -c $samples 2>$null
    foreach ($l in $lines) {
        # columns: gpuIdx  pid  type  sm  mem  enc  dec ...   ('-' when idle)
        if ($l -match '^\s*\d+\s+(\d+)\s+\S+\s+(\S+)') {
            $procId = [int]$matches[1]; $sm = $matches[2]
            if ($sm -match '^\d+$') {
                $v = [int]$sm
                if (-not $load.ContainsKey($procId) -or $v -gt $load[$procId]) { $load[$procId] = $v }
            }
        }
    }
    $load
}

# GPU-heavy, non-infra processes in a specific session, worst first.
function Get-SeatGpuApps($sessionId, $threshold, $infra) {
    (Get-NvidiaSmLoad 2).GetEnumerator() | ForEach-Object {
        $p = Get-Process -Id $_.Key -ErrorAction SilentlyContinue
        if ($p -and $_.Value -ge $threshold -and $p.SessionId -eq $sessionId -and ($infra -notcontains $p.ProcessName)) {
            [pscustomobject]@{ PidNum = $_.Key; Name = $p.ProcessName; Sm = $_.Value }
        }
    } | Sort-Object Sm -Descending
}

Rotate-LogIfNeeded
Write-Log "Watchdog started (mode=$Mode, grace=$GraceMinutes min, poll=$PollSeconds s, gpuThreshold=$GpuThreshold%, whatif=$($WhatIf.IsPresent))."
if ($Mode -eq 'KillGpuApp' -and -not (Get-Command nvidia-smi -ErrorAction SilentlyContinue)) {
    Write-Log "WARN: nvidia-smi not found -- KillGpuApp cannot detect games. Use -Mode Logoff or install the NVIDIA driver tools."
}

$lastActive = @{}   # account -> last time a stream was seen active
$state      = @{}   # account -> 'active' | 'idle' | 'handled'
$known      = @{}   # account -> base port (previous cycle)
$cycle      = 0
$HeartbeatEvery = [Math]::Max(1, [int](3600 / [Math]::Max(1, $PollSeconds)))

while ($true) {
    $cycle++
    $seats   = @(Get-DuoSeats)
    $current = @{}; foreach ($s in $seats) { $current[$s.Account] = $s.Base }

    foreach ($a in $current.Keys) {
        if (-not $known.ContainsKey($a)) { Write-Log "Seat discovered: '$a' (Sunshine base port $($current[$a]))." }
    }
    foreach ($a in @($known.Keys)) {
        if (-not $current.ContainsKey($a)) {
            Write-Log "Seat removed from config: '$a'."
            $lastActive.Remove($a) | Out-Null; $state.Remove($a) | Out-Null
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

        if ($state[$acct] -eq 'handled') { continue }

        if (-not $lastActive.ContainsKey($acct)) { $lastActive[$acct] = Get-Date }
        if ($state[$acct] -ne 'idle') {
            Write-Log "Seat '$acct' no client ($($probe.Reason)); grace countdown started ($GraceMinutes min)."
            $state[$acct] = 'idle'
        }

        $idleMin = [int](New-TimeSpan -Start $lastActive[$acct] -End (Get-Date)).TotalMinutes
        if ($idleMin -lt $GraceMinutes) { continue }

        # --- grace expired: act ---
        $r = Get-SeatSession $seat.Base
        if (-not $r.Id) {
            Write-Log "WARN: Seat '$acct' idle $idleMin min but cannot act -- $($r.Reason)."
        }
        elseif ($Mode -eq 'Logoff') {
            if ($WhatIf) { Write-Log "[WhatIf] Seat '$acct' idle $idleMin min -> would logoff $($r.Reason)." }
            else { Write-Log "Seat '$acct' idle $idleMin min -> logoff $($r.Reason)."; logoff $r.Id 2>$null }
        }
        else {  # KillGpuApp
            $apps = @(Get-SeatGpuApps $r.Id $GpuThreshold $InfraNames)
            if ($apps.Count -eq 0) {
                Write-Log "Seat '$acct' idle $idleMin min: no process >= $GpuThreshold% GPU in session $($r.Id); nothing to kill (Sunshine left running)."
            } else {
                foreach ($app in $apps) {
                    if ($WhatIf) {
                        Write-Log "[WhatIf] Seat '$acct' idle $idleMin min -> would kill '$($app.Name)' (pid $($app.PidNum), $($app.Sm)% GPU) in session $($r.Id)."
                    } else {
                        Write-Log "Seat '$acct' idle $idleMin min -> killing '$($app.Name)' (pid $($app.PidNum), $($app.Sm)% GPU) in session $($r.Id). Sunshine left running."
                        & taskkill /PID $app.PidNum /T /F 2>$null | Out-Null
                    }
                }
            }
        }
        $state[$acct] = 'handled'
        $lastActive.Remove($acct) | Out-Null
    }

    if ($cycle % $HeartbeatEvery -eq 0) {
        Rotate-LogIfNeeded
        $summary = ($seats | ForEach-Object { "$($_.Account)=$($state[$_.Account])" }) -join ', '
        if (-not $summary) { $summary = '(no seats found)' }
        Write-Log "Heartbeat: mode=$Mode, $($seats.Count) seat(s): $summary"
    }

    Start-Sleep -Seconds $PollSeconds
}

# Duo Seat Watchdog

Auto **log off idle [DuoStream](https://github.com/DuoStream/Duo) seats** to save power once their Moonlight client disconnects.

## The problem

DuoStream runs each streaming user as a real Windows RDP session with its own [Sunshine](https://github.com/LizardByte/Sunshine) instance. Sunshine has **no idle/disconnect timeout** ([DuoStream/Duo#186](https://github.com/DuoStream/Duo/issues/186)), so when a Moonlight client disconnects — network drop, closed lid, minimized client — the seat keeps the game running and the GPU busy **indefinitely**, burning power for nothing.

Sunshine's per-app `undo` / `prep-cmd` only fires on a clean *quit*, not on a *disconnect*, so it doesn't help here.

## What this does

A small PowerShell watchdog that:

1. **Auto-discovers** Duo seats from Duo's own `*.conf` files (account name + Sunshine base port).
2. **Watches** each seat's Sunshine ports for an active stream (established remote TCP on a control port, or bound UDP video/audio/control endpoints — Sunshine only binds these while streaming). This is input-independent, so it won't false-trigger during an input-less cutscene.
3. **Logs off** the seat's RDP session after a grace period (default **30 min**) with no active stream. Logging off terminates the game and frees the virtual display / GPU.

### Safety

It **only** logs off RDP sessions whose username matches a discovered Duo account. It **never** touches:

- the console session (physical monitor / Parsec — session 1),
- session 0 (services),
- any non-Duo RDP session (e.g. a work RDP login).

## Install

From an **elevated** PowerShell (logging off another user's session requires admin):

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-Task.ps1
```

This registers a SYSTEM scheduled task `DuoSeatWatchdog` that runs at startup, restarts on failure, and starts immediately. Activity is logged to `%ProgramData%\DuoSeatWatchdog\watchdog.log`.

### Options

```powershell
# Shorter grace period
powershell -ExecutionPolicy Bypass -File .\Install-Task.ps1 -GraceMinutes 15
```

## Test first (dry run)

Watch one cycle in a visible window without logging anyone off:

```powershell
.\Duo-Seat-Watchdog.ps1 -GraceMinutes 30 -WhatIf -Verbose
```

`-WhatIf` logs what it *would* do; drop it to arm for real.

## Uninstall

```powershell
Unregister-ScheduledTask -TaskName DuoSeatWatchdog -Confirm:$false
```

## Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `-GraceMinutes` | `30` | Minutes with no active stream before a seat is logged off |
| `-PollSeconds` | `60` | Seconds between checks |
| `-ConfigDir` | `C:\Program Files\Duo\config` | Duo per-account `*.conf` directory |
| `-LogFile` | `%ProgramData%\DuoSeatWatchdog\watchdog.log` | Activity log path |
| `-WhatIf` | off | Log intended logoffs without performing them |

## How seat detection works

For a seat with Sunshine base port `P` (from its `.conf`), the watchdog treats the seat as **streaming** if either:

- an **established** TCP connection from a non-loopback address exists on `P-5`, `P`, `P+1`, or `P+21` (HTTPS / HTTP / web / RTSP), or
- any **UDP endpoint** is bound in `P+5 .. P+15` (video / control / audio / mic).

When neither has been true for `GraceMinutes`, the seat's RDP session is logged off.

## Disclaimer

Provided as-is. Logging off a session force-closes everything running in it. Test with `-WhatIf` first, and confirm the account→session mapping matches your setup (`quser`).

## License

MIT

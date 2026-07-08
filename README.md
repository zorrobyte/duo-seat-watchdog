# Duo Seat Watchdog

When a [DuoStream](https://github.com/DuoStream/Duo) seat's Moonlight client disconnects, **stop the idle game and reclaim the GPU** — without tearing down Sunshine, so reconnects stay instant.

## The problem

DuoStream runs each streaming user as a real Windows RDP session with its own [Sunshine](https://github.com/LizardByte/Sunshine) instance. Sunshine has **no idle/disconnect timeout** ([DuoStream/Duo#186](https://github.com/DuoStream/Duo/issues/186)), so when a client disconnects — network drop, closed lid, minimized client — the seat keeps the game running and the GPU pinned **indefinitely**, burning power for nothing. Sunshine's per-app `undo`/`prep-cmd` only fires on a clean *quit*, not on a *disconnect*.

## What it does

A PowerShell watchdog that auto-discovers Duo seats from Duo's own `*.conf` files, watches each seat's Sunshine ports for an active stream, and after a grace period (default **30 min**) with no client, acts by **`-Mode`**:

| Mode | Behaviour |
|---|---|
| **`KillGpuApp`** (default) | Uses `nvidia-smi` to find the high-GPU process running **in that seat's session** and kills it (and its child processes). **Sunshine and the session stay alive** → instant reconnect. "Stop the game, keep the seat warm." |
| **`Logoff`** | Logs the seat's whole RDP session off — kills the game *and* that seat's Sunshine/desktop. Duo rebuilds the seat on the next connect. Maximum power reclaimed, slightly slower reconnect. |

### How detection works

- **Seat → session:** resolved by finding which process owns the seat's Sunshine port (`Get-NetTCPConnection`). No dependency on `quser` or username matching.
- **Active stream:** an established remote TCP connection on a control port, or bound UDP video/audio/control endpoints (Sunshine only binds these while streaming). Input-independent, so it won't false-trigger during a cutscene.
- **The game:** `nvidia-smi pmon` per-process `sm%`, filtered to the seat's session, above `-GpuThreshold` (default 15%), minus an infra denylist (Sunshine, dwm, nvcontainer, browsers, launchers…). Because it reads NVIDIA load, the AMD iGPU is ignored automatically.

> On a typical multi-GPU Duo box the seats render on one NVIDIA GPU and the console/Parsec desktop on another — but the watchdog keys off the **session**, not a fixed GPU index, so it stays correct either way.

### Safety

Every action is scoped to the seat's own RDP session (id > 1). It **never** touches:

- the **console session** (physical monitor / Parsec, session 1) — a game you play locally or over Parsec is never killed,
- session 0 (services),
- any non-Duo RDP session.

## Install

From an **elevated** PowerShell (acting on another session requires admin):

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-Task.ps1
```

Registers a SYSTEM scheduled task `DuoSeatWatchdog` that runs at startup, restarts on failure, and starts immediately. Logs to `%ProgramData%\DuoSeatWatchdog\watchdog.log`.

## Test first (dry run)

Watch a cycle without killing anything (force the action path with grace 0):

```powershell
.\Duo-Seat-Watchdog.ps1 -WhatIf -Verbose -GraceMinutes 0
```

`-WhatIf` logs what it *would* kill; drop it to arm for real.

## Logging (self-documenting)

Transition-based (not per-poll), so the log stays small and rotates at 5 MB. It records seat discovery/removal, stream ACTIVE / no-client transitions, every kill/logoff (with process name, PID, and `sm%`), an hourly heartbeat, and `WARN` lines for the edge cases that matter — a seat that couldn't be resolved to a session, or no GPU app found over threshold. Watch these in real use to tune `-GpuThreshold` / `-InfraNames` before adding more hardening.

## Uninstall

```powershell
Unregister-ScheduledTask -TaskName DuoSeatWatchdog -Confirm:$false
```

## Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `-Mode` | `KillGpuApp` | `KillGpuApp` (kill game, keep Sunshine) or `Logoff` (log off whole seat) |
| `-GraceMinutes` | `30` | Minutes with no active stream before acting |
| `-GpuThreshold` | `15` | `nvidia-smi` sm% above which a seat process is treated as a game |
| `-InfraNames` | (list) | Process names never killed even if they use the GPU |
| `-PollSeconds` | `60` | Seconds between checks |
| `-ConfigDir` | `C:\Program Files\Duo\config` | Duo per-account `*.conf` directory |
| `-LogFile` | `%ProgramData%\DuoSeatWatchdog\watchdog.log` | Activity log path |
| `-WhatIf` | off | Log intended actions without performing them |

## Requirements

- Windows, DuoStream installed, an NVIDIA GPU with `nvidia-smi` (bundled with the driver) for `KillGpuApp` mode. `Logoff` mode needs neither NVIDIA nor `nvidia-smi`.
- Runs as SYSTEM/admin.

## Disclaimer

Provided as-is. `KillGpuApp` force-kills the detected process tree; `Logoff` force-closes the whole session. Unsaved work in the seat is lost. Test with `-WhatIf` first.

## License

MIT

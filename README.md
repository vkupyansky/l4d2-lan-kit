# L4D2 LAN Kit [![Русский](https://img.shields.io/badge/README-Русский-blue)](README.ru.md)

A Windows dedicated server for relaxed Left 4 Dead 2 LAN co-op: two players, two survivor companions, and automatic campaign changes.

## Install

Requires Windows 10/11 x64, Windows PowerShell 5.1, a **Private** LAN, and internet. Use matching official Steam game versions; Mac players can use CrossOver.

1. Download this repository as a ZIP and extract it.
2. Open **Install.cmd** and approve administrator access. It downloads the official server and pinned dependencies, configures a restricted firewall rule, and creates a manual scheduled task.
3. Run **Start.cmd** after installation; installation does not start a session.

First run creates **kit.config.json** from `config.example.json`. Configure `ServerRoot`, `ListenIPv4`, `Port`, `StartMap`, `Hostname`, `Profile`, and `EnableKeepLaser` there. One Private LAN address is selected automatically; otherwise set `ListenIPv4`. Launchers do not change PowerShell execution policy.

## Play and manage

- **Start.cmd** starts the server; **Stop.cmd** ends the current session.
- **Check.cmd** checks nine required plugins, configuration/bot initialization, and fresh errors without changes.
- In each game's developer console: `connect <server-LAN-IP>:27016`.

Built-in LOCAL SERVICE keeps the server running after terminals or remote desktop close. Boot autostart and RCON are disabled. Launchers request administrator access. Reinstallation preserves edits and refuses conflicting unknown files.

Stop before editing gameplay overrides in `<ServerRoot>/left4dead2/cfg/server.cfg`. They apply after profile defaults; LAN-only, cheats-off, and RCON-off guards remain enforced.

## Gameplay

| Component | What it does |
|---|---|
| Left4Bots2 + Left4Lib | Survivor assistance: item pickup, transfers, defibrillators; full campaign automation is off. |
| ACS + Mission Manager + Changelevel | Cycles all 14 official campaigns after finales; no voting or skip after repeated failures. |
| Path To Goal | `!ptg` shows a route; `!ptg_menu` adjusts hints. |
| Item Hint | Shift+E or `!mark` marks items, enemies, or locations. |
| Weapon Drop | `!drop` drops the held weapon; secondary weapon dropping is blocked. |
| Keep Laser Sights (optional) | Transfers existing lasers when swapping guns. |
| Who Called the Horde | Names the player triggering supported horde events. |

Keep Laser Sights is **off by default**. Set `EnableKeepLaser` to `true` to download and compile its [official source](https://forums.alliedmods.net/attachment.php?attachmentid=200229&d=1681243413). On HTTP 403, save it as `runtime/downloads/l4d2_keeplasers.sp` and rerun Install.cmd; SHA is checked. Left4Bots2/Left4Lib download from authors.

Profile `casual`: Easy, 24 common infected, mobs of 8–24, mega mobs of 40, and Easy's 120–240-second interval. Body-shot damage factor is 1 instead of Easy's 2 for tougher common infected. Scripted events can override horde settings.

## Optional client changes and limits

[M4A1 ADS model](https://steamcommunity.com/sharedfiles/filedetails/?id=2972592952) replaces **M16 only**; [Weapon System](https://github.com/IA-NanaNana/l4d2-aim-down-sight) provides server-side ADS. [Vanilla+ Weapon Sounds](https://steamcommunity.com/sharedfiles/filedetails/?id=3567477734) changes audio. These packages are not included. Choose one model per weapon; M4 and the sound pack overlap in rifle sounds.

One tested Mac used 1800×1169, Wine graphics, MSync, and disabled in-game voice. Adapt to your display; 60–120 FPS is not guaranteed.

Progressive map unlocking and automatic chapter/equipment saves are unavailable. Restart uses `StartMap`. The existing LAN setup was tested; clean-machine installation remains unverified.

Developer check: `powershell.exe -NoProfile -File tests/Test-Validation.ps1` (or use `pwsh`).

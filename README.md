# L4D2 LAN Kit [![Русский](https://img.shields.io/badge/README-Русский-blue)](README.ru.md)

A Windows server kit for relaxed Left 4 Dead 2 LAN co-op: two players, two survivor companions, and all 14 official campaigns in sequence.

## Install

Requires Windows 10/11 x64, Windows PowerShell 5.1, a **Private** LAN, internet, and space for roughly **10 GB of server files**. Players install their own matching Steam game versions; Mac clients can use CrossOver.

1. Download this repository as a ZIP and extract it.
2. Open **Install.cmd** and approve administrator access. It downloads the official server through SteamCMD and pinned dependencies, then configures a restricted firewall rule and manual scheduled task.
3. Run **Start.cmd** after installation; installation does not start a session.

The ZIP contains setup files, sources, and configuration. The large game/server files are downloaded during installation and remain necessary to run the server.

First run creates **kit.config.json** from `config.example.json`. Edit it for the server folder, address, port, hostname, and starting chapter. One Private LAN address is selected automatically; otherwise set `ListenIPv4`.

## Play and manage

- **Start.cmd** starts the server; **Stop.cmd** ends the current session.
- **Check.cmd** checks required plugins, configuration/bot initialization, and fresh errors without changes.
- In each game's developer console: `connect <server-LAN-IP>:27016`.

An empty server waits for its first player before initializing the round.

The server runs under LOCAL SERVICE after terminals or remote desktop close. Boot autostart and RCON are disabled. Reinstallation preserves edits and refuses conflicting unknown files.

Stop before editing gameplay settings in `<ServerRoot>/left4dead2/cfg/server.cfg`. They override profile defaults; LAN-only, cheats-off, and RCON-off guards remain enforced. `StartMap` in `kit.config.json` selects the next starting chapter.

## Gameplay

| Component | What it does |
|---|---|
| Left4Bots2 + Left4Lib | Survivor assistance: item pickup, transfers, defibrillators; full campaign automation is off. |
| ACS + Mission Manager + Changelevel | Default start: No Mercy. Cycles all 14 official campaigns after finales; no voting or skip after repeated failures. |
| LAN Horde Limits | Applies the horde profile to supported scripted events without changing bosses or finale stages. |
| Path To Goal | `!ptg` shows a route; `!ptg_menu` adjusts hints. |
| Item Hint | Shift+E or `!mark` marks items, enemies, or locations. |
| Weapon Drop | `!drop` drops the held weapon; secondary weapon dropping is blocked. |
| Keep Laser Sights (optional) | Transfers existing lasers when swapping guns. |
| Who Called the Horde | Names the player triggering supported horde events. |

Keep Laser Sights is **off by default**. Set `EnableKeepLaser` to `true` to download and compile its [official source](https://forums.alliedmods.net/attachment.php?attachmentid=200229&d=1681243413). On HTTP 403, save it as `runtime/downloads/l4d2_keeplasers.sp` and rerun Install.cmd; SHA is checked. Left4Bots2/Left4Lib download from authors.

Profile `casual`: **Easy**, 18 common infected, mobs of **6–18**, mega mobs of **30**, and Easy's 120–240-second interval. Body-shot damage factor is 1 instead of Easy's 2 for tougher common infected.

LAN Horde Limits uses Left4DHooks 1.174 to cap supported positive `DirectorOptions` values and set scripted spawn timer floors to 6/10 seconds. Missing, zero, and negative values, bosses, special infected, and finale stages remain unchanged.

If companions stop following, type these messages in the game chat, without `!`:

```text
bots cancel all
bots follow
```

## Limits

Included server mods work with unmodified clients. Weapon models and sound replacements are separate client add-ons and are not included. The Weapon System ADS plugin is not installed.

Progressive map unlocking and automatic chapter/equipment saves are unavailable. Restart uses `StartMap`.

Tested on Windows PowerShell 5.1: 57 isolated checks; installation and reinstallation with SteamCMD-validated official cached content, preserving user settings; start, repeated start, check, stop, restart, and LAN response. Clean-OS installation and a new two-client gameplay session remain unverified.

Developer check: **Test.cmd** runs isolated configuration, package integrity, and installation recovery tests.

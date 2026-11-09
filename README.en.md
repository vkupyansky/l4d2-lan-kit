# L4D2 LAN Kit

A Windows server kit for relaxed Left 4 Dead 2 LAN co-op: two players, two survivor companions, and all 14 official campaigns in sequence.

[Русский](README.md) · **[Download v0.2.0](https://github.com/vkupyansky/l4d2-lan-kit/releases/download/v0.2.0/L4D2-LAN-Kit-v0.2.0.zip)** · [All releases](https://github.com/vkupyansky/l4d2-lan-kit/releases)

## Features

| Component | What it does |
| --- | --- |
| Left4Bots2 + Left4Lib | Survivor assistance: item pickup, transfers and defibrillators. Full campaign automation is off. |
| ACS + Mission Manager + Changelevel | Starts with No Mercy and cycles all 14 official campaigns, without voting or skipping after repeated failures. |
| LAN Horde Limits | Applies the horde profile to supported scripted events while preserving bosses and finale stages. |
| Path To Goal | `!ptg` shows a route; `!ptg_menu` adjusts hints. |
| Item Hint | Shift+E or `!mark` marks items, enemies or locations. |
| Weapon Drop | `!drop` drops the held weapon; secondary weapon dropping is blocked. |
| Keep Laser Sights | Optional transfer of existing lasers when swapping guns. |
| Who Called the Horde | Names the player triggering supported horde events. |

Profile `casual`: Easy, 18 common infected, regular hordes of 6–18, large hordes of 30, and Easy's 120–240-second interval. Body-shot damage factor is 1 instead of Easy's 2, making common infected tougher.

LAN Horde Limits uses Left4DHooks 1.174 to cap supported positive `DirectorOptions` values and set scripted spawn timer floors to 6/10 seconds. Missing, zero and negative values, bosses, special infected and finale stages remain unchanged.

## Install and run

Requires Windows 10/11 x64, Windows PowerShell 5.1, a Private LAN, internet, and roughly 10 GB of server space. Players install matching Steam game versions separately. Mac clients can use CrossOver.

1. Download the kit above and extract the ZIP.
2. Open **Install.cmd** and approve administrator access. It downloads the official server through SteamCMD and pinned dependencies, then configures a restricted firewall rule and a manual scheduled task.
3. Open **Start.cmd**. Installation does not start a session.
4. In each game's developer console, enter `connect <server-LAN-IP>:27016`.

The ZIP contains setup files, sources and configuration. Large game/server files are downloaded during installation and remain necessary. First installation creates `kit.config.json` from [config.example.json](config.example.json): server folder, address, port, hostname and starting chapter. One Private LAN address is selected automatically; otherwise set `ListenIPv4`.

## Usage

- **Start.cmd** starts the server; **Stop.cmd** ends the current session.
- **Check.cmd** checks required plugins, configuration/bot initialization and fresh errors without changes.
- An empty server waits for its first player before initializing the round.

The server runs under LOCAL SERVICE after terminals or remote desktop close. Boot autostart and RCON are disabled. Reinstallation preserves settings and refuses conflicting unknown files.

Stop before editing gameplay settings. `<ServerRoot>/left4dead2/cfg/server.cfg` overrides profile defaults; LAN-only, cheats-off and RCON-off guards remain enforced. `StartMap` in `kit.config.json` selects the next starting chapter.

Keep Laser Sights is off by default. Set `"EnableKeepLaser": true` to download and compile its [official source](https://forums.alliedmods.net/attachment.php?attachmentid=200229&d=1681243413). On HTTP 403, save it as `runtime/downloads/l4d2_keeplasers.sp` and rerun Install.cmd; SHA is checked. Left4Bots2/Left4Lib also download from their authors.

If companions stop following, send these messages in game chat, without `!`:

```text
bots cancel all
bots follow
```

## Checks

```powershell
.\Test.cmd
```

Isolated checks cover configuration, package integrity and installation recovery. They do not replace a new gameplay session.

## Limitations

Server mods work with unmodified clients. Weapon models and replacement sounds are separate client add-ons and are not included. Weapon System ADS is not installed. Progressive map unlocking and automatic chapter/equipment saves are unavailable; restart uses `StartMap`.

Verified on Windows PowerShell 5.1: 57 isolated checks, installation/reinstallation preserving settings, start, repeated start, Check, stop, restart and LAN response. Official cached content was validated by SteamCMD. Clean-OS installation and a new two-client session remain unverified.

## Documentation

- [Configuration template](config.example.json).
- [Dependency versions, sources and SHA-256](metadata/dependencies.json), [package manifest](metadata/bundle.json).

## License

The independent installer, LAN Horde Limits, templates and documentation use [MIT](LICENSE). Third-party components keep their own terms; authorship, GPL sources and distribution exclusions are documented in [THIRD_PARTY.md](THIRD_PARTY.md). Game files are licensed separately.

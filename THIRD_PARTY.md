# Third-party components

The [MIT license](LICENSE) covers L4D2 LAN Kit's independent installer code, LAN Horde Limits plugin, templates, and documentation. The plugin's [source](assets/overlay/left4dead2/addons/sourcemod/scripting/l4d2_lan_horde_limits.sp) carries an MIT SPDX identifier and uses the bundled Left4DHooks API. Third-party components and derivative changes retain their original licenses and credits. MIT does not cover game content or third-party add-ons.

Pinned versions, source URLs, and SHA-256 hashes are recorded in [metadata/dependencies.json](metadata/dependencies.json) and [metadata/bundle.json](metadata/bundle.json). A public repository alone does not grant redistribution rights; see [GitHub's licensing guidance](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/licensing-a-repository).

## Bundled GPL source

The following source, required includes, gamedata, and translations may be bundled under their respective GPL terms. SMX files are compiled locally with the pinned official SourcePawn compiler; precompiled SMX files are not included in this source bundle.

| Component and original authors | License and primary evidence |
| --- | --- |
| Left4DHooks — Silvers and contributors | GPL-3.0; [pinned LICENSE](https://github.com/SilvDev/Left4DHooks/blob/bbae91ec596d042e4b092c4f28deab4f0ed9284d/LICENSE). |
| Path To Goal — gvazdas, zyiks | GPL-3.0-or-later in the [source header](https://codeberg.org/gvazdas/l4d2_zombie_master/src/commit/3a6a451bc560beda31f18e77f99d20f8d210a666/left4dead2/addons/sourcemod/scripting/l4d_path_to_goal.sp). Included library notices are preserved. |
| Item Hint — BHaType, fdxx, HarryPotter | GPL-3.0; repository [LICENSE](https://github.com/fbef0102/L4D1_2-Plugins/blob/5df7a57cf18c97b7fbc5a8f6626b41ca2a9acc76/LICENSE) and explicit project-wide licensing statement in the [author's README](https://github.com/fbef0102/L4D1_2-Plugins/blob/5df7a57cf18c97b7fbc5a8f6626b41ca2a9acc76/README.md). |
| Weapon Drop — Machine, dcx2, Electr000999 /z, Senip, Shao, NoroHime, HarryPotter | GPL-3.0 under the same [repository LICENSE](https://github.com/fbef0102/L4D1_2-Plugins/blob/5df7a57cf18c97b7fbc5a8f6626b41ca2a9acc76/LICENSE). Original author lists remain in the source. |
| Who Called the Horde / Trigger Horde Notify — HarryPotter and credited contributors | GPL-3.0 under the [author's repository LICENSE](https://github.com/fbef0102/L4D1_2-Plugins/blob/5df7a57cf18c97b7fbc5a8f6626b41ca2a9acc76/LICENSE). The manifests identify the exact source and version. |
| Use Priority Patch 2.6 — Silvers / SilverShot | GPL-3.0-or-later in the [official source attachment](https://forums.alliedmods.net/attachment.php?attachmentid=188692&d=1714942373); matching [gamedata](https://forums.alliedmods.net/attachment.php?attachmentid=183778&d=1714942373). The author's [repository LICENSE](https://github.com/SilvDev/Use_Priority_Patch/blob/1c63929f547372de4cb8153f58ad96233e553666/LICENSE) is GPL-3.0, but its older 2.5 source is not substituted for 2.6. |
| Multi-Colors, Colors / More Colors — Bara, exvel, Dr. McKay, Popoklopsi, Powerlord, srcdslab and contributors | GPL-3.0; [Bara LICENSE](https://github.com/Bara/Multi-Colors/blob/master/LICENSE) and [srcdslab LICENSE](https://github.com/srcdslab/sm-plugin-MultiColors/blob/master/LICENSE). Credits and notices in the includes are preserved. |

Each bundled component retains the full applicable GPL text, corresponding source, and build dependencies, as required by [SourceMod's licensing terms](https://www.sourcemod.net/license.php). Modified files and translations identify the changes and date without replacing original authorship. Any future binary release must include its corresponding source package and build instructions.

The bundled `left4dhooks.inc` has wording-only comment edits dated 2026-11-01; executable code, copyright notices, and license notices are unchanged.

The bundled Item Hint source removes an upstream account-specific connection ban. This change is marked 2026-11-08; original authorship and GPL terms are preserved.

## Downloaded from original publishers

These archives are not mirrored in this repository or its GitHub Releases. Installation downloads pinned originals and preserves their notices.

| Component | License or distribution policy |
| --- | --- |
| SteamCMD and Left 4 Dead 2 dedicated server, app 222860 | Valve software, separate from this project's license. Game/server files are obtained through [official SteamCMD](https://developer.valvesoftware.com/wiki/SteamCMD). |
| Metamod:Source | zLib/libpng; [official LICENSE](https://github.com/alliedmodders/metamod-source/blob/1.11-dev/LICENSE.txt). Original archives come from [official downloads](https://www.sourcemm.net/downloads.php). |
| SourceMod, SourcePawn, standard extensions | GPL-3.0 with exceptions and component-specific notices; [official terms](https://www.sourcemod.net/license.php). The [official archive](https://www.sourcemod.net/downloads.php) supplies the compiler and LICENSE.txt. |
| Left 4 Bots 2 / Left 4 Lib — smilzo | No separate redistribution license was found in the reviewed releases. VPK files and source are not mirrored; installation uses original [Left4Bots releases](https://github.com/smilz0/Left4Bots/releases) and [Left4Lib releases](https://github.com/smilz0/Left4Lib/releases). |
| ACS / Mission Manager — Rikka0w0, Chris Pringle; Changelevel — LuxLuma | No repository-wide license was found for the complete ACS archive. Download the [original v2.3.0 release](https://github.com/rikka0w0/l4d2_mission_manager/releases/tag/v2.3.0). Its separate Changelevel component has a [GPL-3.0-or-later source header](https://github.com/rikka0w0/l4d2_mission_manager/blob/e3fa1b464740769991fee035f16465f4b8c57cad/scripting/l4d2_changelevel.sp); that does not license the entire ACS package. |
| Keep Laser Sights 1.4 — dcx2, Mr. Zero, SilverShot, In1ernal Error | No separate redistribution grant was found in the [reviewed original source](https://forums.alliedmods.net/attachment.php?attachmentid=200229&d=1681243413). Original/modified source and SMX are not bundled. Optional installation uses the [author's download](https://forums.alliedmods.net/showthread.php?t=173749) or a user-provided original verified by SHA-256. A blocked download is reported rather than replaced with an unofficial mirror. |

## Excluded from public distribution

- Closed-source ADS 1.1 / `l4d2_weapon_system`: the [author's repository](https://github.com/IA-NanaNana/l4d2-aim-down-sight) provides neither plugin source nor an explicit redistribution license. This plugin is not installed or redistributed.
- Weapon models, animations, materials, and replacement sounds, including modified third-party VPKs. No verified redistribution grant covers these optional client add-ons in this project.
- Game distributions, game DLL/VPK files, third-party Windows client builds, Steam-emulation libraries, account files, credentials, personal settings, private network details, local logs, dumps, and machine-specific test results.

Names and trademarks belong to their respective owners. L4D2 LAN Kit is an independent installation kit, not an official Valve or third-party author product.

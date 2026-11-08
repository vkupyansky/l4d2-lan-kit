// SPDX-License-Identifier: MIT
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <left4dhooks>

public Plugin myinfo =
{
    name = "L4D2 LAN Horde Limits",
    author = "L4D2 LAN Kit",
    description = "Applies the LAN horde profile to existing Director script values",
    version = "1.0.0",
    url = ""
};

enum HordeOption
{
    Option_None,
    Option_Common,
    Option_MobMin,
    Option_MobMax,
    Option_Mega,
    Option_SpawnMinTime,
    Option_SpawnMaxTime
}

ConVar g_Common;
ConVar g_MobMin;
ConVar g_MobMax;
ConVar g_Mega;
ConVar g_Mode;
int g_CommonLimit;
int g_MobMinSize;
int g_MobMaxSize;
int g_MegaSize;
bool g_Ready;
bool g_Coop;

public void OnPluginStart()
{
    if (GetEngineVersion() != Engine_Left4Dead2)
        SetFailState("This plugin requires Left 4 Dead 2.");

    g_Common = RequireConVar("z_common_limit");
    g_MobMin = RequireConVar("z_mob_spawn_min_size");
    g_MobMax = RequireConVar("z_mob_spawn_max_size");
    g_Mega = RequireConVar("z_mega_mob_size");
    g_Mode = RequireConVar("mp_gamemode");
    g_Common.AddChangeHook(OnProfileChanged);
    g_MobMin.AddChangeHook(OnProfileChanged);
    g_MobMax.AddChangeHook(OnProfileChanged);
    g_Mega.AddChangeHook(OnProfileChanged);
    g_Mode.AddChangeHook(OnProfileChanged);
}

public void OnAllPluginsLoaded()
{
    if (Left4DHooks_Version() < 1174)
        SetFailState("Left4DHooks 1.174 or newer is required.");
}

public void OnMapStart()
{
    g_Ready = false;
}

public void OnMapEnd()
{
    g_Ready = false;
}

public void OnConfigsExecuted()
{
    RefreshProfile();
    g_Ready = true;
    PrintToServer("[LAN HORDE] coop=%d common=%d mob=%d-%d mega=%d; scripted timer floors=6/10 seconds",
        g_Coop, g_CommonLimit, g_MobMinSize, g_MobMaxSize, g_MegaSize);
}

public void OnProfileChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    if (g_Ready)
        RefreshProfile();
}

ConVar RequireConVar(const char[] name)
{
    ConVar convar = FindConVar(name);
    if (convar == null)
        SetFailState("Required game convar is missing: %s", name);
    return convar;
}

void RefreshProfile()
{
    g_CommonLimit = g_Common.IntValue;
    g_MobMinSize = g_MobMin.IntValue;
    g_MobMaxSize = g_MobMax.IntValue;
    g_MegaSize = g_Mega.IntValue;
    if (g_CommonLimit <= 0 || g_MobMinSize <= 0 || g_MobMaxSize < g_MobMinSize || g_MegaSize <= 0)
        SetFailState("Horde profile requires positive common/mob/mega values and mob min <= max.");

    char mode[32];
    g_Mode.GetString(mode, sizeof(mode));
    g_Coop = StrEqual(mode, "coop");
}

HordeOption FindOption(const char[] key)
{
    if (StrEqual(key, "CommonLimit") || StrEqual(key, "HordeEscapeCommonLimit"))
        return Option_Common;
    if (StrEqual(key, "MobMinSize"))
        return Option_MobMin;
    if (StrEqual(key, "MobMaxSize") || StrEqual(key, "MobMaxPending") || StrEqual(key, "MobSpawnSize"))
        return Option_MobMax;
    if (StrEqual(key, "MegaMobSize"))
        return Option_Mega;
    if (StrEqual(key, "MobSpawnMinTime"))
        return Option_SpawnMinTime;
    if (StrEqual(key, "MobSpawnMaxTime"))
        return Option_SpawnMaxTime;
    return Option_None;
}

int GetBound(HordeOption option)
{
    switch (option)
    {
        case Option_Common: return g_CommonLimit;
        case Option_MobMin: return g_MobMinSize;
        case Option_MobMax: return g_MobMaxSize;
        case Option_Mega: return g_MegaSize;
        case Option_SpawnMinTime: return 6;
        case Option_SpawnMaxTime: return 10;
    }
    return 0;
}

bool NeedsChange(HordeOption option, float value, int bound)
{
    if (option == Option_SpawnMinTime || option == Option_SpawnMaxTime)
        return value < float(bound);
    return value > float(bound);
}

bool IsDirectorOptions(int scope)
{
    if (scope == 0 || scope == -1)
        return false;
    // BeginScript may replace this table, so resolve its handle for each query
    int directorScope = L4D2_GetDirectorScriptScope(4);
    return directorScope != 0 && directorScope != -1 && scope == directorScope;
}

public Action L4D2_OnGetScriptValueInt(const char[] key, int &retVal, int hScope)
{
    if (!g_Ready || !g_Coop || retVal <= 0)
        return Plugin_Continue;
    HordeOption option = FindOption(key);
    if (option == Option_None)
        return Plugin_Continue;
    int bound = GetBound(option);
    if (!NeedsChange(option, float(retVal), bound) || !IsDirectorOptions(hScope))
        return Plugin_Continue;
    retVal = bound;
    return Plugin_Handled;
}

public Action L4D2_OnGetScriptValueFloat(const char[] key, float &retVal, int hScope)
{
    if (!g_Ready || !g_Coop || !(retVal > 0.0))
        return Plugin_Continue;
    HordeOption option = FindOption(key);
    if (option == Option_None)
        return Plugin_Continue;
    int bound = GetBound(option);
    if (!NeedsChange(option, retVal, bound) || !IsDirectorOptions(hScope))
        return Plugin_Continue;
    retVal = float(bound);
    return Plugin_Handled;
}

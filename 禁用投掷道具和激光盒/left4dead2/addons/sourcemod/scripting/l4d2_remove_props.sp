#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#define PLUGIN_VERSION "1.0.0"
#define MODEL_GASCAN "models/props_junk/gascan001a.mdl"
#define MODEL_PROPANE "models/props_junk/propanecanister001a.mdl"
#define MODEL_OXYGEN "models/props_equipment/oxygentank01.mdl"
#define MODEL_LASER "models/w_models/weapons/w_laser_sights.mdl"

public Plugin myinfo =
{
    name = "L4D2 Remove Props",
    author = "Codex",
    description = "Removes gas cans, propane tanks, oxygen tanks and laser sight boxes.",
    version = PLUGIN_VERSION,
    url = ""
};

ConVar g_Enabled;
ConVar g_Gascan;
ConVar g_Propane;
ConVar g_Oxygen;
ConVar g_Laser;
ConVar g_KeepScavenge;
bool g_MapReady;
bool g_ConfigReady;
int g_MapSerial;
int g_Removed;

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int errMax)
{
    if (GetEngineVersion() != Engine_Left4Dead2)
    {
        strcopy(error, errMax, "This plugin only supports Left 4 Dead 2.");
        return APLRes_SilentFailure;
    }
    return APLRes_Success;
}

public void OnPluginStart()
{
    CreateConVar("l4d2_remove_props_version", PLUGIN_VERSION, "Plugin version", FCVAR_NOTIFY | FCVAR_DONTRECORD);
    g_Enabled = CreateConVar("l4d2_remove_props_enable", "1", "Enable removal of selected world items", FCVAR_NONE, true, 0.0, true, 1.0);
    g_Gascan = CreateConVar("l4d2_remove_props_gascan", "1", "Remove portable gas cans", FCVAR_NONE, true, 0.0, true, 1.0);
    g_Propane = CreateConVar("l4d2_remove_props_propane", "1", "Remove propane tanks", FCVAR_NONE, true, 0.0, true, 1.0);
    g_Oxygen = CreateConVar("l4d2_remove_props_oxygen", "1", "Remove oxygen tanks", FCVAR_NONE, true, 0.0, true, 1.0);
    g_Laser = CreateConVar("l4d2_remove_props_laser", "1", "Remove laser sight boxes", FCVAR_NONE, true, 0.0, true, 1.0);
    g_KeepScavenge = CreateConVar("l4d2_remove_props_keep_scavenge", "1", "Keep objective gas cans (nonzero skin). 0 may make finales/scavenge impossible", FCVAR_NONE, true, 0.0, true, 1.0);

    g_Enabled.AddChangeHook(OnSettingChanged);
    g_Gascan.AddChangeHook(OnSettingChanged);
    g_Propane.AddChangeHook(OnSettingChanged);
    g_Oxygen.AddChangeHook(OnSettingChanged);
    g_Laser.AddChangeHook(OnSettingChanged);
    g_KeepScavenge.AddChangeHook(OnSettingChanged);
    AutoExecConfig(true, "l4d2_remove_props");

    HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
    RegAdminCmd("sm_removeprops_status", Command_Status, ADMFLAG_GENERIC, "Show item removal settings and count.");

    // Late load: attach to existing entities as well as future creations.
    // Actual cleanup waits for OnConfigsExecuted, including the saved policy.
    for (int entity = MaxClients + 1; entity < GetMaxEntities(); entity++)
    {
        if (!IsValidEntity(entity))
            continue;
        char classname[64];
        GetEntityClassname(entity, classname, sizeof(classname));
        OnEntityCreated(entity, classname);
    }
}

public void OnMapStart()
{
    g_MapSerial++;
    g_MapReady = true;
    g_ConfigReady = false;
    g_Removed = 0;
    // Also catches models/skins assigned later and props changed by scripts.
    CreateTimer(2.0, Timer_Sweep, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public void OnMapEnd()
{
    g_MapReady = false;
    g_ConfigReady = false;
    g_MapSerial++;
}

public void OnConfigsExecuted()
{
    g_ConfigReady = true;
    RequestFrame(Frame_Sweep, g_MapSerial);
}

public void OnSettingChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    RequestFrame(Frame_Sweep, g_MapSerial);
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    RequestFrame(Frame_Sweep, g_MapSerial);
}

bool IsActive()
{
    return g_MapReady && g_ConfigReady && g_Enabled.BoolValue;
}

bool IsCandidate(const char[] classname)
{
    return StrEqual(classname, "weapon_gascan")
        || StrEqual(classname, "weapon_gascan_spawn")
        || StrEqual(classname, "weapon_propanetank")
        || StrEqual(classname, "weapon_oxygentank")
        || StrEqual(classname, "weapon_spawn")
        || StrEqual(classname, "upgrade_laser_sight")
        || StrEqual(classname, "upgrade_spawn")
        || StrContains(classname, "prop_physics") == 0;
}

public void OnEntityCreated(int entity, const char[] classname)
{
    if (entity <= MaxClients || !IsCandidate(classname))
        return;

    SDKHook(entity, SDKHook_SpawnPost, OnItemSpawned);
    SDKHook(entity, SDKHook_Use, OnItemUse);
    SDKHook(entity, SDKHook_Touch, OnItemTouch);
}

public void OnItemSpawned(int entity)
{
    // Do not delete inside Spawn: the engine/calling plugin may still use it.
    // A serialised reference prevents deleting a reused entity index.
    RequestFrame(Frame_CheckItem, EntIndexToEntRef(entity));
}

public Action OnItemUse(int entity, int activator, int caller, UseType type, float value)
{
    return (IsActive() && ShouldRemove(entity)) ? Plugin_Handled : Plugin_Continue;
}

public Action OnItemTouch(int entity, int other)
{
    return (IsActive() && ShouldRemove(entity)) ? Plugin_Handled : Plugin_Continue;
}

public void Frame_CheckItem(any reference)
{
    if (!IsActive())
        return;
    int entity = EntRefToEntIndex(reference);
    if (entity != INVALID_ENT_REFERENCE && IsValidEntity(entity))
        RemoveBlockedItem(entity);
}

public void Frame_Sweep(any serial)
{
    if (serial == g_MapSerial && IsActive())
        SweepWorld();
}

public Action Timer_Sweep(Handle timer)
{
    if (IsActive())
        SweepWorld();
    return Plugin_Continue;
}

void SweepWorld()
{
    for (int entity = MaxClients + 1; entity < GetMaxEntities(); entity++)
    {
        if (IsValidEntity(entity))
            RemoveBlockedItem(entity);
    }
}

bool ShouldRemoveGascan(int entity)
{
    if (!g_Gascan.BoolValue)
        return false;
    // Stock objective cans use nonzero skins. Custom maps can use their own
    // quest logic, so skin detection cannot guarantee every custom objective.
    if (g_KeepScavenge.BoolValue && HasEntProp(entity, Prop_Send, "m_nSkin")
        && GetEntProp(entity, Prop_Send, "m_nSkin") != 0)
        return false;
    return true;
}

bool ShouldRemove(int entity)
{
    char classname[64];
    GetEntityClassname(entity, classname, sizeof(classname));
    if (!IsCandidate(classname))
        return false;

    if (StrEqual(classname, "weapon_gascan") || StrEqual(classname, "weapon_gascan_spawn"))
        return ShouldRemoveGascan(entity);
    if (StrEqual(classname, "weapon_propanetank"))
        return g_Propane.BoolValue;
    if (StrEqual(classname, "weapon_oxygentank"))
        return g_Oxygen.BoolValue;
    if (StrEqual(classname, "upgrade_laser_sight"))
        return g_Laser.BoolValue;

    // A carryable item can be a physics prop instead of a weapon entity.
    // Match the complete model path; do not remove arbitrary physics props.
    if (!HasEntProp(entity, Prop_Data, "m_ModelName"))
        return false;
    char model[PLATFORM_MAX_PATH];
    GetEntPropString(entity, Prop_Data, "m_ModelName", model, sizeof(model));
    ReplaceString(model, sizeof(model), "\\", "/");
    if (StrEqual(model, MODEL_GASCAN, false))
        return ShouldRemoveGascan(entity);
    if (StrEqual(model, MODEL_PROPANE, false)
        || StrEqual(model, "models/props_junk/propanecanister001.mdl", false))
        return g_Propane.BoolValue;
    if (StrEqual(model, MODEL_OXYGEN, false))
        return g_Oxygen.BoolValue;
    if (StrEqual(model, MODEL_LASER, false))
        return g_Laser.BoolValue;

    // Mixed upgrade_spawn/item spawners are left intact. Their resulting
    // upgrade_laser_sight entities are intercepted independently, keeping
    // incendiary and explosive ammo available at the same spawn points.
    return false;
}

void RemoveBlockedItem(int entity)
{
    if (!ShouldRemove(entity))
        return;
    // Hot-loading should not invalidate a player's active carried weapon.
    // It will be caught after being dropped or converted to a physics prop.
    if (HasEntProp(entity, Prop_Send, "m_hOwnerEntity"))
    {
        int owner = GetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity");
        if (owner >= 1 && owner <= MaxClients && IsClientInGame(owner))
            return;
    }
    RemoveEntity(entity);
    g_Removed++;
}

public Action Command_Status(int client, int args)
{
    ReplyToCommand(client, "[RemoveProps] active=%d, gascan=%d, propane=%d, oxygen=%d, laser=%d, keep_objective=%d, removed_this_map=%d",
        IsActive(), g_Gascan.BoolValue, g_Propane.BoolValue, g_Oxygen.BoolValue,
        g_Laser.BoolValue, g_KeepScavenge.BoolValue, g_Removed);
    return Plugin_Handled;
}

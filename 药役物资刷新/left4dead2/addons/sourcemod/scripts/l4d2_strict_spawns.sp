#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#define PLUGIN_VERSION "1.1.0"
#define ENTITY_LIMIT 2049
#define PILL_BUDGET 2
#define MAX_GUN_STATIONS 5
#define WEAPON_ID_CHAINSAW 20

public Plugin myinfo =
{
    name = "L4D2 Strict Map Spawns",
    author = "Codex",
    description = "Two pills, at most five two-gun stations per round, and no chainsaw spawns.",
    version = PLUGIN_VERSION,
    url = ""
};

// SG552 belongs to the requested SMG group, despite being a rifle in the game.
static const char SMG_SPAWNS[][] =
{
    "weapon_smg_silenced_spawn",
    "weapon_smg_spawn",
    "weapon_smg_mp5_spawn",
    "weapon_rifle_sg552_spawn"
};
static const char SHOTGUN_SPAWNS[][] =
{
    "weapon_pumpshotgun_spawn",
    "weapon_shotgun_chrome_spawn"
};
static const char FIREARMS[][] =
{
    "weapon_smg_silenced", "weapon_smg", "weapon_smg_mp5",
    "weapon_rifle_sg552", "weapon_pumpshotgun", "weapon_shotgun_chrome",
    "weapon_pistol", "weapon_pistol_magnum", "weapon_autoshotgun",
    "weapon_shotgun_spas", "weapon_rifle", "weapon_rifle_ak47",
    "weapon_rifle_desert", "weapon_hunting_rifle", "weapon_sniper_military",
    "weapon_sniper_awp", "weapon_sniper_scout", "weapon_rifle_m60",
    "weapon_grenade_launcher"
};
static const char FORBIDDEN_SUPPLIES[][] =
{
    "weapon_molotov", "weapon_pipe_bomb", "weapon_vomitjar",
    "weapon_first_aid_kit", "weapon_adrenaline"
};
static const char PRECACHE_WEAPONS[][] =
{
    "weapon_smg_silenced", "weapon_smg", "weapon_smg_mp5",
    "weapon_rifle_sg552", "weapon_pumpshotgun", "weapon_shotgun_chrome",
    "weapon_pain_pills"
};

enum ItemKind
{
    Item_Ignore,
    Item_Gun,
    Item_Pills,
    Item_Medicine,
    Item_Throwable,
    Item_Blocked
};

enum struct SpawnPoint
{
    float origin[3];
    float angles[3];
    int station; // Startup candidate-group marker, not an index into g_Stations.
}

enum struct GunStation
{
    float first[3];
    float second[3];
    float firstAngles[3];
    float secondAngles[3];
    int smg;
    int shotgun;
    int firstRef;
    int secondRef;
    // These are lifetime flags, NOT entity-existence checks. Empty stations
    // must not be replenished after all their pickups have been used.
    bool firstIssued;
    bool secondIssued;
}

ArrayList g_GunPoints;
ArrayList g_PillPoints;
ArrayList g_MedicinePoints;
ArrayList g_Stations;
ConVar g_Radius;
ConVar g_Height;
ConVar g_WeaponCount;
Handle g_InitTimer;
Handle g_MaintenanceTimer;
bool g_Active;
bool g_Ready;
bool g_Creating;
bool g_LateLoad;
bool g_MapReady;
bool g_StartPending;
int g_Generation;
int g_PillsIssued;
int g_Removed;
int g_RetryTicks;
float g_StationRadius;
float g_StationHeight;
int g_PickupCount;
int g_PillRefs[PILL_BUDGET];
float g_PillPositions[PILL_BUDGET][3];

// Indices are reset on every creation. Deferred work always uses serialised
// entity references, so reusing an edict cannot delete an unrelated entity.
bool g_Managed[ENTITY_LIMIT];
bool g_PlayerItem[ENTITY_LIMIT];
bool g_Quarantined[ENTITY_LIMIT];

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int errMax)
{
    if (GetEngineVersion() != Engine_Left4Dead2)
    {
        strcopy(error, errMax, "This plugin only supports Left 4 Dead 2.");
        return APLRes_SilentFailure;
    }
    g_LateLoad = late;
    return APLRes_Success;
}

public void OnPluginStart()
{
    g_GunPoints = new ArrayList(sizeof(SpawnPoint));
    g_PillPoints = new ArrayList(sizeof(SpawnPoint));
    g_MedicinePoints = new ArrayList(sizeof(SpawnPoint));
    g_Stations = new ArrayList(sizeof(GunStation));

    CreateConVar("l4d2_strict_spawns_version", PLUGIN_VERSION, "Plugin version", FCVAR_NOTIFY | FCVAR_DONTRECORD);
    g_Radius = CreateConVar("l4d2_strict_station_radius", "160.0", "Station grouping distance in Source units; next round", FCVAR_NONE, true, 32.0, true, 512.0);
    g_Height = CreateConVar("l4d2_strict_station_height", "48.0", "Maximum height difference in a station; next round", FCVAR_NONE, true, 8.0, true, 128.0);
    g_WeaponCount = CreateConVar("l4d2_strict_weapon_count", "5", "Pickups per gun TYPE at each station; next round", FCVAR_NONE, true, 1.0, true, 32.0);
    AutoExecConfig(true, "l4d2_strict_spawns");

    HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
    HookEvent("round_end", Event_RoundEnd, EventHookMode_PostNoCopy);
    HookEvent("map_transition", Event_RoundEnd, EventHookMode_PostNoCopy);
    RegAdminCmd("sm_spawnrules_status", Command_Status, ADMFLAG_GENERIC, "Show pill budget, stations, and remaining world items.");
    RegAdminCmd("sm_spawnrules_dump", Command_Dump, ADMFLAG_GENERIC, "Write station choices and pill coordinates to the server console.");

    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientInGame(client))
        {
            OnClientPutInServer(client);
            RememberInventory(client);
        }
    }

    if (g_LateLoad)
    {
        // SourceMod calls OnMapStart for a late-loaded plugin as well.
        // Defer engine work until that forward, when precaching is permitted.
        g_StartPending = true;
        LogMessage("Late load: rules apply to current WORLD items; change map for a clean full-round pill budget.");
    }
}

public void OnMapStart()
{
    g_MapReady = true;
    PrecacheItems();
    // Some game paths fire round_start before OnMapStart. Remember that event,
    // but never create a speculative round here and then erase its replacements
    // when the actual first round_start arrives.
    if (g_StartPending)
    {
        g_StartPending = false;
        BeginRound();
    }
}

public void OnMapEnd()
{
    StopRound();
    g_MapReady = false;
    g_StartPending = false;
}

public void OnPluginEnd()
{
    // Do not delete carried equipment on unload. Existing replacements remain
    // until the next map; reloading a live round is intentionally unsupported.
    StopRound();
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_MapReady)
    {
        g_StartPending = true;
        return;
    }
    // A duplicate startup event must only extend the settling window, preserving
    // positions of originals that were already filtered.
    if (g_Active && !g_Ready)
    {
        delete g_InitTimer;
        g_InitTimer = CreateTimer(1.0, Timer_Initialize, g_Generation, TIMER_FLAG_NO_MAPCHANGE);
        return;
    }
    BeginRound();
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    StopRound();
}

void StopRound()
{
    g_Active = false;
    g_Ready = false;
    g_Generation++;
    delete g_InitTimer;
    delete g_MaintenanceTimer;
}

void BeginRound()
{
    StopRound();
    // Normally the engine has removed these during its round reset. Remove
    // any survivors of that reset without touching a player's inventory.
    for (int entity = MaxClients + 1; entity < GetMaxEntities() && entity < ENTITY_LIMIT; entity++)
    {
        if (g_Managed[entity] && IsValidEntity(entity) && !g_PlayerItem[entity] && !HasPlayerOwner(entity))
            RemoveEntity(entity);
        g_Managed[entity] = false;
    }
    g_GunPoints.Clear();
    g_PillPoints.Clear();
    g_MedicinePoints.Clear();
    g_Stations.Clear();
    g_PillsIssued = 0;
    g_Removed = 0;
    g_RetryTicks = 0;
    for (int i = 0; i < PILL_BUDGET; i++)
        g_PillRefs[i] = INVALID_ENT_REFERENCE;
    g_Active = true;
    // Filter existing entities on the next frame; never kill entities from
    // inside their own Spawn call or an entity-creation forward.
    RequestFrame(Frame_Scan, g_Generation);
    g_InitTimer = CreateTimer(1.0, Timer_Initialize, g_Generation, TIMER_FLAG_NO_MAPCHANGE);
    g_MaintenanceTimer = CreateTimer(1.0, Timer_Maintain, g_Generation, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

void PrecacheItems()
{
    // Dispatching each real weapon during map startup also precaches its
    // scripts/sounds/viewmodel, including the two CSS weapons.
    for (int i = 0; i < sizeof(PRECACHE_WEAPONS); i++)
    {
        int entity = CreateManaged(PRECACHE_WEAPONS[i]);
        if (entity == -1)
            continue;
        int reference = EntIndexToEntRef(entity);
        DispatchSpawn(entity);
        entity = EntRefToEntIndex(reference);
        if (entity != INVALID_ENT_REFERENCE)
            RemoveEntity(entity);
    }
}

public void OnClientPutInServer(int client)
{
    SDKHook(client, SDKHook_WeaponEquipPost, OnPlayerWeapon);
    SDKHook(client, SDKHook_WeaponDropPost, OnPlayerWeapon);
}

public void OnPlayerWeapon(int client, int weapon)
{
    if (weapon > MaxClients && weapon < ENTITY_LIMIT && IsValidEntity(weapon))
    {
        g_PlayerItem[weapon] = true;
        g_Quarantined[weapon] = false;
    }
}

void RememberInventory(int client)
{
    for (int slot = 0; slot <= 4; slot++)
    {
        int weapon = GetPlayerWeaponSlot(client, slot);
        if (weapon > MaxClients && weapon < ENTITY_LIMIT)
            g_PlayerItem[weapon] = true;
    }
}

public void OnEntityCreated(int entity, const char[] classname)
{
    if (entity <= MaxClients || entity >= ENTITY_LIMIT)
        return;
    g_Managed[entity] = false;
    g_PlayerItem[entity] = false;
    g_Quarantined[entity] = false;
    if (g_Creating || Classify(classname) == Item_Ignore)
        return;
    SDKHook(entity, SDKHook_SpawnPost, OnItemSpawned);
    SDKHook(entity, SDKHook_Use, OnItemUse);
    SDKHook(entity, SDKHook_Touch, OnItemTouch);
}

public void OnEntityDestroyed(int entity)
{
    if (entity > MaxClients && entity < ENTITY_LIMIT)
    {
        g_Managed[entity] = false;
        g_PlayerItem[entity] = false;
        g_Quarantined[entity] = false;
    }
}

public void OnItemSpawned(int entity)
{
    if (!g_Active || g_Managed[entity])
        return;
    g_Quarantined[entity] = true;
    RequestFrame(Frame_Process, EntIndexToEntRef(entity));
}

public Action OnItemUse(int entity, int activator, int caller, UseType type, float value)
{
    return (g_Active && g_Quarantined[entity]) ? Plugin_Handled : Plugin_Continue;
}

public Action OnItemTouch(int entity, int other)
{
    return (g_Active && g_Quarantined[entity]) ? Plugin_Handled : Plugin_Continue;
}

public void Frame_Process(any reference)
{
    int entity = EntRefToEntIndex(reference);
    if (g_Active && entity != INVALID_ENT_REFERENCE && IsValidEntity(entity))
        ProcessEntity(entity);
}

public void Frame_Scan(any generation)
{
    if (g_Active && generation == g_Generation)
        ScanWorld();
}

void ScanWorld()
{
    // Snapshot first: creating a replacement may reuse a just-freed index.
    ArrayList references = new ArrayList();
    for (int entity = MaxClients + 1; entity < GetMaxEntities() && entity < ENTITY_LIMIT; entity++)
    {
        if (IsValidEntity(entity))
            references.Push(EntIndexToEntRef(entity));
    }
    for (int i = 0; i < references.Length; i++)
    {
        int entity = EntRefToEntIndex(references.Get(i));
        if (entity != INVALID_ENT_REFERENCE && IsValidEntity(entity))
            ProcessEntity(entity);
    }
    delete references;
}

void ProcessEntity(int entity)
{
    if (entity <= MaxClients || entity >= ENTITY_LIMIT || g_Managed[entity])
        return;
    if (g_PlayerItem[entity] || HasPlayerOwner(entity))
    {
        g_PlayerItem[entity] = true;
        g_Quarantined[entity] = false;
        return;
    }
    char classname[64];
    GetEntityClassname(entity, classname, sizeof(classname));
    ItemKind kind = Classify(classname);
    // A generic weapon_spawn can also represent a chainsaw. Remove it without
    // counting its position as a candidate gun station.
    if (kind == Item_Gun && StrEqual(classname, "weapon_spawn")
        && HasEntProp(entity, Prop_Send, "m_weaponID")
        && GetEntProp(entity, Prop_Send, "m_weaponID") == WEAPON_ID_CHAINSAW)
        kind = Item_Blocked;
    if (kind == Item_Ignore)
        return;

    SpawnPoint point;
    GetEntPropVector(entity, Prop_Data, "m_vecAbsOrigin", point.origin);
    GetEntPropVector(entity, Prop_Data, "m_angAbsRotation", point.angles);
    point.station = -1;
    // Delete BEFORE spawning replacements; no original can be picked up while
    // a new station is being built. Only recognised item entities are removed.
    RemoveEntity(entity);
    g_Removed++;
    switch (kind)
    {
        case Item_Gun:
        {
            if (!g_Ready)
                AddPoint(g_GunPoints, point);
            else
                AddLateGunPoint(point);
        }
        case Item_Pills:
        {
            if (g_PillsIssued < PILL_BUDGET)
                AddPoint(g_PillPoints, point);
        }
        case Item_Medicine:
        {
            if (g_PillsIssued < PILL_BUDGET)
                AddPoint(g_MedicinePoints, point);
        }
    }
}

bool HasPlayerOwner(int entity)
{
    if (!HasEntProp(entity, Prop_Send, "m_hOwnerEntity"))
        return false;
    int owner = GetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity");
    return owner >= 1 && owner <= MaxClients;
}

ItemKind Classify(const char[] classname)
{
    if (StrEqual(classname, "weapon_spawn"))
        return Item_Gun;
    char base[64];
    strcopy(base, sizeof(base), classname);
    int length = strlen(base);
    if (length > 6 && StrEqual(base[length - 6], "_spawn"))
        base[length - 6] = '\0';
    // Covers both weapon_chainsaw and weapon_chainsaw_spawn, including
    // director/random-item spawns. Do not replace a chainsaw with two guns.
    if (StrEqual(base, "weapon_chainsaw"))
        return Item_Blocked;
    if (StrEqual(base, "weapon_pain_pills"))
        return Item_Pills;
    for (int i = 0; i < sizeof(FIREARMS); i++)
    {
        if (StrEqual(base, FIREARMS[i]))
            return Item_Gun;
    }
    for (int i = 0; i < sizeof(FORBIDDEN_SUPPLIES); i++)
    {
        if (StrEqual(base, FORBIDDEN_SUPPLIES[i]))
            return i >= 3 ? Item_Medicine : Item_Throwable;
    }
    // weapon_item_spawn itself is a random-item generator. Leave it in place
    // so unrequested supplies still work, and filter each actual child item.
    // Ammo, melee, defibs, upgrades, and objective props are deliberately kept.
    return Item_Ignore;
}

void AddPoint(ArrayList list, SpawnPoint point)
{
    SpawnPoint existing;
    for (int i = 0; i < list.Length; i++)
    {
        list.GetArray(i, existing, sizeof(existing));
        if (GetVectorDistance(existing.origin, point.origin, true) < 4.0)
            return;
    }
    list.PushArray(point, sizeof(point));
}

public Action Timer_Initialize(Handle timer, any generation)
{
    if (timer == g_InitTimer)
        g_InitTimer = null;
    if (!g_Active || generation != g_Generation)
        return Plugin_Stop;
    g_StationRadius = g_Radius.FloatValue;
    g_StationHeight = g_Height.FloatValue;
    g_PickupCount = g_WeaponCount.IntValue;
    ScanWorld();
    BuildStations();
    g_Ready = true;
    IssuePills();
    LogMessage("Round initialized: %d/%d stations (including saferooms); pills issued %d/2; filtered %d original items.", g_Stations.Length, MAX_GUN_STATIONS, g_PillsIssued, g_Removed);
    return Plugin_Stop;
}

public Action Timer_Maintain(Handle timer, any generation)
{
    if (!g_Active || generation != g_Generation)
    {
        if (timer == g_MaintenanceTimer)
            g_MaintenanceTimer = null;
        return Plugin_Stop;
    }
    if (!g_Ready)
        return Plugin_Continue;
    ScanWorld();
    // Retry failed initial allocations, never recreate items already issued.
    int incomplete;
    GunStation station;
    for (int i = 0; i < g_Stations.Length; i++)
    {
        IssueStation(i);
        g_Stations.GetArray(i, station, sizeof(station));
        if (!station.firstIssued || !station.secondIssued)
            incomplete++;
    }
    IssuePills();
    g_RetryTicks++;
    if (g_PillsIssued < PILL_BUDGET && (g_RetryTicks == 10 || g_RetryTicks % 60 == 0))
        LogError("Pill budget incomplete (%d/2): waiting for valid positions or free edicts. Run sm_spawnrules_status.", g_PillsIssued);
    if (incomplete > 0 && (g_RetryTicks == 10 || g_RetryTicks % 60 == 0))
        LogError("%d weapon stations incomplete: check free edicts and server weapon support.", incomplete);
    return Plugin_Continue;
}

bool SameStation(const float a[3], const float b[3])
{
    float radius = g_StationRadius;
    return FloatAbs(a[2] - b[2]) <= g_StationHeight
        && GetVectorDistance(a, b, true) <= radius * radius
        && ClearPath(a, b);
}

bool ClearPath(const float a[3], const float b[3])
{
    float start[3], end[3];
    CopyVector(a, start);
    CopyVector(b, end);
    start[2] += 12.0;
    end[2] += 12.0;
    Handle trace = TR_TraceRayFilterEx(start, end, MASK_SOLID, RayType_EndPoint, Trace_World);
    bool clear = !TR_StartSolid(trace) && !TR_DidHit(trace);
    delete trace;
    return clear;
}

public bool Trace_World(int entity, int contentsMask)
{
    if (entity >= 1 && entity <= MaxClients)
        return false;
    if (entity > MaxClients && IsValidEntity(entity))
    {
        char classname[64];
        GetEntityClassname(entity, classname, sizeof(classname));
        if (StrContains(classname, "weapon_") == 0 || StrEqual(classname, "infected") || StrEqual(classname, "witch"))
            return false;
    }
    return true;
}

void BuildStations()
{
    // Group the entire map first, including both saferooms. Sample complete
    // stations afterwards so the entity enumeration order cannot always keep
    // only the first five locations. Unselected originals were already removed.
    ArrayList candidates = new ArrayList(sizeof(GunStation));
    SpawnPoint anchor, other;
    for (int i = 0; i < g_GunPoints.Length; i++)
    {
        g_GunPoints.GetArray(i, anchor, sizeof(anchor));
        if (anchor.station != -1)
            continue;
        GunStation station;
        InitializeStation(station, anchor);
        int index = candidates.Length;
        anchor.station = index;
        g_GunPoints.SetArray(i, anchor, sizeof(anchor));
        bool hasSecond = false;
        for (int j = i + 1; j < g_GunPoints.Length; j++)
        {
            g_GunPoints.GetArray(j, other, sizeof(other));
            if (other.station != -1 || !SameStation(anchor.origin, other.origin))
                continue;
            other.station = index;
            g_GunPoints.SetArray(j, other, sizeof(other));
            if (!hasSecond && GetVectorDistance(anchor.origin, other.origin, true) >= 256.0)
            {
                CopyVector(other.origin, station.second);
                CopyVector(other.angles, station.secondAngles);
                hasSecond = true;
            }
        }
        if (!hasSecond)
            FindNeighbour(anchor.origin, anchor.angles[1], station.second);
        candidates.PushArray(station, sizeof(station));
    }

    GunStation selected;
    while (candidates.Length > 0 && g_Stations.Length < MAX_GUN_STATIONS)
    {
        int choice = GetRandomInt(0, candidates.Length - 1);
        candidates.GetArray(choice, selected, sizeof(selected));
        candidates.Erase(choice);
        RegisterStation(selected);
    }
    delete candidates;
}

void InitializeStation(GunStation station, SpawnPoint point)
{
    CopyVector(point.origin, station.first);
    CopyVector(point.origin, station.second);
    CopyVector(point.angles, station.firstAngles);
    CopyVector(point.angles, station.secondAngles);
    station.smg = GetRandomInt(0, sizeof(SMG_SPAWNS) - 1);
    station.shotgun = GetRandomInt(0, sizeof(SHOTGUN_SPAWNS) - 1);
    station.firstRef = INVALID_ENT_REFERENCE;
    station.secondRef = INVALID_ENT_REFERENCE;
    station.firstIssued = false;
    station.secondIssued = false;
}

void AddLateGunPoint(SpawnPoint point)
{
    // Lifetime quota: picking up/destroying guns does not release a station.
    // Delayed saferoom/director/script spawns share the exact same five slots.
    if (g_Stations.Length >= MAX_GUN_STATIONS)
        return;
    // Previously consumed stations stay registered: delayed director/script
    // spawns cannot reroll a third type or replenish that station.
    GunStation station;
    for (int i = 0; i < g_Stations.Length; i++)
    {
        g_Stations.GetArray(i, station, sizeof(station));
        if (SameStation(point.origin, station.first) || SameStation(point.origin, station.second))
            return;
    }
    InitializeStation(station, point);
    FindNeighbour(point.origin, point.angles[1], station.second);
    RegisterStation(station);
}

void RegisterStation(GunStation station)
{
    // The only insertion point for both initial and delayed stations. Reserve
    // the quota before spawning so allocation retries cannot create a sixth.
    if (g_Stations.Length >= MAX_GUN_STATIONS)
        return;
    int index = g_Stations.PushArray(station, sizeof(station));
    IssueStation(index);
}

void IssueStation(int index)
{
    GunStation station;
    g_Stations.GetArray(index, station, sizeof(station));
    if (!station.firstIssued)
    {
        int entity = SpawnGun(SMG_SPAWNS[station.smg], station.first, station.firstAngles);
        if (entity != -1)
        {
            station.firstRef = EntIndexToEntRef(entity);
            station.firstIssued = true;
        }
    }
    if (!station.secondIssued)
    {
        int entity = SpawnGun(SHOTGUN_SPAWNS[station.shotgun], station.second, station.secondAngles);
        if (entity != -1)
        {
            station.secondRef = EntIndexToEntRef(entity);
            station.secondIssued = true;
        }
    }
    g_Stations.SetArray(index, station, sizeof(station));
}

int CreateManaged(const char[] classname)
{
    g_Creating = true;
    int entity = CreateEntityByName(classname);
    g_Creating = false;
    if (entity == -1)
        return -1;
    if (entity >= ENTITY_LIMIT)
    {
        RemoveEntity(entity);
        return -1;
    }
    g_Managed[entity] = true;
    return entity;
}

int SpawnGun(const char[] classname, const float origin[3], const float angles[3])
{
    int entity = CreateManaged(classname);
    if (entity == -1)
        return -1;
    char count[12];
    IntToString(g_PickupCount, count, sizeof(count));
    DispatchKeyValue(entity, "count", count);
    DispatchKeyValue(entity, "spawnflags", "2");
    DispatchKeyValue(entity, "spawn_without_director", "1");
    DispatchKeyValue(entity, "solid", "6");
    TeleportEntity(entity, origin, angles, NULL_VECTOR);
    int reference = EntIndexToEntRef(entity);
    if (!DispatchSpawn(entity) || EntRefToEntIndex(reference) == INVALID_ENT_REFERENCE)
    {
        entity = EntRefToEntIndex(reference);
        if (entity != INVALID_ENT_REFERENCE)
            RemoveEntity(entity);
        return -1;
    }
    return entity;
}

void IssuePills()
{
    while (g_PillsIssued < PILL_BUDGET)
    {
        float position[3];
        if (!ChoosePillPosition(position))
            return;
        // Real single-use weapon, not a refillable weapon_*_spawn entity.
        int entity = CreateManaged("weapon_pain_pills");
        if (entity == -1)
            return;
        float angles[3];
        TeleportEntity(entity, position, angles, NULL_VECTOR);
        int reference = EntIndexToEntRef(entity);
        if (!DispatchSpawn(entity) || EntRefToEntIndex(reference) == INVALID_ENT_REFERENCE)
        {
            entity = EntRefToEntIndex(reference);
            if (entity != INVALID_ENT_REFERENCE)
                RemoveEntity(entity);
            return;
        }
        // Keep the bottle at its validated position until picked up. Pickup
        // transfers this same entity to inventory; it does not create a third.
        SetEntityMoveType(entity, MOVETYPE_NONE);
        g_PillRefs[g_PillsIssued] = reference;
        CopyVector(position, g_PillPositions[g_PillsIssued]);
        g_PillsIssued++;
    }
}

bool ChoosePillPosition(float position[3])
{
    // Prefer actual pill positions, then other medicine, then weapon tables.
    if (TryPointList(g_PillPoints, position) || TryPointList(g_MedicinePoints, position) || TryPointList(g_GunPoints, position))
        return true;

    // No item markers (custom/empty map): use an actual living survivor as a
    // reachable anchor. If nobody has spawned, keep waiting rather than use 0,0,0.
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || GetClientTeam(client) != 2 || !IsPlayerAlive(client))
            continue;
        float origin[3];
        GetClientAbsOrigin(client, origin);
        for (int attempt = 0; attempt < 8; attempt++)
        {
            float yaw = float(attempt) * 45.0;
            if (TryOffset(origin, yaw, 24.0, position) && SeparatePill(position))
                return true;
        }
    }
    return false;
}

bool TryPointList(ArrayList list, float position[3])
{
    if (list.Length == 0)
        return false;
    int start = GetRandomInt(0, list.Length - 1);
    SpawnPoint point;
    for (int i = 0; i < list.Length; i++)
    {
        list.GetArray((start + i) % list.Length, point, sizeof(point));
        CopyVector(point.origin, position);
        position[2] += 4.0;
        if (SeparatePill(position) && FreeItemPosition(position))
            return true;
    }
    // A map with exactly one item marker still needs two separate bottles.
    for (int i = 0; i < list.Length; i++)
    {
        list.GetArray((start + i) % list.Length, point, sizeof(point));
        for (int attempt = 0; attempt < 8; attempt++)
        {
            if (TryOffset(point.origin, float(attempt) * 45.0, 24.0, position) && SeparatePill(position))
                return true;
        }
    }
    return false;
}

bool SeparatePill(const float position[3])
{
    for (int i = 0; i < g_PillsIssued; i++)
    {
        if (GetVectorDistance(position, g_PillPositions[i], true) < 256.0)
            return false;
    }
    return true;
}

bool FreeItemPosition(const float position[3])
{
    float mins[3] = {-4.0, -4.0, 0.0};
    float maxs[3] = {4.0, 4.0, 12.0};
    Handle trace = TR_TraceHullFilterEx(position, position, mins, maxs, MASK_SOLID, Trace_World);
    bool clear = !TR_StartSolid(trace) && !TR_AllSolid(trace) && !TR_DidHit(trace);
    delete trace;
    return clear;
}

bool TryOffset(const float origin[3], float yaw, float distance, float result[3])
{
    float start[3], end[3];
    CopyVector(origin, start);
    start[2] += 16.0;
    CopyVector(start, end);
    end[0] += Cosine(DegToRad(yaw)) * distance;
    end[1] += Sine(DegToRad(yaw)) * distance;
    Handle trace = TR_TraceRayFilterEx(start, end, MASK_SOLID, RayType_EndPoint, Trace_World);
    bool clear = !TR_StartSolid(trace) && !TR_DidHit(trace);
    delete trace;
    if (!clear)
        return false;
    CopyVector(end, start);
    end[2] -= 96.0;
    trace = TR_TraceRayFilterEx(start, end, MASK_SOLID, RayType_EndPoint, Trace_World);
    bool found = !TR_StartSolid(trace) && TR_DidHit(trace);
    if (found)
    {
        TR_GetEndPosition(result, trace);
        result[2] += 4.0;
    }
    delete trace;
    return found && FreeItemPosition(result);
}

void FindNeighbour(const float origin[3], float yaw, float result[3])
{
    for (int attempt = 0; attempt < 8; attempt++)
    {
        if (TryOffset(origin, yaw + 90.0 + float(attempt) * 45.0, 32.0, result))
            return;
    }
    // Tiny shelves may have no room beside the original; stack vertically
    // rather than invent an unchecked position behind a wall.
    CopyVector(origin, result);
    result[2] += 8.0;
}

void CopyVector(const float source[3], float destination[3])
{
    for (int axis = 0; axis < 3; axis++)
        destination[axis] = source[axis];
}

public Action Command_Status(int client, int args)
{
    int pills, guns, forbidden, pending;
    char classname[64];
    for (int entity = MaxClients + 1; entity < GetMaxEntities() && entity < ENTITY_LIMIT; entity++)
    {
        if (!IsValidEntity(entity) || HasPlayerOwner(entity))
            continue;
        GetEntityClassname(entity, classname, sizeof(classname));
        ItemKind kind = Classify(classname);
        if (kind == Item_Pills)
            pills++;
        if (g_Managed[entity] && kind == Item_Gun)
            guns++;
        if (!g_Managed[entity] && !g_PlayerItem[entity] && kind != Item_Ignore)
            forbidden++;
    }
    GunStation station;
    for (int i = 0; i < g_Stations.Length; i++)
    {
        g_Stations.GetArray(i, station, sizeof(station));
        if (!station.firstIssued || !station.secondIssued)
            pending++;
    }
    ReplyToCommand(client, "[StrictSpawns] active=%d ready=%d; pills_issued=%d/2; world_pills=%d; stations=%d/%d; world_gun_spawners=%d; incomplete_stations=%d; unfiltered=%d; removed=%d",
        g_Active, g_Ready, g_PillsIssued, pills, g_Stations.Length, MAX_GUN_STATIONS, guns, pending, forbidden, g_Removed);
    return Plugin_Handled;
}

public Action Command_Dump(int client, int args)
{
    GunStation station;
    for (int i = 0; i < g_Stations.Length; i++)
    {
        g_Stations.GetArray(i, station, sizeof(station));
        PrintToServer("[StrictSpawns] station %d: (%.1f %.1f %.1f) %s [%d] + %s [%d]", i + 1,
            station.first[0], station.first[1], station.first[2], SMG_SPAWNS[station.smg], station.firstRef,
            SHOTGUN_SPAWNS[station.shotgun], station.secondRef);
    }
    for (int i = 0; i < g_PillsIssued; i++)
        PrintToServer("[StrictSpawns] pill %d: (%.1f %.1f %.1f) ref=%d", i + 1, g_PillPositions[i][0], g_PillPositions[i][1], g_PillPositions[i][2], g_PillRefs[i]);
    ReplyToCommand(client, "[StrictSpawns] Dump written to SERVER console; coordinates are initial spawn locations.");
    return Plugin_Handled;
}

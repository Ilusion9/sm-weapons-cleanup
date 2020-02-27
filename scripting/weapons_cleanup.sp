#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#pragma newdecls required

public Plugin myinfo =
{
	name = "Weapons Cleanup",
	author = "Ilusion9",
	description = "Maintain the specified dropped weapons in the world.",
	version = "1.2",
	url = "https://github.com/Ilusion9/"
};

#define MAXENTITIES 2048
enum struct WeaponInfo
{
	bool mapPlaced;
	bool isBomb;
	float dropTime;
	float spawnTime;
}

bool g_IsPluginLoadedLate;
bool g_HasRoundStarted;

ConVar g_Cvar_MaxWeapons;
ConVar g_Cvar_MaxBombs;
WeaponInfo g_WeaponsInfo[MAXENTITIES + 1];

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	g_IsPluginLoadedLate = late;
}

public void OnPluginStart()
{
	g_Cvar_MaxWeapons = CreateConVar("sm_weapon_max_before_cleanup", "24", "Maintain the specified dropped weapons in the world. The C4 will be ignored.", FCVAR_PROTECTED, true, 0.0);
	g_Cvar_MaxWeapons.AddChangeHook(ConVarChange_MaxWeapons);
	
	g_Cvar_MaxBombs = CreateConVar("sm_c4_max_before_cleanup", "3", "Maintain the specified dropped C4 bombs in the world.", FCVAR_PROTECTED, true, 0.0);
	g_Cvar_MaxBombs.AddChangeHook(ConVarChange_MaxC4);

	AutoExecConfig(true, "weapons_cleanup");
	HookEvent("round_start", Event_RoundStart);
	HookEvent("round_end", Event_RoundEnd);
	
	if (g_IsPluginLoadedLate)
	{
		for (int i = 1; i <= MaxClients; i++)
		{
			if (IsClientInGame(i))
			{
				OnClientPutInServer(i);
			}
		}
	}
}

public void OnMapStart()
{
	g_HasRoundStarted = false;
}

public void ConVarChange_MaxWeapons(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if (!g_Cvar_MaxWeapons.IntValue)
	{
		return;
	}
	
	int value = StringToInt(oldValue);
	if (!value || g_Cvar_MaxWeapons.IntValue < value)
	{
		ManageWorldWeapons();
	}
}

public void ConVarChange_MaxC4(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if (!g_Cvar_MaxBombs.IntValue)
	{
		return;
	}
	
	int value = StringToInt(oldValue);
	if (!value || g_Cvar_MaxBombs.IntValue < value)
	{
		ManageWorldBombs();
	}
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if (strncmp(classname, "weapon_", 7, true) != 0)
	{
		return;
	}
	
	g_WeaponsInfo[entity].isBomb = StrEqual(classname[7], "c4", true);
	SDKHook(entity, SDKHook_SpawnPost, SDK_OnWeaponSpawn_Post);
}

public void SDK_OnWeaponSpawn_Post(int weapon)
{
	if (!IsValidEntity(weapon))
	{
		return;
	}
	
	float gameTime = GetGameTime();
	if (gameTime - g_WeaponsInfo[weapon].spawnTime < 1.0) // SDKSpawn is called twice ...
	{
		return;
	}
	
	g_WeaponsInfo[weapon].mapPlaced = false;
	g_WeaponsInfo[weapon].dropTime = 0.0;
	g_WeaponsInfo[weapon].spawnTime = gameTime;
	
	RequestFrame(Frame_WeaponSpawn, EntIndexToEntRef(weapon));
}

public void Frame_WeaponSpawn(any data)
{
	int weapon = EntRefToEntIndex(view_as<int>(data));
	if (weapon == INVALID_ENT_REFERENCE)
	{
		return;
	}
	
	if (!g_HasRoundStarted)
	{
		return;
	}
	
	if (g_WeaponsInfo[weapon].isBomb)
	{
		ManageWorldBombs(weapon);
	}
	else
	{
		ManageWorldWeapons(weapon);
	}
}

public void OnClientPutInServer(int client)
{
	SDKHook(client, SDKHook_WeaponDropPost, SDK_OnWeaponDrop_Post);
}

public void SDK_OnWeaponDrop_Post(int client, int weapon)
{
	if (!IsValidEntity(weapon))
	{
		return;
	}
	
	g_WeaponsInfo[weapon].mapPlaced = false;
	g_WeaponsInfo[weapon].dropTime = GetGameTime();
	
	RequestFrame(Frame_WeaponDrop, EntIndexToEntRef(weapon));
}

public void Frame_WeaponDrop(any data)
{
	int weapon = EntRefToEntIndex(view_as<int>(data));
	if (weapon == INVALID_ENT_REFERENCE)
	{
		return;
	}
	
	if (g_WeaponsInfo[weapon].isBomb)
	{
		ManageWorldBombs(weapon);
	}
	else
	{
		ManageWorldWeapons(weapon);
	}
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast) 
{
	if (IsWarmupPeriod())
	{
		return;
	}
	
	RequestFrame(Frame_RoundStart);
}

public void Frame_RoundStart(any data)
{
	g_HasRoundStarted = true;
	int ent = -1;
	
	while ((ent = FindEntityByClassname(ent, "weapon_*")) != -1)
	{
		if (IsEntityOwned(ent))
		{
			continue;
		}
		
		g_WeaponsInfo[ent].mapPlaced = true;
	}
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast) 
{
	g_HasRoundStarted = false;
}

void ManageWorldBombs(int currentWeapon = -1)
{
	int ent = -1;
	ArrayList listWeapons = new ArrayList();
	
	while ((ent = FindEntityByClassname(ent, "weapon_c4")) != -1)
	{
		if (ent == currentWeapon || IsEntityOwned(ent) || !CanBePickedUp(ent) || g_WeaponsInfo[ent].mapPlaced)
		{
			continue;
		}
		
		listWeapons.Push(ent);
	}
	
	int maxWeapons = g_Cvar_MaxBombs.IntValue;
	if (currentWeapon != -1 && !IsEntityOwned(currentWeapon))
	{
		maxWeapons--;
	}
	
	RemoveOldestWeapons(listWeapons, maxWeapons);
	delete listWeapons;
}

void ManageWorldWeapons(int currentWeapon = -1)
{
	int ent = -1;
	ArrayList listWeapons = new ArrayList();
	
	while ((ent = FindEntityByClassname(ent, "weapon_*")) != -1)
	{
		if (ent == currentWeapon || IsEntityOwned(ent) || !CanBePickedUp(ent) || g_WeaponsInfo[ent].mapPlaced || g_WeaponsInfo[ent].isBomb)
		{
			continue;
		}
		
		listWeapons.Push(ent);
	}
	
	int maxWeapons = g_Cvar_MaxWeapons.IntValue;
	if (currentWeapon != -1 && !IsEntityOwned(currentWeapon))
	{
		maxWeapons--;
	}
	
	RemoveOldestWeapons(listWeapons, maxWeapons);
	delete listWeapons;
}

void RemoveOldestWeapons(ArrayList listWeapons, int maxWeapons)
{
	int diff = listWeapons.Length - maxWeapons;
	if (diff > 1)
	{
		listWeapons.SortCustom(sortWeapons);
		for (int i = maxWeapons; i < listWeapons.Length; i++)
		{
			AcceptEntityInput(listWeapons.Get(i), "Kill");
		}
		
		return;
	}
	
	if (diff == 1)
	{
		int toCompare;
		int toRemove = listWeapons.Get(0);
		
		for (int i = 1; i < listWeapons.Length; i++)
		{
			toCompare = listWeapons.Get(i);
			if (g_WeaponsInfo[toCompare].dropTime < g_WeaponsInfo[toRemove].dropTime)
			{
				toRemove = toCompare;
			}
		}
		
		AcceptEntityInput(toRemove, "Kill");
	}
}

bool IsWarmupPeriod()
{
	return GameRules_GetProp("m_bWarmupPeriod") != 0;
}

bool IsEntityOwned(int entity)
{
	return GetEntPropEnt(entity, Prop_Data, "m_hOwnerEntity") != -1;
}

bool CanBePickedUp(int entity)
{
	return GetEntProp(entity, Prop_Data, "m_bCanBePickedUp") != 0;
}

public int sortWeapons(int index1, int index2, Handle array, Handle hndl)
{
	int weapon1 = view_as<ArrayList>(array).Get(index1);
	int weapon2 = view_as<ArrayList>(array).Get(index2);
	
	if (g_WeaponsInfo[weapon1].dropTime < g_WeaponsInfo[weapon2].dropTime)
	{
		return 1;
	}
	
	if (g_WeaponsInfo[weapon1].dropTime > g_WeaponsInfo[weapon2].dropTime)
	{
		return -1;
	}
	
	return 0;
}

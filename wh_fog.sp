#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <sdktools_trace>
#include <files>

#define PLUGIN_VERSION   "1.0.0"
#define FOG_CONFIG_DIR   "configs"
#define FOG_CONFIG_REL   "configs/wh_fog.cfg"
#define FOG_MAX_LISTED   16

#define FOG_GRID_X       3
#define FOG_GRID_Z       5
#define FOG_TOTAL_RAYS   (FOG_GRID_X * FOG_GRID_Z)

static const float g_fGridX[FOG_GRID_X] = { -0.82, 0.0, 0.82 };
static const float g_fGridZ[FOG_GRID_Z] = { -0.85, -0.40, 0.0, 0.45, 0.85 };

static ConVar g_cvEnabled;
static ConVar g_cvMinDist;
static ConVar g_cvDist;
static ConVar g_cvFarDist;
static ConVar g_cvFarRays;
static ConVar g_cvRevealDamage;
static ConVar g_cvRevealTime;
static ConVar g_cvHideWeapons;
static ConVar g_cvAliveOnly;
static ConVar g_cvDebug;

static ConVar g_hListed[FOG_MAX_LISTED];
static int    g_iListed;

static int   g_iCacheTick[MAXPLAYERS + 1][MAXPLAYERS + 1];
static bool  g_bCacheHidden[MAXPLAYERS + 1][MAXPLAYERS + 1];
static float g_fRevealUntil[MAXPLAYERS + 1][MAXPLAYERS + 1];

static float g_fLastDebugLog;

public Plugin myinfo =
{
	name        = "wh_fog - anti-wallhack fog of war",
	author      = "Alley",
	description = "Hides an enemy from a viewer only when the world blocks the WHOLE silhouette (15-ray grid, distance-aware)",
	version     = PLUGIN_VERSION,
	url         = "https://github.com/Alleyv2"
};

public void OnPluginStart()
{
	LoadTranslations("common.phrases");

	g_cvEnabled      = CreateConVar("wh_fog_enabled",       "1",    "Master switch for the anti-wallhack fog of war");
	g_cvMinDist      = CreateConVar("wh_fog_min_dist",      "64.0", "Always transmit an enemy closer than this (game units). Safety valve against point-blank/cornered players, NOT a distance gate. 0 = off", FCVAR_NONE, true, 0.0);
	g_cvDist         = CreateConVar("wh_fog_dist",          "0.0",  "If > 0, apply the fog ONLY to enemies further than this (game units): close-quarters fights stay untouched. 0 = fog at every range", FCVAR_NONE, true, 0.0);
	g_cvFarDist      = CreateConVar("wh_fog_far_dist",      "0.0",  "Long-range tightening: beyond this distance hide once wh_fog_far_rays rays are blocked instead of all 15. 0 = off (recommended)", FCVAR_NONE, true, 0.0);
	g_cvFarRays      = CreateConVar("wh_fog_far_rays",      "15",   "Rays that must be blocked beyond wh_fog_far_dist for the enemy to be hidden (1..15; 15 = whole silhouette)", FCVAR_NONE, true, 1.0, true, 15.0);
	g_cvRevealDamage = CreateConVar("wh_fog_reveal_damage", "1",    "Show an enemy for a while after they damaged you");
	g_cvRevealTime   = CreateConVar("wh_fog_reveal_time",   "3.0",  "Seconds an enemy stays visible after damaging you", FCVAR_NONE, true, 0.0, true, 60.0);
	g_cvHideWeapons  = CreateConVar("wh_fog_hide_weapons",  "1",    "Also hide the active weapon of a hidden player (a weapon is a separate entity and would float as a marker)");
	g_cvAliveOnly    = CreateConVar("wh_fog_alive_only",    "1",    "Only hide for LIVING viewers; 0 also hides from dead viewers and free-look");
	g_cvDebug        = CreateConVar("wh_fog_debug",         "0",    "Log hide/reveal decisions (rate limited to one block per second)");

	Fog_List(g_cvEnabled);
	Fog_List(g_cvMinDist);
	Fog_List(g_cvDist);
	Fog_List(g_cvFarDist);
	Fog_List(g_cvFarRays);
	Fog_List(g_cvRevealDamage);
	Fog_List(g_cvRevealTime);
	Fog_List(g_cvHideWeapons);
	Fog_List(g_cvAliveOnly);
	Fog_List(g_cvDebug);

	RegAdminCmd("sm_whfog_status",  Cmd_Status,  ADMFLAG_GENERIC, "sm_whfog_status - show, for you, which enemies are hidden and why");
	RegAdminCmd("sm_whfog_refresh", Cmd_Refresh, ADMFLAG_GENERIC, "sm_whfog_refresh - drop the per-tick visibility cache");

	HookEvent("player_hurt", Event_PlayerHurt, EventHookMode_Post);

	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i))
			OnClientPutInServer(i);
	}

	Fog_ConfigSync();
}

public void OnConfigsExecuted()
{
	Fog_ConfigSync();

	char path[PLATFORM_MAX_PATH];
	Fog_ConfigPath(path, sizeof(path));

	char line[384];
	Format(line, sizeof(line),
	       "[wh_fog] v%s loaded: enabled=%d | min_dist=%.0f dist=%.0f far_dist=%.0f far_rays=%d | hide_weapons=%d alive_only=%d | config %s",
	       PLUGIN_VERSION, g_cvEnabled.BoolValue ? 1 : 0,
	       g_cvMinDist.FloatValue, g_cvDist.FloatValue,
	       g_cvFarDist.FloatValue, g_cvFarRays.IntValue,
	       g_cvHideWeapons.BoolValue ? 1 : 0, g_cvAliveOnly.BoolValue ? 1 : 0,
	       path);

	LogMessage("%s", line);
	PrintToServer("%s", line);
}

static void Fog_List(ConVar cv)
{
	if (g_iListed < FOG_MAX_LISTED)
		g_hListed[g_iListed++] = cv;
}

static void Fog_ConfigPath(char[] buffer, int maxlen)
{
	char dir[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, dir, sizeof(dir), FOG_CONFIG_DIR);

	if (!DirExists(dir))
		CreateDirectory(dir, FPERM_U_READ | FPERM_U_WRITE | FPERM_U_EXEC | FPERM_G_READ | FPERM_G_EXEC | FPERM_O_READ | FPERM_O_EXEC);

	BuildPath(Path_SM, buffer, maxlen, FOG_CONFIG_REL);
}

static void Fog_ConfigSync()
{
	char path[PLATFORM_MAX_PATH];
	Fog_ConfigPath(path, sizeof(path));

	if (!FileExists(path))
		Fog_ConfigWriteDefaults(path);

	Fog_ConfigLoad(path);
}

static void Fog_ConfigWriteDefaults(const char[] path)
{
	File h = OpenFile(path, "wt");
	if (h == null)
	{
		LogError("[wh_fog] could not create the default config %s", path);
		return;
	}

	for (int i = 0; i < g_iListed; i++)
	{
		char name[64], value[256];
		GetConVarName(g_hListed[i], name, sizeof(name));
		g_hListed[i].GetString(value, sizeof(value));
		WriteFileLine(h, "%s \"%s\"", name, value);
	}

	delete h;
	LogMessage("[wh_fog] created the default config %s", path);
}

static void Fog_ConfigLoad(const char[] path)
{
	File h = OpenFile(path, "rt");
	if (h == null)
	{
		LogError("[wh_fog] could not read the config %s", path);
		return;
	}

	char line[512];
	int applied = 0;

	while (ReadFileLine(h, line, sizeof(line)))
	{
		TrimString(line);

		if (line[0] == '\0' || line[0] == '/' || line[0] == '#')
			continue;

		char name[64], value[256];
		if (!Fog_ParseLine(line, name, sizeof(name), value, sizeof(value)))
			continue;

		if (strncmp(name, "wh_fog_", 7) != 0)
			continue;

		ConVar cv = FindConVar(name);
		if (cv == null)
			continue;

		if (cv.SetString(value))
		{
			applied++;
		}
		else
		{
			LogError("[wh_fog] bad value in %s: %s \"%s\"", path, name, value);
		}
	}

	delete h;
	LogMessage("[wh_fog] config %s applied (%d settings)", path, applied);
}

static bool Fog_ParseLine(const char[] line, char[] name, int nameLen, char[] value, int valueLen)
{
	int i = 0, n = 0;
	int len = strlen(line);

	while (i < len && line[i] != ' ' && line[i] != '\t')
	{
		if (n < nameLen - 1)
			name[n++] = line[i];
		i++;
	}
	name[n] = '\0';

	while (i < len && (line[i] == ' ' || line[i] == '\t'))
		i++;

	if (i >= len)
		return false;

	char quote = line[i];
	int v = 0;

	if (quote == '"' || quote == '\'')
	{
		i++;
		while (i < len && line[i] != quote)
		{
			if (v < valueLen - 1)
				value[v++] = line[i];
			i++;
		}
	}
	else
	{
		while (i < len && line[i] != ' ' && line[i] != '\t')
		{
			if (v < valueLen - 1)
				value[v++] = line[i];
			i++;
		}
	}

	while (v > 0 && (value[v - 1] == '\r' || value[v - 1] == '\n'))
		v--;

	value[v] = '\0';

	return (name[0] != '\0' && value[0] != '\0');
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if (entity <= 0 || classname[0] == '\0')
		return;
	if (StrContains(classname, "weapon_", false) != 0)
		return;

	SDKHook(entity, SDKHook_SetTransmit, OnWeaponSetTransmit);
}

public void OnClientPutInServer(int client)
{
	SDKHook(client, SDKHook_SetTransmit, OnPlayerSetTransmit);
	Fog_ResetClient(client);
}

public void OnClientDisconnect(int client)
{
	Fog_ResetClient(client);
}

static void Fog_ResetClient(int client)
{
	for (int i = 0; i <= MaxClients; i++)
	{
		g_iCacheTick[client][i] = -1;
		g_iCacheTick[i][client] = -1;
		g_fRevealUntil[client][i] = 0.0;
		g_fRevealUntil[i][client] = 0.0;
	}
}

public bool FogTraceFilter(int entity, int contentsMask, any data)
{
	if (entity >= 1 && entity <= MaxClients)
		return false;

	return true;
}

static bool Fog_LineClear(const float start[3], const float end[3])
{
	bool clear = true;

	Handle trace = TR_TraceRayFilterEx(start, end, MASK_VISIBLE, RayType_EndPoint, FogTraceFilter, 0);
	if (trace != null)
	{
		if (!TR_StartSolid(trace) && TR_DidHit(trace))
			clear = false;

		CloseHandle(trace);
	}

	return clear;
}

static int Fog_BlockedRays(int viewer, int target)
{
	float viewerOrigin[3], targetOrigin[3];
	GetClientAbsOrigin(viewer, viewerOrigin);
	GetClientAbsOrigin(target, targetOrigin);

	float eye[3];
	GetClientEyePosition(viewer, eye);

	float mins[3], maxs[3];
	GetClientMins(target, mins);
	GetClientMaxs(target, maxs);

	float center[3];
	center[0] = targetOrigin[0] + (mins[0] + maxs[0]) * 0.5;
	center[1] = targetOrigin[1] + (mins[1] + maxs[1]) * 0.5;
	center[2] = targetOrigin[2] + (mins[2] + maxs[2]) * 0.5;

	float axis[3], right[3], up[3];
	SubtractVectors(center, eye, axis);
	NormalizeVector(axis, axis);

	up[0] = 0.0;
	up[1] = 0.0;
	up[2] = 1.0;

	GetVectorCrossProduct(axis, up, right);
	if (NormalizeVector(right, right) < 0.01)
	{
		right[0] = 1.0;
		right[1] = 0.0;
		right[2] = 0.0;
	}

	GetVectorCrossProduct(right, axis, up);
	NormalizeVector(up, up);

	float halfW = FloatAbs(maxs[0]);
	if (FloatAbs(mins[0]) > halfW)
		halfW = FloatAbs(mins[0]);

	float halfH = (maxs[2] - mins[2]) * 0.5;

	if (halfW < 8.0)
		halfW = 8.0;
	if (halfH < 24.0)
		halfH = 24.0;

	float dxScale = halfW * 0.98;
	float dzScale = halfH * 0.95;

	int blocked = 0;

	for (int ix = 0; ix < FOG_GRID_X; ix++)
	{
		for (int iz = 0; iz < FOG_GRID_Z; iz++)
		{
			float ox = g_fGridX[ix] * dxScale;
			float oz = g_fGridZ[iz] * dzScale;

			float point[3];
			point[0] = center[0] + right[0] * ox + up[0] * oz;
			point[1] = center[1] + right[1] * ox + up[1] * oz;
			point[2] = center[2] + right[2] * ox + up[2] * oz;

			if (!Fog_LineClear(eye, point))
				blocked++;
		}
	}

	return blocked;
}

static int Fog_RaysNeeded(float distance)
{
	if (g_cvFarDist.FloatValue > 0.0 && distance >= g_cvFarDist.FloatValue)
	{
		int needed = RoundToNearest(g_cvFarRays.FloatValue);
		if (needed < 1)
			needed = 1;
		if (needed > FOG_TOTAL_RAYS)
			needed = FOG_TOTAL_RAYS;
		return needed;
	}

	return FOG_TOTAL_RAYS;
}

static bool Fog_ShouldHide(int viewer, int target)
{
	if (!g_cvEnabled.BoolValue)
		return false;

	if (viewer < 1 || viewer > MaxClients || target < 1 || target > MaxClients)
		return false;
	if (viewer == target)
		return false;

	if (!IsClientInGame(viewer) || !IsClientInGame(target))
		return false;

	if (IsFakeClient(viewer))
		return false;
	if (IsClientSourceTV(viewer) || IsClientReplay(viewer))
		return false;

	if (!IsPlayerAlive(target))
		return false;

	if (g_cvAliveOnly.BoolValue && !IsPlayerAlive(viewer))
		return false;

	int teamViewer = GetClientTeam(viewer);
	int teamTarget = GetClientTeam(target);

	if (teamViewer < 2 || teamTarget < 2)
		return false;
	if (teamViewer == teamTarget)
		return false;

	float now = GetGameTime();
	if (g_fRevealUntil[viewer][target] > now)
		return false;

	float viewerOrigin[3], targetOrigin[3];
	GetClientAbsOrigin(viewer, viewerOrigin);
	GetClientAbsOrigin(target, targetOrigin);
	float distance = GetVectorDistance(viewerOrigin, targetOrigin);

	if (g_cvMinDist.FloatValue > 0.0 && distance < g_cvMinDist.FloatValue)
		return false;

	if (g_cvDist.FloatValue > 0.0 && distance < g_cvDist.FloatValue)
		return false;

	int tick = GetGameTickCount();
	if (tick > 0 && g_iCacheTick[viewer][target] == tick)
		return g_bCacheHidden[viewer][target];

	int needed  = Fog_RaysNeeded(distance);
	int blocked = Fog_BlockedRays(viewer, target);
	bool hidden = (blocked >= needed);

	g_iCacheTick[viewer][target] = tick;
	g_bCacheHidden[viewer][target] = hidden;

	return hidden;
}

public Action OnPlayerSetTransmit(int entity, int client)
{
	if (Fog_ShouldHide(client, entity))
	{
		Fog_Debug("%N hidden from %N (silhouette fully blocked)", entity, client);
		return Plugin_Handled;
	}

	return Plugin_Continue;
}

public Action OnWeaponSetTransmit(int entity, int client)
{
	if (!g_cvEnabled.BoolValue || !g_cvHideWeapons.BoolValue)
		return Plugin_Continue;

	int owner = GetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity");
	if (owner < 1 || owner > MaxClients || owner == client)
		return Plugin_Continue;

	if (Fog_ShouldHide(client, owner))
		return Plugin_Handled;

	return Plugin_Continue;
}

public void Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cvEnabled.BoolValue || !g_cvRevealDamage.BoolValue)
		return;

	int attacker = GetClientOfUserId(event.GetInt("attacker"));
	int victim   = GetClientOfUserId(event.GetInt("userid"));
	if (attacker <= 0 || victim <= 0 || attacker == victim)
		return;

	float until = GetGameTime() + g_cvRevealTime.FloatValue;
	g_fRevealUntil[victim][attacker] = until;
	g_fRevealUntil[attacker][victim] = until;

	Fog_Debug("%N revealed to %N after damage for %.1fs", attacker, victim, g_cvRevealTime.FloatValue);
}

static void Fog_Debug(const char[] fmt, any ...)
{
	if (!g_cvDebug.BoolValue)
		return;

	float now = GetGameTime();
	if (now - g_fLastDebugLog < 1.0)
		return;
	g_fLastDebugLog = now;

	char body[256];
	VFormat(body, sizeof(body), fmt, 2);
	LogMessage("[wh_fog] %s", body);
}

public Action Cmd_Status(int client, int args)
{
	if (client <= 0)
		return Plugin_Handled;

	char map[64];
	GetCurrentMap(map, sizeof(map));

	char path[PLATFORM_MAX_PATH];
	Fog_ConfigPath(path, sizeof(path));

	int alive = 0, hidden = 0, revealed = 0, teammates = 0;
	float now = GetGameTime();

	ReplyToCommand(client, "[wh_fog] v%s | map %s | config %s", PLUGIN_VERSION, map, path);
	ReplyToCommand(client, "[wh_fog] enabled=%d min_dist=%.0f dist=%.0f far_dist=%.0f far_rays=%d",
	               g_cvEnabled.IntValue, g_cvMinDist.FloatValue, g_cvDist.FloatValue,
	               g_cvFarDist.FloatValue, g_cvFarRays.IntValue);

	for (int i = 1; i <= MaxClients; i++)
	{
		if (i == client || !IsClientInGame(i) || !IsPlayerAlive(i))
			continue;

		char name[64];
		GetClientName(i, name, sizeof(name));

		alive++;

		if (GetClientTeam(client) < 2)
			continue;

		if (GetClientTeam(i) == GetClientTeam(client))
		{
			teammates++;
			continue;
		}

		float viewpos[3], origin[3];
		GetClientAbsOrigin(client, viewpos);
		GetClientAbsOrigin(i, origin);
		float distance = GetVectorDistance(viewpos, origin);

		bool hiddenNow  = Fog_ShouldHide(client, i);
		bool isRevealed = (g_fRevealUntil[client][i] > now);

		if (hiddenNow)
			hidden++;
		if (isRevealed)
			revealed++;

		if (g_cvEnabled.BoolValue && !hiddenNow && !isRevealed)
		{
			int blocked = Fog_BlockedRays(client, i);
			ReplyToCommand(client, "  %-24s TRANSMITTED  dist=%.0f  blocked_rays=%d/%d",
			               name, distance, blocked, FOG_TOTAL_RAYS);
		}
		else
		{
			ReplyToCommand(client, "  %-24s %s%s  dist=%.0f",
			               name,
			               hiddenNow ? "HIDDEN" : "TRANSMITTED",
			               isRevealed ? " (revealed after damage)" : "",
			               distance);
		}
	}

	ReplyToCommand(client, "[wh_fog] live targets=%d hidden=%d revealed=%d teammates untouched=%d",
	               alive, hidden, revealed, teammates);
	return Plugin_Handled;
}

public Action Cmd_Refresh(int client, int args)
{
	for (int i = 0; i <= MaxClients; i++)
	{
		for (int j = 0; j <= MaxClients; j++)
			g_iCacheTick[i][j] = -1;
	}

	Fog_ConfigSync();

	ReplyToCommand(client, "[wh_fog] visibility cache cleared and config re-read");
	return Plugin_Handled;
}

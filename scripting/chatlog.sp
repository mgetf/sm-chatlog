#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <steamworks>

#define CHATLOG_MSG 256
#define CHATLOG_NAME 65
#define CHATLOG_FLUSH_MAX 20
#define CHATLOG_BUFFER_MAX 2000

enum struct ChatEntry
{
	char steamId[32];
	char name[CHATLOG_NAME];
	int team;
	bool teamSay;
	char message[CHATLOG_MSG];
	char map[64];
	int timestamp;
}

Database g_Database = null;
ArrayList g_Buffer;
bool g_Flushing = false;
char g_ServerIp[64];
char g_ServerName[128];
char g_Map[64];
ConVar g_Hostname;
ConVar g_Hostport;

public Plugin myinfo =
{
	name = "Chat Log",
	author = "mge.tf",
	description = "Writes say and say_team to a database",
	version = "1.0",
	url = "https://mge.tf"
};

public void OnPluginStart()
{
	g_Buffer = new ArrayList(sizeof(ChatEntry));
	g_Hostname = FindConVar("hostname");
	g_Hostport = FindConVar("hostport");
	if (g_Hostname != null)
	{
		g_Hostname.AddChangeHook(OnHostnameChanged);
		g_Hostname.GetString(g_ServerName, sizeof(g_ServerName));
	}
	CreateTimer(1.5, Timer_Flush, _, TIMER_REPEAT);
	Database.Connect(SQL_OnConnect, "chat");
}

public void OnMapStart()
{
	GetCurrentMap(g_Map, sizeof(g_Map));
	RefreshServerIp();
}

public void OnAllPluginsLoaded()
{
	RefreshServerIp();
}

public void SteamWorks_SteamServersConnected()
{
	RefreshServerIp();
}

public void OnClientSayCommand_Post(int client, const char[] command, const char[] args)
{
	if (client < 1 || client > MaxClients)
		return;
	if (!IsClientInGame(client) || IsFakeClient(client))
		return;
	if (IsClientSourceTV(client) || IsClientReplay(client))
		return;
	if (!IsClientAuthorized(client))
		return;

	char text[CHATLOG_MSG];
	strcopy(text, sizeof(text), args);
	TrimString(text);
	if (text[0] == '\0')
		return;

	char steam[32];
	if (!GetClientAuthId(client, AuthId_Steam2, steam, sizeof(steam)))
		return;

	ChatEntry entry;
	strcopy(entry.steamId, sizeof(entry.steamId), steam);
	GetClientName(client, entry.name, sizeof(entry.name));
	ReplaceString(entry.name, sizeof(entry.name), "\n", "");
	ReplaceString(entry.name, sizeof(entry.name), "\r", "");
	entry.team = GetClientTeam(client);
	entry.teamSay = StrEqual(command, "say_team", false);
	strcopy(entry.message, sizeof(entry.message), text);
	strcopy(entry.map, sizeof(entry.map), g_Map);
	entry.timestamp = GetTime();

	if (g_Buffer.Length >= CHATLOG_BUFFER_MAX)
		g_Buffer.Erase(0);
	g_Buffer.PushArray(entry, sizeof(entry));

	if (g_Buffer.Length >= CHATLOG_FLUSH_MAX)
		FlushBuffer();
}

public void OnHostnameChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	strcopy(g_ServerName, sizeof(g_ServerName), newValue);
}

public Action Timer_Flush(Handle timer)
{
	FlushBuffer();
	return Plugin_Continue;
}

void RefreshServerIp()
{
	int ip[4];
	if (!SteamWorks_GetPublicIP(ip))
		return;
	int port = g_Hostport != null ? g_Hostport.IntValue : 27015;
	Format(g_ServerIp, sizeof(g_ServerIp), "%d.%d.%d.%d:%d", ip[0], ip[1], ip[2], ip[3], port);
}

public void SQL_OnConnect(Database db, const char[] error, any data)
{
	if (db == null)
	{
		SetFailState("[chatlog] database connect failed: %s", error);
		return;
	}

	g_Database = db;
	db.SetCharset("utf8mb4");
	db.Query(SQL_LogError, "CREATE TABLE IF NOT EXISTS chat_logs (\
		id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,\
		steam_id VARCHAR(32) NOT NULL,\
		name VARCHAR(64) NULL,\
		team TINYINT NULL,\
		scope ENUM('all','team') NOT NULL,\
		message VARCHAR(255) NOT NULL,\
		server_ip VARCHAR(64) NOT NULL,\
		server_name VARCHAR(128) NULL,\
		map VARCHAR(64) NULL,\
		timestamp INT UNSIGNED NOT NULL,\
		INDEX idx_steam_ts (steam_id, timestamp),\
		INDEX idx_server_ts (server_ip, timestamp),\
		INDEX idx_ts (timestamp)\
	) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4");
}

void FlushBuffer()
{
	if (g_Flushing || g_Database == null || g_ServerIp[0] == '\0' || g_Buffer.Length == 0)
		return;

	int count = g_Buffer.Length;
	if (count > CHATLOG_FLUSH_MAX)
		count = CHATLOG_FLUSH_MAX;

	char serverIp[128];
	char serverName[256];
	g_Database.Escape(g_ServerIp, serverIp, sizeof(serverIp));
	g_Database.Escape(g_ServerName, serverName, sizeof(serverName));

	char query[32768];
	Format(query, sizeof(query), "INSERT INTO chat_logs (steam_id, name, team, scope, message, server_ip, server_name, map, timestamp) VALUES ");

	for (int i = 0; i < count; i++)
	{
		ChatEntry entry;
		g_Buffer.GetArray(i, entry, sizeof(entry));

		char steam[64];
		char name[CHATLOG_NAME * 2 + 1];
		char message[CHATLOG_MSG * 2 + 1];
		char map[128];
		g_Database.Escape(entry.steamId, steam, sizeof(steam));
		g_Database.Escape(entry.name, name, sizeof(name));
		g_Database.Escape(entry.message, message, sizeof(message));
		g_Database.Escape(entry.map, map, sizeof(map));

		char row[1024];
		Format(
			row,
			sizeof(row),
			"%s('%s', '%s', %d, '%s', '%s', '%s', '%s', '%s', %d)",
			i == 0 ? "" : ",",
			steam,
			name,
			entry.team,
			entry.teamSay ? "team" : "all",
			message,
			serverIp,
			serverName,
			map,
			entry.timestamp
		);
		StrCat(query, sizeof(query), row);
	}

	g_Flushing = true;
	g_Database.Query(SQL_FlushDone, query, count);
}

public void SQL_FlushDone(Database db, DBResultSet results, const char[] error, any data)
{
	g_Flushing = false;
	if (error[0] != '\0')
	{
		LogError("[chatlog] insert failed: %s", error);
		return;
	}

	int count = data;
	while (count > 0 && g_Buffer.Length > 0)
	{
		g_Buffer.Erase(0);
		count--;
	}
}

public void SQL_LogError(Database db, DBResultSet results, const char[] error, any data)
{
	if (error[0] != '\0')
		LogError("[chatlog] query failed: %s", error);
}

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <steamworks>

#undef REQUIRE_PLUGIN
#include <ccc>
#include <scp>
#include <sourcebanspp>
#define REQUIRE_PLUGIN

#define PLUGIN_VERSION		"2.0.1"
#define STEAMREP_URL		"http://steamrep.com/id2rep.php"
#define STEAM_API_URL		"http://api.steampowered.com/ISteamUser/GetPlayerBans/v1/"

enum LogLevel {
	Log_Error = 0,
	Log_Info,
	Log_Debug
}

enum TagType {
	TagType_None = 0,
	TagType_Scammer,
	TagType_TradeBanned,
	TagType_TradeProbation
}

public Plugin myinfo = {
	name        = "[TF2] SteamRep Checker (Redux)",
	author      = "Dr. McKay, JoinedSenses",
	description = "Checks a user's SteamRep upon connection",
	version     = PLUGIN_VERSION,
	url         = "https://github.com/JoinedSenses/SM-SteamRep-Checker/"
};

ConVar cvarDealMethod;
ConVar cvarSteamIDBanLength;
ConVar cvarIPBanLength;
ConVar cvarKickTaggedScammers;
ConVar cvarValveBanDealMethod;
ConVar cvarValveCautionDealMethod;
ConVar cvarSteamAPIKey;
ConVar cvarSendIP;
ConVar cvarExcludedTags;
ConVar cvarLogLevel;

ConVar sv_visiblemaxplayers;

TagType clientTag[MAXPLAYERS + 1];

EngineVersion g_EngineVersion;

public void OnPluginStart() {
	CreateConVar("steamrep_checker_version", PLUGIN_VERSION, "SteamRep Checker (Redux) Version", FCVAR_DONTRECORD|FCVAR_NOTIFY|FCVAR_SPONLY).SetString(PLUGIN_VERSION);
	cvarDealMethod = CreateConVar("steamrep_checker_deal_method", "2", "How to deal with reported scammers.\n0 = Disabled\n1 = Prefix chat with [SCAMMER] tag and warn users in chat (requires Custom Chat Colors)\n2 = Kick\n3 = Ban Steam ID\n4 = Ban IP\n5 = Ban Steam ID + IP", _, true, 0.0, true, 5.0);
	cvarSteamIDBanLength = CreateConVar("steamrep_checker_steamid_ban_length", "0", "Duration in minutes to ban Steam IDs for if steamrep_checker_deal_method = 3 or 5 (0 = permanent)", _, true, 0.0);
	cvarIPBanLength = CreateConVar("steamrep_checker_ip_ban_length", "0", "Duration in minutes to ban IP addresses for if steamrep_checker_deal_method = 4 or 5 (0 = permanent)");
	cvarKickTaggedScammers = CreateConVar("steamrep_checker_kick_tagged_scammers", "1", "Kick chat-tagged scammers if the server gets full?", _, true, 0.0, true, 1.0);
	cvarValveBanDealMethod = CreateConVar("steamrep_checker_valve_ban_deal_method", "2", "How to deal with Valve trade-banned players (requires API key to be set)\n0 = Disabled\n1 = Prefix chat with [TRADE BANNED] tag and warn users in chat (requires Custom Chat Colors)\n2 = Kick\n3 = Ban Steam ID\n4 = Ban IP\n5 = Ban Steam ID + IP", _, true, 0.0, true, 5.0);
	cvarValveCautionDealMethod = CreateConVar("steamrep_checker_valve_probation_deal_method", "1", "How to deal with Valve trade-probation players (requires API key to be set)\n0 = Disabled\n1 = Prefix chat with [TRADE PROBATION] tag and warn users in chat (requires Custom Chat Colors)\n2 = Kick\n3 = Ban Steam ID\n4 = Ban IP\n5 = Ban Steam ID + IP", _, true, 0.0, true, 5.0);
	cvarSteamAPIKey = CreateConVar("steamrep_checker_steam_api_key", "", "API key obtained from http://steamcommunity.com/dev (only required for Valve trade-ban or trade-probation detection", FCVAR_PROTECTED);
	cvarSendIP = CreateConVar("steamrep_checker_send_ip", "0", "Send IP addresses of connecting players to SteamRep?", _, true, 0.0, true, 1.0);
	cvarExcludedTags = CreateConVar("steamrep_checker_untrusted_tags", "", "Input the tags of any community whose bans you do not trust here.");
	cvarLogLevel = CreateConVar("steamrep_checker_log_level", "1", "Level of logging\n0 = Errors only\n1 = Info + errors\n2 = Info, errors, and debug", _, true, 0.0, true, 2.0);

	AutoExecConfig();

	sv_visiblemaxplayers = FindConVar("sv_visiblemaxplayers");

	HookEvent("player_changename", Event_PlayerChangeName);

	RegConsoleCmd("sm_rep", Command_Rep, "Checks a user's SteamRep");
	RegConsoleCmd("sm_sr", Command_Rep, "Checks a user's SteamRep");

	g_EngineVersion = GetEngineVersion();
}

public void OnClientConnected(int client) {
	clientTag[client] = TagType_None;
}

public void OnClientPostAdminCheck(int client) {
	PerformKicks();

	if (IsFakeClient(client) || CheckCommandAccess(client, "SkipSR", ADMFLAG_ROOT)) {
		return;
	}

	char auth[32];
	GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth));

	char excludedTags[64];
	cvarExcludedTags.GetString(excludedTags, sizeof(excludedTags));

	char ip[64];
	if (cvarSendIP.BoolValue) {
		GetClientIP(client, ip, sizeof(ip));
	}

	Handle request = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, STEAMREP_URL);
	SteamWorks_SetHTTPRequestContextValue(request, GetClientUserId(client));
	SteamWorks_SetHTTPRequestGetOrPostParameter(request, "steamID32", auth);
	SteamWorks_SetHTTPRequestGetOrPostParameter(request, "ignore", excludedTags);
	SteamWorks_SetHTTPRequestGetOrPostParameter(request, "IP", ip);
	SteamWorks_SetHTTPCallbacks(request, httpSteamRepRequestCompleted);
	SteamWorks_SendHTTPRequest(request);
	LogItem(Log_Debug, "Sending HTTP request for %L", client);
}

void PerformKicks() {
	if (GetClientCount(false) >= (sv_visiblemaxplayers.IntValue - 1) && cvarKickTaggedScammers.BoolValue) {
		if (cvarDealMethod.IntValue == 1) {
			for (int i = 1; i <= MaxClients; i++) {
				if (IsClientInGame(i) && clientTag[i] == TagType_Scammer) {
					KickClient(i, "You were kicked to free a slot because you are a reported scammer");
					return;
				}
			}
		}

		if (cvarValveBanDealMethod.IntValue == 1) {
			for (int i = 1; i <= MaxClients; i++) {
				if (IsClientInGame(i) && clientTag[i] == TagType_TradeBanned) {
					KickClient(i, "You were kicked to free a slot because you are trade banned");
					return;
				}
			}
		}

		if (cvarValveCautionDealMethod.IntValue == 1) {
			for (int i = 1; i <= MaxClients; i++) {
				if (IsClientInGame(i) && clientTag[i] == TagType_TradeProbation) {
					KickClient(i, "You were kicked to free a slot because you are on trade probation");
					return;
				}
			}
		}
	}
}

public void httpSteamRepRequestCompleted(Handle request, bool failure, bool successful, EHTTPStatusCode statusCode, any userid) {
	int client = GetClientOfUserId(userid);
	if (!client) {
		LogItem(Log_Debug, "Client with User ID %i left.", userid);
		delete request;
		return;
	}

	if (failure || !successful) {
		LogItem(Log_Error, "Error checking SteamRep for client %L. Status code: %i", client, statusCode);
		delete request;
		return;
	}

	int size;
	SteamWorks_GetHTTPResponseBodySize(request, size);

	char[] data = new char[size];
	SteamWorks_GetHTTPResponseBodyData(request, data, size);

	delete request;

	LogItem(Log_Debug, "Received rep for %L: '%s'", client, data);

	char exploded[3][35];
	ExplodeString(data, "&", exploded, sizeof(exploded), sizeof(exploded[]));

	if (StrContains(exploded[1], "SCAMMER", false) != -1) {
		LogItem(Log_Debug, "%L is a scammer, handling", client);
		HandleScammer(client, exploded[2]);
	}
	else {
		char apiKey[64];
		cvarSteamAPIKey.GetString(apiKey, sizeof(apiKey));

		if (strlen(apiKey) != 0) {
			LogItem(Log_Debug, "%L is not a SR scammer, checking Steam...", client);

			char steamid[64];
			GetClientAuthId(client, AuthId_SteamID64, steamid, sizeof(steamid));

			request = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, STEAM_API_URL);
			SteamWorks_SetHTTPRequestGetOrPostParameter(request, "key", apiKey);
			SteamWorks_SetHTTPRequestGetOrPostParameter(request, "steamids", steamid);
			SteamWorks_SetHTTPRequestGetOrPostParameter(request, "format", "vdf");
			SteamWorks_SetHTTPCallbacks(request, httpSteamAPIRequestCompleted);
			SteamWorks_SetHTTPRequestContextValue(request, userid);
			SteamWorks_SendHTTPRequest(request);
		}
	}
}

void HandleScammer(int client, const char[] auth) {
	char clientAuth[32];
	GetClientAuthId(client, AuthId_Steam2, clientAuth, sizeof(clientAuth));
	if (!StrEqual(auth, clientAuth)) {
		LogItem(Log_Error, "Steam ID for %L (%s) didn't match SteamRep's response (%s)", client, clientAuth, auth);
		return;
	}

	switch(cvarDealMethod.IntValue) {
		case 0: {
			// Disabled
		}
		case 1: {
			// Chat tag
			if (!LibraryExists("scp")) {
				LogItem(Log_Info, "Simple Chat Processor (Redux) is not loaded, so tags will not be colored in chat.", client);
				return;
			}

			LogItem(Log_Info, "Tagged %L as a scammer", client);

			SetClientTag(client, TagType_Scammer);
		}
		case 2: {
			// Kick
			LogItem(Log_Info, "Kicked %L as a scammer", client);

			KickClient(client, "You are a reported scammer. Visit http://www.steamrep.com for more information");
		}
		case 3: {
			// Ban Steam ID
			LogItem(Log_Info, "Banned %L by Steam ID as a scammer", client);

			if (GetFeatureStatus(FeatureType_Native, "SBBanPlayer") == FeatureStatus_Available) {
				SBPP_BanPlayer(0, client, cvarSteamIDBanLength.IntValue, "Player is a reported scammer via SteamRep.com");
			}
			else {
				BanClient(client, cvarSteamIDBanLength.IntValue, BANFLAG_AUTHID, "Player is a reported scammer via SteamRep.com", "You are a reported scammer. Visit http://www.steamrep.com for more information", "steamrep_checker");
			}
		}
		case 4: {
			// Ban IP
			LogItem(Log_Info, "Banned %L by IP as a scammer", client);

			if (GetFeatureStatus(FeatureType_Native, "SBBanPlayer") == FeatureStatus_Available) {
				// SourceBans doesn't currently expose a native to ban an IP!
				char ip[64];
				GetClientIP(client, ip, sizeof(ip));

				ServerCommand("sm_banip \"%s\" %d A scammer has connected from this IP. Steam ID: %s", ip, cvarIPBanLength.IntValue, clientAuth);
			}
			else {
				char banMessage[256];
				FormatEx(banMessage, sizeof(banMessage), "A scammer has connected from this IP. Steam ID: %s", clientAuth);
				BanClient(client, cvarIPBanLength.IntValue, BANFLAG_IP, banMessage, "You are a reported scammer. Visit http://www.steamrep.com for more information", "steamrep_checker");
			}
		}
		case 5: {
			// Ban Steam ID + IP
			LogItem(Log_Info, "Banned %L by Steam ID and IP as a scammer", client);
			if (GetFeatureStatus(FeatureType_Native, "SBBanPlayer") == FeatureStatus_Available) {
				char ip[64];
				GetClientIP(client, ip, sizeof(ip));

				SBPP_BanPlayer(0, client, cvarSteamIDBanLength.IntValue, "Player is a reported scammer via SteamRep.com");

				ServerCommand("sm_banip \"%s\" %d A scammer has connected from this IP. Steam ID: %s", ip, cvarIPBanLength.IntValue, clientAuth);
			}
			else {
				BanClient(client, cvarSteamIDBanLength.IntValue, BANFLAG_AUTHID, "Player is a reported scammer via SteamRep.com", "You are a reported scammer. Visit http://www.steamrep.com for more information", "steamrep_checker");
				BanClient(client, cvarIPBanLength.IntValue, BANFLAG_IP, "Player is a reported scammer via SteamRep.com", "You are a reported scammer. Visit http://www.steamrep.com for more information", "steamrep_checker");
			}
		}
	}
}

public void httpSteamAPIRequestCompleted(Handle request, bool failure, bool successful, EHTTPStatusCode statusCode, any userid) {
	int client = GetClientOfUserId(userid);
	if (client == 0) {
		LogItem(Log_Debug, "Client with User ID %d left when checking Valve status.", userid);
		delete request;
		return;
	}

	if (failure || !successful) {
		LogItem(Log_Error, "Error checking Steam for client %L. Status code: %i", client, statusCode);
		delete request;
		return;
	}

	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), "data/steamrep_checker.txt");

	SteamWorks_WriteHTTPResponseBodyToFile(request, path);
	delete request;

	KeyValues kv = new KeyValues("response");
	if (!kv.ImportFromFile(path)) {
		LogItem(Log_Error, "Steam returned invalid KeyValues for %L.", client);
		delete kv;
		return;
	}

	kv.JumpToKey("players");
	kv.JumpToKey("0");

	char banStatus[64];
	kv.GetString("EconomyBan", banStatus, sizeof(banStatus));

	delete kv;

	if (StrEqual(banStatus, "banned")) {
		LogItem(Log_Debug, "%L is trade-banned, handling...", client);
		HandleValvePlayer(client, true);
	}
	else if (StrEqual(banStatus, "probation")) {
		LogItem(Log_Debug, "%L is on trade probation, handling...", client);
		HandleValvePlayer(client, false);
	}
	else {
		LogItem(Log_Debug, "Steam reports that %L is OK", client);
	}
}

void HandleValvePlayer(int client, bool banned) {
	char clientAuth[32];
	GetClientAuthId(client, AuthId_Steam2, clientAuth, sizeof(clientAuth));
	switch((banned) ? cvarValveBanDealMethod.IntValue : cvarValveCautionDealMethod.IntValue) {
		case 0: {
			// Disabled
		}
		case 1: {
			// Chat tag
			if (!LibraryExists("scp")) {
				LogItem(Log_Info, "Simple Chat Processor (Redux) is not loaded, so tags will not be colored in chat.", client);
				return;
			}

			LogItem(Log_Info, "Tagged %L as %s", client, banned ? "trade banned" : "trade probation");
			SetClientTag(client, banned ? TagType_TradeBanned : TagType_TradeProbation);
		}
		case 2: {
			// Kick
			LogItem(Log_Info, "Kicked %L as %s", client, banned ? "trade banned" : "trade probation");

			KickClient(client, "You are %s", banned ? "trade banned" : "on trade probation");
		}
		case 3: {
			// Ban Steam ID
			LogItem(Log_Info, "Banned %L by Steam ID as %s", client, banned ? "trade banned" : "trade probation");

			if (GetFeatureStatus(FeatureType_Native, "SBBanPlayer") == FeatureStatus_Available) {
				char message[256];
				FormatEx(message, sizeof(message), "Player is %s", banned ? "trade banned" : "on trade probation");
				SBPP_BanPlayer(0, client, cvarSteamIDBanLength.IntValue, message);
			}
			else {
				char message[256];
				char kickMessage[256];
				FormatEx(message, sizeof(message), "Player is %s", banned ? "trade banned" : "on trade probation");
				FormatEx(kickMessage, sizeof(kickMessage), "You are %s", banned ? "trade banned" : "on trade probation");
				BanClient(client, cvarSteamIDBanLength.IntValue, BANFLAG_AUTHID, message, kickMessage, "steamrep_checker");
			}
		}
		case 4: {
			// Ban IP
			LogItem(Log_Info, "Banned %L by IP as %s", client, banned ? "trade banned" : "trade probation");

			if (GetFeatureStatus(FeatureType_Native, "SBBanPlayer") == FeatureStatus_Available) {
				// SourceBans doesn't currently expose a native to ban an IP!
				ServerCommand("sm_banip #%d %d A %s has connected from this IP. Steam ID: %s", banned ? "trade banned player" : "player on trade probation", GetClientUserId(client), cvarIPBanLength.IntValue, clientAuth);
			}
			else {
				char message[256];
				char kickMessage[256];
				FormatEx(message, sizeof(message), "A %s has connected from this IP. Steam ID: %s", banned ? "trade banned player" : "player on trade probation", clientAuth);
				FormatEx(kickMessage, sizeof(kickMessage), "You are %s", banned ? "trade banned" : "on trade probation");
				BanClient(client, cvarIPBanLength.IntValue, BANFLAG_IP, message, kickMessage, "steamrep_checker");
			}
		}
		case 5: {
			// Ban Steam ID + IP
			LogItem(Log_Info, "Banned %L by Steam ID and IP as %s", client, banned ? "trade banned" : "trade probation");

			if (GetFeatureStatus(FeatureType_Native, "SBBanPlayer") == FeatureStatus_Available) {
				char message[256];
				FormatEx(message, sizeof(message), "Player is %s", banned ? "trade banned" : "on trade probation");
				SBPP_BanPlayer(0, client, cvarSteamIDBanLength.IntValue, message);
				ServerCommand("sm_banip #%d %d A %s has connected from this IP. Steam ID: %s", banned ? "trade banned player" : "player on trade probation", GetClientUserId(client), cvarIPBanLength.IntValue, clientAuth);
			}
			else {
				char message[256];
				char kickMessage[256];
				FormatEx(message, sizeof(message), "A %s has connected from this IP. Steam ID: %s", banned ? "trade banned player" : "player on trade probation", clientAuth);
				FormatEx(kickMessage, sizeof(kickMessage), "You are %s", banned ? "trade banned" : "on trade probation");
				BanClient(client, cvarSteamIDBanLength.IntValue, BANFLAG_AUTHID, message, kickMessage, "steamrep_checker");
				BanClient(client, cvarIPBanLength.IntValue, BANFLAG_IP, message, kickMessage, "steamrep_checker");
			}
		}
	}
}

void SetClientTag(int client, TagType type) {
	char name[MAX_NAME_LENGTH];
	switch(type) {
		case TagType_Scammer: {
			// PrintToChatAll("\x07FF0000WARNING: \x03%N \x01is a reported scammer at SteamRep.com", client);
			FormatEx(name, sizeof(name), "[SCAMMER] %N", client);
			SetClientInfo(client, "name", name);
		}
		case TagType_TradeBanned: {
			// PrintToChatAll("\x07FF0000WARNING: \x03%N \x01is trade banned", client);
			FormatEx(name, sizeof(name), "[TRADE BANNED] %N", client);
			SetClientInfo(client, "name", name);
		}
		case TagType_TradeProbation: {
			// PrintToChatAll("\x07FF7F00CAUTION: \x03%N \x01is on trade probation", client);
			FormatEx(name, sizeof(name), "[TRADE PROBATION] %N", client);
			SetClientInfo(client, "name", name);
		}
	}
	clientTag[client] = type;
}

public Action OnChatMessage(int &author, ArrayList recipients, char[] name, char[] message) {
	switch(clientTag[author]) {
		case TagType_None: return Plugin_Continue;
		case TagType_Scammer: {
			ReplaceString(
				name,
				MAXLENGTH_NAME,
				"[SCAMMER]",
				g_EngineVersion == Engine_TF2 ? "\x07FF0000[SCAMMER]\x03" : "\x02[SCAMMER]\x03"
			);
		}
		case TagType_TradeBanned: {
			ReplaceString(
				name,
				MAXLENGTH_NAME,
				"[TRADE BANNED]",
				g_EngineVersion == Engine_TF2 ? "\x07FF0000[TRADE BANNED]\x03" : "\x02[TRADE BANNED]\x03"
			);
		}
		case TagType_TradeProbation: {
			ReplaceString(
				name,
				MAXLENGTH_NAME,
				"[TRADE PROBATION]",
				g_EngineVersion == Engine_TF2 ? "\x07FF7F00[TRADE PROBATION]\x03" : "\x10[TRADE PROBATION]\x03"
			);
		}
	}
	return Plugin_Changed;
}

public Action CCC_OnColor(int client, const char[] message, CCC_ColorType type) {
	if (type == CCC_TagColor && clientTag[client] != TagType_None) {
		return Plugin_Handled;
	}

	return Plugin_Continue;
}

public void Event_PlayerChangeName(Event event, const char[] name, bool dontBroadcast) {
	int client = GetClientOfUserId(event.GetInt("userid"));

	TagType tagType = clientTag[client];
	if (tagType == TagType_None) {
		return;
	}

	char clientName[MAX_NAME_LENGTH];
	event.GetString("newname", clientName, sizeof(clientName));

	switch (tagType) {
		case TagType_Scammer: {
			if (StrContains(clientName, "[SCAMMER]") != 0) {
				Format(clientName, sizeof(clientName), "[SCAMMER] %s", clientName);
				SetClientName(client, clientName);
			}
		}
		case TagType_TradeBanned: {
			if (StrContains(clientName, "[TRADE BANNED]") != 0) {
				Format(clientName, sizeof(clientName), "[TRADE BANNED] %s", clientName);
				SetClientName(client, clientName);
			}
		}
		case TagType_TradeProbation: {
			if (StrContains(clientName, "[TRADE PROBATION]") != 0) {
				Format(clientName, sizeof(clientName), "[TRADE PROBATION] %s", clientName);
				SetClientName(client, clientName);
			}
		}
	}
}

public Action Command_Rep(int client, int args) {
	int target;
	if (args == 0) {
		target = GetClientAimTarget(client);
		if (target <= 0) {
			DisplayClientMenu(client);
			return Plugin_Handled;
		}
	}
	else {
		char arg1[MAX_NAME_LENGTH];
		GetCmdArg(1, arg1, sizeof(arg1));
		target = FindTargetEx(client, arg1, true, false, false);
		if (target == -1) {
			DisplayClientMenu(client);
			return Plugin_Handled;
		}
	}

	char steamID[64];
	GetClientAuthId(client, AuthId_SteamID64, steamID, sizeof(steamID));

	char url[256];
	FormatEx(url, sizeof(url), "http://steamrep.com/profiles/%s", steamID);

	KeyValues kv = new KeyValues("data");
	kv.SetString("title", "");
	kv.SetString("type", "2");
	kv.SetString("msg", url);
	kv.SetNum("customsvr", 1);

	ShowVGUIPanel(client, "info", kv);

	delete kv;

	return Plugin_Handled;
}

void DisplayClientMenu(int client) {
	Menu menu = new Menu(Handler_ClientMenu);
	menu.SetTitle("Select Player");

	char name[MAX_NAME_LENGTH];
	char index[8];
	for (int i = 1; i <= MaxClients; i++) {
		if (!IsClientInGame(i) || IsFakeClient(i)) {
			continue;
		}

		GetClientName(i, name, sizeof(name));
		IntToString(GetClientUserId(i), index, sizeof(index));

		menu.AddItem(index, name);
	}

	menu.Display(client, 0);
}

public int Handler_ClientMenu(Menu menu, MenuAction action, int client, int param) {
	if (action == MenuAction_End) {
		delete menu;
	}

	if (action != MenuAction_Select) {
		return;
	}

	char selection[32];
	menu.GetItem(param, selection, sizeof(selection));

	FakeClientCommand(client, "sm_rep #%s", selection);
}

int FindTargetEx(int client, const char[] target, bool nobots = false, bool immunity = true, bool replyToError = true) {
	char target_name[MAX_TARGET_LENGTH];
	int target_list[1];
	int target_count;
	bool tn_is_ml;

	int flags = COMMAND_FILTER_NO_MULTI;
	if (nobots) {
		flags |= COMMAND_FILTER_NO_BOTS;
	}
	if (!immunity) {
		flags |= COMMAND_FILTER_NO_IMMUNITY;
	}

	if ((target_count = ProcessTargetString(
			target,
			client,
			target_list,
			1,
			flags,
			target_name,
			sizeof(target_name),
			tn_is_ml)) > 0) {
		return target_list[0];
	}

	if (replyToError) {
		ReplyToTargetError(client, target_count);
	}

	return -1;
}

void LogItem(LogLevel level, const char[] format, any ...) {
	if (cvarLogLevel.IntValue < view_as<int>(level)) {
		return;
	}

	static char logPrefixes[][] = {"[ERROR]", "[INFO]", "[DEBUG]"};

	char buffer[512];
	VFormat(buffer, sizeof(buffer), format, 3);

	char file[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, file, sizeof(file), "logs/steamrep_checker.log");

	LogToFileEx(file, "%s %s", logPrefixes[view_as<int>(level)], buffer);
}
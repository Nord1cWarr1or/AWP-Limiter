#include <amxmodx>
#include <amxmisc>
#include <reapi>

#include <awp_limiter_n>

new const PLUGIN_VERSION[] = "1.3.1 Beta";

#pragma semicolon 1

#define GetCvarDesc(%0) fmt("%L", LANG_SERVER, %0)

#if !defined MAX_MAPNAME_LENGTH
const MAX_MAPNAME_LENGTH = 32;
#endif

const TASKID__CHECK_ONLINE = 10200;

enum _:Cvars {
    PLUGIN_CHAT_PREFIX[32],
    MIN_PLAYERS,
    MAX_AWP,
    LIMIT_TYPE,
    PERCENT_PLAYERS,
    IMMNUNITY_FLAG[2],
    IMMUNITY_TYPE[3],
    SKIP_BOTS,
    SKIP_SPECTATORS,
    MESSAGE_ALLOWED_AWP,
    ROUND_INFINITE,
    GIVE_COMPENSATION,
    CVAR_ROUNDS_PAUSE
};

new g_pCvarValue[Cvars];

enum _:API_FORWARDS {
    LOW_ONLINE_MODE_START,
    LOW_ONLINE_MODE_STOP,
    TRIED_TO_GET_AWP,
    AWP_TAKEN_FROM_PLAYER,
    GIVE_COMPENSATION_FW,
    SHOULD_WORK_ON_MAP
};

new g_iForwardsPointers[API_FORWARDS];
new g_iReturn;

new bool:g_bIsLowOnline = true;
new g_iAWPAmount[TeamName];
new HookChain:g_iHookChain_RoundEnd;
new HookChain:g_iHookChain_PlayerSpawn;
new g_bitImmunityFlags;
new g_iNumAllowedAWP;
new g_iOnlinePlayers;
new bool:IsUserBot[MAX_PLAYERS + 1];
new g_bPauseRoundsRemaining[MAX_PLAYERS + 1];
new Trie:g_iSaveRoundsRemaining;

/* <== DEBUG ==> */

new bool:g_bIsDebugActive;
new g_szLogPach[MAX_RESOURCE_PATH_LENGTH];

/* <====> */

public plugin_init() {
    register_plugin("AWP Limiter", PLUGIN_VERSION, "Nordic Warrior");

    register_dictionary("awp_limiter_n.txt");

    RegisterHookChain(RG_CSGameRules_CanHavePlayerItem,     "RG_CSGameRules_CanHavePlayerItem_pre",     .post = false);
    RegisterHookChain(RG_CBasePlayer_HasRestrictItem,       "RG_CBasePlayer_HasRestrictItem_pre",       .post = false);
    RegisterHookChain(RG_CBasePlayer_AddPlayerItem,         "RG_CBasePlayer_AddPlayerItem_post",        .post = true);
    RegisterHookChain(RG_CSGameRules_RestartRound,          "RG_RestartRound_post",                     .post = true);
    RegisterHookChain(RG_CBasePlayer_RemovePlayerItem,      "RG_CBasePlayer_RemovePlayerItem_post",     .post = true);
    RegisterHookChain(RG_CBasePlayer_Killed,                "RG_CBasePlayer_Killed_pre",                .post = false);

    g_iHookChain_RoundEnd = RegisterHookChain(RG_RoundEnd,              "RG_RoundEnd_post",             .post = true);
    g_iHookChain_PlayerSpawn = RegisterHookChain(RG_CBasePlayer_Spawn,  "RG_CBasePlayer_Spawn_post",    .post = true);

    DisableHookChain(g_iHookChain_PlayerSpawn);

    CreateCvars();

    AutoExecConfig(.name = "AWPLimiter");

    CreateAPIForwards();

    new szMapName[MAX_MAPNAME_LENGTH];
    rh_get_mapname(szMapName, charsmax(szMapName), MNT_TRUE);

    if (IsAwpMap(szMapName)) {
        log_amx("Map <%s> is an AWP map (by name). Plugin was stopped.", szMapName);
        pause("ad");
        return;
    }

    ExecuteForward(g_iForwardsPointers[SHOULD_WORK_ON_MAP], g_iReturn, szMapName);

    if (g_iReturn == AWPL_BREAK) {
        log_amx("Plugin shouldn't work on map <%s> because of API.", szMapName);
        pause("ad");
        return;
    }

    g_iSaveRoundsRemaining = TrieCreate();

    /* <== DEBUG ==> */

    g_bIsDebugActive = bool:(plugin_flags() & AMX_FLAG_DEBUG);

    if (g_bIsDebugActive) {
        new szLogsDir[MAX_RESOURCE_PATH_LENGTH];
        get_localinfo("amxx_logs", szLogsDir, charsmax(szLogsDir));

        add(szLogsDir, charsmax(szLogsDir), "/awpl_debug");

        if (!dir_exists(szLogsDir)) {
            mkdir(szLogsDir);
        }

        new iYear, iMonth, iDay;
        date(iYear, iMonth, iDay);

        formatex(g_szLogPach, charsmax(g_szLogPach), "%s/awpl__%i-%02i-%02i.log", szLogsDir, iYear, iMonth, iDay);

        log_to_file(g_szLogPach, "================================================================");

        debug_log(__LINE__, "Plugin initializated. Map: %s.", szMapName);
    }

    /* <====> */

    // Fix https://github.com/alliedmodders/amxmodx/issues/728#issue-450682936
    // Credits: wopox1337 (https://github.com/ChatAdditions/ChatAdditions_AMXX/commit/47c682051f2d1697a4b3d476f4f3cdd3eb1f6be7)
    set_task(6.274, "_OnConfigsExecuted");
}

public _OnConfigsExecuted() {
    if (g_pCvarValue[ROUND_INFINITE] > 0) {
        DisableHookChain(g_iHookChain_RoundEnd);

        if (!task_exists(TASKID__CHECK_ONLINE)) {
            set_task_ex(float(g_pCvarValue[ROUND_INFINITE]), "CheckOnline", TASKID__CHECK_ONLINE, .flags = SetTask_Repeat);
        }

        debug_log(__LINE__, "Infinite round. Task for check online started.");
    } else if (g_pCvarValue[ROUND_INFINITE] == -1) {
        DisableHookChain(g_iHookChain_RoundEnd);
        EnableHookChain(g_iHookChain_PlayerSpawn);

        debug_log(__LINE__, "Infinite round. Player Spawn hook enabled.");
    }

    g_bitImmunityFlags = read_flags(g_pCvarValue[IMMNUNITY_FLAG]);

    register_cvar("AWPLimiter_version", PLUGIN_VERSION, FCVAR_SERVER | FCVAR_SPONLY | FCVAR_UNLOGGED);
}

public RG_CSGameRules_CanHavePlayerItem_pre(const id, const item) {
    if (get_member(item, m_iId) != WEAPON_AWP) {
        return;
    }

    debug_log(__LINE__, "<CanHavePlayerItem> called. Player: <%n>", id);

    if (g_bitImmunityFlags && get_user_flags(id) & g_bitImmunityFlags) {
        debug_log(__LINE__, "Player has immunity. Skipped.");
        return;
    }

    new AwpRestrictionType:iReason;

    if (!PlayerCanTakeAWP(id, iReason)) {
        ExecuteForward(g_iForwardsPointers[TRIED_TO_GET_AWP], g_iReturn, id, OTHER, iReason);

        if (g_iReturn == AWPL_BREAK) {
            debug_log(__LINE__, "AWP is allowed by API.");
            return;
        }

        debug_log(__LINE__, "Player can't take AWP because of %s.", iReason == LOW_ONLINE ? "low online" : "it's too much in team");

        SendReasonToPlayer(id, iReason);

        SetHookChainReturn(ATYPE_INTEGER, false);
    }
}

public RG_CBasePlayer_HasRestrictItem_pre(const id, ItemID:item, ItemRestType:type) {
    if (item != ITEM_AWP) {
        return;
    }

    if (user_has_awp(id)) {
        return;
    }

    debug_log(__LINE__, "<HasRestrictItem> called. Player: <%n>, Type: %i.", id, type);

    if (g_bitImmunityFlags && get_user_flags(id) & g_bitImmunityFlags) {
        debug_log(__LINE__, "Player has immunity. Skipped.");
        return;
    }

    if (type == ITEM_TYPE_EQUIPPED) {
        new szMapName[MAX_MAPNAME_LENGTH];
        rh_get_mapname(szMapName, charsmax(szMapName), MNT_TRUE);

        log_amx("Map <%s> is an AWP map (by equip). Plugin was stopped.", szMapName);
        pause("ad");

        return;
    }

    new AwpRestrictionType:iReason;

    if (!PlayerCanTakeAWP(id, iReason)) {
        ExecuteForward(g_iForwardsPointers[TRIED_TO_GET_AWP], g_iReturn, id, type == ITEM_TYPE_BUYING ? BUY : TOUCH, iReason);

        if (g_iReturn == AWPL_BREAK) {
            debug_log(__LINE__, "AWP is allowed by API.");
            return;
        }

        SetHookChainReturn(ATYPE_BOOL, true);

        if (type == ITEM_TYPE_TOUCHED) {
            static Float:flGameTime; flGameTime = get_gametime();
            static Float:flNextMessageTime;

            if (flGameTime >= flNextMessageTime) {
                SendReasonToPlayer(id, iReason);
                debug_log(__LINE__, "Player can't take AWP because of %s.", iReason == LOW_ONLINE ? "low online" : "it's too much in team");

                flNextMessageTime = flGameTime + 1.0;
            }

            return;
        }

        SendReasonToPlayer(id, iReason);
        debug_log(__LINE__, "Player can't take AWP because of %s.", iReason == LOW_ONLINE ? "low online" : "it's too much in team");
    }
}

bool:PlayerCanTakeAWP(const id, &AwpRestrictionType:iReason = AWP_ALLOWED) {
    if (g_bIsLowOnline) {
        iReason = LOW_ONLINE;
        return false;
    }

    new TeamName:iPlayerTeam = get_member(id, m_iTeam);

    if (!TeamCanTakeAWP(iPlayerTeam)) {
        iReason = TOO_MANY_AWP_ON_TEAM;
        return false;
    }

    if (g_pCvarValue[CVAR_ROUNDS_PAUSE] > 0 && g_bPauseRoundsRemaining[id] > 0) {
        iReason = ROUNDS_PAUSE;
        return false;
    }

    return true;
}

bool:TeamCanTakeAWP(const TeamName:iTeam) {
    switch (g_pCvarValue[LIMIT_TYPE]) {
        case 1:
        {
            if (g_iAWPAmount[iTeam] >= g_pCvarValue[MAX_AWP]) {
                return false;
            }
        }
        case 2:
        {
            if (g_iAWPAmount[iTeam] >= g_iNumAllowedAWP) {
                return false;
            }
        }
    }

    return true;
}

SendReasonToPlayer(id, AwpRestrictionType:iReason) {
    SetGlobalTransTarget(id);

    switch (iReason) {
        case LOW_ONLINE: client_print_color(id, print_team_red, "%s %l %s", g_pCvarValue[PLUGIN_CHAT_PREFIX], "CHAT_LOW_ONLINE", g_pCvarValue[MIN_PLAYERS], g_pCvarValue[SKIP_SPECTATORS] ? fmt("%l", "CHAT_WITHOUT_SPECTATORS") : "");
        case TOO_MANY_AWP_ON_TEAM: client_print_color(id, print_team_red, "%s %l", g_pCvarValue[PLUGIN_CHAT_PREFIX], "CHAT_TOO_MANY_AWP_PER_TEAM", g_pCvarValue[LIMIT_TYPE] == 1 ? g_pCvarValue[MAX_AWP] : g_iNumAllowedAWP);
        case ROUNDS_PAUSE: client_print_color(id, print_team_red, "%s %l", g_pCvarValue[PLUGIN_CHAT_PREFIX], "CHAT_ROUNDS_PAUSE", g_pCvarValue[CVAR_ROUNDS_PAUSE]);
    }
}

public RG_CBasePlayer_AddPlayerItem_post(const id, const pItem) {
    if (g_bIsLowOnline) {
        return;
    }

    if (get_member(pItem, m_iId) != WEAPON_AWP) {
        return;
    }

    debug_log(__LINE__, "<AddPlayerItem> called. Player: <%n>", id);

    if (g_pCvarValue[SKIP_BOTS] && IsUserBot[id]) {
        debug_log(__LINE__, "Player is bot. Skipped.");
        return;
    }

    new TeamName:iUserTeam = get_member(id, m_iTeam);

    g_iAWPAmount[iUserTeam]++;

    debug_log(__LINE__, "(+) Now it's [ %i ] AWP in %i team", g_iAWPAmount[iUserTeam], iUserTeam);
}

public client_disconnected(id) {
    if (!is_user_connected(id)) {
        return;
    }

    debug_log(__LINE__, "<client_disconnected> called. Player: <%n>", id);

    new szAuthID[MAX_AUTHID_LENGTH];
    get_user_authid(id, szAuthID, charsmax(szAuthID));

    TrieSetCell(g_iSaveRoundsRemaining, szAuthID, g_bPauseRoundsRemaining[id]);

    if (!user_has_awp(id)) {
        return;
    }

    if (IsUserBot[id]) {
        IsUserBot[id] = false;

        if (g_pCvarValue[SKIP_BOTS]) {
            debug_log(__LINE__, "Player is bot. Skipped.");
            return;
        }
    }

    new TeamName:iUserTeam = get_member(id, m_iTeam);

    g_iAWPAmount[iUserTeam]--;

    debug_log(__LINE__, "(-) Player has AWP. Now it's [ %i ] AWP in %i team", g_iAWPAmount[iUserTeam], iUserTeam);
}

public RG_CBasePlayer_RemovePlayerItem_post(const id, const pItem) {
    if (g_bIsLowOnline) {
        return;
    }

    if (get_member(pItem, m_iId) != WEAPON_AWP) {
        return;
    }

    debug_log(__LINE__, "<RemovePlayerItem> called. Player: <%n>", id);

    if (g_pCvarValue[SKIP_BOTS] && IsUserBot[id]) {
        debug_log(__LINE__, "Player is bot. Skipped.");
        return;
    }

    new TeamName:iUserTeam = get_member(id, m_iTeam);

    g_iAWPAmount[iUserTeam]--;

    debug_log(__LINE__, "(-) Now it's [ %i ] AWP in %i team", g_iAWPAmount[iUserTeam], iUserTeam);
}

public RG_CBasePlayer_Killed_pre(const id, pevAttacker, iGib) {
    if (g_pCvarValue[CVAR_ROUNDS_PAUSE] == 0) {
        return;
    }

    if (g_bIsLowOnline) {
        return;
    }

    if (!user_has_awp(id)) {
        return;
    }

    if (g_bPauseRoundsRemaining[id] > 0) {
        return;
    }

    g_bPauseRoundsRemaining[id] = -1;

    debug_log(__LINE__, "<PlayerKilled> called. Player: <%n>. Set g_bPauseRoundsRemaining to -1", id);
}

public client_putinserver(id) {
    if (is_user_bot(id)) {
        IsUserBot[id] = true;
    }

    new szAuthID[MAX_AUTHID_LENGTH];
    get_user_authid(id, szAuthID, charsmax(szAuthID));

    TrieGetCell(g_iSaveRoundsRemaining, szAuthID, g_bPauseRoundsRemaining[id]);
}

public RG_RestartRound_post() {
    arrayset(g_iAWPAmount[TEAM_UNASSIGNED], 0, sizeof g_iAWPAmount);

    debug_log(__LINE__, "--> New round has started. <--");

    new bool:bCompleteReset = get_member_game(m_bCompleteReset);

    for (new id = 1; id <= MaxClients; id++) {
        if (!is_user_alive(id)) {
            continue;
        }

        if (g_pCvarValue[SKIP_BOTS] && is_user_bot(id)) {
            continue;
        }

        if (bCompleteReset) {
            g_bPauseRoundsRemaining[id] = 0;
            TrieClear(g_iSaveRoundsRemaining);
            continue;
        }

        if (user_has_awp(id)) {
            g_iAWPAmount[get_member(id, m_iTeam)]++;
            continue;
        }

        if (g_bPauseRoundsRemaining[id] == -1) {
            g_bPauseRoundsRemaining[id] = g_pCvarValue[CVAR_ROUNDS_PAUSE];
        } else if (g_bPauseRoundsRemaining[id] > 0) {
            g_bPauseRoundsRemaining[id]--;
        }
    }

    debug_log(__LINE__, "Now it's [ %i ] AWP in CT team & [ %i ] AWP in TE team.", g_iAWPAmount[TEAM_CT], g_iAWPAmount[TEAM_TERRORIST]);
}

public RG_CBasePlayer_Spawn_post(const id) {
    if (!is_user_alive(id)) {
        return;
    }

    CheckOnline();
}

public RG_RoundEnd_post(WinStatus:status, ScenarioEventEndRound:event, Float:tmDelay) {
    debug_log(__LINE__, "--> Round is ended. <--");

    CheckOnline();
}

public CheckOnline() {
    GetOnlinePlayers();

    debug_log(__LINE__, "<CheckOnline> called. Online players: [ %i ].%s", g_iOnlinePlayers, g_pCvarValue[SKIP_SPECTATORS] ? " Spectators skipped." : "");

    if (!g_iOnlinePlayers) {
        g_bIsLowOnline = true;
        return;
    }

    if (g_iOnlinePlayers < g_pCvarValue[MIN_PLAYERS]) {
        if (!g_bIsLowOnline) {
            SetLowOnlineMode();
        }

        return;
    } else {
        if (g_bIsLowOnline) {
            UnsetLowOnlineMode();
        }
    }

    CheckTeamLimit();
}

GetOnlinePlayers() {
    new iNumCT = get_playersnum_ex(g_pCvarValue[SKIP_BOTS] ? (GetPlayers_ExcludeBots | GetPlayers_ExcludeHLTV | GetPlayers_MatchTeam) : (GetPlayers_ExcludeHLTV | GetPlayers_MatchTeam), "CT");
    new iNumTE = get_playersnum_ex(g_pCvarValue[SKIP_BOTS] ? (GetPlayers_ExcludeBots | GetPlayers_ExcludeHLTV | GetPlayers_MatchTeam) : (GetPlayers_ExcludeHLTV | GetPlayers_MatchTeam), "TERRORIST");

    g_iOnlinePlayers = iNumCT + iNumTE;

    if (!g_pCvarValue[SKIP_SPECTATORS]) {
        g_iOnlinePlayers += get_playersnum_ex(GetPlayers_ExcludeBots | GetPlayers_ExcludeHLTV | GetPlayers_MatchTeam, "SPECTATOR");
    }
}

SetLowOnlineMode() {
    ExecuteForward(g_iForwardsPointers[LOW_ONLINE_MODE_START], g_iReturn);

    if (g_iReturn == AWPL_BREAK) {
        debug_log(__LINE__, "Low online mode can't start because of API.");
        CheckTeamLimit();
        return;
    }

    g_bIsLowOnline = true;

    TakeAllAwps();

    debug_log(__LINE__, "Low online mode has started.");
}

UnsetLowOnlineMode() {
    ExecuteForward(g_iForwardsPointers[LOW_ONLINE_MODE_STOP], g_iReturn);

    if (g_iReturn == AWPL_BREAK) {
        debug_log(__LINE__, "Low online mode can't stop because of API.");
        return;
    }

    g_bIsLowOnline = false;

    if (g_pCvarValue[MESSAGE_ALLOWED_AWP]) {
        client_print_color(0, print_team_blue, "%s %l", g_pCvarValue[PLUGIN_CHAT_PREFIX], "CHAT_AWP_BECAME_AVALIABLE");
    }

    debug_log(__LINE__, "Low online mode has stopped.");
}

CheckTeamLimit() {
    switch (g_pCvarValue[LIMIT_TYPE]) {
        case 1: {
            debug_log(__LINE__, "Limit type: 1. Max AWP per team: %i", g_pCvarValue[MAX_AWP]);

            if (g_iAWPAmount[TEAM_TERRORIST] > g_pCvarValue[MAX_AWP]) {
                TakeAwpsFromTeam(TEAM_TERRORIST);
            }

            if (g_iAWPAmount[TEAM_CT] > g_pCvarValue[MAX_AWP]) {
                TakeAwpsFromTeam(TEAM_CT);
            }
        }
        case 2: {
            g_iNumAllowedAWP = floatround(g_iOnlinePlayers * (g_pCvarValue[PERCENT_PLAYERS] / 100.0), floatround_floor);

            debug_log(__LINE__, "Limit type: 2. Cvar percent: %i, calculated num of max AWP per team: %i", g_pCvarValue[PERCENT_PLAYERS], g_iNumAllowedAWP);

            if (g_iNumAllowedAWP < 1) {
                g_iNumAllowedAWP = 1;

                debug_log(__LINE__, "The AWP limit is less than one, so it was set to 1.", g_pCvarValue[PERCENT_PLAYERS], g_iNumAllowedAWP);
            }

            if (g_iAWPAmount[TEAM_TERRORIST] > g_iNumAllowedAWP) {
                TakeAwpsFromTeam(TEAM_TERRORIST);
            }

            if (g_iAWPAmount[TEAM_CT] > g_iNumAllowedAWP) {
                TakeAwpsFromTeam(TEAM_CT);
            }
        }
    }
}

TakeAllAwps() {
    new TeamName:iUserTeam;

    for (new id = 1; id <= MaxClients; id++) {
        if (!is_user_alive(id)) {
            continue;
        }

        if (g_pCvarValue[SKIP_BOTS] && is_user_bot(id)) {
            continue;
        }

        if (!user_has_awp(id)) {
            continue;
        }

        ExecuteForward(g_iForwardsPointers[AWP_TAKEN_FROM_PLAYER], g_iReturn, id, LOW_ONLINE);

        if (g_iReturn == AWPL_BREAK) {
            debug_log(__LINE__, "AWP is not taken from player because of API.");
            continue;
        }

        rg_remove_item(id, "weapon_awp");

        iUserTeam = get_member(id, m_iTeam);

        g_iAWPAmount[iUserTeam]--;

        client_print_color(id, print_team_red, "%s %l %l", g_pCvarValue[PLUGIN_CHAT_PREFIX], "CHAT_AWP_TAKEN_AWAY", "CHAT_REASON_LOW_ONLINE");

        GiveCompensation(id);

        debug_log(__LINE__, "(-) Now it's [ %i ] AWP in %i team", g_iAWPAmount[iUserTeam], iUserTeam);
    }
}

TakeAwpsFromTeam(TeamName:iTeam) {
    debug_log(__LINE__, "<TakeAwpsFromTeam> called for %i team.", iTeam);

    new iPlayers[MAX_PLAYERS], iPlayersNum;
    new GetPlayersFlags:iGetPlayersFlags = (GetPlayers_ExcludeDead | GetPlayers_ExcludeHLTV);

    if (g_pCvarValue[SKIP_BOTS]) {
        iGetPlayersFlags |= GetPlayers_ExcludeBots;
    }

    get_players_ex(iPlayers, iPlayersNum, iGetPlayersFlags);
    SortIntegers(iPlayers, sizeof iPlayers, Sort_Random);

    for (new i, id; i <= MAX_PLAYERS; i++) {
        id = iPlayers[i];

        if (!id) {
            continue;
        }

        if (!user_has_awp(id)) {
            continue;
        }

        ExecuteForward(g_iForwardsPointers[AWP_TAKEN_FROM_PLAYER], g_iReturn, id, TOO_MANY_AWP_ON_TEAM);

        if (g_iReturn == AWPL_BREAK) {
            debug_log(__LINE__, "AWP is not taken from player because of API.");
            continue;
        }

        rg_remove_item(id, "weapon_awp");

        client_print_color(id, print_team_red, "%s %l %l", g_pCvarValue[PLUGIN_CHAT_PREFIX], "CHAT_AWP_TAKEN_AWAY", "CHAT_REASON_TOO_MANY_AWP_PER_TEAM");

        GiveCompensation(id);

        if (g_pCvarValue[LIMIT_TYPE] == 1 && g_iAWPAmount[iTeam] <= g_pCvarValue[MAX_AWP]) {
            break;
        } else if (g_pCvarValue[LIMIT_TYPE] == 2 && g_iAWPAmount[iTeam] <= g_iNumAllowedAWP) {
            break;
        }
    }
}

GiveCompensation(const id) {
    if (!g_pCvarValue[GIVE_COMPENSATION]) {
        return;
    }

    ExecuteForward(g_iForwardsPointers[GIVE_COMPENSATION_FW], g_iReturn, id);

    if (g_iReturn == AWPL_BREAK) {
        return;
    }

    switch (g_pCvarValue[GIVE_COMPENSATION]) {
        case -1: {
            if (random_num(0, 1)) {
                rg_give_item(id, "weapon_ak47");
                rg_set_user_bpammo(id, WEAPON_AK47, 90);
            } else {
                rg_give_item(id, "weapon_m4a1");
                rg_set_user_bpammo(id, WEAPON_M4A1, 90);
            }

            client_print_color(id, print_team_blue, "%s %l", g_pCvarValue[PLUGIN_CHAT_PREFIX], "CHAT_COMPENSATION_RIFLE");
        }
        default: {
            rg_add_account(id, g_pCvarValue[GIVE_COMPENSATION]);
            client_print_color(id, print_team_blue, "%s %l", g_pCvarValue[PLUGIN_CHAT_PREFIX], "CHAT_COMPENSATION_MONEY", g_pCvarValue[GIVE_COMPENSATION]);
        }
    }
}

CreateCvars() {
    new pCvar;

    bind_pcvar_string(create_cvar("awpl_chat_prefix", "^3[^4AWP^3]",
        .description = "Plugin prefix."),
    g_pCvarValue[PLUGIN_CHAT_PREFIX], charsmax(g_pCvarValue[PLUGIN_CHAT_PREFIX]));

    bind_pcvar_num(create_cvar("awpl_min_players", "10",
        .description = GetCvarDesc("CVAR_MIN_PLAYERS")),
    g_pCvarValue[MIN_PLAYERS]);

    bind_pcvar_num(create_cvar("awpl_limit_type", "1",
        .description = GetCvarDesc("CVAR_LIMIT_TYPE"),
        .has_min = true, .min_val = 1.0,
        .has_max = true, .max_val = 2.0),
    g_pCvarValue[LIMIT_TYPE]);

    bind_pcvar_num(create_cvar("awpl_max_awp", "2",
        .description = GetCvarDesc("CVAR_MAX_AWP"),
        .has_min = true, .min_val = 1.0),
    g_pCvarValue[MAX_AWP]);

    bind_pcvar_num(create_cvar("awpl_percent_players", "10",
        .description = GetCvarDesc("CVAR_PERCENT_PLAYERS")),
    g_pCvarValue[PERCENT_PLAYERS]);

    bind_pcvar_string(pCvar = create_cvar("awpl_immunity_flag", "a",
        .description = GetCvarDesc("CVAR_IMMUNITY_FLAG")),
    g_pCvarValue[IMMNUNITY_FLAG], charsmax(g_pCvarValue[IMMNUNITY_FLAG]));

    hook_cvar_change(pCvar, "OnChangeCvar_Immunity");

    // bind_pcvar_string(create_cvar("awpl_immunity_type", "abc",
    //     .description = "Иммунитет от запрета:^na — Покупки AWP^nb — Поднятия с земли^nc — Взятия в различных меню"),
    // g_pCvarValue[IMMUNITY_TYPE], charsmax(g_pCvarValue[IMMUNITY_TYPE]));

    bind_pcvar_num(create_cvar("awpl_skip_bots", "0",
        .description = GetCvarDesc("CVAR_SKIP_BOTS"),
        .has_min = true, .min_val = 0.0,
        .has_max = true, .max_val = 1.0),
    g_pCvarValue[SKIP_BOTS]);

    bind_pcvar_num(create_cvar("awpl_skip_spectators", "1",
        .description = GetCvarDesc("CVAR_SKIP_SPECTATORS"),
        .has_min = true, .min_val = 0.0,
        .has_max = true, .max_val = 1.0),
    g_pCvarValue[SKIP_SPECTATORS]);

    bind_pcvar_num(create_cvar("awpl_message_allow_awp", "1",
        .description = GetCvarDesc("CVAR_MESSAGE_AWLLOW_AWP"),
        .has_min = true, .min_val = 0.0,
        .has_max = true, .max_val = 1.0),
    g_pCvarValue[MESSAGE_ALLOWED_AWP]);

    bind_pcvar_num(pCvar = create_cvar("awpl_round_infinite", "0",
        .description = GetCvarDesc("CVAR_ROUND_INFINITE"),
        .has_min = true, .min_val = -1.0),
    g_pCvarValue[ROUND_INFINITE]);

    hook_cvar_change(pCvar, "OnChangeCvar_RoundInfinite");

    bind_pcvar_num(create_cvar("awpl_give_compensation", "-1",
        .description = GetCvarDesc("CVAR_GIVE_COMPENSATION"),
        .has_min = true, .min_val = -1.0),
    g_pCvarValue[GIVE_COMPENSATION]);

    bind_pcvar_num(create_cvar("awpl_rounds_pause_num", "0",
        .description = GetCvarDesc("CVAR_ROUNDS_PAUSE"),
        .has_min = true, .min_val = 0.0),
    g_pCvarValue[CVAR_ROUNDS_PAUSE]);
}

public OnChangeCvar_RoundInfinite(pCvar, const szOldValue[], const szNewValue[]) {
    debug_log(__LINE__, "Cvar <awpl_round_infinite> changed. Old: %s. New: %s", szOldValue, szNewValue);

    new iNewValue = str_to_num(szNewValue);

    if (iNewValue > 0) {
        DisableHookChain(g_iHookChain_RoundEnd);
        DisableHookChain(g_iHookChain_PlayerSpawn);

        if (!task_exists(TASKID__CHECK_ONLINE)) {
            set_task_ex(float(g_pCvarValue[ROUND_INFINITE]), "CheckOnline", TASKID__CHECK_ONLINE, .flags = SetTask_Repeat);
        } else {
            change_task(TASKID__CHECK_ONLINE, float(iNewValue));
        }

        CheckOnline();
    } else if (iNewValue == -1)    {
        DisableHookChain(g_iHookChain_RoundEnd);
        remove_task(TASKID__CHECK_ONLINE);
        EnableHookChain(g_iHookChain_PlayerSpawn);
    } else {
        EnableHookChain(g_iHookChain_RoundEnd);
        DisableHookChain(g_iHookChain_PlayerSpawn);
        remove_task(TASKID__CHECK_ONLINE);
    }
}

public OnChangeCvar_Immunity(pCvar, const szOldValue[], const szNewValue[]) {
    debug_log(__LINE__, "Cvar <awpl_immunity_flag> changed. Old: %s. New: %s", szOldValue, szNewValue);

    g_bitImmunityFlags = read_flags(szNewValue);
}

IsAwpMap(const szMapName[]) {
    if (equali(szMapName, "awp_", 4)) {
        return true;
    }

    return false;
}

CreateAPIForwards() {
    g_iForwardsPointers[LOW_ONLINE_MODE_START]  = CreateMultiForward("awpl_low_online_start", ET_STOP);
    g_iForwardsPointers[LOW_ONLINE_MODE_STOP]   = CreateMultiForward("awpl_low_online_stop", ET_STOP);
    g_iForwardsPointers[TRIED_TO_GET_AWP]       = CreateMultiForward("awpl_player_tried_to_get_awp", ET_STOP, FP_CELL, FP_CELL, FP_CELL);
    g_iForwardsPointers[AWP_TAKEN_FROM_PLAYER]  = CreateMultiForward("awpl_awp_taken_from_player", ET_STOP, FP_CELL, FP_CELL);
    g_iForwardsPointers[GIVE_COMPENSATION_FW]   = CreateMultiForward("awpl_give_compensation", ET_STOP, FP_CELL);
    g_iForwardsPointers[SHOULD_WORK_ON_MAP]     = CreateMultiForward("awpl_plugin_should_work_on_this_map", ET_STOP, FP_STRING);
}

public plugin_natives() {
    register_native("awpl_is_low_online", "native_awpl_is_low_online");
    register_native("awpl_set_low_online", "native_awpl_set_low_online");
    register_native("awpl_can_team_take_awp", "native_awpl_can_team_take_awp");
    register_native("awpl_can_player_take_awp", "native_awpl_can_player_take_awp");
}

public native_awpl_is_low_online(iPlugin, iParams) {
    return g_bIsLowOnline;
}

public native_awpl_set_low_online(iPlugin, iParams) {
    new bool:bSet = bool:get_param(1);

    GetOnlinePlayers();

    if (bSet) {
        debug_log(__LINE__, "Low online mode is set via native.");
        SetLowOnlineMode();
    } else {
        debug_log(__LINE__, "Low online mode is unset via native.");
        UnsetLowOnlineMode();
        CheckTeamLimit();
    }
}

public native_awpl_can_team_take_awp(iPlugin, iParams) {
    new TeamName:iTeam = TeamName:get_param(1);

    return TeamCanTakeAWP(iTeam);
}

public native_awpl_can_player_take_awp(iPlugin, iParams) {
    enum { index = 1, reason };

    new id = get_param(index);

    new AwpRestrictionType:iReason;

    new bool:bCanTakeAWP = PlayerCanTakeAWP(id, iReason);

    set_param_byref(reason, any:iReason);
    return bCanTakeAWP;
}

public plugin_end() {
    if (g_bIsDebugActive) {
        log_to_file(g_szLogPach, "================================================================^n");
    }
}

stock bool:user_has_awp(const id) {
    return rg_has_item_by_name(id, "weapon_awp");
}

/* <== DEBUG ==> */

debug_log(const iLine, const szText[], any: ...) {
    if (!g_bIsDebugActive) {
        return;
    }

    static szLogText[512];
    vformat(szLogText, charsmax(szLogText), szText, 3);

    format(szLogText, charsmax(szLogText), "[AWPL DEBUG] %s | LINE: %i", szLogText, iLine);

    log_to_file(g_szLogPach, szLogText);
}

/* <====> */

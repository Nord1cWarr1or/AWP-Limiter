#include <amxmodx>
#include <amxmisc>
#include <reapi>

#include <awp_limiter_n>

new const PLUGIN_VERSION[] = "1.1.0 Beta";

#pragma semicolon 1

// Based on code by: Kaido Ren, Garey
#define FOREACHPLAYER(%0,%1,%2,%3) new __players[MAX_PLAYERS], %0, %1; \
    %1 *= 1; \
    get_players_ex(__players, %0, %2, %3); \
    for (new i, %1 = __players[i]; i < %0; %1 = __players[++i])

#if !defined MAX_MAPNAME_LENGTH
const MAX_MAPNAME_LENGTH = 32;
#endif

new g_szMapName[MAX_MAPNAME_LENGTH];

const TASKID__CHECK_ONLINE = 10200;

enum _:Cvars
{
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
    GIVE_COMPENSATION
};

new g_pCvarValue[Cvars];

enum _:API_FORWARDS
{
    LOW_ONLINE_MODE_START,
    LOW_ONLINE_MODE_STOP,
    TRIED_TO_GET_AWP,
    AWP_TAKEN_FROM_PLAYER,
    GIVE_COMPENSATION_FW
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

/* <== DEBUG ==> */

new bool:g_bIsDebugActive;
new g_szLogPach[MAX_RESOURCE_PATH_LENGTH];

/* <====> */

public plugin_init()
{
    register_plugin("AWP Limiter", PLUGIN_VERSION, "Nordic Warrior");

    if(IsAwpMap())
    {
        log_amx("Map <%s> is an AWP map (by name). Plugin was stopped.", g_szMapName);
        pause("ad");

        return;
    }

    RegisterHookChain(RG_CSGameRules_CanHavePlayerItem,     "RG_CSGameRules_CanHavePlayerItem_pre",     .post = false);
    RegisterHookChain(RG_CBasePlayer_HasRestrictItem,       "RG_CBasePlayer_HasRestrictItem_pre",       .post = false);
    RegisterHookChain(RG_CBasePlayer_AddPlayerItem,         "RG_CBasePlayer_AddPlayerItem_post",        .post = true);
    RegisterHookChain(RH_SV_DropClient,                     "RH_SV_DropClient_pre",                     .post = false);
    RegisterHookChain(RG_CSGameRules_RestartRound,          "RG_RestartRound_post",                     .post = true);
    RegisterHookChain(RG_CBasePlayer_RemovePlayerItem,      "RG_CBasePlayer_RemovePlayerItem_post",     .post = true);

    g_iHookChain_RoundEnd = RegisterHookChain(RG_RoundEnd,              "RG_RoundEnd_post",             .post = true);
    g_iHookChain_PlayerSpawn = RegisterHookChain(RG_CBasePlayer_Spawn,  "RG_CBasePlayer_Spawn_post",    .post = true);

    DisableHookChain(g_iHookChain_PlayerSpawn);

    CreateCvars();

    AutoExecConfig(.name = "AWPLimiter");

    CreateAPIForwards();

    /* <== DEBUG ==> */

    g_bIsDebugActive = bool:(plugin_flags() & AMX_FLAG_DEBUG);

    if(g_bIsDebugActive)
    {
        new szLogsDir[MAX_RESOURCE_PATH_LENGTH];
        get_localinfo("amxx_logs", szLogsDir, charsmax(szLogsDir));

        add(szLogsDir, charsmax(szLogsDir), "/awpl_debug");

        if(!dir_exists(szLogsDir))
            mkdir(szLogsDir);

        new iYear, iMonth, iDay;
        date(iYear, iMonth, iDay);

        formatex(g_szLogPach, charsmax(g_szLogPach), "%s/awpl__%i-%02i-%02i.log", szLogsDir, iYear, iMonth, iDay);

        log_to_file(g_szLogPach, "================================================================");

        debug_log(__LINE__, "Plugin initializated. Map: %s.", g_szMapName);
    }

    /* <====> */

    // Fix https://github.com/alliedmodders/amxmodx/issues/728#issue-450682936
    // Credits: wopox1337 (https://github.com/ChatAdditions/ChatAdditions_AMXX/commit/47c682051f2d1697a4b3d476f4f3cdd3eb1f6be7)
    set_task(6.274, "_OnConfigsExecuted");
}

public _OnConfigsExecuted()
{
    if(g_pCvarValue[ROUND_INFINITE] > 0)
    {
        DisableHookChain(g_iHookChain_RoundEnd);

        if(!task_exists(TASKID__CHECK_ONLINE))
        {
            set_task_ex(float(g_pCvarValue[ROUND_INFINITE]), "CheckOnline", TASKID__CHECK_ONLINE, .flags = SetTask_Repeat);
        }

        debug_log(__LINE__, "Infinite round. Task for check online started.");
    }
    else if(g_pCvarValue[ROUND_INFINITE] == -1)
    {
        DisableHookChain(g_iHookChain_RoundEnd);
        EnableHookChain(g_iHookChain_PlayerSpawn);

        debug_log(__LINE__, "Infinite round. Player Spawn hook enabled.");
    }

    g_bitImmunityFlags = read_flags(g_pCvarValue[IMMNUNITY_FLAG]);

    register_cvar("AWPLimiter_version", PLUGIN_VERSION, FCVAR_SERVER|FCVAR_SPONLY|FCVAR_UNLOGGED);
}

public RG_CSGameRules_CanHavePlayerItem_pre(const id, const item)
{
    if(get_member(item, m_iId) != WEAPON_AWP)
        return;

    debug_log(__LINE__, "<CanHavePlayerItem> called. Player: <%n>", id);

    if(g_bitImmunityFlags && get_user_flags(id) & g_bitImmunityFlags)
    {
        debug_log(__LINE__, "Player has immunity. Skipped.");
        return;
    }

    if(g_bIsLowOnline)
    {
        ExecuteForward(g_iForwardsPointers[TRIED_TO_GET_AWP], g_iReturn, id, OTHER, LOW_ONLINE);

        if(g_iReturn == AWPL_BREAK)
        {
            debug_log(__LINE__, "AWP is allowed by API.");
            return;
        }

        client_print_color(id, print_team_red, "^3[^4AWP^3] ^3Недостаточно игроков на сервере, ^1чтобы взять ^4AWP^1. Необходимо: ^4%i^1.%s", g_pCvarValue[MIN_PLAYERS], g_pCvarValue[SKIP_SPECTATORS] ? " ^3(без учёта зрителей)" : "");

        debug_log(__LINE__, "Player can't take AWP because of low online.");

        SetHookChainReturn(ATYPE_INTEGER, false);
    }
    else
    {
        if(g_pCvarValue[LIMIT_TYPE] == 1 && g_iAWPAmount[get_member(id, m_iTeam)] >= g_pCvarValue[MAX_AWP] || \
            g_pCvarValue[LIMIT_TYPE] == 2 && g_iAWPAmount[get_member(id, m_iTeam)] >= g_iNumAllowedAWP)
        {
            ExecuteForward(g_iForwardsPointers[TRIED_TO_GET_AWP], g_iReturn, id, OTHER, TOO_MANY_AWP_ON_TEAM);

            if(g_iReturn == AWPL_BREAK)
            {
                debug_log(__LINE__, "AWP is allowed by API.");
                return;
            }

            client_print_color(id, print_team_red, "^3[^4AWP^3] ^3Слишком много ^4AWP ^3в команде. ^1Максимально: ^4%i^1.", g_pCvarValue[LIMIT_TYPE] == 1 ? g_pCvarValue[MAX_AWP] : g_iNumAllowedAWP);

            debug_log(__LINE__, "Player can't take AWP because of it's too much in team.");

            SetHookChainReturn(ATYPE_INTEGER, false);
        }
    }
}

public RG_CBasePlayer_HasRestrictItem_pre(const id, ItemID:item, ItemRestType:type)
{
    if(item != ITEM_AWP)
        return;

    if(user_has_awp(id))
        return;

    debug_log(__LINE__, "<HasRestrictItem> called. Player: <%n>, Type: %i.", id, type);

    if(g_bitImmunityFlags && get_user_flags(id) & g_bitImmunityFlags)
    {
        debug_log(__LINE__, "Player has immunity. Skipped.");
        return;
    }

    switch(type)
    {
        case ITEM_TYPE_BUYING:
        {
            if(g_bIsLowOnline)
            {
                ExecuteForward(g_iForwardsPointers[TRIED_TO_GET_AWP], g_iReturn, id, BUY, LOW_ONLINE);

                if(g_iReturn == AWPL_BREAK)
                {
                    debug_log(__LINE__, "AWP is allowed by API.");
                    return;
                }

                client_print_color(id, print_team_red, "^3[^4AWP^3] ^3Недостаточно игроков на сервере, ^1чтобы купить ^4AWP^1. Необходимо: ^4%i^1.%s", g_pCvarValue[MIN_PLAYERS], g_pCvarValue[SKIP_SPECTATORS] ? " ^3(без учёта зрителей)" : "");

                debug_log(__LINE__, "Player can't buy AWP because of low online.");

                SetHookChainReturn(ATYPE_BOOL, true);
            }
            else
            {
                if(g_pCvarValue[LIMIT_TYPE] == 1 && g_iAWPAmount[get_member(id, m_iTeam)] >= g_pCvarValue[MAX_AWP] || \
                    g_pCvarValue[LIMIT_TYPE] == 2 && g_iAWPAmount[get_member(id, m_iTeam)] >= g_iNumAllowedAWP)
                {
                    ExecuteForward(g_iForwardsPointers[TRIED_TO_GET_AWP], g_iReturn, id, BUY, TOO_MANY_AWP_ON_TEAM);

                    if(g_iReturn == AWPL_BREAK)
                    {
                        debug_log(__LINE__, "AWP is allowed by API.");
                        return;
                    }

                    client_print_color(id, print_team_red, "^3[^4AWP^3] ^3Слишком много ^4AWP ^3в команде. ^1Максимально: ^4%i^1.", g_pCvarValue[LIMIT_TYPE] == 1 ? g_pCvarValue[MAX_AWP] : g_iNumAllowedAWP);

                    debug_log(__LINE__, "Player can't buy AWP because of it's too much in team.");

                    SetHookChainReturn(ATYPE_BOOL, true);
                }
            }
        }
        case ITEM_TYPE_TOUCHED:
        {
            static iSendMessage = -1;
            iSendMessage++;

            if(g_bIsLowOnline)
            {
                ExecuteForward(g_iForwardsPointers[TRIED_TO_GET_AWP], g_iReturn, id, TOUCH, LOW_ONLINE);

                if(g_iReturn == AWPL_BREAK)
                {
                    debug_log(__LINE__, "AWP is allowed by API.");
                    return;
                }

                if(iSendMessage == 0)
                {
                    client_print_color(id, print_team_red, "^3[^4AWP^3] ^3Недостаточно игроков на сервере, ^1чтобы взять ^4AWP^1. Необходимо: ^4%i^1.%s", g_pCvarValue[MIN_PLAYERS], g_pCvarValue[SKIP_SPECTATORS] ? " ^3(без учёта зрителей)" : "");
                }
                else if(iSendMessage > 100)
                {
                    iSendMessage = -1;
                }

                debug_log(__LINE__, "Player can't take AWP from ground because of low online.");

                SetHookChainReturn(ATYPE_BOOL, true);
            }
            else
            {
                if(g_pCvarValue[LIMIT_TYPE] == 1 && g_iAWPAmount[get_member(id, m_iTeam)] >= g_pCvarValue[MAX_AWP] || \
                    g_pCvarValue[LIMIT_TYPE] == 2 && g_iAWPAmount[get_member(id, m_iTeam)] >= g_iNumAllowedAWP)
                {
                    ExecuteForward(g_iForwardsPointers[TRIED_TO_GET_AWP], g_iReturn, id, TOUCH, TOO_MANY_AWP_ON_TEAM);

                    if(g_iReturn == AWPL_BREAK)
                    {
                        debug_log(__LINE__, "AWP is allowed by API.");
                        return;
                    }

                    if(iSendMessage == 0)
                    {
                        client_print_color(id, print_team_red, "^3[^4AWP^3] ^3Слишком много ^4AWP ^3в команде. ^1Максимально: ^4%i^1.", g_pCvarValue[LIMIT_TYPE] == 1 ? g_pCvarValue[MAX_AWP] : g_iNumAllowedAWP);

                        debug_log(__LINE__, "Player can't take AWP from ground because of it's too much in team.");
                    }
                    else if(iSendMessage > 100)
                    {
                        iSendMessage = -1;
                    }

                    SetHookChainReturn(ATYPE_BOOL, true);
                }
            }
        }
        case ITEM_TYPE_EQUIPPED: 
        {
            log_amx("Map <%s> is an AWP map (by equip). Plugin was stopped.", g_szMapName);
            pause("ad");

            return;
        }
    }
}

public RG_CBasePlayer_AddPlayerItem_post(const id, const pItem)
{
    if(g_bIsLowOnline)
        return;

    if(get_member(pItem, m_iId) != WEAPON_AWP)
        return;

    debug_log(__LINE__, "<AddPlayerItem> called. Player: <%n>", id);

    if(g_pCvarValue[SKIP_BOTS] && IsUserBot[id])
    {
        debug_log(__LINE__, "Player is bot. Skipped.");
        return;
    }

    new TeamName:iUserTeam = get_member(id, m_iTeam);

    g_iAWPAmount[iUserTeam]++;

    debug_log(__LINE__, "(+) Now it's [ %i ] AWP in %i team", g_iAWPAmount[iUserTeam], iUserTeam);
}

public RH_SV_DropClient_pre(const id, bool:crash, const fmt[])
{
    if(!is_user_connected(id))
        return;

    if(!user_has_awp(id))
        return;

    debug_log(__LINE__, "<DropClient> called. Player: <%n>", id);

    if(IsUserBot[id])
    {
        IsUserBot[id] = false;

        if(g_pCvarValue[SKIP_BOTS])
        {
            debug_log(__LINE__, "Player is bot. Skipped.");
            return;
        }
    }

    new TeamName:iUserTeam = get_member(id, m_iTeam);

    g_iAWPAmount[iUserTeam]--;

    debug_log(__LINE__, "(-) Now it's [ %i ] AWP in %i team", g_iAWPAmount[iUserTeam], iUserTeam);
}

public RG_CBasePlayer_RemovePlayerItem_post(const id, const pItem)
{
    if(g_bIsLowOnline)
        return;

    if(get_member(pItem, m_iId) != WEAPON_AWP)
        return;

    debug_log(__LINE__, "<RemovePlayerItem> called. Player: <%n>", id);

    if(g_pCvarValue[SKIP_BOTS] && IsUserBot[id])
    {
        debug_log(__LINE__, "Player is bot. Skipped.");
        return;
    }

    new TeamName:iUserTeam = get_member(id, m_iTeam);

    g_iAWPAmount[iUserTeam]--;

    debug_log(__LINE__, "(-) Now it's [ %i ] AWP in %i team", g_iAWPAmount[iUserTeam], iUserTeam);
}

public client_putinserver(id)
{
    if(is_user_bot(id))
    {
        IsUserBot[id] = true;
    }
}

public RG_RestartRound_post()
{
    arrayset(g_iAWPAmount[TEAM_UNASSIGNED], 0, sizeof g_iAWPAmount);

    debug_log(__LINE__, "--> New round has started. <--");

    if(g_bIsLowOnline)
    {
        debug_log(__LINE__, "Low online mode is now active. AWP count is skipped.");
        return;
    }

    FOREACHPLAYER(iPlayers, id, g_pCvarValue[SKIP_BOTS] ? (GetPlayers_ExcludeBots|GetPlayers_ExcludeHLTV|GetPlayers_ExcludeDead) : (GetPlayers_ExcludeHLTV|GetPlayers_ExcludeDead), "")
    {
        if(user_has_awp(id))
        {
            g_iAWPAmount[get_member(id, m_iTeam)]++;
        }
    }

    debug_log(__LINE__, "Now it's [ %i ] AWP in CT team & [ %i ] AWP in TE team.", g_iAWPAmount[TEAM_CT], g_iAWPAmount[TEAM_TERRORIST]);
}

public RG_CBasePlayer_Spawn_post(const id)
{
    if(!is_user_alive(id))
        return;

    CheckOnline();
}

public RG_RoundEnd_post(WinStatus:status, ScenarioEventEndRound:event, Float:tmDelay)
{
    debug_log(__LINE__, "--> Round is ended. <--");

    CheckOnline();
}

public CheckOnline()
{
    GetOnlinePlayers();

    debug_log(__LINE__, "<CheckOnline> called. Online players: [ %i ].%s", g_iOnlinePlayers, g_pCvarValue[SKIP_SPECTATORS] ? " Spectators skipped." : "");

    if(!g_iOnlinePlayers)
    {
        g_bIsLowOnline = true;
        return;
    }

    if(g_iOnlinePlayers < g_pCvarValue[MIN_PLAYERS])
    {
        if(!g_bIsLowOnline)
        {
            SetLowOnlineMode();
        }

        return;
    }
    else
    {
        if(g_bIsLowOnline)
        {
            UnsetLowOnlineMode();
        }
    }

    CheckTeamLimit();
}

GetOnlinePlayers()
{
    new iNumCT = get_playersnum_ex(g_pCvarValue[SKIP_BOTS] ? (GetPlayers_ExcludeBots|GetPlayers_ExcludeHLTV|GetPlayers_MatchTeam) : (GetPlayers_ExcludeHLTV|GetPlayers_MatchTeam), "CT");
    new iNumTE = get_playersnum_ex(g_pCvarValue[SKIP_BOTS] ? (GetPlayers_ExcludeBots|GetPlayers_ExcludeHLTV|GetPlayers_MatchTeam) : (GetPlayers_ExcludeHLTV|GetPlayers_MatchTeam), "TERRORIST");

    g_iOnlinePlayers = iNumCT + iNumTE;

    if(!g_pCvarValue[SKIP_SPECTATORS])
    {
        g_iOnlinePlayers += get_playersnum_ex(GetPlayers_ExcludeBots|GetPlayers_ExcludeHLTV|GetPlayers_MatchTeam, "SPECTATOR");
    }
}

SetLowOnlineMode()
{
    ExecuteForward(g_iForwardsPointers[LOW_ONLINE_MODE_START], g_iReturn);

    if(g_iReturn == AWPL_BREAK)
    {
        debug_log(__LINE__, "Low online mode can't start because of API.");
        CheckTeamLimit();
        return;
    }

    g_bIsLowOnline = true;

    TakeAllAwps();

    debug_log(__LINE__, "Low online mode has started.");
}

UnsetLowOnlineMode()
{
    ExecuteForward(g_iForwardsPointers[LOW_ONLINE_MODE_STOP], g_iReturn);

    if(g_iReturn == AWPL_BREAK)
    {
        debug_log(__LINE__, "Low online mode can't stop because of API.");
        return;
    }

    g_bIsLowOnline = false;

    if(g_pCvarValue[MESSAGE_ALLOWED_AWP])
    {
        client_print_color(0, print_team_blue, "^3[^4AWP^3] ^1Необходимый ^3онлайн набран^1, ^3можно брать ^4AWP^1.");
    }

    debug_log(__LINE__, "Low online mode has stopped.");
}

CheckTeamLimit()
{
    switch(g_pCvarValue[LIMIT_TYPE])
    {
        case 1: debug_log(__LINE__, "Limit type: 1. Max AWP per team: %i", g_pCvarValue[MAX_AWP]);
        case 2:
        {
            g_iNumAllowedAWP = floatround(g_iOnlinePlayers * (g_pCvarValue[PERCENT_PLAYERS] / 100.0), floatround_floor);

            debug_log(__LINE__, "Limit type: 2. Cvar percent: %i, calculated num of max AWP per team: %i", g_pCvarValue[PERCENT_PLAYERS], g_iNumAllowedAWP);

            if(g_iNumAllowedAWP < 1)
            {
                g_iNumAllowedAWP = 1;

                debug_log(__LINE__, "The AWP limit is less than one, so it was set to 1.", g_pCvarValue[PERCENT_PLAYERS], g_iNumAllowedAWP);
            }

            if(g_iAWPAmount[TEAM_TERRORIST] > g_iNumAllowedAWP)
            {
                TakeAwpsFromTeam(TEAM_TERRORIST);
            }

            if(g_iAWPAmount[TEAM_CT] > g_iNumAllowedAWP)
            {
                TakeAwpsFromTeam(TEAM_CT);
            }
        }
    }
}

TakeAllAwps()
{
    new TeamName:iUserTeam;

    FOREACHPLAYER(iPlayers, id, g_pCvarValue[SKIP_BOTS] ? (GetPlayers_ExcludeBots|GetPlayers_ExcludeHLTV|GetPlayers_ExcludeDead) : (GetPlayers_ExcludeHLTV|GetPlayers_ExcludeDead), "")
    {
        if(user_has_awp(id))
        {
            ExecuteForward(g_iForwardsPointers[AWP_TAKEN_FROM_PLAYER], g_iReturn, id, LOW_ONLINE);

            if(g_iReturn == AWPL_BREAK)
            {
                debug_log(__LINE__, "AWP is not taken from player because of API.");
                continue;
            }

            rg_remove_item(id, "weapon_awp");

            iUserTeam = get_member(id, m_iTeam);

            g_iAWPAmount[iUserTeam]--;

            client_print_color(id, print_team_red, "^3[^4AWP^3] ^1У вас ^3отобрано ^4AWP^1. Причина: ^3низкий онлайн^1.");

            GiveCompensation(id);

            debug_log(__LINE__, "(-) Now it's [ %i ] AWP in %i team", g_iAWPAmount[iUserTeam], iUserTeam);
        }
    }
}

TakeAwpsFromTeam(TeamName:iTeam)
{
    FOREACHPLAYER(iPlayers, id, g_pCvarValue[SKIP_BOTS] ? (GetPlayers_ExcludeBots|GetPlayers_ExcludeHLTV|GetPlayers_ExcludeDead|GetPlayers_MatchTeam) : (GetPlayers_ExcludeHLTV|GetPlayers_ExcludeDead|GetPlayers_MatchTeam), iTeam == TEAM_TERRORIST ? "TERRORIST" : "CT")
    {
        if(user_has_awp(id))
        {
            ExecuteForward(g_iForwardsPointers[AWP_TAKEN_FROM_PLAYER], g_iReturn, id, TOO_MANY_AWP_ON_TEAM);

            if(g_iReturn == AWPL_BREAK)
            {
                debug_log(__LINE__, "AWP is not taken from player because of API.");
                continue;
            }

            rg_remove_item(id, "weapon_awp");

            g_iAWPAmount[iTeam]--;

            client_print_color(id, print_team_red, "^3[^4AWP^3] ^1У вас ^3отобрано ^4AWP^1. Причина: ^3слишком много AWP в команде^1.");

            GiveCompensation(id);

            debug_log(__LINE__, "(-) Now it's [ %i ] AWP in %i team", g_iAWPAmount[iTeam], iTeam);
        }
    }
}

GiveCompensation(const id)
{
    if(!g_pCvarValue[GIVE_COMPENSATION])
        return;

    ExecuteForward(g_iForwardsPointers[GIVE_COMPENSATION_FW], g_iReturn, id);

    if(g_iReturn == AWPL_BREAK)
        return;
    
    switch(g_pCvarValue[GIVE_COMPENSATION])
    {
        case -1:
        {
            if(random_num(0, 1))
            {
                rg_give_item(id, "weapon_ak47");
                rg_set_user_bpammo(id, WEAPON_AK47, 90);
            }
            else
            {
                rg_give_item(id, "weapon_m4a1");
                rg_set_user_bpammo(id, WEAPON_M4A1, 90);
            }

            client_print_color(id, print_team_blue, "^3[^4AWP^3] ^1Вам ^3выдана ^4винтовка ^1в качестве ^3компенсации^1.");
        }
        default:
        {
            rg_add_account(id, g_pCvarValue[GIVE_COMPENSATION]);
            client_print_color(id, print_team_blue, "^3[^4AWP^3] ^1Вам ^3выдана компенсация ^1в размере ^3%i^4$", g_pCvarValue[GIVE_COMPENSATION]);
        }
    }
}

CreateCvars()
{
    new pCvar;

    bind_pcvar_num(create_cvar("awpl_min_players", "10",
        .description = "Минимальное кол-во игроков, при котором станут доступны AWP"),
    g_pCvarValue[MIN_PLAYERS]);

    bind_pcvar_num(create_cvar("awpl_limit_type", "1",
        .description = "Тип лимита AWP.^n1 — Точное кол-во AWP на команду^n2 — Процент от онлайн игроков (awpl_percent_players)",
        .has_min = true, .min_val = 1.0,
        .has_max = true, .max_val = 2.0),
    g_pCvarValue[LIMIT_TYPE]);

    bind_pcvar_num(create_cvar("awpl_max_awp", "2",
        .description = "Максимальное кол-во AWP на команду, при awpl_limit_type = 1",
        .has_min = true, .min_val = 1.0),
    g_pCvarValue[MAX_AWP]);

    bind_pcvar_num(create_cvar("awpl_percent_players", "10",
        .description = "Процент от онлайн игроков для awpl_limit_type = 2^nНапример, при 10% — при онлайне 20 чел. доступно 2 AWP на команду"),
    g_pCvarValue[PERCENT_PLAYERS]);

    bind_pcvar_string(pCvar = create_cvar("awpl_immunity_flag", "a",
        .description = "Флаг иммунитета^nОставьте значение пустым, для отключения иммунитета"),
    g_pCvarValue[IMMNUNITY_FLAG], charsmax(g_pCvarValue[IMMNUNITY_FLAG]));

    hook_cvar_change(pCvar, "OnChangeCvar_Immunity");

    // bind_pcvar_string(create_cvar("awpl_immunity_type", "abc",
    //     .description = "Иммунитет от запрета:^na — Покупки AWP^nb — Поднятия с земли^nc — Взятия в различных меню"),
    // g_pCvarValue[IMMUNITY_TYPE], charsmax(g_pCvarValue[IMMUNITY_TYPE]));

    bind_pcvar_num(create_cvar("awpl_skip_bots", "0",
        .description = "Пропуск подсчёта авп у ботов.^n0 — Выключен^n1 — Включен",
        .has_min = true, .min_val = 0.0,
        .has_max = true, .max_val = 1.0),
    g_pCvarValue[SKIP_BOTS]);

    bind_pcvar_num(create_cvar("awpl_skip_spectators", "1",
        .description = "Пропуск зрителей при подсчёте онлайна.^n0 — Выключен^n1 — Включен",
        .has_min = true, .min_val = 0.0,
        .has_max = true, .max_val = 1.0),
    g_pCvarValue[SKIP_SPECTATORS]);

    bind_pcvar_num(create_cvar("awpl_message_allow_awp", "1",
        .description = "Отправлять ли сообщение, о том что AWP снова доступна при наборе онлайна?^n0 — Выключено^n1 — Включено",
        .has_min = true, .min_val = 0.0,
        .has_max = true, .max_val = 1.0),
    g_pCvarValue[MESSAGE_ALLOWED_AWP]);

    bind_pcvar_num(pCvar = create_cvar("awpl_round_infinite", "0",
        .description = "Поддержка бесконечного раунда. (CSDM)^n0 — Выключено^n>= 1 — Проверять онлайн раз в N секунд^n-1 — каждый спавн любого игрока",
        .has_min = true, .min_val = -1.0),
    g_pCvarValue[ROUND_INFINITE]);

    hook_cvar_change(pCvar, "OnChangeCvar_RoundInfinite");

    bind_pcvar_num(create_cvar("awpl_give_compensation", "-1",
        .description = "Выдача компенсации за отобранное AWP при понижении онлайна.^n-1 — AK-47 или M4A1.^n0 — Выключено^n> 1 — Указаное количество денег.",
        .has_min = true, .min_val = -1.0),
    g_pCvarValue[GIVE_COMPENSATION]);
}

public OnChangeCvar_RoundInfinite(pCvar, const szOldValue[], const szNewValue[])
{
    debug_log(__LINE__, "Cvar <awpl_round_infinite> changed. Old: %s. New: %s", szOldValue, szNewValue);

    new iNewValue = str_to_num(szNewValue);

    if(iNewValue > 0)
    {
        DisableHookChain(g_iHookChain_RoundEnd);
        DisableHookChain(g_iHookChain_PlayerSpawn);

        if(!task_exists(TASKID__CHECK_ONLINE))
        {
            set_task_ex(float(g_pCvarValue[ROUND_INFINITE]), "CheckOnline", TASKID__CHECK_ONLINE, .flags = SetTask_Repeat);
        }
        else
        {
            change_task(TASKID__CHECK_ONLINE, float(iNewValue));
        }

        CheckOnline();
    }
    else if(iNewValue == -1)
    {
        DisableHookChain(g_iHookChain_RoundEnd);
        remove_task(TASKID__CHECK_ONLINE);
        EnableHookChain(g_iHookChain_PlayerSpawn);
    }
    else
    {
        EnableHookChain(g_iHookChain_RoundEnd);
        DisableHookChain(g_iHookChain_PlayerSpawn);
        remove_task(TASKID__CHECK_ONLINE);
    }
}

public OnChangeCvar_Immunity(pCvar, const szOldValue[], const szNewValue[])
{
    debug_log(__LINE__, "Cvar <awpl_immunity_flag> changed. Old: %s. New: %s", szOldValue, szNewValue);

    g_bitImmunityFlags = read_flags(szNewValue);
}

IsAwpMap()
{
    rh_get_mapname(g_szMapName, charsmax(g_szMapName), MNT_TRUE);

    if(equali(g_szMapName, "awp_", 4))
    {
        return true;
    }

    return false;
}

CreateAPIForwards()
{
    g_iForwardsPointers[LOW_ONLINE_MODE_START]  = CreateMultiForward("awpl_low_online_start", ET_STOP);
    g_iForwardsPointers[LOW_ONLINE_MODE_STOP]   = CreateMultiForward("awpl_low_online_stop", ET_STOP);
    g_iForwardsPointers[TRIED_TO_GET_AWP]       = CreateMultiForward("awpl_player_tried_to_get_awp", ET_STOP, FP_CELL, FP_CELL, FP_CELL);
    g_iForwardsPointers[AWP_TAKEN_FROM_PLAYER]  = CreateMultiForward("awpl_awp_taken_from_player", ET_STOP, FP_CELL, FP_CELL);
    g_iForwardsPointers[GIVE_COMPENSATION_FW]   = CreateMultiForward("awpl_give_compensation", ET_STOP, FP_CELL);
}

public plugin_natives()
{
    register_native("awpl_is_low_online", "native_awpl_is_low_online");
    register_native("awpl_set_low_online", "native_awpl_set_low_online");
}

public native_awpl_is_low_online(iPlugin, iParams)
{
    return g_bIsLowOnline;
}

public native_awpl_set_low_online(iPlugin, iParams)
{
    new bool:bSet = bool:get_param(1);

    GetOnlinePlayers();

    if(bSet)
    {
        debug_log(__LINE__, "Low online mode is set via native.");
        SetLowOnlineMode();
    }
    else
    {
        debug_log(__LINE__, "Low online mode is unset via native.");
        UnsetLowOnlineMode();
        CheckTeamLimit();
    }
}

public plugin_end()
{
    log_to_file(g_szLogPach, "================================================================^n");
}

stock bool:user_has_awp(const id)
{
    return rg_has_item_by_name(id, "weapon_awp");
}

/* <== DEBUG ==> */

debug_log(const iLine, const szText[], any:...)
{
    if(!g_bIsDebugActive)
        return;

    static szLogText[512];
    vformat(szLogText, charsmax(szLogText), szText, 3);
    
    format(szLogText, charsmax(szLogText), "[AWPL DEBUG] %s | LINE: %i", szLogText, iLine);

    log_to_file(g_szLogPach, szLogText);
}

/* <====> */
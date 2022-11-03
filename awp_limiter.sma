#include <amxmodx>
#include <amxmisc>
#include <reapi>

new const PLUGIN_VERSION[] = "0.0.10";

// #pragma semicolon 1

#define FOREACHPLAYER(%0,%1,%2) new __players[MAX_PLAYERS], %0, %1; \
    dummyFunc(%1); \
    get_players_ex(__players, %0, %2); \
    for (new i, %1 = __players[i]; i < %0; %1 = __players[++i])

stock dummyFunc(cell) {
    #pragma unused cell
}

#if !defined MAX_MAPNAME_LENGTH
const MAX_MAPNAME_LENGTH = 64;
#endif

const Float:CHECK_ONLINE_FREQ = 60.0;
const TASKID__CHECK_ONLINE = 10200;

enum _:Cvars
{
    MIN_PLAYERS,
    MAX_AWP,
    LIMIT_TYPE,
    PERCENT_PLAYERS,
    IMMNUNITY_FLAG[2],
    IMMUNITY_TYPE[3],
    BOTS,
    MESSAGE_ALLOWED_AWP,
    ROUND_INFINITE
};

new g_pCvarValue[Cvars];

new bool:g_bIsLowOnline = true;
new g_iAWPAmount[TeamName];
new g_pCvarAwpRoundInfinite;
new g_pCvarImmunity;
new HookChain:g_iHookChainRoundEnd;
new g_bitImmunityFlags;

/* <== DEBUG ==> */

new bool:g_bIsDebugActive;
new g_szLogPach[MAX_RESOURCE_PATH_LENGTH];

/* <====> */

public plugin_init()
{
    register_plugin("AWP Limiter", PLUGIN_VERSION, "Nordic Warrior");

    CheckMap();

    // сделать мультиланг

    RegisterHookChain(RG_CSGameRules_CanHavePlayerItem, "RG_CSGameRules_CanHavePlayerItem_pre", .post = false);
    RegisterHookChain(RG_CBasePlayer_HasRestrictItem, "RG_CBasePlayer_HasRestrictItem_pre", .post = false);
    RegisterHookChain(RG_CBasePlayer_AddPlayerItem, "RG_CBasePlayer_AddPlayerItem_post", .post = true);
    RegisterHookChain(RG_CBasePlayer_Killed, "RG_CBasePlayer_Killed_pre", .post = false);
    RegisterHookChain(RH_SV_DropClient, "RH_SV_DropClient_pre", .post = false);
    RegisterHookChain(RG_CSGameRules_RestartRound, "RG_RestartRound_post", .post = true);
    g_iHookChainRoundEnd = RegisterHookChain(RG_RoundEnd, "RG_RoundEnd_post", .post = true);
    RegisterHookChain(RG_CBasePlayer_DropPlayerItem, "RG_CBasePlayer_DropPlayerItem_post", .post = true);

    CreateCvars();

    AutoExecConfig();

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

        new szMapName[MAX_MAPNAME_LENGTH];
        rh_get_mapname(szMapName, charsmax(szMapName), MNT_TRUE);

        debug_log(__LINE__, "Plugin initializated. Map: %s.", szMapName);
    }

    /* <====> */
}

public OnConfigsExecuted()
{
    if(g_pCvarValue[ROUND_INFINITE])
    {
        DisableHookChain(g_iHookChainRoundEnd);
        set_task_ex(CHECK_ONLINE_FREQ, "CheckOnline", TASKID__CHECK_ONLINE, .flags = SetTask_Repeat);

        debug_log(__LINE__, "Infinite round. Task for check online started.");
    }

    g_bitImmunityFlags = read_flags(g_pCvarValue[IMMNUNITY_FLAG]);

    register_cvar("AWPLimiter_version", PLUGIN_VERSION, FCVAR_SERVER|FCVAR_SPONLY|FCVAR_UNLOGGED);
}

public RG_CSGameRules_CanHavePlayerItem_pre(const id, const item)
{
    if(get_member(item, m_iId) != WEAPON_AWP)
        return HC_CONTINUE;

    debug_log(__LINE__, "<CanHavePlayerItem> called.");

    if(g_bitImmunityFlags && get_user_flags(id) & g_bitImmunityFlags)
        return HC_CONTINUE;

    if(g_bIsLowOnline)
    {
        client_print_color(id, print_team_red, "^3[^4AWP^3] ^3Недостаточно игроков на сервере, ^1чтобы взять ^4AWP^1. Необходимо: ^4%i^1. ^3(без учёта зрителей)", g_pCvarValue[MIN_PLAYERS]);
        SetHookChainReturn(ATYPE_INTEGER, false);
        return HC_SUPERCEDE;
    }
    else if(g_iAWPAmount[get_member(id, m_iTeam)] >= g_pCvarValue[MAX_AWP])
    {
        client_print_color(id, print_team_red, "^3[^4AWP^3] ^3Слишком много ^4AWP ^3в команде. ^1Максимально: ^4%i^1.", g_pCvarValue[MAX_AWP]);
        SetHookChainReturn(ATYPE_INTEGER, false);
        return HC_SUPERCEDE;
    }

    return HC_CONTINUE;
}

public RG_CBasePlayer_HasRestrictItem_pre(const id, ItemID:item, ItemRestType:type)
{
    if(item != ITEM_AWP)
        return HC_CONTINUE;

    debug_log(__LINE__, "<HasRestrictItem> called. Type: %i.", type);

    if(g_bitImmunityFlags && get_user_flags(id) & g_bitImmunityFlags)
        return HC_CONTINUE;

    switch(type)
    {
        case ITEM_TYPE_BUYING:
        {
            if(g_bIsLowOnline)
            {
                if(!is_user_has_awp(id))
                {
                    client_print_color(id, print_team_red, "^3[^4AWP^3] ^3Недостаточно игроков на сервере, ^1чтобы купить ^4AWP^1. Необходимо: ^4%i^1. ^3(без учёта зрителей)", g_pCvarValue[MIN_PLAYERS]);

                    SetHookChainReturn(ATYPE_BOOL, true);
                    return HC_SUPERCEDE;
                }
                else return HC_CONTINUE;
            }
            else if(g_iAWPAmount[get_member(id, m_iTeam)] >= g_pCvarValue[MAX_AWP])
            {
                if(!is_user_has_awp(id))
                {
                    client_print_color(id, print_team_red, "^3[^4AWP^3] ^3Слишком много ^4AWP ^3в команде. ^1Максимально: ^4%i^1.", g_pCvarValue[MAX_AWP]);

                    SetHookChainReturn(ATYPE_BOOL, true);
                    return HC_SUPERCEDE;
                }
                else return HC_CONTINUE;
            }
        }
        case ITEM_TYPE_TOUCHED:
        {
            static iSendMessage = -1;
            iSendMessage++;

            if(g_bIsLowOnline)
            {
                if(!is_user_has_awp(id))
                {
                    if(iSendMessage == 0)
                    {
                        client_print_color(id, print_team_red, "^3[^4AWP^3] ^3Недостаточно игроков на сервере, ^1чтобы взять ^4AWP^1. Необходимо: ^4%i^1. ^3(без учёта зрителей)", g_pCvarValue[MIN_PLAYERS]);
                    }
                    else if(iSendMessage > 100)
                    {
                        iSendMessage = -1;
                    }

                    SetHookChainReturn(ATYPE_BOOL, true);
                    return HC_SUPERCEDE;
                }
                else return HC_CONTINUE;
            }
            else if(g_iAWPAmount[get_member(id, m_iTeam)] >= g_pCvarValue[MAX_AWP])
            {
                if(!is_user_has_awp(id))
                {
                    if(iSendMessage == 0)
                    {
                        client_print_color(id, print_team_red, "^3[^4AWP^3] ^3Слишком много ^4AWP ^3в команде. ^1Максимально: ^4%i^1.", g_pCvarValue[MAX_AWP]);
                    }
                    else if(iSendMessage > 100)
                    {
                        iSendMessage = -1;
                    }
                    
                    SetHookChainReturn(ATYPE_BOOL, true);
                    return HC_SUPERCEDE;
                }
                else return HC_CONTINUE;
            }
        }
        case ITEM_TYPE_EQUIPPED: 
        {
            new szMapName[MAX_MAPNAME_LENGTH];
            rh_get_mapname(szMapName, charsmax(szMapName));

            log_amx("Map <%s> is an AWP map (by equip). Plugin was stopped.", szMapName);

            pause("ad");
            return HC_CONTINUE;
        }
    }

    return HC_CONTINUE;
}

public RG_CBasePlayer_AddPlayerItem_post(const id, const pItem)
{
    if(get_member(pItem, m_iId) != WEAPON_AWP || g_bIsLowOnline)
        return;

    debug_log(__LINE__, "<AddPlayerItem> called.");

    g_iAWPAmount[get_member(id, m_iTeam)]++;
}

public RG_CBasePlayer_Killed_pre(const id, pevAttacker, iGib)
{
    if(!is_user_has_awp(id) || g_bIsLowOnline)
        return;

    debug_log(__LINE__, "Player <%n> died with AWP.", id);

    g_iAWPAmount[get_member(id, m_iTeam)]--;
}

public RH_SV_DropClient_pre(const id, bool:crash, const fmt[])
{
    if(!is_user_connected(id) || !is_user_has_awp(id))
        return;

    debug_log(__LINE__, "Player <%n> leaved from server with AWP.", id);

    g_iAWPAmount[get_member(id, m_iTeam)]--;
}

public RG_RestartRound_post()
{
    arrayset(g_iAWPAmount[TEAM_UNASSIGNED], 0, sizeof g_iAWPAmount);

    debug_log(__LINE__, "New round started.");

    if(g_bIsLowOnline)
        return;

    FOREACHPLAYER(iPlayers, id, g_pCvarValue[BOTS] ? (GetPlayers_ExcludeHLTV|GetPlayers_ExcludeDead) : (GetPlayers_ExcludeBots|GetPlayers_ExcludeHLTV|GetPlayers_ExcludeDead))
    {
        if(is_user_has_awp(id))
        {
            g_iAWPAmount[get_member(id, m_iTeam)]++;
        }
    }
}

public RG_RoundEnd_post(WinStatus:status, ScenarioEventEndRound:event, Float:tmDelay)
{
    CheckOnline();

    debug_log(__LINE__, "Round ended.");
}

public RG_CBasePlayer_DropPlayerItem_post(const id, const pszItemName[])
{
    new iWeaponBox = GetHookChainReturn(ATYPE_INTEGER);
    
    if(rg_get_weaponbox_id(iWeaponBox) != WEAPON_AWP || g_bIsLowOnline)
        return;

    debug_log(__LINE__, "<DropPlayerItem> called.");

    g_iAWPAmount[get_member(id, m_iTeam)]--;
}

public CheckOnline()
{
    new iNumCT = get_playersnum_ex(GetPlayers_ExcludeHLTV | GetPlayers_MatchTeam, "CT");
    new iNumTE = get_playersnum_ex(GetPlayers_ExcludeHLTV | GetPlayers_MatchTeam, "TERRORIST");

    new iOnlinePlayers = iNumCT + iNumTE;

    debug_log(__LINE__, "CheckOnline called. Online players: %i", iOnlinePlayers);

    switch(g_pCvarValue[LIMIT_TYPE])
    {
        case 1: debug_log(__LINE__, "Limit type: 1. Min players: %i", g_pCvarValue[MIN_PLAYERS]);
        case 2: debug_log(__LINE__, "Limit type: 2. Cvar percent: %i, calculated percent: %i", g_pCvarValue[PERCENT_PLAYERS], floatround(iOnlinePlayers * (g_pCvarValue[PERCENT_PLAYERS] / 100.0), floatround_floor));
    }

    if(iOnlinePlayers < (g_pCvarValue[LIMIT_TYPE] == 1 ? g_pCvarValue[MIN_PLAYERS] : floatround(iOnlinePlayers * (g_pCvarValue[PERCENT_PLAYERS] / 100.0), floatround_floor)))
    {
        g_bIsLowOnline = true;

        FOREACHPLAYER(iPlayers, id, g_pCvarValue[BOTS] ? (GetPlayers_ExcludeHLTV|GetPlayers_ExcludeDead) : (GetPlayers_ExcludeBots|GetPlayers_ExcludeHLTV|GetPlayers_ExcludeDead))
        {
            if(rg_remove_item(id, "weapon_awp"))
            {
                g_iAWPAmount[get_member(id, m_iTeam)]--;

                client_print_color(id, print_team_red, "^3[^4AWP^3] ^1У вас ^3отобрано ^4AWP^1. Причина: ^3низкий онлайн^1.");                
            }
        }
    }
    else
    {
        if(g_bIsLowOnline && g_pCvarValue[MESSAGE_ALLOWED_AWP])
        {
            client_print_color(0, print_team_blue, "^3[^4AWP^3] ^1Необходимый ^3онлайн набран^1, ^3можно брать ^4AWP^1.");
        }

        g_bIsLowOnline = false;
    }
}

CreateCvars()
{
    bind_pcvar_num(create_cvar("awpl_min_players", "10",                                    // +
        .description = "Минимальное кол-во игроков, при котором станут доступны AWP"),
    g_pCvarValue[MIN_PLAYERS]);

    bind_pcvar_num(create_cvar("awpl_max_awp", "2",                                         // +
        .description = "Максимальное кол-во AWP на команду, при awpl_limit_type = 1",
        .has_min = true, .min_val = 1.0),
    g_pCvarValue[MAX_AWP]);

    bind_pcvar_num(create_cvar("awpl_limit_type", "2",
        .description = "Тип лимита AWP.^n1 - Точное кол-во AWP на команду^n2 - Процент от онлайн игроков (awpl_percent_players)",
        .has_min = true, .min_val = 1.0,
        .has_max = true, .max_val = 2.0),
    g_pCvarValue[LIMIT_TYPE]);

    bind_pcvar_num(create_cvar("awpl_percent_players", "10",                                
        .description = "Процент от онлайн игроков для awpl_limit_type = 2^nНапример, при 10% - при онлайне 20 чел. доступно 2 AWP на команду"),
    g_pCvarValue[PERCENT_PLAYERS]);

    bind_pcvar_string(g_pCvarImmunity = create_cvar("awpl_immunity_flag", "a",                                // +
        .description = "Флаг иммунитета^nОставьте значение пустым, для отключения иммунитета"),
    g_pCvarValue[IMMNUNITY_FLAG], charsmax(g_pCvarValue[IMMNUNITY_FLAG]));

    bind_pcvar_string(create_cvar("awpl_immunity_type", "abc",
        .description = "Иммунитет от запрета:^na - Покупки AWP^nb - Поднятия с земли^nc - Взятия в различных меню"),
    g_pCvarValue[IMMUNITY_TYPE], charsmax(g_pCvarValue[IMMUNITY_TYPE]));

    bind_pcvar_num(create_cvar("awpl_bots", "0",                                            // +
        .description = "Подсчёт авп у ботов, выключите, если у вас нет ботов.^n0 - Выключен^n1 - Включен",
        .has_min = true, .min_val = 0.0,
        .has_max = true, .max_val = 1.0),
    g_pCvarValue[BOTS]);

    bind_pcvar_num(create_cvar("awpl_message_allow_awp", "1",                               // +
        .description = "Отправлять ли сообщение, о том что AWP снова доступна при наборе онлайна?^n0 - Выключено^n1 - Включено",
        .has_min = true, .min_val = 0.0,
        .has_max = true, .max_val = 1.0),
    g_pCvarValue[MESSAGE_ALLOWED_AWP]);

    bind_pcvar_num(g_pCvarAwpRoundInfinite = create_cvar("awpl_round_infinite", "0",           // +
        .description = "Поддержка бесконечного раунда. (CSDM)^n0 - Выключено^n1 - Включено",
        .has_min = true, .min_val = 0.0,
        .has_max = true, .max_val = 1.0),
    g_pCvarValue[ROUND_INFINITE]);

    hook_cvar_change(g_pCvarAwpRoundInfinite, "OnChangeCvar_RoundInfinite");
    hook_cvar_change(g_pCvarImmunity, "OnChangeCvar_Immunity");

    // проверить все квары
}

public OnChangeCvar_RoundInfinite(pCvar, const szOldValue[], const szNewValue[])
{
    debug_log(__LINE__, "Cvar <awpl_round_infinite> changed. Old: %s. New: %s", szOldValue, szNewValue);

    if(str_to_num(szNewValue))
    {
        DisableHookChain(g_iHookChainRoundEnd);
        set_task_ex(CHECK_ONLINE_FREQ, "CheckOnline", TASKID__CHECK_ONLINE, .flags = SetTask_Repeat);
    }
    else
    {
        EnableHookChain(g_iHookChainRoundEnd);
        remove_task(TASKID__CHECK_ONLINE);
    }
}

public OnChangeCvar_Immunity(pCvar, const szOldValue[], const szNewValue[])
{
    debug_log(__LINE__, "Cvar <awpl_immunity_flag> changed. Old: %s. New: %s", szOldValue, szNewValue);

    g_bitImmunityFlags = read_flags(szNewValue);
}

CheckMap()
{
    new szMapName[MAX_MAPNAME_LENGTH];
    rh_get_mapname(szMapName, charsmax(szMapName));

    if(equali(szMapName, "awp_", 4))
    {
        log_amx("Map <%s> is an AWP map (by name). Plugin was stopped.", szMapName);
        pause("ad");
    }

    return PLUGIN_HANDLED;
}

stock bool:is_user_has_awp(const id)
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
/**
    Version 0.0.8a (14.05.2020)
        - Дабавлена надпись о доступности авп в новом раунде
        - Добавлена надпись о том, что онлайн игроков считается без учёта зрителей

    Version 0.0.8a (14.05.2020)
        - Убрана надпись если есть авп, и игрок пытается взять еще одну
        - Ограничена отправка сообщений при таче авп

    Version 0.0.9 (14.05.2020)
        - Стало можно купить/взять вторую авп, если достингут лимит
    
    Version 0.0.9a (14.05.2020)
        - Убран хук RG_CSGameRules_CanHavePlayerItem

    Version 0.0.9b (14.05.2020)
        - Оптимизация засчет if/else в хуках
        - Карта с авп теперь блочится другим способом, через RG_CBasePlayer_HasRestrictItem
        - Хук RG_CSGameRules_CanHavePlayerItem возвращён

    Version 0.0.9с (22.05.2020)
        - Добавлена обратно проверка на имя карты.
        - Добавлены логи, что плагин отключён из-за карты, с типом определения карты.

    Version 0.0.10 (26.05.2020)
        - Изменена проверка на уменьшение кол-ва AWP c RG_CBasePlayer_RemovePlayerItem на RG_CBasePlayer_Killed
        - Оптимизация
        - Добавлен квар "awpl_round_infinite"
        - Сделан квар "awpl_limit_type"
*/
#include <amxmodx>
#include <amxmisc>
#include <reapi>

new const PLUGIN_VERSION[] = "0.0.10";

#pragma semicolon 1

#define FOREACHPLAYER(%0,%1,%2) new __players[MAX_PLAYERS], %0, %1; \
    dummyFunc(%1); \
    get_players_ex(__players, %0, %2); \
    for (new i, %1 = __players[i]; i < %0; %1 = __players[++i])

stock dummyFunc(cell) {
    #pragma unused cell
}

#define is_user_has_awp(%0) rg_has_item_by_name(%0, "weapon_awp")

#if !defined MAX_MAPNAME_LENGTH
const MAX_MAPNAME_LENGTH = 64;
#endif

const Float:CHECK_ONLINE_FREQ = 1.0;
const TASKID__CHECK_ONLINE = 10200;

enum _:Cvars
{
    MIN_PLAYERS,
    MAX_AWP,
    LIMIT_TYPE,
    PERCENT_PLAYERS,
    IMMUNITY,
    IMMNUNITY_FLAG[2],
    IMMUNITY_TYPE[3],
    BOTS,
    MESSAGE_ALLOWED_AWP,
    ROUND_INFINITE
};

new g_pCvarValue[Cvars];

new bool:g_bIsLowOnline = true;
new g_iAWPAmount[TeamName];
new g_pCvarRoundInfinite;
new HookChain:g_iHookChainRoundEnd;

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

    CreateCvars();

    AutoExecConfig();
}

public OnConfigsExecuted()
{
    if(g_pCvarValue[ROUND_INFINITE])
    {
        DisableHookChain(g_iHookChainRoundEnd);
        set_task_ex(CHECK_ONLINE_FREQ, "CheckOnline", TASKID__CHECK_ONLINE, .flags = SetTask_Repeat);
    }

    register_cvar("AWPLimiter_version", PLUGIN_VERSION, FCVAR_SERVER|FCVAR_SPONLY|FCVAR_UNLOGGED);
}

public RG_CSGameRules_CanHavePlayerItem_pre(const pPlayer, const item)
{
    if(get_member(item, m_iId) != WEAPON_AWP)
        return HC_CONTINUE;

    if(g_bIsLowOnline)
    {
        client_print_color(pPlayer, print_team_red, "^3[^4AWP^3] ^3Недостаточно игроков на сервере, ^1чтобы взять ^4AWP^1. Необходимо: ^4%i^1. ^3(без учёта зрителей)", g_pCvarValue[MIN_PLAYERS]);
        SetHookChainReturn(ATYPE_INTEGER, false);
        return HC_SUPERCEDE;
    }
    else if(g_iAWPAmount[get_member(pPlayer, m_iTeam)] >= g_pCvarValue[MAX_AWP])
    {
        client_print_color(pPlayer, print_team_red, "^3[^4AWP^3] ^3Слишком много ^4AWP ^3в команде. ^1Максимально: ^4%i^1.", g_pCvarValue[MAX_AWP]);
        SetHookChainReturn(ATYPE_INTEGER, false);
        return HC_SUPERCEDE;
    }

    return HC_CONTINUE;
}

public RG_CBasePlayer_HasRestrictItem_pre(const pPlayer, ItemID:item, ItemRestType:type)
{
    if(item != ITEM_AWP)
        return HC_CONTINUE;

    switch(type)
    {
        case ITEM_TYPE_BUYING:
        {
            if(g_bIsLowOnline)
            {
                if(!is_user_has_awp(pPlayer))
                {
                    client_print_color(pPlayer, print_team_red, "^3[^4AWP^3] ^3Недостаточно игроков на сервере, ^1чтобы купить ^4AWP^1. Необходимо: ^4%i^1. ^3(без учёта зрителей)", g_pCvarValue[MIN_PLAYERS]);

                    SetHookChainReturn(ATYPE_BOOL, true);
                    return HC_SUPERCEDE;
                }
                else return HC_CONTINUE;
            }
            else if(g_iAWPAmount[get_member(pPlayer, m_iTeam)] >= g_pCvarValue[MAX_AWP])
            {
                if(!is_user_has_awp(pPlayer))
                {
                    client_print_color(pPlayer, print_team_red, "^3[^4AWP^3] ^3Слишком много ^4AWP ^3в команде. ^1Максимально: ^4%i^1.", g_pCvarValue[MAX_AWP]);

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
                if(!is_user_has_awp(pPlayer))
                {
                    if(iSendMessage == 0)
                    {
                        client_print_color(pPlayer, print_team_red, "^3[^4AWP^3] ^3Недостаточно игроков на сервере, ^1чтобы взять ^4AWP^1. Необходимо: ^4%i^1. ^3(без учёта зрителей)", g_pCvarValue[MIN_PLAYERS]);
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
            else if(g_iAWPAmount[get_member(pPlayer, m_iTeam)] >= g_pCvarValue[MAX_AWP])
            {
                if(!is_user_has_awp(pPlayer))
                {
                    if(iSendMessage == 0)
                    {
                        client_print_color(pPlayer, print_team_red, "^3[^4AWP^3] ^3Слишком много ^4AWP ^3в команде. ^1Максимально: ^4%i^1.", g_pCvarValue[MAX_AWP]);
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

public RG_CBasePlayer_AddPlayerItem_post(const pPlayer, const pItem)
{
    if(get_member(pItem, m_iId) != WEAPON_AWP || g_bIsLowOnline)
        return;

    g_iAWPAmount[get_member(pPlayer, m_iTeam)]++;
}

public RG_CBasePlayer_Killed_pre(const pPlayer, pevAttacker, iGib)
{
    if(!is_user_has_awp(pPlayer) || g_bIsLowOnline)
        return;

    g_iAWPAmount[get_member(pPlayer, m_iTeam)]--;
}

public RH_SV_DropClient_pre(const pPlayer, bool:crash, const fmt[])
{
    if(!is_user_connected(pPlayer) || !is_user_has_awp(pPlayer))
        return;

    g_iAWPAmount[get_member(pPlayer, m_iTeam)]--;
}

public RG_RestartRound_post()
{
    arrayset(g_iAWPAmount[TEAM_UNASSIGNED], 0, sizeof g_iAWPAmount);

    if(g_bIsLowOnline)
        return;

    FOREACHPLAYER(iPlayers, pPlayer, g_pCvarValue[BOTS] ? (GetPlayers_ExcludeHLTV|GetPlayers_ExcludeDead) : (GetPlayers_ExcludeBots|GetPlayers_ExcludeHLTV|GetPlayers_ExcludeDead))
    {
        if(is_user_has_awp(pPlayer))
        {
            g_iAWPAmount[get_member(pPlayer, m_iTeam)]++;
        }
    }
}

public RG_RoundEnd_post(WinStatus:status, ScenarioEventEndRound:event, Float:tmDelay)
{
    CheckOnline();
}

public CheckOnline()
{
    new iNumCT = get_playersnum_ex(GetPlayers_ExcludeHLTV | GetPlayers_MatchTeam, "CT");
    new iNumTE = get_playersnum_ex(GetPlayers_ExcludeHLTV | GetPlayers_MatchTeam, "TERRORIST");

    new iOnlinePlayers = iNumCT + iNumTE;

    if(iOnlinePlayers < (g_pCvarValue[LIMIT_TYPE] == 1 ? g_pCvarValue[MIN_PLAYERS] : floatround(iOnlinePlayers * (g_pCvarValue[PERCENT_PLAYERS] / 100.0), floatround_floor)))
    {
        g_bIsLowOnline = true;

        FOREACHPLAYER(iPlayers, pPlayer, g_pCvarValue[BOTS] ? (GetPlayers_ExcludeHLTV|GetPlayers_ExcludeDead) : (GetPlayers_ExcludeBots|GetPlayers_ExcludeHLTV|GetPlayers_ExcludeDead))
        {
            if(rg_remove_item(pPlayer, "weapon_awp"))
            {
                g_iAWPAmount[get_member(pPlayer, m_iTeam)]--;

                client_print_color(pPlayer, print_team_red, "^3[^4AWP^3] ^1У вас ^3отобрано ^4AWP^1. Причина: ^3низкий онлайн^1.");                
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

    bind_pcvar_num(create_cvar("awpl_immunity", "0", 
        .description = "Иммунитет по флагу от ограничения AWP^n0 - Выключен^n1 - Включен",
        .has_min = true, .min_val = 0.0,
        .has_max = true, .max_val = 1.0),
    g_pCvarValue[IMMUNITY]);

    bind_pcvar_string(create_cvar("awpl_immunity_flag", "a",
        .description = "Флаг иммунитета"),
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

    bind_pcvar_num(g_pCvarRoundInfinite = create_cvar("awpl_round_infinite", "0",           // +
        .description = "Поддержка бесконечного раунда. (CSDM)^n0 - Выключено^n1 - Включено",
        .has_min = true, .min_val = 0.0,
        .has_max = true, .max_val = 1.0),
    g_pCvarValue[ROUND_INFINITE]);

    hook_cvar_change(g_pCvarRoundInfinite, "OnChangeCvar_RoundInfinite");

    // проверить все квары
}

public OnChangeCvar_RoundInfinite(pCvar, const szOldValue[], const szNewValue[])
{
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
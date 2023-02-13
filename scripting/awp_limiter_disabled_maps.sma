#include <amxmodx>
#include <amxmisc>

#include <awp_limiter_n>

new const PLUGIN_VERSION[] = "1.0.0";

#if !defined MAX_MAPNAME_LENGTH
const MAX_MAPNAME_LENGTH = 32;
#endif

new const CONFIG_FILE[] = "awp_limiter_disabled_maps.ini";

public plugin_init()
{
    register_plugin("AWPL: Disabled maps", PLUGIN_VERSION, "Nordic Warrior");
}

public awpl_plugin_should_work_on_this_map(const szMapName[])
{
    new szConfigPath[MAX_RESOURCE_PATH_LENGTH];
    
    get_configsdir(szConfigPath, charsmax(szConfigPath));
    add(szConfigPath, charsmax(szConfigPath), "/");
    add(szConfigPath, charsmax(szConfigPath), CONFIG_FILE);

    if(!file_exists(szConfigPath))
    {
        set_fail_state("Config <%s> not found.", szConfigPath);
        return AWPL_CONTINUE;
    }

    new DataPack:packedMapName = CreateDataPack();
    WritePackString(packedMapName, szMapName);
    ResetPack(packedMapName);

    new INIParser:iParser = INI_CreateParser();

    INI_SetReaders(iParser, "OnReadConfigKeyValue");
    new iResult = INI_ParseFile(iParser, szConfigPath, .data = packedMapName);
    INI_DestroyParser(iParser);

    if(!iResult)
    {
        return AWPL_BREAK;
    }

    return AWPL_CONTINUE;
}

public bool:OnReadConfigKeyValue(INIParser:handle, const key[], const value[], bool:invalid_tokens, bool:equal_token, bool:quotes, curtok, any:data)
{
    static szMapName[MAX_MAPNAME_LENGTH];

    if(!szMapName[0])
    {
        ReadPackString(data, szMapName, charsmax(szMapName));
        DestroyDataPack(data);
    }

    if(strcmp(szMapName, key, true) == 0)
    {
        return false;
    }

    return true;
}

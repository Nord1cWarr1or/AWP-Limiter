
#if defined _awp_limiter_n
	#endinput
#endif
#define _awp_limiter_n

/**
 * For forward awpl_player_tried_to_get_awp
 */
enum AwpGiveType:GIVE_TYPE
{
    BUY,
    TOUCH,
    OTHER,  // Taken from 3rd party plugins
};

/**
 * For forwards awpl_player_tried_to_get_awp, awpl_awp_taken_from_player
 */
enum AwpRestrictionType:RESTRICTION_TYPE
{
    AWP_ALLOWED,
    LOW_ONLINE,
    TOO_MANY_AWP_ON_TEAM,
    ROUNDS_PAUSE
};

/**
 * For forwards; return types
 */
enum
{
    AWPL_CONTINUE,
    AWPL_BREAK
};

/**
 * Called before the low online mode is activated.
 *
 * @return              AWPL_CONTINUE to allow starting of low online mode
 *                      AWPL_BREAK to stop starting of low online mode
 */
forward awpl_low_online_start();

/**
 * Called before the low online mode is turned off.
 *
 * @return              AWPL_CONTINUE to allow stopping of low online mode
 *                      AWPL_BREAK to continue low online mode
 */
forward awpl_low_online_stop();

/**
 * Called every time a player tries to take an AWP during low online mode.
 *
 * @param id            Player index
 * @param iGiveType     Indicates how the AWP was received. Look at the enum GIVE_TYPE
 * @param iRestrictType Indicates why the AWP was restricted. Look at the enum RESTRICTION_TYPE
 *
 * @return              AWPL_CONTINUE to allow an AWP to be blocked by main plugin
 *                      AWPL_BREAK to stop an AWP blocking
 */
forward awpl_player_tried_to_get_awp(const id, AwpGiveType:iGiveType, AwpRestrictionType:iRestrictType);

/**
 * Called every time an AWP was taken from player.
 *
 * @param id            Player index
 * @param iRestrictType Indicates why the AWP was taken. Look at the enum RESTRICTION_TYPE
 *
 * @return              AWPL_CONTINUE to allow an AWP to be taken by main plugin
 *                      AWPL_BREAK to stop an AWP taking
 */
forward awpl_awp_taken_from_player(const id, AwpRestrictionType:iRestrictType);

/**
 * Called when a player receives compensation for a taken AWP.
 *
 * @note This forward only called when "awpl_give_compensation" CVar is active.
 * @note You can use this forward for give your own compensation to players.
 *
 * @param id            Player index
 *
 * @return              AWPL_CONTINUE to allow giving compensation by main plugin
 *                      AWPL_BREAK to stop giving compensation
 */
forward awpl_give_compensation(const id);

/**
 * Called once on map start, to decide whether the plugin should work on this map
 *
 * @note This forward called in plugin_init().
 *
 * @param szMapName     Map name
 *
 * @return              AWPL_CONTINUE to allow the AWP Limiter work on this map
 *                      AWPL_BREAK to disable it
 */
forward awpl_plugin_should_work_on_this_map(const szMapName[]);

/**
 * Checks if the low online mode is currently active.
 *
 * @return              True if the low online mode is currently active, false otherwise.
 */
native bool:awpl_is_low_online();

/**
 * Forced to start or stop low online mode.
 *
 * @note The mode setted by this native will be active only
 *       until next online check.
 * @note Using this native will cause an immediate awp to be taken if low online mide is set to true.
 *
 * @param bSet          Determines whether to start or stop low online mode
 *
 * @noreturn
 */
native awpl_set_low_online(bool:bSet);

/**
 * Checks if players in given team can take AWP.
 *
 * @param iTeam         Team index
 *
 * @return              True if players in given team can take AWP, false otherwise.
 */
native bool:awpl_can_team_take_awp(TeamName:iTeam);

/**
 * Checks if a given player can take an AWP.
 *
 * @param id            Player index
 * @param iReason       The optional variable to store the reason if player can't take AWP.
 *                      Look at the enum RESTRICTION_TYPE
 *
 * @return              True if player can take AWP, false otherwise.
 */
native bool:awpl_can_player_take_awp(id, &AwpRestrictionType:iReason = AWP_ALLOWED);

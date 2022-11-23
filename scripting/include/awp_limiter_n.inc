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
 * For forward awpl_player_tried_to_get_awp
 */
enum AwpRestrictionType:RESTRICTION_TYPE
{
    LOW_ONLINE,
    TOO_MANY_AWP_ON_TEAM
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
 * Called just after low online mode is enabled.
 *
 * @noreturn
 */
forward awpl_low_online_started();

/**
 * Called just after low online mode is disabled.
 *
 * @noreturn
 */
forward awpl_low_online_stopped();

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
 * Checks if the low online mode is currently active.
 *
 * @return              True if the low online mode is currently active, false otherwise.
 */
native bool:awpl_is_low_online();

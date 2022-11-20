#if defined _awp_limiter_n
	#endinput
#endif
#define _awp_limiter_n

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
 * Checks if the low online mode is currently active.
 *
 * @return          True if the low online mode is currently active, false otherwise.
 */
native awpl_is_low_online();

#pragma once

#include <stdint.h>

#if defined(DM_SHELL_INPUT_BRIDGE) || (defined(DM_SHELL) && DM_SHELL)
// The library always owns player assignment and routes input to the running engine.
void shell_pad_player(int player, uint64_t buttons, int32_t lx, int32_t ly, int32_t rx, int32_t ry);
void shell_pad_slots(uint32_t mask, uint32_t joyright);
void shell_pad_clear(int player);
void shell_pad_motion(int player, const float acc[3], const float gyro[3], const float angle[3], const float dir[9]);

#else
#include "dm_input.h"
#define shell_pad_player dm_pad_set_player
#define shell_pad_slots dm_pad_players_with_joyright
#define shell_pad_clear dm_pad_clear_player
#define shell_pad_motion dm_motion_set_player
#endif

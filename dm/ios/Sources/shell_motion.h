// Real motion for the game's six-axis sensors (dm_motion_set_player, hle_hid.c): the iPad's own sensors for player 1 (DmGamepad.m) and the gyroscope of a controller that has one
// (DualSense, DualShock 4, Switch Pro; shell_players.m) for its player. The front end gives each reading in the controller's frame (x right, y away from the player, z up) and
// this keeps the orientation between readings: it starts from gravity (the first reading), then follows the gyroscope.
#pragma once
#include <stdint.h>

typedef struct { int init; double q[4], angle[3], last; } shell_motion;   // q: the controller's orientation (w, x, y, z), angle: revolutions turned about each axis, last: seconds
// grav, user: acceleration in G (gravity, the rest; user may be all 0 when the sensor does not split them), rot: radians / s, t: the reading's time in seconds
void shell_motion_feed(shell_motion *m, int player, double t, const double grav[3], const double user[3], const double rot[3]);
void shell_motion_enable(int on);   // the launcher's Motion controls switch (on unless DM_GYRO=0); off: nothing is fed and the sensors read as lying still
int shell_motion_enabled(void);

// Real motion for the game's six-axis sensors (shell_motion.h).
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include "dm_input.h"
#include "shell_motion.h"

static atomic_int g_on = -1;
void shell_motion_enable(int on) { atomic_store(&g_on, on != 0); }
int shell_motion_enabled(void) {
    int on = atomic_load(&g_on);
    if (on < 0) { const char *e = getenv("DM_GYRO"); on = !(e && !strcmp(e, "0")); atomic_store(&g_on, on); }
    return on;
}

static void normalize(double q[4]) {
    double n = sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]);
    if (n < 1e-12) { q[0] = 1; q[1] = q[2] = q[3] = 0; return; }
    for (int i = 0; i < 4; i++) q[i] /= n;
}
static void from_gravity(double q[4], const double g[3]) {   // the rotation taking the measured gravity to straight down (0, 0, -1): the tilt, no yaw
    double n = sqrt(g[0] * g[0] + g[1] * g[1] + g[2] * g[2]);
    if (n < 0.1) { q[0] = 1; q[1] = q[2] = q[3] = 0; return; }   // free fall or no reading: start level
    double a[3] = {g[0] / n, g[1] / n, g[2] / n}, d = -a[2];   // dot(a, (0, 0, -1))
    if (d < -0.9999) { q[0] = 0; q[1] = 1; q[2] = q[3] = 0; return; }   // upside down: half a turn about x
    q[0] = 1 + d; q[1] = -a[1]; q[2] = a[0]; q[3] = 0;   // (1 + a.b, a x b) with b = (0, 0, -1)
    normalize(q);
}

void shell_motion_feed(shell_motion *m, int player, double t, const double grav[3], const double user[3], const double rot[3]) {
    if (!shell_motion_enabled() || player < 0 || player >= DM_PLAYERS) return;
    if (!m->init || t < m->last) { from_gravity(m->q, grav); memset(m->angle, 0, sizeof m->angle); m->init = 1; m->last = t; }
    double dt = t - m->last; if (dt > 0.1) dt = 0.1;   // a gap (the app was paused): no jump
    m->last = t;
    double w = sqrt(rot[0] * rot[0] + rot[1] * rot[1] + rot[2] * rot[2]);
    if (w > 1e-9 && dt > 0) {   // q = q * (the turn of this step, about the controller's own axes)
        double h = w * dt / 2, s = sin(h) / w, r[4] = {cos(h), rot[0] * s, rot[1] * s, rot[2] * s}, *q = m->q;
        double n[4] = {q[0] * r[0] - q[1] * r[1] - q[2] * r[2] - q[3] * r[3], q[0] * r[1] + q[1] * r[0] + q[2] * r[3] - q[3] * r[2],
                       q[0] * r[2] - q[1] * r[3] + q[2] * r[0] + q[3] * r[1], q[0] * r[3] + q[1] * r[2] - q[2] * r[1] + q[3] * r[0]};
        memcpy(m->q, n, sizeof n); normalize(m->q);
    }
    float acc[3], gyro[3], angle[3], dir[9];
    for (int i = 0; i < 3; i++) {
        acc[i] = (float)(grav[i] + user[i]);
        gyro[i] = (float)(rot[i] / (2 * M_PI));
        m->angle[i] += rot[i] / (2 * M_PI) * dt; angle[i] = (float)m->angle[i];
    }
    double qw = m->q[0], qx = m->q[1], qy = m->q[2], qz = m->q[3];
    // the controller's x, y and z axes in the world: the columns of the rotation matrix
    dir[0] = (float)(1 - 2 * (qy * qy + qz * qz)); dir[1] = (float)(2 * (qx * qy + qw * qz)); dir[2] = (float)(2 * (qx * qz - qw * qy));
    dir[3] = (float)(2 * (qx * qy - qw * qz)); dir[4] = (float)(1 - 2 * (qx * qx + qz * qz)); dir[5] = (float)(2 * (qy * qz + qw * qx));
    dir[6] = (float)(2 * (qx * qz + qw * qy)); dir[7] = (float)(2 * (qy * qz - qw * qx)); dir[8] = (float)(1 - 2 * (qx * qx + qy * qy));
    dm_motion_set_player(player, acc, gyro, angle, dir);
}

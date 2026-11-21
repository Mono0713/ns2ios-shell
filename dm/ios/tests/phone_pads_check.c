// Stand-in host for test_phone_pads.py: runs phone_pads.c's server and writes what it hands the host (players mask, each player's buttons and sticks) to a file every 20 ms.
// A second argument holds that many players for physical controllers first (shell_players.m takes them from the same table, shell_slots.c). Lines on stdin act as the
// launcher: "swap <a> <b>", "kick <p>", "layout <p> <0|1>", "rumble <p> <amplitude %>" (players counted from 0); the file also lists each slot's kind and layout
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
#include "dm_input.h"
#include "hle_haptics.h"
#include "shell_slots.h"

void phone_pads_start(void);
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static uint64_t g_btn[DM_PLAYERS]; static int32_t g_ax[DM_PLAYERS][4]; static uint32_t g_mask, g_joyright;
void dm_pad_set_player(int p, uint64_t b, int32_t lx, int32_t ly, int32_t rx, int32_t ry) {
    pthread_mutex_lock(&g_mu); g_btn[p] = b; g_ax[p][0] = lx; g_ax[p][1] = ly; g_ax[p][2] = rx; g_ax[p][3] = ry; pthread_mutex_unlock(&g_mu);
}
static float g_acc[DM_PLAYERS][3], g_gyro[DM_PLAYERS][3]; static int g_motions[DM_PLAYERS];
void dm_motion_set_player(int p, const float acc[3], const float gyro[3], const float angle[3], const float dir[9]) {
    (void)angle; (void)dir; pthread_mutex_lock(&g_mu); for (int i = 0; i < 3; i++) { g_acc[p][i] = acc[i]; g_gyro[p][i] = gyro[i]; } g_motions[p]++; pthread_mutex_unlock(&g_mu);
}
static void no_output(dm_haptic_state s) { (void)s; }   // the Apple output (haptics_apple.m) plays nothing for a phone's player either
void dm_pad_players_with_joyright(uint32_t mask, uint32_t joyright) {
    pthread_mutex_lock(&g_mu); g_mask = mask; g_joyright = joyright; pthread_mutex_unlock(&g_mu);
}
void dm_pad_clear_player(int p) { dm_pad_set_player(p, 0, 0, 0, 0, 0); }
uint64_t now_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (uint64_t)t.tv_sec * 1000000000u + (uint64_t)t.tv_nsec; }

static void *commands(void *arg) {
    (void)arg; char line[64]; int a, b;
    while (fgets(line, sizeof line, stdin)) {
        if (sscanf(line, "swap %d %d", &a, &b) == 2) shell_slot_swap(a, b);
        else if (sscanf(line, "kick %d", &a) == 1) shell_slot_kick(a);
        else if (sscanf(line, "layout %d %d", &a, &b) == 2) shell_slot_set_layout(a, b);
        else if (sscanf(line, "rumble %d %d", &a, &b) == 2) {   // the game sets player a's motors to amplitude b / 100
            dm_vibration_update u[2] = {{a, 0, {b / 100.0f, 160, b / 100.0f, 320}}, {a, 1, {b / 100.0f, 160, b / 100.0f, 320}}}; dm_haptics_send(u, 2);
        }
    }
    return NULL;
}

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    char tmp[1024]; snprintf(tmp, sizeof tmp, "%s.tmp", argv[1]);
    static int controllers[DM_PLAYERS];
    for (int i = 0; argc > 2 && i < atoi(argv[2]) && i < DM_PLAYERS; i++) shell_slot_take(&controllers[i], "Xbox Wireless Controller", SHELL_SLOT_CONTROLLER, "Xbox Wireless Controller");
    dm_haptics_init(no_output, 1);
    phone_pads_start();
    pthread_t th; pthread_create(&th, NULL, commands, NULL);
    for (;;) {
        FILE *f = fopen(tmp, "w"); if (!f) return 1;
        shell_slot_info info[DM_PLAYERS]; shell_slots_list(info);   // before g_mu: the table calls dm_pad_players under its own lock
        pthread_mutex_lock(&g_mu);
        fprintf(f, "{\"slots\": [");
        for (int i = 0; i < DM_PLAYERS; i++) fprintf(f, "%s[%d, %d]", i ? ", " : "", info[i].kind, info[i].xbox);
        fprintf(f, "], \"mask\": %u, \"joyright\": %u, \"players\": [", g_mask, g_joyright);
        for (int i = 0; i < DM_PLAYERS; i++) fprintf(f, "%s[%llu, %d, %d, %d, %d]", i ? ", " : "", (unsigned long long)g_btn[i], g_ax[i][0], g_ax[i][1], g_ax[i][2], g_ax[i][3]);
        fprintf(f, "], \"motion\": [");
        for (int i = 0; i < DM_PLAYERS; i++) fprintf(f, "%s[%d, %.3f, %.3f, %.3f, %.3f, %.3f, %.3f]", i ? ", " : "", g_motions[i], g_acc[i][0], g_acc[i][1], g_acc[i][2], g_gyro[i][0], g_gyro[i][1], g_gyro[i][2]);
        fprintf(f, "]}\n");
        pthread_mutex_unlock(&g_mu);
        fclose(f); rename(tmp, argv[1]);
        usleep(20000);
    }
}

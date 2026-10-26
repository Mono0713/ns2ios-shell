// Stand-in host for test_phone_pads.py: runs phone_pads.c's server and writes what it hands the host (players mask, each player's buttons and sticks) to a file every 20 ms.
// A second argument holds that many players for physical controllers first (DmGamepad.m takes them from the same table, shell_slots.c)
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
#include "dm_input.h"
#include "shell_slots.h"

void phone_pads_start(void);
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static uint64_t g_btn[DM_PLAYERS]; static int32_t g_ax[DM_PLAYERS][4]; static uint32_t g_mask;
void dm_pad_set_player(int p, uint64_t b, int32_t lx, int32_t ly, int32_t rx, int32_t ry) {
    pthread_mutex_lock(&g_mu); g_btn[p] = b; g_ax[p][0] = lx; g_ax[p][1] = ly; g_ax[p][2] = rx; g_ax[p][3] = ry; pthread_mutex_unlock(&g_mu);
}
void dm_pad_players(uint32_t mask) { pthread_mutex_lock(&g_mu); g_mask = mask; pthread_mutex_unlock(&g_mu); }
uint64_t now_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (uint64_t)t.tv_sec * 1000000000u + (uint64_t)t.tv_nsec; }

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    char tmp[1024]; snprintf(tmp, sizeof tmp, "%s.tmp", argv[1]);
    static int controllers[DM_PLAYERS];
    for (int i = 0; argc > 2 && i < atoi(argv[2]) && i < DM_PLAYERS; i++) shell_slot_take(&controllers[i], "Xbox Wireless Controller");
    phone_pads_start();
    for (;;) {
        FILE *f = fopen(tmp, "w"); if (!f) return 1;
        pthread_mutex_lock(&g_mu);
        fprintf(f, "{\"mask\": %u, \"players\": [", g_mask);
        for (int i = 0; i < DM_PLAYERS; i++) fprintf(f, "%s[%llu, %d, %d, %d, %d]", i ? ", " : "", (unsigned long long)g_btn[i], g_ax[i][0], g_ax[i][1], g_ax[i][2], g_ax[i][3]);
        fprintf(f, "]}\n");
        pthread_mutex_unlock(&g_mu);
        fclose(f); rename(tmp, argv[1]);
        usleep(20000);
    }
}

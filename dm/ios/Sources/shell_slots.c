// The shared player-slot table (shell_slots.h).
#include <pthread.h>
#include "dm_input.h"
#include "pad_slots.h"
#include "shell_slots.h"

static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static pad_slots g_slots;

int shell_slot_take(const void *owner, const char *name) {
    pthread_mutex_lock(&g_mu);
    int p = pad_slot_take(&g_slots, owner, name);
    dm_pad_players(pad_slot_mask(&g_slots));   // under the lock, so the last mask set is the table's
    pthread_mutex_unlock(&g_mu);
    return p;
}
int shell_slot_free(const void *owner) {
    pthread_mutex_lock(&g_mu);
    int p = pad_slot_free(&g_slots, owner);
    dm_pad_players(pad_slot_mask(&g_slots));
    pthread_mutex_unlock(&g_mu);
    return p;
}
int shell_slot_of(const void *owner) {
    pthread_mutex_lock(&g_mu);
    int p = pad_slot_of(&g_slots, owner);
    pthread_mutex_unlock(&g_mu);
    return p;
}

// The shared player-slot table (shell_slots.h).
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include "dm_input.h"
#include "embedded_game_input.h"
#include "pad_slots.h"
#include "shell_slots.h"

static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static pad_slots g_slots;
static shell_slot_info g_info[DM_PLAYERS];
static unsigned char g_joyright[DM_PLAYERS];
static void (*g_moved[SHELL_SLOT_KINDS])(const void *, int, int);
static void (*g_kick[SHELL_SLOT_KINDS])(const void *);
static void (*g_layout[SHELL_SLOT_KINDS])(const void *, int);
static void (*g_identify[SHELL_SLOT_KINDS])(const void *);
static void (*g_hook)(void);
static void (*g_input)(int, uint64_t, int32_t, int32_t);
static void (*g_layout_req)(int, int);

static void changed(void) { void (*h)(void) = g_hook; if (h) h(); }

// Called with the table locked: occupancy and mode come from the same holders.
static void publish_slots(void) {
    uint32_t joyright = 0;
    for (int p = 0; p < DM_PLAYERS; p++) if (g_joyright[p]) joyright |= 1u << p;
    shell_pad_slots(pad_slot_mask(&g_slots), joyright);
}
void shell_slots_publish(void) {
    pthread_mutex_lock(&g_mu);
    publish_slots();
    pthread_mutex_unlock(&g_mu);
}

static int take(const void *owner, const char *name, int kind, const char *label, int joyright) {
    pthread_mutex_lock(&g_mu);
    int first = !g_slots.owner[0] && g_slots.last[0][0] && (!name || strcmp(g_slots.last[0], name)) ? 1 : 0;
    int p = pad_slot_take_from(&g_slots, owner, name, first);
    if (p >= 0 && g_info[p].kind != kind) g_info[p].xbox = 0;   // a new holder starts with the Switch layout until its own choice is set (shell_players.m)
    if (p >= 0) {
        g_info[p].kind = kind;
        g_joyright[p] = joyright != 0;
        snprintf(g_info[p].label, sizeof g_info[p].label, "%s", label ? label : "");
    }
    publish_slots();
    pthread_mutex_unlock(&g_mu);
    changed();
    return p;
}
int shell_slot_take(const void *owner, const char *name, int kind, const char *label) {
    return take(owner, name, kind, label, 0);
}
int shell_slot_take_phone(const void *owner, const char *name, const char *label, int joyright) {
    return take(owner, name, SHELL_SLOT_PHONE, label, joyright);
}
int shell_slot_set_joyright(const void *owner, int joyright) {
    pthread_mutex_lock(&g_mu);
    int p = pad_slot_of(&g_slots, owner);
    if (p >= 0 && g_info[p].kind == SHELL_SLOT_PHONE) {
        g_joyright[p] = joyright != 0;
        publish_slots();
    } else p = -1;
    pthread_mutex_unlock(&g_mu);
    return p;
}
int shell_slot_free(const void *owner) {
    pthread_mutex_lock(&g_mu);
    int p = pad_slot_free(&g_slots, owner);
    if (p >= 0) { g_info[p].kind = SHELL_SLOT_NONE; g_info[p].xbox = 0; g_joyright[p] = 0; }
    publish_slots();
    pthread_mutex_unlock(&g_mu);
    changed();
    return p;
}
int shell_slot_of(const void *owner) {
    pthread_mutex_lock(&g_mu);
    int p = pad_slot_of(&g_slots, owner);
    pthread_mutex_unlock(&g_mu);
    return p;
}
int shell_slot_held(int p) {
    if (p < 0 || p >= DM_PLAYERS) return 0;
    pthread_mutex_lock(&g_mu);
    int held = g_slots.owner[p] != NULL;
    pthread_mutex_unlock(&g_mu);
    return held;
}
int shell_slot_menu_player(int p) {
    if (p < 0 || p >= DM_PLAYERS) return -1;
    pthread_mutex_lock(&g_mu);
    int player = g_slots.owner[0] ? p : 0;
    if (!g_slots.owner[p]) player = -1;
    pthread_mutex_unlock(&g_mu);
    return player;
}
void shell_slot_restore_primary(const char *name) {
    pthread_mutex_lock(&g_mu);
    if (!g_slots.owner[0]) snprintf(g_slots.last[0], sizeof g_slots.last[0], "%s", name ? name : "");
    pthread_mutex_unlock(&g_mu);
}
void shell_slot_primary_name(char name[64]) {
    pthread_mutex_lock(&g_mu);
    memcpy(name, g_slots.last[0], sizeof g_slots.last[0]);
    pthread_mutex_unlock(&g_mu);
}
void shell_slots_list(shell_slot_info out[]) {
    pthread_mutex_lock(&g_mu);
    for (int i = 0; i < DM_PLAYERS; i++) {
        out[i] = g_info[i]; snprintf(out[i].name, sizeof out[i].name, "%s", g_slots.last[i]);
        if (!g_slots.owner[i]) out[i].kind = SHELL_SLOT_NONE;
    }
    pthread_mutex_unlock(&g_mu);
}
void shell_slots_handlers(int kind, void (*moved)(const void *, int, int), void (*kick)(const void *), void (*layout)(const void *, int)) {
    if (kind <= SHELL_SLOT_NONE || kind >= SHELL_SLOT_KINDS) return;
    pthread_mutex_lock(&g_mu); g_moved[kind] = moved; g_kick[kind] = kick; g_layout[kind] = layout; pthread_mutex_unlock(&g_mu);
}
int shell_slot_swap(int a, int b) {
    if (a < 0 || b < 0 || a >= DM_PLAYERS || b >= DM_PLAYERS) return 0;
    if (a == b) return 1;
    pthread_mutex_lock(&g_mu);
    const void *oa = g_slots.owner[a], *ob = g_slots.owner[b];
    if (!oa && !ob) { pthread_mutex_unlock(&g_mu); return 1; }
    char last[64]; memcpy(last, g_slots.last[a], sizeof last); memcpy(g_slots.last[a], g_slots.last[b], sizeof last); memcpy(g_slots.last[b], last, sizeof last);
    // A player taking vacant P1 takes over the role. The former P1 rejoins using the ordinary open-slot order.
    if (a == 0 && !oa && ob) g_slots.last[b][0] = '\0';
    if (b == 0 && !ob && oa) g_slots.last[a][0] = '\0';
    if (a == 0 && oa && !ob) g_slots.last[a][0] = '\0';
    if (b == 0 && ob && !oa) g_slots.last[b][0] = '\0';
    g_slots.owner[a] = ob; g_slots.owner[b] = oa;
    shell_slot_info t = g_info[a]; g_info[a] = g_info[b]; g_info[b] = t;
    void (*ma)(const void *, int, int) = oa ? g_moved[g_info[b].kind] : NULL, (*mb)(const void *, int, int) = ob ? g_moved[g_info[a].kind] : NULL;
    unsigned char joyright = g_joyright[a]; g_joyright[a] = g_joyright[b]; g_joyright[b] = joyright;
    shell_pad_clear(a);
    shell_pad_clear(b);
    publish_slots();
    pthread_mutex_unlock(&g_mu);
    if (ma) ma(oa, a, b);
    if (mb) mb(ob, b, a);
    changed();
    return 1;
}
int shell_slot_kick(int p) {
    if (p < 0 || p >= DM_PLAYERS) return 0;
    pthread_mutex_lock(&g_mu);
    const void *o = g_slots.owner[p]; void (*k)(const void *) = o ? g_kick[g_info[p].kind] : NULL;
    pthread_mutex_unlock(&g_mu);
    if (!o) return 0;
    if (k) k(o); else shell_slot_free(o);   // a kind with no handler: the slot just becomes free
    return 1;
}
int shell_slot_set_layout(int p, int xbox) {
    if (p < 0 || p >= DM_PLAYERS) return 0;
    pthread_mutex_lock(&g_mu);
    const void *o = g_slots.owner[p]; void (*l)(const void *, int) = o ? g_layout[g_info[p].kind] : NULL;
    int was = g_info[p].xbox; if (o) g_info[p].xbox = xbox != 0;
    pthread_mutex_unlock(&g_mu);
    if (!o) return 0;
    if (was != (xbox != 0)) { if (l) l(o, xbox != 0); changed(); }
    return 1;
}
void shell_slots_identify_handler(int kind, void (*identify)(const void *)) {
    if (kind <= SHELL_SLOT_NONE || kind >= SHELL_SLOT_KINDS) return;
    pthread_mutex_lock(&g_mu); g_identify[kind] = identify; pthread_mutex_unlock(&g_mu);
}
int shell_slot_identify(int p) {
    if (p < 0 || p >= DM_PLAYERS) return 0;
    pthread_mutex_lock(&g_mu);
    const void *o = g_slots.owner[p]; void (*f)(const void *) = o ? g_identify[g_info[p].kind] : NULL;
    pthread_mutex_unlock(&g_mu);
    if (f) f(o);
    return f != NULL;
}
int shell_slot_layout(const void *owner) {
    pthread_mutex_lock(&g_mu);
    int p = pad_slot_of(&g_slots, owner), x = p >= 0 ? g_info[p].xbox : 0;
    pthread_mutex_unlock(&g_mu);
    return x;
}
void shell_slots_on_change(void (*hook)(void)) { g_hook = hook; }
void shell_slot_input(int p, uint64_t buttons, int32_t lx, int32_t ly) { void (*h)(int, uint64_t, int32_t, int32_t) = g_input; if (h && p >= 0 && p < DM_PLAYERS) h(p, buttons, lx, ly); }
void shell_slots_on_input(void (*hook)(int, uint64_t, int32_t, int32_t)) { g_input = hook; }
static void (*g_home)(int);
void shell_slot_home(int p) { void (*h)(int) = g_home; if (h && p >= 0 && p < DM_PLAYERS) h(p); }
void shell_slots_on_home(void (*hook)(int)) { g_home = hook; }
void shell_slot_request_layout(int p, int xbox) { void (*h)(int, int) = g_layout_req; if (h) h(p, xbox != 0); else shell_slot_set_layout(p, xbox); }
void shell_slots_on_layout_request(void (*hook)(int, int)) { g_layout_req = hook; }

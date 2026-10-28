// The one player-slot table of the app (pad_slots.h): every source of a player of its own takes its slot here, the physical controllers (shell_players.m) and the phones
// (phone_pads.c) alike, so two of them never get the same player and dm_pad_players is set from one mask. Each call locks: the phone server runs on its own thread.
// Each slot also keeps what the launcher lists (shell_players.m): which kind of holder it is and a label. The launcher can swap two players and remove a holder; each kind
// registers what that means for its holders (shell_slots_handlers), and every change calls the change hook.
#pragma once
#include <stdint.h>

enum { SHELL_SLOT_NONE = 0, SHELL_SLOT_CONTROLLER = 1, SHELL_SLOT_PHONE = 2, SHELL_SLOT_KINDS };
typedef struct { int kind, xbox; char label[64], name[64]; } shell_slot_info;   // xbox: the holder's buttons go by Xbox labels (A bottom); name: its identity (pad_slots.h)

int shell_slot_take(const void *owner, const char *name, int kind, const char *label);   // the slot (player - 1) owner holds, taking one if it holds none (pad_slot_take's order); -1 when all are held
int shell_slot_free(const void *owner);   // frees owner's slot and returns it, -1 when it held none; the caller releases that player's input
int shell_slot_of(const void *owner);
int shell_slot_held(int p);   // 1 while a controller or a phone holds player p + 1
void shell_slots_list(shell_slot_info out[]);   // DM_PLAYERS entries, kind SHELL_SLOT_NONE for a free slot

// moved: owner's slot is now `to` (it was `from`), called after the swap with no lock held; the holder feeds `to` its current state at once (a player the swap left
// free is released by the swap itself).
// kick: the launcher removed owner; the holder frees its slot (and decides when it may come back). Both are called on the caller's thread (the main thread).
// layout: the holder now uses the Xbox (1) or the Switch (0) button layout.
void shell_slots_handlers(int kind, void (*moved)(const void *owner, int from, int to), void (*kick)(const void *owner), void (*layout)(const void *owner, int xbox));
int shell_slot_swap(int a, int b);   // exchanges the holders of players a + 1 and b + 1 (either may be free); 0 when a or b is out of range
int shell_slot_kick(int p);          // removes the holder of player p + 1 through its kind's kick handler; 0 when the slot is free
int shell_slot_set_layout(int p, int xbox);   // the button layout of player p + 1's holder, through its kind's layout handler; 0 when the slot is free
int shell_slot_layout(const void *owner);     // owner's button layout (1 Xbox), 0 when it holds no slot
// The holder itself asks for a layout (a phone's page has its own switch): goes through the hook when one is set (shell_players.m keeps the choice for that device,
// as the launcher's does), else straight to shell_slot_set_layout. On the holder's thread
void shell_slot_request_layout(int p, int xbox);
void shell_slots_on_layout_request(void (*hook)(int p, int xbox));
// identify: the launcher's "which one is this?" for owner's player: its holder buzzes (a controller's rumble, a phone's vibration and flash). On the caller's thread (main)
void shell_slots_identify_handler(int kind, void (*identify)(const void *owner));
int shell_slot_identify(int p);   // 0 when the slot is free or its kind has no handler
void shell_slots_on_change(void (*hook)(void));   // called after every take, free, swap, kick and layout change, on that call's thread, with no lock held
// Input from a holder that the app itself looks at (the launcher's controller navigation, shell_players.m): each holder reports its buttons and left stick
// (dm_input.h units, y up) after dm_pad_set_player, on its own thread
void shell_slot_input(int p, uint64_t buttons, int32_t lx, int32_t ly);
void shell_slots_on_input(void (*hook)(int p, uint64_t buttons, int32_t lx, int32_t ly));

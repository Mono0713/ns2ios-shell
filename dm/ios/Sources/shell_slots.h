// The one player-slot table of the app (pad_slots.h): every source of a player of its own takes its slot here, the physical controllers (DmGamepad.m) and the phones
// (phone_pads.c) alike, so two of them never get the same player and dm_pad_players is set from one mask. Each call locks: the phone server runs on its own thread.
#pragma once

int shell_slot_take(const void *owner, const char *name);   // the slot (player - 1) owner holds, taking one if it holds none (pad_slot_take's order); -1 when all are held
int shell_slot_free(const void *owner);   // frees owner's slot and returns it, -1 when it held none; the caller releases that player's input
int shell_slot_of(const void *owner);

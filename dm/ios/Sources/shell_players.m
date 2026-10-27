// Players of their own on iOS, from app launch (main.m shell_players_start), so the launcher already lists them: each physical controller (GameController) takes a
// player from the shared slot table (shell_slots.h) as it connects, as the phones do (phone_pads.c); the first is player 1, the next player 2, and so on up to 8 (a
// reconnected controller gets its player back). They go to dm_pad_set_player; player 1's is ORed with the touch gamepad in hle_hid.c, and a one-player game still sees
// every controller as player 1.
// The launcher's player list (Launcher.swift) talks to this file through two notifications, so Swift needs no C header:
//   DMPlayersChanged (posted here, main thread)  userInfo players: [[player, kind, label, name, xbox]] for each held slot (player from 1; kind 1 controller,
//                                               2 phone), removed: [[index, label]] for the controllers the launcher removed that are still connected
//   DMPlayersCommand (posted by the launcher)    userInfo op: refresh | swap (a, b: players from 1) | kick (p) | layout (p, xbox 0/1) | add (index into removed)
//                                               | launcher (on 0/1: the settings screen is shown)
//   DMLauncherInput (posted here, main thread)   while the launcher is shown, A or + pressed on any player's controller or phone: the launcher starts the game
// Button layout, per device (its name: a controller's model, a phone's id) and kept in NSUserDefaults: Xbox (A, B, X, Y as printed: A at the bottom) or Switch (by
// position: right A, bottom B). A device that has no choice yet: an Xbox-branded controller gets Xbox, another controller what DM_PAD_BY_LABEL says (the launcher's
// old switch, 0 when unset), a phone Switch. A phone's page draws its buttons in its layout (phone_pads.c sends it).
#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <string.h>
#include "dm.h"
#include "dm_input.h"
#include "haptics_apple.h"
#include "shell_slots.h"

enum { B_A = 0, B_B, B_X, B_Y, B_LS, B_RS, B_L, B_R, B_ZL, B_ZR, B_PLUS, B_MINUS, B_LEFT, B_UP, B_RIGHT, B_DOWN };

static NSMutableArray<GCController *> *g_pads;    // the connected controllers that hold a player, kept alive while they do (the slot table keys on their pointers)
static NSMutableArray<GCController *> *g_removed; // connected controllers the launcher removed: unused until they reconnect or the launcher adds them back

static NSString *str(const char *s) { return [NSString stringWithUTF8String:s] ?: @"?"; }   // a phone's name is whatever its page sent: not always UTF-8
static NSString *layout_key(const char *name) { return [@"DMPadLayout." stringByAppendingString:str(name)]; }
static int wanted_layout(int kind, const char *name, const char *label) {
    NSNumber *saved = [NSUserDefaults.standardUserDefaults objectForKey:layout_key(name)];
    if (saved) return saved.boolValue;
    if (kind != SHELL_SLOT_CONTROLLER) return 0;
    if (strcasestr(label, "xbox")) return 1;
    const char *e = getenv("DM_PAD_BY_LABEL"); return e && atoi(e) != 0;
}

// ---- A or + starts the game from the launcher (shell_slot_input: controllers here, phones on the phone server's thread) ----
static atomic_int g_launcher;
static _Atomic uint64_t g_last_buttons[DM_PLAYERS];
static void launcher_input(int p, uint64_t buttons) {
    uint64_t pressed = buttons & ~atomic_exchange(&g_last_buttons[p], buttons);
    if (atomic_load(&g_launcher) && (pressed & (1ull << B_A | 1ull << B_PLUS)))
        dispatch_async(dispatch_get_main_queue(), ^{ [NSNotificationCenter.defaultCenter postNotificationName:@"DMLauncherInput" object:nil]; });
}

static int32_t axis(float v) { return (int32_t)(fmaxf(-1.f, fminf(1.f, v)) * 32767); }
static void read_pad(GCController *c) {
    GCExtendedGamepad *g = c.extendedGamepad;
    int p = shell_slot_of((__bridge const void *)c); if (p < 0 || !g) return;
    dm_haptics_apple_controller(p, c);
    uint64_t m = 0;
    #define K(btn, bit) if (btn.isPressed) m |= 1ull << bit
    if (shell_slot_layout((__bridge const void *)c)) { K(g.buttonA, B_A); K(g.buttonB, B_B); K(g.buttonX, B_X); K(g.buttonY, B_Y); }   // by label (Xbox layout)
    else { K(g.buttonB, B_A); K(g.buttonA, B_B); K(g.buttonY, B_X); K(g.buttonX, B_Y); }   // by position: right A, bottom B, top X, left Y
    K(g.leftShoulder, B_L); K(g.rightShoulder, B_R); K(g.leftTrigger, B_ZL); K(g.rightTrigger, B_ZR);
    K(g.buttonMenu, B_PLUS); if (g.buttonOptions) K(g.buttonOptions, B_MINUS);
    if (g.leftThumbstickButton) K(g.leftThumbstickButton, B_LS); if (g.rightThumbstickButton) K(g.rightThumbstickButton, B_RS);
    K(g.dpad.left, B_LEFT); K(g.dpad.up, B_UP); K(g.dpad.right, B_RIGHT); K(g.dpad.down, B_DOWN);
    #undef K
    dm_pad_set_player(p, m, axis(g.leftThumbstick.xAxis.value), axis(g.leftThumbstick.yAxis.value), axis(g.rightThumbstick.xAxis.value), axis(g.rightThumbstick.yAxis.value));
    shell_slot_input(p, m);
}

static void stop_using(GCController *c, int p) {   // c no longer feeds player p (disconnected or removed)
    c.extendedGamepad.valueChangedHandler = nil;
    dm_haptics_apple_controller(p, nil);
    shell_slot_free((__bridge const void *)c);
    if (p >= 0) dm_pad_set_player(p, 0, 0, 0, 0, 0);   // nothing stays pressed
    [g_pads removeObject:c];
}
static void pads_changed(GCController *gone) {   // a disconnect may still list the controller that went away: it is the notification's object
    NSArray<GCController *> *now = GCController.controllers;
    for (GCController *c in [g_pads copy]) if (c == gone || ![now containsObject:c]) {
        int p = shell_slot_of((__bridge const void *)c);
        LOG("controller '%s' disconnected: player %d is free", c.vendorName.UTF8String ?: "?", p + 1);
        stop_using(c, p);
    }
    for (GCController *c in [g_removed copy]) if (c == gone || ![now containsObject:c]) [g_removed removeObject:c];   // removed until it reconnects
    for (GCController *c in now) if (c.extendedGamepad && c != gone && ![g_pads containsObject:c] && ![g_removed containsObject:c]) {
        const char *name = c.vendorName.UTF8String ?: "?";
        int p = shell_slot_take((__bridge const void *)c, name, SHELL_SLOT_CONTROLLER, name);
        if (p < 0) { LOG("controller connected: all %d players are taken, not used", DM_PLAYERS); continue; }
        [g_pads addObject:c];
        shell_slot_set_layout(p, wanted_layout(SHELL_SLOT_CONTROLLER, name, name));
        c.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *g, GCControllerElement *el) { (void)el; read_pad(g.controller); };
        LOG("controller '%s' connected: player %d", name, p + 1);
        read_pad(c);
    }
    [NSNotificationCenter.defaultCenter postNotificationName:@"DMPadsChanged" object:nil];   // DmGamepad.m: the touch gamepad hides while a controller plays
}

// ---- The launcher's moves (shell_slots.h handlers for controllers; main thread) ----
static GCController *pad_of(const void *owner) { for (GCController *c in g_pads) if ((__bridge const void *)c == owner) return c; return nil; }
static void on_moved(const void *owner, int from, int to) {
    GCController *c = pad_of(owner); if (!c) return;
    dm_haptics_apple_controller(from, nil);   // its new player's rumble from now on (read_pad registers it there)
    LOG("controller '%s' moved in the launcher: player %d -> %d", c.vendorName.UTF8String ?: "?", from + 1, to + 1);
    read_pad(c);
}
static void on_kick(const void *owner) {
    GCController *c = pad_of(owner); if (!c) return;
    int p = shell_slot_of(owner);
    LOG("controller '%s' removed in the launcher: player %d is free", c.vendorName.UTF8String ?: "?", p + 1);
    [g_removed addObject:c];
    stop_using(c, p);
    [NSNotificationCenter.defaultCenter postNotificationName:@"DMPadsChanged" object:nil];
}
static void on_layout(const void *owner, int xbox) { (void)xbox; GCController *c = pad_of(owner); if (c) read_pad(c); }

// ---- The launcher's list ----
static void post_players(void) {
    shell_slot_info info[DM_PLAYERS]; shell_slots_list(info);
    for (int p = 0; p < DM_PLAYERS; p++) if (info[p].kind != SHELL_SLOT_NONE) {   // each device's own layout (a phone that just joined starts at Switch)
        int want = wanted_layout(info[p].kind, info[p].name, info[p].label);
        if (want != info[p].xbox) { shell_slot_set_layout(p, want); return; }   // that change posts again, with the list as it is now
    }
    NSMutableArray *players = [NSMutableArray array], *removed = [NSMutableArray array];
    for (int p = 0; p < DM_PLAYERS; p++) if (info[p].kind != SHELL_SLOT_NONE)
        [players addObject:@[@(p + 1), @(info[p].kind), str(info[p].label), str(info[p].name), @(info[p].xbox)]];
    for (NSUInteger i = 0; i < g_removed.count; i++) [removed addObject:@[@(i), g_removed[i].vendorName ?: @"?"]];
    static NSString *last;   // the log names each change of the list once
    NSMutableString *now = [NSMutableString string];
    for (int p = 0; p < DM_PLAYERS; p++) if (info[p].kind != SHELL_SLOT_NONE)
        [now appendFormat:@" P%d %@ '%@'%@", p + 1, info[p].kind == SHELL_SLOT_PHONE ? @"phone" : @"controller", str(info[p].label), info[p].xbox ? @" xbox" : @""];
    for (GCController *c in g_removed) [now appendFormat:@" removed '%@'", c.vendorName ?: @"?"];
    if (![now isEqualToString:last]) { last = [now copy]; LOG("players:%s", now.length ? now.UTF8String : " none"); }
    [NSNotificationCenter.defaultCenter postNotificationName:@"DMPlayersChanged" object:nil userInfo:@{@"players": players, @"removed": removed}];
}
static atomic_int g_post_pending;   // changes in a burst (a swap is two moves and a change) post the list once
static void slots_changed(void) {   // any thread (a phone joins on the server's)
    if (atomic_exchange(&g_post_pending, 1)) return;
    dispatch_async(dispatch_get_main_queue(), ^{ atomic_store(&g_post_pending, 0); post_players(); });
}

static void command(NSDictionary *u) {
    NSString *op = u[@"op"]; int p = [u[@"p"] intValue] - 1;
    if ([op isEqualToString:@"swap"]) shell_slot_swap([u[@"a"] intValue] - 1, [u[@"b"] intValue] - 1);
    else if ([op isEqualToString:@"kick"]) shell_slot_kick(p);
    else if ([op isEqualToString:@"layout"]) {
        shell_slot_info info[DM_PLAYERS]; shell_slots_list(info);
        if (p < 0 || p >= DM_PLAYERS || info[p].kind == SHELL_SLOT_NONE) return;
        [NSUserDefaults.standardUserDefaults setBool:[u[@"xbox"] boolValue] forKey:layout_key(info[p].name)];
        shell_slot_set_layout(p, [u[@"xbox"] boolValue]);
    } else if ([op isEqualToString:@"launcher"]) {
        atomic_store(&g_launcher, [u[@"on"] intValue] != 0);
        return;
    } else if ([op isEqualToString:@"add"]) {
        NSUInteger i = [u[@"index"] unsignedIntegerValue];
        if (i < g_removed.count) { [g_removed removeObjectAtIndex:i]; pads_changed(nil); }
    }
    post_players();   // refresh, and the answer to every other command
}

void shell_players_start(void) {   // main.m, on the main thread, once
    g_pads = [NSMutableArray array]; g_removed = [NSMutableArray array];
    shell_slots_handlers(SHELL_SLOT_CONTROLLER, on_moved, on_kick, on_layout);
    shell_slots_on_change(slots_changed);
    shell_slots_on_input(launcher_input);
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    for (NSNotificationName n in @[GCControllerDidConnectNotification, GCControllerDidDisconnectNotification])
        [nc addObserverForName:n object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            pads_changed([note.name isEqualToString:GCControllerDidDisconnectNotification] ? note.object : nil);
        }];
    [nc addObserverForName:@"DMPlayersCommand" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { command(note.userInfo); }];
    dispatch_async(dispatch_get_main_queue(), ^{ pads_changed(nil); });   // the ones already connected, once the app runs
}
int shell_players_controllers(void) { return (int)g_pads.count; }   // controllers playing now (main thread): the touch gamepad hides while there is one
void shell_players_release(void) { for (GCController *c in g_pads) { int p = shell_slot_of((__bridge const void *)c); if (p >= 0) dm_pad_set_player(p, 0, 0, 0, 0, 0); } }   // on resign active

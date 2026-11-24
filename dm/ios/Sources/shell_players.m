// Players of their own on iOS, from app launch (main.m shell_players_start), so the launcher already lists them: each physical controller (GameController) takes a
// player from the shared slot table (shell_slots.h) as it connects, as the phones do (phone_pads.c); the first is player 1, the next player 2, and so on up to 8 (a
// reconnected controller gets its player back). They go to dm_pad_set_player; player 1's is ORed with the touch gamepad in hle_hid.c, and a one-player game still sees
// every controller as player 1.
// The launcher's player list (Launcher.swift) talks to this file through two notifications, so Swift needs no C header:
//   DMPlayersChanged (posted here, main thread)  userInfo players: [[player, kind, label, name, xbox]] for each held slot (player from 1; kind 1 controller,
//                                               2 phone), removed: [[index, label]] for the controllers the launcher removed that are still connected
//   DMPlayersCommand (posted by the launcher)    userInfo op: refresh | swap (a, b: players from 1) | kick (p) | layout (p, xbox 0/1) | identify (p) | add (index into removed)
//                                               | launcher (on 0/1: the settings screen is shown)
//   DMLauncherInput (posted here, main thread)   while the launcher is shown, each player's controller or phone: userInfo p (player from 1), key: a | b | plus | up |
//                                               down | left | right (the left stick counts as the D-pad), on: 1 pressed, 0 released (directions only, so the launcher can
//                                               repeat them). Player 1 drives the whole screen, the others only their own row. While P1 is vacant all can drive the menus.
//   DMHomePressed (posted here, main thread)    a player pressed Home: a controller's Home (Xbox) button, − and + together, or a phone page's Home button
//                                               (shell_slot_home): userInfo p (player from 1). front_ios.m opens or closes its menu over the game
//   DMPlayerActive (posted here, main thread)    while the launcher is shown, any player pressed something or moved a stick: userInfo p (player from 1), at most
//                                               about 7 times a second per player: its row lights up
// Button layout, per player and kept in NSUserDefaults for the device (its name: a controller's model, a phone's id), which it gets as it connects: Xbox (A, B, X, Y
// as printed: A at the bottom) or Switch (by position: right A, bottom B). Two controllers of the same model may play in different layouts; the one changed last is
// what that model starts with. A device that has no choice yet: an Xbox-branded controller gets Xbox, another controller what DM_PAD_BY_LABEL says (the launcher's
// old switch, 0 when unset), a phone Switch. A phone's page draws its buttons in its layout (phone_pads.c sends it).
#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreHaptics/CoreHaptics.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <string.h>
#include <time.h>
#include "dm.h"
#include "dm_input.h"
#include "haptics_apple.h"
#include "shell_slots.h"
#include "shell_motion.h"

enum { B_A = 0, B_B, B_X, B_Y, B_LS, B_RS, B_L, B_R, B_ZL, B_ZR, B_PLUS, B_MINUS, B_LEFT, B_UP, B_RIGHT, B_DOWN };

static NSMutableArray<GCController *> *g_pads;    // the connected controllers that hold a player, kept alive while they do (the slot table keys on their pointers)
static NSMutableArray<GCController *> *g_removed; // connected controllers the launcher removed: unused until they reconnect or the launcher adds them back
static BOOL g_choose_primary;   // the cold-start controllers include physically indistinguishable copies of the same model

static NSString *str(const char *s) { return [NSString stringWithUTF8String:s] ?: @"?"; }   // a phone's name is whatever its page sent: not always UTF-8
static NSString *layout_key(const char *name) { return [@"DMPadLayout." stringByAppendingString:str(name)]; }
static int wanted_layout(int kind, const char *name, const char *label) {
    NSNumber *saved = [NSUserDefaults.standardUserDefaults objectForKey:layout_key(name)];
    if (saved) return saved.boolValue;
    if (kind != SHELL_SLOT_CONTROLLER) return 0;
    if (strcasestr(label, "xbox")) return 1;
    const char *e = getenv("DM_PAD_BY_LABEL"); return e && atoi(e) != 0;
}

// ---- Player 1 drives the launcher (shell_slot_input: controllers here, phones on the phone server's thread) ----
static atomic_int g_launcher;
static NSString *const primary_key = @"DMPrimaryPlayerIdentity";
static _Atomic uint64_t g_last_nav[DM_PLAYERS];   // each player's buttons, the left stick folded into the D-pad
static _Atomic uint64_t g_last_active[DM_PLAYERS];   // when each player's row last lit up (ns)
int front_ios_game_started(void);
static void home_input(int p, BOOL shortcut, BOOL phone) {   // any thread
    dispatch_async(dispatch_get_main_queue(), ^{
        int a = shell_slot_menu_player(p);
        if (a < 0) return;
        if (a != p) LOG("player %d's Home counts as player 1's: nobody holds player 1", p + 1);
        if (phone && !front_ios_game_started()) {
            if (a == 0) [NSNotificationCenter.defaultCenter postNotificationName:@"DMPhonePickerHome" object:nil];
        } else {
            [NSNotificationCenter.defaultCenter postNotificationName:@"DMHomePressed" object:nil userInfo:@{@"p": @(a + 1), @"shortcut": @(shortcut)}];
        }
    });
}
static void phone_home_press(int p) { home_input(p, NO, YES); }
static void launcher_input(int p, uint64_t buttons, int32_t lx, int32_t ly) {
    const int32_t t = DM_STICK_MAX / 2;
    // − and + pressed together: Home, for a controller with no Home button the app gets (and a phone, besides its page's own button)
    const uint64_t pm = 1ull << B_PLUS | 1ull << B_MINUS;
    if (atomic_load(&g_launcher) && (buttons || abs(lx) > t || abs(ly) > t)) {   // any player's input lights its row, so each one sees which player it is
        uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        if (now - atomic_load(&g_last_active[p]) > 150000000) {
            atomic_store(&g_last_active[p], now);
            NSDictionary *u = @{@"p": @(p + 1)};
            dispatch_async(dispatch_get_main_queue(), ^{ [NSNotificationCenter.defaultCenter postNotificationName:@"DMPlayerActive" object:nil userInfo:u]; });
        }
    }
    if (lx < -t) buttons |= 1ull << B_LEFT;
    if (lx > t) buttons |= 1ull << B_RIGHT;
    if (ly > t) buttons |= 1ull << B_UP;
    if (ly < -t) buttons |= 1ull << B_DOWN;
    uint64_t old = atomic_exchange(&g_last_nav[p], buttons), pressed = buttons & ~old, released = old & ~buttons;
    if ((buttons & pm) == pm && front_ios_game_started()) {
        if ((old & pm) != pm) home_input(p, YES, NO);
        pressed &= ~pm;
    }
    if (!atomic_load(&g_launcher) || !(pressed | released)) return;
    static const struct { int bit, held; const char *key; } keys[] = {
        {B_A, 0, "a"}, {B_B, 0, "b"}, {B_X, 0, "x"}, {B_Y, 0, "y"}, {B_PLUS, 1, "plus"}, {B_MINUS, 1, "minus"}, {B_UP, 1, "up"}, {B_DOWN, 1, "down"}, {B_LEFT, 1, "left"}, {B_RIGHT, 1, "right"}};
    for (size_t i = 0; i < sizeof keys / sizeof *keys; i++) {
        int on = (pressed >> keys[i].bit & 1) != 0;
        if (!on && !(keys[i].held && (released >> keys[i].bit & 1))) continue;   // a direction also reports its release: the launcher repeats it while held
        NSString *key = @(keys[i].key);
        dispatch_async(dispatch_get_main_queue(), ^{
            int menuPlayer = shell_slot_menu_player(p);
            if (menuPlayer < 0) return;
            [NSNotificationCenter.defaultCenter postNotificationName:@"DMLauncherInput" object:nil
                userInfo:@{@"key": key, @"on": @(on), @"p": @(menuPlayer + 1), @"source": @(p + 1)}];
        });
    }
}

static int32_t axis(float v) { return (int32_t)(fmaxf(-1.f, fminf(1.f, v)) * 32767); }
static void read_pad(GCController *c, bool layout_changed) {
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
    int32_t lx = axis(g.leftThumbstick.xAxis.value), ly = axis(g.leftThumbstick.yAxis.value);
    dm_pad_set_player(p, m, lx, ly, axis(g.rightThumbstick.xAxis.value), axis(g.rightThumbstick.yAxis.value));
    if (layout_changed) {
        // A held face button just acquired another label. This sample is a layout change, not a press.
        const uint64_t face = (1ull << B_A) | (1ull << B_B) | (1ull << B_X) | (1ull << B_Y);
        uint64_t old = atomic_load(&g_last_nav[p]);
        atomic_store(&g_last_nav[p], (old & ~face) | (m & face));
    }
    shell_slot_input(p, m, lx, ly);
}

// ---- A controller's gyroscope (DualSense, DualShock 4, Switch Pro): its player's six-axis sensor (shell_motion.h). GameController gives it in the controller's frame, x right,
// y away from the player, z up, the same as the game's ----
static NSMapTable<GCController *, NSMutableData *> *g_motion_state;   // each controller's shell_motion
static void motion_on(GCController *c) {
    GCMotion *mo = c.motion;
    if (!mo || !mo.hasRotationRate) return;
    if (mo.sensorsRequireManualActivation) mo.sensorsActive = YES;
    NSMutableData *st = [NSMutableData dataWithLength:sizeof(shell_motion)];
    [g_motion_state setObject:st forKey:c];
    LOG("controller '%s': its gyroscope is its player's motion", c.vendorName.UTF8String ?: "?");
    __weak GCController *wc = c;
    mo.valueChangedHandler = ^(GCMotion *m) {
        GCController *cc = wc; if (!cc) return;
        int p = shell_slot_of((__bridge const void *)cc); if (p < 0) return;
        double g[3], u[3] = {0, 0, 0}, r[3] = {m.rotationRate.x, m.rotationRate.y, m.rotationRate.z};
        if (m.hasGravityAndUserAcceleration) { g[0] = m.gravity.x; g[1] = m.gravity.y; g[2] = m.gravity.z; u[0] = m.userAcceleration.x; u[1] = m.userAcceleration.y; u[2] = m.userAcceleration.z; }
        else { g[0] = m.acceleration.x; g[1] = m.acceleration.y; g[2] = m.acceleration.z; }
        shell_motion_feed((shell_motion *)st.mutableBytes, p, CACurrentMediaTime(), g, u, r);
    };
}
static void motion_off(GCController *c) {
    c.motion.valueChangedHandler = nil;
    if (c.motion.sensorsRequireManualActivation) c.motion.sensorsActive = NO;
    [g_motion_state removeObjectForKey:c];
}

static void stop_using(GCController *c, int p) {   // c no longer feeds player p (disconnected or removed)
    c.extendedGamepad.valueChangedHandler = nil; c.extendedGamepad.buttonHome.pressedChangedHandler = nil;
    motion_off(c);
    dm_haptics_apple_controller(p, nil);
    shell_slot_free((__bridge const void *)c);
    if (p >= 0) {
        atomic_store(&g_last_nav[p], 0);
        dm_pad_set_player(p, 0, 0, 0, 0, 0);
    }
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
        c.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *g, GCControllerElement *el) { (void)el; read_pad(g.controller, false); };
        GCControllerButtonInput *home = c.extendedGamepad.buttonHome;   // the Xbox button, PlayStation's PS, the Pro Controller's Home: the app's menu, not the system's
        if (home) {
            home.preferredSystemGestureState = GCSystemGestureStateDisabled;
            __weak GCController *wc = c;
            home.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL pressed) {
                (void)b; (void)v; GCController *cc = wc; if (!pressed || !cc) return;
                int hp = shell_slot_of((__bridge const void *)cc); if (hp < 0) return;
                LOG("controller '%s' (player %d) pressed Home", cc.vendorName.UTF8String ?: "?", hp + 1); home_input(hp, NO, NO);
            };
        }
        motion_on(c);
        LOG("controller '%s' connected: player %d", name, p + 1);
        read_pad(c, false);
    }
    [NSNotificationCenter.defaultCenter postNotificationName:@"DMPadsChanged" object:nil];   // DmGamepad.m: the touch gamepad hides while a controller or phone plays
}

// ---- The launcher's moves (shell_slots.h handlers for controllers; main thread) ----
static GCController *pad_of(const void *owner) { for (GCController *c in g_pads) if ((__bridge const void *)c == owner) return c; return nil; }
static void on_moved(const void *owner, int from, int to) {
    GCController *c = pad_of(owner); if (!c) return;
    shell_slot_info info[DM_PLAYERS]; shell_slots_list(info);
    if (info[from].kind != SHELL_SLOT_CONTROLLER) dm_haptics_apple_controller(from, nil);
    LOG("controller '%s' moved in the launcher: player %d -> %d", c.vendorName.UTF8String ?: "?", from + 1, to + 1);
    read_pad(c, true);   // the A that confirmed the move must not also activate the next menu item
}
static void on_kick(const void *owner) {
    GCController *c = pad_of(owner); if (!c) return;
    int p = shell_slot_of(owner);
    LOG("controller '%s' removed in the launcher: player %d is free", c.vendorName.UTF8String ?: "?", p + 1);
    [g_removed addObject:c];
    stop_using(c, p);
    [NSNotificationCenter.defaultCenter postNotificationName:@"DMPadsChanged" object:nil];
}
static void on_layout(const void *owner, int xbox) { (void)xbox; GCController *c = pad_of(owner); if (c) read_pad(c, true); }
static void on_identify(const void *owner) {   // the launcher's "which one is this?": a short rumble of its own (an engine apart from the game's, stopped after it)
    GCController *c = pad_of(owner); if (!c.haptics) return;
    CHHapticEngine *e = [c.haptics createEngineWithLocality:GCHapticsLocalityDefault]; NSError *err = nil;
    if (!e || ![e startAndReturnError:&err]) return;
    CHHapticEvent *ev = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous
        parameters:@[[[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:1]] relativeTime:0 duration:0.4];
    CHHapticPattern *pat = [[CHHapticPattern alloc] initWithEvents:@[ev] parameters:@[] error:&err];
    id<CHHapticPatternPlayer> pl = pat ? [e createPlayerWithPattern:pat error:&err] : nil;
    [pl startAtTime:CHHapticTimeImmediate error:&err];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 700 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [e stopWithCompletionHandler:nil]; });
}

static NSArray<NSNumber *> *primary_candidates(void) {
    GCController *primary = nil;
    for (GCController *c in g_pads) {
        if (shell_slot_of((__bridge const void *)c) == 0) { primary = c; break; }
    }
    NSString *model = primary.vendorName;
    if (!model.length) return @[];
    NSMutableArray<NSNumber *> *candidates = [NSMutableArray array];
    for (GCController *c in g_pads) {
        if (![model isEqualToString:c.vendorName] || ![primary.productCategory isEqualToString:c.productCategory]) continue;
        int p = shell_slot_of((__bridge const void *)c);
        if (p >= 0) [candidates addObject:@(p + 1)];
    }
    return candidates.count > 1 ? candidates : @[];
}

// ---- The launcher's list ----
// A phone whose Wi-Fi drops for a moment reconnects at once and gets its player back; its row would vanish and come back, and the whole list below it jump. So a list
// that lost a phone is posted only when the phone stays away for PHONE_GRACE seconds (or the launcher removed it)
enum { PHONE_GRACE = 3 };
static NSSet<NSString *> *g_shown_phones;          // the phones (their ids) in the list last posted
static NSMutableSet<NSString *> *g_removing;       // phones the launcher removed: they leave the list at once
static int g_grace_waiting;
static void post_players(void) {
    shell_slot_info info[DM_PLAYERS]; shell_slots_list(info);
    // a phone's own layout (one that just joined starts at Switch). Not a controller's: it got its layout as it connected, and its name is only its model, so
    // two controllers of the same model would be switched together
    for (int p = 0; p < DM_PLAYERS; p++) if (info[p].kind == SHELL_SLOT_PHONE) {
        int want = wanted_layout(info[p].kind, info[p].name, info[p].label);
        if (want != info[p].xbox) { shell_slot_set_layout(p, want); return; }   // that change posts again, with the list as it is now
    }
    NSMutableSet<NSString *> *phones = [NSMutableSet set];
    for (int p = 0; p < DM_PLAYERS; p++) if (info[p].kind == SHELL_SLOT_PHONE) [phones addObject:str(info[p].name)];
    NSMutableSet<NSString *> *gone = [g_shown_phones mutableCopy] ?: [NSMutableSet set];
    [gone minusSet:phones];
    if (g_grace_waiting >= 0 && ![gone isSubsetOfSet:g_removing]) {   // a phone dropped off: give it time to come back
        if (!g_grace_waiting) {
            g_grace_waiting = 1;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, PHONE_GRACE * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ g_grace_waiting = -1; post_players(); g_grace_waiting = 0; });
        }
        return;
    }
    [g_removing minusSet:gone];
    g_shown_phones = phones;
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
    NSArray *candidates = g_choose_primary ? primary_candidates() : @[];
    if (!candidates.count) g_choose_primary = NO;
    [NSNotificationCenter.defaultCenter postNotificationName:@"DMPlayersChanged" object:nil
        userInfo:@{@"players": players, @"removed": removed, @"primaryCandidates": candidates}];
}
static atomic_int g_post_pending;   // changes in a burst (a swap is two moves and a change) post the list once
static void slots_changed(void) {   // any thread (a phone joins on the server's)
    if (atomic_exchange(&g_post_pending, 1)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        atomic_store(&g_post_pending, 0);
        char primary[64]; shell_slot_primary_name(primary);
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSString *name = primary[0] ? [NSString stringWithUTF8String:primary] : nil;
        NSString *saved = [defaults stringForKey:primary_key];
        if (name && ![name isEqualToString:saved]) [defaults setObject:name forKey:primary_key];
        else if (!name && saved) [defaults removeObjectForKey:primary_key];
        post_players();
        [NSNotificationCenter.defaultCenter postNotificationName:@"DMPadsChanged" object:nil];   // DmGamepad.m: a phone that joined or left
    });
}

static void command(NSDictionary *u);
// A phone's page switched its own layout (phone_pads.c, its server thread): kept for that phone as the launcher's switch is
static void layout_request(int p, int xbox) { dispatch_async(dispatch_get_main_queue(), ^{ command(@{@"op": @"layout", @"p": @(p + 1), @"xbox": @(xbox)}); }); }
static void command(NSDictionary *u) {
    NSString *op = u[@"op"]; int p = [u[@"p"] intValue] - 1;
    if ([op isEqualToString:@"swap"]) {
        int a = [u[@"a"] intValue] - 1, b = [u[@"b"] intValue] - 1;
        if (a == 0 || b == 0) g_choose_primary = NO;
        shell_slot_swap(a, b);
    } else if ([op isEqualToString:@"choosePrimary"]) {
        if (!g_choose_primary || ![primary_candidates() containsObject:@(p + 1)]) return;
        g_choose_primary = NO;
        shell_slot_swap(0, p);
    }
    else if ([op isEqualToString:@"kick"]) {
        shell_slot_info info[DM_PLAYERS]; shell_slots_list(info);
        if (p >= 0 && p < DM_PLAYERS && info[p].kind == SHELL_SLOT_PHONE) [g_removing addObject:str(info[p].name)];
        shell_slot_kick(p);
    }
    else if ([op isEqualToString:@"layout"]) {
        shell_slot_info info[DM_PLAYERS]; shell_slots_list(info);
        if (p < 0 || p >= DM_PLAYERS || info[p].kind == SHELL_SLOT_NONE) return;
        [NSUserDefaults.standardUserDefaults setBool:[u[@"xbox"] boolValue] forKey:layout_key(info[p].name)];
        shell_slot_set_layout(p, [u[@"xbox"] boolValue]);
    } else if ([op isEqualToString:@"identify"]) {   // the badge lights up too (the iPad's own touch controls have nothing to buzz)
        shell_slot_identify(p);
        [NSNotificationCenter.defaultCenter postNotificationName:@"DMPlayerActive" object:nil userInfo:@{@"p": @(p + 1)}];
        return;
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
    g_pads = [NSMutableArray array]; g_removed = [NSMutableArray array]; g_removing = [NSMutableSet set]; g_motion_state = [NSMapTable strongToStrongObjectsMapTable];
    shell_slot_restore_primary([NSUserDefaults.standardUserDefaults stringForKey:primary_key].UTF8String);
    shell_slots_handlers(SHELL_SLOT_CONTROLLER, on_moved, on_kick, on_layout);
    shell_slots_on_layout_request(layout_request);
    shell_slots_identify_handler(SHELL_SLOT_CONTROLLER, on_identify);
    shell_slots_on_change(slots_changed);
    shell_slots_on_input(launcher_input);
    shell_slots_on_home(phone_home_press);
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    for (NSNotificationName n in @[GCControllerDidConnectNotification, GCControllerDidDisconnectNotification])
        [nc addObserverForName:n object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            pads_changed([note.name isEqualToString:GCControllerDidDisconnectNotification] ? note.object : nil);
        }];
    [nc addObserverForName:@"DMPlayersCommand" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { command(note.userInfo); }];
    dispatch_async(dispatch_get_main_queue(), ^{
        pads_changed(nil);   // the ones already connected, once the app runs
        g_choose_primary = primary_candidates().count > 0;
        if (g_choose_primary) post_players();
    });
}
int shell_players_external(void) {   // controllers and phones playing now (main thread): the touch gamepad hides while there is one
    shell_slot_info info[DM_PLAYERS]; shell_slots_list(info);
    int n = 0; for (int p = 0; p < DM_PLAYERS; p++) n += info[p].kind != SHELL_SLOT_NONE;
    return n;
}
void shell_players_release(void) { for (GCController *c in g_pads) { int p = shell_slot_of((__bridge const void *)c); if (p >= 0) dm_pad_set_player(p, 0, 0, 0, 0, 0); } }   // on resign active

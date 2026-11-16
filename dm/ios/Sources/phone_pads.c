// Phone controllers: phones on the same Wi-Fi open http://<iPad address>:8080/ in their browser and play as controllers, no app installed. Each phone is a player of its own,
// from the app's one player-slot table (shell_slots.h), which the physical controllers (DmGamepad.m) take theirs from too, so a phone and a controller never share a player and
// dm_pad_players is set from one mask: a phone gets player 1 while no controller holds it (together with the touch gamepad, which stays player 1's), else the next free one,
// up to 8. A phone that reloads its page or reconnects gets its player back while it is free, keyed on the id its page keeps in localStorage.
// The launcher may swap a phone's player with another or remove the phone (shell_slots.h): a removed phone is told so (kicked) and stays out, even across reconnects, until
// its page asks to join again or the app restarts.
// One port serves the page (GET /, phone_pad_page.h, generated from phone_pad.html) and the controller stream (GET /ws, WebSocket). Protocol, all from the phone:
//   text   {"t":"layout","xbox":0|1}  -> the phone's own layout switch, answered with an assign in that layout
//   text   {"t":"home"}  -> the page's Home button: the app's menu over the game (shell_slot_home), as a controller's Home button
//   text   {"t":"hello","v":1,"id":"<device id>","name":"<label>"[,"join":1]}  -> answered {"t":"assign","player":<1..8>,"layout":"switch"|"xbox"}, {"t":"full"} or {"t":"kicked"}
//          (join: the player asked to come back after the launcher removed the phone); assign comes again whenever the launcher moves the phone to another player or changes its button layout
//   binary 8 bytes: 0x01, sequence (u8, wraps), buttons (u16 LE, NpadButton bits as dm_input.h), lx, ly, rx, ry (i8 each, -127..127, y up)
//   binary 16 bytes: 0x03, sequence (u8), time (u16 LE, ms, wraps), gravity x y z (i16 LE, G * 4096: the acceleration, pointing down), rotation x y z (i16 LE, degrees / s * 8),
//          in the controller's frame (x right, y away from the player, z out of the screen): the phone's motion as its player's six-axis sensor (shell_motion.h)
//   and to the phone, besides the answers above: {"t":"r","l":<0..255>} the game's rumble for its player (sent on a change, at most every 30 ms, again every 400 ms while it runs)
// The phone sends on every change and at least every 100 ms; a phone silent for a second has everything released. One thread, poll(), plain BSD sockets.
// Connections that hold no player cannot pile up and lock phones out: a request that does not arrive within REQ_NS, or a WebSocket silent for GONE_NS, is closed, and when every
// connection is taken a new one closes the oldest connection without a player (a browser's spare preconnect, the page of a phone that walked away while 'full' or removed).
// HTTPS on the same port (phone_pads_tls.h; a connection that opens with a TLS handshake): browsers give a page the phone's motion sensors only over HTTPS, and the page's Motion
// button moves to https://. The certificate is the app's own, so the phone asks once to trust it, and iPhone Safari then still refuses WebSockets to it: such a page sends its
// messages by POST /p?id=<device id> instead, a body of frames (kind u8: 1 text, 2 binary; length u16 LE; the message as above), answered with the messages for the phone, one
// JSON object a line. A POST page is a session of its own (kind SESSION, no socket): its requests may come on any connection, and it ends after GONE_NS without one.
// The service is announced over Bonjour as _nxpad._tcp: besides letting tools find it, that is what makes iOS ask for local network access (NSLocalNetworkUsageDescription).
// DM_PHONE_PADS=0 turns it off; DM_PHONE_PADS_PORT picks another port (8080 by default).
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <arpa/inet.h>
#include <time.h>
#include <unistd.h>
#include "dm.h"
#include "dm_input.h"
#include "hle_haptics.h"
#include "phone_pad_page.h"
#include "phone_pads_tls.h"
#include "shell_motion.h"
#include "shell_slots.h"
#ifdef __APPLE__
#include <dns_sd.h>
#include <pthread/qos.h>
#endif

enum { MAX_CLIENTS = 32, IN_CAP = 4096, OUT_CAP = 1024 };
enum { HTTP = 0, WS = 1, SESSION = 2 };   // a connection before (or without) the WebSocket switch, a WebSocket, a POST page's session (no socket: fd SESSION_FD)
#define SESSION_FD (-2)
#define SILENT_NS 1000000000ull   // quiet this long: nothing held down
#define GONE_NS 15000000000ull    // quiet this long: the page is gone (a tab left in the background keeps its socket open), its player is freed
#define ALIVE_NS 300000000ull    // heard within this: the page is in front (it sends at least every 100 ms while it is)
#define REQ_NS 10000000000ull     // a connection that has sent no request this long (since it opened, or since its last request) is closed
#define RUMBLE_GAP_NS 30000000ull       // rumble changes reach a phone at most this often
#define MIN_HOLD_NS 50000000ull   // a press the game is sure to see: a tap shorter than this (or a press and its release that the Wi-Fi delivered together) is held this long
#define RUMBLE_REPEAT_NS 400000000ull   // and a running rumble is repeated this often (the page's vibration pattern runs a little longer)
typedef struct {
    int fd, kind, player;        // fd: -1 a free entry; player: slot index, -1 before the hello
    uint32_t ip;                 // the phone's address (network order): one phone, one player
    void *tls;                   // the connection's TLS (phone_pads_tls.h), NULL for plain HTTP
    size_t n; uint8_t in[IN_CAP];
    int last_seq; uint64_t last_ns; int released;
    uint16_t raw; int32_t axes[4];   // the buttons and sticks the phone last sent; what the game gets adds the taps still held (MIN_HOLD_NS)
    uint16_t kept; uint64_t press_ns[16], hold_until;   // kept: buttons the phone let go of that stay down until hold_until; when each button went down
    uint64_t open_ns, seen_ns;   // when the connection opened, when anything last arrived on it (a session: its last request)
    char name[64], id[64];       // id: the phone's own (its page's localStorage), the slot table's name for it
    char out[OUT_CAP]; size_t on;   // a session's messages for the phone, until its next request takes them
    int hp;                      // the player whose rumble this phone takes (dm_haptics_route), -1 none
    int rumble; uint64_t rumble_ns;   // the rumble level last sent, when
    shell_motion motion; uint64_t mt; int mlast;   // the phone's orientation (shell_motion.h); its clock in ms, unwrapped, and the last raw u16
    _Atomic int moved, kicked, relayout, identify;   // set by the launcher (shell_slots.h handlers, main thread), handled on the server thread
} client;
static client g_cl[MAX_CLIENTS];   // a client's address is its owner in the slot table; only the server thread touches a client, but for the two flags
static char g_banned[MAX_CLIENTS][64];   // ids of phones the launcher removed: they stay out until they ask to join again
static int used(const client *c) { return c->fd != -1; }

#ifndef __APPLE__   // no TLS off Apple, but where a test links phone_pads_tls_test.c
__attribute__((weak)) void *pp_tls_new(int fd) { (void)fd; return NULL; }
__attribute__((weak)) long pp_tls_recv(void *t, void *b, size_t n) { (void)t; (void)b; (void)n; return -1; }
__attribute__((weak)) int pp_tls_send(void *t, const void *p, size_t n) { (void)t; (void)p; (void)n; return -1; }
__attribute__((weak)) void pp_tls_free(void *t) { (void)t; }
#endif

// ---- SHA-1 + base64, for the WebSocket handshake only ----
static void sha1(const uint8_t *m, size_t len, uint8_t out[20]) {
    uint32_t h[5] = {0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0};
    uint8_t blk[64]; uint64_t bits = (uint64_t)len * 8; size_t total = ((len + 8) / 64 + 1) * 64;
    for (size_t off = 0; off < total; off += 64) {
        for (int i = 0; i < 64; i++) {
            size_t k = off + i;
            blk[i] = k < len ? m[k] : k == len ? 0x80 : k >= total - 8 ? (uint8_t)(bits >> (8 * (total - 1 - k))) : 0;
        }
        uint32_t w[80];
        for (int i = 0; i < 16; i++) w[i] = (uint32_t)blk[4 * i] << 24 | (uint32_t)blk[4 * i + 1] << 16 | (uint32_t)blk[4 * i + 2] << 8 | blk[4 * i + 3];
        for (int i = 16; i < 80; i++) { uint32_t x = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]; w[i] = x << 1 | x >> 31; }
        uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4];
        for (int i = 0; i < 80; i++) {
            uint32_t f, k;
            if (i < 20) { f = (b & c) | (~b & d); k = 0x5A827999; } else if (i < 40) { f = b ^ c ^ d; k = 0x6ED9EBA1; }
            else if (i < 60) { f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC; } else { f = b ^ c ^ d; k = 0xCA62C1D6; }
            uint32_t t = (a << 5 | a >> 27) + f + e + k + w[i]; e = d; d = c; c = b << 30 | b >> 2; b = a; a = t;
        }
        h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e;
    }
    for (int i = 0; i < 20; i++) out[i] = (uint8_t)(h[i / 4] >> (24 - 8 * (i % 4)));
}
static void base64(const uint8_t *in, size_t n, char *out) {
    static const char T[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    size_t o = 0;
    for (size_t i = 0; i < n; i += 3) {
        uint32_t v = (uint32_t)in[i] << 16 | (i + 1 < n ? (uint32_t)in[i + 1] << 8 : 0) | (i + 2 < n ? in[i + 2] : 0);
        out[o++] = T[v >> 18 & 63]; out[o++] = T[v >> 12 & 63];
        out[o++] = i + 1 < n ? T[v >> 6 & 63] : '='; out[o++] = i + 2 < n ? T[v & 63] : '=';
    }
    out[o] = 0;
}

// ---- Sending ----
static void send_raw(int fd, const void *p, size_t n) {
    const uint8_t *b = p;
    while (n) {
        ssize_t w = send(fd, b, n, 0);
        if (w < 0 && errno == EINTR) continue;
        if (w < 0 && errno == EAGAIN) { struct pollfd p = {.fd = fd, .events = POLLOUT}; if (poll(&p, 1, 1000) > 0) continue; return; }   // the page is bigger than the socket buffer
        if (w <= 0) return;
        b += w; n -= (size_t)w;
    }
}
static void send_all(client *c, const void *p, size_t n) {
    if (c->fd < 0) return;
    if (c->tls) pp_tls_send(c->tls, p, n); else send_raw(c->fd, p, n);
}
// A message for the phone: a WebSocket frame, or for a session the next answer's line
static void say(client *c, const char *s) {
    size_t n = strlen(s);
    if (c->kind == SESSION) {
        if (c->on + n + 1 > OUT_CAP) c->on = 0;   // a phone that stopped asking: only the newest matter
        memcpy(c->out + c->on, s, n); c->out[c->on + n] = '\n'; c->on += n + 1;
        return;
    }
    if (c->kind != WS) return;
    uint8_t h[4] = {0x81, 0}; size_t hn = 2;
    if (n < 126) h[1] = (uint8_t)n; else { h[1] = 126; h[2] = (uint8_t)(n >> 8); h[3] = (uint8_t)n; hn = 4; }
    uint8_t f[OUT_CAP + 4]; if (n > OUT_CAP) return;
    memcpy(f, h, hn); memcpy(f + hn, s, n); send_all(c, f, hn + n);   // one write: one TLS record
}

// ---- Rumble: the game's vibration for a phone's player (hle_haptics.h), as one level the page plays ----
// The player's rumble is routed while a phone holds it, so the game's vibration is kept for it (dm_haptics_actual); the Apple output has no channel for it and plays nothing
static void haptics_follow(client *c) {
    int p = c->player < 0 ? -1 : shell_slot_of(c);
    if (p != c->hp) {
        if (c->hp >= 0) {   // given back, unless a controller has it now (haptics_apple.m routes that one)
            shell_slot_info info[DM_PLAYERS]; shell_slots_list(info);
            if (info[c->hp].kind != SHELL_SLOT_CONTROLLER) dm_haptics_route(c->hp, 0);
        }
        c->hp = p; c->rumble = 0; c->rumble_ns = 0;
        if (p >= 0) dm_haptics_route(p, 1);
    } else if (p >= 0 && dm_haptics_enabled() && !(dm_haptics_available() >> p & 1)) dm_haptics_route(p, 1);   // the game's start set up the routes afresh (dm_haptics_init)
}
static int rumble_level(int p) {
    dm_vibration v[2] = {dm_haptics_actual(p, 0), dm_haptics_actual(p, 1)};
    int l = (int)(dm_haptics_level(v, 2, 1).intensity * 255 + 0.5f);
    return l < 0 ? 0 : l > 255 ? 255 : l;
}
static int rumble_due(client *c, uint64_t t) {   // 1: a rumble message is waiting for the gap to pass
    if (c->hp < 0 || c->kind == HTTP) return 0;
    int l = rumble_level(c->hp);
    if (l == c->rumble && !(l && t - c->rumble_ns >= RUMBLE_REPEAT_NS)) return 0;
    if (t - c->rumble_ns < RUMBLE_GAP_NS) return 1;
    char m[32]; snprintf(m, sizeof m, "{\"t\":\"r\",\"l\":%d}", l); say(c, m);
    c->rumble = l; c->rumble_ns = t;
    return 0;
}

// ---- Players ----
static void send_assign(client *c, int p);
static void release(client *c) { int p = shell_slot_of(c); c->raw = 0; c->kept = 0; c->hold_until = 0; if (p >= 0 && !c->released) { dm_pad_set_player(p, 0, 0, 0, 0, 0); c->released = 1; } }
// A game reads the buttons once a frame, so a press and its release closer together than a frame or two are never seen: a quick tap (Tetris), or two packets the
// Wi-Fi held back and handed over at once. A button let go within MIN_HOLD_NS of going down stays down until then (the loop below lets it go)
static void hold_expire(client *c, int p, uint64_t t) {
    if (!c->kept || t < c->hold_until) return;
    uint16_t still = 0; uint64_t until = 0;
    for (int b = 0; b < 16; b++) if (c->kept >> b & 1 && t - c->press_ns[b] < MIN_HOLD_NS) { still |= 1 << b; if (!until || c->press_ns[b] + MIN_HOLD_NS < until) until = c->press_ns[b] + MIN_HOLD_NS; }   // the next to let go
    c->kept = still; c->hold_until = until;
    if (p >= 0) { dm_pad_set_player(p, c->raw | c->kept, c->axes[0], c->axes[1], c->axes[2], c->axes[3]); shell_slot_input(p, c->raw | c->kept, c->axes[0], c->axes[1]); }
}
static void drop(client *c) {
    if (c->player >= 0) {
        release(c);
        int p = shell_slot_free(c);
        LOG("phone pads: '%s' disconnected: player %d is free (the phone gets it back when it reconnects)", c->name, p + 1);
    }
    c->player = -1; haptics_follow(c);
    if (c->tls) pp_tls_free(c->tls);
    if (c->fd >= 0) close(c->fd);
    memset(c, 0, sizeof *c); c->fd = -1; c->player = -1; c->hp = -1;
}
static void replace(client *old, const char *name) {
    LOG("phone pads: '%s' joined again from the same phone: the old page's player %d goes", name, shell_slot_of(old) + 1);
    say(old, "{\"t\":\"replaced\"}");
    drop(old);
}
// The value of "key":"..." in a small JSON object (the hello); enough for this protocol, which never escapes quotes in these fields
static int json_str(const char *j, const char *key, char *out, size_t cap) {
    char pat[32]; snprintf(pat, sizeof pat, "\"%s\"", key);
    const char *p = strstr(j, pat); if (!p) return 0;
    p += strlen(pat); while (*p == ' ' || *p == ':') p++;
    if (*p++ != '"') return 0;
    size_t n = 0; while (*p && *p != '"' && n + 1 < cap) { unsigned char ch = (unsigned char)*p++; out[n++] = ch < 0x20 ? '?' : (char)ch; }
    out[n] = 0; return n > 0;
}
static int banned(const char *id, int unban) {
    for (int i = 0; i < MAX_CLIENTS; i++) if (g_banned[i][0] && !strcmp(g_banned[i], id)) { if (unban) g_banned[i][0] = 0; return !unban; }
    return 0;
}
static void on_hello(client *c, const char *json) {
    char id[64], name[32] = "phone";
    if (!json_str(json, "id", id, sizeof id)) return;
    json_str(json, "name", name, sizeof name);
    if (banned(id, strstr(json, "\"join\"") != NULL)) { say(c, "{\"t\":\"kicked\"}"); return; }
    if (c->player >= 0) { release(c); shell_slot_free(c); c->player = -1; }
    // The same phone still connected on an older socket (a page that reloaded before the old connection timed out, a second tab): that one is told it was replaced, so it
    // stops reconnecting (phone_pad.html) instead of taking the player back and the two pages trading it forever, and closed, so this one takes its player
    for (int i = 0; i < MAX_CLIENTS; i++) if (&g_cl[i] != c && used(&g_cl[i]) && g_cl[i].player >= 0 && !strcmp(g_cl[i].id, id)) replace(&g_cl[i], name);
    // The same address from another page with its own storage, so another id (Safari and the Home Screen copy, or a second browser): the old page goes if it has gone quiet,
    // as a page that is no longer in front does at once. One that is still sending is another phone behind the same address (a range extender or guest network that
    // translates addresses): it keeps its player. Not for loopback, which is the server test's several phones on one machine
    if (c->ip && c->ip != htonl(INADDR_LOOPBACK))
        for (int i = 0; i < MAX_CLIENTS; i++) if (&g_cl[i] != c && used(&g_cl[i]) && g_cl[i].player >= 0 && g_cl[i].ip == c->ip && now_ns() - g_cl[i].seen_ns > ALIVE_NS)
            replace(&g_cl[i], name);
    int p = shell_slot_take(c, id, SHELL_SLOT_PHONE, name);   // a phone that held a player before has its id on that slot and gets it back while it is free
    snprintf(c->name, sizeof c->name, "%s", name); snprintf(c->id, sizeof c->id, "%s", id);
    if (p < 0) { say(c, "{\"t\":\"full\"}"); LOG("phone pads: '%s' connected: all %d players are taken, not used", name, DM_PLAYERS); return; }
    c->player = p; c->last_seq = -1; c->last_ns = now_ns(); c->released = 1; c->motion.init = 0;
    send_assign(c, p);
    haptics_follow(c);
    char why[16] = ""; json_str(json, "why", why, sizeof why);   // load / ping / closed / front (phone_pad.html hello)
    LOG("phone pads: '%s' connected%s: player %d%s%s", name, c->kind == SESSION ? " (HTTPS requests)" : c->tls ? " (HTTPS)" : "", p + 1, why[0] ? ", after " : "", why);
}
// The page's own layout switch: the same as the launcher's (shell_players.m keeps it for this phone); the assign that follows redraws the page
static void on_text(client *c, const char *json) {
    char t[16] = ""; json_str(json, "t", t, sizeof t);
    if (!strcmp(t, "home")) { int p = c->player < 0 ? -1 : shell_slot_of(c); if (p >= 0) { LOG("phone pads: '%s' (player %d) pressed Home", c->name, p + 1); shell_slot_home(p); } return; }
    if (!strcmp(t, "ping")) { say(c, "{\"t\":\"pong\"}"); return; }
    if (!strcmp(t, "note")) { char w[48] = ""; json_str(json, "w", w, sizeof w); LOG("phone pads: '%s': the page %s", c->name, w); return; }   // phone_pad.html note()   // the page's check that the iPad is still there (phone_pad.html)
    if (strcmp(t, "layout")) { on_hello(c, json); return; }
    int p = c->player < 0 ? -1 : shell_slot_of(c); if (p < 0) return;
    int xbox = strstr(json, "\"xbox\":1") != NULL;
    LOG("phone pads: '%s' (player %d) chose the %s layout on the phone", c->name, p + 1, xbox ? "Xbox" : "Switch");
    shell_slot_request_layout(p, xbox);
}
static int16_t i16(const uint8_t *b) { return (int16_t)(b[0] | b[1] << 8); }
static void on_motion(client *c, int p, const uint8_t *b) {
    int raw = b[2] | b[3] << 8;
    if (!c->motion.init) { c->mt = 1000; c->mlast = raw; }   // the phone's clock: only its steps count, from a second in (shell_motion starts afresh on its first reading)
    c->mt += (uint16_t)(raw - c->mlast); c->mlast = raw;
    double g[3], r[3], u[3] = {0, 0, 0};
    for (int i = 0; i < 3; i++) { g[i] = i16(b + 4 + 2 * i) / 4096.0; r[i] = i16(b + 10 + 2 * i) / 8.0 * 3.14159265358979 / 180; }
    if (!c->motion.init) LOG("phone pads: '%s' (player %d) sends its motion", c->name, p + 1);
    shell_motion_feed(&c->motion, p, c->mt / 1000.0, g, u, r);
}
static void on_binary(client *c, const uint8_t *b, size_t n) {
    int p = c->player < 0 ? -1 : shell_slot_of(c);   // the table's, not c->player: the launcher may have just moved the phone
    if (p < 0 || n < 8) return;
    if (b[0] == 3 && n >= 16) { on_motion(c, p, b); return; }
    if (b[0] != 1) return;
    int seq = b[1];
    if (c->last_seq >= 0 && ((seq - c->last_seq) & 255) > 128) return;   // older than the last one taken: arrived out of order
    c->last_seq = seq; c->last_ns = now_ns(); c->released = 0;
    uint16_t raw = (uint16_t)(b[2] | b[3] << 8), down = raw & ~c->raw, up = c->raw & ~raw;
    uint64_t t = c->last_ns;
    for (int k = 0; k < 16; k++) {
        if (down >> k & 1) { c->press_ns[k] = t; c->kept &= ~(1 << k); }
        else if (up >> k & 1 && t - c->press_ns[k] < MIN_HOLD_NS) c->kept |= 1 << k;
    }
    c->hold_until = 0;
    for (int k = 0; k < 16; k++) if (c->kept >> k & 1 && (!c->hold_until || c->press_ns[k] + MIN_HOLD_NS < c->hold_until)) c->hold_until = c->press_ns[k] + MIN_HOLD_NS;
    c->raw = raw;
    for (int i = 0; i < 4; i++) c->axes[i] = (int8_t)b[4 + i] * (DM_STICK_MAX / 127);
    uint64_t btn = raw | c->kept;
    dm_pad_set_player(p, btn, c->axes[0], c->axes[1], c->axes[2], c->axes[3]);
    shell_slot_input(p, btn, c->axes[0], c->axes[1]);
}

// ---- The launcher's moves and removals (shell_slots.h handlers): called on the main thread, carried out by the server thread ----
static client *client_of(const void *owner) { const client *c = owner; return c >= g_cl && c < g_cl + MAX_CLIENTS ? (client *)c : NULL; }
static void on_moved(const void *owner, int from, int to) { (void)from; (void)to; client *c = client_of(owner); if (c) atomic_store(&c->moved, 1); }
static void on_kick(const void *owner) { client *c = client_of(owner); if (c) atomic_store(&c->kicked, 1); }
static void on_layout(const void *owner, int xbox) { (void)xbox; client *c = client_of(owner); if (c) atomic_store(&c->relayout, 1); }
static void on_identify(const void *owner) { client *c = client_of(owner); if (c) atomic_store(&c->identify, 1); }
static void send_assign(client *c, int p) {   // the player and the button layout the page shows
    char msg[64]; snprintf(msg, sizeof msg, "{\"t\":\"assign\",\"player\":%d,\"layout\":\"%s\"}", p + 1, shell_slot_layout(c) ? "xbox" : "switch"); say(c, msg);
}
static void launcher_requests(client *c) {
    if (atomic_exchange(&c->kicked, 0) && c->player >= 0) {
        release(c);
        shell_slot_free(c);
        for (int i = 0; i < MAX_CLIENTS; i++) if (!g_banned[i][0]) { snprintf(g_banned[i], sizeof g_banned[i], "%s", c->id); break; }
        LOG("phone pads: '%s' removed in the launcher: player %d is free", c->name, c->player + 1);
        c->player = -1;
        say(c, "{\"t\":\"kicked\"}");
    }
    if (atomic_exchange(&c->moved, 0) && c->player >= 0) {
        int p = shell_slot_of(c); if (p < 0) return;
        LOG("phone pads: '%s' moved in the launcher: player %d -> %d", c->name, c->player + 1, p + 1);
        c->player = p; c->released = 0; c->motion.init = 0;   // its next packet (at most 100 ms away) feeds the new player
        send_assign(c, p);
    }
    if (atomic_exchange(&c->relayout, 0) && c->player >= 0) send_assign(c, c->player);
    if (atomic_exchange(&c->identify, 0) && c->player >= 0) say(c, "{\"t\":\"rumble\",\"ms\":400,\"flash\":1}");   // the page vibrates and flashes
    haptics_follow(c);
}

// ---- HTTP, the POST sessions and the WebSocket frames ----
static client *session_for(client *conn, const char *id) {   // the POST page's session for this device id, made on its first request
    for (int i = 0; i < MAX_CLIENTS; i++) if (g_cl[i].kind == SESSION && g_cl[i].fd == SESSION_FD && !strcmp(g_cl[i].id, id)) return &g_cl[i];
    client *s = NULL;
    for (int i = 0; i < MAX_CLIENTS && !s; i++) if (!used(&g_cl[i])) s = &g_cl[i];
    if (!s) for (int i = 0; i < MAX_CLIENTS; i++) if (&g_cl[i] != conn && g_cl[i].player < 0 && (!s || g_cl[i].seen_ns < s->seen_ns)) s = &g_cl[i];   // all taken: the oldest without a player
    if (!s) return NULL;
    if (used(s)) drop(s);
    memset(s, 0, sizeof *s);
    s->fd = SESSION_FD; s->kind = SESSION; s->player = -1; s->hp = -1; s->ip = conn->ip; s->open_ns = s->seen_ns = now_ns();
    snprintf(s->id, sizeof s->id, "%s", id);
    return s;
}
static void post(client *conn, const char *id, const uint8_t *body, size_t len) {
    client *s = session_for(conn, id);
    if (s) {
        s->seen_ns = now_ns();
        for (size_t off = 0; off + 3 <= len;) {
            int kind = body[off]; size_t n = (size_t)body[off + 1] | (size_t)body[off + 2] << 8;
            if (off + 3 + n > len) break;
            const uint8_t *d = body + off + 3;
            if (kind == 1) { char j[256]; size_t k = n < sizeof j - 1 ? n : sizeof j - 1; memcpy(j, d, k); j[k] = 0; on_text(s, j); }
            else if (kind == 2) on_binary(s, d, n);
            off += 3 + n;
            if (!used(s) || s->kind != SESSION) { s = NULL; break; }   // replaced by a later hello in the same body: nothing more for it
        }
        if (s) rumble_due(s, now_ns());
    }
    char h[192]; size_t on = s ? s->on : 0;
    int hn = snprintf(h, sizeof h, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nCache-Control: no-store\r\nContent-Length: %zu\r\n\r\n", on);
    uint8_t r[sizeof h + OUT_CAP]; memcpy(r, h, (size_t)hn); if (on) memcpy(r + hn, s->out, on);
    send_all(conn, r, (size_t)hn + on);   // one write: one TLS record
    if (s) s->on = 0;
}
static int http(client *c) {   // 1: keep the connection (a WebSocket, or kept alive for the next POST), 0: done or bad request, close it
    char *req = (char *)c->in, *end = strstr(req, "\r\n\r\n");
    if (!end) return c->n < IN_CAP - 1;
    size_t head = (size_t)(end - req) + 4;
    char method[8] = "", path[160] = "";
    if (sscanf(req, "%7s %159s", method, path) != 2) return 0;
    if (!strcmp(method, "POST") && !strncmp(path, "/p?", 3)) {
        char *cl = strcasestr(req, "\r\nContent-Length:"); size_t len = cl && cl < end ? (size_t)strtoul(cl + 17, NULL, 10) : 0;
        if (head + len > IN_CAP - 1) return 0;
        if (c->n < head + len) return 1;   // the body is still on its way
        char id[64] = ""; const char *q = strstr(path, "id=");
        if (q) { size_t k = 0; q += 3; while (q[k] && q[k] != '&' && k + 1 < sizeof id) { id[k] = q[k]; k++; } id[k] = 0; }
        if (!id[0]) return 0;
        post(c, id, c->in + head, len);
        memmove(c->in, c->in + head + len, c->n - head - len); c->n -= head + len; c->in[c->n] = 0;
        return used(c) ? (c->n ? http(c) : 1) : 0;
    }
    if (strcmp(method, "GET")) return 0;
    if (!strcmp(path, "/ws")) {
        char *k = strcasestr(req, "\r\nSec-WebSocket-Key:"); if (!k) return 0;
        k += 20; while (*k == ' ') k++;
        char key[128]; size_t n = 0; while (k[n] && k[n] != '\r' && n + 1 < 64) { key[n] = k[n]; n++; }
        strcpy(key + n, "258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
        uint8_t d[20]; char acc[32]; sha1((const uint8_t *)key, strlen(key), d); base64(d, 20, acc);
        char resp[256]; int rn = snprintf(resp, sizeof resp, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n", acc);
        send_all(c, resp, (size_t)rn);
        c->kind = WS; c->n = 0;
        return 1;
    }
    if (!strcmp(path, "/") || !strncmp(path, "/?", 2)) {
        char h[160]; int hn = snprintf(h, sizeof h, "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: %zu\r\nConnection: close\r\n\r\n", sizeof phone_pad_page - 1);
        send_all(c, h, (size_t)hn); send_all(c, phone_pad_page, sizeof phone_pad_page - 1);
    } else { static const char nf[] = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"; send_all(c, nf, sizeof nf - 1); }
    return 0;
}
static int ws_frames(client *c) {   // 0: the phone closed the connection or sent something malformed
    size_t off = 0;
    while (c->n - off >= 2) {
        uint8_t *f = c->in + off; int op = f[0] & 15; size_t len = f[1] & 127, p = 2;
        if (!(f[1] & 128)) return 0;   // a browser always masks its frames
        if (len == 126) { if (c->n - off < 4) break; len = (size_t)f[2] << 8 | f[3]; p = 4; }
        else if (len == 127) return 0;  // nothing in this protocol is that long
        if (c->n - off < p + 4 + len) break;
        uint8_t *mask = f + p, *d = f + p + 4;
        for (size_t i = 0; i < len; i++) d[i] ^= mask[i & 3];
        if (op == 8) return 0;
        if (op == 9) { uint8_t pong[2] = {0x8a, 0}; send_all(c, pong, 2); }
        else if (op == 1) { char j[256]; size_t n = len < sizeof j - 1 ? len : sizeof j - 1; memcpy(j, d, n); j[n] = 0; on_text(c, j); }
        else if (op == 2) on_binary(c, d, len);
        if (!used(c)) return 0;
        off += p + 4 + len;
    }
    memmove(c->in, c->in + off, c->n - off); c->n -= off;
    return 1;
}
static int on_readable(client *c) {   // 0: close the connection
    if (!c->tls && c->n == 0 && c->kind == HTTP) {   // a TLS handshake (its first byte, a handshake record) or plain HTTP
        uint8_t b; ssize_t r = recv(c->fd, &b, 1, MSG_PEEK);
        if (r <= 0) return r < 0 && (errno == EAGAIN || errno == EINTR);
        if (b == 0x16 && !(c->tls = pp_tls_new(c->fd))) return 0;   // no HTTPS here
    }
    for (int rounds = 0; rounds < 16; rounds++) {   // TLS may hold decrypted bytes poll() does not see: read until there is nothing
        if (c->n >= IN_CAP - 1) return 0;
        ssize_t r;
        if (c->tls) { long t = pp_tls_recv(c->tls, c->in + c->n, IN_CAP - 1 - c->n); if (t == -2) return 1; r = t; }
        else { r = recv(c->fd, c->in + c->n, IN_CAP - 1 - c->n, 0); if (r < 0 && (errno == EAGAIN || errno == EINTR)) return 1; }
        if (r <= 0) return 0;
        c->n += (size_t)r; c->seen_ns = now_ns(); c->in[c->n] = 0;
        if (!(c->kind == WS ? ws_frames(c) : http(c))) return 0;
        if (!c->tls) return 1;
    }
    return 1;
}

static void *serve(void *arg) {
    int ls = (int)(intptr_t)arg;
#ifdef __APPLE__
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);   // input: not queued behind the game's busy threads when every core is taken
#endif
    for (int i = 0; i < MAX_CLIENTS; i++) { g_cl[i].fd = -1; g_cl[i].player = -1; g_cl[i].hp = -1; }
    int wait_ms = 200;
    for (;;) {
        struct pollfd pf[MAX_CLIENTS + 1]; int map[MAX_CLIENTS + 1], n = 0;
        pf[n] = (struct pollfd){.fd = ls, .events = POLLIN}; map[n++] = -1;
        for (int i = 0; i < MAX_CLIENTS; i++) if (g_cl[i].fd >= 0) { pf[n] = (struct pollfd){.fd = g_cl[i].fd, .events = POLLIN}; map[n++] = i; }
        int r = poll(pf, (nfds_t)n, wait_ms);
        if (r < 0 && errno != EINTR) { LOG("[RED] phone pads: poll failed (errno %d), phones can no longer play", errno); return NULL; }
        for (int k = 0; r > 0 && k < n; k++) {
            if (!(pf[k].revents & (POLLIN | POLLHUP | POLLERR))) continue;
            if (map[k] < 0) {
                struct sockaddr_in from = {0}; socklen_t fl = sizeof from;
                int fd = accept(ls, (struct sockaddr *)&from, &fl); if (fd < 0) continue;
                int slot = -1; for (int i = 0; i < MAX_CLIENTS; i++) if (!used(&g_cl[i])) { slot = i; break; }
                if (slot < 0) {   // all taken: the oldest connection without a player goes (never a phone that is playing)
                    for (int i = 0; i < MAX_CLIENTS; i++) if (g_cl[i].player < 0 && (slot < 0 || g_cl[i].seen_ns < g_cl[slot].seen_ns)) slot = i;
                    if (slot < 0) { close(fd); continue; }
                    LOG("phone pads: all %d connections taken: closed an idle one (%s) for a new one", MAX_CLIENTS, g_cl[slot].kind != HTTP ? g_cl[slot].name[0] ? g_cl[slot].name : "no hello" : "no request");
                    drop(&g_cl[slot]);
                }
#ifdef SO_NOSIGPIPE
                int one = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
                int nd = 1; setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &nd, sizeof nd);
                fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
                memset(&g_cl[slot], 0, sizeof g_cl[slot]); g_cl[slot].fd = fd; g_cl[slot].player = -1; g_cl[slot].hp = -1;
                g_cl[slot].ip = from.sin_family == AF_INET ? from.sin_addr.s_addr : 0;
                g_cl[slot].open_ns = g_cl[slot].seen_ns = now_ns();
                continue;
            }
            if (g_cl[map[k]].fd == pf[k].fd && !on_readable(&g_cl[map[k]])) drop(&g_cl[map[k]]);   // (the entry may have been dropped and taken again by now)
        }
        for (int i = 0; i < MAX_CLIENTS; i++) if (used(&g_cl[i])) launcher_requests(&g_cl[i]);
        uint64_t t = now_ns();   // a phone that went quiet (screen locked, out of range) leaves nothing pressed
        wait_ms = 200;
        for (int i = 0; i < MAX_CLIENTS; i++) if (used(&g_cl[i]) && rumble_due(&g_cl[i], t)) wait_ms = 10;
        for (int i = 0; i < MAX_CLIENTS; i++) if (used(&g_cl[i]) && g_cl[i].hp >= 0 && g_cl[i].kind == WS && wait_ms > 30) wait_ms = 30;   // the game's rumble is looked at this often
        for (int i = 0; i < MAX_CLIENTS; i++) if (used(&g_cl[i]) && g_cl[i].kept) {   // taps held for the game (MIN_HOLD_NS) let go when their time is up
            hold_expire(&g_cl[i], g_cl[i].player < 0 ? -1 : shell_slot_of(&g_cl[i]), t);
            if (g_cl[i].kept) { int ms = (int)((g_cl[i].hold_until - t) / 1000000) + 1; if (ms < wait_ms) wait_ms = ms; }
        }
        for (int i = 0; i < MAX_CLIENTS; i++) if (used(&g_cl[i]) && g_cl[i].player >= 0 && t - g_cl[i].last_ns > SILENT_NS) release(&g_cl[i]);
        for (int i = 0; i < MAX_CLIENTS; i++) if (used(&g_cl[i]) && g_cl[i].player >= 0 && t - (g_cl[i].kind == SESSION ? g_cl[i].seen_ns : g_cl[i].last_ns) > GONE_NS) {
            LOG("phone pads: '%s' silent for %llu s: its page is gone", g_cl[i].name, GONE_NS / 1000000000ull);
            drop(&g_cl[i]);   // the phone gets the player back if it comes back while it is free (its id stays on the slot)
        }
        for (int i = 0; i < MAX_CLIENTS; i++) if (used(&g_cl[i]) && g_cl[i].player < 0 && t - g_cl[i].seen_ns > (g_cl[i].kind == HTTP ? REQ_NS : GONE_NS))
            drop(&g_cl[i]);   // no player: a request that never came (or no next one on a kept connection), or a 'full' / removed page that went silent
    }
}

// The address phones open, as the launcher shows it (Launcher.swift phonePadsURL): this device's IPv4 address on Wi-Fi (en0), or on another interface that is up
// (a personal hotspot's bridge) when there is no Wi-Fi. 0 while the server is not running or there is no address. For the in-game QR code card (DmGamepad.m)
int phone_pads_url(char *out, size_t cap) {
    const char *port = getenv("DM_PHONE_PADS_LIVE"); if (!port) return 0;
    struct ifaddrs *list = NULL; if (getifaddrs(&list) != 0) return 0;
    char best[INET_ADDRSTRLEN] = "", other[INET_ADDRSTRLEN] = "";
    for (struct ifaddrs *i = list; i; i = i->ifa_next) {
        if (!i->ifa_addr || i->ifa_addr->sa_family != AF_INET || !(i->ifa_flags & IFF_UP) || (i->ifa_flags & IFF_LOOPBACK)) continue;
        char a[INET_ADDRSTRLEN]; inet_ntop(AF_INET, &((struct sockaddr_in *)i->ifa_addr)->sin_addr, a, sizeof a);
        if (!strncmp(a, "169.254.", 8)) continue;
        if (!strcmp(i->ifa_name, "en0")) { if (!best[0]) snprintf(best, sizeof best, "%s", a); }
        else if (!other[0] && (!strncmp(i->ifa_name, "bridge", 6) || !strncmp(i->ifa_name, "en", 2))) snprintf(other, sizeof other, "%s", a);
    }
    freeifaddrs(list);
    const char *addr = best[0] ? best : other; if (!addr[0]) return 0;
    return snprintf(out, cap, "http://%s:%s/", addr, port) < (int)cap;
}

// Called once at app start (main.m), after the env files are read
void phone_pads_start(void) {
    const char *on = getenv("DM_PHONE_PADS");
    if (on && !strcmp(on, "0")) { LOG("phone pads: off (DM_PHONE_PADS=0)"); return; }
    const char *ps = getenv("DM_PHONE_PADS_PORT"); int port = ps ? atoi(ps) : 8080;
    if (port <= 0 || port > 65535) port = 8080;
    signal(SIGPIPE, SIG_IGN);
    shell_slots_handlers(SHELL_SLOT_PHONE, on_moved, on_kick, on_layout);
    shell_slots_identify_handler(SHELL_SLOT_PHONE, on_identify);
    int ls = socket(AF_INET, SOCK_STREAM, 0), one = 1;
    if (ls < 0) { LOG("[RED] phone pads: no socket (errno %d)", errno); return; }
    setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons((uint16_t)port), .sin_addr.s_addr = htonl(INADDR_ANY)};
    if (bind(ls, (struct sockaddr *)&a, sizeof a) < 0 || listen(ls, 16) < 0) { LOG("[RED] phone pads: port %d is not available (errno %d)", port, errno); close(ls); return; }
    char pv[8]; snprintf(pv, sizeof pv, "%d", port); setenv("DM_PHONE_PADS_LIVE", pv, 1);   // the launcher shows the address and its QR code while this is set (Launcher.swift)
#ifdef __APPLE__
    static DNSServiceRef sd;
    DNSServiceErrorType e = DNSServiceRegister(&sd, 0, 0, NULL, "_nxpad._tcp", NULL, NULL, htons((uint16_t)port), 0, NULL, NULL, NULL);
    if (e) LOG("phone pads: Bonjour announcement failed (%d); phones can still use the address", (int)e);
#endif
    pthread_t th; pthread_create(&th, NULL, serve, (void *)(intptr_t)ls); pthread_detach(th);
    LOG("phone pads: open http://<this device's Wi-Fi address>:%d/ on a phone (the launcher shows the address and a QR code)", port);
}

// Phone controllers: phones on the same Wi-Fi open http://<iPad address>:8080/ in their browser and play as controllers, no app installed. Each phone is a player of its own,
// from the app's one player-slot table (shell_slots.h), which the physical controllers (DmGamepad.m) take theirs from too, so a phone and a controller never share a player and
// dm_pad_players is set from one mask: a phone gets player 1 while no controller holds it (together with the touch gamepad, which stays player 1's), else the next free one,
// up to 8. A phone that reloads its page or reconnects gets its player back while it is free, keyed on the id its page keeps in localStorage.
// The launcher may swap a phone's player with another or remove the phone (shell_slots.h): a removed phone is told so (kicked) and stays out, even across reconnects, until
// its page asks to join again or the app restarts.
// One port serves the page (GET /, phone_pad_page.h, generated from phone_pad.html) and the controller stream (GET /ws, WebSocket). Protocol, all from the phone:
//   text   {"t":"hello","v":1,"id":"<device id>","name":"<label>"[,"join":1]}  -> answered {"t":"assign","player":<1..8>,"layout":"switch"|"xbox"}, {"t":"full"} or {"t":"kicked"}
//          (join: the player asked to come back after the launcher removed the phone); assign comes again whenever the launcher moves the phone to another player or changes its button layout
//   binary 8 bytes: 0x01, sequence (u8, wraps), buttons (u16 LE, NpadButton bits as dm_input.h), lx, ly, rx, ry (i8 each, -127..127, y up)
// The phone sends on every change and at least every 100 ms; a phone silent for a second has everything released. One thread, poll(), plain BSD sockets.
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
#include <time.h>
#include <unistd.h>
#include "dm.h"
#include "dm_input.h"
#include "phone_pad_page.h"
#include "shell_slots.h"
#ifdef __APPLE__
#include <dns_sd.h>
#endif

enum { MAX_CLIENTS = 24, IN_CAP = 4096, SILENT_NS = 1000000000 };
typedef struct {
    int fd, ws, player;          // ws: the connection has switched to WebSocket; player: slot index, -1 before the hello
    size_t n; uint8_t in[IN_CAP];
    int last_seq; uint64_t last_ns; int released;
    char name[64], id[64];       // id: the phone's own (its page's localStorage), the slot table's name for it
    _Atomic int moved, kicked, relayout;   // set by the launcher (shell_slots.h handlers, main thread), handled on the server thread
} client;
static client g_cl[MAX_CLIENTS];   // a client's address is its owner in the slot table; only the server thread touches a client, but for the two flags
static char g_banned[MAX_CLIENTS][64];   // ids of phones the launcher removed: they stay out until they ask to join again


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
static void send_all(int fd, const void *p, size_t n) {
    const uint8_t *b = p;
    while (n) {
        ssize_t w = send(fd, b, n, 0);
        if (w < 0 && errno == EINTR) continue;
        if (w < 0 && errno == EAGAIN) { struct pollfd p = {.fd = fd, .events = POLLOUT}; if (poll(&p, 1, 1000) > 0) continue; return; }   // the page is bigger than the socket buffer
        if (w <= 0) return;
        b += w; n -= (size_t)w;
    }
}
static void ws_text(int fd, const char *s) {
    size_t n = strlen(s); uint8_t h[4] = {0x81, 0}; size_t hn = 2;
    if (n < 126) h[1] = (uint8_t)n; else { h[1] = 126; h[2] = (uint8_t)(n >> 8); h[3] = (uint8_t)n; hn = 4; }
    send_all(fd, h, hn); send_all(fd, s, n);
}

// ---- Players ----
static void send_assign(client *c, int p);
static void release(client *c) { int p = shell_slot_of(c); if (p >= 0 && !c->released) { dm_pad_set_player(p, 0, 0, 0, 0, 0); c->released = 1; } }
static void drop(client *c) {
    if (c->player >= 0) {
        release(c);
        int p = shell_slot_free(c);
        LOG("phone pads: '%s' disconnected: player %d is free (the phone gets it back when it reconnects)", c->name, p + 1);
    }
    close(c->fd);
    memset(c, 0, sizeof *c); c->fd = -1; c->player = -1;
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
    if (banned(id, strstr(json, "\"join\"") != NULL)) { ws_text(c->fd, "{\"t\":\"kicked\"}"); return; }
    if (c->player >= 0) { release(c); shell_slot_free(c); c->player = -1; }
    // The same phone still connected on an older socket (a page that reloaded before the old connection timed out): close that one, so this one takes its player
    for (int i = 0; i < MAX_CLIENTS; i++) if (&g_cl[i] != c && g_cl[i].fd >= 0 && g_cl[i].player >= 0 && !strcmp(g_cl[i].id, id)) drop(&g_cl[i]);
    int p = shell_slot_take(c, id, SHELL_SLOT_PHONE, name);   // a phone that held a player before has its id on that slot and gets it back while it is free
    snprintf(c->name, sizeof c->name, "%s", name); snprintf(c->id, sizeof c->id, "%s", id);
    if (p < 0) { ws_text(c->fd, "{\"t\":\"full\"}"); LOG("phone pads: '%s' connected: all %d players are taken, not used", name, DM_PLAYERS); return; }
    c->player = p; c->last_seq = -1; c->last_ns = now_ns(); c->released = 1;
    send_assign(c, p);
    LOG("phone pads: '%s' connected: player %d", name, p + 1);
}
static void on_state(client *c, const uint8_t *b, size_t n) {
    int p = c->player < 0 ? -1 : shell_slot_of(c);   // the table's, not c->player: the launcher may have just moved the phone
    if (p < 0 || n < 8 || b[0] != 1) return;
    int seq = b[1];
    if (c->last_seq >= 0 && ((seq - c->last_seq) & 255) > 128) return;   // older than the last one taken: arrived out of order
    c->last_seq = seq; c->last_ns = now_ns(); c->released = 0;
    uint64_t btn = (uint64_t)(b[2] | b[3] << 8);
    int32_t ax[4]; for (int i = 0; i < 4; i++) ax[i] = (int8_t)b[4 + i] * (DM_STICK_MAX / 127);
    dm_pad_set_player(p, btn, ax[0], ax[1], ax[2], ax[3]);
    shell_slot_input(p, btn);
}

// ---- The launcher's moves and removals (shell_slots.h handlers): called on the main thread, carried out by the server thread ----
static client *client_of(const void *owner) { const client *c = owner; return c >= g_cl && c < g_cl + MAX_CLIENTS ? (client *)c : NULL; }
static void on_moved(const void *owner, int from, int to) { (void)from; (void)to; client *c = client_of(owner); if (c) atomic_store(&c->moved, 1); }
static void on_kick(const void *owner) { client *c = client_of(owner); if (c) atomic_store(&c->kicked, 1); }
static void on_layout(const void *owner, int xbox) { (void)xbox; client *c = client_of(owner); if (c) atomic_store(&c->relayout, 1); }
static void send_assign(client *c, int p) {   // the player and the button layout the page shows
    char msg[64]; snprintf(msg, sizeof msg, "{\"t\":\"assign\",\"player\":%d,\"layout\":\"%s\"}", p + 1, shell_slot_layout(c) ? "xbox" : "switch"); ws_text(c->fd, msg);
}
static void launcher_requests(client *c) {
    if (atomic_exchange(&c->kicked, 0) && c->player >= 0) {
        release(c);
        shell_slot_free(c);
        for (int i = 0; i < MAX_CLIENTS; i++) if (!g_banned[i][0]) { snprintf(g_banned[i], sizeof g_banned[i], "%s", c->id); break; }
        LOG("phone pads: '%s' removed in the launcher: player %d is free", c->name, c->player + 1);
        c->player = -1;
        ws_text(c->fd, "{\"t\":\"kicked\"}");
    }
    if (atomic_exchange(&c->moved, 0) && c->player >= 0) {
        int p = shell_slot_of(c); if (p < 0) return;
        LOG("phone pads: '%s' moved in the launcher: player %d -> %d", c->name, c->player + 1, p + 1);
        c->player = p; c->released = 0;   // its next packet (at most 100 ms away) feeds the new player
        send_assign(c, p);
    }
    if (atomic_exchange(&c->relayout, 0) && c->player >= 0) send_assign(c, c->player);
}

// ---- HTTP and the WebSocket frames ----
static int http(client *c) {   // 1: keep the connection (switched to WebSocket), 0: done or bad request, close it
    c->in[c->n < IN_CAP ? c->n : IN_CAP - 1] = 0;
    char *req = (char *)c->in, path[64] = "";
    if (sscanf(req, "GET %63s", path) != 1) return 0;
    if (!strcmp(path, "/ws")) {
        char *k = strcasestr(req, "\r\nSec-WebSocket-Key:"); if (!k) return 0;
        k += 20; while (*k == ' ') k++;
        char key[128]; size_t n = 0; while (k[n] && k[n] != '\r' && n + 1 < 64) { key[n] = k[n]; n++; }
        strcpy(key + n, "258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
        uint8_t d[20]; char acc[32]; sha1((const uint8_t *)key, strlen(key), d); base64(d, 20, acc);
        char resp[256]; int rn = snprintf(resp, sizeof resp, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n", acc);
        send_all(c->fd, resp, (size_t)rn);
        int one = 1; setsockopt(c->fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
        c->ws = 1; c->n = 0;
        return 1;
    }
    if (!strcmp(path, "/") || !strncmp(path, "/?", 2)) {
        char h[160]; int hn = snprintf(h, sizeof h, "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: %zu\r\nConnection: close\r\n\r\n", sizeof phone_pad_page - 1);
        send_all(c->fd, h, (size_t)hn); send_all(c->fd, phone_pad_page, sizeof phone_pad_page - 1);
    } else { static const char nf[] = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"; send_all(c->fd, nf, sizeof nf - 1); }
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
        if (op == 9) { uint8_t pong[2] = {0x8a, 0}; send_all(c->fd, pong, 2); }
        else if (op == 1) { char j[256]; size_t n = len < sizeof j - 1 ? len : sizeof j - 1; memcpy(j, d, n); j[n] = 0; on_hello(c, j); }
        else if (op == 2) on_state(c, d, len);
        off += p + 4 + len;
    }
    memmove(c->in, c->in + off, c->n - off); c->n -= off;
    return 1;
}
static int on_readable(client *c) {   // 0: close the connection
    if (c->n >= IN_CAP) return 0;
    ssize_t r = recv(c->fd, c->in + c->n, IN_CAP - 1 - c->n, 0);
    if (r <= 0) return r < 0 && (errno == EAGAIN || errno == EINTR);
    c->n += (size_t)r;
    if (c->ws) return ws_frames(c);
    c->in[c->n] = 0;
    if (!strstr((char *)c->in, "\r\n\r\n")) return c->n < IN_CAP - 1;
    return http(c);
}

static void *serve(void *arg) {
    int ls = (int)(intptr_t)arg;
    for (int i = 0; i < MAX_CLIENTS; i++) { g_cl[i].fd = -1; g_cl[i].player = -1; }
    for (;;) {
        struct pollfd pf[MAX_CLIENTS + 1]; int map[MAX_CLIENTS + 1], n = 0;
        pf[n] = (struct pollfd){.fd = ls, .events = POLLIN}; map[n++] = -1;
        for (int i = 0; i < MAX_CLIENTS; i++) if (g_cl[i].fd >= 0) { pf[n] = (struct pollfd){.fd = g_cl[i].fd, .events = POLLIN}; map[n++] = i; }
        int r = poll(pf, (nfds_t)n, 200);
        if (r < 0 && errno != EINTR) { LOG("[RED] phone pads: poll failed (errno %d), phones can no longer play", errno); return NULL; }
        for (int k = 0; r > 0 && k < n; k++) {
            if (!(pf[k].revents & (POLLIN | POLLHUP | POLLERR))) continue;
            if (map[k] < 0) {
                int fd = accept(ls, NULL, NULL); if (fd < 0) continue;
                int slot = -1; for (int i = 0; i < MAX_CLIENTS; i++) if (g_cl[i].fd < 0) { slot = i; break; }
                if (slot < 0) { close(fd); continue; }
#ifdef SO_NOSIGPIPE
                int one = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
                fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
                memset(&g_cl[slot], 0, sizeof g_cl[slot]); g_cl[slot].fd = fd; g_cl[slot].player = -1;
                continue;
            }
            if (!on_readable(&g_cl[map[k]])) drop(&g_cl[map[k]]);
        }
        for (int i = 0; i < MAX_CLIENTS; i++) if (g_cl[i].fd >= 0) launcher_requests(&g_cl[i]);
        uint64_t t = now_ns();   // a phone that went quiet (screen locked, out of range) leaves nothing pressed
        for (int i = 0; i < MAX_CLIENTS; i++) if (g_cl[i].fd >= 0 && g_cl[i].player >= 0 && t - g_cl[i].last_ns > SILENT_NS) release(&g_cl[i]);
    }
}

// Called once at app start (main.m), after the env files are read
void phone_pads_start(void) {
    const char *on = getenv("DM_PHONE_PADS");
    if (on && !strcmp(on, "0")) { LOG("phone pads: off (DM_PHONE_PADS=0)"); return; }
    const char *ps = getenv("DM_PHONE_PADS_PORT"); int port = ps ? atoi(ps) : 8080;
    if (port <= 0 || port > 65535) port = 8080;
    signal(SIGPIPE, SIG_IGN);
    shell_slots_handlers(SHELL_SLOT_PHONE, on_moved, on_kick, on_layout);
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

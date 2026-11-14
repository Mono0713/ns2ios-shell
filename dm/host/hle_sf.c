// Services whose client a game links into its own main (nn::sf::hipc): Animal Crossing: New Horizons 3.0.3 carries the clients of olsc:u (cloud save data backup settings,
// main+0x404bc6c) and npns (push notifications). The SDK's client code connects through sm (an abort in sm::Initialize under InitializeHipcServiceResolution, from main+0x5b8198) and talks
// HIPC through svcSendSyncRequest; the host has neither. It hands out sessions of its own instead and answers each request in the message buffer, for the services listed in sf_served:
// success, the output data zeroed, no objects or handles. For olsc that reads as "backup off for every user", so the game leaves the settings alone (main+0x2809c8c asks per user and
// switches backup off where it is on).
// Every other service gets the same answer (a red line names it, once): before, any other name was refused as sm refuses a service nobody registered, and the SDK aborted
// on the refusal (SUPER BOMBERMAN R 2: friend:u, Result 0xe15). DM_SF_STRICT=1 refuses them again, for comparing.
// The same server answers the kernel-level route (sf_svc below): an SDK call the host does not take over connects to the sm: port (svcConnectToNamedPort), asks sm for the
// service (CMIF or, from SDK 12, TIPC) and sends its requests with svcSendSyncRequest on the thread's message buffer. Those SVCs used to be placeholders that left the request
// in the buffer, which the SDK read back as a broken reply and aborted (nn::diag under sm::Initialize, the most common first crash of a new game). Now sm hands out a host
// session for every name and every request is answered as above, so an SDK feature the host knows nothing about reads as present and empty instead of ending the game.
// The SDK's own client functions are taken over where they reach the kernel (their calls inside sdk go through its PLT): the session manager's CreateNewSession runs natively on
// DuplicateSession, and ConvertToDomainImpl on QueryPointerBufferSize and ConvertSessionToDomain. DM_SF_TRACE=1 dumps every request.
// Message layout (Atmosphère / libnx): HIPC header {u16 type, counts of X / A / B / W descriptors; u32 data words, receive list, special header flag}, the special header and descriptors,
// then the data words, whose CMIF part starts 16-byte aligned to the buffer: in a domain session the domain header {u8 type, u8 objects, u16 size, u32 object, u32, u32 token} first,
// then {"SFCI", version, command, token} and the arguments. The response is the same with {u32 objects, 3 × u32} and {"SFCO", version, result, token}
#include "hle.h"
#include <pthread.h>

#define SF_H0 0xd0000u   // session handles: outside the kernel handle table (0x1000 + slot, 4096 slots, hle_thread.c)
#define SF_MAX 256
static struct { char name[16]; int used, domain; unsigned seen; } g_sf[SF_MAX];
static pthread_mutex_t g_sf_mu = PTHREAD_MUTEX_INITIALIZER;
static const char *const sf_served[] = {"olsc:u"};   // answered with zeros by design (see above): no red line

static int sf_slot(uint32_t h) {
    unsigned i = h - SF_H0;
    return i < SF_MAX && g_sf[i].used ? (int)i : -1;
}
static uint32_t sf_new(const char *name, int domain) {
    pthread_mutex_lock(&g_sf_mu);
    unsigned i = 0; while (i < SF_MAX && g_sf[i].used) i++;
    if (i == SF_MAX) {   // full (a game that opens sessions and never closes them): share a session of the same service, else the last one
        for (i = 0; i < SF_MAX - 1 && strncmp(g_sf[i].name, name, sizeof g_sf[i].name); i++) {}
        pthread_mutex_unlock(&g_sf_mu);
        return SF_H0 + i;
    }
    strlcpy(g_sf[i].name, name, sizeof g_sf[i].name); g_sf[i].used = 1; g_sf[i].domain = domain; g_sf[i].seen = 0;
    pthread_mutex_unlock(&g_sf_mu);
    return SF_H0 + i;
}
static int sf_strict(void) { static int v = -1; if (v < 0) { const char *e = getenv("DM_SF_STRICT"); v = e && atoi(e) != 0; } return v; }
// A service the host has no implementation of: named once in the log, so a game that misbehaves after it can be traced to it
static void sf_note_unserved(const char *name) {
    for (size_t k = 0; k < sizeof sf_served / sizeof *sf_served; k++) if (!strncmp(name, sf_served[k], 8)) return;
    static char seen[64][9]; static unsigned n; static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&mu);
    int first = 1; for (unsigned k = 0; k < n && first; k++) if (!strncmp(seen[k], name, 8)) first = 0;
    if (first && n < 64) strlcpy(seen[n++], name, sizeof seen[0]);
    pthread_mutex_unlock(&mu);
    if (first) LOG("[RED] sf: the game opens service %.8s, which the host does not implement: every request on it succeeds with zeroed output (a stand-in so the game goes on)", name);
}

// Answer one HIPC message in place (CMIF, CMIF in a domain, control requests, TIPC): success, the output zeroed. The reply has no descriptors; a move handle when the
// request asks for a new session (sm's GetServiceHandle, the control requests that clone one), whose name is new_name (NULL = the same service)
// Message layout (Atmosphère / libnx): HIPC header {u16 type, counts of X / A / B / W descriptors; u32 data words, receive list, special header flag}, the special header and descriptors,
// then the data words, whose CMIF part starts 16-byte aligned to the buffer: in a domain session the domain header {u8 type, u8 objects, u16 size, u32 object, u32, u32 token} first,
// then {"SFCI", version, command, token} and the arguments. The response is the same with {u32 objects, 3 × u32} and {"SFCO", version, result, token}. TIPC (sm from SDK 12):
// type 16 + command, the arguments right after the headers; the reply's first data word is the result
static Result sf_answer(int slot, uint32_t *m, uint64_t size, int is_sm) {
    const char *name = g_sf[slot].name;
    uint8_t *base = (uint8_t *)m;
    if (size < 0x40) return 0xe401u;
    unsigned type = m[0] & 0xffff, nx = m[0] >> 16 & 15, nabw = (m[0] >> 20 & 15) + (m[0] >> 24 & 15) + (m[0] >> 28 & 15), ndw = m[1] & 0x3ff;
    uint32_t *p = m + 2;
    if (m[1] >> 31) { uint32_t sh = *p++; p += (sh & 1 ? 2 : 0) + (sh >> 1 & 15) + (sh >> 5 & 15); }   // special header: process ID, copy and move handles
    p += nx * 2 + nabw * 3;
    size_t data = (size_t)((uint8_t *)p - base), cm = (data + 15) & ~(size_t)15;
    if (data + ndw * 4 > size) { LOG("[RED] sf: %s: request of %u data words does not fit %llu bytes", name, ndw, (unsigned long long)size); return 0xe401u; }
    static int trace = -1; if (trace < 0) trace = getenv("DM_SF_TRACE") && atoi(getenv("DM_SF_TRACE"));
    if (trace) { char hx[3 * 0x80 + 1] = ""; for (unsigned k = 0; k < 0x80 && k < size; k++) snprintf(hx + 3 * k, 4, "%02x ", base[k]); LOG("sf: %s request: %s", name, hx); }
    if (type == 2 || type == 15) return RES_OK;   // CMIF / TIPC close: the session is gone, nothing to answer
    int tipc = type >= 16, ctrl = type == 5 || type == 7;
    if (!tipc && !ctrl && type != 4 && type != 6) { LOG("[RED] sf: %s: HIPC message type %u not served", name, type); return 0xe401u; }
    unsigned cmd, obj = 0, ver = 0; int dom = 0; const uint8_t *in = NULL;
    if (tipc) { cmd = type - 16; in = (const uint8_t *)p; }
    else {
        // a domain request carries its domain header before SFCI: told from the message itself, so a session needs no state for it (sm hands out one session per name)
        if (cm + 16 > size) return 0xe401u;
        // (a domain close carries no SFCI at all: its domain header's type is 2)
        if (*(uint32_t *)(base + cm) != 0x49434653 && cm + 32 <= size && (type == 4 || type == 6) &&
            (*(uint32_t *)(base + cm + 16) == 0x49434653 || base[cm] == 2)) {
            dom = 1; obj = *(uint32_t *)(base + cm + 4);
            if (base[cm] == 2) { memset(base, 0, 16); return RES_OK; }   // a domain object closed
        }
        size_t hin = cm + (dom ? 16 : 0);
        if (*(uint32_t *)(base + hin) != 0x49434653) { LOG("[RED] sf: %s: request without SFCI (%#x)", name, *(uint32_t *)(base + hin)); return 0xe401u; }
        ver = *(uint32_t *)(base + hin + 4); cmd = *(uint32_t *)(base + hin + 8); in = base + hin + 16;
    }
    // A new session to hand back: sm's GetServiceHandle (CMIF 1, TIPC 1; the name is the first argument, 8 bytes), the control requests CopyFromCurrentDomain (1),
    // CloneCurrentObject (2) and CloneCurrentObjectEx (4)
    uint32_t move = 0; char svc[9] = "";
    if (is_sm && cmd == 1 && !ctrl) {
        memcpy(svc, in, 8); svc[8] = 0;
        if (!svc[0]) return 0xc15u;   // sm ResultInvalidServiceName
        if (sf_strict()) { LOG("[RED] sf: the SDK asks sm for service %.8s, which the host does not implement (refused: DM_SF_STRICT)", svc); return 0xe15u; }
        sf_note_unserved(svc);
        move = sf_new(svc, 0);
    } else if (ctrl && (cmd == 1 || cmd == 2 || cmd == 4)) move = sf_new(name, 0);
    // log each object / command once (the last one seen per session)
    unsigned key = (obj & 0xff) << 16 | (ctrl ? 0x8000 : 0) | (cmd & 0x7fff);
    pthread_mutex_lock(&g_sf_mu); int first = g_sf[slot].seen != key; g_sf[slot].seen = key; pthread_mutex_unlock(&g_sf_mu);
    if ((first && !is_sm) || trace) LOG("sf: %s %s%u command %u (%u data words in): success, zeroed output", name, ctrl ? "control " : tipc ? "tipc " : "object ", ctrl || tipc ? 0 : obj, cmd, ndw);
    // The reply: the header, the special header with the move handle when there is one, then the data words; everything up to the buffer's end reads as zero
    size_t end = size < 0x1000 ? size : 0x1000;
    memset(base, 0, end);
    size_t o = 8;
    if (move) { m[1] |= 1u << 31; m[2] = 1u << 5; m[3] = move; o = 16; }   // special header: one move handle
    if (tipc) { /* the result word is the first data word: already 0 */ }
    else {
        o = (o + 15) & ~(size_t)15;
        if (dom) o += 16;   // domain reply header: no out objects
        uint32_t *h = (uint32_t *)(base + o); h[0] = 0x4f434653; h[1] = ver; h[2] = RES_OK; h[3] = 0;   // "SFCO"
        if (ctrl && cmd == 0) h[4] = 1;   // ConvertCurrentObjectToDomain: the session's object is 1
    }
    size_t d0 = move ? 16 : 8;
    m[1] |= (uint32_t)((end - d0) / 4 < 0x3ff ? (end - d0) / 4 : 0x3ff);
    if (ctrl && cmd == 0) { pthread_mutex_lock(&g_sf_mu); g_sf[slot].domain = 1; pthread_mutex_unlock(&g_sf_mu); }
    return RES_OK;
}

// The kernel-level route (hle_svc.c, before its placeholders): svcConnectToNamedPort "sm:" → a host session of sm; svcSendSyncRequest (the thread's message buffer, the first
// 0x100 bytes of its ThreadLocalRegion) and svcSendSyncRequestWithUserBuffer on any host session → answered above. Returns 1 when it handled the SVC.
// Only the sm: port is answered: another named port (a debug or kernel port) stays the placeholder it was
int sf_svc(int num, uint64_t *regs) {
    if (sf_strict()) return 0;
    switch (num) {
    case 0x1F: {   // ConnectToNamedPort(w1 → handle, x1 name)
        const char *nm = (const char *)regs[1];
        if (!nm || strncmp(nm, "sm:", 4)) return 0;
        static uint32_t sm; if (!sm) sm = sf_new("sm:", 0);
        regs[0] = 0; regs[1] = sm; return 1;
    }
    case 0x21: case 0x22: {   // SendSyncRequest(w0 session) / SendSyncRequestWithUserBuffer(x0 buffer, x1 size, w2 session)
        uint32_t h = (uint32_t)(num == 0x21 ? regs[0] : regs[2]);
        int i = sf_slot(h);
        if (i < 0) {   // a handle the host never gave out (a reply the SDK read wrongly): answered as a session of no known service rather than failing
            static uint32_t unknown; if (!unknown) { unknown = sf_new("?", 0); LOG("[RED] sf: SendSyncRequest on %#x, not a host session: answered as an unknown service", h); }
            i = sf_slot(unknown);
        }
        uint32_t *m = num == 0x21 ? pthread_getspecific(g_keytlr) : (uint32_t *)regs[0];
        uint64_t size = num == 0x21 ? 0x100 : regs[1];
        if (!m) return 0;
        regs[0] = sf_answer(i, m, size, !strcmp(g_sf[i].name, "sm:"));
        return 1;
    }
    }
    return 0;
}

HLE_FORCE("_ZN2nn2sf4hipc31InitializeHipcServiceResolutionEv", "service name resolution (connects to sm); the host resolves the names it serves itself", Result, h_sf_InitRes, void) { return RES_OK; }
HLE_FORCE("_ZN2nn2sf4hipc29FinalizeHipcServiceResolutionEv", "service name resolution (sm)", void, h_sf_FinRes, void) {}
HLE_FORCE("_ZN2nn2sf4hipc20ConnectToHipcServiceEPNS_3svc6HandleEPKc", "connect to a service through sm → a host session (every service; see the top of this file)", Result, h_sf_Connect,
          uint32_t *out, const char *name) {
    if (sf_strict()) { LOG("[RED] sf: the game connects to service %.8s itself, which the host does not serve (refused: DM_SF_STRICT)", name); return 0xe15u; }   // sm ResultNotRegistered
    char nm[9]; strlcpy(nm, name, sizeof nm);
    sf_note_unserved(nm);
    *out = sf_new(nm, 0); LOG("sf: %s → host session %#x (every request succeeds with zeroed output)", nm, *out);
    return RES_OK;
}
HLE_FORCE("_ZN2nn2sf4hipc24CloseClientSessionHandleENS_3svc6HandleE", "close a session (kernel handle) → the host session", void, h_sf_Close, uint32_t h) {
    int i = sf_slot(h);
    if (i < 0) { LOG("[RED] sf: CloseClientSessionHandle on %#x, not a host session", h); return; }
    pthread_mutex_lock(&g_sf_mu); g_sf[i].used = 0; pthread_mutex_unlock(&g_sf_mu);
}
// Control requests: the pointer buffer is the server's receive buffer for X descriptors (none: the host reads them in place), the domain conversion makes the session's object 1, a duplicate
// is a new session to the same object
HLE_FORCE("_ZN2nn2sf4hipc6client22QueryPointerBufferSizeEPtNS_3svc6HandleE", "control request: pointer buffer size of a session → 0 for a host session", Result, h_sf_PtrBuf, uint16_t *out, uint32_t h) {
    if (sf_slot(h) < 0) { LOG("[RED] sf: QueryPointerBufferSize on %#x, not a host session", h); return RES_FAIL; }
    *out = 0; return RES_OK;
}
HLE_FORCE("_ZN2nn2sf4hipc6client22ConvertSessionToDomainEPNS0_4cmif18CmifDomainObjectIdENS_3svc6HandleE", "control request: convert a session to a domain → the host session's object 1", Result, h_sf_ToDomain,
          uint32_t *out, uint32_t h) {
    int i = sf_slot(h);
    if (i < 0) { LOG("[RED] sf: ConvertSessionToDomain on %#x, not a host session", h); return RES_FAIL; }
    g_sf[i].domain = 1; *out = 1; return RES_OK;
}
HLE_FORCE("_ZN2nn2sf4hipc6client16DuplicateSessionEPNS_3svc6HandleES4_", "control request: clone a session → a new host session to the same service", Result, h_sf_Dup, uint32_t *out, uint32_t h) {
    int i = sf_slot(h);
    if (i < 0) { LOG("[RED] sf: DuplicateSession on %#x, not a host session", h); return RES_FAIL; }
    *out = sf_new(g_sf[i].name, g_sf[i].domain); return RES_OK;
}
HLE_FORCE("_ZN2nn2sf4hipc6client18DuplicateSessionExEPNS_3svc6HandleES4_j", "control request: clone a session (with a tag) → a new host session to the same service", Result, h_sf_DupEx,
          uint32_t *out, uint32_t h, unsigned tag) { (void)tag; return h_sf_Dup(out, h); }

HLE_FORCE("_ZN2nn2sf4hipc15SendSyncRequestENS_3svc6HandleEPvm", "send a request on a session (svcSendSyncRequest) → answered by the host for its sessions", Result, h_sf_Send,
          uint32_t h, uint32_t *m, uint64_t size) {
    int i = sf_slot(h);
    if (i < 0 || size < 0x40) { LOG("[RED] sf: SendSyncRequest on %#x (%llu bytes), not a host session", h, (unsigned long long)size); return 0xe401u; }   // kernel ResultInvalidHandle
    return sf_answer(i, m, size, 0);
}

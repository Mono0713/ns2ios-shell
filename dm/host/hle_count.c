// DM_HLECOUNT=<output file, may contain %d = process id> (Mac diagnostic, for HLE coverage audit): count how many times each HLE is called by the guest and write a TSV "category name count" on exit (including 0 counts).
// Method: at load time, resolve guest references to host implementations (forced takeover / HLE table / libc passthrough / unimplemented stubs) to a counting stub:
//   ldr x16, =&count; movz x17, #1; stadd x17, [x16]; ldr x16, =implementation; br x16
// Touches only x16 / x17, which may be clobbered between calls; arguments and return values pass through unchanged. Stubs are written in a writable page and sealed read-only executable when loading ends (hlecount_seal).
// svc is counted separately by number (the hle_svc.c dispatch entry calls hlecount_svc). Unavailable on iOS (code written at runtime cannot execute).
#include "dm.h"
#include <stdatomic.h>
#include <sys/mman.h>
#include <unistd.h>
#include <libkern/OSCacheControl.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdlib.h>
#if !TARGET_OS_IPHONE
#define HC_MAX 8192
static struct { const char *kind, *name; void *fn; _Atomic uint64_t n; } g_hc[HC_MAX];
static unsigned g_nhc; static uint32_t *g_hcode; static int g_hon = -1, g_hsealed; static const char *g_hpath;
static _Atomic uint64_t g_hsvc[256];
static int hc_on(void) { if (g_hon < 0) { g_hpath = getenv("DM_HLECOUNT"); g_hon = g_hpath != NULL; } return g_hon; }
static void hc_write(void) {
    char pth[1024]; snprintf(pth, sizeof pth, g_hpath, (int)getpid());   // %d in the path is replaced with the process id (parallel runs each write their own copy)
    FILE *f = fopen(pth, "w"); if (!f) { LOG("[RED] DM_HLECOUNT cannot write %s", pth); return; }
    fprintf(f, "kind\tname\tcount\n");
    for (unsigned i = 0; i < g_nhc; i++) fprintf(f, "%s\t%s\t%llu\n", g_hc[i].kind, g_hc[i].name, (unsigned long long)atomic_load(&g_hc[i].n));
    for (int k = 0; k < 256; k++) if (atomic_load(&g_hsvc[k])) fprintf(f, "SVC\t%#x\t%llu\n", k, (unsigned long long)atomic_load(&g_hsvc[k]));
    fclose(f); LOG("DM_HLECOUNT: %u entries → %s", g_nhc, pth);
}
void *hletrace_wrap(const char *kind, const char *name, void *fn);
void *hlecount_wrap(const char *kind, const char *name, void *fn) {
    if (!hc_on()) return hletrace_wrap(kind, name, fn);   // DM_HLETRACE (below) when DM_HLECOUNT is not set
    if (!fn) return fn;
    if (g_hsealed) { static int once; if (!once++) LOG("[RED] DM_HLECOUNT: resolution after the pages were sealed (%s), later entries are not counted", name); return fn; }
    for (unsigned i = 0; i < g_nhc; i++) if (g_hc[i].fn == fn && !strcmp(g_hc[i].name, name)) return g_hcode + 12 * i;   // Same name and same implementation reuse one stub
    if (g_nhc == HC_MAX) die("DM_HLECOUNT more than %d entries", HC_MAX);
    if (!g_hcode) { g_hcode = mmap(NULL, HC_MAX * 48, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0); if (g_hcode == MAP_FAILED) die("DM_HLECOUNT mmap"); atexit(hc_write); }
    unsigned i = g_nhc++; g_hc[i].kind = kind; g_hc[i].name = name; g_hc[i].fn = fn;
    uint32_t *w = g_hcode + 12 * i;                                  // 48 bytes: 5 instructions + 1 empty + two 8-byte literals (offsets 0x18 / 0x20)
    w[0] = 0x58000000 | ((0x18 / 4) << 5) | 16;                      // ldr x16, [pc+0x18]   → &count
    w[1] = 0xD2800031;                                                // movz x17, #1
    w[2] = 0xF8200000 | (17u << 16) | (16u << 5) | 31;               // stadd x17, [x16] (ldadd with destination xzr)
    w[3] = 0x58000000 | (((0x20 - 0xc) / 4) << 5) | 16;              // ldr x16, [pc+0x14]   → implementation
    w[4] = 0xD61F0200;                                                // br x16
    w[5] = 0xD503201F;                                                // nop
    uint64_t a = (uint64_t)&g_hc[i].n, b = (uint64_t)fn; memcpy(w + 6, &a, 8); memcpy(w + 8, &b, 8);
    return w;
}
void hlecount_seal(void) {
    if (!hc_on() || !g_hcode) return;
    if (mprotect(g_hcode, HC_MAX * 48, PROT_READ | PROT_EXEC)) die("DM_HLECOUNT mprotect");
    g_hsealed = 1;
    sys_icache_invalidate(g_hcode, HC_MAX * 48);
    LOG("DM_HLECOUNT: %u counting stubs sealed", g_nhc);
}
void hletrace_svc(int num);
void hlecount_svc(int num) { if (g_hon > 0 && num >= 0 && num < 256) atomic_fetch_add(&g_hsvc[num], 1); hletrace_svc(num); }
void hlecount_flush(void) { if (hc_on() && g_hcode) hc_write(); }   // Also write a copy on the graceful exit path (SIGTERM / scene disconnect)
#else
void *hletrace_wrap(const char *kind, const char *name, void *fn);
void *hlecount_wrap(const char *kind, const char *name, void *fn) { return hletrace_wrap(kind, name, fn); }
void hlecount_seal(void) {}
void hletrace_svc(int num);
void hlecount_svc(int num) { hletrace_svc(num); }
void hlecount_flush(void) {}
#endif

// DM_HLETRACE=<seconds, default 5> (works on iOS too, any game): every few seconds, log which imports (HLE take-overs, libc passthrough, unimplemented stubs) and which svcs
// the guest called in that window, most-called first. For a game that runs but never gets anywhere (Stick Fight: the main loop presents empty frames forever), the calls it
// repeats every frame are what it is waiting on. iOS cannot run code written at run time, so the counting stubs are a pool built into the binary: stub i adds 1 to
// g_tc[i].n and jumps to g_tc[i].fn (only x16 / x17 touched, as DM_HLECOUNT's); resolution hands out the next free one. Off unless set: imports then bind as before
#define TC_MAX 4096
typedef struct { _Atomic uint64_t n; void *fn; } tc_slot;
__attribute__((used)) tc_slot g_tc[TC_MAX];
static const char *g_tc_name[TC_MAX], *g_tc_kind[TC_MAX]; static uint64_t g_tc_prev[TC_MAX]; static _Atomic unsigned g_ntc;
static _Atomic uint64_t g_tsvc[256]; static uint64_t g_tsvc_prev[256];
extern const char dm_tc_stubs[];   // TC_MAX stubs of 8 instructions (32 bytes) each
__asm__(".arch_extension lse\n.text\n.p2align 2\n.globl _dm_tc_stubs\n.private_extern _dm_tc_stubs\n_dm_tc_stubs:\n"
        ".set tci, 0\n.rept 4096\n"
        "    adrp x16, _g_tc@PAGE\n    add x16, x16, _g_tc@PAGEOFF\n"
        "    add x16, x16, #((tci * 16) >> 12), lsl #12\n    add x16, x16, #((tci * 16) & 0xfff)\n"
        "    mov x17, #1\n    stadd x17, [x16]\n    ldr x16, [x16, #8]\n    br x16\n"
        ".set tci, tci + 1\n.endr\n");
static int tc_period(void) { static int p = -2; if (p == -2) { const char *e = getenv("DM_HLETRACE"); p = e ? (atoi(e) > 0 ? atoi(e) : 5) : -1; } return p; }
static void tc_short(const char *name, char *out, size_t n) {   // nn::friends::AsyncContext::HasDone(bool*) → nn::friends::AsyncContext::HasDone
    static char *(*dem)(const char *, char *, size_t *, int *); static int looked;   // libc++abi's, looked up so the host links without it
    if (!looked) { looked = 1; dem = (char *(*)(const char *, char *, size_t *, int *))dlsym(RTLD_DEFAULT, "__cxa_demangle"); }
    int st = -1; char *d = dem ? dem(name, NULL, NULL, &st) : NULL;
    snprintf(out, n, "%s", d && !st ? d : name); free(d);
    char *par = strchr(out, '('); if (par && par != out) *par = 0;
}
static void *tc_main(void *arg) {
    (void)arg; pthread_setname_np("dm hle trace");
    for (int round = 1; round <= 240; round++) {
        sleep((unsigned)tc_period());
        unsigned n = atomic_load(&g_ntc); uint64_t d[TC_MAX]; unsigned idx[TC_MAX], k = 0;
        for (unsigned i = 0; i < n; i++) { uint64_t c = atomic_load(&g_tc[i].n); d[i] = c - g_tc_prev[i]; g_tc_prev[i] = c; if (d[i]) idx[k++] = i; }
        for (unsigned a = 1; a < k; a++) { unsigned v = idx[a], b = a; while (b && d[idx[b - 1]] < d[v]) { idx[b] = idx[b - 1]; b--; } idx[b] = v; }   // most-called first
        char line[6000]; size_t o = 0; line[0] = 0;
        for (unsigned a = 0; a < k && a < 40 && o < sizeof line - 200; a++) {
            char nm[160]; tc_short(g_tc_name[idx[a]], nm, sizeof nm);
            o += (size_t)snprintf(line + o, sizeof line - o, "%s %s%s=%llu", a ? "," : "", strcmp(g_tc_kind[idx[a]], "STUB") ? "" : "STUB ", nm, (unsigned long long)d[idx[a]]);
        }
        LOG("[hletrace] %ds window %d: %u imports called%s", tc_period(), round, k, line);
        o = 0; line[0] = 0;
        for (int s2 = 0; s2 < 256; s2++) { uint64_t c = atomic_load(&g_tsvc[s2]), dd = c - g_tsvc_prev[s2]; g_tsvc_prev[s2] = c; if (dd && o < sizeof line - 40) o += (size_t)snprintf(line + o, sizeof line - o, " %#x=%llu", s2, (unsigned long long)dd); }
        if (o) LOG("[hletrace] %ds window %d svc:%s", tc_period(), round, line);
    }
    return NULL;
}
void *hletrace_wrap(const char *kind, const char *name, void *fn) {
    if (tc_period() < 0 || !fn) return fn;
    unsigned n = atomic_load(&g_ntc);
    for (unsigned i = 0; i < n; i++) if (g_tc[i].fn == fn && !strcmp(g_tc_name[i], name)) return (void *)(dm_tc_stubs + 32 * i);   // same name and implementation: one stub
    if (n == TC_MAX) { static int once; if (!once++) LOG("[RED] DM_HLETRACE: more than %d imports, the rest are not counted", TC_MAX); return fn; }
    g_tc[n].fn = fn; g_tc_name[n] = name; g_tc_kind[n] = kind; atomic_store(&g_ntc, n + 1);
    if (!n) { pthread_t t; pthread_create(&t, NULL, tc_main, NULL); pthread_detach(t); LOG("DM_HLETRACE=%d: the imports and svcs the game calls are logged every %d s", tc_period(), tc_period()); }
    return (void *)(dm_tc_stubs + 32 * n);
}
void hletrace_svc(int num) { if (tc_period() > 0 && num >= 0 && num < 256) atomic_fetch_add(&g_tsvc[num], 1); }

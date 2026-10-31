// Run marker for the iOS launcher's automatic game memory (Launcher.swift, LauncherSettings.swift MemoryAuto). When the player leaves the memory pool at Auto,
// the launcher writes Application Support/launcher/<game>.run before the game starts and opens it here; the host then records in it how the run went, so the
// next launch can tell a run that died for memory from one that died for another reason (a crash in the game's code is no reason to change the pool).
// File: byte 0 the state, byte 1 the memory flag, then lines the launcher wrote (pool=, auto=). States:
//   b running, not yet known to work        g not counted: before the game starts, or in the background (the player left)     w memory pressure (iOS warning, or under 256 MB left)
//   k worked: 40 s of frames (final)        x the game's own abort (svcBreak)                       c a host crash (signal)       h the watchdog's hang exit
// Flag byte: m once the host refused the game memory (SetHeapSize past the heap region or the pool, MapPhysicalMemory past the pool), '-' otherwise.
// The first of x / c / h wins (what followed is a consequence). Written with pwrite on a descriptor opened in advance: safe from a signal handler.
#include "hle.h"
#include <fcntl.h>
#include <unistd.h>
#include <stdatomic.h>

static _Atomic int g_fd = -1;
static _Atomic char g_state;

void dm_run_mark_open(const char *path) {
    int fd = open(path, O_WRONLY | O_CLOEXEC);
    if (fd < 0) { LOG("[RED] run marker %s cannot be opened: the launcher's automatic memory learns nothing from this run", path); return; }
    int old = atomic_exchange(&g_fd, fd); if (old >= 0) close(old);
    atomic_store(&g_state, 'g');   // as the launcher wrote it: running (b) from the game's first memory setup (hle_svc.c mem_init_once)
    LOG("run marker: %s", path);
}

static int allowed(char cur, char c) {
    switch (c) {
    case 'k': return cur == 'b' || cur == 'g' || cur == 'w';
    case 'x': case 'c': case 'h': return cur != 'k' && cur != 'x' && cur != 'c' && cur != 'h';
    case 'w': return cur == 'b';   // not before the game starts (shader preparation) or while in the background
    case 'g': return cur == 'b';
    case 'b': return cur == 'g';
    default: return 0;
    }
}

void dm_run_mark(char c) {
    int fd = atomic_load(&g_fd); if (fd < 0) return;
    char cur = atomic_load(&g_state);
    do { if (!allowed(cur, c)) return; } while (!atomic_compare_exchange_weak(&g_state, &cur, c));
    if (pwrite(fd, &c, 1, 0) != 1) {}
}

void dm_run_mark_memory_refused(void) {
    static _Atomic int once; int fd = atomic_load(&g_fd);
    if (fd < 0 || atomic_load(&g_state) == 'k' || atomic_exchange(&once, 1)) return;
    char m = 'm'; if (pwrite(fd, &m, 1, 1) != 1) {}
}

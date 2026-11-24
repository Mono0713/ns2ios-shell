// nn::vi (display layer): on a real device, the vi service is used to open the display, create a layer and get the native window handle; the handle is passed to NVN's window builder.
// Host: returns host static objects; when hooking up Metal, the native window corresponds to the front end's CAMetalLayer (front_metal_layer()).
#include "../host/hle.h"
#include "nvn/nvn_obj.h"
#include <pthread.h>
#include <stdatomic.h>

static struct { uint32_t magic; } g_display = {0x50534944}, g_layer = {0x5259414c};
static struct { uint32_t magic; void *layer; } g_native = {0x4e49574e, 0};

HLE_FORCE("_ZN2nn2vi10InitializeEv", "display service init; the host has no vi service", void, h_vi_Init, void) {}
HLE_FORCE("_ZN2nn2vi18OpenDefaultDisplayEPPNS0_7DisplayE", "open default display; the host returns a static object", Result, h_vi_OpenDisp, void **out) {
    *out = &g_display; return RES_OK;
}
HLE_FORCE("_ZN2nn2vi11CreateLayerEPPNS0_5LayerEPNS0_7DisplayE", "create layer; the host returns a static object", Result, h_vi_CreateLayer, void **out, void *disp) {
    (void)disp; *out = &g_layer; return RES_OK;
}
// The overload with the layer's size (SDL3's Switch video driver, Absolum: 1920x1080 docked); the SDK's version calls through the vi service object the host never made (SIGSEGV at +0xe4).
// An NVN or Vulkan window's textures decide what is presented; an EGL window surface takes the layer's size (dm/gfx/gl/hle_gl.m: Digimon Story Cyber Sleuth sizes its layer
// itself and draws into the surface at that size)
static _Atomic uint32_t g_layer_wh;   // w | h << 16 of the last sized CreateLayer, 0 = none
void dm_vi_layer_size(int *w, int *h) { uint32_t v = g_layer_wh; *w = (int)(v & 0xffff); *h = (int)(v >> 16); }
HLE_FORCE("_ZN2nn2vi11CreateLayerEPPNS0_5LayerEPNS0_7DisplayEii", "create layer of a given size; the host returns a static object", Result, h_vi_CreateLayerWH, void **out, void *disp, int w, int h) {
    (void)disp; LOG("vi::CreateLayer %dx%d", w, h); *out = &g_layer;
    if (w > 0 && h > 0 && w < 0x10000 && h < 0x10000) g_layer_wh = (uint32_t)w | (uint32_t)h << 16;
    return RES_OK;
}
HLE_FORCE("_ZN2nn2vi15GetNativeWindowEPPvPNS0_5LayerE", "native window handle, passed to the NVN window builder; the host returns a static object", Result, h_vi_GetNative, void **out, void *layer) {
    (void)layer; *out = &g_native; return RES_OK;
}
// Link's Awakening also crops its layer and tears the display down on exit; the SDK's versions dereference the vi service objects the host never made (SetLayerCrop: SIGSEGV at +0x64).
// The crop is kept for the Vulkan present (hle_vk.m): Super Mario Galaxy keeps a 1920x1080 swapchain in handheld mode, draws into its top-left 1280x720 and crops the layer
// to that every frame. NVN games crop through their window instead (nvnWindowSetCrop), so their present does not read it. Logged only when it changes
static _Atomic uint64_t g_crop;   // x | y << 16 | w << 32 | h << 48, 0 = none
void dm_vi_layer_crop(int c[4]) { uint64_t v = g_crop; c[0] = (int)(v & 0xffff); c[1] = (int)(v >> 16 & 0xffff); c[2] = (int)(v >> 32 & 0xffff); c[3] = (int)(v >> 48); }
HLE_FORCE("_ZN2nn2vi12SetLayerCropEPNS0_5LayerEiiii", "layer crop; the host records it and the Vulkan present crops by it", Result, h_vi_SetCrop, void *layer, int x, int y, int w, int h) {
    (void)layer;
    uint64_t v = x < 0 || y < 0 || w <= 0 || h <= 0 || x > 0xffff || y > 0xffff || w > 0xffff || h > 0xffff ? 0 : (uint64_t)x | (uint64_t)y << 16 | (uint64_t)w << 32 | (uint64_t)h << 48;
    if (atomic_exchange(&g_crop, v) != v) LOG("vi::SetLayerCrop %d,%d %dx%d", x, y, w, h);
    return RES_OK;
}
// Super Mario Odyssey sets its layer's scaling mode; the SDK's version uses the vi service objects the host never made
HLE_FORCE("_ZN2nn2vi19SetLayerScalingModeEPNS0_5LayerENS0_11ScalingModeE", "layer scaling mode; the host present does its own scaling", Result, h_vi_SetScaling, void *layer, int mode) {
    (void)layer; LOG("vi::SetLayerScalingMode %d (ignored)", mode); return RES_OK;
}
// Unreal Engine paces its frames by the layer's frame number (Octopath Traveler 0, main+0x10140e8); the SDK's versions read the Android surface of the vi service the host never made
// (SIGSEGV in android::Surface::getQueuedFrameNumber). The host's frame number is the count of frames the game has presented
uint64_t dm_nvn_frame_count(void);
HLE_FORCE("_ZN2nn2vi20GetLatestFrameNumberEPmPKNS0_5LayerE", "the layer's latest frame number: the frames presented so far", Result, h_vi_FrameNo, uint64_t *out, const void *layer) {
    (void)layer; *out = dm_nvn_frame_count(); return RES_OK;
}
// SDK 20.5.15 reads eight 40-byte records, newest first. Unreal's viewport thread uses the
// last presented frame to retire swap-chain fences, including during FlushRenderingCommands.
enum { VI_HISTORY_LENGTH = 8 };
typedef struct { uint64_t frame, ticket, queued_ns, presented_ns; } vi_frame_event;
typedef struct { uint64_t state, frame, queued, presented, latched; } vi_frame_info;
_Static_assert(sizeof(vi_frame_info) == 0x28, "SDK FrameInfo size");
static vi_frame_event g_vi_history[VI_HISTORY_LENGTH];
static pthread_mutex_t g_vi_history_lock = PTHREAD_MUTEX_INITIALIZER;
void dm_vi_frame_queued(uint64_t frame, uint64_t ticket) {
    pthread_mutex_lock(&g_vi_history_lock);
    g_vi_history[frame % VI_HISTORY_LENGTH] = (vi_frame_event){frame, ticket, guest_ns(), 0};
    pthread_mutex_unlock(&g_vi_history_lock);
}

static uint64_t vi_frame_ticks(uint64_t ns) {
    return ns / 625 * 12 + ns % 625 * 12 / 625;   // Horizon's 19.2 MHz guest clock
}

HLE_FORCE("_ZN2nn2vi16ListFrameHistoryEPNS0_9FrameInfoEiPKNS0_5LayerE", "the layer's latest queued and presented frames", int, h_vi_FrameHist, void *out, int n, const void *layer) {
    (void)layer;
    if (!out) return VI_HISTORY_LENGTH;
    if (n <= 0) return 0;
    uint64_t done = mtl_present_done();
    uint64_t newest = dm_nvn_frame_count();
    uint64_t guest_now = guest_ns(), host_now = now_ns();
    uint8_t *records = out;
    int count = 0;
    pthread_mutex_lock(&g_vi_history_lock);
    for (uint64_t frame = newest; frame && newest - frame < VI_HISTORY_LENGTH && count < n; frame--) {
        vi_frame_event *event = &g_vi_history[frame % VI_HISTORY_LENGTH];
        if (event->frame != frame) continue;
        if (!event->presented_ns && event->ticket <= done) {
            // Count a frame once the present queue has retired it, even if the compositor
            // dropped it or there is no drawable. Otherwise the guest can wait forever.
            double time = event->ticket ? mtl_presented_time(event->ticket) : 0;
            uint64_t presented = time > 0 ? (uint64_t)(time * 1e9) : host_now;
            uint64_t elapsed = host_now > presented ? host_now - presented : 0;
            uint64_t seen = guest_now > elapsed ? guest_now - elapsed : 0;
            event->presented_ns = seen > event->queued_ns ? seen : event->queued_ns;
            if (!event->presented_ns) event->presented_ns = 1;
        }
        uint64_t ticks = vi_frame_ticks(event->presented_ns);
        vi_frame_info info = {event->presented_ns ? 2 : 1, frame, vi_frame_ticks(event->queued_ns), ticks, ticks};
        memcpy(records + count++ * sizeof info, &info, sizeof info);
    }
    pthread_mutex_unlock(&g_vi_history_lock);
    return count;
}
// Rhythm Heaven Groove (SDK 21) asks for the built-in panel's identity at start (main+0xa9a4); the SDK's version calls through the vi service object the host never made (SIGSEGV at +0x20).
//   The game reads a u32 kind and, when it is 2 or more, 0x14 more bytes that it hands on; any other answer makes it hand on zeros. The host has no panel: an all-zero identifier, kind 0
HLE_FORCE("_ZN2nn2vi32GetDefaultDisplayPanelIdentifierEPNS0_15PanelIdentifierE", "built-in panel identity; the host has no panel: all zero", Result, h_vi_PanelId, void *out) {
    memset(out, 0, 0x18); return RES_OK;
}
// The Great Ace Attorney Chronicles (SDK 10) lists up to 10 displays before opening the default one (main+0x808f08) and does not read the list. DisplayInfo is 0x60 bytes:
//   name[0x40], bool has a layer limit at +0x40, then u64 layer count limit, largest layer width and height. One display, "Default", as Horizon lists for an application
HLE_FORCE("_ZN2nn2vi12ListDisplaysEPNS0_11DisplayInfoEi", "list displays; the host has one, \"Default\"", int, h_vi_ListDisp, void *out, int n) {
    if (n <= 0 || !out) return 0;
    uint8_t *p = out; memset(p, 0, 0x60); strcpy((char *)p, "Default");
    p[0x40] = 1; uint64_t lim[3] = {1, 1920, 1080}; memcpy(p + 0x48, lim, sizeof lim);
    return 1;
}
HLE_FORCE("_ZN2nn2vi12DestroyLayerEPNS0_5LayerE", "destroy layer; host static object", void, h_vi_DestroyLayer, void *layer) { (void)layer; }
HLE_FORCE("_ZN2nn2vi12CloseDisplayEPNS0_7DisplayE", "close display; host static object", void, h_vi_CloseDisp, void *disp) { (void)disp; }
HLE_FORCE("_ZN2nn2vi8FinalizeEv", "display service shutdown; the host has no vi service", void, h_vi_Fini, void) {}

// Epic Online Services stand-in (All You Need Is Help, Unity IL2CPP). The host never runs the real EOS SDK NRO (hle_ro.c: an online SDK, refused); the C++ games that
// link it (Hades, Hades II) take the failed nn::ro registration as "play offline". Unity's EOS bindings instead resolve every EOS_* entry through the IL2CPP P/Invoke resolver
// (nn::ro::LoadModule of rom:/Plugins/EOSSDK-Switch-Shipping.nro, then LookupModuleSymbol per name). With the module refused the first call throws, libEOS.Platform's
// s_PlatformInterface stays null, and All You Need Is Help's SaveDataManager.Start waits for it forever ("Waiting Platform.IsInitialized", a loading spinner at 60 fps).
// So when a game loads an EOS SDK NRO the host hands it this module instead: every EOS_* name resolves to a stub that answers as an offline console would.
//   EOS_Initialize / Shutdown / Logging / Platform_Set* / ...Set...: success. EOS_Platform_Create and Platform_Get*Interface: a handle (a zeroed host page; the stubs never read it).
//   AddNotify*: a notification id that never fires. Counts, IsValid, login status: 0. EOS_GetVersion / E*_ToString: a string. Everything else: EOS_NotFound.
//   Requests that complete through a callback (handle, options, client data, callback): the callback runs on the next EOS_Platform_Tick with EOS_NoConnection and the client data.
// Nothing is sent anywhere: the host has no EOS SDK and no Epic login.
// Each name gets one of a pool of compile-time trampolines (iOS allows no code generation at run time) that loads its number into x16 and enters eos_dispatch.
#include "hle.h"
#include <pthread.h>

#define EOS_STUBS 1024
#define EOS_Success 0
#define EOS_NoConnection 1
#define EOS_InvalidParameters 10
#define EOS_NotFound 18

// x16 = stub number; x0-x7 saved to a frame, eos_dispatch(args, n) returns x0
__asm__(
    ".text\n"
    ".p2align 2\n"
    "_dm_eos_enter:\n"
    "    stp x29, x30, [sp, #-0x60]!\n"
    "    mov x29, sp\n"
    "    stp x0, x1, [sp, #0x10]\n"
    "    stp x2, x3, [sp, #0x20]\n"
    "    stp x4, x5, [sp, #0x30]\n"
    "    stp x6, x7, [sp, #0x40]\n"
    "    add x0, sp, #0x10\n"
    "    mov x1, x16\n"
    "    bl _dm_eos_dispatch\n"
    "    ldp x29, x30, [sp], #0x60\n"
    "    ret\n"
    ".p2align 3\n"
    ".globl _dm_eos_stubs\n"
    ".private_extern _dm_eos_stubs\n"
    "_dm_eos_stubs:\n"
    "    .set eos_i, 0\n"
    "    .rept 1024\n"
    "    movz x16, #eos_i\n"
    "    b _dm_eos_enter\n"
    "    .set eos_i, eos_i + 1\n"
    "    .endr\n");
extern const uint8_t dm_eos_stubs[];

// The requests: (handle, options, client data, completion callback), the SDK 1.16 set Unity's bindings declare (All You Need Is Help's 631 entries)
static const char *const k_eos_async[] = {
    "EOS_Achievements_QueryDefinitions", "EOS_Achievements_QueryPlayerAchievements", "EOS_Achievements_UnlockAchievements", "EOS_Auth_DeletePersistentAuth", "EOS_Auth_LinkAccount",
    "EOS_Auth_Login", "EOS_Auth_Logout", "EOS_Auth_QueryIdToken", "EOS_Auth_VerifyIdToken", "EOS_Auth_VerifyUserAuth", "EOS_Connect_CreateDeviceId", "EOS_Connect_CreateUser",
    "EOS_Connect_DeleteDeviceId", "EOS_Connect_LinkAccount", "EOS_Connect_Login", "EOS_Connect_Logout", "EOS_Connect_QueryExternalAccountMappings",
    "EOS_Connect_QueryProductUserIdMappings", "EOS_Connect_TransferDeviceIdAccount", "EOS_Connect_UnlinkAccount", "EOS_Connect_VerifyIdToken",
    "EOS_CustomInvites_AcceptRequestToJoin", "EOS_CustomInvites_RejectRequestToJoin", "EOS_CustomInvites_SendCustomInvite", "EOS_CustomInvites_SendRequestToJoin",
    "EOS_Ecom_Checkout", "EOS_Ecom_QueryEntitlementToken", "EOS_Ecom_QueryEntitlements", "EOS_Ecom_QueryOffers", "EOS_Ecom_QueryOwnership", "EOS_Ecom_QueryOwnershipBySandboxIds",
    "EOS_Ecom_QueryOwnershipToken", "EOS_Ecom_RedeemEntitlements", "EOS_Friends_AcceptInvite", "EOS_Friends_QueryFriends", "EOS_Friends_RejectInvite", "EOS_Friends_SendInvite",
    "EOS_KWS_CreateUser", "EOS_KWS_QueryAgeGate", "EOS_KWS_QueryPermissions", "EOS_KWS_RequestPermissions", "EOS_KWS_UpdateParentEmail",
    "EOS_Leaderboards_QueryLeaderboardDefinitions", "EOS_Leaderboards_QueryLeaderboardRanks", "EOS_Leaderboards_QueryLeaderboardUserScores", "EOS_LobbySearch_Find",
    "EOS_Lobby_CreateLobby", "EOS_Lobby_DestroyLobby", "EOS_Lobby_HardMuteMember", "EOS_Lobby_JoinLobby", "EOS_Lobby_JoinLobbyById", "EOS_Lobby_KickMember", "EOS_Lobby_LeaveLobby",
    "EOS_Lobby_PromoteMember", "EOS_Lobby_QueryInvites", "EOS_Lobby_RejectInvite", "EOS_Lobby_SendInvite", "EOS_Lobby_UpdateLobby", "EOS_Mods_EnumerateMods", "EOS_Mods_InstallMod",
    "EOS_Mods_UninstallMod", "EOS_Mods_UpdateMod", "EOS_P2P_QueryNATType", "EOS_PlayerDataStorage_DeleteCache", "EOS_PlayerDataStorage_DeleteFile",
    "EOS_PlayerDataStorage_DuplicateFile", "EOS_PlayerDataStorage_QueryFile", "EOS_PlayerDataStorage_QueryFileList", "EOS_PlayerDataStorage_ReadFile",
    "EOS_PlayerDataStorage_WriteFile", "EOS_Presence_QueryPresence", "EOS_Presence_SetPresence", "EOS_ProgressionSnapshot_DeleteSnapshot", "EOS_ProgressionSnapshot_SubmitSnapshot",
    "EOS_RTCAdmin_Kick", "EOS_RTCAdmin_QueryJoinRoomToken", "EOS_RTCAdmin_SetParticipantHardMute", "EOS_RTCAudio_QueryInputDevicesInformation",
    "EOS_RTCAudio_QueryOutputDevicesInformation", "EOS_RTCAudio_RegisterPlatformUser", "EOS_RTCAudio_SetInputDeviceSettings", "EOS_RTCAudio_SetOutputDeviceSettings",
    "EOS_RTCAudio_UnregisterPlatformUser", "EOS_RTCAudio_UpdateParticipantVolume", "EOS_RTCAudio_UpdateReceiving", "EOS_RTCAudio_UpdateReceivingVolume",
    "EOS_RTCAudio_UpdateSending", "EOS_RTCAudio_UpdateSendingVolume", "EOS_RTCData_UpdateReceiving", "EOS_RTCData_UpdateSending", "EOS_RTC_BlockParticipant", "EOS_RTC_JoinRoom",
    "EOS_RTC_LeaveRoom", "EOS_Reports_SendPlayerBehaviorReport", "EOS_Sanctions_CreatePlayerSanctionAppeal", "EOS_Sanctions_QueryActivePlayerSanctions", "EOS_SessionSearch_Find",
    "EOS_Sessions_DestroySession", "EOS_Sessions_EndSession", "EOS_Sessions_JoinSession", "EOS_Sessions_QueryInvites", "EOS_Sessions_RegisterPlayers", "EOS_Sessions_RejectInvite",
    "EOS_Sessions_SendInvite", "EOS_Sessions_StartSession", "EOS_Sessions_UnregisterPlayers", "EOS_Sessions_UpdateSession", "EOS_Stats_IngestStat", "EOS_Stats_QueryStats",
    "EOS_TitleStorage_DeleteCache", "EOS_TitleStorage_QueryFile", "EOS_TitleStorage_QueryFileList", "EOS_TitleStorage_ReadFile", "EOS_UI_HideFriends", "EOS_UI_ShowBlockPlayer",
    "EOS_UI_ShowFriends", "EOS_UI_ShowNativeProfile", "EOS_UI_ShowReportPlayer", "EOS_UserInfo_QueryUserInfo", "EOS_UserInfo_QueryUserInfoByDisplayName",
    "EOS_UserInfo_QueryUserInfoByExternalAccount",
};

enum { K_FAIL, K_OK, K_HANDLE, K_NOTIFY, K_ZERO, K_ONE, K_VERSION, K_ENUMSTR, K_OFFLINE, K_TOSTRING, K_CREATECONT, K_ASYNC };
static struct { char *name; int kind; unsigned calls; } g_eos[EOS_STUBS];
static int g_neos;
static pthread_mutex_t g_eos_mu = PTHREAD_MUTEX_INITIALIZER;
static _Alignas(16384) uint8_t g_eos_handle[16384];   // every handle the stubs hand out: zeroed memory, so a game that peeks into one reads zeros
static uint64_t g_eos_notify = 1;

static int has(const char *s, const char *sub) { return strstr(s, sub) != NULL; }
static int ends(const char *s, const char *suf) { size_t a = strlen(s), b = strlen(suf); return a >= b && !strcmp(s + a - b, suf); }

static int eos_kind(const char *n) {
    for (size_t i = 0; i < sizeof k_eos_async / sizeof *k_eos_async; i++) if (!strcmp(n, k_eos_async[i])) return K_ASYNC;
    if (!strcmp(n, "EOS_Platform_Create") || (!strncmp(n, "EOS_Platform_Get", 16) && ends(n, "Interface"))) return K_HANDLE;
    if (!strcmp(n, "EOS_GetVersion")) return K_VERSION;
    if (!strcmp(n, "EOS_EResult_IsOperationComplete")) return K_ONE;
    if (!strncmp(n, "EOS_E", 5) && ends(n, "_ToString")) return K_ENUMSTR;   // EOS_EResult_ToString, EOS_ENetworkStatus_ToString: a const char * for an enum value
    if (ends(n, "_ToString")) return K_TOSTRING;                             // id / token to a caller's buffer
    if (!strcmp(n, "EOS_IntegratedPlatform_CreateIntegratedPlatformOptionsContainer")) return K_CREATECONT;
    if (has(n, "_AddNotify")) return K_NOTIFY;
    if (!strcmp(n, "EOS_Platform_GetNetworkStatus")) return K_OFFLINE;
    if (ends(n, "Count") || ends(n, "_IsValid") || has(n, "_Has") || has(n, "_GetLoginStatus") || ends(n, "_FromString")) return K_ZERO;
    if (!strcmp(n, "EOS_Initialize") || !strcmp(n, "EOS_Shutdown") || !strncmp(n, "EOS_Logging_", 12) || !strncmp(n, "EOS_Platform_Set", 16) ||
        has(n, "_Set") || has(n, "_Add") || has(n, "_Remove") || ends(n, "_Release") || !strcmp(n, "EOS_Platform_Tick")) return K_OK;
    return K_FAIL;   // Copy* / Get* with outputs / requests: EOS_NotFound (a request with a callback is completed by eos_async below)
}

// Requests completed on the next tick: the callback gets {ResultCode, ClientData, zeros}, as the SDK passes its callback info (every *CallbackInfo starts so)
#define EOS_QMAX 64
static struct { void (*cb)(const void *); void *client; } g_q[EOS_QMAX];
static int g_qn;
static int guest_code(uint64_t p) {
    for (int i = 0; i < g_nmod; i++) if (g_mod[i].loaded && p >= (uint64_t)g_mod[i].base && p < (uint64_t)g_mod[i].base + g_mod[i].text_end) return 1;
    return 0;
}
static void eos_tick(void) {
    for (;;) {
        pthread_mutex_lock(&g_eos_mu);
        if (!g_qn) { pthread_mutex_unlock(&g_eos_mu); return; }
        void (*cb)(const void *) = g_q[0].cb; void *client = g_q[0].client;
        memmove(g_q, g_q + 1, --g_qn * sizeof *g_q);
        pthread_mutex_unlock(&g_eos_mu);
        _Alignas(16) uint8_t info[0x100] = {0};
        *(int32_t *)info = EOS_NoConnection; *(void **)(info + 8) = client;
        cb(info);
    }
}

uint64_t dm_eos_dispatch(const uint64_t *a, unsigned n);
uint64_t dm_eos_dispatch(const uint64_t *a, unsigned n) {
    if (n >= (unsigned)g_neos) { LOG("[RED] eos: stub %u has no name", n); return EOS_NotFound; }
    const char *name = g_eos[n].name; int k = g_eos[n].kind;
    uint64_t r;
    switch (k) {
    case K_OK: r = EOS_Success; break;
    case K_HANDLE: r = (uint64_t)g_eos_handle; break;
    case K_NOTIFY: pthread_mutex_lock(&g_eos_mu); r = g_eos_notify++; pthread_mutex_unlock(&g_eos_mu); break;
    case K_ZERO: r = 0; break;
    case K_ONE: r = 1; break;
    case K_VERSION: r = (uint64_t)"1.16.0-offline"; break;
    case K_ENUMSTR: r = (uint64_t)(a[0] == EOS_NoConnection && has(name, "EResult") ? "EOS_NoConnection" : "EOS_Offline"); break;
    case K_OFFLINE: r = 2; break;   // EOS_ENetworkStatus: 1 disabled, 2 offline, 3 online
    case K_TOSTRING: r = EOS_InvalidParameters; break;
    case K_CREATECONT: if (a[1]) *(uint64_t *)a[1] = (uint64_t)g_eos_handle; r = EOS_Success; break;
    default: r = EOS_NotFound; break;
    }
    if (k == K_ASYNC) {   // complete it on the next tick; the requests that return something (Read/WriteFile, DeleteCache) return 0: no request handle, "started"
        pthread_mutex_lock(&g_eos_mu);
        if (!guest_code(a[3])) LOG("[RED] eos: %s: the callback %#llx is not code in a loaded module, not called", name, (unsigned long long)a[3]);
        else if (g_qn < EOS_QMAX) { g_q[g_qn].cb = (void (*)(const void *))a[3]; g_q[g_qn].client = (void *)a[2]; g_qn++; }
        else LOG("[RED] eos: more than %d requests waiting for a tick, %s dropped", EOS_QMAX, name);
        pthread_mutex_unlock(&g_eos_mu);
        r = 0;
    }
    if (!g_eos[n].calls++) {
        static int logged; if (logged++ < 200) LOG("eos: %s → %s", name, k == K_ASYNC ? "request, completes on the next tick with EOS_NoConnection" : k == K_HANDLE ? "a handle" :
                                                    k == K_FAIL ? "EOS_NotFound" : k == K_OK ? "success" : "offline answer");
    }
    if (!strcmp(name, "EOS_Platform_Tick")) eos_tick();
    if (!strcmp(name, "EOS_Platform_Create")) LOG("eos: platform created (host stand-in: offline, no Epic login)");
    return r;
}

// The stub for a name (one trampoline per distinct name)
void *dm_eos_sym(const char *name) {
    if (!name || strncmp(name, "EOS_", 4)) return NULL;
    pthread_mutex_lock(&g_eos_mu);
    int i = 0; while (i < g_neos && strcmp(g_eos[i].name, name)) i++;
    if (i == g_neos) {
        if (g_neos == EOS_STUBS) { pthread_mutex_unlock(&g_eos_mu); LOG("[RED] eos: more than %d EOS functions, %s unresolved", EOS_STUBS, name); return NULL; }
        g_eos[i].name = strdup(name); g_eos[i].kind = eos_kind(name); g_eos[i].calls = 0; g_neos++;
    }
    pthread_mutex_unlock(&g_eos_mu);
    return (void *)(dm_eos_stubs + 8 * i);
}

// An NRO image that is the EOS SDK: it exports EOS_Platform_Create (the name is in its dynamic string table)
int dm_eos_image(const void *image, size_t n) {
    static const char k[] = "EOS_Platform_Create";
    return image && n > sizeof k && memmem(image, n, k, sizeof k) != NULL;
}

# Minecraft Dungeons II (0100A7C01B792000): the rewriter's patches of this game's own builds. dm/tools/patch_nso.py loads every profile's patches.py and applies
# those of a module's NSO build ID; CUTS as described there ("Registered patches")
CUTS = {
  # Minecraft Dungeons II 1.1.3.0 (v131072) main: Unreal Engine 5 constructs its FMallocBinned3 in place, as FINAL FANTASY RESONANCE's: nninitStartup reserves the engine
  # region (main+0x14390), then calls the constructor on main+0x997e228 (bss; x1 = 0), which carves 38 GB of the region for its 76 pools (main+0xb0650). The call is cut;
  # the host puts its allocator's vtable (main+0x85bb8a8, 32 slots, the 5.6 layout: TryMalloc / TryRealloc call +0x30 / +0x40, MallocZeroed = TryMallocZeroed main+0xb9ca8,
  # slot 26 "Binned3") in the object before any guest code runs (hle_uemalloc.c). FPlatformMemory::BaseAllocator (main+0x14824) returns the object, and the thread-local
  # storage allocator (main+0x143f0 / main+0x14430) calls its Malloc / Free slots (+0x30 / +0x50)
  'c6b32f4d3d4243ff190b082b4f6aea18': [
    (0x143b0, '6c700294', '1f2003d5', 'nninitStartup: bl 0xb0560 (FMallocBinned3 constructor, 38 GB of the engine region) → nop; the host allocator is in the object already (hle_uemalloc.c)'),
  ],
}

OBS = {
  # It reaches its intro and then aborts in Xal.cpp:78 with XblInitialize=E_INVALIDARG. XalInitialize runs first, then the game
  # reads PrimaryServiceConfigId from its config or derives it from XalGetTitleId. Trace the separate Xal result, the Xbl entry
  # arguments, and the sandbox query's return in XSAPI to identify which input or setup step actually failed.
  # iPad 2026-11-23: XalInitialize itself returned E_FAIL, and the Xbl arguments held a zero service-config UUID.
  # The 1728 candidate passed Unreal's NULL-default and disabled Xbox subsystem overrides to the guest process.
  # The same Xbox initialization still ran and the same fatal error followed. The test overrides are not in the profile.
  'c6b32f4d3d4243ff190b082b4f6aea18': [
    (0x4238c34, 22, 'd10043a0', 'XalInitialize returned its HRESULT in w0 before the game logs it; orig sub x0, x29, #0x10'),
    (0x7133f20, 22, 'd10683ff', 'XblInitialize entry: x0 points to its argument struct; orig sub sp, sp, #0x1a0'),
    (0x7176224, 22, '2a0003f5', 'XSAPI config: XalGetSandbox returned its HRESULT in w0; orig mov w21, w0'),
  ],
}

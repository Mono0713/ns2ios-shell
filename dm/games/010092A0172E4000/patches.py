# It Takes Two (010092A0172E4000): the rewriter's patches of this game's own builds. dm/tools/patch_nso.py loads every profile's patches.py and applies those of a module's NSO build ID;
# CUTS, OBS and FRAME_STEP as described there ("Registered patches"). Patches of Nintendo SDK module builds are in dm/tools/sdk_patches.py
# The game packs from a provisional profile (switchpad/make_provisional.py keeps this file); its memory rows are in dm/games/provisional_overrides.tsv
CUTS = {
  # It Takes Two 1.0.3 (v196608) main: Unreal Engine 4.26 with FMallocBinned3, the same shape as Pikmin 4. nninitStartup (main+0x349db60) reserves the engine's address region only when
  # -SwitchVirtualAddressSpaceSize= is absent, and then 62 GB (orr #0xf80000000) through nn::os::AllocateAddressRegion (main+0x349e1f4) without checking it. The iPad's alias region held 49 GB,
  # so the base stayed 0, and on the first allocation GCreateMalloc (main+0x349e9c8) mallocs 0x1c38 bytes and constructs FMallocBinned3 in them (bl main+0x34fd298, vtable main+0x97d5f70),
  # which carves 37 GB of pools out of that region: the game hung in main's init_array after "heap 0.01 GB" (iPad log 2026-11-20). The default is cut to 4064 MB, as Pikmin 4's, the
  # constructor call is cut, and observation gate OBS_UE_MALLOC (OBS below) puts the host allocator's vtable into the new object, still in x19 (dm/host/hle_uemalloc.c)
  '104db32fd10e753898d3957264a24c08': [
    (0x349e1dc, 'e81361b2', '08c0bfd2', 'nninitStartup: the engine region\'s default size orr x8,xzr,#0xf80000000 (62 GB) → mov x8,#0xfe000000 (4064 MB)'),
    (0x349e1f0, 'e11361b2', '01c0bfd2', 'nninitStartup: AllocateAddressRegion size orr x1,xzr,#0xf80000000 (62 GB) → mov x1,#0xfe000000 (4064 MB)'),
    (0x349e9e0, '2e7a0194', '1f2003d5', 'GCreateMalloc: bl 0x34fd298 (FMallocBinned3 constructor) → nop; the host allocator\'s vtable is put in at the gate after it (hle_uemalloc.c)'),
  ],
}
OBS = {
  # It Takes Two 1.0.3 main: right after the cut FMallocBinned3 constructor call (CUTS above), x19 = the new allocator object; the host writes its vtable there (hle_uemalloc.c)
  '104db32fd10e753898d3957264a24c08': [
    (0x349e9e4, 21, 'aa1303e0', 'GCreateMalloc: the allocator object is in x19, before it is used: the host puts its vtable in; orig mov x0, x19'),
  ],
}

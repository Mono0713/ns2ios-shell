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

# Kirby Star Allies (01007E3006DDA000): the rewriter's patches of this game's own builds. dm/tools/patch_nso.py loads every profile's patches.py and applies those of a module's NSO build ID;
# CUTS, OBS and FRAME_STEP as described there ("Registered patches"). Patches of Nintendo SDK module builds are in dm/tools/sdk_patches.py
CUTS = {
  # Kirby Star Allies 4.0.0 / 4.0.0a main: the frame pacing object (a singleton whose pointer is at main+0x54c5b0, made at main+0x59e8 with +0 = 0) keeps a mode at +0, an index into
  # {1, 2, 3, 4, 5, 6} vsyncs per frame. The game runs one logic update per vsync (main+0x7f18 → the main loop's n updates per frame at main+0x176c / 0x17f8), so the mode changes the
  # frame rate and not the game's speed. Its setter (main+0x5a48) is what puts the stages to 30 fps (mode 1, from main+0x1c9a98 and main+0x1ca3b0); its store is cut, as in masagrator's
  # FPSLocker config for this build (FPSLocker-Warehouse, patches/01007E3006DDA000/D55608916FA56C18.yaml, interval offsets by Kirby567Fan), so the mode stays at 0, 60 fps. The launcher's
  # 30 fps cap writes 1 into it (hle_fpslock.c). One update per vsync: on a device that falls short of 60, the game slows down instead of skipping
  'd55608916fa56c184f2a8fe80da0427c': [
    (0x5a4c, '010000b9', '1f2003d5', 'frame pacing mode setter: str w1, [x0] → nop; the mode stays at the constructor\'s 0 (60 fps), the host writes 1 for a 30 fps cap'),
  ],
}

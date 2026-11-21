# Rabbids Party of Legends (01008970149B0000): the rewriter's patches of this game's own builds. dm/tools/patch_nso.py loads every profile's patches.py and applies those of a module's NSO build ID;
# CUTS, OBS and FRAME_STEP as described there ("Registered patches"). The game packs from a provisional profile (switchpad/make_provisional.py keeps this file)
OBS = {
  # subsdk1 (the SDK's movie library, 1.0.0 v65536): the intro movie (VP9 + Vorbis) crashed on the audio read thread at subsdk1+0x2e9e2c, in NuMediaExtractor::fetchTrackSamples,
  # reading a track's source that held 3, 3, 0, 2 instead of an object (main+0x4091100; iPad logs 2026-11-21, at 1 GB and at 3.2 GB alike, so not memory). Diagnostic gates
  # (OBS_TRACE, hle_sdk16.c: the registers and what they point at, the first 16 hits) on where that pointer is stored and where it is read
  '7e9f31f59e001cf5d9b546ffb233f480': [
    # right after bl 0x3310a0 (a gate goes at a function entry or after a bl): x23 = the source stored into the new TrackInfo by the stp x23, x21, [x22] next, x21 = the track index
    (0x2e98ac, 22, '08008092', 'NuMediaExtractor::selectTrack: the source (x23) about to go into the new TrackInfo; orig mov x8, #-1'),
    (0x2e9b10, 22, 'ff8304d1', 'NuMediaExtractor::fetchTrackSamples entry: x0 = the extractor (tracks: Vector at +0x68, storage +0x70, count +0x78); orig sub sp, sp, #0x120'),
  ],
}

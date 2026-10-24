# The two games that need a capture

Everything the packer does works from the game's own files. Two games are the exception, and this page is about them.

| Game | Title ID | Shaders | What it costs you |
|---|---|---|---|
| **Super Mario Galaxy** (1.3.1) | `010099C022B96000` | 3,089 | one run of the game, about a minute |
| **Super Mario Galaxy 2** (1.4.0) | `0100FD8022DAA000` | 3,797 | same, and it shares only 38.5% of them with the first game |

## Why these two are different

A shader has to exist as a file or as something we can rebuild before the game ever runs. Three cases, and the first two are the normal ones:

| Where the shaders live | Example | What the packer does |
|---|---|---|
| In the game files, already compiled | NVN games (47 of the supported list), Hades (74 SPIR-V files in its RomFS) | reads and translates them |
| The engine carries its own generator as readable code | Balatro's LÖVE (`resources/shaders/*.fs` + `wrap_GraphicsShader.lua`) | runs that generator, which produces the exact shaders the game would compile |
| The engine generates them from hardware state, in compiled code | **Galaxy 1 and 2** (Hagi turns GameCube/Wii GX pipeline state into SPIR-V) | **nothing to read — the shaders only exist while the game runs** |

Galaxy's shaders are not programs in a file. They are what a GX pipeline configuration *becomes*, computed inside Hagi (a C++ shader compiler, compiled to machine code) from `pipelineDB.pip`. To produce them on a PC we would have to rewrite that compiler — a GX state → SPIR-V translator — which is a different project, not a missing step. Collecting them once takes a minute.

## What to do

The first step produces a package that boots, plays its audio and draws nothing. That is the point: it is a game that runs far enough to build its own shaders.

### 1. Pack it without shaders

```bash
python scripts/nxn_pack.py <shell.zip> <game folder> -k prod.keys --tools <tools folder> --no-shaders -o Galaxy-capture.ipa
```

### 2. Tell the app where to write them

Install the IPA, then:

1. In the Files app, next to `Documents/log.txt`, make an empty folder named `vkcap`.
2. Add one line to `Documents/env.txt` (create it if it does not exist; one `KEY=VALUE` per line):

```
DM_VK_CAPTURE=vkcap
```

The path is relative to the app's Documents folder, which is where `log.txt` lives — you do not need the sandbox path.

### 3. Run the game once

Launch it and leave it for a minute. It shows a title screen and starts building pipelines; every shader it creates is written to `vkcap/` as `<key>.spv`. It will look broken — black screen, maybe a logo — that is expected, nothing is being drawn.

Quit, then look at the folder. **Galaxy 1 should hold 3,089 files, Galaxy 2 3,797.** If it has fewer, run it again: files already there are skipped, so it is safe to repeat, and later areas of the game add more.

### 4. Pack it again

```bash
python scripts/nxn_pack.py <shell.zip> <game folder> -k prod.keys --tools <tools folder> --vk-capture "/path/to/vkcap" -o Galaxy.ipa
```

3,089 modules become about 3,950 Metal sources (some fragment shaders get a second variant for dual-source blending). The first launch on the phone compiles them all — a few minutes, with a progress screen — and after that they come from the system's shader cache.

## Notes

- **The capture is per game, not per version.** A save or an update does not invalidate it; a different title does.
- **Keep the folder.** Rebuilding the same game later only needs `--vk-capture` again, not another run.
- **The IPA with shaders contains your game files.** Like every package this packer makes, it is for your own use.
- If a game you pack reports `no SPIR-V files in .../RomFS` and it is *not* one of these two, that is a bug — please open an issue with the log from `Documents/log.txt`.

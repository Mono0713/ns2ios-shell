# The shell split

The normal route builds everything on one Mac: `scripts/build_ipa_from_nsp.py` rewrites the game program, translates its
shaders, compiles them with Apple's `metal` compiler, and lets `xcodebuild` link the whole app. A user without a Mac cannot do
any of that.

This route splits it in two:

| | Where | What |
|---|---|---|
| **1. Shell** (once) | Mac or the `macOS` CI runner | `dm/ios/tools/shell_build.sh` compiles the app with **no game content at all** and publishes a few MB of build input |
| **2. Pack** (per game) | Windows, Linux or macOS | `scripts/nxn_pack.py` takes the user's own NSP + `prod.keys`, rewrites the program, translates the shaders, writes them into the shell and produces an IPA |

Nothing from any game ever reaches this repository or CI. The shell is generic across games, which is the hard part and the point.

## Why one shell serves any game

Upstream nxnative bakes game-specific data into the executable, so a shell would only work for the game it was built for. Shell
mode (`-DDM_SHELL`) moves each of those to run time:

| Baked in normally | In shell mode |
|---|---|
| `gen_embed.py` compiles the rewritten module images into `__TEXT` / `__DM*W` sections (`host/loader.c`) | Taken from `Frameworks/Guest.framework/Guest`, a segments-only dylib written by `dm/tools/guest_dylib.py` with nothing but the Python standard library — byte-identical output on any OS |
| `DM_GAME_MODULES` from the game profile (`host/main.c:94`, only used when argv gives no names) | Read back from the Guest library's `__dm<name>x0` section names (`dm_shell_modules`), appended to `argv` in `main.m` |
| `DMSH_CHAIN` from the profile's `dmsh_chain.h` | Resolved from the name of the one library directory under `msl/` (`b-<version>`) — the chain version hashes the game's shader tables, so it differs per game |
| `.metallib` compiled by `xcrun metal` | Files that do not start with `MTLB` are treated as MSL source and compiled on the device, then cached by the system |
| `romfs_marker`-based RomFS lookup | Any existing, non-empty RomFS directory is accepted |
| The profile's memory layout (`mem_used`, `app_pool`, `mem_alias`, …) | Read from the environment at startup; the packer writes the game's real values into the app's `dm/env.txt` |
| — | `dm/ios/Sources/dm_shader_prep.m` compiles all source-form shaders once on first launch with a progress page |

The rewriter and shader tables needed no work: in nxnative they are already ordinary resources (`Gen/dm`, a resource folder in
`ios/project.yml`) read at run time, not arrays compiled into code. That is why this shell needs **no game files** to build,
unlike d2r-mobile's `shell_build.sh`.

The memory layout was not obvious and cost a device round trip: with the placeholder's default `mem_used` (64 MB) instead of
Hades II's 108 MB, the game asks for `pool - used` of heap and overflows the pool by 44 MB, aborting in `SetHeapSize`.

## Building

Locally on a Mac with Xcode 26:

```
bash dm/ios/tools/shell_build.sh
```

Or on CI: run the **Build shell** workflow. Manual runs use this fork's tree; the daily schedule uses the latest upstream commit
with this fork's files copied over it (`.shell-overlay.txt`). Both publish a release. The build ends with checks that the app
carries no `romfs/`, `msl/`, `aoc/`, no module image sections and no file over 8 MB outside `dm/font`.

## Status

| Part | State |
|---|---|
| Shell mode (`-DDM_SHELL`) and the shell build | Working, published by CI as releases |
| `scripts/nxn_pack.py` (the packer) | Working end to end on Windows |
| Device test | **Passed far enough to prove the route**: the shell loads the Guest library, discovers the modules, and compiled Hades II's 140 shaders on the phone in 4.3 s. It then aborted in `SetHeapSize` on the memory layout (fixed since, patch not yet re-tested on the device) |

## What running on Windows actually required

Every one of these was macOS-only code that had never run elsewhere:

| File | Problem |
|---|---|
| `dm/gfx/tools/shader_split.py` | `os.path.relpath` yields backslashes, so recorded RomFS paths stopped matching the profile's `shader_groups`, every shader fell into `other`, and the split tables failed their own comparison |
| `dm/gfx/tools/dmsh_mtlcache.py` | `ctypes.CDLL(None)` means "the running process" on POSIX only; on Windows it raises `TypeError` at import |
| `dm/gfx/tools/dmsh_chain.py` | A single-file translator build has no `.dll` to fingerprint; the executable is `dmsh_xlate.exe`; a Windows checkout's CRLF makes the embedded source digest differ from the tree's |
| `dm/gfx/tools/nometal_run.py` | Three `xcrun` probes were unhandled (the ported script raises on any it does not know), and it deletes a temporary file per shader — which a deletion-counting harness kills midway |
| `dm/ios/tools/pack_ipa.py` | `os.stat` on Windows has no x bit, so the app's main binary was stored as 0644 and the installed app would not start |
| `dm/host/hle_svc.c` | The memory layout was compile-time only, which a game-free shell cannot supply |

## Self-checks worth keeping

- `shell_build.sh` refuses to publish if the app carries `romfs/`, `msl/`, `aoc/`, module image sections, or any file over
  8 MB outside `dm/font`.
- The packer compares the NSO build ID of `ExeFS/main` and `sdk` against the profile, and the split shader tables against the
  profile byte for byte. A wrong game version stops there instead of producing an IPA that fails on the phone.
- Shader completeness is decided by `dmsh_build.py`'s per-shader results, not by "some library exists": an interrupted run
  would otherwise be trusted.

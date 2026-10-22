# Shell: packing an IPA without a Mac

The normal route builds everything on one Mac: `scripts/build_ipa_from_nsp.py` rewrites the game program, translates its shaders,
compiles them with Apple's `metal` compiler, and lets `xcodebuild` link the whole app. A user without a Mac cannot do any of that.

This route splits it in two:

| | Where | What |
|---|---|---|
| **1. Shell** (once) | Mac or the `macOS` CI runner | `dm/ios/tools/shell_build.sh` compiles the app with **no game content at all** and publishes a few MB of build input |
| **2. Pack** (per game) | Windows, Linux or macOS | `scripts/nxn_pack.py` takes the user's own NSP + `prod.keys`, rewrites the program, translates the shaders, writes them into the shell and produces an IPA |

Nothing from any game ever reaches this repository or CI. The shell is generic across games, which is the hard part and the point.

## Why one shell serves any game

Upstream nxnative bakes game-specific data into the executable, so a shell would only work for the game it was built for. Shell mode
(`-DDM_SHELL`) moves each of those to run time:

| Baked in normally | In shell mode |
|---|---|
| `gen_embed.py` compiles the rewritten module images into `__TEXT` / `__DM*W` sections (`host/loader.c`) | Taken from `Frameworks/Guest.framework/Guest`, a segments-only dylib written by `dm/tools/guest_dylib.py` with nothing but the Python standard library — byte-identical output on any OS |
| `DM_GAME_MODULES` from the game profile (`host/main.c:94`, only used when argv gives no names) | Read back from the Guest library's `__dm<name>x0` section names (`dm_shell_modules`), appended to `argv` in `main.m` |
| `DMSH_CHAIN` from the profile's `dmsh_chain.h` | Resolved from the name of the one library directory under `msl/` (`b-<version>`) — the chain version hashes the game's shader tables, so it differs per game |
| `.metallib` compiled by `xcrun metal` | Files that do not start with `MTLB` are treated as MSL source and compiled on the device, then cached by the system |
| `romfs_marker`-based RomFS lookup | Any existing, non-empty RomFS directory is accepted |
| — | `dm/ios/Sources/dm_shader_prep.m` compiles all source-form shaders once on first launch with a progress page (ported from d2r-mobile, MIT) |

The rewriter and shader tables needed no work: in nxnative they are already ordinary resources (`Gen/dm`, a resource folder in
`ios/project.yml`) read at run time, not arrays compiled into code. That is why this shell needs **no game files** to build, unlike
d2r-mobile's `shell_build.sh`.

## Building the shell

Locally on a Mac with Xcode 26:

```
bash dm/ios/tools/shell_build.sh
```

Or on CI, which needs neither a Mac nor a `prod.keys`: run the **Build shell** workflow. It ends with checks that the app carries no
`romfs/`, `msl/`, `aoc/`, no module image sections and no file over 8 MB, and uploads
`nxnative-shell-build-input.zip` (a build input — not an installable `.ipa`).

The shell builds against the neutral placeholder profile `dm/games/0000000000000000`, whose values are only fallbacks.

## Status

| Part | State |
|---|---|
| Shell mode (`-DDM_SHELL`) and the shell build | Written; compiles in CI (see the workflow runs) |
| `scripts/nxn_pack.py` (the packer) | **Not written yet** — the next step |
| Device test of a packed IPA | Not done |

What the packer still needs, per the code survey: `nx_extract` (`dotnet`, pure managed, drop the `clonefile` path), `patch_nso.py`
(pure Python + capstone), `shader_split.py`, `dmsh_xlate.dll` (`dotnet`, the apphost in the repo is osx-arm64 but the IL is portable),
`spirv-cross` (Windows build exists), `guest_dylib.py`, and `pack_ipa.py` (pure standard library, but its `st_mode`-based external
attributes need a fix on Windows so the app binary keeps its executable bit). The Apple-only steps — `xcrun metal` and `xcodebuild` —
are exactly the two this split removes.

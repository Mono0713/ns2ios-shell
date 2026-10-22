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

## Following upstream

The schedule runs at 08:00 Beijing time (00:00 UTC) and **only builds when upstream moved**: it compares upstream's latest
commit with the version in the newest release and skips in a few seconds when they agree. So when upstream adds support for a
new game, the shell downloaded from here plays it — nobody has to follow up by hand.

This repository is not a clone of upstream; it only carries the difference, in two kinds:

| File | Meaning |
|---|---|
| lines starting with `+` in `.shell-overlay.txt` | files this fork **adds**, copied wholesale onto the upstream tree |
| `.shell-patches/*.patch` | this fork's changes to files upstream **already has**; `git apply`'d onto the upstream tree |
| `.shell-base.txt` | the upstream commit the patches were generated against |

Patches rather than whole-file copies exist so that an upstream edit elsewhere in the same file survives. The **only** case that
conflicts is upstream changing the same lines a patch touches.

### When it conflicts

Symptom: the `Shell` job fails in `Assemble the source tree` with `xxx.patch does not apply`. The pipeline stops there and
publishes nothing — you never get a shell that has drifted from upstream without being told.

1. `git clone --depth 1 https://github.com/seedds/nxnative up`
2. `cd up && git apply --reject <this repo>/.shell-patches/xxx.patch` and look at the `.rej` files
3. Read the `.rej` and the new upstream code, then **re-apply the intent** by hand; pasting the old text usually is not right
4. Regenerate the patch and move the base:
   ```
   python dm/ios/tools/make_shell_patch.py dm/xxx/yyy.py     # one file; --all regenerates every "~" entry
   ```
   It diffs against upstream's copy at the commit in `.shell-base.txt` and normalises CRLF on both sides, because the patch is
   applied to upstream's LF files. After moving the base commit, confirm with
   `git -C up apply --check <.shell-patches/xxx.patch>`, then commit the file, the patch and `.shell-base.txt` together
5. Only if step 4 is not enough does C need work: upstream changed one of the six substitutions shell mode makes (a signature, a
   struct field, a `#define` name) or the layout of data that is read across the boundary, so the patch applies but the build
   fails. Fix `dm/host/*.c` and regenerate the patches

The rule of thumb for "does C need work": if upstream touched none of those six substitution points or the structs around them,
the patch applying means it builds.

All of this happens in CI. On Windows it shows up as nothing but a new shell zip: same command, same flags, same Python
dependencies.

## The contract between the shell and the packer

They are built separately, so one thing has to line up: the rewriter (`patch_nso.py`) writes call sites into the game's
modules and the host (`gate_register` in `dm/host/hle.c`) dispatches them **by kind name** — `svc`, `cntpct`, `cntvct`,
`obs`, `spin`. The shell is compiled in advance, so a kind a newer packer writes may be one it does not know, and the result
is a package that builds fine and dies on installation:

```
[dm] FATAL unknown gate kind spin
[dm] bt: abort gate_register load_modules host_preload preload_thread
```

That happened once for real: a shell from an early fork build paired with a later packer aborted in `load_modules`.

So `shell_build.sh` now records what the shell can do in `dm/shell_info.txt`:

```
KIND=ios
SOURCE_SHA=<the commit it was built from>
GATES=svc cntpct cntvct obs spin
GUEST=1
ENV=1
```

`GATES` is not written by hand: it is extracted from the strcmp chain in `hle.c`, and if that extraction fails (upstream
rewrote the line, say) the build fails — better no release than a stamp that lies to the packer. `GUEST` and `ENV` are
decided the same way, from the actual code in `loader.c` and `main.m`.

After the rewrite, the packer checks that every kind it actually emitted is in `GATES`, and stops with the fix if not. A
shell too old to carry these keys only gets a warning: a missing key means "cannot be verified", not "broken", and the first
shells published here are in that state.

## The working folder, and cleaning it up

The packer creates `<title ID>_pack` next to the game's files and keeps every intermediate product in it:

| Folder | What it is | Still needed after packing? |
|---|---|---|
| `extract/` | the ExeFS and RomFS unpacked from the NSP/XCI | no, it is unpacked again in a minute |
| `build/patched/` | the rewritten modules | no |
| `shader/` | the split shader package and the translation cache | no |
| `stage/` | the assembled app tree, including a copy of the RomFS — the largest item | no, it is in the IPA |
| `logs/` | one log per step | **yes**, a few KB, and it is what explains a problem on the phone |

So once the IPA is written, the rest is deleted and only `logs/` stays. The amount is the point: `extract/` and `stage/` each
hold a copy of the game, so a 4 GB game leaves ~16 GB behind. `--keep-work` keeps the whole tree (worth it when repacking the
same game repeatedly, as it skips the unpack and the translation), and `--clean <game folder>` clears out an earlier run.

Only directories this script created are removed, one child at a time, each checked to be inside the work folder — so a
symlink in the RomFS cannot lead the deletion anywhere else.

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

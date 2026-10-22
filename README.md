# nxnative shell — pack an IPA without a Mac

Play your own Nintendo Switch games on iPhone and iPad. This fork of [nxnative](https://github.com/seedds/nxnative) splits the
build in two, so the Mac-only half happens **once** on a CI runner and everything that needs your game files happens on **your
own machine — Windows, Linux or macOS, without Xcode**.

| | Where | What |
|---|---|---|
| **1. Shell** | built by CI, downloaded once | A few MB of unsigned iOS app with **no game content at all** |
| **2. Pack** | your machine | `scripts/nxn_pack.py` takes your NSP + `prod.keys`, rewrites the program, translates the shaders and writes them into the shell |

The shell is **game-agnostic**: one shell serves any game in the supported list. Nothing from any game ever reaches this
repository or CI.

> 中文说明：[README.zh-CN.md](README.zh-CN.md)
>
> Upstream project and its own documentation (the Mac route): **[seedds/nxnative](https://github.com/seedds/nxnative#readme)**.


## Quick start (Windows)

**1. Download two files** from the [Releases](../../releases) page:

- `shell-<date>-<commit>-shell.zip` — the shell
- `nxnative-windows-tools.zip` — `nx_extract.exe`, `dmsh_xlate.exe`, `spirv-cross.exe` (self-contained, no .NET SDK needed)

Unpack the tools anywhere, e.g. `D:\nxn-tools`.

**2. Put one game's files in a folder.** The file name must carry the title ID and version:

```
D:\games\hades2\
  Hades II [0100A00019DE0000][v0].nsp
```

**3. Run:**

```bash
python scripts/nxn_pack.py shell-<date>-<commit>-shell.zip D:\games\hades2 ^
    -k D:\keys\prod.keys --tools D:\nxn-tools
```

**4. Sideload the IPA** it writes next to your NSPs (SideStore, Sideloadly, LiveContainer…). The first launch compiles the
shaders once, with a progress page that estimates how long it will take.

The **temporary files are removed as soon as the IPA is written**: the extraction, the rewritten modules, the split shaders
and the assembled app tree add up to several times the size of the game (a 4 GB game leaves ~16 GB behind) and none of it is
worth keeping. Only the few-KB log (`<title ID>_pack\logs\`) stays, because that is what explains a package that misbehaves
on the phone.

Add `--keep-work` to keep that tree when you repack the same game repeatedly, or clear out an earlier run:

```bash
python scripts/nxn_pack.py --clean D:\games\hades2
```

## Requirements

On the **packing machine**:

| Need | How |
|---|---|
| Python 3.9+ | `pip install lz4 capstone fonttools backports.zstd pillow` |
| Three executables | From `nxnative-windows-tools.zip`, passed with `--tools` |
| `prod.keys` | Dumped from your own console. It never leaves your machine: it is passed to `nx_extract` as an argument and is not written to any log |

No .NET SDK, no C++ toolchain, no Mac. (Building the tools yourself is possible: `dotnet publish dm/tools/nx_extract -r win-x64
--self-contained`, same for `dm/gfx/tools/dmsh_xlate`; SPIRV-Cross must be the `vulkan-sdk-1.4.357.0` tag.)

## File names do not matter

The packer identifies the game from the **metadata inside the NSP** — the plaintext `cnmt.xml` next to the (encrypted) content
files, which carries the title ID, the content type (base game / update / DLC) and the version. So files can be named
anything at all.

The `[XXXXXXXXXXXXX000]` and `[vN]` in a name are only read when a file carries no such metadata: **XCI cartridges** (a
cartridge has no metadata XML). If you rename an XCI, keep the title ID in the name.

Formats: **NSP** (base game, updates, DLC) and **XCI** (base game only). **NSZ is not supported** — unpack it first with
`nsz -D "file.nsz"`.

## Which games work, and which version

Any game with a profile in [`dm/games/`](dm/games/). **Any version works**, with or without an update: the packer takes the
newest version it finds in the folder (override with `-p vN`) and builds it with the shaders split from that version's own
files. Upstream tested each game on one version; on another version the app says so, and fixes made for the tested version
(60 fps, for instance) do not apply to it.

An update is optional — the base game alone is enough. DLC files in the folder are packed too, and without them the game sees
none, exactly as on a Switch without them.

## How it works

```
CI (once)          your machine                      iPhone
─────────          ──────────────────────────────    ────────────────────
shell_build.sh ──► nxn_pack.py
  host program       ├ extract NSP      (nx_extract)
  no game content    ├ rewrite program   (patch_nso.py)
  no shaders         ├ split shaders     (shader_split.py)
  no RomFS           ├ translate → MSL   (dmsh_xlate, spirv-cross)  ──► IPA ──► sideload
                     ├ write Guest.framework (guest_dylib.py)            │
                     └ assemble + pack (pack_ipa.py)                    ▼
                                                                  first launch:
                                                                  compile shaders
```

Two things make one shell work for every game, both moved from compile time to run time:

- the **module list** is read back from the `__dm<name>x0` sections of `Frameworks/Guest.framework` (the game program is a
  segment-only dylib instead of being compiled into the executable);
- the **shader chain version** is read from the name of the `msl/b-<version>` directory.

The shell is also compiled against a neutral placeholder profile, so the game's memory layout (`mem_used`, `app_pool`, …) is
written by the packer into the app's `dm/env.txt` and read by the host at startup.

## Notes and caveats

- **The IPA contains your game files.** It is for your own use; do not distribute it.
- **First launch takes a while**: the phone compiles every shader once. Hades II's 140 shaders take about 5 s; bigger titles
  take minutes (the progress page estimates). The system caches the result, so later launches start immediately.
- To change a setting on the device without repacking, put `KEY=VALUE` lines in the app's `Documents/env.txt`.
- If it crashes, the host writes `Documents/log.txt` — in almost every case that file names the reason.
- Packing needs **disk space of roughly twice the NSP size**: the extracted RomFS, the staged app and the IPA coexist.

## Repository layout

```
dm/ios/tools/shell_build.sh      builds the shell (CI, needs the macOS 26 SDK)
scripts/nxn_pack.py              packs the shell + your game files into an IPA (any OS)
dm/tools/guest_dylib.py          writes Frameworks/Guest.framework from the rewritten modules
dm/gfx/tools/nometal_run.py      runs the shader chain without Apple's metal compiler
dm/ios/Sources/dm_shader_prep.m  first-launch shader compilation page
dm/games/0000000000000000/       neutral profile the shell is compiled against
.shell-overlay.txt               files this fork adds or changes on top of upstream
docs/SHELL.md                    the split in more detail
```

## Credits and license

This is a fork of **[nxnative](https://github.com/seedds/nxnative)** by **seedds**, and owes most of its substance to it: the
rewriter, the translation chain, the host, the game profiles and the thirty-odd device-verified titles are upstream's work.

The native-execution approach itself comes from **[d2r-mobile](https://github.com/jhaizhou-ops/d2r-mobile)** by
**jhaizhou-ops** (MIT), built for Diablo II: Resurrected. Upstream nxnative (first called smbw-mobile) started as a copy of its
generic parts — the NSO rewriter, the Horizon host, the NVN-on-Metal layer and the iOS app shell — and fixes go both ways
between the two projects. They are two separate projects by two different authors, each with its own game.

The shell route here follows d2r-mobile's `shell_build.sh`; `guest_dylib.py`, `nometal_run.py`, `dm_shader_prep.m` and
`shell_build.sh` are ported from it.

`nx_extract` uses **[LibHac](https://github.com/Thealexbarney/LibHac)**; the shader translator embeds Ryujinx's shader library;
shaders are translated with **[SPIRV-Cross](https://github.com/KhronosGroup/SPIRV-Cross)**.

**License: MIT**, the same as upstream. [LICENSE](LICENSE) is upstream's own file and carries the original copyright notice
(© 2026 jhaizhou — nxnative kept it from d2r-mobile, whose generic parts it started from). If you redistribute this fork or a
build of it, keep that notice and this license with it. The MIT license covers the code only: game files, keys and any IPA you
pack are your own responsibility and are not covered by it.

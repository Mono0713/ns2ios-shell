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

**You need four things:**

| What | Where from | Where it goes |
|---|---|---|
| **The whole repository** | `git clone https://github.com/xinerqu/ns2ios-shell`, or the source zip on the Releases page | anywhere, e.g. `D:\nxn` |
| **The shell** | `shell-<date>-<commit>.zip` on the Releases page | e.g. `D:\nxn\shell.zip` |
| **The three executables** | `nxnative-windows-tools.zip` on the Releases page (self-contained, no .NET SDK) | unpack to e.g. `D:\nxn-tools` |
| **Your game files + `prod.keys`** | your own machine | e.g. `D:\games\hades2\` |

> **Why the whole repository, and not just `nxn_pack.py`?**
> The script is only the entry point; the work is done by `dm/` in the repository. Each supported game's parameters (module
> list, memory layout, rewriter tables, shader tables) live in `dm/games/<title ID>/`, and the rewriter and shader tools in
> `dm/tools/` and `dm/gfx/tools/`. Without `dm/` it says so immediately rather than failing halfway. Laying it out flat —
> `nxn_pack.py` next to `dm/` — works too; the script accepts both.

**1. Install the packages** (into **the interpreter you will run the packer with** — they are per interpreter):

```bash
python -m pip install lz4 capstone fonttools backports.zstd pillow
```

**2. Put one game's files in a folder.** The name does not matter: the game is identified from the package's contents (see
"File names do not matter" below).

```
D:\games\hades2\
  Hades II.nsp          ← or .xci, any name
  (optional) update.nsp ← same folder; the newest version present is the one packed
```

**3. Run it from the repository folder:**

```bash
cd D:\nxn
python scripts\nxn_pack.py shell.zip D:\games\hades2 ^
    -k D:\keys\prod.keys --tools D:\nxn-tools
```

The IPA is written next to the game files by default (`-o` to choose). The run unpacks the game, rewrites the modules,
translates the shaders, assembles the app and packs the IPA, reporting each step and how long it took.

**4. Sideload the IPA** (SideStore, Sideloadly, LiveContainer…). The first launch compiles the shaders once, with a progress
page that estimates how long it will take.

### After the pack

The **temporary files are removed as soon as the IPA is written**: the extraction, the rewritten modules, the split shaders
and the assembled app tree add up to several times the size of the game (a 4 GB game leaves ~16 GB behind) and none of it is
worth keeping. Only the few-KB log (`<title ID>_pack\logs\`) stays, because that is what explains a package that misbehaves
on the phone.

- `--keep-work` keeps that tree, so repacking the same game skips the unpack and the translation
- `--clean <game folder>` clears out what an earlier run left
- a cartridge dump (`.xci`) gets a `<file>.xci.tid` next to it on the first pack, so the next one does not unpack it again

## Requirements

On the **packing machine**:

| Need | How |
|---|---|
| The whole repository | `git clone` or the source zip — **`dm/` must be there**, see above |
| Python 3.9+ | `python -m pip install lz4 capstone fonttools backports.zstd pillow`, into **the interpreter that runs the packer** |
| Three executables | From `nxnative-windows-tools.zip`, passed with `--tools` |
| `prod.keys` | Dumped from your own console. It never leaves your machine: it is passed to `nx_extract` as an argument and is not written to any log |

No .NET SDK, no C++ toolchain, no Mac. (Building the tools yourself is possible: `dotnet publish dm/tools/nx_extract -r win-x64
--self-contained`, same for `dm/gfx/tools/dmsh_xlate`; SPIRV-Cross must be the `vulkan-sdk-1.4.357.0` tag.)

**About Python**: a machine often has more than one, and the one `pip install` writes to must be the one that runs
`nxn_pack.py`. The reliable form uses the same executable for both:

```
C:\path\to\python.exe -m pip install lz4 capstone fonttools backports.zstd pillow
C:\path\to\python.exe scripts\nxn_pack.py ...
```

The packer checks for all five packages before it starts and prints the commands to run, rather than failing halfway.

## File names do not matter

The packer identifies the game from the **metadata inside the NSP** — the plaintext `cnmt.xml` next to the (encrypted) content
files, which carries the title ID, the content type (base game / update / DLC) and the version. So files can be named
anything at all.

The `[XXXXXXXXXXXXX000]` and `[vN]` in a name are only read when a file carries no such metadata. **XCI cartridges** carry
neither a ticket nor a readable header (an NCA header is encrypted with a key from its own key area), so on the first pack
the packer unpacks the dump and takes the title ID from the result, recording it in `<file>.xci.tid`; later packs read that
instead of unpacking again.

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
- **The memory limit is about 3.4 GB, and the shell asks to raise it.** Without the `increased-memory-limit` entitlement iOS
  allows a process about 3,375 MB, while the emulated game alone asks for 3,285 MiB, so a big title sits right against the
  wall — and going over it is a **memory kill with no crash log**, not a crash. The shell is signed ad hoc at build time with
  that entitlement inside `DmIOS`, because an unsigned binary has no signature for an install tool to read it from; whether it
  survives the re-sign depends on the tool:

  | How it is installed | Entitlement kept |
  |---|---|
  | AltStore Classic 2.2+, Impactor, Xcode with a personal team | yes |
  | SideStore with a free Apple ID | yes, after a one-off fix to the App ID |
  | Sideloadly | no (the game runs under the 3.4 GB cap as before) |

  To tell: the boot line in `Documents/log.txt`, `boot: memory limit N MB` — about 3,375 MB means it did not take effect,
  6–8 GB means it did.
- **Each game is a separate app, so several install side by side.** The bundle ID comes from the title ID
  (`org.nxnative.<title ID>`), so a second game does not replace the first and their saves are separate. Repacking the same
  game updates it in place, saves intact. Packages built before this change still carried the shell's `org.nxnative.shell`
  and did collide — repack, and delete the old one by hand.
- **The shell and the packer belong together.** Use the shell from the same release rather than a zip kept from earlier: an
  old shell may not understand what a new packer writes into it (the usual symptom is an app that dies while loading with
  `unknown gate kind spin` in its log). The packer now reads the shell's own `dm/shell_info.txt` and stops at pack time
  with what to do, instead of leaving it for the phone to find.
- **First launch takes a while**: the phone compiles every shader once. Hades II's 140 shaders take about 5 s; bigger titles
  take minutes (the progress page estimates). The system caches the result, so later launches start immediately.
- To change a setting on the device without repacking, put `KEY=VALUE` lines in the app's `Documents/env.txt`.
- If it crashes, the host writes `Documents/log.txt` — in almost every case that file names the reason.
- Packing needs **disk space of roughly twice the NSP size**: the extracted RomFS, the staged app and the IPA coexist. The
  temporary files are then removed automatically (`--keep-work` / `--clean`, see above).

## Repository layout

Only the first two entries have to exist for **packing**; the rest is what they depend on, plus what builds the shell.

```
scripts/nxn_pack.py              the packer; it lives in the repository, with dm/ beside scripts/
dm/                              everything packing needs -- nothing works without it:
dm/games/<title ID>/             each supported game's parameters (modules, memory layout, rewriter and shader tables)
dm/tools/                        the rewriter (patch_nso.py), guest_dylib.py, nacp.py
dm/gfx/tools/                    the shader chain (shader_split, dmsh_build, nometal_run…)
dm/host/ dm/ios/                 host and iOS app sources (used to build the shell)
dm/ios/tools/shell_build.sh      builds the shell (CI, needs the macOS 26 SDK)
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

**The memory limit** is credited to **[LNPANDY/nxnative-romfs-archive](https://github.com/LNPANDY/nxnative-romfs-archive)**
(MIT): `com.apple.developer.kernel.increased-memory-limit` has to be inside a placeholder ad-hoc signature, because an
unsigned binary has no signature for an install tool to read it from — declaring it in the project alone does nothing. The
measurements behind this (about 3,375 MB without it, Tears of the Kingdom killed at 3,342 MB resident) and which install
tools keep the entitlement are theirs as well. The build-time signing here (`dm/ios/DmIOS.entitlements` and the `codesign`
step in `shell_build.sh`) is written for this fork; no code was copied.

`nx_extract` uses **[LibHac](https://github.com/Thealexbarney/LibHac)**; the shader translator embeds Ryujinx's shader library;
shaders are translated with **[SPIRV-Cross](https://github.com/KhronosGroup/SPIRV-Cross)**.

**License: MIT**, the same as upstream. [LICENSE](LICENSE) is upstream's own file and carries the original copyright notice
(© 2026 jhaizhou — nxnative kept it from d2r-mobile, whose generic parts it started from). If you redistribute this fork or a
build of it, keep that notice and this license with it. The MIT license covers the code only: game files, keys and any IPA you
pack are your own responsibility and are not covered by it.

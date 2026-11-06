#!/usr/bin/env python3
"""Address-space cuts for an sdk build nobody registered in dm/tools/sdk_patches.py, found by their instructions.

Every SDK build the repository has met needed the same two rewriter cuts once a game reserved address regions in earnest
(docs/reference/memory.md, "The SDK's address-region node area" and "Size-aligned regions exhaust the alias address space"):

  - node area: the AddressRegionManager constructor keeps about 1 GB (0x3fe00000) at the start of the alias region for its
    nodes, two `mov wN, #0x3fe00000` (`orr wN, wzr, #0x3fe00000` on SDK 7 / 8): the limit and the length it registers as
    occupied. Both become 62 MB (0x3e00000), as on the 20-odd registered builds.
  - size-class alignment (before SDK 20): VammManager::AllocateAddressRegion, just after the constructor, aligns a region of
    4 MB to 32 MB to 4 MB, one of 32 MB to 1 GB to 32 MB and a larger one to 1 GB (three movs within 16 bytes). They become
    2 MB, as SDK 20 does (Sea of Stars' build). SDK 7 / 8 builds load only the 1 GB class, with orr wN, wzr, #0x40000000;
    it becomes 32 MB, as on DRAGON QUEST XI S's, Smash's and Unspottable's builds.

Unity games then stop writing at NULL + pool − 0x20 once the alias region's high-water mark reaches its end while far less
is mapped (Toasterball: +4.26 of 4.38 GB with 1.51 GB mapped, a write at 0xffffe0). On hardware the alias region is 64 GB.

The packers (scripts/nxn_pack.py step_rewrite, scripts/build_ipa_from_nsp.py rewrite) call prepare() before rewriting: for an
unregistered sdk build in which the instructions are found exactly once, it writes <dst>/sdk_auto/patches.py with CUTS for
that build ID, which patch_nso.py loads from DM_GAMES_DIR like a provisional profile's patches.py, asserting the original
bytes as for any registered cut. A registered build keeps its own cuts; nothing found, nothing written.

    python sdk_auto_cuts.py <sdk NSO>          prints what it would cut
"""
import os
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import nso_syms   # noqa: E402

NODE = 0x3fe00000
NODE_NEW = 0x3e00000
MOVZ_NODE, ORR_NODE = 0x52a7fc00, 0x320b23e0          # movz wN, #0x3fe0, lsl 16 / orr wN, wzr, #0x3fe00000
MOV_62MB = 0x52a07c00                                  # movz wN, #0x3e0, lsl 16
ALIGN = {0x52a00800: '4 MB to 32 MB', 0x52a04000: '32 MB to 1 GB', 0x52a80000: '1 GB and more'}   # movz wN, #0x40 / #0x200 / #0x4000, lsl 16
MOV_2MB = 0x52a00400                                   # movz wN, #0x20, lsl 16
ORR_1GB, MOV_32MB = 0x320203e0, 0x52a04000             # orr wN, wzr, #0x40000000 (SDK 7 / 8) / movz wN, #0x200, lsl 16
PAIR_SPAN = 0x200                                      # the two node-area movs: 0x6c to 0xa0 apart on the registered builds
ALIGN_AFTER = 0x1000                                   # the alignment movs: 0x1fc past the constructor's first mov on Sea of Stars' build


def _hex(w): return struct.pack('<I', w).hex()


def cuts(img, text_end):
    """[(offset, original hex, new hex, reason)] for one image's text, [] unless each pattern is found exactly once."""
    words = struct.unpack_from(f'<{min(text_end, len(img)) // 4}I', img, 0)
    node = [(i * 4, w) for i, w in enumerate(words) if (w & ~0x1f) in (MOVZ_NODE, ORR_NODE) and w & 0x1f != 31]
    pairs = [(a, b) for k, a in enumerate(node) for b in node[k + 1:] if 0 < b[0] - a[0] <= PAIR_SPAN]
    if len(pairs) != 1: return []
    out = []
    for (off, w), what in zip(pairs[0], ('node area limit', 'length of the node area registered as an occupied region')):
        r = w & 0x1f; form = f'mov w{r}' if (w & ~0x1f) == MOVZ_NODE else f'orr w{r},wzr'
        out.append((off, _hex(w), _hex(MOV_62MB | r),
                    f'AddressRegionManager constructor (found by sdk_auto_cuts.py): {what} {form},#0x3fe00000 → mov w{r},#0x3e00000'))
    first = pairs[0][0][0]
    lo, hi = first // 4, min(len(words), (first + ALIGN_AFTER) // 4)
    hits = []
    for i in range(lo, hi):
        win = [(j * 4, words[j]) for j in range(i, min(i + 4, len(words))) if (words[j] & ~0x1f) in ALIGN and words[j] & 0x1f != 31]
        if {w & ~0x1f for _, w in win} == set(ALIGN) and len(win) == 3 and (words[i] & ~0x1f) in ALIGN: hits.append(win)
    orr = [(j * 4, words[j]) for j in range(lo, hi) if (words[j] & ~0x1f) == ORR_1GB and words[j] & 0x1f != 31]
    if not hits and len(orr) == 1:   # SDK 7 / 8: only the 1 GB class, as orr wN, wzr, #0x40000000; registered builds take it to 32 MB (as from 32 MB up)
        off, w = orr[0]; r = w & 0x1f
        out.append((off, _hex(w), _hex(MOV_32MB | r),
                    f'AllocateAddressRegion (found by sdk_auto_cuts.py): alignment of regions of 1 GB and more orr w{r},wzr,#0x40000000 → mov w{r},#0x2000000 (32 MB, as from 32 MB up)'))
    if len(hits) == 1:
        for off, w in hits[0]:
            r = w & 0x1f
            out.append((off, _hex(w), _hex(MOV_2MB | r),
                        f'AllocateAddressRegion (found by sdk_auto_cuts.py): alignment of regions of {ALIGN[w & ~0x1f]} → mov w{r},#0x200000 (2 MB, as SDK 20)'))
    return out


def nso_cuts(path):
    """(build ID, cuts) of an NSO file."""
    d = open(path, 'rb').read()
    return d[0x40:0x50].hex(), cuts(nso_syms.load(path), struct.unpack_from('<I', d, 0x18)[0])


def registered(bid, repo, games_dirs):
    """The patch files that already name this build (patch_nso.py stops when two claim it)."""
    files = [os.path.join(repo, 'dm/tools/sdk_patches.py')]
    for root in [os.path.join(repo, 'dm/games')] + list(games_dirs):
        if os.path.isdir(root): files += [os.path.join(root, n, 'patches.py') for n in sorted(os.listdir(root))]
    def names(f):
        with open(f, encoding='utf-8', errors='replace') as h: return bid in h.read()
    return [f for f in files if os.path.isfile(f) and names(f)]


def prepare(exe_dir, mods, dst, repo, games_dirs=()):
    """Write <dst>/sdk_auto/patches.py for an unregistered sdk build (or remove a stale one). Returns (folder to add to DM_GAMES_DIR or None, a line for the log, the cuts' text)."""
    pdir = os.path.join(dst, 'sdk_auto'); pf = os.path.join(pdir, 'patches.py')
    games_dirs = [g for g in games_dirs if os.path.realpath(g) != os.path.realpath(dst)]
    if os.path.isfile(pf): os.remove(pf)
    sdk = os.path.join(exe_dir, 'sdk')
    if 'sdk' not in mods or not os.path.isfile(sdk): return None, 'sdk auto cuts: no sdk module', ''
    bid, cs = nso_cuts(sdk)
    if registered(bid, repo, games_dirs): return None, f'sdk auto cuts: sdk build {bid} has registered patches', ''
    if not cs: return None, f'sdk auto cuts: sdk build {bid}: no node-area constructor found, nothing cut', ''
    os.makedirs(pdir, exist_ok=True)
    body = ''.join(f'    ({o:#x}, {ob!r}, {nb!r}, {why!r}),\n' for o, ob, nb, why in cs)
    text = f'# Written by dm/tools/sdk_auto_cuts.py for an sdk build no patch file names; regenerated on every rewrite.\nCUTS = {{\n  {bid!r}: [\n{body}  ],\n}}\n'
    with open(pf + '.tmp', 'w', encoding='utf-8', newline='\n') as f: f.write(text)
    os.replace(pf + '.tmp', pf)
    return dst, f'sdk auto cuts: sdk build {bid}: ' + ', '.join(f'{o:#x}' for o, *_ in cs) + f' ({len(cs)} cuts, {pf})', text


if __name__ == '__main__':
    if len(sys.argv) != 2: sys.exit(__doc__)
    bid, cs = nso_cuts(sys.argv[1])
    print(f'sdk build {bid}: {len(cs)} cuts')
    for o, ob, nb, why in cs: print(f'  {o:#x} {ob} → {nb}  {why}')

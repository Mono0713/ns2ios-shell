"""Write a provisional game profile on Windows, the way upstream's build_ipa_from_nsp.py does on a Mac for a game with no
profile (survey with nx_extract --manifest, then dm/games/profile_guess.py), and put it into the packer's dm/games.
The Mac-only heap check is skipped. Experimental: the game may not run.

Usage: python make_provisional.py <src dir> <tools dir> <prod.keys> <base.nsp> <update.nsp|-> <version e.g. v1376256> [title ID]
"""
import re
import shutil
import subprocess
import sys
from pathlib import Path

src, tools, keys, base, upd, ver = sys.argv[1:7]
src = Path(src)
sys.path[:0] = [str(src / 'scripts'), str(src / 'dm' / 'games'), str(src / 'dm' / 'tools')]
import build_ipa_from_nsp as bip
import profile_guess as pg
import nacp

bip.pg = pg
work = Path(base).parent / 'provisional_survey'
if work.exists():
    shutil.rmtree(work)
ex = work / 'extract'
r = subprocess.run([str(Path(tools) / 'nx_extract.exe'), keys, base, upd, str(ex), '--manifest'],
                   capture_output=True, text=True, encoding='utf-8', errors='replace')
print(r.stdout[-2000:], r.stderr[-2000:])
if r.returncode:
    sys.exit('nx_extract failed')
F = pg.facts_of(ex / 'ExeFS', ex / 'romfs_manifest.tsv')
dv = re.search(r'display version (\S+)', r.stdout)
# the title ID: given (Switch Pad passes the one the packer asked for), else from the file name's [0100…]
app = int(sys.argv[7], 16) if len(sys.argv) > 7 else int(Path(base).name.split('[')[1].split(']')[0], 16)
f = {'F': F, 'name': nacp.name(ex / 'control.nacp'), 'version': ver, 'display': dv.group(1) if dv else '?',
     'survey': 'Windows, make_provisional.py'}
pdir = work / 'profile' / ('%016X' % app)
bip.write_profile(pdir, app, f)
dest = src / 'dm' / 'games' / ('%016X' % app)
if dest.exists():
    shutil.rmtree(dest)
shutil.copytree(pdir, dest)
# The shader tables come out empty here (the shader split fills them while packing), but the packer reads an NVN shader
# table with only its header as "this game has no NVN shaders" and takes the Vulkan route. Leave them out, as Boomerang
# Fu's profile does, so the packer splits the shaders from the game files.
for n in ('shader_map.tsv', 'shader_facts.tsv', 'shader_pairs.tsv'):
    t = dest / n
    if t.is_file() and len([l for l in t.read_text(encoding='utf-8').splitlines() if l.strip() and not l.startswith('#')]) <= 1:
        t.unlink()
# The guessed app pool can be far bigger than what runs on an iPad: PICO PARK 2's guess (3.2 GB) closed the app right
# after the shaders, and both it and Boomerang Fu run with 1 GB. Start there; the launcher's memory pool slider can raise it.
POOL_CAP = 0x40000000
gt = dest / 'game.tsv'
rows = gt.read_text(encoding='utf-8').splitlines()
for i, l in enumerate(rows):
    k, _, v = l.partition('\t')
    if k == 'app_pool' and int(v.strip(), 16) > POOL_CAP:
        rows[i] = 'app_pool\t0x%X' % POOL_CAP
        print('app_pool %s -> 0x%X (provisional cap)' % (v.strip(), POOL_CAP))
# Used memory (mem_used): the game sizes its heap as pool - used memory, and the host refuses a heap that does not fit
# beside the modules (hle_svc.c SetHeapSize). Upstream sets mem_used after the rewrite (build_ipa_from_nsp.py
# refine_after_rewrite); the packer here only does that for a derived profile, so a provisional profile whose modules
# pass the default 64 MB got a 0.03 GB heap and an abort at the first allocation (Tricky Towers, Unity, SDK 4.5: 76 MB
# of modules; Cuphead upstream likewise). The rewritten modules are not there yet, so this estimates them from the
# originals: each module's image with bss (a far module's patch area sits 32 MB before its base instead, and its bss is
# counted apart), plus room for the patch area, rounded up to 16 MB as the packer's own fill_mem_used does.
if not any(l.partition('\t')[0] == 'mem_used' for l in rows):
    est = 0
    for name, m in F['mods'].items():
        if name == 'rtld':
            continue
        img = sum(m['sizes']) + (0x2000000 if m['far'] else m['bss'])
        est += img + max(0x400000, img // 10)
    if est > 0x4000000:
        used = (est + 0xFFFFFF) & ~0xFFFFFF
        rows.append('# modules of about %d MB with their patch areas: more than the default 64 MB of used memory' % (est >> 20))
        rows.append('mem_used\t0x%X' % used)
        print('mem_used 0x%X (modules of about %d MB)' % (used, est >> 20))
gt.write_text('\n'.join(rows) + '\n', encoding='utf-8')
print('profile installed:', dest)
print((dest / 'game.tsv').read_text(encoding='utf-8'))

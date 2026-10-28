"""Write a provisional game profile on Windows, the way upstream's build_ipa_from_nsp.py does on a Mac for a game with no
profile (survey with nx_extract --manifest, then dm/games/profile_guess.py), and put it into the packer's dm/games.
The Mac-only heap check is skipped. Experimental: the game may not run.

Usage: python make_provisional.py <src dir> <tools dir> <prod.keys> <base.nsp> <update.nsp|-> <version e.g. v1376256>
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
app = int(Path(base).name.split('[')[1].split(']')[0], 16)
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
print('profile installed:', dest)
print((dest / 'game.tsv').read_text(encoding='utf-8'))

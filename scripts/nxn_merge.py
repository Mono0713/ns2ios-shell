#!/usr/bin/env python3
"""Merge IPAs that scripts/nxn_pack.py made, one game each, into one IPA that holds them all; on the iPad its game picker
(dm/ios/Sources/GamePicker.swift) chooses which one to start.

    python scripts/nxn_merge.py -o Games.ipa "Boomerang Fu.ipa" "ANIMAL WELL.ipa"
    python scripts/nxn_merge.py -o Games.ipa --name "Switch 遊戲" Games-old.ipa Odyssey.ipa   # an IPA this script made counts as its games

The layout it writes (main.m reads it):

    Payload/DmIOS.app/                     the shell: its executable, Info.plist, dm/font, dm/shell_info.txt (from the first IPA, or --shell)
    Payload/DmIOS.app/games/<title ID>/    each game: dm/ (its tables, env.txt, launcher.json), msl/, romfs/, aoc/, pso/, game.json, icon.png
    Payload/DmIOS.app/Frameworks/Guest_<title ID>.framework/Guest    each game's program

One process runs one game: the host maps the game's program at fixed addresses and cannot take it out again, so the
launcher's Change game closes the app. Entries are copied as they are compressed in the source IPAs (no inflating and
deflating again), so merging costs about the time it takes to copy the files. The bundle ID is the same for every merge
(org.nxnative.games unless --bundle-id), so a merge with one more game installs over the last one and keeps the saves,
which are Documents/save/<title ID>.
"""
import argparse, io, json, os, plistlib, re, struct, sys, time, zipfile, zlib

L32, L16 = 0xFFFFFFFF, 0xFFFF
CHUNK = 16 << 20
SHELL_DM = ('font/', 'shell_info.txt', 'placeholder.tsv')   # the shell's own files under dm/; everything else there is the game's
GAME_DIRS = ('romfs/', 'msl/', 'aoc/', 'pso/')


def die(msg): sys.exit('[RED] nxn_merge: ' + msg)
def say(msg): print('nxn_merge: ' + msg, flush=True)


def app_dir(z):
    apps = sorted({n.split('/')[1] for n in z.namelist() if n.startswith('Payload/') and n.count('/') >= 2 and n.split('/')[1].endswith('.app')})
    if len(apps) != 1: die('%s holds %d apps, expected 1' % (z.filename, len(apps)))
    return 'Payload/%s/' % apps[0]


def shell_info(z, A):
    try: txt = z.read(A + 'dm/shell_info.txt').decode('utf-8', 'replace')
    except KeyError: return {}
    return dict(l.split('=', 1) for l in txt.splitlines() if '=' in l)


class Game:
    """One game in a source IPA: where its entries are and where they go."""
    def __init__(self, z, A, tid, name, version, language, icon, prefix=None, guest=None):
        self.z, self.A, self.tid, self.name, self.version, self.language, self.icon = z, A, tid, name, version, language, icon
        self.prefix = prefix      # an IPA this script made: the game's folder games/<tid>/ in it
        self.guest = guest        # the folder of its Guest framework in that IPA

    def entries(self, out_A):
        """(source ZipInfo, archive name in the merged IPA) for each entry of this game"""
        g = out_A + 'games/%s/' % self.tid
        fw = out_A + 'Frameworks/Guest_%s.framework/' % self.tid
        for i in self.z.infolist():
            n = i.filename
            if not n.startswith(self.A): continue
            r = n[len(self.A):]
            if self.prefix is not None:
                if r.startswith(self.prefix) and r[len(self.prefix):] not in ('', 'game.json', 'icon.png'): yield i, g + r[len(self.prefix):]
                elif r.startswith(self.guest) and r[len(self.guest):] == 'Guest': yield i, fw + 'Guest'
                continue
            if r.startswith('dm/') and len(r) > 3 and not r[3:].startswith(SHELL_DM): yield i, g + r
            elif r.startswith(GAME_DIRS): yield i, g + r
            elif r == 'Frameworks/Guest.framework/Guest': yield i, fw + 'Guest'


def games_in(z):
    """The games of one source IPA: one for an IPA from nxn_pack.py, each of games/ for one this script made"""
    A = app_dir(z)
    names = set(z.namelist())
    pl = plistlib.loads(z.read(A + 'Info.plist'))
    if any(n.startswith(A + 'games/') for n in names):   # a merged IPA
        out = []
        for n in sorted(names):
            m = re.fullmatch(re.escape(A) + r'games/([0-9A-Fa-f]{16})/game\.json', n)
            if not m: continue
            tid = m.group(1).upper(); j = json.loads(z.read(n))
            icon = z.read(A + 'games/%s/icon.png' % m.group(1)) if A + 'games/%s/icon.png' % m.group(1) in names else None
            out.append(Game(z, A, tid, j.get('name', tid), j.get('version', ''), j.get('language', 'en-US'), icon,
                            prefix='games/%s/' % m.group(1), guest='Frameworks/Guest_%s.framework/' % m.group(1)))
        return out
    if A + 'Frameworks/Guest.framework/Guest' not in names: die('%s has no game in it (no Frameworks/Guest.framework): pack the game with nxn_pack.py first' % z.filename)
    m = re.fullmatch(r'org\.nxnative\.([0-9a-f]{16})', pl.get('CFBundleIdentifier', ''))
    if not m: die('%s: bundle ID %r is not org.nxnative.<title ID>; was it made by nxn_pack.py?' % (z.filename, pl.get('CFBundleIdentifier')))
    tid = m.group(1).upper()
    icon = None
    for c in ('AppIcon60x60@3x.png', 'AppIcon60x60@2x.png'):
        if A + c in names: icon = z.read(A + c); break
    return [Game(z, A, tid, pl.get('CFBundleDisplayName', tid), pl.get('CFBundleShortVersionString', ''), pl.get('DMLanguage', 'en-US'), icon)]


class Out:
    """A zip writer that copies entries without inflating them: their compressed bytes, CRC and sizes as the source has them"""
    def __init__(self, path):
        self.f, self.pos, self.cd, self.names = open(path, 'wb', buffering=1 << 20), 0, [], set()

    def w(self, b): self.f.write(b); self.pos += len(b)

    def _entry(self, name, method, crc, csize, usize, dt, attr, src=None, data=b''):
        if name in self.names: die('%s twice in the merged IPA' % name)
        self.names.add(name)
        nb = name.encode('utf-8'); fl = 0 if name.isascii() else 0x800
        y, mo, d, h, mi, s = dt
        if y < 1980: y, mo, d, h, mi, s = 1980, 1, 1, 0, 0, 0
        t, dd = (h << 11) | (mi << 5) | (s // 2), ((y - 1980) << 9) | (mo << 5) | d
        z64 = csize >= L32 or usize >= L32
        ext = struct.pack('<HHQQ', 1, 16, usize, csize) if z64 else b''
        off = self.pos
        ver = 45 if z64 else 20
        self.w(struct.pack('<IHHHHHIIIHH', 0x04034B50, ver, fl, method, t, dd, crc, L32 if z64 else csize, L32 if z64 else usize, len(nb), len(ext)) + nb + ext)
        if src is not None:
            left = csize
            while left:
                b = src.read(min(CHUNK, left))
                if not b: die('%s ends early' % name)
                self.w(b); left -= len(b)
        elif data: self.w(data)
        zf = [v for v in (usize, csize, off) if v >= L32]
        cext = struct.pack('<HH%dQ' % len(zf), 1, 8 * len(zf), *zf) if zf else b''
        self.cd.append(struct.pack('<IHHHHHHIIIHHHHHII', 0x02014B50, 0x031E, 45 if zf else ver, fl, method, t, dd, crc, min(csize, L32), min(usize, L32),
                                   len(nb), len(cext), 0, 0, 0, attr, min(off, L32)) + nb + cext)

    def copy(self, z, i, name):
        """the entry i of the open zip z, under a new name"""
        z.fp.seek(i.header_offset)
        h = z.fp.read(30)
        if h[:4] != b'PK\x03\x04': die('%s: bad local header for %s' % (z.filename, i.filename))
        nl, el = struct.unpack('<HH', h[26:30])
        z.fp.seek(i.header_offset + 30 + nl + el)
        self._entry(name, i.compress_type, i.CRC, i.compress_size, i.file_size, i.date_time, i.external_attr, src=z.fp)

    def add(self, name, data, mode=0o644):
        attr = ((0o040755 if name.endswith('/') else 0o100000 | mode) << 16) | (0x10 if name.endswith('/') else 0)
        c = zlib.compressobj(6, zlib.DEFLATED, -15); zd = c.compress(data) + c.flush()
        method, body = (8, zd) if data and len(zd) < len(data) else (0, data)
        self._entry(name, method, zlib.crc32(data), len(body), len(data), time.localtime()[:6], attr, data=body)

    def close(self):
        cd_off, n = self.pos, len(self.cd); blob = b''.join(self.cd); self.w(blob)
        if n >= L16 or cd_off >= L32 or len(blob) >= L32:
            z = self.pos
            self.w(struct.pack('<IQHHIIQQQQ', 0x06064B50, 44, 0x031E, 45, 0, 0, n, n, len(blob), cd_off))
            self.w(struct.pack('<IIQI', 0x07064B50, 0, z, 1))
        self.w(struct.pack('<IHHHHIIH', 0x06054B50, 0, 0, min(n, L16), min(n, L16), min(len(blob), L32), min(cd_off, L32), 0))
        self.f.close()


def grid_icon(icons):
    """the app icon: up to four game icons in a 2 x 2 grid (Pillow), else the first game's icon as it is"""
    icons = [i for i in icons if i]
    if not icons: return None
    try:
        from PIL import Image
    except ImportError:
        return icons[0]
    try:
        ims = [Image.open(io.BytesIO(b)).convert('RGB') for b in icons[:4]]
        if len(ims) == 1: out = ims[0].resize((180, 180), Image.LANCZOS)
        else:
            out = Image.new('RGB', (180, 180), (24, 24, 28)); cell, gap = 86, 3
            for k, im in enumerate(ims):
                out.paste(im.resize((cell, cell), Image.LANCZOS), (gap + (k % 2) * (cell + 2 * gap), gap + (k // 2) * (cell + 2 * gap)))
        b = io.BytesIO(); out.save(b, 'PNG'); return b.getvalue()
    except Exception as e:
        say('note: the app icon is the first game\'s (%s)' % e)
        return icons[0]


def png_resize(png, px):
    try:
        from PIL import Image
        b = io.BytesIO(); Image.open(io.BytesIO(png)).convert('RGB').resize((px, px), Image.LANCZOS).save(b, 'PNG'); return b.getvalue()
    except Exception:
        return png


def main():
    ap = argparse.ArgumentParser(description='Merge single-game IPAs from nxn_pack.py into one IPA with a game picker')
    ap.add_argument('ipas', nargs='+', help='IPAs from nxn_pack.py (or from this script)')
    ap.add_argument('-o', '--out', required=True, help='the merged IPA')
    ap.add_argument('--name', default='Switch 遊戲', help='the app name on the home screen')
    ap.add_argument('--bundle-id', default='org.nxnative.games', help='keep it the same to install a new merge over the last one (saves stay)')
    ap.add_argument('--shell', help='a shell zip (or IPA) whose app to use instead of the first IPA\'s')
    a = ap.parse_args()
    for f in (sys.stdout, sys.stderr):   # a game name a Windows console's code page cannot show must not stop the merge
        try: f.reconfigure(errors='replace')
        except Exception: pass
    t0 = time.time()

    zs = [zipfile.ZipFile(p) for p in a.ipas]
    games, seen = [], {}
    for z in zs:
        for g in games_in(z):
            if g.tid in seen: die('%s is in both %s and %s: give each game once' % (g.name, seen[g.tid], z.filename))
            seen[g.tid] = z.filename; games.append(g)
    if len(games) < 2: say('only one game: the picker is skipped and it starts at once')

    sz = zipfile.ZipFile(a.shell) if a.shell else zs[0]
    SA = app_dir(sz)
    info = shell_info(sz, SA)
    if info.get('MULTI') != '1':
        die('the shell in %s cannot run several games (dm/shell_info.txt has no MULTI=1): use a shell from %s or later, '
            'with --shell or by packing the first game with it' % (sz.filename, 'the multi-game build'))
    for z in zs:
        o = shell_info(z, app_dir(z)).get('SOURCE_SHA')
        if o and o != info.get('SOURCE_SHA'):
            say('note: %s was packed with shell %s, the merged IPA uses %s; repack it if it does not start' % (os.path.basename(z.filename), o[:7], info.get('SOURCE_SHA', '?')[:7]))

    out_A = 'Payload/DmIOS.app/'
    part = a.out + '.partial'
    o = Out(part)
    try:
        # the shell: everything of its app but the game's parts and the signature
        for i in sz.infolist():
            n = i.filename
            if not n.startswith(SA): continue
            r = n[len(SA):]
            if r.startswith(('_CodeSignature/', 'games/', 'Frameworks/', 'romfs/', 'msl/', 'aoc/', 'pso/')) or r in ('embedded.mobileprovision', 'Info.plist') or r.startswith('AppIcon'): continue
            if r.startswith('dm/') and len(r) > 3 and not r[3:].startswith(SHELL_DM): continue
            o.copy(sz, i, out_A + r)
        for d in ('Payload/', out_A):
            if d not in o.names: o.add(d, b'')
        # Info.plist: the merged app's identity
        pl = plistlib.loads(sz.read(SA + 'Info.plist'))
        pl['CFBundleIdentifier'] = a.bundle_id
        pl['CFBundleDisplayName'] = a.name
        # CFBundleName names the App ID that signing registers with Apple, which takes letters, digits and spaces only:
        # install tools strip the rest, so a Chinese name leaves it empty and Apple refuses it ("No value was provided for
        # the parameter 'appIdName'"). The home screen shows CFBundleDisplayName, which keeps the name as given.
        pl['CFBundleName'] = re.sub(r'\s+', ' ', re.sub(r'[^A-Za-z0-9 ]', '', a.name)).strip() or 'NX Games'
        pl['CFBundleShortVersionString'] = pl['CFBundleVersion'] = time.strftime('%Y.%m%d.%H%M')
        pl.pop('DMLanguage', None)   # each game's own, from its game.json (main.m)
        icon = grid_icon([g.icon for g in games])
        if icon:
            o.add(out_A + 'AppIcon60x60@3x.png', icon); o.add(out_A + 'AppIcon60x60@2x.png', png_resize(icon, 120))
            pl['CFBundleIcons'] = {'CFBundlePrimaryIcon': {'CFBundleIconFiles': ['AppIcon60x60']}}
        o.add(out_A + 'Info.plist', plistlib.dumps(pl))
        o.add(out_A + 'Frameworks/', b''); o.add(out_A + 'games/', b'')
        # each game
        for g in games:
            say('%s %s (%s)' % (g.name, g.version, g.tid))
            o.add(out_A + 'games/%s/' % g.tid, b'')
            o.add(out_A + 'Frameworks/Guest_%s.framework/' % g.tid, b'')
            n_guest = 0
            for i, name in g.entries(out_A):
                o.copy(g.z, i, name); n_guest += name.endswith('/Guest')
            if n_guest != 1: die('%s: its Guest library is missing' % g.name)
            fw = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Guest</string>
<key>CFBundleIdentifier</key><string>%s.guest.%s</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleName</key><string>Guest</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>MinimumOSVersion</key><string>26.0</string>
<key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
</dict></plist>
''' % (a.bundle_id, g.tid.lower())
            o.add(out_A + 'Frameworks/Guest_%s.framework/Info.plist' % g.tid, fw.encode('utf-8'))
            o.add(out_A + 'games/%s/game.json' % g.tid, json.dumps({'id': g.tid, 'name': g.name, 'version': g.version, 'language': g.language}, ensure_ascii=False, indent=1).encode('utf-8'))
            if g.icon: o.add(out_A + 'games/%s/icon.png' % g.tid, g.icon)
        o.close()
    except BaseException:
        o.f.close(); os.unlink(part); raise
    os.replace(part, a.out)
    say('%d games -> %s (%.2f GB) in %.0f s' % (len(games), a.out, os.path.getsize(a.out) / 2**30, time.time() - t0))


if __name__ == '__main__': main()

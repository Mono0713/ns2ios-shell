#!/usr/bin/env python3
"""Guest.framework/Guest with the game's NRO modules too: guest_dylib.py's library plus the NRO table the loader reads (loader.c nro_pieces), for a game that loads NROs at run time with
nn::ro (Super Mario Party Jamboree: 139 in nro/NX_Release; Super Smash Bros. Ultimate: 98 in data.arc). scripts/nxn_pack.py collects and rewrites them (dm/tools/nro_collect.py,
patch_nso.py) and lists them in nro.tsv beside the modules; without them in the library the game aborts at its first ro::LoadModule ("no rewritten NRO with SHA-256 …").

The layout is gen_embed.py's (the iOS executable embeds NROs the same way): a Mach-O file has at most 255 sections, so the NROs do not get three sections each. Their pieces follow each
other, each 16K aligned, in __TEXT,__dm_nro_x0 / __DM_NRO_W,__img / __TEXT,__dm_nro_x1, and __DATA,__dm_nro_tab lists them: per module 32 bytes of name, then the offset and length of its
x0, W and x1 pieces in their sections (u64 each). Rows named 'refused' (an online SDK the host never loads) have no module.

A separate file from guest_dylib.py on purpose: PACK_ABI (dm/tools/pack_abi.py) hashes guest_dylib.py, and a game without NROs gets the very same library as before (nxn_pack.py calls
guest_dylib.write for it), so the packages already converted stay mergeable. A package with NROs needs a shell whose loader skips the NRO sections when it lists the modules (loader.c
dm_shell_modules); an older shell took "_nro_" for a module and stopped.
Usage: guest_nro.py <build output directory> <output directory> <module name...>"""
import os, struct, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import guest_dylib as gd
from guest_dylib import PG, r16


def nro_names(out):   # the NROs nro.tsv lists, without the refused rows; [] without a manifest
    tab = os.path.join(out, 'nro.tsv')
    if not os.path.exists(tab): return []
    return [ln.split('\t')[0] for ln in open(tab, encoding='utf-8') if ln.strip() and not ln.startswith('#') and not ln.startswith('refused\t')]


def pieces(out, n):   # the module's image and its (x0, W, x1) pieces as bytes, each padded to whole pages: the same cut as guest_dylib.build
    hdr = dict(l[2:].split() for l in open(os.path.join(out, n + '.fixups.tsv')) if l.startswith('# '))
    te, po = int(hdr['TEXT_END'], 16), int(hdr['PATCH_OFF'], 16)
    img = open(os.path.join(out, n + '.patched.bin'), 'rb').read(); sz = len(img); a, end = r16(te), r16(sz)
    cut = lambda lo, hi: img[lo:min(hi, sz)].ljust(hi - lo, b'\0')
    if po < 0:
        fil = int(hdr['FILE_IMAGE_LEN'], 16)
        assert a <= fil <= sz, (n, hex(a), hex(fil), hex(sz))
        return cut(0, a), cut(a, fil), cut(fil, end)
    assert po % PG == 0 and a <= po <= end, (n, hex(te), hex(po), hex(sz))
    return cut(0, a), cut(a, po), cut(po, end)


def build(out, names, nros):
    text, wsegs = [], []
    for n in names:
        x0, w, x1 = pieces(out, n)
        text += [('__dm%sx0' % n, x0), ('__dm%sx1' % n, x1)]
        wsegs.append(('__DM%sW' % n, w))
    rows, cat = [], [b'', b'', b'']
    for n in nros:
        assert '_' not in n and len(n) < 32, n
        ps = pieces(out, n); row = [n]
        for i, p in enumerate(ps): row += [len(cat[i]), len(p)]; cat[i] += p
        rows.append(row)
    text += [('__dm_nro_x0', cat[0]), ('__dm_nro_x1', cat[2])]
    wsegs.append(('__DM_NRO_W', cat[1]))
    tab = b''.join(r[0].encode().ljust(32, b'\0') + struct.pack('<6Q', *r[1:]) for r in rows)
    off = PG; tsects = []; body = b''
    for sn, b in text:
        if not b and sn.startswith('__dm_nro'): b = bytes(PG)   # no NRO has a patch area: the section still gets a page, so getsectiondata finds it (a module's empty piece stays empty, as in guest_dylib)
        tsects.append((sn, off, len(b), 0x80000400)); body += b; off += len(b)
    cmds = [gd.segment('__TEXT', 0, off, 0, off, 5, tsects)]; tsz = off
    for sn, b in wsegs:
        if not b and sn == '__DM_NRO_W': b = bytes(PG)
        cmds.append(gd.segment(sn, off, len(b), off, len(b), 3, [('__img', off, len(b), 0)])); body += b; off += len(b)
    tb = tab.ljust(r16(len(tab)), b'\0')
    cmds.append(gd.segment('__DATA', off, len(tb), off, len(tb), 3, [('__dm_nro_tab', off, len(tab), 0)])); body += tb; off += len(tb)
    strtab = b'\0' * 8
    cs_off = (off + len(strtab) + 15) & ~15; cs_size = (((cs_off // 4096 + 1) * 52 + 4095) & ~4095) + 0x40000
    import hashlib
    uuid = hashlib.sha256(body).digest()[:16]
    cmds += [gd.segment('__LINKEDIT', off, r16(cs_off + cs_size - off), off, cs_off + cs_size - off, 1, []),
             gd.dylib_cmd(0xd, b'@rpath/Guest.framework/Guest'),
             struct.pack('<II10I', 0x80000022, 48, *([0] * 10)),
             struct.pack('<IIIIII', 0x2, 24, off, 0, off, len(strtab)),
             struct.pack('<II18I', 0xb, 80, *([0] * 18)),
             struct.pack('<II16s', 0x1b, 24, uuid),
             struct.pack('<IIIIII', 0x32, 24, 2, gd.MIN_IOS, gd.MIN_IOS, 0),
             gd.dylib_cmd(0xc, b'/usr/lib/libSystem.B.dylib'),
             struct.pack('<IIII', 0x1d, 16, cs_off, cs_size)]
    lc = b''.join(cmds); assert 32 + len(lc) <= PG, 'load commands pass the first page'
    mh = struct.pack('<IiiIIIII', 0xfeedfacf, 0x0100000c, 0, 6, len(cmds), len(lc), 0x00100085, 0)
    data = ((mh + lc).ljust(PG, b'\0') + body + strtab).ljust(cs_off, b'\0')
    return (data + gd.adhoc_sig(data, tsz)).ljust(cs_off + cs_size, b'\0')


def write(out, dst, names, bundle_id='local.guest'):
    """guest_dylib.write, with the NROs of <out>/nro.tsv when it lists any; without, exactly guest_dylib's library. → (framework path, bytes, NRO count)"""
    nros = nro_names(out)
    if not nros:
        fw, n = gd.write(out, dst, names, bundle_id); return fw, n, 0
    fw = os.path.join(dst, 'Guest.framework'); os.makedirs(fw, exist_ok=True)
    data = build(out, names, nros)
    with open(os.path.join(fw, 'Guest'), 'wb') as f: f.write(data)
    with open(os.path.join(fw, 'Info.plist'), 'w', encoding='utf-8', newline='\n') as f: f.write(gd.INFO_PLIST % bundle_id)
    return fw, len(data), len(nros)


if __name__ == '__main__':
    if len(sys.argv) < 4: sys.exit(__doc__)
    fw, n, k = write(sys.argv[1], sys.argv[2], sys.argv[3:])
    print('%s: %d bytes, %d NROs' % (fw, n, k))

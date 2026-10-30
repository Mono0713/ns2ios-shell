#!/usr/bin/env python3
"""The package format a shell reads, as one short hash: PACK_ABI in dm/shell_info.txt.

A game package (an IPA scripts/nxn_pack.py made, one game) carries the shell_info.txt of the shell it was packed with,
so it carries this value too. scripts/nxn_merge.py puts game packages into a newer shell only when the values match, and
Switch Pad names its packages by it, so a shell whose host changed but whose package format did not (most updates: an
HLE fix, a launcher change) reuses every package already converted instead of converting the whole library again.

What it covers: the module rewriter (its call sites and fixup tables are what the host's loader and gates read), the
Guest framework it is wrapped in, and the gate kinds host/hle.c dispatches. Anything else a package holds whose format
the host reads (the shader library records, the tables under dm/, the romfs layout) is covered by PACK_FORMAT below:
bump it in the same commit as a change that makes old packages unreadable.

    python3 dm/tools/pack_abi.py          prints the value
"""
import hashlib, os, re, sys

PACK_FORMAT = 1
HERE = os.path.dirname(os.path.abspath(__file__))
FILES = ('patch_nso.py', 'nso_asm.py', 'nso_code.py', 'guest_dylib.py')


def gates(root):
    src = open(os.path.join(root, 'host', 'hle.c'), encoding='utf-8').read()
    return ' '.join(re.findall(r'strcmp\(kind, "([a-z]+)"\)', src))


def pack_abi():
    root = os.path.dirname(HERE)   # dm/
    h = hashlib.sha256(b'PACK_FORMAT=%d\n' % PACK_FORMAT)
    h.update(('GATES=%s\n' % gates(root)).encode())
    for f in FILES:
        h.update(f.encode() + b'\n')
        h.update(open(os.path.join(HERE, f), 'rb').read().replace(b'\r\n', b'\n'))   # a Windows checkout reads the same
    return h.hexdigest()[:12]


if __name__ == '__main__':
    print(pack_abi())

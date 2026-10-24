#!/usr/bin/env python3
"""Keep the packer's copies in step with the tree the shell is built from.

The shell is built from upstream's tree plus this fork's patches (`.shell-overlay.txt`), but the packer a user runs reads
this repository's own copies of dm/tools, dm/gfx/tools and dm/games. Nothing compared the two, so the shell could be
current while the packer's rewriter was months old -- silently, until a game needed something the snapshot did not have.

    python3 dm/tools/packer_sync.py <fork> <tree>            # report drift, exit 1 when there is any
    python3 dm/tools/packer_sync.py <fork> <tree> --sync     # copy upstream's version over ours

What it will not touch: files this fork patches or adds (the "~" and "+" entries -- those need a human when upstream
moves them), the prebuilt translator, the toolchain lock, and the per-profile build outputs upstream does not commit.
"""
import os
import shutil
import sys

TOPS = ('dm/tools', 'dm/gfx/tools', 'dm/games')
ALWAYS_SKIP = {'dm/gfx/tools/dmsh_xlate_bin', 'dm/gfx/tools/dmsh_chain.lock'}
SKIP_NAMES = {'c1_full.tsv', 'cb_extent.tsv', 'dmsh_chain.h'}   # made per profile at build time, not sources


def ours(fork):
    keep = set(ALWAYS_SKIP)
    for line in open(os.path.join(fork, '.shell-overlay.txt'), encoding='utf-8'):
        if line[:1] in ('~', '+'):
            keep.add(line[1:].split('#')[0].strip().rstrip('/'))
    return keep


def wanted(rel, keep):
    if os.path.basename(rel) in SKIP_NAMES or rel.endswith(('.pyc', '.old')): return False
    if '__pycache__' in rel or '/.git' in rel: return False
    return not (rel in keep or any(rel.startswith(k + '/') for k in keep))


def normal(b):
    return b.replace(b'\r\n', b'\n')


def walk(root):
    for top in TOPS:
        base = os.path.join(root, top)
        for d, _, files in os.walk(base):
            for f in files:
                full = os.path.join(d, f)
                yield os.path.relpath(full, root).replace(os.sep, '/')


def main(argv):
    if len(argv) < 2: sys.exit(__doc__)
    fork, tree, sync = argv[0], argv[1], '--sync' in argv
    keep = ours(fork)
    changed, added = [], []
    for rel in sorted(walk(fork)):
        if not wanted(rel, keep): continue
        mine, theirs = os.path.join(fork, rel), os.path.join(tree, rel)
        if not os.path.isfile(theirs): changed.append(rel + ' (gone upstream)'); continue
        if normal(open(mine, 'rb').read()) != normal(open(theirs, 'rb').read()): changed.append(rel)
    for rel in sorted(walk(tree)):
        if wanted(rel, keep) and not os.path.exists(os.path.join(fork, rel)): added.append(rel)

    for rel in changed + added:
        print(('sync ' if sync else 'drift ') + rel)
    if sync:
        for rel in changed:
            theirs = os.path.join(tree, rel)
            if os.path.isfile(theirs):
                dst = os.path.join(fork, rel)
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                with open(theirs, 'rb') as a, open(dst, 'wb') as b: b.write(normal(a.read()))
        for rel in added:
            dst = os.path.join(fork, rel)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            with open(os.path.join(tree, rel), 'rb') as a, open(dst, 'wb') as b: b.write(normal(a.read()))
        print('%d updated, %d added' % (len([c for c in changed if 'gone upstream' not in c]), len(added)))
        return 0

    print('%d file(s) differ, %d upstream-only' % (len(changed), len(added)))
    return 1 if (changed or added) else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

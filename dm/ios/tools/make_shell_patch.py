#!/usr/bin/env python3
"""Regenerate .shell-patches/*.patch from this tree against the upstream commit named in .shell-base.txt.

A patch is the unified diff between upstream's copy of one file and ours. Run this after editing a file that
.shell-overlay.txt lists with "~", and after moving the base commit:

    python dm/ios/tools/make_shell_patch.py dm/gfx/tools/dmsh_mtlcache.py
    python dm/ios/tools/make_shell_patch.py --all

Then check that it still applies, and commit both the file and its patch:

    git -C <a clone of upstream at the base commit> apply --check <this repo>/.shell-patches/xxx.patch

Why not diff the working tree against a clone: the checkout here is often CRLF while upstream is LF, which would show
every line as changed. Both sides are normalised to LF, because the patch is applied to upstream's LF files.
"""
import difflib, os, re, sys, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
PATCHES = os.path.join(ROOT, '.shell-patches')
BASE_FILE = os.path.join(ROOT, '.shell-base.txt')
UPSTREAM = 'https://raw.githubusercontent.com/seedds/nxnative/{rev}/{path}'
PREFIX = re.compile(r'^[+~]\s*')


def base_commit():
    with open(BASE_FILE, encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if re.fullmatch(r'[0-9a-f]{40}', line):
                return line
    sys.exit('.shell-base.txt names no 40-character commit')


def modified_files():
    """The "~" entries of the overlay: files this fork changes inside files upstream already has."""
    out = []
    with open(os.path.join(ROOT, '.shell-overlay.txt'), encoding='utf-8') as f:
        for line in f:
            line = line.split('#', 1)[0].strip()
            if line.startswith('~'):
                out.append(PREFIX.sub('', line).strip())
    return out


def read_lf(path):
    with open(path, 'rb') as f:
        return f.read().replace(b'\r\n', b'\n').decode('utf-8', 'surrogateescape')


def patch_name(path):
    return os.path.join(PATCHES, path.replace('/', '__') + '.patch')


def make(path, rev):
    ours = os.path.join(ROOT, path)
    if not os.path.isfile(ours):
        print(f'  skip {path}: not in this tree')
        return False
    url = UPSTREAM.format(rev=rev, path=path)
    try:
        theirs = urllib.request.urlopen(url, timeout=60).read().replace(b'\r\n', b'\n').decode('utf-8', 'surrogateescape')
    except Exception as e:                                    # noqa: BLE001 - any fetch failure is the same message
        print(f'  FAIL {path}: cannot fetch {url}: {e}')
        return False
    a, b = theirs.splitlines(True), read_lf(ours).splitlines(True)
    if a == b:
        print(f'  same {path}: identical to upstream at {rev[:7]}, no patch written')
        return False
    diff = list(difflib.unified_diff(a, b, fromfile=f'a/{path}', tofile=f'b/{path}', n=3))
    if not diff:
        print(f'  same {path}: only the trailing newline differs')
        return False
    os.makedirs(PATCHES, exist_ok=True)
    with open(patch_name(path), 'w', encoding='utf-8', newline='\n') as f:
        f.write(f'diff --git a/{path} b/{path}\n')
        f.writelines(diff)
    print(f'  wrote {os.path.relpath(patch_name(path), ROOT)}  ({sum(1 for l in diff if l.startswith("+"))-1} added,'
          f' {sum(1 for l in diff if l.startswith("-"))-1} removed)')
    return True


def main(argv):
    rev = base_commit()
    paths = modified_files() if argv[:1] == ['--all'] else argv
    if not paths:
        sys.exit('name one or more files, or --all for every "~" entry in .shell-overlay.txt')
    print(f'base {rev}\n')
    ok = [p for p in paths if make(PREFIX.sub('', p).strip(), rev)]
    print(f'\n{len(ok)} patch(es) written. Both the file and its patch belong in the same commit.')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

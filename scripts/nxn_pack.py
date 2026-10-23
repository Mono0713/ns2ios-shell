#!/usr/bin/env python3
"""Pack the game-free shell and your own game files into an installable IPA, on Windows, Linux or macOS.

No Mac, no Xcode and no paid Apple developer account: the shell (built once by dm/ios/tools/shell_build.sh, or downloaded
from the Build shell workflow) supplies the app, this script supplies the game. Apple's two Mac-only steps -- `xcrun metal`
and `xcodebuild` -- are the ones the shell split removed.

Usage:
  python scripts/nxn_pack.py <shell.zip> <NSP folder> -k <prod.keys> [-o out.ipa] [-p vN] [--stop-after STEP]
  python scripts/nxn_pack.py --clean <NSP folder>          # remove what an earlier run left behind, and exit

  <NSP folder>   one game's files: the base game (.nsp, or a cartridge dump .xci) plus every update the game profile's
                 shader_versions lists (see dm/games/<title ID>/game.tsv). DLC NSPs are packed too when present.
  -k            prod.keys (also read from the KEYS environment variable)
  -p            the version to pack (default: the newest one in the folder)
  --stop-after  stop after a step, to bring the chain up one piece at a time. Steps:
                extract, rewrite, shaders, guest, assemble, pack
  --force       redo steps whose output already exists
  --keep-work   keep the working folder (<NSP folder>/<title ID>_pack) instead of removing it after a good pack, so a
                rerun reuses the extraction, the rewritten modules and the compiled shaders. Worth it when repacking the
                same game repeatedly; the folder is several times the size of the game.
  --clean       delete that working folder without packing anything

Requirements: Python 3.9+ with lz4, capstone, fonttools and pillow and the three executables from the release (nx_extract,
dmsh_xlate, spirv-cross) on PATH or in --tools. Every step says what is missing before it starts.

Only your own game files go in, and the IPA it produces contains them: it is for your own use, do not distribute it.
"""
import argparse, json, os, plistlib, re, shutil, struct, subprocess, sys, time, zipfile
from pathlib import Path

PY = sys.executable
HERE = Path(__file__).resolve().parent
REPO = HERE.parent
if not (REPO / 'dm').is_dir() and (HERE / 'dm').is_dir():
    REPO = HERE      # also works laid out flat, as nxn_pack.py next to the dm/ it drives
DM = REPO / 'dm'
GFX = DM / 'gfx' / 'tools'
IOS = DM / 'ios'
TOOLS = DM / 'tools'


def say(s): print('[%s] %s' % (time.strftime('%H:%M:%S'), s), flush=True)
def die(s): sys.exit('[x] ' + s)
def warn(s): print('[!] ' + s, flush=True)


def folder_size(p):
    """Bytes under p, without following a symlink out of it: the game's RomFS can be large and the count is only a report."""
    n = 0
    for root, dirs, files in os.walk(p, followlinks=False):
        for f in files:
            try: n += os.lstat(os.path.join(root, f)).st_size
            except OSError: pass
    return n


def tidy(work, keep_logs=True):
    """Remove what the pack no longer needs, and return the bytes freed.

    Everything in here is either derivable from the game files again (the extraction, the rewritten modules, the split
    shaders, the assembled stage tree) or a cache the next run rebuilds. logs/ can stay: it is a few KB, and it is the only
    thing that explains a package that misbehaves on the phone. Each child is removed through its own path, and only if it
    really is inside the work folder, so a symlinked RomFS cannot take anything else with it.
    """
    total = 0
    root = work.resolve()
    for d in sorted(work.iterdir()):
        if keep_logs and d.name == 'logs': continue
        if d.parent.resolve() != root:
            warn('not removing %s: it is not inside %s' % (d, work)); continue
        n = folder_size(d) if d.is_dir() and not d.is_symlink() else d.lstat().st_size
        try:
            if d.is_dir() and not d.is_symlink(): shutil.rmtree(d)
            else: d.unlink()
        except OSError as e:
            warn('could not remove %s (%s): leaving it' % (d.name, e)); continue
        total += n
        say('  removed %-12s %9.1f MB' % (d.name + ('/' if d.is_dir() else ''), n / 1048576))
    return total


def clean_folders(folder):
    """--clean: everything a previous run left in this folder, logs included."""
    if not folder.is_dir(): die('no such folder: %s' % folder)
    works = sorted(p for p in folder.iterdir() if p.is_dir() and p.name.endswith('_pack'))
    if not works: say('nothing to clean: %s holds no <title ID>_pack folder' % folder); return
    freed = 0
    for w in works:
        say('cleaning %s' % w.name)
        freed += tidy(w, keep_logs=False)
        try: w.rmdir()
        except OSError: pass
    say('freed %.1f MB' % (freed / 1048576))


def shell_stamp(shell):
    """What the shell says it can do: dm/shell_info.txt, written by dm/ios/tools/shell_build.sh. A shell from before that
    stamp grew these keys has an empty or partial answer, which is itself the answer."""
    with zipfile.ZipFile(shell) as z:
        names = [n for n in z.namelist() if n.startswith('Payload/') and n.endswith('/dm/shell_info.txt')]
        if not names: return {}
        txt = z.read(names[0]).decode('utf-8', 'replace')
    st = {}
    for line in txt.splitlines():
        if '=' in line:
            k, v = line.split('=', 1)
            st[k.strip()] = v.strip()
    return st


def check_shell(stamp):
    """Refuse a shell this packer cannot fill in sensibly. Both failures below build a package that is fine until it runs,
    so they are hard errors -- but only on a stamp that says so: a key that is missing means the shell predates the stamp,
    which is unknown rather than bad (the first shells shipped before it grew these keys)."""
    if not stamp:
        warn('this shell carries no dm/shell_info.txt, so it is not from this project\'s shell route: what the packer '
             'writes may not be what it reads. Use the shell from the release.')
        return
    if stamp.get('GUEST') == '0':
        die('this shell cannot load Frameworks/Guest.framework (it was built before the shell route): the game modules '
            'would never run. Use the shell from the release.')
    if stamp.get('ENV') == '0':
        die('this shell ignores dm/env.txt, so the game would get the placeholder memory layout instead of its own: the '
            'heap request it makes from it is what overflows the pool (SetHeapSize). Use the shell from the release.')
    missing = [k for k in ('GUEST', 'ENV', 'GATES') if k not in stamp]
    if missing:
        warn('this shell predates %s in dm/shell_info.txt, so it cannot be checked against this packer. If the app stops '
             'on the phone with "unknown gate kind ...", this is why: use the shell from the same release.' % ', '.join(missing))
    if stamp.get('MEM') != '1':
        # Not fatal: every game profile fits in 3,285 MiB, which an unentitled app is allowed. It shows up when a game needs
        # more than that, and then it is a memory kill with no crash log rather than a crash.
        warn('this shell carries no increased-memory-limit entitlement, so iOS caps the app at about 3,375 MB (the boot line '
             'in Documents/log.txt says which). The bigger games can be killed for memory on it: use the shell from the '
             'current release.')


def check_gates(stamp, patched, mods):
    """Every gate kind the rewriter put into a module must be one the shell dispatches.

    The rewriter turns an svc into a call the host looks up by kind (dm/host/hle.c). A shell built before a kind existed
    registers it as unknown and aborts while loading the modules -- on the phone, after a successful build, with "unknown
    gate kind spin". Catching it here costs a second and names the fix.
    """
    kinds = set()
    for m in mods:
        f = patched / (m + '.gates.tsv')
        if not f.is_file(): continue
        for line in f.read_text(errors='replace').splitlines():
            p = line.split('\t')
            if len(p) >= 2: kinds.add(p[1])
    if not kinds: return
    allowed = set(stamp.get('GATES', '').split())
    if not allowed:
        warn('the shell does not say which gate kinds it dispatches, and this game needs %s: if it stops while loading '
             'the modules with "unknown gate kind", it is too old for this packer' % ' '.join(sorted(kinds)))
        return
    missing = kinds - allowed
    if missing:
        die('this shell cannot dispatch the %s gate(s) this game needs (it dispatches: %s).\n'
            '    It is older than this packer: download the current shell from the release.'
            % (', '.join(sorted(missing)), ' '.join(sorted(allowed))))
    say('gates: %s (the shell dispatches: %s)' % (' '.join(sorted(kinds)), ' '.join(sorted(allowed))))


def run(cmd, env=None, cwd=None, log=None, what=None):
    """Run a command, echoing it and keeping its output if a log path is given."""
    if what: say(what)
    if os.environ.get('NXN_VERBOSE'): print('    $ ' + ' '.join(str(c) for c in cmd), flush=True)
    e = dict(os.environ, PYTHONUTF8='1')
    if env: e.update({k: str(v) for k, v in env.items()})
    t0 = time.time()
    if log:
        Path(log).parent.mkdir(parents=True, exist_ok=True)
        with open(log, 'w', encoding='utf-8', errors='replace') as f:
            r = subprocess.run([str(c) for c in cmd], env=e, cwd=str(cwd) if cwd else None, stdout=f, stderr=subprocess.STDOUT)
    else:
        r = subprocess.run([str(c) for c in cmd], env=e, cwd=str(cwd) if cwd else None)
    if r.returncode:
        tail = ''
        if log and Path(log).is_file():
            tail = '\n---- last lines of %s ----\n%s' % (log, '\n'.join(open(log, errors='replace').read().splitlines()[-25:]))
        die('%s failed (exit %d)%s' % (what or cmd[0], r.returncode, tail))
    if what: say('    done in %.1fs' % (time.time() - t0))
    return r


def which(*names):
    for n in names:
        p = shutil.which(n)
        if p: return p
    return None


# ---------------------------------------------------------------- environment

def check_env(keys_path, prebuilt=None):
    """Only what every step needs. Tools for a single step are checked when that step is reached, so the chain can be
    brought up piece by piece with --stop-after without installing everything first."""
    bad = []
    for m, pkg in (('lz4.block', 'lz4'), ('capstone', 'capstone'), ('fontTools', 'fonttools'), ('PIL', 'pillow')):
        try: __import__(m)
        except Exception: bad.append('Python package %s:  %s -m pip install %s' % (m, PY, pkg))
    try:
        import compression.zstd                                    # built in from Python 3.14
    except Exception:
        try: __import__('backports.zstd')
        except Exception: bad.append('Python package backports.zstd:  %s -m pip install backports.zstd' % PY)
    dotnet = which('dotnet') or (str(Path.home() / '.dotnet' / 'dotnet') if (Path.home() / '.dotnet' / 'dotnet').is_file() else None)
    if prebuilt:
        # nx_extract and the shader translator come prebuilt, so no .NET SDK is needed on this machine
        pass
    elif not dotnet:
        bad.append('.NET 10 SDK: https://dotnet.microsoft.com/download (or pass --tools with the prebuilt executables)')
    else:
        # having dotnet.exe proves nothing: a runtime-only install has no compiler and `dotnet build` fails later
        r = subprocess.run([dotnet, '--list-sdks'], capture_output=True, text=True)
        if not re.search(r'^10\.', (r.stdout or ''), re.M):
            bad.append('.NET 10 SDK (this dotnet has no 10.x SDK; found: %s)' % ((r.stdout or '').strip() or 'none'))
    if not Path(keys_path).is_file(): bad.append('prod.keys not found: %s' % keys_path)
    if bad: die('missing %d item(s):\n  - %s' % (len(bad), '\n  - '.join(bad)))
    return dotnet


def need_tool(name, why, hint):
    p = which(name)
    if not p: die('%s is needed to %s.\n    %s' % (name, why, hint))
    return p


# ---------------------------------------------------------------- profile

UPSTREAM_API = 'https://api.github.com/repos/seedds/nxnative/contents/dm/games/{tid}?ref=main'
UPSTREAM_RAW = 'https://raw.githubusercontent.com/seedds/nxnative/main/dm/games/{tid}/{name}'


def fetch_profile(tid):
    """A game upstream added after this copy of the repository was made: take its profile from upstream instead of refusing.

    The shell is game-agnostic, so a shell built this morning runs a game whose profile did not exist when this repository
    was cloned. The profile -- build IDs, module list, memory layout, the shader tables -- lives only in the packer, so
    without this a new game is unpackable here while the shell would happily run it. Returns True when the profile is now
    on disk; never raises, because the caller has a message for the failure anyway.
    """
    d = DM / 'games' / tid
    say('no local profile for %s: asking upstream for it' % tid)
    try:
        import urllib.request
        with urllib.request.urlopen(UPSTREAM_API.format(tid=tid), timeout=30) as r:
            entries = json.load(r)
        if not isinstance(entries, list): return False
        d.mkdir(parents=True, exist_ok=True)
        total = 0
        for e in entries:
            name = e.get('name', '')
            if e.get('type') != 'file' or not name or '/' in name: continue
            with urllib.request.urlopen(UPSTREAM_RAW.format(tid=tid, name=name), timeout=120) as r:
                data = r.read()
            (d / name).write_bytes(data)
            total += len(data)
        say('  got %d files, %.1f MB into %s' % (len(entries), total / 1048576, d))
        return (d / 'game.tsv').is_file()
    except Exception as e:                                   # noqa: BLE001 - offline is the same as "not available"
        warn('could not fetch the profile for %s (%s)' % (tid, e))
        return False


def load_profile(tid):
    """dm/games/<title ID>/game.tsv: key<TAB>value, several values per key, one `build` row per version."""
    d = DM / 'games' / tid
    f = d / 'game.tsv'
    if not f.is_file():
        fetch_profile(tid)
    if not f.is_file():
        die('no game profile for title ID %s (%s)\n'
            '    Supported games: %s\n'
            '    This one is neither here nor upstream: check the title ID (the packer reads it from the package itself), or '
            'use a shell and a packer that upstream has a profile for.'
            % (tid, f, ', '.join(sorted(p.name for p in (DM / 'games').iterdir() if (p / 'game.tsv').is_file()))))
    rows = {}
    for line in f.read_text(encoding='utf-8').splitlines():
        if not line.strip() or line.lstrip().startswith('#'): continue
        k, _, v = line.partition('\t')
        rows.setdefault(k.strip(), []).append(v)
    return d, rows



def one(rows, key, default=None):
    v = rows.get(key)
    return v[0] if v else default


# ---------------------------------------------------------------- NSP scanning

def tid_sidecar(xci):
    """`<file>.xci.tid` next to the dump: the title ID found by extracting it once.

    Without it, every run would extract the whole cartridge again just to find out what it is, because nothing inside a
    dump names it. It holds one line of hex.
    """
    return xci.with_name(xci.name + '.tid')


def probe_xci(nx, keys, xci, out):
    """The title ID of a cartridge dump, read by nx_extract.

    An XCI cannot be identified the way an NSP is: a dump carries no ticket (the keys sit in each NCA's own key area), and an
    NCA header -- where the title ID lives -- is encrypted with a key from prod.keys. nx_extract has both the keys and LibHac,
    so it extracts into `out` and reports `title <id>`; the extraction is the one the pack needs anyway, so nothing is done
    twice. Returns the title ID, or None.
    """
    out.mkdir(parents=True, exist_ok=True)
    r = subprocess.run([str(nx), str(keys), str(xci), '-', str(out)],
                       capture_output=True, text=True, encoding='utf-8', errors='replace')
    text = (r.stdout or '') + (r.stderr or '')
    (out / 'probe.log').write_text(text, encoding='utf-8', errors='replace')
    m = re.search(r'^title\s+([0-9a-fA-F]{16})', text, re.M)
    if r.returncode or not m:
        warn('nx_extract could not read %s (see %s): %s'
             % (xci.name, out / 'probe.log', (text.strip().splitlines() or ['no output'])[-1]))
        return None
    tid = m.group(1).upper()
    try: tid_sidecar(xci).write_text(tid + '\n', encoding='utf-8')
    except OSError: pass
    return tid


def nsp_meta(path):
    """Title ID, content type and version, read from the package itself.

    Two sources, in order of how much they tell us:
      1. the plaintext cnmt.xml next to the encrypted NCAs -- title ID, content type (Application / Patch / AddOnContent) and
         the numeric version, all in one place;
      2. the name of the .tik inside: a ticket is named after its rights ID, which is the title ID followed by the key
         generation, so its first 16 hex digits are the title ID. That covers packages whose tools dropped the XML (they
         often keep only cnmt.nca, which is encrypted). The version is then unknown and taken as 0.
    Returns None for an XCI (an HFS0 container without either) or a file it cannot parse."""
    try:
        with open(path, 'rb') as f:
            if f.read(4) != b'PFS0': return None
            n, strtab, _ = struct.unpack('<III', f.read(12))
            if not 0 < n < 4096: return None
            entries = [struct.unpack('<QQII', f.read(24)) for _ in range(n)]
            strtab_off, data_off = 0x10 + 24 * n, 0x10 + 24 * n + strtab
            tik_id = None
            for off, size, name_off, _r in entries:
                f.seek(strtab_off + name_off)
                nm = b''
                while True:
                    c = f.read(1)
                    if not c or c == b'\0': break
                    nm += c
                low = nm.lower()
                if low.endswith(b'.cnmt.xml') and 0 < size < (1 << 20):
                    f.seek(data_off + off)
                    t = f.read(size).decode('utf-8', 'replace')
                    mid = re.search(r'<Id>\s*0x([0-9A-Fa-f]{16})\s*</Id>', t)
                    mty = re.search(r'<Type>\s*(\w+)\s*</Type>', t)
                    mvr = re.search(r'<Version>\s*(\d+)\s*</Version>', t)
                    if mid:
                        return {'id': mid.group(1).upper(), 'type': mty.group(1) if mty else '',
                                'version': int(mvr.group(1)) if mvr else 0}
                elif low.endswith(b'.tik') and tik_id is None:
                    m = re.match(rb'([0-9a-fA-F]{16})', nm.rsplit(b'/', 1)[-1])
                    if m: tik_id = m.group(1).decode('utf-8').upper()
            if tik_id:
                return {'id': tik_id, 'type': '', 'version': 0}
    except Exception:
        pass
    return None


def name_tid(p):
    m = re.search(r'\[([0-9A-Fa-f]{16})\]', p.name)
    return m.group(1).upper() if m else None


def name_ver(p):
    m = re.search(r'\[v(\d+)\]', p.name)
    return 'v' + m.group(1) if m else None


def scan_nsps(folder):
    """Group the folder's files into one game: the base, its updates and its DLC.

    The title ID is taken from the ticket inside the NSP, so file names do not have to follow a pattern (the [XXXXXXXXXXXXX000]
    in a name is only a fallback). An update's title ID is the base game's plus 0x800 and a DLC's is plus 0x1000 + index, which
    is how the files are grouped -- so a folder holding a base game and its update is one game, not two.

    The version still comes from the [vN] in the name: the ticket carries no display version, and it is only used to tell
    updates apart (a base game is v0)."""
    nsps = sorted(list(folder.glob('*.nsp')) + list(folder.glob('*.xci')))
    nsz = sorted(folder.glob('*.nsz'))
    if nsz:
        die('%d NSZ file(s) in %s: this reads NSP and XCI only.\n'
            '    Unpack them first:  nsz -D "%s"   (needs your prod.keys)' % (len(nsz), folder, nsz[0].name))
    if not nsps: die('no .nsp or .xci in %s' % folder)
    apps = {}
    for p in nsps:
        if p.stat().st_size == 0: warn('skipping empty file %s' % p.name); continue
        meta = nsp_meta(p)
        if meta:
            tid, ver = meta['id'], 'v%d' % meta['version']
            kind = {'Application': 'base', 'Patch': 'update', 'AddOnContent': 'dlc'}.get(meta['type'], 'base')
        else:
            # an XCI, or an NSP without the metadata XML: fall back to the name, then to what an earlier run recorded, and
            # to the title ID's low bits for the kind
            tid, ver = name_tid(p), name_ver(p)
            if not tid:
                try: rec = tid_sidecar(p).read_text(encoding='utf-8').strip().upper()
                except OSError: rec = ''
                if re.fullmatch(r'[0-9A-F]{16}', rec):
                    tid = rec
                    say('using the title ID an earlier run recorded for %s' % p.name)
            if not tid:
                if p.suffix.lower() != '.xci':
                    warn('cannot read %s: no metadata inside and no [XXXXXXXXXXXXX000] in the name' % p.name)
                # an .xci saying nothing here is normal (a dump has no ticket and its NCA headers are encrypted): it is
                # identified by extracting it, which happens below when it is the only file in the folder
                continue
            low = int(tid, 16) & 0xFFF
            kind = 'base' if low == 0 else ('update' if low == 0x800 else 'dlc')
        base_id = int(tid, 16) - (int(tid, 16) & 0xFFF)   # updates sit at +0x800, DLC above +0x1000
        key = '%016X' % base_id
        a = apps.setdefault(key, {'base': None, 'updates': {}, 'dlc': [], 'all': []})
        a['all'].append((kind, ver, p))
        if kind == 'base': a['base'] = p
        elif kind == 'update': a['updates'][ver or 'v?'] = p
        else: a['dlc'].append(p)
    return apps


# ---------------------------------------------------------------- steps

def build_nx_extract(dotnet, work, tools_dir=None):
    names = ('nx_extract.exe', 'nx_extract')
    if tools_dir:
        for n in names:
            c = tools_dir / n
            if c.is_file(): say('using the prebuilt nx_extract: %s' % c); return c
    out = work / 'tools' / 'nx_extract'
    exe = out / ('nx_extract.exe' if os.name == 'nt' else 'nx_extract')
    if exe.is_file(): say('nx_extract already built'); return exe
    if not dotnet: die('no prebuilt nx_extract and no .NET SDK: pass --tools <folder> or install the SDK')
    run([dotnet, 'build', TOOLS / 'nx_extract', '-c', 'Release', '-o', out, '-v', 'quiet'],
        log=work / 'logs' / 'nx_extract_build.log', what='building nx_extract (.NET)')
    if not exe.is_file():
        cand = list(out.glob('nx_extract*'))
        if not cand: die('nx_extract did not appear in %s' % out)
        exe = cand[0]
    return exe


def step_extract(nx, keys, folder, picks, work, versions):
    ex = work / 'extract'
    ex.mkdir(parents=True, exist_ok=True)
    dirs = {}
    for ver in versions:
        dst = ex / ver
        if dst.is_dir() and (dst / 'ExeFS').is_dir(): say('reusing the extracted %s' % ver); dirs[ver] = dst; continue
        base, upd = picks[ver]
        tmp = ex / (ver + '.partial')
        shutil.rmtree(tmp, ignore_errors=True)
        run([nx, keys, base, upd if upd else '-', tmp], log=work / 'logs' / ('extract_%s.log' % ver),
            what='extracting %s (%s)' % (ver, base.name))
        tmp.replace(dst)
        dirs[ver] = dst
    return dirs


# Files a derived profile leaves out: the build makes all of these again from the packed version's own files.
DERIVED_SKIP = {'game.tsv', 'shader_map.tsv', 'shader_facts.tsv', 'shader_pairs.tsv', 'c1_full.tsv', 'cb_extent.tsv',
                'dmsh_chain.h', 'vk_capture.tsv'}


def module_build_id(nso):
    with open(nso, 'rb') as f:
        f.seek(0x40)
        return f.read(16).hex()


def check_build_ids(game, rows, ver, mods):
    """The build IDs of the extracted modules against the ones the profile registers for this version.

    A mismatch does not have to stop the pack: upstream derives a profile from the files and carries on ("Any version works"),
    which is what derive_profile below does. Returns the mismatches so main can decide, and whether there was a row at all."""
    want = {}
    for line in rows.get('build', []):
        f = line.split('\t')
        if f[0] != ver: continue
        for item in f[2:]:
            if '=' in item: k, v = item.split('=', 1); want[k] = v
    if not want:
        return ['the profile registers no build IDs for %s' % ver], False
    bad = []
    for m in mods:
        p = game / 'ExeFS' / m
        if not p.is_file(): bad.append('%s missing' % m); continue
        got = module_build_id(p)
        if m in want and got != want[m]: bad.append('%s %s (registered %s)' % (m, got, want[m]))
    return bad, True


def derive_profile(gdir, tid, ver, game, mods, dest, disp):
    """The profile for a version it was not brought up on, written into `dest` (outside the repository).

    Its keys as they are, with this version's own build row, package and shader versions; the shader tables, the chain header
    and the capture list are left out because the build makes them again from this version's files. Callers then put `dest`
    on DM_GAMES_DIR with DM_GAMES_FIRST=1, which every tool in the chain honours -- the same mechanism upstream uses for a
    provisional profile.
    """
    shutil.rmtree(dest, ignore_errors=True)
    dest.mkdir(parents=True, exist_ok=True)
    for p in gdir.iterdir():
        if p.is_file() and p.name not in DERIVED_SKIP:
            shutil.copyfile(p, dest / p.name)
    # The module list has to follow the files too: a build may ship fewer modules than the profile was brought up on
    # (Absolum 1.0.4 has no subsdk2), and a rewrite that is told to load one the dump does not have dies on the missing file.
    present = [q.name for q in (game / 'ExeFS').iterdir() if q.is_file() and q.name not in ('rtld', 'main.npdm')]
    order = lambda m: (m != 'main', 2 if m == 'sdk' else (1 if m.startswith('subsdk') and m[6:].isdigit() else 3),
                       int(m[6:]) if m.startswith('subsdk') and m[6:].isdigit() else 0)
    mods_now = sorted(present, key=order)
    row = '\t'.join(['build', ver, disp] + ['%s=%s' % (m, module_build_id(game / 'ExeFS' / m)) for m in mods_now])
    out, put = ['# Derived from %s for %s (%s), a version that profile was not brought up on:' % (gdir, ver, disp),
                '# its keys as they are, this version\'s build row and module list, and shader tables from its own files'], False
    for line in (gdir / 'game.tsv').read_text(encoding='utf-8').splitlines():
        if line.split('\t', 1)[0] in ('build', 'package', 'shader_versions', 'modules'):
            if not put:
                out += [row, 'package\t%s' % ver, 'shader_versions\t%s' % ver, 'modules\t%s' % ' '.join(mods_now)]
                put = True
            continue
        out.append(line)
    (dest / 'game.tsv').write_text('\n'.join(out) + '\n', encoding='utf-8')
    return dest


def load_rows(d):
    rows = {}
    for line in (d / 'game.tsv').read_text(encoding='utf-8').splitlines():
        if not line.strip() or line.lstrip().startswith('#'): continue
        k, _, v = line.partition('\t')
        rows.setdefault(k.strip(), []).append(v)
    return rows



def check_free_space(folder, factor=3.5):
    """Refuse to start when the disk cannot hold the peak.

    Packing keeps three copies of the game on disk at once -- the extraction, the assembled app tree and the IPA -- which
    measured 9.0 GiB for a 2.96 GiB cartridge dump, about 3x. Starting without that room fails halfway through the
    extraction, which leaves a partial tree of the same size to clean up, so say it up front instead.
    """
    src = sum(p.stat().st_size for p in folder.iterdir()
              if p.is_file() and p.suffix.lower() in ('.nsp', '.xci', '.nsz'))
    if not src: return                       # nothing recognised yet: scan_nsps says so with a better message
    need, free = int(src * factor), shutil.disk_usage(folder).free
    if free >= need:
        say('disk: %.1f GiB free, about %.1f GiB needed' % (free / 2**30, need / 2**30)); return
    die('not enough space on the disk holding %s: %.1f GiB free, about %.1f GiB needed.\n'
        '    %.1f GiB of game files, and packing holds three copies at once (the extraction, the assembled app and the '
        'IPA).\n    Free some space, or move the game folder to another disk.'
        % (folder, free / 2**30, need / 2**30, src / 2**30))


def fill_mem_used(patched, mods, gdir, rows):
    """The used memory GetInfo reports beside the heap: 64 MB unless the rewritten modules need more (dm/games/README.md).

    A profile that was brought up on one build can carry less than a later build's modules need, and a derived profile
    inherits exactly that. The game then sizes its heap as total - used, asks for more than the pool holds, and the SDK
    aborts during nninitStartup -- which is what Absolum 1.0.4 did: 138 MB of modules against a 64 MB default. Returns the
    value written, or None when the profile already has enough.
    """
    if one(rows, 'sys_resource'): return None                # with a system resource the heap is sized by the alias split
    total = sum((patched / m).stat().st_size for m in mods if (patched / m).is_file())
    have = one(rows, 'mem_used')
    if have and int(have, 0) >= total: return None
    if total <= 0x4000000 and not have: return None          # the default covers it
    value = '0x%X' % ((total + 0xFFFFFF) & ~0xFFFFFF)        # a 16 MB granule above the measured size
    lines = (gdir / 'game.tsv').read_text(encoding='utf-8').splitlines()
    out, done = [], False
    for line in lines:
        if line.split('\t', 1)[0] == 'mem_used':
            out.append('mem_used\t' + value); done = True
        else:
            out.append(line)
    if not done: out.append('mem_used\t' + value)
    (gdir / 'game.tsv').write_text('\n'.join(out) + '\n', encoding='utf-8')
    return value, total


def step_rewrite(exe_dir, mods, out, work, force=False):
    # patch_nso.py is pure Python (capstone + lz4): its stubs are hand-assembled machine code, not built at run time,
    # so no C compiler is needed here even though its comments mention clang.
    if not force and all((out / (m + '.patched.bin')).is_file() and (out / (m + '.fixups.tsv')).is_file() for m in mods):
        say('rewritten modules already there'); return
    out.mkdir(parents=True, exist_ok=True)
    for m in mods:
        run([PY, TOOLS / 'patch_nso.py', exe_dir / m, out, m],
            log=work / 'logs' / ('rewrite_%s.log' % m), what='rewriting %s' % m)


def step_shaders(game, prof_dir, tables, work, tid, force=False):
    """shader_split.py: pull the shaders out of the game files and produce the four tables. The rows must match the
    profile's (that is how we know the files are the version the profile was built from)."""
    pkg, tb = work / 'shader' / 'pkg', work / 'shader' / 'tables'
    if not force and (pkg / 'index.tsv').is_file() and all((tb / n).is_file() for n in tables):
        say('shader split already done'); return pkg, tb
    tb.mkdir(parents=True, exist_ok=True)
    names = ['shader_map.tsv', 'shader_facts.tsv', 'shader_pairs.tsv']
    run([PY, GFX / 'shader_split.py', game / 'RomFS', game / 'ExeFS' / 'main', pkg] + [tb / n for n in names],
        env={'DM_GAME': tid}, log=work / 'logs' / 'shader_split.log', what='splitting the shaders out of the game files')
    for n in names:
        a, b = tb / n, prof_dir / n
        if b.is_file():
            ra = [l for l in a.read_text(errors='replace').splitlines() if l and not l.startswith('#')]
            rb = [l for l in b.read_text(errors='replace').splitlines() if l and not l.startswith('#')]
            if ra != rb:
                # The profile's table was built on the machines upstream tested; ours is split from your files right now, which
                # is at least as accurate for the version you have. The build ID check above is the hard gate on the version.
                warn('%s differs from game profile %s\'s (a different build of the tables, or another game version): '
                     'using the one just split from your files' % (n, prof_dir.name))
    return pkg, tb


def step_translate(pkg, work, xlate, iosout, tid, force=False):
    """dmsh_build.py, with no metal compiler: nometal_run.py turns `xcrun metal` into a copy, so the "libraries" hold MSL
    source and the phone compiles them once on first launch. dmsh_build.py creates <iosout>/b-<chain version> itself."""
    # Completeness is decided by the per-shader results dmsh_build.py writes, not by "some file is there": a run that was
    # interrupted leaves libraries behind, and trusting them would ship a package that only fails on the phone.
    cache = work / 'shader' / 'cache'
    def done():
        marks = sorted(cache.glob('b-*/_b_build.json'))
        if not marks: return False
        try: res = json.load(open(marks[-1], encoding='utf-8'))
        except Exception: return False
        if not res or any(r.get('st') != 'ok' for r in res): return False
        d = iosout / marks[-1].parent.name
        have = {x.name for x in d.glob('*_b.metallib')} if d.is_dir() else set()
        return all(r['key'] + '_b.metallib' in have for r in res)
    if not force and done():
        say('shader libraries already there'); return
    need_tool('spirv-cross', 'translate SPIR-V to Metal Shading Language',
              'install Vulkan SDK 1.4.357.0 (its Bin/ holds spirv-cross.exe) or build SPIRV-Cross at tag vulkan-sdk-1.4.357.0')
    nometal = GFX / 'nometal_run.py'
    if not nometal.is_file():
        die('dm/gfx/tools/nometal_run.py is missing (it is what makes this work without Apple\'s compiler)')
    # dmsh_build.py refuses to start when the toolchain does not match dmsh_chain.lock, which on a machine using the
    # prebuilt executables it never will: register this machine first. That rewrites dmsh_chain.lock and the profile's
    # dmsh_chain.h -- the header is the compile-time constant only the Xcode route needs, and the shell reads the version
    # from the directory name, so neither value is used any further here.
    genv = {'XLATE': str(xlate), 'DM_GAME': tid}
    chk = subprocess.run([PY, nometal, GFX / 'dmsh_chain.py', '--check-tools'], capture_output=True, text=True,
                         env=dict(os.environ, PYTHONUTF8='1', **genv))
    if chk.returncode:
        say('the toolchain differs from dmsh_chain.lock: registering this machine')
        run([PY, nometal, GFX / 'dmsh_chain.py', '--update-lock'], env=genv,
            log=work / 'logs' / 'chain_lock.log', what='dmsh_chain --update-lock')
        warn('dmsh_chain.lock now describes this machine (do not commit it)')
    # dmsh_build.py refuses to start unless the game profile's dmsh_chain.h holds the chain version it computed, and that
    # header is per game: packing a second game on the same machine fails with "run --header first" if this only happens
    # when the toolchain lock changes. It reads the tables, so it costs nothing to do every time.
    run([PY, nometal, GFX / 'dmsh_chain.py', '--header'], env=genv,
        log=work / 'logs' / 'chain_header.log', what='dmsh_chain --header')
    run([PY, nometal, GFX / 'dmsh_build.py', pkg, work / 'shader' / 'cache'],
        env={'IOSOUT': iosout, 'XLATE': xlate, 'WORK': work, 'J': os.environ.get('J', '8'), 'DM_GAME': tid},
        log=work / 'logs' / 'shaders.log', what='translating shaders to Metal source')
    n = len(list(iosout.glob('b-*/*_b.metallib'))) if iosout.is_dir() else 0
    if not n: die('no shader libraries were produced (see %s)' % (work / 'logs' / 'shaders.log'))
    say('%d shader libraries' % n)


def step_guest(patched, mods, stage):
    sys.path.insert(0, str(TOOLS))
    import guest_dylib
    fw, n = guest_dylib.write(str(patched), str(stage / 'Frameworks'), mods)
    say('Frameworks/Guest.framework: %d bytes' % n)


def step_assemble(shell, stage, game, patched, mods, gdir, rows, name, version, tid, msl_dir, work):
    """Unpack the shell and put the game into it: guest library, MSL source, RomFS, tables, icon, identity."""
    # Move a previous stage aside instead of deleting it: this environment counts file deletions and refuses to go past a
    # threshold, which a 5000-file app tree trips instantly. Renaming keeps the build going; the old tree is reported so it
    # can be deleted by hand (it is several GB because the RomFS is copied into it).
    if stage.exists():
        old = stage.with_name('stage-old')
        if old.exists(): old = stage.with_name('stage-old-%d' % int(time.time()))
        stage.rename(old)
        warn('the previous stage tree was kept as %s (delete it when the build is confirmed)' % old.name)
    stage.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(shell) as z:
        apps = sorted({n.split('/')[1] for n in z.namelist() if n.startswith('Payload/') and n.count('/') >= 2 and n.split('/')[1].endswith('.app')})
        if len(apps) != 1: die('the shell holds %d apps, expected 1: %s' % (len(apps), apps))
        app = apps[0]
        if not any(n.startswith('Payload/%s/dm/' % app) for n in z.namelist()): die('this is not a shell (no dm/ inside): %s' % shell)
        z.extractall(stage)
    A = stage / 'Payload' / app
    say('shell unpacked: %s' % A.name)

    step_guest(patched, mods, A)
    for m in mods:
        for suf in ('.fixups.tsv', '.gates.tsv', '.cuts.tsv', '.obs.tsv'):
            s = patched / (m + suf)
            if s.is_file(): shutil.copyfile(s, A / 'dm' / s.name)

    # shader libraries: the directory name is the chain version, which the shell reads at run time
    if msl_dir.is_dir():
        dst = A / 'msl' / msl_dir.name
        shutil.copytree(msl_dir, dst)
        say('shader source for %d shaders -> msl/%s' % (len(list(dst.glob('*_b.metallib'))), msl_dir.name))

    shutil.copytree(game / 'RomFS', A / 'romfs', symlinks=True)
    say('RomFS in place')

    # tables the game profile carries (shader map, c1 list, warm-up list, uniform extents)
    for n in ('shader_map.tsv', 'pso_manifest.tsv', 'c1_full.tsv', 'cb_extent.tsv'):
        if (gdir / n).is_file(): shutil.copyfile(gdir / n, A / 'dm' / n)

    step_launcher(tid, patched, game, A, work)

    # The shell was built from the placeholder profile, so the memory layout baked into its host is the placeholder's. Write
    # the game's real values here: main.m turns dm/env.txt into environment variables before the host starts, and hle_svc.c
    # reads them. Getting this wrong does not crash immediately -- the game asks for the wrong heap size and aborts in
    # SetHeapSize (Hades II asked for pool - 64 MB instead of pool - 108 MB and overflowed the pool by 44 MB).
    mem_map = (('mem_reserve', 'DM_MEM_RESERVE'), ('mem_alias', 'DM_MEM_ALIAS'), ('mem_stack', 'DM_MEM_STACK'),
               ('app_pool', 'DM_APP_POOL'), ('mem_used', 'DM_MEM_USED'))
    env_lines = ['%s=%s' % (ev, one(rows, k)) for k, ev in mem_map if one(rows, k)]
    if env_lines:
        (A / 'dm' / 'env.txt').write_text('\n'.join(env_lines) + '\n', encoding='utf-8')
        say('dm/env.txt: ' + ', '.join(env_lines))

    # App identity: name, version, bundle ID, icon.
    #
    # The bundle ID has to be per game. iOS identifies an app by it, so every package carrying the shell's
    # org.nxnative.shell is the same app: installing the second game replaces the first, however different the two look on
    # the home screen. Upstream derives it from the title ID (build_ipa_from_nsp.py), which also keeps a repack of the same
    # game an update of it rather than a second copy.
    ip = A / 'Info.plist'
    try:
        with open(ip, 'rb') as f: pl = plistlib.load(f)
        pl['CFBundleIdentifier'] = 'org.nxnative.%016x' % int(tid, 16)
        pl['CFBundleDisplayName'] = name
        pl['CFBundleShortVersionString'] = version
        pl['CFBundleVersion'] = version
        pl['DMShowFPS'] = 'NO'
        pl['DMLanguage'] = os.environ.get('NXN_LANG', 'en-US')
        icon_src = game / 'icon.jpg'
        if icon_src.is_file():
            try:
                from PIL import Image
                im = Image.open(icon_src).convert('RGB')
                for suffix, px in (('@2x', 120), ('@3x', 180)):
                    im.resize((px, px), Image.LANCZOS).save(A / ('AppIcon60x60%s.png' % suffix))
                # Old-style icon declaration: actool (which builds Assets.car) is Mac-only, so the shell ships an empty
                # catalog and the PNGs are declared here instead.
                pl['CFBundleIcons'] = {'CFBundlePrimaryIcon': {'CFBundleIconFiles': ['AppIcon60x60']}}
                say('icon written from the game icon')
            except Exception as e:
                warn('could not write the icon: %s' % e)
        with open(ip, 'wb') as f: plistlib.dump(pl, f)
        say('Info.plist: %s %s' % (name, version))
    except Exception as e:
        warn('could not edit Info.plist (%s); the app keeps the shell identity' % e)
    return A


def step_launcher(tid, patched, game, A, work):
    """The settings screen that upstream put in front of the game (Launcher.swift) is drawn from dm/launcher.json, which
    dm/games/settings.py writes: the rows of dm/games/settings.tsv whose condition holds for this game, with its defaults.

    Upstream's build_ipa.sh does this step; a packer that does not leaves the screen empty, and Launcher.swift then starts the
    game at once -- so this warns instead of failing, unlike the steps whose output the game itself needs.
    """
    s = DM / 'games' / 'settings.py'
    if not s.is_file(): return                     # upstream before the launcher existed
    nacp = game / 'control.nacp'
    if not nacp.is_file():
        warn('no control.nacp beside the RomFS: no dm/launcher.json, so the game starts without the settings screen')
        return
    out = A / 'dm' / 'launcher.json'
    r = subprocess.run([str(PY), str(s), tid, str(patched), str(nacp), str(out)],
                       capture_output=True, text=True, env=dict(os.environ, PYTHONUTF8='1'))
    log = work / 'logs' / 'launcher.log'
    log.parent.mkdir(parents=True, exist_ok=True)
    log.write_text((r.stdout or '') + (r.stderr or ''), encoding='utf-8', errors='replace')
    if r.returncode or not out.is_file():
        msg = ((r.stderr or r.stdout or '').strip().splitlines() or ['no output'])[-1]
        warn('dm/launcher.json could not be written (%s: see %s), so the game starts without the settings screen' % (msg, log))
        return
    say('launcher settings: %s' % (r.stdout or '').strip())


def step_pack(A, out_ipa, rows, work):
    """pack_ipa.py packs straight from the folders, streaming the big ones and keeping the executable bit."""
    app = 'Payload/%s' % A.name
    maps = ['%s=%s' % (app, A)]
    skips = ['_CodeSignature', 'embedded.mobileprovision']
    for sub in ('msl', 'romfs', 'aoc'):
        # Each big folder is mapped on its own so pack_ipa.py streams it; skipping it in the app walk keeps entries unique.
        if (A / sub).is_dir():
            maps.append('%s/%s=%s' % (app, sub, A / sub))
            skips.append(sub)
    store = one(rows, 'zip_store', '')
    args = [PY, IOS / 'tools' / 'pack_ipa.py', out_ipa]
    if store: args += ['--store', store]
    for sub in skips: args += ['--skip', '%s/%s' % (app, sub)]
    args += maps
    run(args, log=work / 'logs' / 'pack_ipa.log', what='packing the IPA')


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description='Pack the shell and your own game files into an IPA, without a Mac.')
    ap.add_argument('shell', nargs='?', default='', help='the shell zip (nxnative-shell-build-input.zip)')
    ap.add_argument('nsp_dir', nargs='?', default='', help="a folder with the game's NSP/XCI files")
    ap.add_argument('-k', '--keys', default=os.environ.get('KEYS', ''), help='prod.keys')
    ap.add_argument('-o', '--out', default='', help='output IPA (default: next to the NSPs)')
    ap.add_argument('-p', '--package', default='', help='version to pack (default: the newest one in the folder)')
    ap.add_argument('--stop-after', default='', choices=['', 'extract', 'rewrite', 'shaders', 'guest', 'assemble', 'pack'])
    ap.add_argument('--force', action='store_true', help='redo steps whose output already exists')
    ap.add_argument('--keep-work', action='store_true',
                    help='keep the working folder after a good pack, so a rerun reuses the extraction, the rewritten '
                         'modules and the shaders (it is several times the size of the game)')
    ap.add_argument('--clean', default='', metavar='NSP_FOLDER',
                    help='remove the working folder an earlier run left in NSP_FOLDER, and exit')
    ap.add_argument('--tools', default=os.environ.get('NXN_TOOLS', ''),
                    help='folder holding nx_extract, dmsh_xlate and spirv-cross executables (the windows-tools CI '
                         'artifact). They are put on PATH and used instead of building anything.')
    a = ap.parse_args()

    for st in (sys.stdout, sys.stderr):
        try: st.reconfigure(errors='replace')
        except Exception: pass

    if a.clean:
        clean_folders(Path(a.clean).resolve()); return
    if not a.shell: die("give the shell zip, or --clean <NSP folder> to remove an earlier run's temporary files")
    if not a.nsp_dir: die("give the folder holding the game's NSP/XCI files")
    if not (DM / 'games').is_dir():
        die('this script needs the repository\'s dm/ folder beside it; it is not a file to copy out on its own.\n'
            '    expected <repo>/scripts/nxn_pack.py with <repo>/dm/ next to scripts/, or nxn_pack.py next to dm/.\n'
            '    looked for %s -- the game profiles, the rewriter and the shader tools all live there.' % DM)

    shell = Path(a.shell).resolve()
    folder = Path(a.nsp_dir).resolve()
    if not shell.is_file(): die('no shell file: %s' % shell)
    if not folder.is_dir(): die('no such folder: %s' % folder)
    check_free_space(folder)
    if not a.keys: die('give prod.keys with -k')
    keys = Path(a.keys).resolve()
    stamp = shell_stamp(shell)
    check_shell(stamp)

    tools_dir = None
    if a.tools:
        tools_dir = Path(a.tools).resolve()
        if not tools_dir.is_dir(): die('--tools %s is not a folder' % tools_dir)
        os.environ['PATH'] = str(tools_dir) + os.pathsep + os.environ.get('PATH', '')
        say('tools: %s' % tools_dir)
    dotnet = check_env(keys, tools_dir)
    apps = scan_nsps(folder)
    probed = nx = None
    if not apps:
        xcis = sorted(folder.glob('*.xci'))
        if len(xcis) == 1:
            # The only thing here is a cartridge dump, which carries nothing that identifies it without the keys: extract it
            # (work the pack needs anyway) and take the title ID from nx_extract's report.
            probed = folder / (xcis[0].stem + '.probe')
            nx = build_nx_extract(dotnet, probed, tools_dir)
            tid = probe_xci(nx, keys, xcis[0], probed / 'extract')
            if tid:
                apps = {tid: {'base': xcis[0], 'updates': {}, 'dlc': [], 'all': [('base', 'v0', xcis[0])]}}
    if not apps:
        die('no game could be identified in %s.\n'
            '    An .nsp is read from the package itself; an .xci is read by extracting it, which needs prod.keys that match '
            'that cartridge.' % folder)
    if len(apps) != 1:
        die('the folder holds %d different games (%s); keep one game per folder' % (len(apps), ', '.join(sorted(apps))))
    tid = next(iter(apps)); fam = apps[tid]
    if not fam['base']:
        die('no base game for %s in %s -- the folder only holds updates or DLC: %s'
            % (tid, folder, ', '.join(p.name for _, _, p in fam['all'])))
    gdir, rows = load_profile(tid)
    mods = one(rows, 'modules', 'main sdk').split()
    need = one(rows, 'shader_versions', 'v0').split()
    builds = {}
    for line in rows.get('build', []):
        f = line.split('\t')
        builds[f[0]] = f[1] if len(f) > 1 else ''

    # Which version to pack: the newest one in the folder, as upstream does ("the script packs the newest version in the
    # folder"), or -p. Only that version is extracted -- the profile's shader tables are a union of several versions, so they
    # already cover any version the profile registers, and a version it does not register is reported rather than refused.
    #
    # A cartridge dump is the exception: it carries no version at all, so "the newest in the folder" means nothing there and
    # the profile decides. That holds whether it was identified just now or by a title ID an earlier run recorded.
    is_dump = fam['base'].suffix.lower() == '.xci'
    upds = sorted(fam['updates'], key=lambda s: int(s[1:]) if s[1:].isdigit() else -1)
    pkg = a.package or (upds[-1] if upds else (one(rows, 'package', 'v0') if is_dump else 'v0'))
    if not is_dump and pkg != 'v0' and pkg not in fam['updates']:
        die('no update for %s in %s (the folder has: %s)'
            % (pkg, folder, ', '.join(upds) if upds else 'only the base game'))
    if pkg not in builds:
        warn('%s is not a version this profile registers (%s): it was never tested, and fixes made for a tested version '
             '(60 fps, for instance) do not apply to it' % (pkg, ', '.join(sorted(builds)) or 'none'))
    elif pkg not in need:
        warn('%s is registered, but the shader tables were built from %s -- shaders this version adds may be missing'
             % (pkg, ' '.join(need)))
    versions = [pkg]
    picks = {pkg: (fam['base'], None if is_dump or pkg == 'v0' else fam['updates'][pkg])}
    say('files: base %s%s' % (fam['base'].name,
        (', update %s' % fam['updates'][pkg].name) if not is_dump and pkg != 'v0' else ', no update')
        + (('; ignoring %d DLC' % len(fam['dlc'])) if fam['dlc'] else ''))

    work = folder / (tid + '_pack')
    work.mkdir(parents=True, exist_ok=True)
    (work / 'logs').mkdir(exist_ok=True)
    if probed and (probed / 'extract').is_dir():
        # the probe extraction is this version's extraction: move it in rather than unpack the same few GB again
        dst = work / 'extract' / pkg
        if not dst.exists():
            dst.parent.mkdir(parents=True, exist_ok=True)
            try: shutil.move(str(probed / 'extract'), str(dst))
            except OSError as e: warn('cannot move the probe extraction into %s (%s): it will be extracted again' % (dst, e))
        shutil.rmtree(probed, ignore_errors=True)
    # Default output name: the profile's own, else the game's name. A shared fallback like "game.ipa" would let two games
    # in one folder overwrite each other's package.
    ipa_name = one(rows, 'ipa', '')
    if not ipa_name:
        ipa_name = (re.sub(r'[^0-9A-Za-z._ -]+', '', one(rows, 'name', tid)).strip() or tid) + '.ipa'
    out_ipa = Path(a.out).resolve() if a.out else folder / ipa_name
    say('game: %s (%s)' % (one(rows, 'name', tid), tid))
    say('shell: %s' % shell.name)
    say('versions to pack: %s (packing %s)' % (', '.join(versions), pkg))
    say('work folder: %s' % work)

    nx = nx or build_nx_extract(dotnet, work, tools_dir)
    dirs = step_extract(nx, keys, folder, picks, work, versions)
    if a.stop_after == 'extract': return say('stopped after extract')
    game = dirs[pkg]
    derived_dir = None
    bad, had_row = check_build_ids(game, rows, pkg, mods)
    if not bad:
        say('build IDs match the profile for %s' % pkg)
    else:
        # Upstream packs any version: when the files are not the build the profile was brought up on, it derives a profile
        # from them instead of refusing. Refusing here would turn away a dump that plays fine -- the shader tables are made
        # from these files anyway, and the rewriter's observation gates simply do not apply to an unknown build.
        sys.path.insert(0, str(TOOLS))
        try:
            import nacp
            disp = nacp.version(game / 'control.nacp') or '?'
        except Exception:
            disp = '?'
        reg = gdir
        derived = work / 'profile' / tid
        derive_profile(reg, tid, pkg, game, mods, derived, disp)
        os.environ['DM_GAMES_DIR'] = os.pathsep.join(
            [str(derived.parent)] + [d for d in os.environ.get('DM_GAMES_DIR', '').split(os.pathsep) if d])
        os.environ['DM_GAMES_FIRST'] = '1'
        gdir, rows = derived, load_rows(derived)
        mods = one(rows, 'modules').split()      # the derived list, not the one the registered profile names
        derived_dir = derived
        builds[pkg] = disp
        warn('these files are not the build of %s that profile %s registers (%s).\n'
             '    Packing %s from a profile derived from them, as upstream does: the shader tables come from these files, '
             'and the observation gates registered for the other build do not apply.' % (pkg, reg.name, '; '.join(bad), pkg))
        say('derived profile: %s (%s)' % (derived, disp))

    patched = work / 'build' / 'patched'
    step_rewrite(game / 'ExeFS', mods, patched, work, a.force)
    # After the rewrite, not before: only the rewritten modules' bytes reach GetInfo's UsedMemorySize.
    # Only for a derived profile: a game the profile was brought up on has its mem_used settled by the profile author,
    # and second-guessing it would resize the heap of titles that already work.
    filled = fill_mem_used(patched, mods, gdir, rows) if derived_dir is not None else None
    if filled:
        value, total = filled
        rows = load_rows(gdir)
        say('mem_used %s: the rewritten modules are %.0f MB, more than the default 64 MB the heap is sized against'
            % (value, total / 2**20))
    if a.stop_after == 'rewrite': return say('stopped after rewrite')
    check_gates(stamp, patched, mods)

    # the three tables shader_split.py writes (upstream tuple; the .conflicts.tsv is derived by other tools, not passed here)
    tables = ['shader_map.tsv', 'shader_facts.tsv', 'shader_pairs.tsv']
    pkg_dir, tb = step_shaders(game, gdir, tables, work, tid, a.force)
    if derived_dir is not None:
        # The shader tool reads its tables from the profile it loads, and a derived profile has none (the split just made
        # them). Without this it falls back to the registered profile's tables, which name shader packs this version lacks.
        for f in sorted(tb.glob('*.tsv')):
            shutil.copyfile(f, derived_dir / f.name)
        say('derived profile tables: %s' % ', '.join(f.name for f in sorted(tb.glob('*.tsv'))))
    if a.stop_after == 'shaders': return say('stopped after the shader split')

    # The chain version is not resolved here on purpose. dmsh_chain.py's command-line modes fingerprint the toolchain,
    # which needs the translator's .dll files -- absent from a single-file build -- and the version it writes into a
    # profile header is a compile-time constant that only the Xcode route needs. The shell reads the version back from
    # the directory name at run time, so dmsh_build.py is left to compute it and we take whatever directory it makes.
    iosout = work / 'build' / 'ios' / 'dmsh_b'          # dmsh_build.py creates b-<chain version> inside it
    cands = ([tools_dir / n for n in ('dmsh_xlate.exe', 'dmsh_xlate')] if tools_dir else []) + \
            [GFX / 'dmsh_xlate_bin' / n for n in ('dmsh_xlate.exe', 'dmsh_xlate')]
    xlate = next((c for c in cands if c.is_file()), None)
    if not xlate: die('no shader translator: pass --tools <folder> with dmsh_xlate, or build it with dotnet publish')
    step_translate(pkg_dir, work, xlate, iosout, tid, a.force)
    libs = sorted(p for p in iosout.glob('b-*') if p.is_dir()) if iosout.is_dir() else []
    if not libs: die('no shader library directory under %s' % iosout)
    msl_out = libs[-1]
    say('shader libraries: %s (%d)' % (msl_out.name, len(list(msl_out.glob('*_b.metallib')))))
    if a.stop_after == 'guest': return say('stopped before assembly')

    stage = work / 'stage'
    A = step_assemble(shell, stage, game, patched, mods, gdir, rows,
                      one(rows, 'name', tid), builds[pkg], tid, msl_out, work)
    step_pack(A, out_ipa, rows, work)
    say('done: %s (%.0f MB)' % (out_ipa, out_ipa.stat().st_size / 1048576))
    say('next: sign it with a sideloading tool (SideStore / Sideloadly / LiveContainer) and install it on the phone')
    say('this IPA contains your game files: for your own use only, do not distribute it')

    # The IPA is written and closed, so the working tree is spent: everything in it was either derived from the game files
    # (a rerun redoes it) or copied into the package. Removing it is the default because it is several times the size of
    # the game -- a 4 GB game leaves ~16 GB behind -- and people notice that, not the 90 seconds it saves.
    if a.keep_work:
        say('working folder kept: %s (remove it with --clean "%s")' % (work, folder))
    else:
        say('removing the temporary files (--keep-work keeps them for a faster rerun)')
        freed = tidy(work)
        say('removed %.1f MB; the logs stay in %s' % (freed / 1048576, work / 'logs'))


if __name__ == '__main__':
    main()

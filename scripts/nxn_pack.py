#!/usr/bin/env python3
"""Pack the game-free shell and your own game files into an installable IPA, on Windows, Linux or macOS.

No Mac, no Xcode and no paid Apple developer account: the shell (built once by dm/ios/tools/shell_build.sh, or downloaded
from the Build shell workflow) supplies the app, this script supplies the game. Apple's two Mac-only steps -- `xcrun metal`
and `xcodebuild` -- are the ones the shell split removed.

Usage:
  python scripts/nxn_pack.py <shell.zip> <NSP folder> -k <prod.keys> [-o out.ipa] [-p vN] [--stop-after STEP]

  <NSP folder>   one game's files: the base game (.nsp, or a cartridge dump .xci) plus every update the game profile's
                 shader_versions lists (see dm/games/<title ID>/game.tsv). DLC NSPs are packed too when present.
  -k            prod.keys (also read from the KEYS environment variable)
  -p            the version to pack (default: the profile's `package` value)
  --stop-after  stop after a step, to bring the chain up one piece at a time. Steps:
                extract, rewrite, shaders, guest, assemble, pack
  --force       redo steps whose output already exists

Requirements: Python 3.9+ with lz4, capstone, fonttools and pillow; the .NET 10 SDK (for nx_extract and the shader
translator); spirv-cross 1.4.357.0 on PATH; a C compiler (clang). Every step says what is missing before it starts.

Only your own game files go in, and the IPA it produces contains them: it is for your own use, do not distribute it.
"""
import argparse, os, plistlib, re, shutil, subprocess, sys, time, zipfile
from pathlib import Path

PY = sys.executable
HERE = Path(__file__).resolve().parent
REPO = HERE.parent
DM = REPO / 'dm'
GFX = DM / 'gfx' / 'tools'
IOS = DM / 'ios'
TOOLS = DM / 'tools'


def say(s): print('[%s] %s' % (time.strftime('%H:%M:%S'), s), flush=True)
def die(s): sys.exit('[x] ' + s)
def warn(s): print('[!] ' + s, flush=True)


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

def check_env(keys_path):
    bad = []
    for m, pkg in (('lz4', 'lz4'), ('capstone', 'capstone'), ('fontTools', 'fonttools'), ('PIL', 'pillow')):
        try: __import__(m)
        except Exception: bad.append('Python package %s:  %s -m pip install %s' % (m, PY, pkg))
    if not which('clang', 'gcc', 'cc'): bad.append('a C compiler (clang; on Windows installing LLVM is enough)')
    if not which('spirv-cross'):
        bad.append('spirv-cross 1.4.357.0 on PATH (brew install spirv-cross; on Windows build it from source with '
                   'cmake/ninja, see dm/ios/tools/../../docs/SHELL.md)')
    dotnet = which('dotnet') or (str(Path.home() / '.dotnet' / 'dotnet') if (Path.home() / '.dotnet' / 'dotnet').is_file() else None)
    if not dotnet: bad.append('.NET 10 SDK: https://dotnet.microsoft.com/download')
    if not Path(keys_path).is_file(): bad.append('prod.keys not found: %s' % keys_path)
    if bad: die('missing %d item(s):\n  - %s' % (len(bad), '\n  - '.join(bad)))
    return dotnet


# ---------------------------------------------------------------- profile

def load_profile(tid):
    """dm/games/<title ID>/game.tsv: key<TAB>value, several values per key, one `build` row per version."""
    d = DM / 'games' / tid
    f = d / 'game.tsv'
    if not f.is_file(): die('no game profile for title ID %s (%s)\n'
                            '    Supported games: %s' % (tid, f, ', '.join(sorted(p.name for p in (DM / 'games').iterdir() if (p / 'game.tsv').is_file()))))
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

def scan_nsps(folder):
    """Title IDs from the file names ([XXXXXXXXXXXXX000] / [vN]) and from the .tik inside each NSP.
    Returns {title ID: [(version, path)]} and complains about NSZ, which this cannot read."""
    nsps = sorted(list(folder.glob('*.nsp')) + list(folder.glob('*.xci')))
    nsz = sorted(folder.glob('*.nsz'))
    if nsz: die('%d NSZ file(s) in %s: this reads NSP and XCI only.\n'
                '    Unpack them first:  nsz -D "%s"   (needs your prod.keys)' % (len(nsz), folder, nsz[0].name))
    if not nsps: die('no .nsp or .xci in %s' % folder)
    found = {}
    for p in nsps:
        if p.stat().st_size == 0: warn('skipping empty file %s' % p.name); continue
        tid = ver = None
        m = re.search(r'\[([0-9A-Fa-f]{16})\]', p.name)
        if m: tid = m.group(1).upper()
        m = re.search(r'\[v(\d+)\]', p.name)
        if m: ver = 'v' + m.group(1)
        if tid is None:
            warn('cannot tell the title ID of %s -- rename it to include [XXXXXXXXXXXXX000] and [vN]' % p.name); continue
        found.setdefault(tid, []).append((ver, p))
    return found


# ---------------------------------------------------------------- steps

def build_nx_extract(dotnet, work):
    out = work / 'tools' / 'nx_extract'
    exe = out / ('nx_extract.exe' if os.name == 'nt' else 'nx_extract')
    if exe.is_file(): say('nx_extract already built'); return exe
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


def step_rewrite(exe_dir, mods, out, work, force=False):
    if not force and all((out / (m + '.patched.bin')).is_file() and (out / (m + '.fixups.tsv')).is_file() for m in mods):
        say('rewritten modules already there'); return
    out.mkdir(parents=True, exist_ok=True)
    for m in mods:
        run([PY, TOOLS / 'patch_nso.py', exe_dir / m, out, m],
            log=work / 'logs' / ('rewrite_%s.log' % m), what='rewriting %s' % m)


def step_shaders(game, prof_dir, tables, work, force=False):
    """shader_split.py: pull the shaders out of the game files and produce the four tables. The rows must match the
    profile's (that is how we know the files are the version the profile was built from)."""
    pkg, tb = work / 'shader' / 'pkg', work / 'shader' / 'tables'
    if not force and (pkg / 'index.tsv').is_file() and all((tb / n).is_file() for n in tables):
        say('shader split already done'); return pkg, tb
    tb.mkdir(parents=True, exist_ok=True)
    names = ['shader_map.tsv', 'shader_facts.tsv', 'shader_pairs.tsv']
    run([PY, GFX / 'shader_split.py', game / 'RomFS', game / 'ExeFS' / 'main', pkg] + [tb / n for n in names],
        log=work / 'logs' / 'shader_split.log', what='splitting the shaders out of the game files')
    for n in names:
        a, b = tb / n, prof_dir / n
        if b.is_file():
            ra = [l for l in a.read_text(errors='replace').splitlines() if l and not l.startswith('#')]
            rb = [l for l in b.read_text(errors='replace').splitlines() if l and not l.startswith('#')]
            if ra != rb:
                die('the split shader tables do not match the game profile %s (%s).\n'
                    '    That means the game files are not the version the profile was built from.\n'
                    '    Check the version (the profile lists: %s).' % (prof_dir.name, n, ', '.join(sorted(p.name for p in prof_dir.glob('v*')))) )
    return pkg, tb


def step_translate(pkg, work, xlate, iosout, force=False):
    """dmsh_build.py, with no metal compiler: nometal_run.py turns `xcrun metal` into a copy, so the "libraries" hold MSL
    source and the phone compiles them once on first launch. dmsh_build.py creates <iosout>/b-<chain version> itself."""
    if not force and iosout.is_dir() and any(iosout.glob('b-*/*_b.metallib')):
        say('shader libraries already there'); return
    nometal = GFX / 'nometal_run.py'
    if not nometal.is_file():
        die('dm/gfx/tools/nometal_run.py is missing (it is what makes this work without Apple\'s compiler)')
    run([PY, nometal, GFX / 'dmsh_build.py', pkg, work / 'shader' / 'cache'],
        env={'IOSOUT': iosout, 'XLATE': xlate, 'WORK': work, 'J': os.environ.get('J', '8')},
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
    shutil.rmtree(stage, ignore_errors=True)
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

    # App identity: name, version, bundle ID stays the shell's (the sideloading tool replaces it anyway), icon.
    ip = A / 'Info.plist'
    try:
        with open(ip, 'rb') as f: pl = plistlib.load(f)
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
    ap.add_argument('shell', help='the shell zip (nxnative-shell-build-input.zip)')
    ap.add_argument('nsp_dir', help="a folder with the game's NSP/XCI files")
    ap.add_argument('-k', '--keys', default=os.environ.get('KEYS', ''), help='prod.keys')
    ap.add_argument('-o', '--out', default='', help='output IPA (default: next to the NSPs)')
    ap.add_argument('-p', '--package', default='', help='version to pack (default: the profile picks one)')
    ap.add_argument('--stop-after', default='', choices=['', 'extract', 'rewrite', 'shaders', 'guest', 'assemble', 'pack'])
    ap.add_argument('--force', action='store_true', help='redo steps whose output already exists')
    a = ap.parse_args()

    for st in (sys.stdout, sys.stderr):
        try: st.reconfigure(errors='replace')
        except Exception: pass

    shell = Path(a.shell).resolve()
    folder = Path(a.nsp_dir).resolve()
    if not shell.is_file(): die('no shell file: %s' % shell)
    if not folder.is_dir(): die('no such folder: %s' % folder)
    if not a.keys: die('give prod.keys with -k')
    keys = Path(a.keys).resolve()

    dotnet = check_env(keys)
    found = scan_nsps(folder)
    tids = sorted(found)
    if len(tids) != 1:
        die('the folder holds %d title IDs (%s); keep one game per folder' % (len(tids), ', '.join(tids)))
    tid = tids[0]
    gdir, rows = load_profile(tid)
    mods = one(rows, 'modules', 'main sdk').split()
    need = one(rows, 'shader_versions', 'v0').split()
    pkg = a.package or one(rows, 'package', need[-1])
    builds = {}
    for line in rows.get('build', []):
        f = line.split('\t')
        builds[f[0]] = f[1] if len(f) > 1 else ''
    if pkg not in builds: die('-p %s is not a version this profile registers: %s' % (pkg, ', '.join(builds)))
    versions = need + ([pkg] if pkg not in need else [])

    picks = {}
    for v in versions:
        cand = sorted(found[tid], key=lambda t: (t[0] != v, t[0] or ''))
        have = [p for ver, p in found[tid] if ver == v]
        if not have:
            die('the profile needs version %s and the folder has %s.\n'
                '    Put the missing NSP in %s (the update\'s file name carries [v%s]).'
                % (v, ', '.join(sorted({x[0] or '?' for x in found[tid]})), folder, v[1:]))
        base = next((p for p in have if p.suffix.lower() in ('.nsp', '.xci')), have[0])
        upd = next((p for p in have if p != base and p.suffix.lower() == '.nsp'), None)
        picks[v] = (base, upd)

    work = folder / (tid + '_pack')
    work.mkdir(parents=True, exist_ok=True)
    (work / 'logs').mkdir(exist_ok=True)
    out_ipa = Path(a.out).resolve() if a.out else folder / one(rows, 'ipa', 'game.ipa')
    say('game: %s (%s)' % (one(rows, 'name', tid), tid))
    say('shell: %s' % shell.name)
    say('versions to pack: %s (packing %s)' % (', '.join(versions), pkg))
    say('work folder: %s' % work)

    nx = build_nx_extract(dotnet, work)
    dirs = step_extract(nx, keys, folder, picks, work, versions)
    if a.stop_after == 'extract': return say('stopped after extract')
    game = dirs[pkg]

    patched = work / 'build' / 'patched'
    step_rewrite(game / 'ExeFS', mods, patched, work, a.force)
    if a.stop_after == 'rewrite': return say('stopped after rewrite')

    tables = ['shader_facts.tsv', 'shader_map.tsv', 'shader_map.tsv.conflicts.tsv', 'shader_pairs.tsv']   # dmsh_chain.py TABLES
    pkg_dir, tb = step_shaders(game, gdir, tables, work, a.force)
    if a.stop_after == 'shaders': return say('stopped after the shader split')

    # The chain version is decided by the tools on this machine (it hashes the game's tables and the toolchain). The shell reads
    # it back from the directory name at run time, so nothing has to be recompiled for a different value.
    chk = subprocess.run([PY, GFX / 'nometal_run.py', GFX / 'dmsh_chain.py', '--check-tools'],
                         capture_output=True, text=True, env=dict(os.environ, PYTHONUTF8='1'))
    if chk.returncode:
        say('the local tools differ from dmsh_chain.lock: re-registering the chain for this machine')
        run([PY, GFX / 'nometal_run.py', GFX / 'dmsh_chain.py', '--update-lock'], log=work / 'logs' / 'chain_lock.log', what='registering the translation chain')
        run([PY, GFX / 'nometal_run.py', GFX / 'dmsh_chain.py', '--header'], log=work / 'logs' / 'chain_header.log', what='writing the chain version header')
        warn('dmsh_chain.lock and the profiles\' dmsh_chain.h were updated for this machine: do not commit them')
    ver_out = subprocess.run([PY, GFX / 'nometal_run.py', GFX / 'dmsh_chain.py'], capture_output=True, text=True,
                             env=dict(os.environ, PYTHONUTF8='1')).stdout.strip().splitlines()
    if not ver_out: die('could not get the translation chain version (dmsh_chain.py printed nothing)')
    chain_v = ver_out[-1].strip()
    say('translation chain version on this machine: %s' % chain_v)
    iosout = work / 'build' / 'ios' / 'dmsh_b'          # dmsh_build.py creates b-<chain version> inside it
    xlate = GFX / 'dmsh_xlate_bin' / ('dmsh_xlate.exe' if os.name == 'nt' else 'dmsh_xlate')
    step_translate(pkg_dir, work, xlate, iosout, a.force)
    msl_out = iosout / ('b-' + chain_v)
    if not msl_out.is_dir():
        cand = sorted(p for p in iosout.glob('b-*') if p.is_dir()) if iosout.is_dir() else []
        if not cand: die('no shader library directory under %s' % iosout)
        msl_out = cand[0]; say('using the library directory the build produced: %s' % msl_out.name)
    if a.stop_after == 'guest': return say('stopped before assembly')

    stage = work / 'stage'
    A = step_assemble(shell, stage, game, patched, mods, gdir, rows,
                      one(rows, 'name', tid), builds[pkg], tid, msl_out, work)
    step_pack(A, out_ipa, rows, work)
    say('done: %s (%.0f MB)' % (out_ipa, out_ipa.stat().st_size / 1048576))
    say('next: sign it with a sideloading tool (SideStore / Sideloadly / LiveContainer) and install it on the phone')
    say('this IPA contains your game files: for your own use only, do not distribute it')


if __name__ == '__main__':
    main()

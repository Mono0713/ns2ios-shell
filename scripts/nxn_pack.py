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
import argparse, json, os, plistlib, re, shutil, subprocess, sys, time, zipfile
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


def check_build_ids(game, rows, ver, mods):
    """A profile registers one build ID per module per version. If the files carry a different one, the NSP is not the
    version the profile's rewriter patches and shader tables were made for: the app would build fine and misbehave only
    on the phone, so stop here instead."""
    want = {}
    for line in rows.get('build', []):
        f = line.split('\t')
        if f[0] != ver: continue
        for item in f[2:]:
            if '=' in item: k, v = item.split('=', 1); want[k] = v
    if not want:
        warn('the profile registers no build IDs for %s: skipping the check' % ver); return
    bad = []
    for m in mods:
        p = game / 'ExeFS' / m
        if not p.is_file(): bad.append('%-8s missing' % m); continue
        with open(p, 'rb') as f: head = f.read(0x50)
        got = head[0x40:0x50].hex()
        if m in want and got != want[m]: bad.append('%-8s profile %s / file %s' % (m, want[m], got))
    if bad:
        die('the game files are not version %s of this profile:\n  - %s\n    (the profile registers: %s)'
            % (ver, '\n  - '.join(bad), ', '.join('%s=%s' % kv for kv in want.items())))
    say('build IDs match the profile for %s (%s)' % (ver, ', '.join(sorted(want))))


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
                die('the split shader tables do not match the game profile %s (%s).\n'
                    '    That means the game files are not the version the profile was built from.\n'
                    '    Check the version (the profile lists: %s).' % (prof_dir.name, n, ', '.join(sorted(p.name for p in prof_dir.glob('v*')))) )
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
        run([PY, nometal, GFX / 'dmsh_chain.py', '--header'], env=genv,
            log=work / 'logs' / 'chain_header.log', what='dmsh_chain --header')
        warn('dmsh_chain.lock and dm/games/%s/dmsh_chain.h now describe this machine (do not commit them)' % tid)
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
    ap.add_argument('--tools', default=os.environ.get('NXN_TOOLS', ''),
                    help='folder holding nx_extract, dmsh_xlate and spirv-cross executables (the windows-tools CI '
                         'artifact). They are put on PATH and used instead of building anything.')
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

    tools_dir = None
    if a.tools:
        tools_dir = Path(a.tools).resolve()
        if not tools_dir.is_dir(): die('--tools %s is not a folder' % tools_dir)
        os.environ['PATH'] = str(tools_dir) + os.pathsep + os.environ.get('PATH', '')
        say('tools: %s' % tools_dir)
    dotnet = check_env(keys, tools_dir)
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

    nx = build_nx_extract(dotnet, work, tools_dir)
    dirs = step_extract(nx, keys, folder, picks, work, versions)
    if a.stop_after == 'extract': return say('stopped after extract')
    game = dirs[pkg]
    check_build_ids(game, rows, pkg, mods)

    patched = work / 'build' / 'patched'
    step_rewrite(game / 'ExeFS', mods, patched, work, a.force)
    if a.stop_after == 'rewrite': return say('stopped after rewrite')

    # the three tables shader_split.py writes (upstream tuple; the .conflicts.tsv is derived by other tools, not passed here)
    tables = ['shader_map.tsv', 'shader_facts.tsv', 'shader_pairs.tsv']
    pkg_dir, tb = step_shaders(game, gdir, tables, work, tid, a.force)
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


if __name__ == '__main__':
    main()

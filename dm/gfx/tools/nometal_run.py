#!/usr/bin/env python3
# 在没有苹果 Metal 编译器的机器上跑着色器出库链（Windows / Linux / 没装 Xcode 的 Mac；给 tools/d2rm_pack.py 用）。
# 用法：nometal_run.py <脚本.py> [参数…]   例：nometal_run.py dmsh_build.py <包目录> <缓存目录>
# 做法：不改出库链的任何一个文件（它们的内容参与翻译链版本，一改内测的着色器库就得整体换代），只在本进程里把它们调外部命令的
# 那一个入口（subprocess.run）接过来，认出下面几条命令自己答，其余原样放行：
#   xcrun -sdk <x> metal --version              → 答「none」（工具指纹里编译器记成不用 → 链版本自成一支，缓存与正常模式互不相混）
#   xcrun -sdk <x> metal -c <源码> -o <中间件>    → 把源码拷成中间件（换行统一成 \n）
#   xcrun -sdk <x> metallib <中间件> -o <库>      → 把中间件原样拷成库
#   which <名字>                                 → 用 Python 自己找
#   cp -c <甲> <乙>                              → 普通拷贝
# 结果：「库文件」（*_b.metallib / *_bf.metallib）里放的是着色器源码。壳（DM_SHELL 构建）的图形层发现库不是编好的就在设备上现编
# （gfx/nvn/nvn_mtl.m），系统会把编好的结果缓存，第二次启动起不再编。
# 少掉的一道：正常模式下苹果编译器顺带验了每份源码能编过；这里不验，编不过的要到设备上用到它时才报红。
# Runs the shader build chain on a machine without Apple's Metal compiler (Windows / Linux / a Mac without Xcode; for use by tools/d2rm_pack.py).
# Usage: nometal_run.py <script.py> [args...]   Example: nometal_run.py dmsh_build.py <package dir> <cache dir>
# How: not a single file of the build chain is modified (their contents feed into the translation chain version, and any change would force a whole new generation of the beta shader libraries); only, within this process, the one entry through which they call external commands
# (subprocess.run) is taken over: the commands below are recognized and answered here, and everything else is passed through unchanged:
#   xcrun -sdk <x> metal --version              → answers "none" (the compiler is recorded as unused in the tool fingerprint → the chain version forms its own branch, and its cache never mixes with normal mode's)
#   xcrun -sdk <x> metal -c <source> -o <intermediate file>    → copies the source as the intermediate file (line endings normalized to LF)
#   xcrun -sdk <x> metallib <intermediate file> -o <library>      → copies the intermediate file verbatim as the library
#   which <name>                                 → looked up by Python itself
#   cp -c <a> <b>                              → ordinary copy
# Result: the "library files" (*_b.metallib / *_bf.metallib) contain shader source. When the graphics layer of the shell (DM_SHELL build) finds that a library is not a compiled one, it compiles it on the device
# (gfx/nvn/nvn_mtl.m); the system caches the compiled result, and from the second launch on nothing is compiled again.
# The one check that is lost: in normal mode Apple's compiler also verifies along the way that every source compiles; here that is not verified, and one that fails to compile only reports a failure when it is used on the device.
# Apple's Metal Developer Tools for Windows: when they are installed, the iOS libraries are compiled for real on this
# machine (`metal -target air64-apple-ios18.0`, then `metallib`), so the phone loads them at once instead of compiling
# every shader from source. The Mac libraries (never shipped) stay copies. A shader the Windows compiler refuses is kept
# as source, which the phone still compiles, so a package never loses a shader to this. DM_METAL_TOOLS=<folder> names the
# install folder (the one holding ios\bin\metal.exe); DM_METAL_TOOLS=0 turns it off.
import builtins, os, runpy, shutil, subprocess, sys, tempfile, threading

_real = subprocess.run

# Disk use without APFS clones. On macOS dmsh_build.py and dmsh_mtlcache.py "clone" each library into the output folders
# and the two caches (copy-on-write: no data written). Elsewhere every clone was a full copy, and in source mode each
# "compile" another one, so every shader's MSL was on disk eight times or more (b-<V>/ for Mac and iOS, cas/shader mac and
# ios, cas/metallib mac and ios, the .metal beside them). A Unity game ships its keyword variants as separate programs
# (Pummel Party: 138,126 vertex / pixel pairs), and those copies reached 37 GB for it and over 70 GB for Overcooked! All
# You Can Eat, filling the disk before the package was written. Hard links give the same files for one copy's space:
#   - clones and source-mode "compiles" are hard links where the volume allows one (a plain copy otherwise);
#   - opening a file for writing first detaches it from its other names, so writing one path never changes another
#     (what copy-on-write guarantees on APFS);
#   - text the chain writes uses LF, as on macOS, so a source-mode library is the MSL file itself, linked, instead of a
#     rewritten copy (the CRLF -> LF normalisation in _copy_source then has nothing to do).
# None of this changes a file's content, so like the rest of this wrapper it is outside the chain version.
# DM_HARDLINKS=0 turns it off.
_LINKS = os.name == 'nt' and os.environ.get('DM_HARDLINKS', '1') != '0'
_open = builtins.open


def _detach(path):
    """Before path is changed in place: if other names share its data, give path a copy of its own."""
    try:
        if os.stat(path).st_nlink <= 1: return
    except (OSError, TypeError, ValueError): return
    tmp = '%s.detach-%d-%d' % (os.fsdecode(path), os.getpid(), threading.get_ident())
    shutil.copyfile(path, tmp); os.replace(tmp, path)


def _guarded_open(file, mode='r', buffering=-1, encoding=None, errors=None, newline=None, closefd=True, opener=None):
    if isinstance(file, (str, bytes, os.PathLike)) and any(c in mode for c in 'wax+'):
        if 'w' in mode:      # truncating: the other names keep the old data, this one starts empty
            try:
                if os.stat(file).st_nlink > 1: os.unlink(file)
            except (OSError, TypeError, ValueError): pass
        elif 'x' not in mode: _detach(file)
        if 'b' not in mode and newline is None: newline = '\n'
    return _open(file, mode, buffering, encoding, errors, newline, closefd, opener)


def _link(src, dst):
    """dst becomes another name of src's data (replacing dst), or a copy where a link is not possible."""
    tmp = '%s.link-%d-%d' % (os.fsdecode(dst), os.getpid(), threading.get_ident())
    try: os.link(src, tmp)
    except OSError: shutil.copyfile(src, tmp)
    for i in range(40):      # a scanner holding dst open makes the rename fail on Windows for a few milliseconds
        try: os.replace(tmp, dst); return
        except PermissionError:
            if i == 39: raise
            try: os.unlink(dst)
            except OSError: pass
            import time; time.sleep(0.05)


def _install_links():
    builtins.open = _guarded_open
    try: import dmsh_mtlcache
    except ImportError: return
    orig = dmsh_mtlcache.clone
    def clone(src, dst):
        if getattr(dmsh_mtlcache, '_clonefile', None) is not None: return orig(src, dst)
        _link(src, dst)
    dmsh_mtlcache.clone = clone
_fallback = [0]; _compiled = [0]; _first_err = []; _fb_lock = threading.Lock()


def win_tools():
    """(metal, metallib) of the iOS toolchain in Apple's Metal Developer Tools for Windows, or None."""
    v = os.environ.get('DM_METAL_TOOLS', '')
    if v == '0': return None
    roots = [v] if v else [os.path.join(os.environ.get(e, ''), 'Metal Developer Tools') for e in ('ProgramFiles', 'ProgramW6432', 'ProgramFiles(x86)') if os.environ.get(e)]
    for r in roots:
        for sub in (os.path.join('ios', 'bin'), 'bin', ''):
            m, l = os.path.join(r, sub, 'metal.exe'), os.path.join(r, sub, 'metallib.exe')
            if os.path.isfile(m) and os.path.isfile(l): return m, l
    return None


_WIN = win_tools()


def mode():
    return 'windows-metal-2 %s' % _WIN[0] if _WIN else 'source'


def _sdk(c):
    return c[c.index('-sdk') + 1] if '-sdk' in c and c.index('-sdk') + 1 < len(c) else ''


def _src_arg(c):
    """Index of the source in `metal ... -c ... <source> -o <out>`: the first argument after metal that is neither an option
    nor the value of -o (the iOS command also carries a version option after -c)."""
    o = c.index('-o'); m = c.index('metal')
    idx = [i for i in range(m + 1, len(c)) if not c[i].startswith('-') and i != o + 1]
    if len(idx) != 1: raise RuntimeError('nometal_run：认不出源码参数 %r' % c)
    return idx[0]


def _in_tmp(tool, inp, ext_in, out, ext_out, extra):
    """Run a Windows Metal tool on bare file names inside a fresh temporary folder: metal.exe splits paths at spaces
    ("Switch PAD" → "no such file or directory"), so it never sees a path at all."""
    d = tempfile.mkdtemp(prefix='dmmtl')
    try:
        shutil.copyfile(inp, os.path.join(d, 'i' + ext_in))
        r = _real([tool, *extra, 'i' + ext_in, '-o', 'o' + ext_out], cwd=d, capture_output=True, text=True)
        if r.returncode == 0: shutil.move(os.path.join(d, 'o' + ext_out), out)
        return r
    finally: shutil.rmtree(d, ignore_errors=True)


def _ios_compile(c):
    """`xcrun -sdk iphoneos metal -c ... src -o air` with the Windows compiler; False when it refuses the source."""
    si, o = _src_arg(c), c.index('-o')
    opts = ['-target', 'air64-apple-ios18.0'] + [x for i, x in enumerate(c[c.index('metal') + 1:], c.index('metal') + 1)
                                                  if i not in (si, o, o + 1) and not x.startswith('-mios-version-min=')]
    r = _in_tmp(_WIN[0], c[si], '.metal', c[o + 1], '.air', opts)
    with _fb_lock:
        if r.returncode == 0: _compiled[0] += 1
        elif not _first_err: _first_err.append('%s: %s' % (c[si], (r.stderr or r.stdout).strip()[:600]))
    return r.returncode == 0


def _done(args, out=''):
    return subprocess.CompletedProcess(args, 0, stdout=out, stderr='')


def run(args, *a, **k):
    text = k.get('text') or k.get('universal_newlines')
    enc = (lambda s: s) if text else (lambda s: s.encode())
    if isinstance(args, (list, tuple)) and args:
        c = [str(x) for x in args]
        if _WIN and c[0] == 'xcrun' and _sdk(c) == 'iphoneos':
            if '--version' in c and ('metal' in c or 'metallib' in c):
                # The real compiler's identity goes into the chain version, so these libraries never mix with source ones.
                # "-2": the first version ran metal.exe on paths with spaces, which it refuses, and cached the source copies
                # it fell back to under this identity; a new one keeps those out.
                r = _real([_WIN[0] if 'metal' in c else _WIN[1], '--version'], capture_output=True, text=True)
                return _done(args, enc('windows-2 ' + (r.stdout.splitlines() or ['?'])[0].strip() + '\n'))
            if 'metal' in c and '-c' in c and '-o' in c:
                o = c[c.index('-o') + 1]
                if _ios_compile(c): return _done(args, enc(''))
                with _fb_lock: _fallback[0] += 1      # refused: ship this one as source, as without the Windows tools
                _copy_source(c)
                with open(o + '.src', 'w') as f: f.write('1')
                return _done(args, enc(''))
            if 'metallib' in c and '-o' in c:
                air, lib = c[c.index('metallib') + 1], c[c.index('-o') + 1]
                if os.path.exists(air + '.src'):
                    os.remove(air + '.src'); shutil.copyfile(air, lib); return _done(args, enc(''))
                r = _in_tmp(_WIN[1], air, '.air', lib, '.metallib', [])
                if r.returncode: raise subprocess.CalledProcessError(r.returncode, [_WIN[1], air, '-o', lib], r.stdout, r.stderr)
                return _done(args, enc(''))
        if c[0] == 'xcrun' and 'metal' in c and '--version' in c: return _done(args, enc('none\n'))
        # dmsh_mtlcache.py fingerprints the toolchain with four probes; without a compiler they answer fixed values, so this
        # branch of the chain version is the same on every machine and its cache never mixes with the compiled one.
        if c[0] == 'xcrun' and 'metallib' in c and '--version' in c: return _done(args, enc('none\n'))
        if c[0] == 'xcrun' and '--show-sdk-version' in c: return _done(args, enc('26.0\n'))
        if c[0] == 'xcrun' and '--show-sdk-build-version' in c: return _done(args, enc('26A000\n'))
        if c[0] == 'xcrun' and 'metal' in c and '-c' in c and '-o' in c: _copy_source(c); return _done(args, enc(''))
    return _run_rest(args, c if isinstance(args, (list, tuple)) and args else None, enc, *a, **k)


def _copy_source(c):
    """`metal -c <source> -o <intermediate>` without a compiler: the intermediate file is the source itself.
    The source is the first argument after metal that is neither an option nor the value of -o (the iOS command also carries
    a version option after -c). On Windows spirv-cross writes CRLF line endings: normalize them before they go into the
    package, so the same input gives the same package on every system."""
    o = c.index('-o'); src = [x for i, x in enumerate(c[c.index('metal') + 1:], c.index('metal') + 1) if not x.startswith('-') and i != o + 1]
    if len(src) != 1: raise RuntimeError('nometal_run：认不出源码参数 %r' % c)
    with open(src[0], 'rb') as f: b = f.read()
    if _LINKS and b'\r\n' not in b: _link(src[0], c[o + 1]); return
    with open(c[o + 1], 'wb') as f: f.write(b.replace(b'\r\n', b'\n'))


def _run_rest(args, c, enc, *a, **k):
    if c:
        cp = _link if _LINKS else shutil.copyfile
        if c[0] == 'xcrun' and 'metallib' in c and '-o' in c: cp(c[c.index('metallib') + 1], c[c.index('-o') + 1]); return _done(args, enc(''))
        if c[0] == 'xcrun': raise RuntimeError('nometal_run：没认出的 xcrun 命令 %r' % c)
        if c[0] == 'which' and len(c) == 2: return _done(args, enc((shutil.which(c[1]) or '') + '\n'))
        if c[0] == 'cp' and len(c) == 4 and c[1] == '-c': cp(c[2], c[3]); return _done(args, enc(''))
    return _real(args, *a, **k)


if __name__ == '__main__':
    if len(sys.argv) < 2: sys.exit(__doc__ or '用法：nometal_run.py <脚本.py> [参数…]')
    if sys.argv[1] == '--mode': print(mode()); sys.exit(0)
    subprocess.run = run
    script = os.path.abspath(sys.argv[1]); sys.argv = sys.argv[1:]; sys.path.insert(0, os.path.dirname(script))
    if _LINKS: _install_links()
    try: runpy.run_path(script, run_name='__main__')
    finally:
        if _WIN and (_compiled[0] or _fallback[0]):
            print('nometal_run: %d iOS libraries compiled with %s; %d kept as source (the Windows compiler refused them)' % (_compiled[0], _WIN[0], _fallback[0]), file=sys.stderr)
            if _first_err: print('nometal_run: first refusal: ' + _first_err[0], file=sys.stderr)
    # Every compile refused means the tools themselves do not work here, not a few odd shaders: stop instead of quietly
    # shipping a source-only package. DM_METAL_TOOLS=0 packs without them.
    if _WIN and _fallback[0] and not _compiled[0]:
        sys.exit('nometal_run: the Windows Metal compiler refused all %d shaders (see the first refusal above); '
                 'fix the install or set DM_METAL_TOOLS=0 to pack with shader source' % _fallback[0])

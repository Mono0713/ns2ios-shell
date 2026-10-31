"""A quick look at an extracted game before the long steps (the rewrite, the shaders): what will stop it and what to expect.

Runs right after the extraction, which every pack does first anyway, so it costs seconds. Writes <game folder>/precheck.json
for Switch Pad, which shows it on the game's card, and returns the items for the packer's log:

    {"verdict": "ok" | "warn" | "bad", "items": [{"level": "bad" | "warn" | "info", "key": ..., "text": <Traditional Chinese>}]}

A "bad" item means the pack cannot succeed with this shell (a 32-bit game); the packer stops there instead of an hour later.
Usage on its own: python game_check.py <extracted version dir> [<game folder to write precheck.json in>]
"""
import json
import struct
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
DM = HERE.parent / 'dm'


def npdm_is64(path):
    """main.npdm's META flags: bit 0 set for an AArch64 program. None without the file."""
    try:
        d = Path(path).read_bytes()
    except OSError:
        return None
    if d[:4] != b'META': return None
    return bool(d[0xC] & 1)


def online_signs(F):
    """Why the game looks like it wants Nintendo's online services: the imports and libraries it links."""
    imp = F['mods'].get('main', {}).get('imports', set())
    why = []
    if any('NetworkServiceAccount' in s for s in imp): why.append('Nintendo 帳號的線上身分')
    if any('nifm' in s and 'SubmitNetworkRequest' in s for s in imp): why.append('連線要求')
    if any(m in F['markers'] for m in ('Pia',)): why.append('Nintendo 線上對戰程式庫（pia）')
    return why


def check(game, prof_dir=None):
    sys.path[:0] = [str(DM / 'games'), str(DM / 'tools')]
    import profile_guess as pg
    if not any(n == 'Pia' for _, n in pg.MARKERS): pg.MARKERS = pg.MARKERS + [(b'nn::pia', 'Pia')]   # Nintendo's online play library
    items = []
    add = lambda level, key, text: items.append({'level': level, 'key': key, 'text': text})
    game = Path(game)
    is64 = npdm_is64(game / 'ExeFS' / 'main.npdm')
    if is64 is False:
        add('bad', 'aarch32', '32 位元的遊戲，還不支援（殼只能跑 64 位元的 Switch 遊戲）')
        return items
    romfs = game / 'romfs_manifest.tsv'
    if not romfs.is_file(): romfs = game / 'RomFS'
    try:
        F = pg.facts_of(game / 'ExeFS', romfs if romfs.exists() else game / 'nonexistent')
    except Exception as e:      # a check must never stop a pack that would otherwise run
        add('info', 'unread', '沒辦法先檢查這款（%s），照常轉換' % e)
        return items
    main = F.get('main_markers', set())
    imp = F['mods'].get('main', {}).get('imports', set())
    if any(s in imp for s in ('glDrawElements', 'glDrawArrays', 'glShaderSource')):
        # GL functions imported by name (from NintendoSDK_OpenGL) rather than through eglGetProcAddress: an OpenGL ES game (Roof Rage);
        # a shell older than the GL layer's import resolution leaves every call unimplemented (sound, a magenta screen)
        add('warn', 'gles', 'OpenGL ES 遊戲：要用支援 OpenGL ES 的殼。第一次在 iPad 上玩時畫面會是紫色，殼在錄著色器；'
                            '玩過一輪後再按一次「裝到 iPad」才會有畫面')
    elif F.get('gl_src') or (('EGL / OpenGL' in main) and 'NVN' not in main):
        add('warn', 'gl', 'OpenGL 遊戲：第一次在 iPad 上玩時殼會錄下畫面要用的著色器，再按一次「裝到 iPad」才會有完整畫面')
    elif 'Vulkan' in main and 'NVN' not in main:
        add('warn', 'vulkan', 'Vulkan 遊戲：著色器是執行時才產生的，可能需要先在 iPad 上錄一次')
    if F.get('unity'):
        v = sorted(F['unity'])[0]
        add('info', 'unity', 'Unity %s' % v)
    elif 'Unreal' in F['markers'] or 'Unreal 4' in F['markers']:
        add('info', 'unreal', 'Unreal 引擎')
    on = online_signs(F)
    if on:
        add('warn', 'online', '線上遊戲（%s）：殼會回答「沒有網路」，大部分遊戲會改玩本機模式，少數會一直等' % '、'.join(on))
    size = F.get('romfs', {}).get('bytes', 0)
    if size > 4 << 30:
        add('warn', 'size', '遊戲資料 %.1f GB：iPad 要留夠空間，轉換也比較久' % (size / (1 << 30)))
    if prof_dir and Path(prof_dir).is_dir() and (Path(prof_dir) / 'game.tsv').is_file():
        if (Path(prof_dir) / 'game.tsv').read_text(encoding='utf-8', errors='replace').startswith('# Provisional game profile'):
            add('info', 'provisional', '沒有驗證過的設定檔，用猜的：能不能玩要在 iPad 上試')
    return items


def verdict(items):
    levels = {i['level'] for i in items}
    return 'bad' if 'bad' in levels else 'warn' if 'warn' in levels else 'ok'


def write(items, folder):
    try:
        (Path(folder) / 'precheck.json').write_text(json.dumps({'verdict': verdict(items), 'items': items}, ensure_ascii=False, indent=1),
                                                    encoding='utf-8')
    except OSError:
        pass


if __name__ == '__main__':
    it = check(sys.argv[1])
    if len(sys.argv) > 2: write(it, sys.argv[2])
    for i in it: print('[%s] %s' % (i['level'], i['text']))
    print('verdict:', verdict(it))

// 壳专用（不含游戏内容的公开版安装包，tools/shell_build.sh）：首次启动把全部着色器一次编完，带进度。内测 / 自己用 Xcode 构建的包不编这个文件的内容。
// 为什么要有：使用者的电脑上没有苹果的着色器编译器时，着色器是以源码放进安装包的（tools/d2rm_pack.py、gfx/tools/nometal_run.py），
// 设备上用到哪个现编哪个。真机实测：平均约 80 毫秒一个、单个最长约 450 毫秒；边玩边编的话第一次进一个新场景会顿约 0.8 秒
// （编好的库同一处是 0.12 秒）。所以改成进主菜单之前一次编完——系统会把编好的结果缓存，之后游戏里再建同一个库不花时间。
// 做完的记号放在 Library/Caches（和系统的着色器缓存在同一处，系统清缓存时一起没，下次启动自动重做一遍）。
// 中途切到后台 / 被杀：已编的在系统缓存里，回来从头数一遍，已编的每个只要不到 1 毫秒，等于接着做。
// Shell only (the public install package with no game content, tools/shell_build.sh): on first launch compile all shaders in one go, with progress. Beta packages / packages you build yourself with Xcode do not compile this file's contents.
// Why it exists: when the user's computer has no Apple shader compiler, the shaders are put into the install package as source (tools/d2rm_pack.py, gfx/tools/nometal_run.py),
// and each is compiled on the device when it is first used. Measured on a real device: about 80 ms each on average, about 450 ms for the longest single one; compiling while playing, the first entry into a new scene stutters for about 0.8 seconds
// (0.12 seconds at the same spot with compiled libraries). So it is changed to compiling everything once before entering the main menu -- the system caches the compiled results, and building the same library again in the game afterwards takes no time.
// The completion marker is placed in Library/Caches (the same place as the system's shader cache, so it goes away together when the system clears caches, and the next launch automatically redoes it once).
// Sent to the background / killed midway: what was compiled is in the system cache; on return it counts from the start, each already compiled one taking less than 1 ms, which amounts to resuming.
#ifdef DM_SHELL
#import <Metal/Metal.h>
#import <UIKit/UIKit.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>

static void pl(NSString *s) { fprintf(stderr, "[dm] %s\n", s.UTF8String); }
static int lg(void) { NSString *l = NSLocale.preferredLanguages.firstObject; return [l hasPrefix:@"zh"] ? 1 : [l hasPrefix:@"es"] ? 2 : 0; }   // 系统首选语言：1 中文 / 2 西语 / 0 其余英文 | System preferred language: 1 Chinese / 2 Spanish / 0 English otherwise
// A device that prefers Traditional Chinese (zh-Hant, zh-TW, zh-HK, zh-MO) gets the Chinese lines converted by ICU's Hans-Hant transform
static NSString *zh_for_device(NSString *s) {
    NSString *l = NSLocale.preferredLanguages.firstObject.lowercaseString ?: @"";
    BOOL hant = [l hasPrefix:@"zh-hant"] || [l hasPrefix:@"zh-tw"] || [l hasPrefix:@"zh-hk"] || [l hasPrefix:@"zh-mo"];
    return hant ? ([s stringByApplyingTransform:@"Hans-Hant" reverse:NO] ?: s) : s;
}
#define L3(zh, en, es) (lg() == 1 ? zh_for_device(zh) : lg() == 2 ? (es) : (en))
static NSString *msldir(void) {   // main.m sets DM_MSL_DIR to the chosen game's msl/ (a package of several games has one per game)
    const char *e = getenv("DM_MSL_DIR");
    return e && *e ? @(e) : [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"msl"];
}
static NSString *libdir(void) {   // <包>/msl/b-<链版本>：壳里只有一个版本目录 | <package>/msl/b-<chain version>: the shell has only one version directory
    NSString *msl = msldir();
    for (NSString *d in [NSFileManager.defaultManager contentsOfDirectoryAtPath:msl error:nil] ?: @[]) if ([d hasPrefix:@"b-"]) return [msl stringByAppendingPathComponent:d];
    return nil;
}
// 编好的库以 MTLB 开头；不是的就是源码 | a compiled library starts with MTLB; anything else is source
static BOOL is_source(NSString *path) {
    FILE *f = fopen(path.fileSystemRepresentation, "rb"); if (!f) return NO; char h[4] = {0}; size_t n = fread(h, 1, 4, f); fclose(f);
    return n == 4 && memcmp(h, "MTLB", 4) != 0;
}
// 以源码形式放进包的着色器：NVN 的是 b-<链版本> 下的 *.metallib（还是源码，不是 MTLB），GL 的是 msl/gl/src 下的 *.metal
// （打包的电脑上没有苹果的编译器时，gl_shaders.py 只写这两样：PC 上能装 glslang 和 spirv-cross，装不了 xcrun metal）
// The shaders a package holds as source: NVN's are the *.metallib that are not MTLB under b-<chain version>, GL's the
// *.metal under msl/gl/src (what gl_shaders.py writes when the packing computer has no Apple compiler).
// The NVN check reads 4 bytes of every .metallib (tens of thousands in a Unity package): one file after another that took
// ~0.9 ms each on an iPad (35k files, 30 s). The reads are independent, so they run on several threads at once.
static NSArray<NSString *> *shader_sources(void) {
    NSMutableArray<NSString *> *a = [NSMutableArray array];
    NSString *d = libdir();
    NSMutableArray<NSString *> *libs = [NSMutableArray array];
    for (NSString *f in [[NSFileManager.defaultManager contentsOfDirectoryAtPath:d error:nil] sortedArrayUsingSelector:@selector(compare:)] ?: @[])
        if ([f hasSuffix:@".metallib"]) [libs addObject:[d stringByAppendingPathComponent:f]];
    size_t nl = libs.count;
    if (nl) {
        BOOL *src = calloc(nl, sizeof(BOOL));
        size_t chunks = MIN(nl, (size_t)64), per = (nl + chunks - 1) / chunks;
        dispatch_apply(chunks, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t c) {
            for (size_t i = c * per; i < MIN(nl, (c + 1) * per); i++) @autoreleasepool { src[i] = is_source(libs[i]); }
        });
        for (size_t i = 0; i < nl; i++) if (src[i]) [a addObject:libs[i]];
        free(src);
    }
    NSString *gs = [msldir() stringByAppendingPathComponent:@"gl/src"];
    for (NSString *f in [[NSFileManager.defaultManager contentsOfDirectoryAtPath:gs error:nil] sortedArrayUsingSelector:@selector(compare:)] ?: @[])
        if ([f hasSuffix:@".metal"]) [a addObject:[gs stringByAppendingPathComponent:f]];
    NSString *vs = [msldir() stringByAppendingPathComponent:@"vk/src"];
    for (NSString *f in [[NSFileManager.defaultManager contentsOfDirectoryAtPath:vs error:nil] sortedArrayUsingSelector:@selector(compare:)] ?: @[])
        if ([f hasSuffix:@".metal"]) [a addObject:[vs stringByAppendingPathComponent:f]];
    return a;
}
static NSString *marker(NSArray<NSString *> *src, NSString *dir) {
    // The key has to name this package's shaders, not just the source tree: the chain version (b-<V>) follows the source tree
    // and is the same for every game, so a marker keyed by it alone says "done" for a different game's package, or for a
    // repack whose shaders changed -- and the app then loads source-form .metallib files as if they were compiled, which
    // Metal rejects as "Invalid library file" and the game runs on with no picture at all. The package's own stamp
    // (inputs.tsv: the game and the digest of the profile inputs) is what distinguishes one package from another; a package
    // without it falls back to a digest of the directory's contents.
    NSString *tag = dir.lastPathComponent ?: @"gl";
    NSString *stamp = [NSString stringWithContentsOfFile:[(dir ?: [msldir() stringByAppendingPathComponent:@"gl"]) stringByAppendingPathComponent:@"inputs.tsv"] encoding:NSUTF8StringEncoding error:nil];
    for (NSString *ln in [stamp componentsSeparatedByString:@"\n"]) {
        NSArray *c = [ln componentsSeparatedByString:@"\t"];
        if (c.count == 2 && ([c[0] isEqual:@"inputs"] || [c[0] isEqual:@"game"])) tag = [tag stringByAppendingFormat:@"-%@", c[1]];
    }
    unsigned long long n = 0, bytes = 0;
    for (NSString *p in src) { n++; bytes += [NSFileManager.defaultManager attributesOfItemAtPath:p error:nil].fileSize; }
    if (n) tag = [tag stringByAppendingFormat:@"-%llux%llu", n, bytes];
    NSString *c = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    return [c stringByAppendingPathComponent:[NSString stringWithFormat:@"dm_shader_prep_%@_%@.done", tag, NSProcessInfo.processInfo.operatingSystemVersionString.length ? @(NSProcessInfo.processInfo.operatingSystemVersion.majorVersion * 100 + NSProcessInfo.processInfo.operatingSystemVersion.minorVersion).stringValue : @"0"]];
}
// 要不要做：返回 1 = 已接手（显示进度页，做完调 done）；0 = 不用做（没有源码着色器，或上次已经做完）
// Whether it needs to run: returns 1 = taken over (shows the progress page, calls done when finished); 0 = nothing to do (no source shaders, or already finished last time)
static int prep_show(NSArray<NSString *> *src, NSString *mk, void (^done)(void)) {
    UIWindow *win = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) if ([s isKindOfClass:UIWindowScene.class]) for (UIWindow *w in ((UIWindowScene *)s).windows) if (!win || w.isKeyWindow) win = w;
    UIView *host = win.rootViewController.view ?: win; if (!host) { pl(@"【红】着色器准备：没有窗口可放进度页，跳过（进游戏后会边玩边编，第一次进新场景会顿）"); return 0; }
    UIView *v = [[UIView alloc] initWithFrame:host.bounds]; v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight; v.backgroundColor = UIColor.blackColor;
    UILabel *title = [UILabel new], *sub = [UILabel new], *note = [UILabel new]; UIProgressView *bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    for (UILabel *l in @[title, sub, note]) { l.textColor = [UIColor colorWithWhite:0.85 alpha:1]; l.textAlignment = NSTextAlignmentCenter; l.numberOfLines = 0; l.translatesAutoresizingMaskIntoConstraints = NO; [v addSubview:l]; }
    title.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold]; sub.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightRegular]; note.font = [UIFont systemFontOfSize:13]; note.textColor = [UIColor colorWithWhite:0.6 alpha:1];
    bar.translatesAutoresizingMaskIntoConstraints = NO; bar.progressTintColor = [UIColor colorWithRed:0.78 green:0.36 blue:0.16 alpha:1]; [v addSubview:bar];
    title.text = L3(@"首次启动：正在准备着色器", @"First launch: preparing shaders", @"Primer inicio: preparando los shaders");
    note.text = L3(@"只需要做这一次，做完以后游戏里不会因为着色器卡顿。\n系统更新或重装之后会再做一次。可以切到后台，回来接着做。",
                   @"This is only needed once; afterwards the game will not stutter because of shaders.\nIt runs again after a system update or a reinstall. You can switch away and it continues when you come back.",
                   @"Solo hace falta una vez; después, el juego no se trabará por los shaders.\nSe repite tras una actualización del sistema o una reinstalación. Puedes salir de la app y continuará al volver.");
    [NSLayoutConstraint activateConstraints:@[
        [title.centerXAnchor constraintEqualToAnchor:v.centerXAnchor], [title.bottomAnchor constraintEqualToAnchor:bar.topAnchor constant:-22],
        [bar.centerXAnchor constraintEqualToAnchor:v.centerXAnchor], [bar.centerYAnchor constraintEqualToAnchor:v.centerYAnchor], [bar.widthAnchor constraintEqualToAnchor:v.widthAnchor multiplier:0.5],
        [sub.centerXAnchor constraintEqualToAnchor:v.centerXAnchor], [sub.topAnchor constraintEqualToAnchor:bar.bottomAnchor constant:14],
        [note.centerXAnchor constraintEqualToAnchor:v.centerXAnchor], [note.topAnchor constraintEqualToAnchor:sub.bottomAnchor constant:22], [note.widthAnchor constraintLessThanOrEqualToAnchor:v.widthAnchor multiplier:0.8]]];
    [host addSubview:v];
    UIApplication.sharedApplication.idleTimerDisabled = YES;   // 这几分钟别自动锁屏 | do not auto-lock the screen during these few minutes
    int total = (int)src.count, threads = (int)MAX(2, MIN(6, (NSInteger)NSProcessInfo.processInfo.activeProcessorCount - 2));
    const char *te = getenv("DM_SHADER_PREP_THREADS"); if (te && atoi(te) > 0) threads = atoi(te);   // 测试开关：指定并行数 | test switch: set the degree of parallelism
    pl([NSString stringWithFormat:@"着色器准备：开始，共 %d 个，%d 线程", total, threads]);
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent(); __block _Atomic int fin = 0, bad = 0;
    void (^tick)(void) = ^{ int n = atomic_load(&fin); double el = CFAbsoluteTimeGetCurrent() - t0, left = n > 20 ? el / n * (total - n) : -1;
        bar.progress = (float)n / total;
        NSString *eta = left < 0 ? L3(@"正在估算剩余时间", @"estimating time left", @"calculando el tiempo restante") : left >= 90 ? [NSString stringWithFormat:L3(@"预计还要 %.0f 分钟", @"about %.0f min left", @"faltan unos %.0f min"), ceil(left / 60)] : [NSString stringWithFormat:L3(@"预计还要 %.0f 秒", @"about %.0f s left", @"faltan unos %.0f s"), ceil(left / 5) * 5];
        sub.text = [NSString stringWithFormat:@"%d / %d · %@", n, total, eta]; };
    tick();
    NSTimer *tm = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) { tick(); }];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); dispatch_semaphore_t sem = dispatch_semaphore_create(threads); dispatch_group_t g = dispatch_group_create();
        for (NSString *p in src) { dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
            dispatch_group_async(g, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ @autoreleasepool {
                NSString *txt = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil]; NSError *e = nil;
                id<MTLLibrary> l = txt ? [dev newLibraryWithSource:txt options:nil error:&e] : nil;   // 与游戏里建库用的是同一个调用、同样的参数：缓存才对得上 | the same call with the same arguments as the game uses to build the library: only then does the cache match
                if (!l && atomic_fetch_add(&bad, 1) < 5) pl([NSString stringWithFormat:@"【红】着色器准备：%@ 编不过：%@", p.lastPathComponent, e.localizedDescription ?: @"读不了"]);
                int n = atomic_fetch_add(&fin, 1) + 1; if (n % 500 == 0) pl([NSString stringWithFormat:@"着色器准备：%d / %d，已用 %.0f 秒，温控档位 %ld", n, total, CFAbsoluteTimeGetCurrent() - t0, (long)NSProcessInfo.processInfo.thermalState]);
                dispatch_semaphore_signal(sem); } }); }
        dispatch_group_wait(g, DISPATCH_TIME_FOREVER);
        double el = CFAbsoluteTimeGetCurrent() - t0; int nb = atomic_load(&bad);
        pl([NSString stringWithFormat:@"着色器准备：完成 %d 个，编不过 %d 个，用时 %.1f 秒，%d 线程，结束时温控档位 %ld", total, nb, el, threads, (long)NSProcessInfo.processInfo.thermalState]);
        if (!nb) [@"ok" writeToFile:mk atomically:YES encoding:NSUTF8StringEncoding error:nil];   // 有编不过的就不记完成：下次启动再来一遍（已编的很快） | if any failed to compile, do not record completion: run it again at the next launch (the already compiled ones are fast)
        dispatch_async(dispatch_get_main_queue(), ^{ [tm invalidate]; [v removeFromSuperview]; UIApplication.sharedApplication.idleTimerDisabled = NO; done(); });
    });
    return 1;
}
// What the last full scan found, so a later start does not open every file again: on an iPad the scan of a Unity game's tens of thousands
// of .metallib files took many seconds at every start, behind "Checking shaders", even when everything was compiled long ago.
// The key is cheap to take and changes whenever the package's shaders can have changed: the shader folders' entry counts and modification
// times (a file added, removed or replaced through a rename) and the package stamp inputs.tsv (size, time and content). The cached answer is
// the marker the full scan computed ("-" when the package has no source-form shaders); it counts only while that marker still exists, so the
// system dropping its shader cache (and the marker with it) brings back the full scan and the compile. DM_SHADER_SCAN_CACHE=0 always scans
// Paths go into the key relative to the app's containers: iOS gives the data container (Documents, where the package's msl/ lives)
// and the bundle a new UUID path at every reinstall, the weekly re-sign included, while their contents stay. With the absolute path in
// the key every game missed the cache once after each install and scanned again (SMO 26 s, Lethal League Blaze 32 s, all compiled).
static NSString *rel_path(NSString *p) {
    NSString *home = NSHomeDirectory(), *app = NSBundle.mainBundle.bundlePath;
    if (home.length && [p hasPrefix:[home stringByAppendingString:@"/"]]) return [@"~" stringByAppendingString:[p substringFromIndex:home.length]];
    if (app.length && [p hasPrefix:[app stringByAppendingString:@"/"]]) return [@"@app" stringByAppendingString:[p substringFromIndex:app.length]];
    return p;
}
static NSString *scan_key(void) {
    NSFileManager *fm = NSFileManager.defaultManager; NSMutableString *k = [NSMutableString stringWithString:rel_path(msldir())];
    NSString *lib = libdir();
    for (NSString *d in @[msldir(), lib ?: @"-", [msldir() stringByAppendingPathComponent:@"gl/src"], [msldir() stringByAppendingPathComponent:@"vk/src"]]) {
        NSDictionary *a = [fm attributesOfItemAtPath:d error:nil];
        NSUInteger n = a ? [fm contentsOfDirectoryAtPath:d error:nil].count : 0;
        [k appendFormat:@"|%@:%lu:%.3f", d.lastPathComponent, (unsigned long)n, a ? a.fileModificationDate.timeIntervalSince1970 : 0.0];
    }
    for (NSString *st in @[[(lib ?: msldir()) stringByAppendingPathComponent:@"inputs.tsv"], [msldir() stringByAppendingPathComponent:@"gl/inputs.tsv"]]) {
        NSDictionary *a = [fm attributesOfItemAtPath:st error:nil]; if (!a) continue;
        NSString *txt = [NSString stringWithContentsOfFile:st encoding:NSUTF8StringEncoding error:nil] ?: @"";
        [k appendFormat:@"|%@:%llu:%.3f:%lx", st.lastPathComponent, a.fileSize, a.fileModificationDate.timeIntervalSince1970, (unsigned long)txt.hash];
    }
    [k appendFormat:@"|os %ld.%ld", (long)NSProcessInfo.processInfo.operatingSystemVersion.majorVersion, (long)NSProcessInfo.processInfo.operatingSystemVersion.minorVersion];
    return k;
}
static NSString *scan_cache_path(void) {
    NSArray *c = msldir().pathComponents; NSString *tag = [[c subarrayWithRange:NSMakeRange(c.count > 3 ? c.count - 3 : 0, MIN(c.count, 3u))] componentsJoinedByString:@"_"];
    tag = [[tag componentsSeparatedByCharactersInSet:[NSCharacterSet alphanumericCharacterSet].invertedSet] componentsJoinedByString:@"_"];
    return [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:[NSString stringWithFormat:@"dm_shader_scan_%@.txt", tag]];
}
// The marker named in the cache: written as its file name (it always lives in Library/Caches), read either way (an older
// shell wrote the absolute path, whose container UUID is stale after a reinstall)
static NSString *caches_path(NSString *m) {
    return [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:m.lastPathComponent];
}
static int scan_cache_on(void) { const char *e = getenv("DM_SHADER_SCAN_CACHE"); return !(e && *e == '0'); }
// Finding the source-form shaders opens every .metallib of the package (tens of thousands for a Unity game) and the marker stats each one: on the main
// thread that held the screen black for many seconds after Play, before the loading screen could draw. The scan runs in the background; then, on the main
// thread, either the progress page takes over or done runs at once (nothing to compile, or done last time)
void dm_shader_prep_start(void (^done)(void)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
        NSString *key = scan_cache_on() ? scan_key() : nil, *cache = key ? scan_cache_path() : nil;
        if (cache) {   // the same package as at the last full scan, and nothing left to compile: start at once
            NSArray<NSString *> *ln = [[NSString stringWithContentsOfFile:cache encoding:NSUTF8StringEncoding error:nil] componentsSeparatedByString:@"\n"];
            NSString *mkc = ln.count >= 2 ? caches_path(ln[1]) : nil;
            if (ln.count >= 2 && [ln[0] isEqualToString:key] && ([ln[1] isEqualToString:@"-"] || [NSFileManager.defaultManager fileExistsAtPath:mkc])) {
                pl([NSString stringWithFormat:@"shader preparation: unchanged since the last scan (%@), nothing to do, checked in %.2f s", [ln[1] isEqualToString:@"-"] ? @"no source-form shaders" : @"all compiled", CFAbsoluteTimeGetCurrent() - t0]);
                dispatch_async(dispatch_get_main_queue(), ^{ done(); });
                return;
            }
            if (ln.count >= 2) pl([NSString stringWithFormat:@"shader preparation: scan cache %@, scanning again", ![ln[0] isEqualToString:key] ? @"key changed" : @"marker gone (system shader cache cleared)"]);
        }
        NSArray<NSString *> *src = shader_sources();   // NVN 的版本目录；GL 包没有，源码在 msl/gl/src | the chain version's directory; a GL package has none, its sources are in msl/gl/src
        NSString *mk = src.count ? marker(src, libdir()) : nil;
        BOOL need = mk && ![NSFileManager.defaultManager fileExistsAtPath:mk];
        if (cache) [[NSString stringWithFormat:@"%@\n%@\n", key, mk ? mk.lastPathComponent : @"-"] writeToFile:cache atomically:YES encoding:NSUTF8StringEncoding error:nil];   // read next start; the marker itself appears once the compile succeeds
        pl([NSString stringWithFormat:@"shader preparation: %lu source-form shaders, %@, checked in %.1f s", (unsigned long)src.count, need ? @"to compile" : @"nothing to do", CFAbsoluteTimeGetCurrent() - t0]);
        dispatch_async(dispatch_get_main_queue(), ^{ if (!need || !prep_show(src, mk, done)) done(); });
    });
}
#endif

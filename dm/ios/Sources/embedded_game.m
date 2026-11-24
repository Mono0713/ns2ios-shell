// The library's existing engine serves legacy games. A game with its own engine uses
// the same app window and saves, through the embedded framework's versioned glue.
#include "embedded_game.h"

#include <dlfcn.h>
#include <stdlib.h>

typedef const char *(*EngineStart)(const char *const *, int, const void *);
typedef void (*EnginePresent)(void *);
typedef void (*EngineFocus)(int);
static EngineFocus active_focus;

BOOL embedded_game_focus(int event) {
    if (!active_focus) return NO;
    active_focus(event);
    return YES;
}

static NSDictionary *read_manifest(NSURL *framework) {
    NSData *data = [NSData dataWithContentsOfURL:[framework URLByAppendingPathComponent:@"game.manifest.json"]];
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    return [json isKindOfClass:NSDictionary.class] ? json : nil;
}

static BOOL alpha_numeric(NSString *value) {
    NSCharacterSet *other = [NSCharacterSet characterSetWithCharactersInString:
        @"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"].invertedSet;
    return [value isKindOfClass:NSString.class] && value.length > 0 &&
        [value rangeOfCharacterFromSet:other].location == NSNotFound;
}

NSString *embedded_game_start(NSString *title, NSString *romfs, NSString *shaders, UIWindow *window) {
    if (active_focus) return @"A game is already running.";
    if (!window) return @"The game window is unavailable.";
    if (title.length != 16 || !alpha_numeric(title)) return @"The game ID is invalid.";

    NSFileManager *files = NSFileManager.defaultManager;
    NSString *name = [@"DmGame" stringByAppendingString:title];
    NSURL *framework = [NSBundle.mainBundle.privateFrameworksURL
        URLByAppendingPathComponent:[name stringByAppendingPathExtension:@"framework"] isDirectory:YES];
    NSDictionary *manifest = read_manifest(framework);
    NSArray *modules = manifest[@"modules"];
    if (![manifest[@"title_id"] isEqual:title] || ![manifest[@"framework_executable"] isEqual:name] ||
        ![manifest[@"image_marker"] isEqual:@"dmgame_image_marker"] ||
        ![modules isKindOfClass:NSArray.class] || !modules.count || modules.count > 32) {
        return @"Install a SwitchPad update that includes this game's compatible engine.";
    }
    for (id module in modules) {
        if (!alpha_numeric(module)) return @"The game's engine lists an invalid program module.";
    }

    NSURL *profile = [framework URLByAppendingPathComponent:@"profile.tsv"];
    NSURL *tables = [framework URLByAppendingPathComponent:@"dm" isDirectory:YES];
    NSURL *pso = [framework URLByAppendingPathComponent:@"pso" isDirectory:YES];
    if (![files isReadableFileAtPath:profile.path] || ![files fileExistsAtPath:tables.path])
        return @"The game's engine is missing its profile.";
    if (!romfs || ![files isReadableFileAtPath:romfs] || !shaders || ![files fileExistsAtPath:shaders])
        return @"Sync this game's data from PadSwitch before playing.";

    NSURL *executable = [framework URLByAppendingPathComponent:name];
    void *handle = dlopen(executable.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL | RTLD_FIRST);
    if (!handle) {
        fprintf(stderr, "[RED] could not open game engine: %s\n", dlerror());
        return @"The game's engine could not be loaded.";
    }
    const int *version = dlsym(handle, "dm_glue_version");
    void *marker = dlsym(handle, "dmgame_image_marker");
    EngineStart start = (EngineStart)dlsym(handle, "dm_glue_start_game");
    EnginePresent present = (EnginePresent)dlsym(handle, "dm_glue_present_game");
    EngineFocus focus = (EngineFocus)dlsym(handle, "dm_glue_focus_event");
    Dl_info image;
    if (!version || *version != 1 || !start || !present || !focus || !marker || !dladdr(marker, &image)) {
        dlclose(handle);
        return @"The game's engine has an incompatible version.";
    }

    NSMutableDictionary<NSString *, NSString *> *env = [@{
        @"DM_PROFILE": profile.path, @"DM_ROMFS": romfs, @"DM_MSL_DIR": shaders,
        @"DM_NVN_SHMAP": [tables URLByAppendingPathComponent:@"shader_map.tsv"].path,
    } mutableCopy];
    if ([files fileExistsAtPath:pso.path]) env[@"DM_PSO_BUNDLE"] = pso.path;
    NSMutableDictionary<NSString *, NSString *> *previous = [NSMutableDictionary dictionary];
    for (NSString *key in env) {
        const char *old = getenv(key.UTF8String);
        if (old) previous[key] = @(old);
        setenv(key.UTF8String, env[key].fileSystemRepresentation, 1);
    }
    const char *argv[34] = {"dmhost", tables.fileSystemRepresentation};
    for (NSUInteger i = 0; i < modules.count; i++) argv[i + 2] = [modules[i] UTF8String];
    const char *error = start(argv, (int)modules.count + 2, image.dli_fbase);
    if (error) {
        NSString *message = @(error);
        for (NSString *key in env) {
            NSString *old = previous[key];
            if (old) setenv(key.UTF8String, old.UTF8String, 1);
            else unsetenv(key.UTF8String);
        }
        // Objective-C classes from the embedded image can already be registered.
        return message;
    }
    active_focus = focus;
    present((__bridge void *)window);
    return nil;
}

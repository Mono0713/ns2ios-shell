// The library's existing engine serves legacy games. A game with its own engine uses
// the same app window and saves, through the embedded framework's versioned glue.
#include "embedded_game.h"
#define DM_SHELL_INPUT_BRIDGE 1
#include "embedded_game_input.h"
#include "dm_input.h"
#include "shell_slots.h"
#include "switchpad_virtual_pad.h"

#include <dlfcn.h>
#include <stdlib.h>
#include <stdatomic.h>

typedef const char *(*EngineStart)(const char *const *, int, const void *);
typedef void (*EnginePresent)(void *);
typedef void (*EngineFocus)(int);
static EngineFocus active_focus;
static _Atomic(const SwitchPadVirtualPad *) active_pad;
static _Atomic(const SwitchPadShellControls *) active_controls;

void shell_pad_player(int player, uint64_t buttons, int32_t lx, int32_t ly, int32_t rx, int32_t ry) {
    const SwitchPadShellControls *controls = atomic_load(&active_controls);
    if (controls) controls->player(player, buttons, lx, ly, rx, ry);
    else dm_pad_set_player(player, buttons, lx, ly, rx, ry);
}

void shell_pad_slots(uint32_t mask, uint32_t joyright) {
    const SwitchPadShellControls *controls = atomic_load(&active_controls);
    if (controls) controls->slots(mask, joyright);
    else dm_pad_players_with_joyright(mask, joyright);
}

void shell_pad_clear(int player) {
    const SwitchPadShellControls *controls = atomic_load(&active_controls);
    if (controls) controls->clear(player);
    else dm_pad_clear_player(player);
}

void shell_pad_motion(int player, const float acc[3], const float gyro[3], const float angle[3], const float dir[9]) {
    const SwitchPadShellControls *controls = atomic_load(&active_controls);
    if (controls) controls->motion(player, acc, gyro, angle, dir);
    else dm_motion_set_player(player, acc, gyro, angle, dir);
}

UIView *embedded_game_menu_host(void) {
    const SwitchPadShellControls *controls = atomic_load(&active_controls);
    return controls ? (__bridge UIView *)controls->menu_host() : nil;
}

BOOL embedded_game_pause(int on) {
    const SwitchPadShellControls *controls = atomic_load(&active_controls);
    if (!controls) return NO;
    controls->pause(on);
    return YES;
}
UIView *dm_gamepad_view(CGRect frame);
void dm_gamepad_reset(void);

static void *make_library_pad(CGRect frame) {
    return (__bridge_retained void *)dm_gamepad_view(frame);
}

BOOL embedded_game_uses_shell_controls(void) {
    return atomic_load(&active_controls) != NULL;
}

BOOL embedded_game_virtual_active(void) {
    return atomic_load(&active_pad) != NULL;
}
BOOL embedded_game_buttons(uint64_t buttons, int32_t lx, int32_t ly, int32_t rx, int32_t ry) {
    const SwitchPadVirtualPad *pad = atomic_load(&active_pad);
    if (!pad) return NO;
    pad->buttons(buttons, lx, ly, rx, ry);
    return YES;
}
BOOL embedded_game_touches(const void *points, int count) {
    const SwitchPadVirtualPad *pad = atomic_load(&active_pad);
    if (!pad) return NO;
    pad->touches(points, count);
    return YES;
}

@interface EmbeddedPadMenu : NSObject <UIEditMenuInteractionDelegate>
@property (nonatomic, strong) UIMenu *menu;
@end
@implementation EmbeddedPadMenu
- (UIMenu *)editMenuInteraction:(UIEditMenuInteraction *)interaction
          menuForConfiguration:(UIEditMenuConfiguration *)configuration
              suggestedActions:(NSArray<UIMenuElement *> *)suggestedActions {
    return self.menu;
}
@end

BOOL embedded_game_show_menu(UIView *view, CGPoint anchor) {
    if (atomic_load(&active_controls)) return NO;   // use the library's Home menu
    const SwitchPadVirtualPad *pad = atomic_load(&active_pad);
    if (!pad) return NO;
    UIMenu *menu = CFBridgingRelease(pad->menu());
    if (!menu || !view.window) return YES;
    static __weak UIView *menu_view;
    static EmbeddedPadMenu *delegate;
    static UIEditMenuInteraction *interaction;
    if (menu_view != view) {
        [menu_view removeInteraction:interaction];
        delegate = [EmbeddedPadMenu new];
        interaction = [[UIEditMenuInteraction alloc] initWithDelegate:delegate];
        [view addInteraction:interaction];
        menu_view = view;
    }
    delegate.menu = menu;
    UIEditMenuConfiguration *cfg = [UIEditMenuConfiguration configurationWithIdentifier:nil sourcePoint:anchor];
    [interaction presentEditMenuWithConfiguration:cfg];
    return YES;
}

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
    const SwitchPadVirtualPad *(*get_pad)(void) = dlsym(handle, "dm_glue_virtual_pad_api");
    const SwitchPadVirtualPad *pad = get_pad ? get_pad() : NULL;
    if (pad && pad->version == 1 && pad->configure && pad->buttons && pad->touches && pad->menu) {
        pad->configure(make_library_pad, dm_gamepad_reset);
        atomic_store(&active_pad, pad);
    }
    const SwitchPadShellControls *(*get_controls)(void) = dlsym(handle, "dm_glue_shell_controls_api");
    const SwitchPadShellControls *controls = get_controls ? get_controls() : NULL;
    if (atomic_load(&active_pad) && controls && controls->version == 1 && controls->adopt && controls->player &&
        controls->slots && controls->clear && controls->motion && controls->pause && controls->menu_host) {
        controls->adopt();
        atomic_store(&active_controls, controls);
        shell_slots_publish();
    }
    active_focus = focus;
    present((__bridge void *)window);
    return nil;
}

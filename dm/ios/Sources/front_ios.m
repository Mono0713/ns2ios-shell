// iOS front end (the iOS implementation of front.h): a centered 16:9 Metal view (black bars on both sides) + a full-screen virtual gamepad layer (DmGamepad.m, controls drawn over the picture).
// A TV on the iPad's USB-C / HDMI adapter (an external display scene, DmTvSceneDelegate) takes the game's picture once the game starts: the picture fills the TV's own
// screen and its resolution instead of the mirrored iPad screen (whose 4:3 shape left bars all round), and the touch controls stay on the iPad. A Home button (a
// controller's, − and + together, a phone page's, the iPad's Menu button while the picture is on the TV) opens the menu over the paused game: continue, or close the
// game to choose another (one process runs one game: the host maps the game's program at fixed addresses for good, and iOS lets no app start itself again).
// The host runs on the big-stack thread started by main.m; front_run runs the guest directly on the calling thread.
#import <UIKit/UIKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#import <AVFAudio/AVFAudio.h>
#include <errno.h>
#include <os/proc.h>
#include "front.h"
#include "hle.h"
#include "dm.h"
#include "haptics_apple.h"

UIView *dm_gamepad_view(CGRect frame);
void dm_gamepad_reset(void);
void front_ios_boot(void);
int front_ios_boot_ok(void);
static void loading_show(UIView *root);
static void run_watch_start(void);   // the launcher's automatic memory: how this run goes
bool dm_show_launcher(void *view_controller, void (*done)(void));   // Launcher.swift: false = no launcher (no dm/launcher.json, or DM_LAUNCHER=0)
int front_ios_pick_needed(void);   // main.m: a package of several games, none chosen yet
void dm_show_picker(void *view_controller, void (*done)(void));   // GamePicker.swift: calls done once main.m has the chosen game's files in place
int shell_game_unchoose(void);   // main.m: forget the chosen game before it loads (0 once it has started loading)

static CAMetalLayer *g_layer;
static UIWindow *g_tv;            // the TV's window while one is connected (nil otherwise); it shows the game once the game view exists
static UIWindowScene *g_tv_scene; // the TV's scene: the window is made only when the game starts, so the picker and the launcher stay mirrored on the TV until then
static BOOL zh_ui(void) {         // Traditional Chinese when the device prefers it, as the launcher (Launcher.swift)
    NSString *lang = NSLocale.preferredLanguages.firstObject.lowercaseString ?: @"";
    return [lang hasPrefix:@"zh-hant"] || [lang hasPrefix:@"zh-tw"] || [lang hasPrefix:@"zh-hk"] || [lang hasPrefix:@"zh-mo"];
}
static UIView *g_loading, *g_prog, *g_menu;   // the loading screen, the prepare step's progress and the Home menu: over the picture, wherever it is
static UIView *overlay_root(void);
static void home_menu_toggle(void);
static void home_menu_relayout(void);
static void home_menu_watch(void);
static void front_ios_power_watch(void);
static void front_ios_audio_watch(void);
static UILabel *front_ios_fps_label(void);

@interface DmGameView : UIView
@end
@implementation DmGameView
+ (Class)layerClass { return CAMetalLayer.class; }
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        CAMetalLayer *l = (CAMetalLayer *)self.layer;
        l.device = MTLCreateSystemDefaultDevice(); l.pixelFormat = MTLPixelFormatBGRA8Unorm;
        l.contentsScale = UIScreen.mainScreen.nativeScale; l.framebufferOnly = NO; l.opaque = YES;
        self.backgroundColor = UIColor.blackColor;
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CAMetalLayer *l = (CAMetalLayer *)self.layer;
    // The screen the view is on: the iPad's at its native scale; a TV's capped at 1920 pixels across (the game draws at 720p or 1080p, and a 4K drawable would only
    // cost the upscale four times the pixels)
    UIScreen *scr = self.window.windowScene.screen ?: UIScreen.mainScreen;
    CGFloat sc = scr.nativeScale > 0 ? scr.nativeScale : 1;
    if (self.window && self.window == g_tv && self.bounds.size.width > 0) sc = MIN(sc, MAX(1.0, 1920.0 / self.bounds.size.width));
    if (l.contentsScale != sc) l.contentsScale = sc;
    l.drawableSize = CGSizeMake(self.bounds.size.width * l.contentsScale, self.bounds.size.height * l.contentsScale);
}
@end

@interface DmRootVC : UIViewController
@property (nonatomic, strong) UIView *stage;   // the game view and the frame-rate counter: in this view, or in the TV's window while a TV is connected
@property (nonatomic, strong) UIView *tvNote;  // what the iPad shows while the picture is on the TV
@property (nonatomic, strong) UIButton *menuButton;   // the iPad's way to the menu while the picture is on the TV (touch only, no controller needed)
@property (nonatomic, strong) DmGameView *game;
@property (nonatomic, strong) UIView *pad;
@property (nonatomic, strong) UILabel *fps;
@property (nonatomic) BOOL launched;
- (void)startGame;
- (void)afterPick;
- (void)placeStage;
@end
static DmRootVC *g_root;
static void launcher_done(void) { [g_root startGame]; }
static void picker_done(void) { [g_root afterPick]; }
// The launcher's Back to the game list (Launcher.swift), once it has gone away: the picker again, as at launch
void front_ios_back_to_picker(void) {
    if (shell_game_unchoose()) dm_show_picker((__bridge void *)g_root, picker_done);
    else [g_root startGame];   // the game has started loading: it can only be played (not reached from the launcher, which comes before)
}
@implementation DmRootVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    front_ios_power_watch();
    if (front_ios_pick_needed()) return;   // the game picker first (viewDidAppear); afterPick does the rest
    if (!front_ios_boot_ok()) {   // No game files: show a hint and do not start the host
        UILabel *lb = [[UILabel alloc] initWithFrame:CGRectInset(self.view.bounds, 40, 40)];
        lb.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        lb.numberOfLines = 0; lb.textAlignment = NSTextAlignmentCenter; lb.textColor = UIColor.whiteColor;
        lb.text = @"Game files not found.\nPut the RomFS folder into this App's Documents as \"romfs\" (Files app), then restart.";
        [self.view addSubview:lb]; return;
    }
    front_ios_audio_watch();
}
// The game view, the pad and the frame-rate counter are made once the launcher has set the switches they read (DM_SHOW_FPS, DM_METAL_HUD); the host's loading began at app launch (main.m)
- (void)startGame {
    if (self.game) return;
    front_hud_env();   // before the game view makes its device (an env file's DM_METAL_HUD sets it in main.m already)
    self.stage = [[UIView alloc] initWithFrame:self.view.bounds]; self.stage.backgroundColor = UIColor.blackColor;
    self.game = [[DmGameView alloc] initWithFrame:self.view.bounds];
    [self.stage addSubview:self.game]; [self.view addSubview:self.stage];
    g_layer = (CAMetalLayer *)self.game.layer;
    if (getenv("DM_METAL_HUD") && atoi(getenv("DM_METAL_HUD"))) { g_layer.developerHUDProperties = @{@"mode": @"default"}; LOG("front end: Metal performance HUD on (DM_METAL_HUD)"); }   // Apple's HUD over the game: frame rate, frame and GPU time, memory
    dm_haptics_apple_init();
    self.pad = dm_gamepad_view(self.view.bounds);
    self.pad.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.pad];
    self.fps = front_ios_fps_label();   // on the picture: the pad hides while a controller is connected
    if (self.fps) [self.stage addSubview:self.fps];
    [self placeStage];   // on the TV when one is connected
    home_menu_watch();
    loading_show(overlay_root());   // under the shader-preparation screen, which front_progress adds on top when it runs
    [self.view setNeedsLayout]; [self.view layoutIfNeeded];
    UIApplication.sharedApplication.idleTimerDisabled = YES;
    run_watch_start();
    front_ios_boot();
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutStage];
    if (self.menuButton) { UIEdgeInsets in = self.view.safeAreaInsets; self.menuButton.frame = CGRectMake(MAX(16, in.left), MAX(16, in.top), 88, 40); }
}
- (void)layoutStage {
    if (!self.game || !self.stage.superview) return;
    self.stage.frame = self.stage.superview.bounds;
    CGRect b = self.stage.bounds; CGFloat w = b.size.width, h = b.size.height;   // Fit 16:9 into the whole screen (the iPad's, or the TV's, which is 16:9 itself)
    if (w <= 0 || h <= 0) return;
    if (w / h > 16.0 / 9.0) w = h * 16.0 / 9.0; else h = w * 9.0 / 16.0;
    self.game.frame = CGRectMake(floor((b.size.width - w) / 2), floor((b.size.height - h) / 2), w, h);
    if (self.fps) {   // the game picture's top-left corner, inside the picture, so it reads as part of the game view rather than floating in the black bar
        CGRect g = self.game.frame; self.fps.frame = CGRectMake(CGRectGetMinX(g) + 8, CGRectGetMinY(g) + 8, 60, 20);
    }
}
// The game's picture on the TV while one is connected (its window made now), else on the iPad under the touch controls. The Metal layer itself moves with its view,
// so the graphics backend keeps presenting to the same layer (front_metal_layer); its drawable follows the new size and scale (DmGameView layoutSubviews)
- (void)placeStage {
    if (!self.stage) return;
    if (g_tv_scene && !g_tv) {
        g_tv = [[UIWindow alloc] initWithWindowScene:g_tv_scene];
        UIViewController *vc = [UIViewController new]; vc.view.backgroundColor = UIColor.blackColor;
        g_tv.rootViewController = vc; g_tv.hidden = NO;
        CGSize sz = g_tv_scene.screen.bounds.size;
        LOG("front end: the game's picture goes to the TV (%.0fx%.0f points, scale %.1f)", sz.width, sz.height, g_tv_scene.screen.nativeScale);
    }
    UIView *dest = g_tv ? g_tv.rootViewController.view : self.view;
    if (self.stage.superview != dest) {
        [self.stage removeFromSuperview];
        if (dest == self.view) [self.view insertSubview:self.stage atIndex:0]; else [dest addSubview:self.stage];
        [self layoutStage]; [self.game setNeedsLayout];
        for (UIView *v in @[g_loading ?: NSNull.null, g_prog ?: NSNull.null, g_menu ?: NSNull.null])   // what covers the picture goes with it
            if ([v isKindOfClass:UIView.class]) { [v removeFromSuperview]; v.frame = overlay_root().bounds; [overlay_root() addSubview:v]; }
    }
    BOOL tv = g_tv != nil;
    if (tv && !self.tvNote) {
        BOOL z = zh_ui();
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectInset(self.view.bounds, 40, 40)];
        l.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        l.numberOfLines = 0; l.textAlignment = NSTextAlignmentCenter; l.textColor = [UIColor colorWithWhite:0.6 alpha:1]; l.font = [UIFont systemFontOfSize:17];
        l.text = z ? @"遊戲畫面在電視上\n手把的 Home（Xbox）鍵、手把同時按 − 和 +、手機手把的 ⌂，或左上角的「選單」，都可以叫出選單"
                   : @"The game is on the TV\nPress a controller's Home (Xbox) button, − and + together, a phone's ⌂, or Menu at the top left for the menu";
        self.tvNote = l; [self.view insertSubview:l atIndex:0];
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        [b setTitle:z ? @"選單" : @"Menu" forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold]; b.tintColor = UIColor.whiteColor;
        b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14]; b.layer.cornerRadius = 10; b.layer.cornerCurve = kCACornerCurveContinuous;
        [b addTarget:self action:@selector(menuTapped) forControlEvents:UIControlEventTouchUpInside];
        self.menuButton = b; [self.view addSubview:b];   // above the pad
        [self.view setNeedsLayout];
    }
    self.tvNote.hidden = self.menuButton.hidden = !tv;
    if (self.menuButton) [self.view bringSubviewToFront:self.menuButton];
}
- (void)menuTapped { home_menu_toggle(); }
- (void)viewDidAppear:(BOOL)a {
    [super viewDidAppear:a];
    if (self.launched) return;
    if (front_ios_pick_needed()) { self.launched = YES; g_root = self; dm_show_picker((__bridge void *)self, picker_done); return; }
    if (!front_ios_boot_ok()) return;
    self.launched = YES; g_root = self;
    if (!dm_show_launcher((__bridge void *)self, launcher_done)) [self startGame];   // the settings screen first (Launcher.swift), when the app has one
}
// A game was chosen in the picker and main.m has set it up (or found its files missing)
- (void)afterPick {
    if (!front_ios_boot_ok()) {
        UILabel *lb = [[UILabel alloc] initWithFrame:CGRectInset(self.view.bounds, 40, 40)];
        lb.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        lb.numberOfLines = 0; lb.textAlignment = NSTextAlignmentCenter; lb.textColor = UIColor.whiteColor;
        lb.text = @"這款遊戲的檔案不完整，請重新打包。\nThis game's files are missing from the package: pack it again.";
        [self.view addSubview:lb]; return;
    }
    static int audio; if (!audio++) front_ios_audio_watch();   // once, though the launcher can go back to the picker
    if (!dm_show_launcher((__bridge void *)self, launcher_done)) [self startGame];
}
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures { return UIRectEdgeAll; }   // Edge gestures need two swipes, to avoid accidental exits
- (BOOL)prefersStatusBarHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
@end
UIViewController *front_ios_root(void) { return [DmRootVC new]; }

// Thermal state and screen brightness for the power and present rows every 300 frames (hle_nvn.c; its weak defaults return -1 on the Mac). thermalState: 0 nominal, 1 fair, 2 serious, 3 critical.
// Brightness is read on the main thread at start and on each change; every change of the thermal state and of Low Power Mode (which lowers the CPU clock) is logged with the time since launch
static _Atomic double g_brightness = -1;
int dm_thermal_now(void) { return (int)NSProcessInfo.processInfo.thermalState; }
int dm_low_power_now(void) { return NSProcessInfo.processInfo.lowPowerModeEnabled; }   // the frame step does not probe in it (hle_nvn.c fstep_cpu_slowed)
double dm_brightness_now(void) { return g_brightness; }
static void front_ios_power_watch(void) {
    g_brightness = UIScreen.mainScreen.brightness;
    [NSNotificationCenter.defaultCenter addObserverForName:UIScreenBrightnessDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { (void)n; g_brightness = UIScreen.mainScreen.brightness; }];
    [NSNotificationCenter.defaultCenter addObserverForName:NSProcessInfoThermalStateDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        (void)n; LOG("front end: thermal state → %d (%.0f s after launch)", dm_thermal_now(), (now_ns() - g_t0_ns) / 1e9); }];
    [NSNotificationCenter.defaultCenter addObserverForName:NSProcessInfoPowerStateDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        (void)n; LOG("front end: Low Power Mode → %s (%.0f s after launch)", dm_low_power_now() ? "on" : "off", (now_ns() - g_t0_ns) / 1e9); }];
    LOG("front end: thermal state %d, brightness %.2f, Low Power Mode %s", dm_thermal_now(), g_brightness, dm_low_power_now() ? "on" : "off");
}

// Frame-rate counter: the frames put on screen in the last second (nvn_mtl.m counts them for NVN and for the Vulkan layer alike; frames the display link merged away are not counted).
// On when the IPA was built with it (the NSP script's SHOW_FPS / --show-fps → DMShowFPS in Info.plist); DM_SHOW_FPS=0 / 1 in Documents/env.txt overrides that without a rebuild. NULL when off
uint64_t mtl_present_count(void);
static UILabel *front_ios_fps_label(void) {
    const char *e = getenv("DM_SHOW_FPS");
    if (!(e ? atoi(e) != 0 : [[NSBundle.mainBundle objectForInfoDictionaryKey:@"DMShowFPS"] boolValue])) return nil;
    UILabel *l = [UILabel new];
    l.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightSemibold]; l.textColor = UIColor.whiteColor; l.textAlignment = NSTextAlignmentCenter;
    l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45]; l.layer.cornerRadius = 6; l.layer.masksToBounds = YES; l.userInteractionEnabled = NO;
    l.text = @"-- fps";
    // The game's own frames (hle_nvn.c dm_nvn_frame_count), not the presents: with present_interval display a 30 fps game is presented every 60 Hz tick, and
    // counting presents showed 60. A Vulkan or GL game has no NVN frame count, so presents are counted for it
    uint64_t dm_nvn_frame_count(void);
    __block uint64_t n0 = dm_nvn_frame_count(), p0 = mtl_present_count(); __block double t0 = CACurrentMediaTime();
    [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        (void)t; uint64_t n = dm_nvn_frame_count(), p = mtl_present_count(); double now = CACurrentMediaTime();
        if (now - t0 < 1.5) l.text = [NSString stringWithFormat:@"%.0f FPS", ((n > n0 ? n - n0 : p - p0)) / (now - t0)];   // a longer span is the time in the background: no reading
        n0 = n; p0 = p; t0 = now;
    }];
    LOG("front end: frame-rate counter on");
    return l;
}

// Loading screen from Play to the game's first frame (front.h front_first_frame): a spinner and a line over the black game view, which otherwise looked like a hang
// for the seconds the game takes to boot. Traditional Chinese when the device prefers it, as the launcher (Launcher.swift)
static void loading_show(UIView *root) {
    if (g_loading || !root) return;
    NSString *lang = NSLocale.preferredLanguages.firstObject.lowercaseString ?: @"";
    BOOL zh = [lang hasPrefix:@"zh-hant"] || [lang hasPrefix:@"zh-tw"] || [lang hasPrefix:@"zh-hk"] || [lang hasPrefix:@"zh-mo"];
    g_loading = [[UIView alloc] initWithFrame:root.bounds]; g_loading.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    g_loading.backgroundColor = UIColor.blackColor; g_loading.userInteractionEnabled = NO;
    UIActivityIndicatorView *spin = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    spin.color = UIColor.whiteColor; spin.center = CGPointMake(CGRectGetMidX(root.bounds), CGRectGetMidY(root.bounds) - 14);
    spin.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [spin startAnimating];
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(0, CGRectGetMidY(root.bounds) + 24, root.bounds.size.width, 24)];
    l.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    l.textAlignment = NSTextAlignmentCenter; l.textColor = [UIColor colorWithWhite:0.72 alpha:1]; l.font = [UIFont systemFontOfSize:15];
    l.text = zh ? @"遊戲載入中…" : @"Loading the game…"; l.tag = 1;
    [g_loading addSubview:spin]; [g_loading addSubview:l]; [root addSubview:g_loading];
}
// The loading screen's line for the current step (main.m: checking shaders, starting the game). Main thread
void front_ios_loading_text(NSString *zh, NSString *en) {
    NSString *lang = NSLocale.preferredLanguages.firstObject.lowercaseString ?: @"";
    BOOL z = [lang hasPrefix:@"zh-hant"] || [lang hasPrefix:@"zh-tw"] || [lang hasPrefix:@"zh-hk"] || [lang hasPrefix:@"zh-mo"];
    ((UILabel *)[g_loading viewWithTag:1]).text = z ? zh : en; LOG("front end: loading screen: %s", en.UTF8String);
}
// The launcher's automatic memory (hle_runmark.c): the run counts as working once frames have kept coming for 40 s after the first, in the foreground, and as
// memory pressure when iOS warns or under 256 MB is left for this process (iOS kills a process at its limit with no crash log, so the pressure is recorded before it)
void dm_run_mark(char c);
uint64_t mtl_present_count(void);
static void run_watch_start(void) {
    static dispatch_source_t t; if (t) return;
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidReceiveMemoryWarningNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        (void)n; LOG("front end: iOS memory warning (%llu MB left)", (unsigned long long)(os_proc_available_memory() >> 20)); dm_run_mark('w'); }];
    t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 4);
    __block int playing = 0, ok = 0, low = 0; __block uint64_t last = 0;
    dispatch_source_set_event_handler(t, ^{
        size_t av = os_proc_available_memory();
        if (av && av < (256u << 20) && !low++) { LOG("front end: %zu MB left for this process: memory pressure", av >> 20); dm_run_mark('w'); }
        if (ok) return;
        uint64_t n = mtl_present_count();
        if (n > last && UIApplication.sharedApplication.applicationState == UIApplicationStateActive) playing++;   // a second with frames, in the foreground
        last = n;
        if (n && playing >= 40) { ok = 1; dm_run_mark('k'); LOG("front end: 40 s of frames: this run's memory pool works"); }
    });
    dispatch_resume(t);
}
void front_first_frame(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ if (!g_loading) return; [g_loading removeFromSuperview]; g_loading = nil; LOG("front end: first frame, loading screen hidden"); });
}
// Progress screen of the prepare step (front.h front_progress): a dark view over the game's view and the pad, the title, a bar and a count, centered; UIKit views, so it draws while the game's thread waits
static UILabel *g_prog_count; static UIProgressView *g_prog_bar; static UILabel *g_prog_title;
void front_progress(const char *title, long done, long total) {
    if (!g_layer) return;
    NSString *tt = title ? @(title) : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!tt) { [g_prog removeFromSuperview]; g_prog = nil; return; }
        if (!g_prog) {
            UIView *root = overlay_root(); if (!root) return;
            g_prog = [[UIView alloc] initWithFrame:root.bounds]; g_prog.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            g_prog.backgroundColor = [UIColor colorWithWhite:0.06 alpha:0.94];
            UIView *box = [[UIView alloc] initWithFrame:CGRectMake(floor((root.bounds.size.width - 320) / 2), floor((root.bounds.size.height - 96) / 2), 320, 96)];
            box.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
            g_prog_title = [[UILabel alloc] initWithFrame:CGRectMake(0, 4, 320, 30)]; g_prog_title.textAlignment = NSTextAlignmentCenter; g_prog_title.textColor = UIColor.whiteColor;
            g_prog_title.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
            g_prog_bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault]; g_prog_bar.frame = CGRectMake(20, 48, 280, 4);
            g_prog_count = [[UILabel alloc] initWithFrame:CGRectMake(0, 64, 320, 22)]; g_prog_count.textAlignment = NSTextAlignmentCenter;
            g_prog_count.textColor = [UIColor colorWithWhite:0.72 alpha:1]; g_prog_count.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightRegular];
            [box addSubview:g_prog_title]; [box addSubview:g_prog_bar]; [box addSubview:g_prog_count]; [g_prog addSubview:box];
            [root addSubview:g_prog];
        }
        g_prog_title.text = tt; g_prog_bar.progress = total > 0 ? (float)done / (float)total : 0;
        g_prog_count.text = [NSString stringWithFormat:@"%@ of %@", [NSNumberFormatter localizedStringFromNumber:@(done) numberStyle:NSNumberFormatterDecimalStyle],
                             [NSNumberFormatter localizedStringFromNumber:@(total) numberStyle:NSNumberFormatterDecimalStyle]];
    });
}
void *front_metal_layer(void) { return (__bridge void *)g_layer; }
void front_run(void (*guest)(void)) { guest(); }   // Already on main.m's big-stack thread

// Software keyboard: show a UIAlertController on the main thread, the calling thread waits for the result
int front_text_input(const char *title, const char *sub, const char *guide, const char *initial, int max_chars, char *out, int out_cap) {
    (void)max_chars;
    if (!g_layer) return -1;
    __block int r = 0; __block NSString *text = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    NSString *t = title && *title ? @(title) : @"", *m = [NSString stringWithFormat:@"%s%s%s", sub ? sub : "", sub && *sub && guide && *guide ? "\n" : "", guide ? guide : ""];
    NSString *init = initial ? @(initial) : @"", *ph = guide ? @(guide) : @"";
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:t message:m preferredStyle:UIAlertControllerStyleAlert];
        [ac addTextFieldWithConfigurationHandler:^(UITextField *f) { f.text = init; f.placeholder = ph; }];
        [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { (void)x; r = 1; text = ac.textFields.firstObject.text; dispatch_semaphore_signal(done); }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *x) { (void)x; dispatch_semaphore_signal(done); }]];
        UIViewController *vc = nil;
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) if ([s isKindOfClass:UIWindowScene.class]) for (UIWindow *w in ((UIWindowScene *)s).windows) if (w.isKeyWindow) vc = w.rootViewController;
        if (!vc) { dispatch_semaphore_signal(done); return; }
        [vc presentViewController:ac animated:YES completion:nil];
    });
    // The guest clock keeps running meanwhile, as on the Switch (hle_swkbd.c): a freeze here as well stopped Octopath Traveler 0's frame loop for as long as the box was up and made its sound stutter
    // (4,977 ms and 2,577 ms frames, 5,181 wakeups a second). The inline keyboard freezes around its own call (hle_swkbd.c)
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    if (!r) return 0;
    snprintf(out, out_cap, "%s", text.UTF8String ? text.UTF8String : "");
    return 1;
}

// Save write failed (most likely the phone's storage is full): show a notice on the main thread without blocking the game. hle_fs.c calls this when a save transaction is refused or a mount has to fall back to read-only;
// the iOS front end used not to implement it, so there was only a log line and the player never learned that progress was not being saved
void front_save_failed(int err) {
    LOG("front end: save data write failed errno=%d, telling the player", err);
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = nil;
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) if ([s isKindOfClass:UIWindowScene.class]) for (UIWindow *w in ((UIWindowScene *)s).windows) if (w.isKeyWindow) vc = w.rootViewController;
        while (vc.presentedViewController) vc = vc.presentedViewController;
        if (!vc) { LOG("[RED] front end: no window for the save-failure alert errno=%d", err); return; }
        NSString *m = err == ENOSPC ? @"Storage is full, so progress was not saved. Free up space and save again."
                                    : [NSString stringWithFormat:@"Saving failed (errno %d); progress was not saved.", err];
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Save failed" message:m preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [vc presentViewController:a animated:YES completion:nil];
    });
}

// Audio session: the frames RemoteIO asks for in each callback follow the I/O buffer duration, about 21 ms by default on iOS (1024 frames at 48 kHz). The game keeps only 4 blocks × 5 ms = 20 ms in flight,
// so every callback came up 1.3 ms short and was zero-filled, about 47 gaps per second (crackling; reproducible on the Mac by forcing 1024-frame callbacks: 1999 underruns in 2000 callbacks). Ask for 5 ms and the system picks the nearest it supports;
// the category stays the default SoloAmbient (silent switch and interrupting other apps' audio behave as before). Set once at boot and again on return to the foreground (the system may reset it after an interruption)
static int g_session_off;   // the last activation failed (another app or a call still held the session): tried again when the app becomes active
void front_ios_audio_session(void) {
    AVAudioSession *s = AVAudioSession.sharedInstance; NSError *e = nil;
    if (![s setCategory:AVAudioSessionCategorySoloAmbient error:&e]) LOG("[RED] audio session category could not be set: %s", e.localizedDescription.UTF8String);
    [s setPreferredSampleRate:48000 error:nil];
    if (![s setPreferredIOBufferDuration:0.005 error:&e]) LOG("[RED] audio session I/O buffer duration could not be set: %s", e.localizedDescription.UTF8String);
    g_session_off = ![s setActive:YES error:&e];
    if (g_session_off) LOG("[RED] audio session activation failed: %s", e.localizedDescription.UTF8String);
    LOG("audio session: sample rate %.0f Hz, I/O buffer %.2f ms (asked for 5 ms)", s.sampleRate, s.IOBufferDuration * 1000);
}

// Real audio output is suspended (the silent sink paces the game) while the app is in the background or another audio session has interrupted ours (Siri, an alarm, a call).
// Without the interruption observer the AudioUnits stayed "started" while iOS no longer called them, and a game waiting for its buffers back lost its sound until restart.
// All of this runs on the main queue, like the scene callbacks
static int g_audio_bg, g_audio_intr;
static void front_ios_audio_apply(void) { dm_audio_suspend(g_audio_bg || g_audio_intr); }
static void front_ios_audio_watch(void) {
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserverForName:AVAudioSessionInterruptionNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        NSUInteger type = [n.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue], reason = [n.userInfo[AVAudioSessionInterruptionReasonKey] unsignedIntegerValue];
        if (type == AVAudioSessionInterruptionTypeBegan) { LOG("audio session: interrupted (reason %lu)", (unsigned long)reason); g_audio_intr = 1; }
        else {
            LOG("audio session: interruption ended"); g_audio_intr = 0;
            if (!g_audio_bg) front_ios_audio_session();
        }
        front_ios_audio_apply();
    }];
    [nc addObserverForName:AVAudioSessionMediaServicesWereResetNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        (void)n; LOG("audio session: the media services were reset; setting the session and the outputs up again");
        front_ios_audio_session(); dm_audio_reset();
    }];
}

// Scene lifecycle (called by SceneDelegate in main.m): 0 resign active, 1 enter background, 2 return to foreground, 3 become active. On entering background, freeze the guest clock and suspend after in-flight GPU work completes (submitting GPU work in background gets the process killed).
// The screen stays on while the game is active: only touches reset the idle timer, so with a controller (or during a cutscene) the screen dimmed and locked mid-game
void front_ios_focus_event(int ev) {
    if (!g_layer) return;
    switch (ev) {
        case 0: dm_gamepad_reset(); dm_focus_set(2); break;
        case 1: dm_run_mark('g'); UIApplication.sharedApplication.idleTimerDisabled = NO; dm_focus_set(3); g_audio_bg = 1; front_ios_audio_apply(); guest_clock_freeze_for(1, 1); dm_gfx_suspend(1); break;
        case 2: dm_run_mark('b'); dm_gfx_suspend(0); guest_clock_freeze_for(1, 0); front_ios_audio_session(); g_audio_bg = 0; front_ios_audio_apply(); dm_focus_set(2); { void front_ios_menu_repause(void); front_ios_menu_repause(); } break;
        case 3:   // Becoming active again also ends an interruption whose "ended" never came (not every one sends it), and retries a session that would not activate on the way back
            UIApplication.sharedApplication.idleTimerDisabled = YES;
            if (g_audio_intr) { LOG("audio session: active again with no interruption-ended notice; resuming"); g_audio_intr = 0; g_session_off = 1; }
            if (g_session_off) front_ios_audio_session();
            front_ios_audio_apply(); { int front_ios_menu_open(void); if (!front_ios_menu_open()) dm_focus_set(1); } break;
    }
}

// ---- The TV (an external display scene) ----
// Where the views that cover the picture go: the TV's window while it shows the game, else the iPad's root view (over the touch controls)
static UIView *overlay_root(void) { return g_tv ? g_tv.rootViewController.view : g_root.view; }
@interface DmTvSceneDelegate : UIResponder <UIWindowSceneDelegate>
@end
@implementation DmTvSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)o {
    (void)session; (void)o;
    if (![scene isKindOfClass:UIWindowScene.class]) return;
    g_tv_scene = (UIWindowScene *)scene;
    // Edge to edge: the default (scale) shrinks the picture inside the TV's frame for TVs that crop their edges, which left a black border on the ones that do not
    g_tv_scene.screen.overscanCompensation = UIScreenOverscanCompensationNone;
    CGSize sz = g_tv_scene.screen.bounds.size;
    LOG("front end: TV connected (%.0fx%.0f points, scale %.1f)%s", sz.width, sz.height, g_tv_scene.screen.nativeScale, g_root.game ? "" : "; mirrored until the game starts");
    [g_root placeStage];   // only once the game view exists: the picker and the launcher stay mirrored until then
    home_menu_relayout();  // a menu already up gets its TV card and its iPad copy
}
- (void)sceneDidDisconnect:(UIScene *)scene {
    if (scene != g_tv_scene) return;
    LOG("front end: TV disconnected; the picture is back on the iPad");
    g_tv.hidden = YES; g_tv_scene = nil;
    UIWindow *w = g_tv; g_tv = nil;
    [g_root placeStage];
    (void)w;   // kept until the stage has left it
    home_menu_relayout();
}
@end

// ---- The Home menu: over the paused game, moved by any player's controller or phone (DMLauncherInput) and by touch ----
// Paused as on the Switch's HOME menu: out of focus, its sound off, its clock frozen and the next submit held (the same steps as going to the background, which
// front_ios_focus_event takes; coming back from the background applies the pause again while the menu is up). The steps run on a queue of their own: the
// graphics suspend waits for the GPU work in flight
static int g_menu_sel, g_menu_closing;
static NSArray<NSArray<NSString *> *> *g_menu_rows;   // [title, detail, action]
static dispatch_queue_t g_pause_q;
static int g_paused;
static void game_pause(int on) {
    if (!g_pause_q) g_pause_q = dispatch_queue_create("dm.home-menu.pause", DISPATCH_QUEUE_SERIAL);
    dispatch_async(g_pause_q, ^{
        if (on == g_paused) return;
        g_paused = on;
        if (on) { dm_focus_set(2); dm_audio_suspend(1); guest_clock_freeze_for(1, 1); dm_gfx_suspend(1); LOG("front end: game paused for the Home menu"); }
        else { dm_gfx_suspend(0); guest_clock_freeze_for(1, 0); dm_audio_suspend(0); dm_focus_set(1); LOG("front end: game resumed from the Home menu"); }
    });
}
static NSString *game_name(void) {
    const char *r = getenv("DM_SHELL_GAME_ROOT");
    NSData *d = r ? [NSData dataWithContentsOfFile:[@(r) stringByAppendingPathComponent:@"game.json"]] : nil;
    id j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    NSString *n = [j isKindOfClass:NSDictionary.class] ? j[@"name"] : nil;
    return [n isKindOfClass:NSString.class] && n.length ? n : ([NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?: @"SwitchPad");
}
static NSMutableArray<UIView *> *g_menu_cards;   // the card on the TV and the iPad's copy (touch), or only the iPad's
static UIView *g_menu_ipad;   // the iPad's copy of the menu while g_menu is on the TV
static unsigned g_menu_gen;   // each opening: a close's late resume does not undo a menu opened again
static void home_menu_draw(void) {
    for (UIView *card in g_menu_cards) for (UIView *row in card.subviews) if (row.tag >= 100) {
        BOOL on = row.tag - 100 == g_menu_sel;
        row.backgroundColor = on ? [UIColor colorWithRed:0.25 green:0.5 blue:1 alpha:1] : [UIColor colorWithWhite:1 alpha:0.08];
    }
}
// The game comes back once every button is up: the A that chose Continue would otherwise reach the game as a press (at most a second's wait)
uint64_t shell_players_held(void);
static void resume_when_released(unsigned gen, int tries) {
    if (gen != g_menu_gen) return;   // opened again meanwhile: it stays paused
    if (shell_players_held() && tries < 20) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ resume_when_released(gen, tries + 1); }); return; }
    game_pause(0);
}
static void home_menu_close(void) {
    if (!g_menu || g_menu_closing) return;
    g_menu_closing = 1;
    [NSNotificationCenter.defaultCenter postNotificationName:@"DMPlayersCommand" object:nil userInfo:@{@"op": @"launcher", @"on": @0}];
    UIView *m = g_menu, *mi = g_menu_ipad;
    [UIView animateWithDuration:0.15 animations:^{ m.alpha = 0; mi.alpha = 0; } completion:^(BOOL f) {
        (void)f; [m removeFromSuperview]; [mi removeFromSuperview];
        if (g_menu == m) { g_menu = nil; g_menu_ipad = nil; g_menu_cards = nil; g_menu_closing = 0; }
    }];
    resume_when_released(g_menu_gen, 0);
}
static void home_menu_quit(void) {
    BOOL z = zh_ui();
    for (UIView *card in g_menu_cards) {
        for (UIView *v in card.subviews) [v removeFromSuperview];
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectInset(card.bounds, 24, 16)];
        l.numberOfLines = 0; l.textAlignment = NSTextAlignmentCenter; l.textColor = UIColor.whiteColor; l.font = [UIFont systemFontOfSize:19 weight:UIFontWeightSemibold];
        l.text = z ? @"已關閉遊戲\n點一下 iPad 上的 SwitchPad 圖示，就會回到選擇遊戲" : @"The game is closed\nTap SwitchPad on the iPad's Home Screen to choose a game";
        [card addSubview:l];
    }
    LOG("front end: Home menu: closing the app to change games");
    fflush(stderr);
    // iOS lets no app open itself again, and a process cannot load a second game (its program sits at fixed addresses), so the app ends here and the next
    // launch shows the picker; 2 s for the line above
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ fflush(stderr); exit(0); });
}
static void home_menu_activate(int i) {
    if (!g_menu || g_menu_closing || i < 0 || i >= (int)g_menu_rows.count) return;
    NSString *act = g_menu_rows[i][2];
    if ([act isEqualToString:@"continue"]) home_menu_close();
    else { g_menu_closing = 1; home_menu_quit(); }
}
@interface DmMenuTap : NSObject
@end
@implementation DmMenuTap
+ (void)tap:(UIButton *)b { g_menu_sel = (int)b.tag - 100; home_menu_draw(); home_menu_activate(g_menu_sel); }
@end
static UIView *home_menu_make(UIView *root) {
    BOOL z = zh_ui();
    UIView *menu = [[UIView alloc] initWithFrame:root.bounds];
    menu.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    menu.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
    CGFloat W = 440, rowH = 64, pad = 16, top = 76;
    CGFloat H = top + g_menu_rows.count * (rowH + 10) + pad - 10 + 34;
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(floor((root.bounds.size.width - W) / 2), floor((root.bounds.size.height - H) / 2), W, H)];
    card.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    card.backgroundColor = [UIColor colorWithRed:0.11 green:0.12 blue:0.14 alpha:0.97];
    card.layer.cornerRadius = 22; card.layer.cornerCurve = kCACornerCurveContinuous;
    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(pad + 4, 18, W - 2 * pad - 8, 26)];
    t.text = game_name(); t.textColor = UIColor.whiteColor; t.font = [UIFont systemFontOfSize:21 weight:UIFontWeightBold];
    UILabel *tag = [[UILabel alloc] init];   // a small tag box: what is going on
    tag.text = z ? @"  已暫停  " : @"  Paused  "; tag.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold]; tag.textColor = [UIColor colorWithWhite:0.8 alpha:1];
    tag.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12]; tag.layer.cornerRadius = 6; tag.layer.masksToBounds = YES;
    [tag sizeToFit]; tag.frame = CGRectMake(pad + 4, 48, tag.bounds.size.width, 20);
    [card addSubview:t]; [card addSubview:tag];
    for (NSUInteger i = 0; i < g_menu_rows.count; i++) {
        UIButton *row = [UIButton buttonWithType:UIButtonTypeCustom];
        row.frame = CGRectMake(pad, top + i * (rowH + 10), W - 2 * pad, rowH); row.tag = 100 + (NSInteger)i;
        row.layer.cornerRadius = 14; row.layer.cornerCurve = kCACornerCurveContinuous;
        [row addTarget:DmMenuTap.class action:@selector(tap:) forControlEvents:UIControlEventTouchUpInside];
        UILabel *a = [[UILabel alloc] initWithFrame:CGRectMake(16, 10, W - 2 * pad - 32, 24)]; a.userInteractionEnabled = NO;
        a.text = g_menu_rows[i][0]; a.textColor = UIColor.whiteColor; a.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
        UILabel *d = [[UILabel alloc] initWithFrame:CGRectMake(16, 34, W - 2 * pad - 32, 20)]; d.userInteractionEnabled = NO;
        d.text = g_menu_rows[i][1]; d.textColor = [UIColor colorWithWhite:0.75 alpha:1]; d.font = [UIFont systemFontOfSize:13];
        [row addSubview:a]; [row addSubview:d]; [card addSubview:row];
    }
    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(pad, H - 34, W - 2 * pad, 22)];
    hint.text = z ? @"方向鍵選擇 · A 確定 · B 或 Home 繼續" : @"D-pad to choose · A to select · B or Home to continue";
    hint.textAlignment = NSTextAlignmentCenter; hint.textColor = [UIColor colorWithWhite:0.55 alpha:1]; hint.font = [UIFont systemFontOfSize:12];
    [card addSubview:hint];
    [menu addSubview:card]; [root addSubview:menu];
    [g_menu_cards addObject:card];
    return menu;
}
static void home_menu_build(void) {
    UIView *root = overlay_root(); if (!root) return;
    g_menu_cards = [NSMutableArray array];
    g_menu = home_menu_make(root);
    if (g_tv && g_root.view) { g_menu_ipad = home_menu_make(g_root.view); g_menu_ipad.backgroundColor = UIColor.blackColor; }   // the iPad's copy, for touch
    home_menu_draw();
}
static void home_menu_relayout(void) {   // the TV came or went while the menu is up: draw it again where the picture is now
    if (!g_menu || g_menu_closing) return;
    [g_menu removeFromSuperview]; [g_menu_ipad removeFromSuperview]; g_menu = nil; g_menu_ipad = nil;
    home_menu_build();
}
static void home_menu_open(void) {
    if (g_menu || !g_root.game) return;   // only once the game was started (the picker and the launcher have their own screens)
    BOOL z = zh_ui();
    const char *ng = getenv("DM_SHELL_GAMES"); BOOL several = ng && atoi(ng) > 1;
    NSMutableArray *rows = [NSMutableArray arrayWithObject:@[z ? @"繼續遊戲" : @"Continue", z ? @"回到遊戲" : @"Back to the game", @"continue"]];
    if (several) [rows addObject:@[z ? @"換遊戲" : @"Change games", z ? @"關閉這個遊戲，再點 SwitchPad 圖示選下一個（未存檔進度會遺失）" : @"Closes this game; tap SwitchPad to choose the next (unsaved progress is lost)", @"quit"]];
    [rows addObject:@[z ? @"關閉遊戲" : @"Close the game", z ? @"結束 SwitchPad（未存檔進度會遺失）" : @"Quits SwitchPad (unsaved progress is lost)", @"quit"]];
    g_menu_rows = rows; g_menu_sel = 0; g_menu_closing = 0; g_menu_gen++;
    game_pause(1);
    [NSNotificationCenter.defaultCenter postNotificationName:@"DMPlayersCommand" object:nil userInfo:@{@"op": @"launcher", @"on": @1}];   // controllers and phones send DMLauncherInput
    home_menu_build();
    LOG("front end: Home menu opened%s", g_tv ? " (on the TV)" : "");
}
static void home_menu_toggle(void) { if (g_menu) home_menu_close(); else home_menu_open(); }
static void home_menu_input(NSDictionary *u) {
    if (!g_menu || g_menu_closing || ![u[@"on"] boolValue]) return;
    NSString *k = u[@"key"];
    if ([k isEqualToString:@"up"]) g_menu_sel = MAX(0, g_menu_sel - 1);
    else if ([k isEqualToString:@"down"]) g_menu_sel = MIN((int)g_menu_rows.count - 1, g_menu_sel + 1);
    else if ([k isEqualToString:@"a"]) { home_menu_activate(g_menu_sel); return; }
    else if ([k isEqualToString:@"b"]) { home_menu_close(); return; }
    home_menu_draw();
}
static void home_menu_watch(void) {   // once the game starts (startGame)
    static int once; if (once++) return;
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserverForName:@"DMHomePressed" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { (void)n; home_menu_toggle(); }];
    [nc addObserverForName:@"DMLauncherInput" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { home_menu_input(n.userInfo); }];
}
int front_ios_menu_open(void) { return g_menu != nil; }
void front_ios_menu_repause(void) {   // the return from the background undid the pause: apply it again while the menu is up
    if (!g_menu || g_menu_closing || !g_pause_q) return;
    dispatch_async(g_pause_q, ^{ g_paused = 0; }); game_pause(1);
}

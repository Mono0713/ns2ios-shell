// iOS front end (the iOS implementation of front.h): a centered 16:9 Metal view (black bars on both sides) + a full-screen virtual gamepad layer (DmGamepad.m, controls drawn over the picture).
// A TV on the iPad's USB-C / HDMI adapter (an external display scene, DmTvSceneDelegate) takes the game's picture once the game starts: the picture fills the TV's own
// screen and its resolution instead of the mirrored iPad screen (whose 4:3 shape left bars all round), and the touch controls stay on the iPad. A Home button (a
// controller's, − and + together, a phone page's, the iPad's Menu button while the picture is on the TV) opens the menu over the paused game: continue, or close the
// game to choose another (one process runs one game: the host maps the game's program at fixed addresses for good, and iOS lets no app start itself again).
// The host runs on the big-stack thread started by main.m; front_run runs the guest directly on the calling thread.
#import <UIKit/UIKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <QuartzCore/CAShapeLayer.h>
#import <Metal/Metal.h>
#import <CoreImage/CoreImage.h>
#import <AVFAudio/AVFAudio.h>
#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>
#import <Network/Network.h>
#include <stdatomic.h>
#include <errno.h>
#include <math.h>
#include <string.h>
#include <os/proc.h>
#include "front.h"
#include "hle.h"
#include "dm.h"
#include "haptics_apple.h"
#include "dm_input.h"
#include "shell_slots.h"
#include "relaunch_ticket.h"

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
static UIWindowScene *g_tv_scene; // the TV's scene: its window is made as soon as it connects, and shows the picker and the launcher until the game starts
// Picture: TV / iPad, the Home menu's choice while a TV is connected (kept for the device): the iPad keeps the game, and the TV window steps aside (hidden)
// The picture on the iPad while a TV is connected: for this connection only (plugging a TV in always starts on the TV), so a tap by mistake is never kept
static BOOL g_video_ipad;
static BOOL video_pref_ipad(void) { return g_video_ipad; }
static BOOL tv_on(void) { return g_tv && !g_tv.hidden && !video_pref_ipad(); }   // the TV's window stays up in handheld play too (tv_handheld_note), so the TV is never mirrored
static _Atomic int g_picture_on_tv;   // tv_on() for the present thread (nvn_mtl.m upscales with MetalFX on a TV), set where the picture moves (placeStage)
int front_picture_on_tv(void) { return g_picture_on_tv; }   // the game's picture is on the TV now
static BOOL zh_ui(void) {         // Traditional Chinese when the device prefers it, as the launcher (Launcher.swift)
    NSString *lang = NSLocale.preferredLanguages.firstObject.lowercaseString ?: @"";
    return [lang hasPrefix:@"zh-hant"] || [lang hasPrefix:@"zh-tw"] || [lang hasPrefix:@"zh-hk"] || [lang hasPrefix:@"zh-mo"];
}
// How much bigger the views over the picture are drawn on a screen larger than an iPad's: a TV's window is often 1920 or 3840 points across at
// scale 1, where a card sized for the iPad came out a fraction of the picture
static CGFloat ui_scale(UIView *root) {
    CGSize b = root.bounds.size; if (b.width <= 0 || b.height <= 0) return 1;
    CGFloat k = MAX(1.0, MIN(b.width / 1194.0, b.height / 834.0));
    return root.window && root.window == g_tv ? k * 1.35 : k;   // seen from the sofa, a few metres away: larger again
}
// A view drawn larger with a transform keeps its backing at the screen's scale, so its text and symbols were magnified bitmaps (soft on a TV): each layer
// drawn at the scale it is shown at instead. After the view is in its window (moving into one sets the layers' scale again)
static void crisp(UIView *v, CGFloat k) {
    UIScreen *screen = v.window.windowScene.screen ?: UIScreen.mainScreen;
    CGFloat s = (v.window == g_tv ? screen.nativeScale : screen.scale) * k;
    for (NSMutableArray *q = [NSMutableArray arrayWithObject:v]; q.count; ) {
        UIView *x = q.lastObject; [q removeLastObject];
        if (x.layer.contentsScale != s) { x.layer.contentsScale = s; [x.layer setNeedsDisplay]; [x setNeedsDisplay]; }
        [q addObjectsFromArray:x.subviews];
    }
}
static UIView *g_loading, *g_prog, *g_menu;   // the loading screen, the prepare step's progress and the Home menu: over the picture, wherever it is
static CFTimeInterval g_play_started;
// Handheld play with a TV connected: the TV shows the same screens as in console play, so these have a second copy there, over the mirrored picture (tv_copies_sync)
static UIView *g_loading_tv, *g_prog_tv, *g_menu_tv;
static void tv_copies_sync(void);
static UIView *overlay_root(void);
static void home_menu_toggle(void);
static void home_menu_relayout(void);
static int g_menu_page;   // 0 main, 1 players / who is 1P, 2 join (QR)
static int g_menu_anim;   // how the next drawn card comes in: 0 at once, 1 opening, 2 next page, 3 page back
static void menu_page(int page, int sel);
static NSArray *menu_rows(int page);
static NSString *phone_address(void);
static UIImage *phone_code(NSString *address);
static UIImage *phones_qr(NSString **url_out);
static NSArray<NSString *> *audio_row(void);
static NSArray<NSString *> *video_row(void);
static void home_menu_watch(void);
static void home_menu_open(void);
static void home_menu_close(void);
static void volume_hold_stop(void);
static void home_menu_quit(int relaunch);
static UIView *tv_panel(CGRect frame);
// The volume the menu and the TV panel set: the device's own (the same as its volume buttons) wherever iOS has one for the output, the iPad's speaker, headphones,
// Bluetooth or AirPlay. An output with no system volume (the TV over HDMI, a line out: iOS sends them full level and the TV's remote sets the loudness) gets
// the app's own gain instead (dm_audio_master, hle_audio.c), kept between runs. iOS gives apps no call to set the system volume; MPVolumeView's slider is
// the system's own control for it, so the setter moves that slider, in a view kept off screen only while it is used (while one is on screen the system's
// volume indicator stays hidden, the volume buttons' too).
enum { DEVICE_VOLUME_STEP_PERCENT = 5, APP_VOLUME_STEP_PERCENT = 1 };
static BOOL volume_is_device(void) {
    for (AVAudioSessionPortDescription *o in AVAudioSession.sharedInstance.currentRoute.outputs)
        if ([o.portType isEqualToString:AVAudioSessionPortHDMI] || [o.portType isEqualToString:AVAudioSessionPortLineOut] || [o.portType isEqualToString:AVAudioSessionPortDisplayPort]) return NO;
    return YES;
}
static float app_gain_pref(void) { NSNumber *v = [NSUserDefaults.standardUserDefaults objectForKey:@"DMVolume"]; return v ? MAX(0.f, MIN(1.f, v.floatValue)) : 1.f; }
static BOOL g_volume_muted;
static void app_gain_apply(void) {
    dm_audio_master(g_volume_muted ? 0.f : (volume_is_device() ? 1.f : app_gain_pref()));
}
static float g_sysvol_set = -1;   // the level last asked of the system, until it reports it (the slider's change arrives a moment later)
static float volume_pref(void) {
    if (g_volume_muted) return 0.f;
    if (!volume_is_device()) return app_gain_pref();
    return g_sysvol_set >= 0 ? g_sysvol_set : AVAudioSession.sharedInstance.outputVolume;
}
static MPVolumeView *g_volview; static int g_volgen;
static UIWindow *root_window(void);   // the iPad's window (defined with g_root below)
static int volume_step_percent(BOOL device) {
    return device ? DEVICE_VOLUME_STEP_PERCENT : APP_VOLUME_STEP_PERCENT;
}
static float volume_quantized(float v, BOOL device) {
    int step = volume_step_percent(device);
    return roundf(MAX(0.f, MIN(1.f, v)) * 100.f / step) * step / 100.f;
}
static void volume_set(float v) {
    BOOL device = volume_is_device();
    v = volume_quantized(v, device);
    BOOL was_muted = g_volume_muted;
    if (v > 0) g_volume_muted = NO;
    if (!device) { [NSUserDefaults.standardUserDefaults setFloat:v forKey:@"DMVolume"]; app_gain_apply(); }
    else {
        UIWindow *w = root_window();
        if (!g_volview && w) {
            g_volview = [[MPVolumeView alloc] initWithFrame:CGRectMake(-1000, -1000, 200, 40)];
            g_volview.alpha = 0.01; g_volview.userInteractionEnabled = NO; [w addSubview:g_volview];
        }
        int gen = ++g_volgen; g_sysvol_set = v;
        void (^apply)(void) = ^{
            if (gen != g_volgen) return;
            for (UIView *x in g_volview.subviews) if ([x isKindOfClass:UISlider.class]) { UISlider *sl = (UISlider *)x; [sl setValue:v animated:NO]; [sl sendActionsForControlEvents:UIControlEventValueChanged]; }
        };
        apply();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_MSEC), dispatch_get_main_queue(), apply);   // a slider just made takes its value only once it has the system's
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (gen != g_volgen) return;
            g_sysvol_set = -1; [g_volview removeFromSuperview]; g_volview = nil;   // the volume buttons show the system's indicator again
            [NSNotificationCenter.defaultCenter postNotificationName:@"DMShellChanged" object:nil];
        });
        if (was_muted != g_volume_muted) app_gain_apply();
    }
    [NSNotificationCenter.defaultCenter postNotificationName:@"DMShellChanged" object:nil];   // the menu and the TV panel redraw what they show
}
static float volume_step(float v, int dir) {
    int step = volume_step_percent(volume_is_device());
    int pct = (int)lroundf(v * 100.f / step) * step + dir * step;
    return MAX(0, MIN(100, pct)) / 100.f;
}
static BOOL volume_adjust(int dir) {
    float current = volume_pref();
    float next = volume_step(current, dir);
    if (next == current) return NO;
    volume_set(next);
    return next > 0.f && next < 1.f;
}
static void volume_toggle_mute(void) {
    // Keep the mute state in the game's mixer so a system slider update or a new route cannot unmute it.
    g_volume_muted = !g_volume_muted;
    app_gain_apply();
    [NSNotificationCenter.defaultCenter postNotificationName:@"DMShellChanged" object:nil];
}

@interface DmVolumeSlider : UISlider
@end
@implementation DmVolumeSlider
- (void)accessibilityIncrement { volume_adjust(1); }
- (void)accessibilityDecrement { volume_adjust(-1); }
- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    volume_hold_stop();
    CGRect track = [self trackRectForBounds:self.bounds];
    CGRect low = [self thumbRectForBounds:self.bounds trackRect:track value:self.minimumValue];
    CGRect high = [self thumbRectForBounds:self.bounds trackRect:track value:self.maximumValue];
    CGRect thumb = [self thumbRectForBounds:self.bounds trackRect:track value:self.value];
    CGPoint point = [touch locationInView:self];
    CGFloat span = CGRectGetMidX(high) - CGRectGetMidX(low);
    if (!CGRectContainsPoint(CGRectInset(thumb, -5, -5), point) && fabs(span) > 0.1) {
        self.value = volume_quantized((point.x - CGRectGetMidX(low)) / span, volume_is_device());
        [self sendActionsForControlEvents:UIControlEventValueChanged];
    }
    return [super beginTrackingWithTouch:touch withEvent:event];
}
@end

static DmVolumeSlider *volume_slider(BOOL z) {
    DmVolumeSlider *slider = [DmVolumeSlider new];
    slider.value = volume_pref();
    slider.accessibilityLabel = z ? @"音量" : @"Volume";
    __weak DmVolumeSlider *weakSlider = slider;
    [slider addAction:[UIAction actionWithHandler:^(UIAction *action) {
        (void)action;
        DmVolumeSlider *control = weakSlider;
        if (!control) return;
        float value = volume_quantized(control.value, volume_is_device());
        if (fabsf(value - volume_pref()) > 0.001f) volume_set(value);
    }] forControlEvents:UIControlEventValueChanged];
    return slider;
}
// The volume buttons and the output changing (a TV plugged in or out, headphones): what the menu and the panel show follows, and the app's gain applies only where it is used
@interface DmVolumeWatch : NSObject
@end
@implementation DmVolumeWatch
- (void)observeValueForKeyPath:(NSString *)k ofObject:(id)o change:(NSDictionary *)c context:(void *)x {
    (void)k; (void)o; (void)c; (void)x;
    dispatch_async(dispatch_get_main_queue(), ^{ [NSNotificationCenter.defaultCenter postNotificationName:@"DMShellChanged" object:nil]; });
}
@end
static void volume_watch(void) {
    static DmVolumeWatch *w; if (w) return;
    w = [DmVolumeWatch new];
    [AVAudioSession.sharedInstance addObserver:w forKeyPath:@"outputVolume" options:0 context:NULL];
    [NSNotificationCenter.defaultCenter addObserverForName:AVAudioSessionRouteChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        (void)n; app_gain_apply();
        [NSNotificationCenter.defaultCenter postNotificationName:@"DMShellChanged" object:nil];
    }];
}
static void output_video_set(BOOL ipad);
static void output_audio_set(BOOL ipad);
static void play_mode_set(BOOL handheld);
static int g_menu_sel, g_menu_closing;   // (defined with the menu below)
static void slot_swap(int a, int b);     // the Players page's and the TV panel's actions on a player (0-based)
static void slot_layout(int p);
static void slot_identify(int p);
static void slot_remove(int p);
void front_ios_audio_session(void);
static void front_ios_power_watch(void);
static void front_ios_audio_watch(void);
static UILabel *front_ios_fps_label(void);
static NSString *game_name(void);

// A view that lays itself out with a block (the TV panel's cards follow the iPad's size and orientation)
@interface DmLayoutView : UIView
@property (nonatomic, copy) void (^layout)(UIView *v);
@end
@implementation DmLayoutView
- (void)layoutSubviews { [super layoutSubviews]; if (self.layout) self.layout(self); }
@end

// The TV's window, from the moment the TV connects: the picker and the launcher are presented there before the game (filling the TV instead of the iPad's 4:3
// screen mirrored with bars), the game's picture once it starts. Hidden while the picture output is the iPad
@interface DmTvRootVC : UIViewController
@end
@implementation DmTvRootVC
- (void)viewDidLoad { [super viewDidLoad]; self.view.backgroundColor = UIColor.blackColor; }
@end
// A gesture's handler as a block (kept alive by the gesture)
@interface DmBlockTarget : NSObject
@property (nonatomic, copy) void (^fire)(id sender);
@end
@implementation DmBlockTarget
- (void)go:(id)sender { if (self.fire) self.fire(sender); }
@end
static void gesture_block(UIGestureRecognizer *g, void (^fire)(id)) {
    DmBlockTarget *t = [DmBlockTarget new]; t.fire = fire; [g addTarget:t action:@selector(go:)];
    objc_setAssociatedObject(g, &gesture_block, t, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static void tv_window_ensure(void) {
    if (!g_tv_scene || g_tv) return;
    g_tv = [[UIWindow alloc] initWithWindowScene:g_tv_scene];
    g_tv.rootViewController = [DmTvRootVC new]; g_tv.hidden = NO;
    CGSize sz = g_tv_scene.screen.bounds.size;
    LOG("front end: TV window made (%.0fx%.0f points, scale %.1f)%s", sz.width, sz.height, g_tv_scene.screen.nativeScale, video_pref_ipad() ? "; handheld play: the TV shows the handheld screen" : "");
}
// Handheld play with a TV connected: the TV keeps its own window and fills it with a quiet full-screen card (the iPad's 4:3 screen mirrored onto it
// had black bars), until the mode goes back to console
static void tv_handheld_note(BOOL on) {
    UIView *root = g_tv.rootViewController.view; if (!root) return;
    UIView *n = [root viewWithTag:77];
    if (on && !n) {
        BOOL z = zh_ui();
        n = [[UIView alloc] initWithFrame:root.bounds]; n.tag = 77; n.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        n.backgroundColor = [UIColor colorWithRed:0.02 green:0.025 blue:0.04 alpha:1];
        CAGradientLayer *g = [CAGradientLayer layer]; g.type = kCAGradientLayerRadial; g.frame = n.bounds;
        g.colors = @[(id)[UIColor colorWithRed:0.04 green:0.4 blue:1 alpha:0.28].CGColor, (id)UIColor.clearColor.CGColor];
        g.startPoint = CGPointMake(0.5, 0.45); g.endPoint = CGPointMake(1.1, 1.1); [n.layer addSublayer:g];
        CGFloat u = MAX(1.0, MIN(root.bounds.size.width / 1920.0, root.bounds.size.height / 1080.0));   // the same 1920 x 1080 canvas as the picker
        UIImageView *ic = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"ipad.landscape" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:120 * u weight:UIImageSymbolWeightLight]]];
        ic.tintColor = [UIColor colorWithWhite:1 alpha:0.9]; [ic sizeToFit];
        ic.center = CGPointMake(CGRectGetMidX(root.bounds), CGRectGetMidY(root.bounds) - 50 * u);
        ic.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
        UILabel *l = [UILabel new]; l.text = z ? @"掌機模式" : @"Handheld mode"; l.textColor = UIColor.whiteColor; l.font = [UIFont systemFontOfSize:48 * u weight:UIFontWeightBold]; [l sizeToFit];
        l.center = CGPointMake(CGRectGetMidX(root.bounds), CGRectGetMaxY(ic.frame) + 40 * u + l.bounds.size.height / 2);
        l.autoresizingMask = ic.autoresizingMask;
        [n addSubview:ic]; [n addSubview:l];
        [root addSubview:n];
    } else if (!on && n) [n removeFromSuperview];
    if (on) [root bringSubviewToFront:n];
}
// Handheld play in game with a TV connected: the TV shows the same game picture as the iPad, fitted to the TV (16:9 fills it); the game presents to the iPad's
// layer and then draws the frame again into this one (nvn_mtl.m present_mirror). Its drawable is capped at 1920 across: a copy, the TV scales it up
static void set_sdr_colorspace(CAMetalLayer *layer) {
    // The present backends put already-encoded SDR values in the drawable.
    CGColorSpaceRef color = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    layer.colorspace = color;
    CGColorSpaceRelease(color);
}
@interface DmMirrorView : UIView
@end
@implementation DmMirrorView
+ (Class)layerClass { return CAMetalLayer.class; }
- (void)layoutSubviews {
    [super layoutSubviews];
    CAMetalLayer *l = (CAMetalLayer *)self.layer; CGSize b = self.bounds.size; if (b.width <= 0) return;
    CGFloat sc = MIN(self.window.windowScene.screen.nativeScale ?: 1, MAX(1.0, 1920.0 / b.width)); l.contentsScale = sc;
    l.drawableSize = CGSizeMake(b.width * sc, b.height * sc);
}
@end
static void *_Atomic g_mirror_layer;
void *front_metal_mirror_layer(void) { return g_mirror_layer; }
static void tv_mirror(BOOL on) {
    UIView *root = g_tv.rootViewController.view;
    DmMirrorView *m = (DmMirrorView *)[root viewWithTag:78];
    if (on && root && !m) {
        m = [[DmMirrorView alloc] initWithFrame:root.bounds]; m.tag = 78; m.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        CAMetalLayer *l = (CAMetalLayer *)m.layer; l.device = MTLCreateSystemDefaultDevice(); l.pixelFormat = MTLPixelFormatBGRA8Unorm; l.framebufferOnly = NO; l.opaque = YES;
        set_sdr_colorspace(l);
        m.backgroundColor = UIColor.blackColor;
        [root addSubview:m]; [m setNeedsLayout]; [m layoutIfNeeded];
        static CAMetalLayer *keep; keep = l;   // never freed under the present thread's copy, which reads the pointer without a lock
        g_mirror_layer = (__bridge void *)l;
        LOG("front end: handheld play: the TV mirrors the game picture");
    } else if (!on) {
        g_mirror_layer = NULL;
        if (m) { [m removeFromSuperview]; LOG("front end: TV mirror off"); }
    }
    if (on && m) [root bringSubviewToFront:m];
}
// Before the game in handheld play with a TV connected: a second copy of the picker or the launcher on the TV (GamePicker.swift dm_pregame_mirror_make), on
// the same models as the iPad's, so each move on the iPad shows on the TV too, laid out for the TV. Over the Handheld mode card; gone once the game starts
__attribute__((weak)) void *dm_pregame_mirror_make(void);
static void tv_pregame_mirror(BOOL on) {
    static UIViewController *mc;
    UIViewController *root = g_tv.rootViewController;
    if (!root || mc.parentViewController != root) { [mc.view removeFromSuperview]; [mc removeFromParentViewController]; mc = nil; }   // the TV went away
    if (!root) return;
    if (on && !mc && dm_pregame_mirror_make) {
        mc = (__bridge_transfer UIViewController *)dm_pregame_mirror_make(); if (!mc) return;
        [root addChildViewController:mc]; mc.view.frame = root.view.bounds; mc.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [root.view addSubview:mc.view]; [mc didMoveToParentViewController:root];
        LOG("front end: handheld play: the TV mirrors the screen before the game");
    } else if (!on && mc) {
        [mc willMoveToParentViewController:nil]; [mc.view removeFromSuperview]; [mc removeFromParentViewController]; mc = nil;
    }
    if (on && mc) [root.view bringSubviewToFront:mc.view];
}
// A screen presented before the game (the picker, the launcher) moves to where the picture now goes: the same controller, so it keeps its state
static int g_pregame_moving;   // a move under way (the dip through black waits for it: mode_fade)
static void pregame_move(UIViewController *from, UIViewController *to) {
    UIViewController *p = from.presentedViewController;
    if (!p || !to || to == from || to.presentedViewController || p.isBeingDismissed || p.isBeingPresented) return;
    LOG("front end: the screen before the game moves to the %s", [to isKindOfClass:DmTvRootVC.class] ? "TV" : "iPad");
    UIWindow *keep = from.view.window;
    g_pregame_moving++;
    [from dismissViewControllerAnimated:NO completion:^{
        (void)keep;
        [to presentViewController:p animated:NO completion:^{
            [to.view layoutIfNeeded];
            [p.view layoutIfNeeded];
            g_pregame_moving--;
        }];
    }];
}

@interface DmGameView : UIView
@end
@implementation DmGameView
+ (Class)layerClass { return CAMetalLayer.class; }
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        CAMetalLayer *l = (CAMetalLayer *)self.layer;
        l.device = MTLCreateSystemDefaultDevice(); l.pixelFormat = MTLPixelFormatBGRA8Unorm;
        l.contentsScale = UIScreen.mainScreen.nativeScale; l.framebufferOnly = NO; l.opaque = YES;
        set_sdr_colorspace(l);
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
    // On a TV the present upscales with MetalFX (nvn_mtl.m fx_active; unless DM_PRESENT_UPSCALE=0) into the TV's own pixels up to 3840 across, so a 1440p or
    // 4K screen gets the whole enlargement sharp instead of stopping at 1920 and leaving the rest to the display's bilinear scaling
    const char *up = getenv("DM_PRESENT_UPSCALE"); BOOL fx = !(up && !strcmp(up, "0"));
    if (self.window && self.window == g_tv && self.bounds.size.width > 0) sc = MIN(sc, MAX(1.0, (fx ? 3840.0 : 1920.0) / self.bounds.size.width));
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
static atomic_bool g_guest_started;
static UIWindow *root_window(void) { return g_root.view.window; }
// Handheld <-> console: each screen keeps a still of what it showed, in a window of its own above everything (the picker and the launcher are presented
// again a moment later by pregame_move, which would land over a still inside the same window), while the change happens under it; the still then fades
// out with a slight zoom, so the new screen comes up through it in one smooth step. A screen that showed nothing (the TV's window hidden) starts from black
static UIWindow *mode_still(UIWindowScene *scene, UIWindow *from) {
    if (!scene) return nil;
    UIView *still = from && !from.hidden ? [from snapshotViewAfterScreenUpdates:NO] : nil;
    UIWindow *w = [[UIWindow alloc] initWithWindowScene:scene];
    w.frame = scene.coordinateSpace.bounds; w.windowLevel = UIWindowLevelAlert + 2; w.userInteractionEnabled = NO; w.backgroundColor = UIColor.clearColor;
    UIViewController *vc = [UIViewController new]; w.rootViewController = vc; vc.view.backgroundColor = UIColor.clearColor;
    UIView *black = [[UIView alloc] initWithFrame:w.bounds]; black.backgroundColor = UIColor.blackColor; black.tag = 2;
    black.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight; [vc.view addSubview:black];
    if (still) { still.frame = w.bounds; still.tag = 1; still.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight; [vc.view addSubview:still]; }
    w.hidden = NO;
    return w;
}
// The picker and the settings each own a controller. Keep the outgoing TV frame
// through both controller changes, then fade it once the incoming view is ready.
static UIWindow *g_picker_cover;
bool front_ios_picker_cover_begin(void) {
    if (!tv_on() || g_picker_cover) return false;
    UIWindow *cover = mode_still(g_tv_scene, g_tv);
    if (![cover.rootViewController.view viewWithTag:1]) { cover.hidden = YES; return false; }
    g_picker_cover = cover;
    return true;
}
bool front_ios_picker_cover_active(void) { return g_picker_cover != nil; }
void front_ios_picker_cover_end(void) {
    UIWindow *cover = g_picker_cover;
    if (!cover) return;
    g_picker_cover = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled() ? 0 : 0.24
                         animations:^{ cover.alpha = 0; }
                         completion:^(BOOL finished) { (void)finished; cover.hidden = YES; }];
    });
}
static int g_mode_fades;
static int g_pending_mode = -1;
static void play_pending_mode(void) {
    if (g_mode_fades || g_pending_mode < 0) return;
    BOOL handheld = g_pending_mode == 1;
    g_pending_mode = -1;
    play_mode_set(handheld);
}
static void mode_fade(UIWindow *w) {
    if (!w) return;
    g_mode_fades++;
    CFTimeInterval start = CACurrentMediaTime();
    __block void (^reveal)(void);
    reveal = ^{
        if (g_pregame_moving && CACurrentMediaTime() - start < 1.6) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 16 * NSEC_PER_MSEC), dispatch_get_main_queue(), reveal);
            return;
        }
        reveal = nil;
        // Keep the outgoing frame visible until the new scene has committed its own layout.
        [CATransaction begin];
        [g_root.view layoutIfNeeded];
        [g_tv.rootViewController.view layoutIfNeeded];
        [CATransaction setCompletionBlock:^{
            [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled() ? 0 : 0.17 delay:0
                                options:UIViewAnimationOptionCurveEaseOut
                             animations:^{ w.alpha = 0; }
                             completion:^(BOOL finished) {
                (void)finished;
                w.hidden = YES;
                g_mode_fades--;
                if (!g_mode_fades) dispatch_async(dispatch_get_main_queue(), ^{ play_pending_mode(); });
            }];
        }];
        [CATransaction commit];
    };
    dispatch_async(dispatch_get_main_queue(), reveal);
}
@interface DmDisplaySample : NSObject
@property(nonatomic) CFTimeInterval firstTick;
@property(nonatomic) NSUInteger ticks;
- (void)recordTick:(CADisplayLink *)link;
@end

@implementation DmDisplaySample
- (void)recordTick:(CADisplayLink *)link {
    if (!self.ticks) self.firstTick = link.timestamp;
    CFTimeInterval elapsed = link.timestamp - self.firstTick;
    if (elapsed >= 1.5) {
        LOG("front end: TV display link measured %.1f Hz over %.2f s", self.ticks / elapsed, elapsed);
        [link invalidate];
        return;
    }
    self.ticks++;
}
@end

static void tv_sample_refresh(UIWindowScene *scene) {
    DmDisplaySample *sample = [DmDisplaySample new];
    CADisplayLink *link = [scene.screen displayLinkWithTarget:sample selector:@selector(recordTick:)];
    if (!link) return;
    [link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [link invalidate]; });
}

static void mode_transition(void (^change)(void)) {
    UIWindow *ipad = g_root.view.window, *a = mode_still(ipad.windowScene, ipad);
    UIWindowScene *tvs = g_tv_scene; UIWindow *b = mode_still(tvs, g_tv);   // still the screen before the change (black while its window is hidden)
    change();
    mode_fade(a);
    if (g_tv_scene == tvs) mode_fade(b); else b.hidden = YES;   // the TV went away: its still goes with it
}
static void launcher_done(void) { [g_root startGame]; }
static void picker_done(void) { [g_root afterPick]; }
static UIViewController *pregame_host(void) {   // where the picker and the launcher are presented: the TV's window while the picture goes there
    tv_window_ensure();
    return tv_on() ? g_tv.rootViewController : g_root;
}
// The launcher's Back to the game list (Launcher.swift), once it has gone away: the picker again, as at launch
void front_ios_back_to_picker(void) {
    if (shell_game_unchoose()) dm_show_picker((__bridge void *)pregame_host(), picker_done);
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
    g_play_started = CACurrentMediaTime();
    // A Joy-Con joining before Play can query and cache the operation mode. Apply the final setting before the guest starts.
    const char *mode = getenv("DM_OPMODE");
    if (mode && (!strcmp(mode, "0") || !strcmp(mode, "1"))) dm_set_opmode(mode[0] - '0');
    front_hud_env();   // before the game view makes its device (an env file's DM_METAL_HUD sets it in main.m already)
    self.stage = [[UIView alloc] initWithFrame:self.view.bounds]; self.stage.backgroundColor = UIColor.blackColor;
    self.game = [[DmGameView alloc] initWithFrame:self.view.bounds];
    atomic_store(&g_guest_started, true);
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
    front_ios_picker_cover_end();
    UIApplication.sharedApplication.idleTimerDisabled = YES;
    run_watch_start();
    front_ios_boot();
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutStage];
    if (self.menuButton) { UIEdgeInsets in = self.view.safeAreaInsets; self.menuButton.frame = tv_on() ? CGRectMake(MAX(32, in.left), MAX(32, in.top) + 8, 104, 44) : CGRectMake(floor(self.view.bounds.size.width / 2) - 22, self.view.bounds.size.height - MAX(12, in.bottom) - 44, 44, 44); }   // handheld: bottom centre, the one place the touch controls leave free (ZL sits in the top corners, − / + and the layout button at the top centre)
}
- (void)layoutStage {
    if (!self.game || !self.stage.superview) return;
    self.stage.frame = self.stage.superview.bounds;
    CGRect b = self.stage.bounds; CGFloat w = b.size.width, h = b.size.height;   // Fit 16:9 into the whole screen (the iPad's, or the TV's, which is 16:9 itself)
    if (w <= 0 || h <= 0) return;
    if (w / h > 16.0 / 9.0) w = h * 16.0 / 9.0; else h = w * 9.0 / 16.0;
    self.game.frame = CGRectMake(floor((b.size.width - w) / 2), floor((b.size.height - h) / 2), w, h);
    if (self.fps) {   // the game picture's top-left corner, inside the picture, so it reads as part of the game view rather than floating in the black bar
        CGRect g = self.game.frame;
        BOOL external = self.stage.window == g_tv && g_tv != nil;
        CGFloat unit = external ? MIN(g.size.width / 1920, g.size.height / 1080) : 1;
        CGFloat font = external ? MAX(16, 25 * unit) : 14;
        CGFloat pad = MAX(8, 10 * unit);
        UIEdgeInsets safe = external ? self.stage.window.windowScene.screen.overscanCompensationInsets : self.stage.safeAreaInsets;
        self.fps.font = [UIFont monospacedDigitSystemFontOfSize:font weight:UIFontWeightSemibold];
        self.fps.layer.cornerRadius = font * 0.4;
        self.fps.frame = CGRectMake(MAX(CGRectGetMinX(g), safe.left) + pad, MAX(CGRectGetMinY(g), safe.top) + pad, font * 5, font * 1.65);
    }
}
// The game's picture on the TV while one is connected (its window made now), else on the iPad under the touch controls. The Metal layer itself moves with its view,
// so the graphics backend keeps presenting to the same layer (front_metal_layer); its drawable follows the new size and scale (DmGameView layoutSubviews)
// Before the game, with a TV connected and the picture moved to the iPad (the panel's Picture switch): the picker and the launcher show their own Back to the TV
// button in their layout (GamePicker.swift / Launcher.swift), asking here whether to (front_ios_tv_waiting, again on each DMShellChanged) and calling
// front_ios_back_to_tv. A floating button of its own covered what was under it (art47)
static void output_video_set(BOOL ipad);
// Before the game in handheld play with a TV connected: the controller the picker and the launcher present their TV copy on (the same screen as the iPad, fitted
// to the TV, its selection following the iPad's), nil otherwise; asked again on each DMShellChanged
int front_ios_game_started(void) { return atomic_load(&g_guest_started); }
void *front_ios_tv_mirror_host(void) { return g_tv && video_pref_ipad() && g_root && !g_root.game ? (__bridge void *)g_tv.rootViewController : NULL; }
int front_ios_tv_waiting(void) { return g_tv_scene && video_pref_ipad() && g_root && !g_root.game; }
void front_ios_back_to_tv(void) { dispatch_async(dispatch_get_main_queue(), ^{ LOG("front end: Back to the TV tapped"); play_mode_set(NO); }); }
- (void)placeStage {
    tv_window_ensure();
    tv_handheld_note(g_tv && video_pref_ipad());
    tv_mirror(g_tv && video_pref_ipad() && self.game);   // in game: the TV shows the same picture (nvn_mtl.m present_mirror)
    tv_pregame_mirror(g_tv && video_pref_ipad() && !self.game && self.launched);   // before it: the picker's / launcher's synced copy
    g_picture_on_tv = tv_on();
    if (self.stage) {
        UIView *dest = tv_on() ? g_tv.rootViewController.view : self.view;
        if (self.stage.superview != dest) {
            [self.stage removeFromSuperview];
            if (dest == self.view) [self.view insertSubview:self.stage atIndex:0]; else [dest insertSubview:self.stage atIndex:0];
            [self layoutStage]; [self.game setNeedsLayout];
            for (UIView *v in @[g_loading ?: NSNull.null, g_prog ?: NSNull.null, g_menu ?: NSNull.null])   // what covers the picture goes with it
                if ([v isKindOfClass:UIView.class]) {
                    UIView *root = overlay_root();
                    [v removeFromSuperview]; v.frame = root.bounds; [root addSubview:v];
                    [v setNeedsLayout]; [v layoutIfNeeded];
                }
        }
    } else if (g_tv && self.launched) {   // before the game: the picker or the launcher follows the picture
        if (tv_on()) pregame_move(self, g_tv.rootViewController); else pregame_move(g_tv.rootViewController, self);
    }
    BOOL tv = tv_on();
    if (tv && !self.tvNote) { self.tvNote = tv_panel(self.view.bounds); [self.view insertSubview:self.tvNote atIndex:0]; }
    self.tvNote.hidden = !tv;
    self.pad.hidden = tv;   // console play: no touch controls over the iPad's panel, which has its own controls
    self.menuButton.hidden = YES;   // the TV panel's own Pause button; handheld: the touch controls' ⌂ key
    tv_copies_sync();
    [self.view setNeedsLayout];
    front_ios_audio_session();   // the TV came or went: the sound follows the choice for TV play (audio_on_ipad)
}
- (void)menuTapped { home_menu_toggle(); }
// What the iPad shows while the picture is on the TV: the phones' QR code (friends scan it from the sofa) and who is playing, kept current;
// the touch controls stay over it while no controller is connected
static UIColor *player_color(int p) {   // each player's own colour (1-based), the same on every screen of the panel
    static const uint32_t c[8] = {0x0A84FF, 0xFF453A, 0x30D158, 0xFFD60A, 0xBF5AF2, 0xFF9F0A, 0x40C8E0, 0xFF375F};
    uint32_t x = c[(p - 1) & 7]; return [UIColor colorWithRed:(x >> 16) / 255.0 green:((x >> 8) & 255) / 255.0 blue:(x & 255) / 255.0 alpha:1];
}
static UIView *glass_card(void) {   // a frosted rounded card with a hairline edge
    UIVisualEffectView *g = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
    g.layer.cornerRadius = 28; g.layer.cornerCurve = kCACornerCurveContinuous; g.clipsToBounds = YES;
    g.layer.borderWidth = 1; g.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.1].CGColor;
    g.contentView.backgroundColor = [UIColor colorWithWhite:1 alpha:0.04];
    return g;
}
static UILabel *panel_label(CGFloat size, UIFontWeight w, CGFloat white) {
    UILabel *l = [UILabel new]; l.font = [UIFont systemFontOfSize:size weight:w]; l.textColor = [UIColor colorWithWhite:white alpha:1]; return l;
}
// What the iPad shows while the picture is on the TV, like a console's second screen, and where everything the Home menu does is done by touch (the TV's menu is
// not copied here): the game and its state; the players card (the eight numbers in each player's colour, a tap on one for its actions, the phones' QR code to join);
// the controls card (pause, volume, picture and sound output, change games, close); the time and the battery. Landscape puts the cards side by side, portrait stacks them
static UIButton *panel_button(NSString *title, NSString *sym, UIColor *bg, UIColor *fg, void (^tap)(void)) {
    UIButtonConfiguration *c = [UIButtonConfiguration filledButtonConfiguration];
    c.title = title; c.image = sym ? [UIImage systemImageNamed:sym withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightSemibold]] : nil;
    c.imagePadding = 10; c.baseBackgroundColor = bg; c.baseForegroundColor = fg; c.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    c.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *in) { NSMutableDictionary *o = [in mutableCopy]; o[NSFontAttributeName] = [UIFont systemFontOfSize:19 weight:UIFontWeightSemibold]; return o; };
    UIButton *b = [UIButton buttonWithConfiguration:c primaryAction:[UIAction actionWithHandler:^(UIAction *a) { (void)a; tap(); }]];
    return b;
}
static UISegmentedControl *panel_segments(NSArray<NSString *> *items, void (^changed)(NSInteger)) {
    UISegmentedControl *sg = [[UISegmentedControl alloc] initWithItems:items];
    sg.selectedSegmentTintColor = [UIColor colorWithRed:0.04 green:0.52 blue:1 alpha:1];
    [sg setTitleTextAttributes:@{NSForegroundColorAttributeName: UIColor.whiteColor, NSFontAttributeName: [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold]} forState:UIControlStateSelected];
    [sg setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.7], NSFontAttributeName: [UIFont systemFontOfSize:17 weight:UIFontWeightMedium]} forState:UIControlStateNormal];
    __weak UISegmentedControl *w = sg;
    [sg addAction:[UIAction actionWithHandler:^(UIAction *a) { (void)a; changed(w.selectedSegmentIndex); }] forControlEvents:UIControlEventValueChanged];
    return sg;
}
static void panel_confirm(NSString *title, NSString *msg, NSString *ok, void (^go)(void)) {   // closing loses unsaved progress: asked first
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:zh_ui() ? @"取消" : @"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:ok style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) { (void)x; go(); }]];
    UIViewController *top = g_root; while (top.presentedViewController) top = top.presentedViewController;
    [top presentViewController:ac animated:YES completion:nil];
}
static UIView *tv_panel(CGRect frame) {
    BOOL z = zh_ui();
    const char *ng = getenv("DM_SHELL_GAMES"); BOOL several = ng && atoi(ng) > 1;
    DmLayoutView *v = [[DmLayoutView alloc] initWithFrame:frame]; v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    v.backgroundColor = [UIColor colorWithRed:0.02 green:0.025 blue:0.04 alpha:1]; v.clipsToBounds = YES;
    // the backdrop: two soft glows drifting slowly
    CAGradientLayer *g1 = [CAGradientLayer layer], *g2 = [CAGradientLayer layer];
    g1.type = kCAGradientLayerRadial; g1.colors = @[(id)[UIColor colorWithRed:0.04 green:0.4 blue:1 alpha:0.32].CGColor, (id)UIColor.clearColor.CGColor];
    g2.type = kCAGradientLayerRadial; g2.colors = @[(id)[UIColor colorWithRed:0.6 green:0.25 blue:0.9 alpha:0.22].CGColor, (id)UIColor.clearColor.CGColor];
    for (CAGradientLayer *g in @[g1, g2]) { g.startPoint = CGPointMake(0.5, 0.5); g.endPoint = CGPointMake(1, 1); [v.layer addSublayer:g]; }
    // the header: the game's name (SwitchPad before one is chosen) and a live tag; the time and the battery on the right
    UILabel *title = panel_label(42, UIFontWeightBold, 1); title.adjustsFontSizeToFitWidth = YES; title.minimumScaleFactor = 0.6;
    UIView *live = [UIView new]; live.backgroundColor = [UIColor colorWithWhite:1 alpha:0.1]; live.layer.cornerRadius = 12; live.layer.cornerCurve = kCACornerCurveContinuous;
    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(14, 11, 10, 10)]; dot.layer.cornerRadius = 5;
    CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"opacity"]; pulse.fromValue = @1; pulse.toValue = @0.25; pulse.duration = 1.1; pulse.autoreverses = YES; pulse.repeatCount = HUGE_VALF;
    [dot.layer addAnimation:pulse forKey:@"pulse"];
    UILabel *lt = panel_label(17, UIFontWeightSemibold, 0.9); [live addSubview:dot]; [live addSubview:lt];
    UILabel *clock = [UILabel new]; clock.font = [UIFont monospacedDigitSystemFontOfSize:24 weight:UIFontWeightSemibold]; clock.textColor = [UIColor colorWithWhite:1 alpha:0.85]; clock.textAlignment = NSTextAlignmentRight;
    UIImageView *bat = [UIImageView new]; bat.contentMode = UIViewContentModeScaleAspectFit;
    UILabel *batl = [UILabel new]; batl.font = [UIFont monospacedDigitSystemFontOfSize:22 weight:UIFontWeightSemibold]; batl.textColor = [UIColor colorWithWhite:1 alpha:0.85];
    UIImageView *wifi = [UIImageView new]; wifi.contentMode = UIViewContentModeScaleAspectFit; wifi.tintColor = [UIColor colorWithWhite:1 alpha:0.85];
    wifi.image = [UIImage systemImageNamed:@"wifi" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightSemibold]];
    for (UIView *x in @[title, live, clock, bat, batl, wifi]) [v addSubview:x];
    {   // Wi-Fi or Wi-Fi slashed, as the picker shows it (GamePicker.swift)
        static nw_path_monitor_t mon; __weak UIImageView *ww = wifi;
        if (mon) nw_path_monitor_cancel(mon);
        mon = nw_path_monitor_create(); nw_path_monitor_set_queue(mon, dispatch_get_main_queue());
        nw_path_monitor_set_update_handler(mon, ^(nw_path_t path) {
            ww.image = [UIImage systemImageNamed:nw_path_uses_interface_type(path, nw_interface_type_wifi) ? @"wifi" : @"wifi.slash"
                               withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightSemibold]];
        });
        nw_path_monitor_start(mon);
    }
    UIDevice.currentDevice.batteryMonitoringEnabled = YES;
    __weak UILabel *wc = clock, *wbl = batl; __weak UIImageView *wb = bat;
    void (^tick)(void) = ^{
        NSDateFormatter *df = [NSDateFormatter new]; df.dateStyle = NSDateFormatterNoStyle; df.timeStyle = NSDateFormatterShortStyle;   // as the picker's Text(.time) wc.text = [df stringFromDate:NSDate.date];
        float lv = UIDevice.currentDevice.batteryLevel; UIDeviceBatteryState st = UIDevice.currentDevice.batteryState;
        BOOL plug = st == UIDeviceBatteryStateCharging || st == UIDeviceBatteryStateFull;
        NSString *sym = lv < 0 ? @"battery.100percent" : plug ? @"battery.100percent.bolt" : lv >= 0.88 ? @"battery.100percent" : lv >= 0.63 ? @"battery.75percent"   // the picker's symbols and steps
                      : lv >= 0.38 ? @"battery.50percent" : lv >= 0.13 ? @"battery.25percent" : @"battery.0percent";
        wb.image = [UIImage systemImageNamed:sym withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightRegular]];
        wb.tintColor = !plug && lv >= 0 && lv <= 0.12 ? [UIColor colorWithRed:1 green:0.27 blue:0.23 alpha:1] : [UIColor colorWithWhite:0.85 alpha:1];
        wbl.text = lv < 0 ? @"" : [NSString stringWithFormat:@"%d%%", (int)lroundf(lv * 100)];
    };
    tick();
    [NSTimer scheduledTimerWithTimeInterval:15 repeats:YES block:^(NSTimer *t) { if (!wc) { [t invalidate]; return; } tick(); }];

    // ---- the players card: the QR code to join on the left, the eight numbers on the right ----
    UIView *pc = glass_card(); [v addSubview:pc];
    UIView *pcv = ((UIVisualEffectView *)pc).contentView;
    UILabel *pt = panel_label(28, UIFontWeightBold, 1); pt.text = z ? @"玩家" : @"Players";
    UILabel *pn = panel_label(20, UIFontWeightSemibold, 0.55);
    UIView *qr = [UIView new]; qr.backgroundColor = UIColor.whiteColor; qr.layer.cornerRadius = 18; qr.layer.cornerCurve = kCACornerCurveContinuous;
    UIImageView *qi = [UIImageView new]; qi.layer.magnificationFilter = kCAFilterNearest; qi.contentMode = UIViewContentModeScaleAspectFit; [qr addSubview:qi];
    UILabel *jt = panel_label(20, UIFontWeightSemibold, 1); jt.text = z ? @"用手機加入" : @"Join with a phone"; jt.textAlignment = NSTextAlignmentCenter;
    __weak UIView *wqr = qr;
    __weak UIImageView *wqi = qi;
    __weak UILabel *wjt = jt;
    __block NSString *lastAddress;
    void (^updateQR)(void) = ^{
        NSString *address = phone_address();
        if (address != lastAddress && ![address isEqualToString:lastAddress]) {
            lastAddress = address;
            wqi.image = phone_code(address);
        }
        wqr.hidden = wqi.image == nil;
        wjt.hidden = wqr.hidden;
    };
    updateQR();
    [NSTimer scheduledTimerWithTimeInterval:3 repeats:YES block:^(NSTimer *timer) {
        if (wqr) updateQR();
        else [timer invalidate];
    }];
    UIView *grid = [UIView new];
    for (UIView *x in @[pt, pn, qr, jt, grid]) [pcv addSubview:x];

    // ---- the controls card ----
    UIView *cc = glass_card(); [v addSubview:cc];
    UIView *ccv = ((UIVisualEffectView *)cc).contentView;
    UILabel *ct = panel_label(28, UIFontWeightBold, 1); ct.text = z ? @"控制" : @"Controls";
    UIColor *accent = [UIColor colorWithRed:0.04 green:0.52 blue:1 alpha:1];
    UIButton *pause = panel_button(@"", @"pause.fill", accent, UIColor.whiteColor, ^{ if (g_root.game) home_menu_toggle(); });
    UIImageView *vlo = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"speaker.fill"]], *vhi = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"speaker.wave.3.fill"]];
    for (UIImageView *x in @[vlo, vhi]) { x.tintColor = [UIColor colorWithWhite:1 alpha:0.7]; x.contentMode = UIViewContentModeScaleAspectFit; }
    UISlider *vol = volume_slider(z); vol.minimumTrackTintColor = accent;
    __weak UISlider *wvol = vol;
    UILabel *vl = panel_label(20, UIFontWeightSemibold, 0.85); vl.textAlignment = NSTextAlignmentRight;
    UILabel *vidl = panel_label(18, UIFontWeightSemibold, 0.65); vidl.text = z ? @"模式" : @"Mode";
    UISegmentedControl *vid = panel_segments(z ? @[@"主機模式", @"掌機模式"] : @[@"Console", @"Handheld"], ^(NSInteger i) {
        play_mode_set(i == 1);
    });
    UILabel *audl = panel_label(18, UIFontWeightSemibold, 0.65); audl.text = z ? @"聲音輸出" : @"Sound";
    UISegmentedControl *aud = panel_segments(z ? @[@"電視", @"iPad 喇叭"] : @[@"TV", @"iPad speaker"], ^(NSInteger i) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ output_audio_set(i == 1); });
    });
    UIButton *change = panel_button(z ? @"換遊戲" : @"Change games", @"square.grid.2x2.fill", [UIColor colorWithWhite:1 alpha:0.12], UIColor.whiteColor, ^{
        panel_confirm(z ? @"換遊戲？" : @"Change games?", z ? @"未存檔的進度會遺失。" : @"Unsaved progress is lost.", z ? @"換遊戲" : @"Change games", ^{ home_menu_quit(1); });
    });
    UIButton *quit = panel_button(z ? @"關閉遊戲" : @"Close", @"power", [UIColor colorWithWhite:1 alpha:0.12], [UIColor colorWithRed:1 green:0.27 blue:0.23 alpha:1], ^{
        panel_confirm(z ? @"關閉遊戲？" : @"Close the game?", z ? @"未存檔的進度會遺失。" : @"Unsaved progress is lost.", z ? @"關閉" : @"Close", ^{ home_menu_quit(0); });
    });
    for (UIView *x in @[ct, pause, vlo, vol, vhi, vl, audl, aud, vidl, vid, change, quit]) [ccv addSubview:x];
    // what the controls show: the game's state, the volume, the outputs (the menu on the TV and this panel change the same things)
    __weak UIButton *wpause = pause, *wchange = change, *wquit = quit; __weak UILabel *wvl = vl, *wtitle = title, *wlt = lt; __weak UISegmentedControl *wvid = vid, *waud = aud; __weak UIView *wdot = dot, *wlive = live;
    void (^sync)(void) = ^{
        BOOL game = g_root.game != nil, paused = g_menu != nil && !g_menu_closing;
        wtitle.text = game ? game_name() : @"SwitchPad";
        wlt.text = !game ? (z ? @"在電視上選擇遊戲" : @"Choose a game on the TV") : paused ? (z ? @"已暫停" : @"Paused") : (z ? @"遊戲中" : @"Playing");
        [wlt sizeToFit]; wlt.frame = CGRectMake(32, 0, wlt.bounds.size.width, 32);
        CGRect lf = wlive.frame; lf.size = CGSizeMake(32 + wlt.bounds.size.width + 14, 32); wlive.frame = lf;
        wdot.backgroundColor = paused ? [UIColor colorWithRed:1 green:0.62 blue:0.04 alpha:1] : [UIColor colorWithRed:0.19 green:0.82 blue:0.35 alpha:1];
        UIButtonConfiguration *c = wpause.configuration;
        c.title = !game ? (z ? @"暫停" : @"Pause") : paused ? (z ? @"繼續遊戲" : @"Continue") : (z ? @"暫停遊戲" : @"Pause");
        c.image = [UIImage systemImageNamed:paused ? @"play.fill" : @"pause.fill" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightSemibold]];
        wpause.configuration = c; wpause.enabled = game;
        wchange.hidden = !(game && several); wquit.hidden = !game;
        if (!wvol.isTracking) wvol.value = volume_pref();
        wvl.text = [NSString stringWithFormat:@"%d%%", (int)lroundf(volume_pref() * 100)];
        wvid.selectedSegmentIndex = video_pref_ipad() ? 1 : 0;
        waud.selectedSegmentIndex = [NSUserDefaults.standardUserDefaults boolForKey:@"DMAudioOnIPad"] ? 1 : 0;
    };
    sync();

    // the player places: filled from shell_players.m's list ([player, kind, label, name, xbox]); a tap opens what can be done with that player; a newly taken place pops in
    __weak UIView *wg = grid; __weak UILabel *wpn = pn;
    __block NSArray *last = @[]; NSMutableSet *held = [NSMutableSet set];
    void (^fill)(NSArray *) = ^(NSArray *players) {
        UIView *gr = wg; if (!gr) return; last = players ?: @[];
        NSMutableDictionary *by = [NSMutableDictionary dictionary];
        for (NSArray *r in last) if ([r isKindOfClass:NSArray.class] && r.count >= 3) by[@([r[0] intValue])] = r;
        wpn.text = [NSString stringWithFormat:@"%lu / 8", (unsigned long)by.count];
        for (UIView *x in gr.subviews) [x removeFromSuperview];
        CGFloat W = gr.bounds.size.width, H = gr.bounds.size.height, gap = 10, cw = (W - gap) / 2, ch = MIN(104, (H - 3 * gap) / 4);
        for (int p = 1; p <= 8; p++) {
            NSArray *r = by[@(p)]; int col = (p - 1) / 4, rowi = (p - 1) % 4;
            UIButton *t = [UIButton buttonWithType:UIButtonTypeCustom]; t.frame = CGRectMake(col * (cw + gap), rowi * (ch + gap), cw, ch);
            t.layer.cornerRadius = 20; t.layer.cornerCurve = kCACornerCurveContinuous;
            t.backgroundColor = [UIColor colorWithWhite:1 alpha:r ? 0.09 : 0.03];
            if (!r) { t.layer.borderWidth = 1; t.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.06].CGColor; }
            // a big number on the player's colour, the name beside it in large type; nothing smaller (it is read from arm's length or the sofa)
            CGFloat bs = MIN(56, ch - 24);
            UILabel *b = [[UILabel alloc] initWithFrame:CGRectMake(14, (ch - bs) / 2, bs, bs)]; b.userInteractionEnabled = NO;
            b.text = [NSString stringWithFormat:@"P%d", p]; b.textAlignment = NSTextAlignmentCenter; b.font = [UIFont systemFontOfSize:21 weight:UIFontWeightHeavy];
            b.layer.cornerRadius = 14; b.layer.cornerCurve = kCACornerCurveContinuous; b.layer.masksToBounds = YES;
            b.backgroundColor = r ? player_color(p) : [UIColor colorWithWhite:1 alpha:0.06]; b.textColor = r ? UIColor.whiteColor : [UIColor colorWithWhite:1 alpha:0.3];
            [t addSubview:b];
            CGFloat nx = 14 + bs + 14;
            if (r) {
                BOOL phone = [r[1] intValue] == 2, xbox = r.count > 4 && [r[4] boolValue];
                UILabel *nm = [[UILabel alloc] initWithFrame:CGRectMake(nx, 0, cw - nx - 44, ch)]; nm.userInteractionEnabled = NO;
                nm.text = [r[2] description]; nm.textColor = UIColor.whiteColor; nm.font = [UIFont systemFontOfSize:21 weight:UIFontWeightSemibold];
                nm.adjustsFontSizeToFitWidth = YES; nm.minimumScaleFactor = 0.7; [t addSubview:nm];
                UIImageView *ic = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:phone ? @"iphone" : @"gamecontroller.fill" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:19 weight:UIImageSymbolWeightSemibold]]];
                ic.tintColor = [UIColor colorWithWhite:1 alpha:0.55]; ic.contentMode = UIViewContentModeCenter; ic.frame = CGRectMake(cw - 42, 0, 28, ch); ic.userInteractionEnabled = NO; [t addSubview:ic];
                // what can be done with this player: number (swap), layout, identify, remove; the same commands the launcher uses (shell_players.m)
                NSMutableArray *to = [NSMutableArray array];
                for (int q = 1; q <= 8; q++) if (q != p) {
                    NSArray *o = by[@(q)];
                    NSString *tt = o ? [NSString stringWithFormat:z ? @"P%d（和 %@ 對調）" : @"P%d (swap with %@)", q, [o[2] description]] : [NSString stringWithFormat:@"P%d", q];
                    [to addObject:[UIAction actionWithTitle:tt image:nil identifier:nil handler:^(UIAction *a) { (void)a; slot_swap(p - 1, q - 1); }]];
                }
                NSMutableArray *items = [NSMutableArray array];
                if (p != 1) [items addObject:[UIAction actionWithTitle:z ? @"設為 P1" : @"Make player 1" image:[UIImage systemImageNamed:@"1.circle"] identifier:nil handler:^(UIAction *a) { (void)a; slot_swap(p - 1, 0); }]];
                [items addObject:[UIMenu menuWithTitle:z ? @"換號碼" : @"Change number" image:[UIImage systemImageNamed:@"arrow.up.arrow.down"] identifier:nil options:0 children:to]];
                [items addObject:[UIAction actionWithTitle:xbox ? (z ? @"按鍵配置：改成 Switch" : @"Layout: Switch") : (z ? @"按鍵配置：改成 Xbox" : @"Layout: Xbox") image:[UIImage systemImageNamed:@"gamecontroller"] identifier:nil handler:^(UIAction *a) { (void)a; slot_layout(p - 1); }]];
                [items addObject:[UIAction actionWithTitle:z ? @"辨識（震動）" : @"Identify" image:[UIImage systemImageNamed:@"wave.3.right"] identifier:nil handler:^(UIAction *a) { (void)a; slot_identify(p - 1); }]];
                UIAction *rm = [UIAction actionWithTitle:z ? @"移除" : @"Remove" image:[UIImage systemImageNamed:@"xmark.circle"] identifier:nil handler:^(UIAction *a) { (void)a; slot_remove(p - 1); }];
                rm.attributes = UIMenuElementAttributesDestructive; [items addObject:rm];
                t.menu = [UIMenu menuWithTitle:[NSString stringWithFormat:@"P%d · %@", p, [r[2] description]] children:items]; t.showsMenuAsPrimaryAction = YES;
                if (![held containsObject:@(p)]) {   // just joined
                    t.alpha = 0; t.transform = CGAffineTransformMakeScale(0.85, 0.85);
                    [UIView animateWithDuration:0.5 delay:0.04 * rowi usingSpringWithDamping:0.7 initialSpringVelocity:0.4 options:0 animations:^{ t.alpha = 1; t.transform = CGAffineTransformIdentity; } completion:nil];
                }
            } else {
                UILabel *e = [[UILabel alloc] initWithFrame:CGRectMake(nx, 0, cw - nx - 10, ch)]; e.userInteractionEnabled = NO;
                e.text = z ? @"空位" : @"Open"; e.textColor = [UIColor colorWithWhite:1 alpha:0.25]; e.font = [UIFont systemFontOfSize:20 weight:UIFontWeightMedium]; [t addSubview:e];
            }
            t.tag = p; [gr addSubview:t];
            if (r) {   // drag a player onto another number (taken or open) to swap: the tile lifts, follows the finger, the place under it lights up
                UIPanGestureRecognizer *pan = [UIPanGestureRecognizer new];
                __block UIView *over = nil; __block CGPoint home; __block CGFloat ow = 0; __block UIColor *oc = nil;
                gesture_block(pan, ^(UIPanGestureRecognizer *g) {
                    UIView *me = g.view, *grid = me.superview; if (!grid) return;
                    if (g.state == UIGestureRecognizerStateBegan) {
                        home = me.center; [grid bringSubviewToFront:me];
                        me.layer.shadowColor = UIColor.blackColor.CGColor; me.layer.shadowOpacity = 0.5; me.layer.shadowRadius = 18; me.layer.shadowOffset = CGSizeMake(0, 10);
                        [UIView animateWithDuration:0.25 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0.3 options:0 animations:^{ me.transform = CGAffineTransformMakeScale(1.06, 1.06); me.alpha = 0.95; } completion:nil];
                        [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
                    } else if (g.state == UIGestureRecognizerStateChanged) {
                        CGPoint d = [g translationInView:grid]; me.center = CGPointMake(home.x + d.x, home.y + d.y);
                        UIView *hit = nil;
                        for (UIView *o in grid.subviews) if (o != me && o.tag >= 1 && o.tag <= 8 && CGRectContainsPoint(o.frame, me.center)) hit = o;
                        if (hit != over) {
                            over.layer.borderWidth = ow; over.layer.borderColor = oc.CGColor;   // as it was (an open place has a faint edge)
                            over = hit; ow = hit.layer.borderWidth; oc = hit.layer.borderColor ? [UIColor colorWithCGColor:hit.layer.borderColor] : nil; over.layer.borderWidth = 2; over.layer.borderColor = player_color((int)me.tag).CGColor;
                            if (hit) [[UISelectionFeedbackGenerator new] selectionChanged];
                        }
                    } else if (g.state >= UIGestureRecognizerStateEnded) {
                        UIView *to = g.state == UIGestureRecognizerStateEnded ? over : nil; over.layer.borderWidth = ow; over.layer.borderColor = oc.CGColor; over = nil;
                        if (to) {   // the list comes back from shell_players.m (DMPlayersChanged) and is drawn again with the new numbers
                            CGPoint c = to.center;
                            [UIView animateWithDuration:0.2 animations:^{ me.center = c; to.center = home; me.transform = CGAffineTransformIdentity; }];
                            slot_swap((int)me.tag - 1, (int)to.tag - 1);
                        } else {
                            [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.75 initialSpringVelocity:0.2 options:0 animations:^{ me.center = home; me.transform = CGAffineTransformIdentity; me.alpha = 1; } completion:^(BOOL f) { (void)f; me.layer.shadowOpacity = 0; }];
                        }
                    }
                });
                [t addGestureRecognizer:pan];
            }
        }
        [held removeAllObjects]; [held addObjectsFromArray:by.allKeys];
    };
    v.layout = ^(UIView *me) {
        CGSize S = me.bounds.size; UIEdgeInsets in = me.safeAreaInsets;
        CGFloat m = 28, L = MAX(m, in.left), R = S.width - MAX(m, in.right), T = MAX(m, in.top) + 4, B = S.height - MAX(m, in.bottom);
        [CATransaction begin]; [CATransaction setDisableActions:YES];
        g1.frame = CGRectMake(-S.width * 0.3, -S.height * 0.4, S.width * 1.1, S.width * 1.1);
        g2.frame = CGRectMake(S.width * 0.4, S.height * 0.3, S.width * 0.9, S.width * 0.9);
        [CATransaction commit];
        title.frame = CGRectMake(L, T, R - L - 260, 50);
        CGRect lf = live.frame; lf.origin = CGPointMake(L, T + 58); live.frame = lf;
        // as the picker's top right: time, Wi-Fi, percent, battery
        bat.frame = CGRectMake(R - 40, T + 10, 40, 30); batl.textAlignment = NSTextAlignmentRight; batl.frame = CGRectMake(R - 40 - 6 - 62, T + 10, 62, 30);
        wifi.frame = CGRectMake(CGRectGetMinX(batl.frame) - 12 - 28, T + 10, 28, 30);
        [clock sizeToFit]; CGFloat cw0 = MAX(90, clock.bounds.size.width); clock.frame = CGRectMake(CGRectGetMinX(wifi.frame) - 12 - cw0, T + 10, cw0, 30);
        CGFloat top = T + 108, ch = B - top;
        BOOL wide = S.width > S.height;
        CGRect pf, cf;
        if (wide) { CGFloat cw = MIN(400, (R - L) * 0.36); pf = CGRectMake(L, top, R - L - cw - 18, ch); cf = CGRectMake(R - cw, top, cw, ch); }
        else { CGFloat hh = MIN(520, ch * 0.56); pf = CGRectMake(L, top, R - L, hh); cf = CGRectMake(L, top + hh + 18, R - L, ch - hh - 18); }
        pc.frame = pf; cc.frame = cf;
        // players card: QR column, then the grid
        CGFloat pw = pf.size.width, ph = pf.size.height, qs = MAX(0, MIN(200, MIN(ph - 140, pw * 0.32)));
        pt.frame = CGRectMake(24, 20, 120, 34); [pt sizeToFit]; pn.frame = CGRectMake(24 + pt.bounds.size.width + 14, 26, 90, 26);
        qr.frame = CGRectMake(24, 72, qs, qs); qi.frame = CGRectInset(qr.bounds, 14, 14);
        jt.frame = CGRectMake(24, 72 + qs + 14, qs, 26);
        CGRect gf = CGRectMake(24 + qs + 20, 72, pw - qs - 68, ph - 72 - 24);
        if (!CGRectEqualToRect(grid.frame, gf)) { grid.frame = gf; [held addObjectsFromArray:@[@1, @2, @3, @4, @5, @6, @7, @8]]; fill(last); }   // a new size: drawn again with no pop
        // controls card: a column
        CGFloat cw2 = cf.size.width - 44, y = 18;
        ct.frame = CGRectMake(22, y + 2, cw2, 34); y += 54;
        pause.frame = CGRectMake(22, y, cw2, 66); y += 86;
        vlo.frame = CGRectMake(22, y + 4, 24, 28); vl.frame = CGRectMake(22 + cw2 - 60, y + 3, 60, 30);
        vol.frame = CGRectMake(22 + 32, y + 1, cw2 - 32 - 32 - 70, 34); vhi.frame = CGRectMake(22 + cw2 - 60 - 34, y + 4, 30, 28); y += 58;
        audl.frame = CGRectMake(22, y, cw2, 24); y += 30; aud.frame = CGRectMake(22, y, cw2, 46); y += 64;
        vidl.frame = CGRectMake(22, y, cw2, 24); y += 30; vid.frame = CGRectMake(22, y, cw2, 46); y += 64;
        CGFloat bh = 60, by = MAX(y, cf.size.height - 20 - bh);
        if (wchange.hidden) { quit.frame = CGRectMake(22, by, cw2, bh); }
        else { change.frame = CGRectMake(22, by, (cw2 - 10) / 2, bh); quit.frame = CGRectMake(22 + (cw2 + 10) / 2, by, (cw2 - 10) / 2, bh); }
    };
    CABasicAnimation *drift = [CABasicAnimation animationWithKeyPath:@"transform.translation"];
    drift.fromValue = [NSValue valueWithCGSize:CGSizeZero]; drift.toValue = [NSValue valueWithCGSize:CGSizeMake(60, 40)];
    drift.duration = 9; drift.autoreverses = YES; drift.repeatCount = HUGE_VALF; drift.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [g1 addAnimation:drift forKey:@"drift"];
    CABasicAnimation *drift2 = [drift copy]; drift2.toValue = [NSValue valueWithCGSize:CGSizeMake(-50, -30)]; drift2.duration = 11; [g2 addAnimation:drift2 forKey:@"drift"];
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserverForName:@"DMPlayersChanged" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { fill(n.userInfo[@"players"]); }];
    __weak DmLayoutView *wv = v;
    [nc addObserverForName:@"DMShellChanged" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { (void)n; sync(); [wv setNeedsLayout]; }];
    [nc postNotificationName:@"DMPlayersCommand" object:nil userInfo:@{@"op": @"refresh"}];   // the list now
    return v;
}
- (void)viewDidAppear:(BOOL)a {
    [super viewDidAppear:a];
    if (self.launched) return;
    if (front_ios_pick_needed()) { self.launched = YES; g_root = self; [self placeStage]; dm_show_picker((__bridge void *)pregame_host(), picker_done); return; }
    if (!front_ios_boot_ok()) return;
    self.launched = YES; g_root = self; [self placeStage];
    if (!dm_show_launcher((__bridge void *)pregame_host(), launcher_done)) [self startGame];   // the settings screen first (Launcher.swift), when the app has one
}
// A game was chosen in the picker and main.m has set it up (or found its files missing)
- (void)afterPick {
    if (!front_ios_boot_ok()) {
        UILabel *lb = [[UILabel alloc] initWithFrame:CGRectInset(self.view.bounds, 40, 40)];
        lb.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        lb.numberOfLines = 0; lb.textAlignment = NSTextAlignmentCenter; lb.textColor = UIColor.whiteColor;
        lb.text = @"這款遊戲的檔案不完整，請重新打包。\nThis game's files are missing from the package: pack it again.";
        UIView *root = overlay_root() ?: self.view;
        lb.frame = CGRectInset(root.bounds, 40, 40);
        [root addSubview:lb]; front_ios_picker_cover_end(); return;
    }
    static int audio; if (!audio++) front_ios_audio_watch();   // once, though the launcher can go back to the picker
    if (!dm_show_launcher((__bridge void *)pregame_host(), launcher_done)) [self startGame];
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
    l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.72]; l.layer.masksToBounds = YES; l.userInteractionEnabled = NO;
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
static DmLayoutView *loading_overlay(UIView *root, UIColor *background) {
    DmLayoutView *view = [[DmLayoutView alloc] initWithFrame:root.bounds];
    view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    view.backgroundColor = background;
    view.userInteractionEnabled = NO;
    return view;
}

static CGFloat loading_scale(UIView *view) {
    CGSize size = view.bounds.size;
    if (size.width <= 0 || size.height <= 0) return 1;
    return MIN(ui_scale(view), MIN(size.width / 360, size.height / 145));
}

static UIView *loading_make(UIView *root) {
    DmLayoutView *view = loading_overlay(root, UIColor.blackColor);
    UIView *spinner = [UIView new];
    CAShapeLayer *ring = [CAShapeLayer layer];
    ring.strokeColor = UIColor.whiteColor.CGColor;
    ring.fillColor = UIColor.clearColor.CGColor;
    ring.lineCap = kCALineCapRound;
    [spinner.layer addSublayer:ring];
    if (!UIAccessibilityIsReduceMotionEnabled()) {
        CABasicAnimation *spin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        spin.toValue = @(2 * M_PI); spin.duration = 0.85; spin.repeatCount = HUGE_VALF;
        [ring addAnimation:spin forKey:@"loading"];
    }
    UILabel *title = [UILabel new];
    title.textAlignment = NSTextAlignmentCenter;
    title.textColor = [UIColor colorWithWhite:0.72 alpha:1];
    title.numberOfLines = 2;
    title.text = zh_ui() ? @"遊戲載入中…" : @"Loading the game…";
    title.tag = 1;
    [view addSubview:spinner];
    [view addSubview:title];
    view.layout = ^(UIView *overlay) {
        CGFloat k = loading_scale(overlay);
        CGRect bounds = overlay.bounds;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        spinner.frame = CGRectMake(CGRectGetMidX(bounds) - 16 * k, CGRectGetMidY(bounds) - 33 * k, 32 * k, 32 * k);
        ring.frame = spinner.bounds;
        ring.lineWidth = 2.5 * k;
        ring.contentsScale = overlay.window.screen.scale ?: 1;
        ring.path = [UIBezierPath bezierPathWithArcCenter:CGPointMake(16 * k, 16 * k) radius:12 * k
                                             startAngle:-M_PI_2 endAngle:1.05 * M_PI clockwise:YES].CGPath;
        [CATransaction commit];
        title.font = [UIFont systemFontOfSize:17 * k weight:UIFontWeightMedium];
        title.frame = CGRectMake(18 * k, CGRectGetMidY(bounds) + 13 * k, CGRectGetWidth(bounds) - 36 * k, 46 * k);
    };
    [root addSubview:view];
    return view;
}
static void loading_show(UIView *root) {
    if (g_loading || !root) return;
    g_loading = loading_make(root); tv_copies_sync();
}
// The loading screen's line for the current step (main.m: checking shaders, starting the game). Main thread
void front_ios_loading_text(NSString *zh, NSString *en) {
    NSString *lang = NSLocale.preferredLanguages.firstObject.lowercaseString ?: @"";
    BOOL z = [lang hasPrefix:@"zh-hant"] || [lang hasPrefix:@"zh-tw"] || [lang hasPrefix:@"zh-hk"] || [lang hasPrefix:@"zh-mo"];
    ((UILabel *)[g_loading viewWithTag:1]).text = z ? zh : en;
    ((UILabel *)[g_loading_tv viewWithTag:1]).text = z ? zh : en;
    LOG("front end: loading screen: %s (%.3f s since Play)", en.UTF8String, CACurrentMediaTime() - g_play_started);
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
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_loading) return;
        [g_loading removeFromSuperview]; g_loading = nil; tv_copies_sync();
        LOG("front end: first frame, loading screen hidden (%.3f s since Play)", CACurrentMediaTime() - g_play_started);
    });
}
// Progress screen of the prepare step (front.h front_progress): a dark view over the game's view and the pad, the title, a bar and a count, centered; UIKit views, so it draws while the game's thread waits
static UIView *prog_make(UIView *root) {
    DmLayoutView *view = loading_overlay(root, [UIColor colorWithWhite:0.06 alpha:0.94]);
    UILabel *title = [UILabel new];
    title.textAlignment = NSTextAlignmentCenter; title.textColor = UIColor.whiteColor;
    title.numberOfLines = 2; title.tag = 1;
    UIProgressView *bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    bar.tag = 2;
    UILabel *count = [UILabel new];
    count.textAlignment = NSTextAlignmentCenter; count.tag = 3;
    count.textColor = [UIColor colorWithWhite:0.72 alpha:1];
    [view addSubview:title]; [view addSubview:bar]; [view addSubview:count];
    view.layout = ^(UIView *overlay) {
        CGFloat k = loading_scale(overlay);
        CGFloat x = CGRectGetMidX(overlay.bounds), y = CGRectGetMidY(overlay.bounds);
        title.font = [UIFont systemFontOfSize:20 * k weight:UIFontWeightSemibold];
        count.font = [UIFont monospacedDigitSystemFontOfSize:14 * k weight:UIFontWeightRegular];
        title.frame = CGRectMake(x - 166 * k, y - 52 * k, 332 * k, 46 * k);
        bar.frame = CGRectMake(x - 140 * k, y + 3 * k, 280 * k, MAX(2, 4 * k));
        count.frame = CGRectMake(x - 166 * k, y + 19 * k, 332 * k, 27 * k);
    };
    [root addSubview:view];
    return view;
}
static void prog_copy(UIView *to, UIView *from) {   // the TV's copy shows what the iPad's shows
    if (!to || !from) return;
    for (NSInteger t = 1; t <= 3; t += 2) ((UILabel *)[to viewWithTag:t]).text = ((UILabel *)[from viewWithTag:t]).text;
    ((UIProgressView *)[to viewWithTag:2]).progress = ((UIProgressView *)[from viewWithTag:2]).progress;
}
void front_progress(const char *title, long done, long total) {
    if (!g_layer) return;
    NSString *tt = title ? @(title) : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!tt) { [g_prog removeFromSuperview]; g_prog = nil; tv_copies_sync(); return; }
        if (!g_prog) { UIView *root = overlay_root(); if (!root) return; g_prog = prog_make(root); }
        BOOL zh = zh_ui();
        NSString *heading = zh && [tt isEqualToString:@"Preparing pipelines"] ? @"正在準備圖形管線…" : tt;
        ((UILabel *)[g_prog viewWithTag:1]).text = heading;
        ((UIProgressView *)[g_prog viewWithTag:2]).progress = total > 0 ? (float)done / (float)total : 0;
        ((UILabel *)[g_prog viewWithTag:3]).text = [NSString stringWithFormat:zh ? @"%@／%@" : @"%@ of %@", [NSNumberFormatter localizedStringFromNumber:@(done) numberStyle:NSNumberFormatterDecimalStyle],
                             [NSNumberFormatter localizedStringFromNumber:@(total) numberStyle:NSNumberFormatterDecimalStyle]];
        if (g_prog_tv) prog_copy(g_prog_tv, g_prog); else tv_copies_sync();
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
// Sound on the iPad while the picture is on the TV (the Home menu's Sound row, kept for the device): for a screen with no speakers. iOS sends the sound to the
// HDMI output with the picture; only the play-and-record category can override that to the built-in speaker (overrideOutputAudioPort), and iOS asks once for
// the microphone with it (NSMicrophoneUsageDescription): nothing is recorded, and a refusal changes nothing for the sound
static BOOL audio_on_ipad(void) { return g_tv_scene && [NSUserDefaults.standardUserDefaults boolForKey:@"DMAudioOnIPad"]; }
void front_ios_audio_session(void) {
    volume_watch();
    AVAudioSession *s = AVAudioSession.sharedInstance; NSError *e = nil;
    BOOL ipad = audio_on_ipad();
    if (ipad ? ![s setCategory:AVAudioSessionCategoryPlayAndRecord withOptions:AVAudioSessionCategoryOptionDefaultToSpeaker error:&e]
             : ![s setCategory:AVAudioSessionCategorySoloAmbient error:&e]) LOG("[RED] audio session category could not be set: %s", e.localizedDescription.UTF8String);
    [s setPreferredSampleRate:48000 error:nil];
    if (![s setPreferredIOBufferDuration:0.005 error:&e]) LOG("[RED] audio session I/O buffer duration could not be set: %s", e.localizedDescription.UTF8String);
    g_session_off = ![s setActive:YES error:&e];
    if (g_session_off) LOG("[RED] audio session activation failed: %s", e.localizedDescription.UTF8String);
    if (ipad && ![s overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker error:&e]) LOG("[RED] audio session: the iPad's speaker could not be chosen: %s", e.localizedDescription.UTF8String);
    app_gain_apply();   // after the category: it decides the output, and so which volume the menu sets
    if (g_tv_scene) LOG("audio session: sound on the %s while a TV is connected", ipad ? "iPad's speaker" : "TV");
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
static UIView *overlay_root(void) { return tv_on() ? g_tv.rootViewController.view : g_root.view; }
@interface DmTvSceneDelegate : UIResponder <UIWindowSceneDelegate>
@end
@implementation DmTvSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)o {
    (void)session; (void)o;
    if (![scene isKindOfClass:UIWindowScene.class]) return;
    g_tv_scene = (UIWindowScene *)scene; g_video_ipad = NO;   // a TV plugged in: the picture goes there
    // Edge to edge: the default (scale) shrinks the picture inside the TV's frame for TVs that crop their edges, which left a black border on the ones that do not
    g_tv_scene.screen.overscanCompensation = UIScreenOverscanCompensationNone;
    CGSize sz = g_tv_scene.screen.bounds.size;
    UIScreen *screen = g_tv_scene.screen;
    UIEdgeInsets safe = screen.overscanCompensationInsets;
    LOG("front end: TV connected (%.0fx%.0f points, scale %.1f, screen reports up to %ld Hz)",
        sz.width, sz.height, screen.nativeScale, (long)screen.maximumFramesPerSecond);
    LOG("front end: TV overscan insets %.0f top, %.0f left, %.0f bottom, %.0f right", safe.top, safe.left, safe.bottom, safe.right);
    mode_transition(^{ [g_root placeStage]; });   // the TV's window now: the picker, the launcher or the game's picture moves there
    tv_sample_refresh(g_tv_scene);
    home_menu_relayout();  // a menu already up moves to the TV
    [NSNotificationCenter.defaultCenter postNotificationName:@"DMShellChanged" object:nil];   // the picker's Back to the TV, the panel
}
- (void)sceneDidDisconnect:(UIScene *)scene {
    if (scene != g_tv_scene) return;
    front_ios_picker_cover_end();
    LOG("front end: TV disconnected; the picture is back on the iPad");
    g_mirror_layer = NULL; g_tv.hidden = YES; g_tv_scene = nil;
    UIWindow *w = g_tv;
    if (g_root.launched && !g_root.game) pregame_move(w.rootViewController, g_root);   // the picker or the launcher comes back to the iPad
    g_tv = nil;
    mode_transition(^{ [g_root placeStage]; });
    (void)w;   // kept until the stage has left it
    home_menu_relayout();
    [NSNotificationCenter.defaultCenter postNotificationName:@"DMShellChanged" object:nil];
}
@end

// ---- The Home menu: over the paused game, moved by any player's controller or phone (DMLauncherInput) and by touch ----
// Paused as on the Switch's HOME menu: out of focus, its sound off, its clock frozen and the next submit held (the same steps as going to the background, which
// front_ios_focus_event takes; coming back from the background applies the pause again while the menu is up). The steps run on a queue of their own: the
// graphics suspend waits for the GPU work in flight
static int g_menu_sel, g_menu_closing;
static int g_menu_move = -1;      // the Players page: the player being moved to another number (0-based), -1 when none
static int g_menu_prev_sel = -1;  // where the pill was before a redraw, so it slides from there
static int g_menu_confirm = -1;   // the Players page: X was pressed once on this player (a second X removes it)
static NSArray<NSArray<NSString *> *> *g_menu_rows;   // [title, detail, action]
static dispatch_queue_t g_pause_q;
static int g_paused;
static void game_pause(int on) {
    CFTimeInterval requested = CACurrentMediaTime();
    if (!g_pause_q) g_pause_q = dispatch_queue_create("dm.home-menu.pause", DISPATCH_QUEUE_SERIAL);
    dispatch_async(g_pause_q, ^{
        if (on == g_paused) return;
        g_paused = on;
        if (on) { dm_focus_set(2); dm_audio_suspend(1); guest_clock_freeze_for(1, 1); dm_gfx_suspend(1); LOG("front end: game paused for the Home menu"); }
        else {
            dm_gfx_suspend(0); guest_clock_freeze_for(1, 0); dm_audio_suspend(0); dm_focus_set(1);
            LOG("front end: game resumed from the Home menu (%.0f ms after request)", (CACurrentMediaTime() - requested) * 1000);
        }
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
// The selection is a pill that slides to the chosen row (a spring), under the rows' text; the chosen row's icon tile lights up
static void home_menu_draw(void) {
    for (UIView *card in g_menu_cards) {
        UIView *pill = [card viewWithTag:50]; if (!pill) continue;
        UIColor *pc = g_menu_move >= 0 ? [UIColor colorWithRed:1 green:0.62 blue:0.04 alpha:1] : [UIColor colorWithRed:0.04 green:0.52 blue:1 alpha:1];   // orange while a player is being moved
        pill.backgroundColor = pc; pill.layer.shadowColor = pc.CGColor;
        for (UIView *row in card.subviews) if (row.tag >= 100) {
            BOOL on = row.tag - 100 == g_menu_sel;
            UIView *tile = [row viewWithTag:60] ?: [row viewWithTag:63];
            if (tile.tag == 60) tile.backgroundColor = on ? [UIColor colorWithWhite:1 alpha:0.95] : [UIColor colorWithWhite:1 alpha:0.1];
            ((UIImageView *)[tile viewWithTag:61]).tintColor = on ? [UIColor colorWithRed:0.04 green:0.52 blue:1 alpha:1] : UIColor.whiteColor;
            BOOL tv = card.window == g_tv;
            ((UILabel *)[row viewWithTag:62]).textColor = [UIColor colorWithWhite:1 alpha:tv ? 1 : on ? 0.85 : 0.5];
            if (!on) continue;
            if (pill.alpha == 0) { pill.frame = row.frame; pill.alpha = 1; continue; }   // first placement: no slide
            [UIView animateWithDuration:0.32 delay:0 usingSpringWithDamping:0.78 initialSpringVelocity:0.4 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                             animations:^{ pill.frame = row.frame; } completion:nil];
            [UIView animateWithDuration:0.08 animations:^{ tile.transform = CGAffineTransformMakeScale(1.12, 1.12); }
                             completion:^(BOOL f) { (void)f; [UIView animateWithDuration:0.18 animations:^{ tile.transform = CGAffineTransformIdentity; }]; }];
        }
    }
    g_menu_prev_sel = g_menu_sel;
}
static void home_menu_close(void) {
    if (!g_menu || g_menu_closing) return;
    volume_hold_stop();
    g_menu_closing = 1;
    dm_input_discard_buttons(DM_BTN_A | DM_BTN_B | DM_BTN_PLUS | DM_BTN_MINUS);
    game_pause(0);
    [NSNotificationCenter.defaultCenter postNotificationName:@"DMPlayersCommand" object:nil userInfo:@{@"op": @"launcher", @"on": @0}];
    UIView *m = g_menu, *mi = g_menu_tv;
    NSArray<UIView *> *cards = [g_menu_cards copy];
    [UIView animateWithDuration:0.2 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
        m.alpha = 0; mi.alpha = 0;
        for (UIView *c in cards) c.transform = CGAffineTransformScale(c.transform, 0.94, 0.94);
    } completion:^(BOOL f) {
        (void)f; [m removeFromSuperview]; [mi removeFromSuperview];
        if (g_menu == m) { g_menu = nil; g_menu_tv = nil; g_menu_cards = nil; g_menu_closing = 0; }
    }];
    [NSNotificationCenter.defaultCenter postNotificationName:@"DMShellChanged" object:nil];   // the TV panel's Pause / Continue
}
// The menu's size depends on its rows. Give the exit status its own layout on each display.
static void home_exit_status(UIView *root, NSString *message) {
    if (!root) return;
    UIView *oldMenu = g_menu.superview == root ? g_menu : nil;
    if (g_menu_tv.superview == root) oldMenu = g_menu_tv;
    DmLayoutView *overlay = [[DmLayoutView alloc] initWithFrame:root.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    overlay.accessibilityViewIsModal = YES;
    UIVisualEffectView *card = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterialDark]];
    card.clipsToBounds = YES;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.14].CGColor;
    card.contentView.backgroundColor = [UIColor colorWithRed:0.08 green:0.09 blue:0.11 alpha:0.55];
    UILabel *label = [UILabel new];
    label.text = message;
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = UIColor.whiteColor;
    label.numberOfLines = 2;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.8;
    [card.contentView addSubview:label];
    CAShapeLayer *ring = [CAShapeLayer layer];
    ring.fillColor = nil;
    ring.strokeColor = UIColor.whiteColor.CGColor;
    ring.lineCap = kCALineCapRound;
    ring.strokeEnd = 0.78;
    [card.contentView.layer addSublayer:ring];
    [overlay addSubview:card];
    overlay.layout = ^(UIView *view) {
        CGSize size = view.bounds.size;
        if (size.width <= 0 || size.height <= 0) return;
        BOOL tv = view.window && view.window == g_tv;
        CGFloat unit = tv ? MAX(0.55, MIN(size.width / 1920, size.height / 1080)) * 1.65 : 1;
        unit = MIN(unit, MIN(size.width * 0.86 / 300, size.height * 0.75 / 120));
        card.frame = CGRectMake((size.width - 300 * unit) / 2, (size.height - 120 * unit) / 2, 300 * unit, 120 * unit);
        card.layer.cornerRadius = 22 * unit;
        card.layer.borderWidth = unit;
        label.font = [UIFont systemFontOfSize:18 * unit weight:UIFontWeightSemibold];
        label.frame = CGRectMake(20 * unit, 66 * unit, 260 * unit, 38 * unit);
        ring.bounds = CGRectMake(0, 0, 32 * unit, 32 * unit);
        ring.position = CGPointMake(150 * unit, 42 * unit);
        ring.contentsScale = view.window.windowScene.screen.scale ?: 1;
        ring.lineWidth = 2.5 * unit;
        ring.path = [UIBezierPath bezierPathWithOvalInRect:CGRectInset(ring.bounds, 3 * unit, 3 * unit)].CGPath;
    };
    overlay.alpha = 0;
    [root addSubview:overlay];
    [overlay layoutIfNeeded];
    BOOL reduce = UIAccessibilityIsReduceMotionEnabled();
    if (!reduce) {
        CABasicAnimation *motion = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        motion.toValue = @(2 * M_PI);
        motion.duration = 0.85;
        motion.repeatCount = HUGE_VALF;
        [ring addAnimation:motion forKey:@"rotation"];
    }
    [UIView animateWithDuration:reduce ? 0 : 0.22 animations:^{ oldMenu.alpha = 0; overlay.alpha = 1; }];
}
// Closing from the Home menu is deliberate. Only Change games grants the next process a one-shot relaunch request.
static void home_menu_quit(int relaunch) {
    static BOOL exiting;
    if (exiting) return;
    exiting = YES;
    g_menu_closing = 1;
    volume_hold_stop();
    BOOL z = zh_ui();
    NSString *message = relaunch ? (z ? @"正在回到選擇遊戲…" : @"Back to the games…") : (z ? @"正在關閉…" : @"Closing…");
    home_exit_status(g_root.view, message);
    home_exit_status(g_tv.rootViewController.view, message);
    LOG("front end: Home menu: user confirmed %s", relaunch ? "Change games" : "Close the game");
    fflush(stderr);
    // The next game needs a fresh process. Leave the request just before exiting, after the closing animation.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (relaunch) {
            NSError *error = nil;
            if (!dm_write_relaunch_ticket(dm_relaunch_ticket_url(), &error))
                LOG("front end: cannot save Change games request: %s", error.localizedDescription.UTF8String ?: "unknown error");
        }
        fflush(stderr);
        exit(0);
    });
}
static void players_cmd(NSDictionary *u) { [NSNotificationCenter.defaultCenter postNotificationName:@"DMPlayersCommand" object:nil userInfo:u]; }
static void menu_refresh(int sel) {   // the same page drawn again (a value changed): no slide, the pill moves from where it was
    if (!g_menu || g_menu_closing) return;
    g_menu_rows = menu_rows(g_menu_page); g_menu_sel = MAX(0, MIN(sel, (int)g_menu_rows.count - 1));
    g_menu_anim = 0; home_menu_relayout(); home_menu_draw();
}
// The Players page: A picks a player up, up and down choose the number it goes to, A puts it down there (or a tap on another number): one swap, so player 1
// keeps the menu while carrying itself to any number, 8P included, and whoever becomes player 1 runs the menu after
static void slot_swap(int a, int b) {
    if (a == b || a < 0 || b < 0 || a >= DM_PLAYERS || b >= DM_PLAYERS) return;
    LOG("front end: Home menu: player %d and player %d swap", a + 1, b + 1);
    players_cmd(@{@"op": @"swap", @"a": @(a + 1), @"b": @(b + 1)});
}
static void slot_activate(int p) {
    shell_slot_info info[DM_PLAYERS]; shell_slots_list(info);
    g_menu_confirm = -1;
    if (g_menu_move < 0) { if (info[p].kind != SHELL_SLOT_NONE) g_menu_move = p; }
    else if (g_menu_move == p) g_menu_move = -1;
    else { slot_swap(g_menu_move, p); g_menu_move = -1; }
    menu_refresh(p);
}
static void slot_layout(int p) {
    shell_slot_info info[DM_PLAYERS]; shell_slots_list(info);
    if (info[p].kind == SHELL_SLOT_NONE) return;
    players_cmd(@{@"op": @"layout", @"p": @(p + 1), @"xbox": @(!info[p].xbox)}); menu_refresh(p);
}
static void slot_identify(int p) { players_cmd(@{@"op": @"identify", @"p": @(p + 1)}); }
static void slot_remove(int p) {
    shell_slot_info info[DM_PLAYERS]; shell_slots_list(info);
    if (info[p].kind == SHELL_SLOT_NONE) return;
    LOG("front end: Home menu: player %d removed", p + 1);
    g_menu_confirm = -1; if (g_menu_move == p) g_menu_move = -1;
    players_cmd(@{@"op": @"kick", @"p": @(p + 1)}); menu_refresh(p);
}
static void output_video_set(BOOL ipad) {   // the picture moves at once, the menu with it, and the choice stays
    if (ipad == video_pref_ipad()) return;
    g_video_ipad = ipad;
    LOG("front end: picture output -> %s", ipad ? "iPad" : "TV");
    mode_transition(^{ [g_root placeStage]; home_menu_relayout(); home_menu_draw(); });
    [NSNotificationCenter.defaultCenter postNotificationName:@"DMShellChanged" object:nil];
}
// Handheld or console play while a TV is connected: the picture and the sound go together (the sound output can still be changed on its own after)
static void play_mode_set(BOOL handheld) {
    // A console-mode save rename uses the iPad's input alert. Finish it before moving the launcher.
    if (handheld && !g_root.game && [g_root.presentedViewController isKindOfClass:UIAlertController.class]) return;
    if (g_mode_fades) {
        g_pending_mode = handheld == video_pref_ipad() ? -1 : handheld;
        return;
    }
    if (g_pregame_moving) return;
    output_video_set(handheld);
    output_audio_set(handheld);
}
static void play_mode_toggle(void) {
    BOOL target = g_pending_mode < 0 ? video_pref_ipad() : g_pending_mode == 1;
    play_mode_set(!target);
}
static void output_audio_set(BOOL ipad) {   // switches at once (a paused game's sound resumes on the new output) and stays the choice
    if (ipad == [NSUserDefaults.standardUserDefaults boolForKey:@"DMAudioOnIPad"]) return;
    [NSUserDefaults.standardUserDefaults setBool:ipad forKey:@"DMAudioOnIPad"];
    LOG("front end: sound output -> %s", ipad ? "iPad speaker" : "TV");
    front_ios_audio_session();
    [NSNotificationCenter.defaultCenter postNotificationName:@"DMShellChanged" object:nil];
}
float front_ios_picker_volume(void) {
    volume_watch();
    return volume_pref();
}

void front_ios_picker_set_volume(float value) {
    if (g_root && !g_root.game) volume_set(value);
}

bool front_ios_picker_adjust_volume(int direction) {
    return g_root && !g_root.game && volume_adjust(direction);
}

int front_ios_picker_outputs(void) {
    if (!g_tv_scene) return 0;
    return 1 | (video_pref_ipad() ? 2 : 0) | ([NSUserDefaults.standardUserDefaults boolForKey:@"DMAudioOnIPad"] ? 4 : 0);
}

void front_ios_picker_action(int action) {
    if (!g_root || g_root.game) return;
    if (action == 0) { volume_toggle_mute(); return; }
    if (action == 3) { fflush(stderr); exit(0); }
    if (!g_tv_scene) return;
    if (action == 1) play_mode_toggle();
    if (action == 2) output_audio_set(![NSUserDefaults.standardUserDefaults boolForKey:@"DMAudioOnIPad"]);
}

static void home_menu_activate(int i) {
    if (!g_menu || g_menu_closing || i < 0 || i >= (int)g_menu_rows.count) return;
    volume_hold_stop();
    NSString *act = g_menu_rows[i][2];
    if ([act isEqualToString:@"continue"]) home_menu_close();
    else if ([act isEqualToString:@"players"]) { g_menu_move = g_menu_confirm = -1; menu_page(1, 0); }
    else if ([act isEqualToString:@"back"]) { g_menu_move = g_menu_confirm = -1; menu_page(0, 1); }
    else if ([act hasPrefix:@"slot:"]) slot_activate([[act substringFromIndex:5] intValue]);
    else if ([act isEqualToString:@"volume"]) volume_toggle_mute();
    else if ([act isEqualToString:@"audio"]) { output_audio_set(![NSUserDefaults.standardUserDefaults boolForKey:@"DMAudioOnIPad"]); menu_refresh(i); }
    else if ([act isEqualToString:@"video"]) { play_mode_toggle(); menu_refresh(i); }
    else { g_menu_closing = 1; home_menu_quit([act isEqualToString:@"change"]); }
}
static NSTimer *g_volume_hold;
static int g_volume_hold_dir;
static int g_volume_hold_player;
static BOOL g_volume_hold_touch;
static CFTimeInterval g_volume_hold_since;
static void volume_hold_stop(void) {
    [g_volume_hold invalidate];
    g_volume_hold = nil;
}
static void volume_hold_tick(NSTimeInterval delay) {
    g_volume_hold = [NSTimer timerWithTimeInterval:delay repeats:NO block:^(NSTimer *timer) {
        if (timer != g_volume_hold) return;
        if (!g_menu || g_menu_closing || !volume_adjust(g_volume_hold_dir)) {
            volume_hold_stop();
            return;
        }
        CFTimeInterval held = CACurrentMediaTime() - g_volume_hold_since;
        volume_hold_tick(held < 1.0 ? 0.18 : held < 2.0 ? 0.095 : 0.045);
    }];
    [NSRunLoop.mainRunLoop addTimer:g_volume_hold forMode:NSRunLoopCommonModes];
}
static void volume_hold_start(int dir, BOOL touch) {
    volume_hold_stop();
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive || !volume_adjust(dir)) return;
    g_volume_hold_dir = dir;
    g_volume_hold_touch = touch;
    g_volume_hold_since = CACurrentMediaTime() - (touch ? 0.4 : 0);
    volume_hold_tick(touch ? 0.18 : 0.4);
}
@interface DmMenuTap : NSObject
@end
@implementation DmMenuTap
+ (void)tap:(UIButton *)b { g_menu_sel = (int)b.tag - 100; home_menu_draw(); home_menu_activate(g_menu_sel); }
+ (void)tool:(UIButton *)b {   // the small buttons on a row: volume down / up, and a player's layout, identify, remove
    int t = (int)b.tag;
    if (t == 300 || t == 301) { volume_hold_stop(); volume_adjust(t == 300 ? -1 : 1); return; }
    int p = (t - 400) / 4, k = (t - 400) % 4;
    if (p < 0 || p >= DM_PLAYERS) return;
    if (k == 0) slot_layout(p); else if (k == 1) slot_identify(p); else slot_remove(p);
}
+ (void)holdVolume:(UILongPressGestureRecognizer *)press {
    int dir = press.view.tag == 300 ? -1 : 1;
    if (press.state == UIGestureRecognizerStateBegan && g_menu && !g_menu_closing) volume_hold_start(dir, YES);
    else if (g_volume_hold_touch && g_volume_hold_dir == dir &&
             (press.state == UIGestureRecognizerStateEnded || press.state == UIGestureRecognizerStateCancelled)) volume_hold_stop();
}
@end
static NSString *menu_symbol(NSString *act) {   // each row's SF Symbol
    NSDictionary *m = @{@"continue": @"play.fill", @"players": @"person.2.fill", @"volume": @"speaker.wave.2.fill", @"video": @"tv", @"audio": @"hifispeaker.fill",
                        @"change": @"square.grid.2x2.fill", @"quit": @"power", @"back": @"chevron.left"};
    return m[act] ?: @"circle.fill";
}
static CGRect home_menu_rect(CGFloat unit, CGFloat x, CGFloat y, CGFloat w, CGFloat h) {
    return CGRectMake(x * unit, y * unit, w * unit, h * unit);
}
static UIView *home_menu_make(UIView *root) {
    BOOL z = zh_ui();
    UIView *menu = [[UIView alloc] initWithFrame:root.bounds];
    menu.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    menu.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    BOOL onTV = root.window && root.window == g_tv;
    BOOL pl = g_menu_page == 1;   // the Players page: the phones' QR code on the left, the eight numbers on the right
    CGFloat W = pl ? 720 : onTV ? 488 : 440, rowH = pl ? 46 : 60, gap = pl ? 6 : 8, pad = 16, top = 84, x0 = pl ? pad + 236 : pad, rw = W - x0 - pad;
    NSString *qrURL = nil; UIImage *qr = pl ? phones_qr(&qrURL) : nil;
    CGFloat H = top + g_menu_rows.count * (rowH + gap) + pad - gap + (pl ? 34 : 4);   // key hints only on the Players page
    CGSize viewport = root.bounds.size;
    CGFloat fit = MIN(viewport.width * 0.84 / W, viewport.height * 0.86 / H);
    CGFloat tvType = MAX(0.55, MIN(viewport.width / 1920, viewport.height / 1080)) * 1.65;
    CGFloat unit = MIN(onTV ? tvType : 1.1, fit > 0 ? fit : 1);
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(0, 0, W * unit, H * unit)];
    card.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    card.layer.cornerRadius = 26 * unit; card.layer.cornerCurve = kCACornerCurveContinuous;
    card.layer.shadowColor = UIColor.blackColor.CGColor; card.layer.shadowOpacity = 0.45; card.layer.shadowRadius = 30 * unit; card.layer.shadowOffset = CGSizeMake(0, 14 * unit);
    // the backdrop: frosted glass over the paused game, a hairline edge
    UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterialDark]];
    glass.frame = card.bounds; glass.tag = 1; glass.layer.cornerRadius = 26 * unit; glass.layer.cornerCurve = kCACornerCurveContinuous; glass.clipsToBounds = YES;
    glass.layer.borderWidth = 1 * unit; glass.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.12].CGColor;
    glass.contentView.backgroundColor = [UIColor colorWithRed:0.08 green:0.09 blue:0.11 alpha:onTV ? 0.86 : 0.55];
    [card addSubview:glass];
    UILabel *t = [[UILabel alloc] initWithFrame:home_menu_rect(unit, pad + 4, 20, W - 2 * pad - 8, 28)];
    t.adjustsFontSizeToFitWidth = YES; t.minimumScaleFactor = 0.75;
    t.text = game_name(); t.textColor = UIColor.whiteColor; t.font = [UIFont systemFontOfSize:22 * unit weight:UIFontWeightBold];
    // a small tag box: what is going on (a pause glyph and a word)
    UIView *tag = [[UIView alloc] initWithFrame:home_menu_rect(unit, pad + 4, 52, 10, 22)];
    tag.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12]; tag.layer.cornerRadius = 7 * unit; tag.layer.cornerCurve = kCACornerCurveContinuous;
    UIImageView *pi = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"pause.fill" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:9 * unit weight:UIImageSymbolWeightBold]]];
    pi.tintColor = [UIColor colorWithWhite:0.85 alpha:1]; pi.center = CGPointMake(14 * unit, 11 * unit); [tag addSubview:pi];
    UILabel *tl = [[UILabel alloc] init]; tl.text = pl ? (z ? @"玩家" : @"Players") : (z ? @"已暫停" : @"Paused");
    tl.font = [UIFont systemFontOfSize:12 * unit weight:UIFontWeightSemibold]; tl.textColor = [UIColor colorWithWhite:0.85 alpha:1]; [tl sizeToFit];
    tl.frame = CGRectMake(24 * unit, 0, tl.bounds.size.width, 22 * unit); [tag addSubview:tl];
    CGRect tf = tag.frame; tf.size.width = 33 * unit + tl.bounds.size.width; tag.frame = tf;
    [card addSubview:t]; [card addSubview:tag];
    if (pl) {   // joining: the QR code on white, what to do, the address
        UIView *qc = [[UIView alloc] initWithFrame:home_menu_rect(unit, pad, top, 220, 220)];
        qc.backgroundColor = UIColor.whiteColor; qc.layer.cornerRadius = 20 * unit; qc.layer.cornerCurve = kCACornerCurveContinuous;
        if (qr) { UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectInset(qc.bounds, 16 * unit, 16 * unit)]; iv.image = qr; iv.layer.magnificationFilter = kCAFilterNearest; iv.contentMode = UIViewContentModeScaleAspectFit; [qc addSubview:iv]; }
        UILabel *jt = [[UILabel alloc] initWithFrame:home_menu_rect(unit, pad, top + 232, 220, 22)]; jt.textAlignment = NSTextAlignmentCenter;
        jt.text = z ? @"用手機加入" : @"Join with a phone"; jt.textColor = UIColor.whiteColor; jt.font = [UIFont systemFontOfSize:16 * unit weight:UIFontWeightBold];
        UILabel *u = [[UILabel alloc] initWithFrame:home_menu_rect(unit, pad, top + 256, 220, 18)]; u.textAlignment = NSTextAlignmentCenter; u.adjustsFontSizeToFitWidth = YES;
        u.text = qrURL ?: (z ? @"手機手把沒有開啟" : @"Phone controllers are off"); u.textColor = [UIColor colorWithWhite:1 alpha:0.5];
        u.font = [UIFont monospacedSystemFontOfSize:12 * unit weight:UIFontWeightRegular];
        [card addSubview:qc]; [card addSubview:jt]; [card addSubview:u];
    }
    for (NSUInteger i = 0; i < g_menu_rows.count; i++) {   // each row's own faint plate, under the sliding pill
        UIView *plate = [[UIView alloc] initWithFrame:home_menu_rect(unit, x0, top + i * (rowH + gap), rw, rowH)];
        plate.backgroundColor = [UIColor colorWithWhite:1 alpha:0.05]; plate.layer.cornerRadius = 16 * unit; plate.layer.cornerCurve = kCACornerCurveContinuous; plate.userInteractionEnabled = NO;
        [card addSubview:plate];
    }
    UIView *pill = [[UIView alloc] initWithFrame:CGRectZero]; pill.tag = 50; pill.alpha = 0; pill.userInteractionEnabled = NO;
    pill.backgroundColor = onTV ? [UIColor colorWithRed:0.02 green:0.32 blue:0.78 alpha:1] : [UIColor colorWithRed:0.04 green:0.52 blue:1 alpha:1]; pill.layer.cornerRadius = 16 * unit; pill.layer.cornerCurve = kCACornerCurveContinuous;
    pill.layer.shadowColor = [UIColor colorWithRed:0.04 green:0.52 blue:1 alpha:1].CGColor; pill.layer.shadowOpacity = 0.5; pill.layer.shadowRadius = 12 * unit; pill.layer.shadowOffset = CGSizeZero;
    [card addSubview:pill];
    if (g_menu_anim == 0 && g_menu_prev_sel >= 0 && g_menu_prev_sel < (int)g_menu_rows.count) {   // redrawn in place: the pill starts where it was and slides
        pill.frame = home_menu_rect(unit, x0, top + g_menu_prev_sel * (rowH + gap), rw, rowH); pill.alpha = 1;
    }
    CGFloat tileS = rowH == 60 ? 36 : 32;
    shell_slot_info info[DM_PLAYERS]; shell_slots_list(info);
    for (NSUInteger i = 0; i < g_menu_rows.count; i++) {
        UIButton *row = [UIButton buttonWithType:UIButtonTypeCustom];
        row.frame = home_menu_rect(unit, x0, top + i * (rowH + gap), rw, rowH); row.tag = 100 + (NSInteger)i;
        NSString *act = g_menu_rows[i][2];
        int slot = [act hasPrefix:@"slot:"] ? [[act substringFromIndex:5] intValue] : -1;
        BOOL held = slot >= 0 && info[slot].kind != SHELL_SLOT_NONE;
        [row addTarget:DmMenuTap.class action:@selector(tap:) forControlEvents:UIControlEventTouchUpInside];
        UIView *tile = [[UIView alloc] initWithFrame:home_menu_rect(unit, 12, (rowH - tileS) / 2, tileS, tileS)]; tile.tag = 60; tile.userInteractionEnabled = NO;
        tile.layer.cornerRadius = 10 * unit; tile.layer.cornerCurve = kCACornerCurveContinuous;
        UIView *ic;
        if (slot >= 0) {   // a player's number on its own colour, instead of an icon
            UILabel *n = [[UILabel alloc] initWithFrame:tile.bounds]; n.text = [NSString stringWithFormat:@"P%d", slot + 1]; n.textAlignment = NSTextAlignmentCenter;
            n.font = [UIFont systemFontOfSize:13 * unit weight:UIFontWeightHeavy]; n.textColor = held ? UIColor.whiteColor : [UIColor colorWithWhite:1 alpha:0.3];
            tile.backgroundColor = held ? player_color(slot + 1) : [UIColor colorWithWhite:1 alpha:0.06]; tile.tag = 63;   // not lit by the selection
            ic = n;
        } else {
            UIImageView *iv = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:menu_symbol(act) withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:15 * unit weight:UIImageSymbolWeightSemibold]]];
            iv.tag = 61; iv.contentMode = UIViewContentModeCenter; ic = iv;
        }
        ic.frame = tile.bounds; [tile addSubview:ic];
        BOOL volume = !onTV && [act isEqualToString:@"volume"];
        int tools = onTV ? 0 : held ? 3 : volume ? 2 : 0;
        CGFloat sliderWidth = volume ? 102 : 0;
        CGFloat x = 12 + tileS + 12, tw = rw - x - 12 - tools * 40 - sliderWidth;
        BOOL two = [g_menu_rows[i][1] length] > 0;
        UILabel *a = [[UILabel alloc] initWithFrame:home_menu_rect(unit, x, two ? (rowH == 60 ? 9 : 5) : (rowH - 22) / 2, tw, 22)]; a.userInteractionEnabled = NO;
        a.tag = 64; a.text = g_menu_rows[i][0]; a.textColor = UIColor.whiteColor; a.font = [UIFont systemFontOfSize:(onTV ? 19 : 17) * unit weight:UIFontWeightSemibold];
        UILabel *d = [[UILabel alloc] initWithFrame:home_menu_rect(unit, x, rowH == 60 ? 32 : 27, tw, 18)]; d.userInteractionEnabled = NO; d.tag = 62;
        d.text = g_menu_rows[i][1];
        d.font = [UIFont systemFontOfSize:(onTV ? 15 : 13) * unit weight:onTV ? UIFontWeightMedium : UIFontWeightRegular];
        if (slot >= 0 && !held) a.textColor = [UIColor colorWithWhite:1 alpha:0.35];
        [row addSubview:tile]; [row addSubview:a]; [row addSubview:d];
        if (volume) {
            d.adjustsFontSizeToFitWidth = YES; d.minimumScaleFactor = 0.7;
            DmVolumeSlider *slider = volume_slider(z);
            slider.tag = 65;
            slider.minimumTrackTintColor = UIColor.whiteColor;
            slider.maximumTrackTintColor = [UIColor colorWithWhite:1 alpha:0.27];
            slider.frame = home_menu_rect(unit, rw - 12 - 40 - sliderWidth, (rowH - 40) / 2, sliderWidth, 40);
            [row addSubview:slider];
        }
        NSArray *syms = held ? @[@"gamecontroller", @"wave.3.right", @"xmark"] : @[@"minus", @"plus"];
        for (int k = 0; k < tools; k++) {
            UIButton *tb = [UIButton buttonWithType:UIButtonTypeSystem];
            CGFloat buttonX = rw - 12 - (tools - k) * 40 + 4 - (volume && k == 0 ? sliderWidth : 0);
            tb.frame = home_menu_rect(unit, buttonX, (rowH - 32) / 2, 32, 32);
            tb.tag = held ? 400 + slot * 4 + k : 300 + k;
            [tb setImage:[UIImage systemImageNamed:syms[k] withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:13 * unit weight:UIImageSymbolWeightBold]] forState:UIControlStateNormal];
            tb.tintColor = UIColor.whiteColor; tb.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14]; tb.layer.cornerRadius = 10 * unit; tb.layer.cornerCurve = kCACornerCurveContinuous;
            [tb addTarget:DmMenuTap.class action:@selector(tool:) forControlEvents:UIControlEventTouchUpInside];
            if (!held) {
                tb.accessibilityLabel = k == 0 ? (z ? @"降低音量" : @"Decrease volume") : (z ? @"提高音量" : @"Increase volume");
                UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc] initWithTarget:DmMenuTap.class action:@selector(holdVolume:)];
                press.minimumPressDuration = 0.4;
                [tb addGestureRecognizer:press];
            }
            [row addSubview:tb];
        }
        [card addSubview:row];
    }
    UILabel *hint = [[UILabel alloc] initWithFrame:home_menu_rect(unit, pad, H - 34, W - 2 * pad, 22)]; hint.hidden = !pl;
    hint.text = pl ? (g_menu_move >= 0 ? (z ? @"↑↓ 選號碼   A 放下   B 取消" : @"↑↓ number   A put down   B cancel")
                                      : (z ? @"A 換號碼   Y 按鍵配置   X 移除" : @"A number   Y layout   X remove"))
                   : @"";
    hint.textAlignment = NSTextAlignmentCenter; hint.textColor = [UIColor colorWithWhite:1 alpha:0.5]; hint.font = [UIFont systemFontOfSize:(onTV ? 15 : 13) * unit weight:UIFontWeightSemibold];
    [card addSubview:hint];
    CGFloat k = onTV ? 1 : ui_scale(root);
    CGAffineTransform base = CGAffineTransformMakeScale(k, k);
    card.transform = base; card.center = CGPointMake(CGRectGetMidX(root.bounds), CGRectGetMidY(root.bounds));
    [menu addSubview:card]; [root addSubview:menu];
    if (onTV || k > 1) crisp(card, k);
    [g_menu_cards addObject:card];
    // coming in: opening pops up from a little smaller and lower (a spring) as the dim fades in; a page slides in from the side it goes to
    if (g_menu_anim == 1) {
        menu.backgroundColor = UIColor.clearColor; card.alpha = 0;
        card.transform = CGAffineTransformTranslate(CGAffineTransformScale(base, 0.9, 0.9), 0, 24 * unit);
        UIColor *dim = [UIColor colorWithWhite:0 alpha:0.55];
        [UIView animateWithDuration:0.22 animations:^{ menu.backgroundColor = dim; }];
        [UIView animateWithDuration:0.45 delay:0 usingSpringWithDamping:0.74 initialSpringVelocity:0.3 options:UIViewAnimationOptionAllowUserInteraction
                         animations:^{ card.alpha = 1; card.transform = base; } completion:nil];
    } else if (g_menu_anim == 2 || g_menu_anim == 3) {
        card.alpha = 0; card.transform = CGAffineTransformTranslate(base, (g_menu_anim == 2 ? 36 : -36) * unit, 0);
        [UIView animateWithDuration:0.34 delay:0 usingSpringWithDamping:0.86 initialSpringVelocity:0.2 options:UIViewAnimationOptionAllowUserInteraction
                         animations:^{ card.alpha = 1; card.transform = base; } completion:nil];
    }
    return menu;
}
static void home_menu_build(void) {
    volume_hold_stop();
    UIView *root = overlay_root(); if (!root) return;
    g_menu_cards = [NSMutableArray array];
    g_menu = home_menu_make(root);
    // with the picture on the TV the iPad keeps its own panel (tv_panel), whose controls do what the menu does: no copy of the menu there.
    // Handheld play with a TV: the menu is on the iPad, under the player's fingers, and its copy on the TV (tv_copies_sync), as in console play
    tv_copies_sync();
    g_menu_anim = 0;
    home_menu_draw();
}
static void home_menu_relayout(void) {   // the TV came or went while the menu is up: draw it again where the picture is now
    if (!g_menu || g_menu_closing) return;
    [g_menu removeFromSuperview]; [g_menu_tv removeFromSuperview]; g_menu = nil; g_menu_tv = nil;
    home_menu_build();
}
// The TV is the same in console and handheld play (the user's rule, art53): only the iPad differs. In handheld play in game the TV shows the mirrored picture
// (tv_mirror), and over it copies of what covers the iPad's picture: the loading screen, the prepare step's progress and the Home menu, laid out for the TV
// as in console play. The copies take no touches; the iPad's own ones are the ones used
static void tv_copies_sync(void) {
    UIView *tv = g_tv.rootViewController.view;
    BOOL want = tv && g_tv && video_pref_ipad() && g_root.game;
    if (want && g_loading && !g_loading_tv) { g_loading_tv = loading_make(tv); ((UILabel *)[g_loading_tv viewWithTag:1]).text = ((UILabel *)[g_loading viewWithTag:1]).text; }
    if ((!want || !g_loading) && g_loading_tv) { [g_loading_tv removeFromSuperview]; g_loading_tv = nil; }
    if (want && g_prog && !g_prog_tv) { g_prog_tv = prog_make(tv); prog_copy(g_prog_tv, g_prog); }
    if ((!want || !g_prog) && g_prog_tv) { [g_prog_tv removeFromSuperview]; g_prog_tv = nil; }
    if (want && g_menu && !g_menu_closing && !g_menu_tv) { g_menu_tv = home_menu_make(tv); home_menu_draw(); }
    if ((!want || !g_menu) && g_menu_tv && !g_menu_closing) { [g_menu_tv removeFromSuperview]; g_menu_tv = nil; }
    for (UIView *v in @[g_loading_tv ?: NSNull.null, g_prog_tv ?: NSNull.null, g_menu_tv ?: NSNull.null])   // over the mirrored picture, in the iPad's order
        if ([v isKindOfClass:UIView.class]) { v.userInteractionEnabled = NO; [tv bringSubviewToFront:v]; }
}
static NSArray<NSString *> *audio_row(void) {
    BOOL z = zh_ui(), ipad = [NSUserDefaults.standardUserDefaults boolForKey:@"DMAudioOnIPad"];
    return @[ipad ? (z ? @"聲音輸出：iPad 喇叭" : @"Sound output: iPad speaker") : (z ? @"聲音輸出：電視" : @"Sound output: TV"),
             @"", @"audio"];
}
static NSArray<NSString *> *volume_row(void) {
    BOOL z = zh_ui(); int pct = (int)lroundf(volume_pref() * 100);
    NSString *what = volume_is_device() ? (z ? @"iPad 音量（同音量鍵）" : @"The iPad's volume (as its buttons)")
                                        : (z ? @"遊戲音量；電視本身用電視遙控器調" : @"The game's level; the TV's own with its remote");
    NSString *hint = pct ? (z ? @"A 靜音" : @"A Mute") : (z ? @"A 恢復音量" : @"A Unmute");
    return @[[NSString stringWithFormat:z ? @"音量  %d%%" : @"Volume  %d%%", pct],
             [NSString stringWithFormat:@"%@ · %@", what, hint], @"volume"];
}
static NSArray<NSString *> *video_row(void) {
    BOOL z = zh_ui(), ipad = video_pref_ipad();
    return @[ipad ? (z ? @"掌機模式" : @"Handheld mode") : (z ? @"主機模式" : @"Console mode"),
             @"", @"video"];
}
// The menu's pages: 0 the main list, 1 the players (the eight numbers, who holds each; joining with a phone on the same page)
static NSArray *menu_rows(int page) {
    BOOL z = zh_ui();
    NSMutableArray *rows = [NSMutableArray array];
    if (page == 1) {
        shell_slot_info info[DM_PLAYERS]; shell_slots_list(info);
        for (int p = 0; p < DM_PLAYERS; p++) {
            NSString *act = [NSString stringWithFormat:@"slot:%d", p];
            BOOL target = g_menu_move >= 0 && g_menu_move != p && g_menu_sel == p;   // where the carried player would go
            if (info[p].kind == SHELL_SLOT_NONE) { [rows addObject:@[z ? @"空位" : @"Open", target ? (z ? @"放到這裡" : @"Put here") : @"", act]]; continue; }
            NSString *kind = info[p].kind == SHELL_SLOT_PHONE ? (z ? @"手機" : @"Phone") : (z ? @"手把" : @"Controller");
            NSString *label = [NSString stringWithUTF8String:info[p].label] ?: @"?";
            NSString *d = [NSString stringWithFormat:@"%@ · %@", kind, info[p].xbox ? @"Xbox" : @"Switch"];
            if (g_menu_move == p) d = z ? @"移動中" : @"Moving";
            if (target) d = z ? @"和這位交換" : @"Swap here";
            if (g_menu_confirm == p) d = z ? @"再按 X 移除" : @"X again to remove";
            [rows addObject:@[label, d, act]];
        }
        [rows addObject:@[z ? @"返回" : @"Back", @"", @"back"]];
        return rows;
    }
    const char *ng = getenv("DM_SHELL_GAMES"); BOOL several = ng && atoi(ng) > 1;
    int n = 0; { shell_slot_info info[DM_PLAYERS]; shell_slots_list(info); for (int p = 0; p < DM_PLAYERS; p++) n += info[p].kind != SHELL_SLOT_NONE; }
    [rows addObject:@[z ? @"繼續遊戲" : @"Continue", @"", @"continue"]];
    [rows addObject:@[z ? @"玩家" : @"Players", [NSString stringWithFormat:z ? @"%d 位" : @"%d", n], @"players"]];
    [rows addObject:volume_row()];
    if (g_tv_scene) { [rows addObject:audio_row()]; [rows addObject:video_row()]; }   // a TV is connected: where the sound and the picture go
    if (several) [rows addObject:@[z ? @"換遊戲" : @"Change games", z ? @"未存檔進度會遺失" : @"Unsaved progress is lost", @"change"]];
    [rows addObject:@[z ? @"關閉遊戲" : @"Close the game", z ? @"未存檔進度會遺失" : @"Unsaved progress is lost", @"quit"]];
    return rows;
}
// g_menu_page declared near the top
static void menu_page(int page, int sel) {
    g_menu_anim = page > g_menu_page ? 2 : 3;   // deeper slides in from the right, back from the left
    g_menu_page = page; g_menu_rows = menu_rows(page); g_menu_sel = MAX(0, MIN(sel, (int)g_menu_rows.count - 1)); g_menu_prev_sel = -1;
    home_menu_relayout(); home_menu_draw();
}
static NSString *phone_address(void) {
    int phone_pads_url(char *out, size_t cap);
    char url[96];
    return phone_pads_url(url, sizeof url) ? @(url) : nil;
}
static UIImage *phone_code(NSString *address) {
    if (!address) return nil;
    CIFilter *f = [CIFilter filterWithName:@"CIQRCodeGenerator"]; [f setValue:[address dataUsingEncoding:NSUTF8StringEncoding] forKey:@"inputMessage"]; [f setValue:@"M" forKey:@"inputCorrectionLevel"];
    CIImage *ci = f.outputImage; CGImageRef cg = ci ? [[CIContext context] createCGImage:ci fromRect:ci.extent] : NULL;
    if (!cg) return nil;
    UIImage *img = [UIImage imageWithCGImage:cg]; CGImageRelease(cg); return img;
}
static UIImage *phones_qr(NSString **url_out) {
    NSString *address = phone_address();
    if (url_out) *url_out = address;
    return phone_code(address);
}
static void home_menu_open(void) {
    if (g_menu || g_menu_closing || !g_root.game) return;
    g_menu_page = 0; g_menu_move = g_menu_confirm = g_menu_prev_sel = -1; g_menu_rows = menu_rows(0); g_menu_sel = 0; g_menu_closing = 0; g_menu_anim = 1;
    game_pause(1);
    [NSNotificationCenter.defaultCenter postNotificationName:@"DMPlayersCommand" object:nil userInfo:@{@"op": @"launcher", @"on": @1}];   // controllers and phones send DMLauncherInput
    home_menu_build();
    LOG("front end: Home menu opened%s", tv_on() ? " (on the TV)" : "");
    [NSNotificationCenter.defaultCenter postNotificationName:@"DMShellChanged" object:nil];
}
static void home_menu_toggle(void) { if (g_menu) home_menu_close(); else home_menu_open(); }
static void home_menu_input(NSDictionary *u) {
    if (!g_menu || g_menu_closing) return;
    if ([u[@"p"] intValue] != 1) return;   // only player 1 runs the menu (who that is: the menu's Players page)
    NSString *k = u[@"key"], *act = g_menu_rows[g_menu_sel][2];
    int source = [u[@"source"] intValue];
    int dir = [k isEqualToString:@"left"] ? -1 : [k isEqualToString:@"right"] ? 1 : 0;
    if (![u[@"on"] boolValue]) {
        if (!g_volume_hold_touch && dir == g_volume_hold_dir && source == g_volume_hold_player) volume_hold_stop();
        return;
    }
    volume_hold_stop();
    int slot = [act hasPrefix:@"slot:"] ? [[act substringFromIndex:5] intValue] : -1;
    BOOL up = [k isEqualToString:@"up"], down = [k isEqualToString:@"down"];
    if ((up || down) && g_menu_move >= 0) {   // carrying a player: the selection chooses where it goes among the eight numbers; nothing changes until A
        g_menu_sel = MAX(0, MIN(DM_PLAYERS - 1, g_menu_sel + (up ? -1 : 1))); menu_refresh(g_menu_sel); return;
    }
    if (up) g_menu_sel = MAX(0, g_menu_sel - 1);
    else if (down) g_menu_sel = MIN((int)g_menu_rows.count - 1, g_menu_sel + 1);
    else if ([k isEqualToString:@"a"]) { home_menu_activate(g_menu_sel); return; }
    else if (dir && [act isEqualToString:@"volume"]) { g_volume_hold_player = source; volume_hold_start(dir, NO); return; }
    else if ([k isEqualToString:@"y"] && slot >= 0) { slot_layout(slot); return; }
    else if ([k isEqualToString:@"x"] && slot >= 0) {
        if (g_menu_confirm == slot) slot_remove(slot);
        else { shell_slot_info info[DM_PLAYERS]; shell_slots_list(info); if (info[slot].kind != SHELL_SLOT_NONE) { g_menu_confirm = slot; menu_refresh(slot); } }
        return;
    }
    else if ([k isEqualToString:@"b"]) {
        if (g_menu_move >= 0 || g_menu_confirm >= 0) { g_menu_move = g_menu_confirm = -1; menu_refresh(g_menu_sel); }
        else if (g_menu_page) { menu_page(0, 1); }
        else home_menu_close();
        return;
    }
    if (g_menu_confirm >= 0) { g_menu_confirm = -1; menu_refresh(g_menu_sel); return; }
    home_menu_draw();
}
static void home_menu_watch(void) {   // once the game starts (startGame)
    static int once; if (once++) return;
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserverForName:@"DMHomePressed" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {   // only player 1's Home (the iPad's own button counts as player 1 too)
        int p = [n.userInfo[@"p"] intValue];
        if (p != 1) { LOG("front end: Home from player %d ignored: only player 1 opens the menu", p); return; }
        home_menu_toggle();
    }];
    [nc addObserverForName:@"DMShellChanged" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {   // the volume or an output changed on the iPad's panel: the rows' words follow
        (void)n; if (!g_menu || g_menu_closing) return;
        NSArray *rows = menu_rows(g_menu_page); if (rows.count != g_menu_rows.count) { menu_refresh(g_menu_sel); return; }
        g_menu_rows = rows;
        for (UIView *card in g_menu_cards) for (NSUInteger i = 0; i < rows.count; i++) {
            UIView *row = [card viewWithTag:100 + (NSInteger)i];
            ((UILabel *)[row viewWithTag:64]).text = rows[i][0];
            ((UILabel *)[row viewWithTag:62]).text = rows[i][1];
            UISlider *slider = (UISlider *)[row viewWithTag:65];
            if (slider && !slider.tracking) slider.value = volume_pref();
        }
    }];
    [nc addObserverForName:@"DMLauncherInput" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { home_menu_input(n.userInfo); }];
    [nc addObserverForName:@"DMPadsChanged" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        (void)n; if (!g_volume_hold_touch) volume_hold_stop();
    }];
    [nc addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        (void)n; volume_hold_stop();
    }];
    [nc addObserverForName:@"DMPlayersChanged" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {   // a phone joined or left while the Players page is up
        (void)n; if (!g_volume_hold_touch) volume_hold_stop();
        if (g_menu && !g_menu_closing && g_menu_page == 1) menu_refresh(g_menu_sel);
    }];
}
int front_ios_menu_open(void) { return g_menu != nil; }
void front_ios_menu_repause(void) {   // the return from the background undid the pause: apply it again while the menu is up
    if (!g_menu || g_menu_closing || !g_pause_q) return;
    dispatch_async(g_pause_q, ^{ g_paused = 0; }); game_pause(1);
}

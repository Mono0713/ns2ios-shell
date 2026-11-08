// Virtual gamepad (Nintendo button positions) + physical controllers (GameController). Both are merged and handed to the host through dm_input_set (hle_hid.c, bit layout in dm_input.h).
//   Two layouts, three in handheld mode; one tap on the layout button at the top centre (labelled with the current layout, "2D" / "3D" / "Tap") goes to the next, and the choice is kept in NSUserDefaults (each game is its own app, so per game); the first launch uses the game profile's pad_layout (DM_GAME_PAD_LAYOUT).
//   Tap (touch): no control but the layout button, every other touch goes to the game's touch screen; offered only while the game is in handheld mode, the only one in which it reads the touch screen (Balatro, played by touch).
//   2D (simple): top corners ZL above L (one column), ZR above R likewise, teardrops with the tip toward the screen corner; − and + side by side at the top centre; the left stick in the bottom-left corner (fixed ring, tilt measured from the ring centre, small dead zone);
//     the A (right) B (bottom) X (top) Y (left) diamond in the bottom-right corner, sliding a finger between keys switches keys. Each bottom corner holds a single control, so it sits close in (reaching halfway into the side safe-area inset).
//   3D (full, Pro Controller style): everything in 2D (left stick and diamond keep their place and size), plus a D-pad (inward of and below the left stick, 8-way), a right stick that is not drawn
//     (a touch landing in the right third of the screen on no control holds it: centred where it lands, the centre dragged along once the finger passes the stick radius) and L3 / R3 (small round keys in the top row, inward of ZL / ZR).
//     Breath of the Wild crouches with L3 and uses the scope with R3; 3D World and Breath of the Wild turn the camera with the right stick.
//   Touch-down ownership: locked keys first (shoulders, − / +, the layout button, L3 / R3), then whichever of the diamond, the D-pad and the left stick has the smallest distance / grab radius (the left stick's grab circle borders the D-pad),
//     then in 3D the right stick for a touch in the right third.
//   Everything hugs the edges and corners to leave the picture room; controls sit over the picture, one CAShapeLayer each: a press only swaps the fill, a stick only moves its knob, nothing redraws the whole screen.
//   Touches no control takes (in 3D, those outside the right third) go to the game's touch screen (pushGame; Super Mario Galaxy's pointer in handheld mode).
//   The virtual gamepad (layout button included) hides while a physical controller is connected and comes back when it is removed; meanwhile every touch goes to the game. Physical controllers keep every button (D-pad and right stick included); each is a player of its own and has its own button layout (shell_players.m).
//   Shaking the phone shakes the controller (DM_BTN_SHAKE: its six-axis sensor, hle_hid.c), whichever controls are in use; see "Shaking the phone" below.
//   Tap layout, out of the way: the layout and QR buttons fade out a few seconds after they were last used; a tap outside the 16:9 picture (the black bars) or a swipe down
//     from the top edge brings them back for a while. Touches outside the picture never reach the game in this layout (they would land on its edge anyway).
//   Editing the controls (2D / 3D): holding the layout button opens an editor over the game. Each group (left stick, diamond, D-pad, ZL+L, ZR+R, − / +, L3, R3) is dragged to
//     move it and pinched to resize it; a group can be hidden; the left stick is fixed (as above) or floating (it centres where a finger lands in the left half of the screen
//     and is dragged along past its radius); an extra opacity multiplies the launcher's. Kept per layout in NSUserDefaults (DmPadCustom.<layout>, shared by every game of
//     a package so a library plays the same everywhere), offsets in u so they follow the launcher's size.
#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#import <CoreMotion/CoreMotion.h>
#import <CoreImage/CoreImage.h>
#import <CoreText/CoreText.h>
#include <pthread.h>
#include "dm.h"
#include "dm_input.h"
#include "front.h"
#include "game_profile.h"
#include "haptics_apple.h"
#include "shell_motion.h"
#include "shell_slots.h"
#include <stdatomic.h>

enum { B_A = 0, B_B, B_X, B_Y, B_LS, B_RS, B_L, B_R, B_ZL, B_ZR, B_PLUS, B_MINUS, B_LEFT, B_UP, B_RIGHT, B_DOWN, B_N };
enum { C_NONE = 0, C_STICK, C_DPAD, C_FACE, C_BTN, C_SWAP, C_GAME };   // which control a touch holds; C_GAME: none, the touch goes to the game's touch screen (finger slot << 8)

static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static uint64_t g_touch_btn, g_pad_btn, g_shake_btn;
static int32_t g_touch_lx, g_touch_ly, g_touch_rx, g_touch_ry, g_pad_lx, g_pad_ly, g_pad_rx, g_pad_ry;
static int tilted(int32_t x, int32_t y) { return (int64_t)x * x + (int64_t)y * y > (int64_t)4000 * 4000; }
static void publish(void) {
    pthread_mutex_lock(&g_mu);
    int32_t lx = g_touch_lx, ly = g_touch_ly, rx = g_touch_rx, ry = g_touch_ry;
    if (tilted(g_pad_lx, g_pad_ly)) { lx = g_pad_lx; ly = g_pad_ly; }   // a tilted physical stick wins
    if (tilted(g_pad_rx, g_pad_ry)) { rx = g_pad_rx; ry = g_pad_ry; }
    dm_input_set(g_touch_btn | g_pad_btn | g_shake_btn, lx, ly, rx, ry);
    pthread_mutex_unlock(&g_mu);
}

// ---- Shaking the phone, and its motion ----
// Device motion at 100 Hz (accelerometer and gyroscope; no permission prompt), or the accelerometer alone at 60 Hz on a device with no gyroscope. Shaking: gravity is followed by a
// slow low-pass (about 0.8 s), and a sample whose acceleration beyond it exceeds DM_SHAKE_G (1.5 G by default; Documents/env.txt overrides) is a hit. The controller is shaken until
// 120 ms after the last hit: a flick is one shake (the host finishes it as a whole cycle) and shaking on keeps it going. Holding the phone and pressing the screen stays far below the
// threshold. Each detected shake is logged with its peak.
// Motion: player 1's six-axis sensor follows the device (shell_motion.h) while no controller or phone holds player 1 and the launcher's Motion controls are on. The device's axes
// go to the controller's by the screen's orientation: the screen's right is x, its top y, out of the screen z, so the device lying flat with the screen up is a controller lying flat
static CMMotionManager *g_motion;
static atomic_int g_screen_orientation = UIInterfaceOrientationLandscapeRight;   // set on the main thread (layoutSubviews), read on the motion queue
static void to_controller(int o, const double d[3], double c[3]) {   // a device-frame vector (x right, y top, z out of the screen, in portrait) in the controller's frame
    switch (o) {
    case UIInterfaceOrientationLandscapeRight: c[0] = -d[1]; c[1] = d[0]; break;   // the device's top on the left
    case UIInterfaceOrientationLandscapeLeft: c[0] = d[1]; c[1] = -d[0]; break;
    case UIInterfaceOrientationPortraitUpsideDown: c[0] = -d[0]; c[1] = -d[1]; break;
    default: c[0] = d[0]; c[1] = d[1]; break;
    }
    c[2] = d[2];
}
static void motion_start(void) {
    if (g_motion) return;
    g_motion = [CMMotionManager new];
    if (!g_motion.accelerometerAvailable) { LOG("front end: no accelerometer, shaking the phone does nothing"); return; }
    const char *e = getenv("DM_SHAKE_G"); double thr = e && atof(e) > 0 ? atof(e) : 1.5;
    BOOL gyro = g_motion.deviceMotionAvailable;
    LOG("front end: shaking the phone shakes the controller (threshold %.2f G)%s", thr, gyro ? "; its gyroscope is player 1's motion while player 1 plays on it" : "; no gyroscope");
    NSOperationQueue *q = [NSOperationQueue new]; q.maxConcurrentOperationCount = 1;
    __block double gx = 0, gy = 0, gz = 0, last = -1, peak = 0; __block BOOL init = NO;
    void (^shake)(CMAcceleration, NSTimeInterval) = ^(CMAcceleration a, NSTimeInterval ts) {
        if (!init) { gx = a.x; gy = a.y; gz = a.z; init = YES; }
        double dx = a.x - gx, dy = a.y - gy, dz = a.z - gz, g = sqrt(dx * dx + dy * dy + dz * dz);
        gx += (a.x - gx) * 0.02; gy += (a.y - gy) * 0.02; gz += (a.z - gz) * 0.02;
        if (g > thr) { if (last < 0) peak = 0; last = ts; peak = fmax(peak, g); }
        BOOL on = last >= 0 && ts - last < 0.12;
        if (!on && last >= 0) { LOG("front end: phone shaken (peak %.1f G)", peak); last = -1; }
        uint64_t want = on ? DM_BTN_SHAKE : 0;
        pthread_mutex_lock(&g_mu); BOOL changed = g_shake_btn != want; g_shake_btn = want; pthread_mutex_unlock(&g_mu);
        if (changed) publish();
    };
    if (!gyro) {
        g_motion.accelerometerUpdateInterval = 1.0 / 60;
        [g_motion startAccelerometerUpdatesToQueue:q withHandler:^(CMAccelerometerData *d, NSError *err) { (void)err; if (d) shake(d.acceleration, d.timestamp); }];
        return;
    }
    static shell_motion m;
    g_motion.deviceMotionUpdateInterval = 1.0 / 100;
    [g_motion startDeviceMotionUpdatesToQueue:q withHandler:^(CMDeviceMotion *d, NSError *err) {
        (void)err; if (!d) return;
        CMAcceleration gr = d.gravity, u = d.userAcceleration; CMRotationRate r = d.rotationRate;
        shake((CMAcceleration){gr.x + u.x, gr.y + u.y, gr.z + u.z}, d.timestamp);   // the accelerometer's reading, as before
        if (shell_slot_held(0)) { m.init = 0; return; }   // player 1 is a controller's or a phone's: not the iPad's
        int o = atomic_load(&g_screen_orientation);
        double dg[3] = {gr.x, gr.y, gr.z}, du[3] = {u.x, u.y, u.z}, dr[3] = {r.x, r.y, r.z}, cg[3], cu[3], cr[3];
        to_controller(o, dg, cg); to_controller(o, du, cu); to_controller(o, dr, cr);
        shell_motion_feed(&m, 0, d.timestamp, cg, cu, cr);
    }];
}

// ---- Layout constants (in u; x measured from the outer edge, the right half mirrors) ----
static const CGFloat
    K_ZL_X = 44, K_ZL_Y = 40, K_ZL_R = 26,          // ZL / ZR: centre from the outer edge and the top, radius
    K_L_X = 44, K_L_Y = 108, K_L_R = 24,            // L / R: same column as ZL / ZR
    K_DROP_TIP = 1.45,                              // teardrop tip distance from the centre (times the radius)
    K_CORNER_IN = 0.5,                              // how far the bottom-corner controls reach into the side safe-area inset (in landscape there is only the rounded screen corner there; the Dynamic Island is mid-edge)
    K_FACE_X = 81, K_PAD_Y = 82,                    // diamond centre from the outer edge; diamond and stick centre from the bottom (B's lower edge about 5 above it)
    K_FACE_GAP = 50, K_FACE_R = 27,                 // diamond: key distance from the centre, key radius
    K_PILL_DX = 52, K_PILL_Y = 22, K_PILL_W = 50, K_PILL_H = 28,   // − / +: centre from the screen's midline (the middle goes to the layout button) and from the top, size
    K_SWAP_R = 15,                                  // layout button: top centre, level with − / +
    K_STICK_X = 81, K_STICK_R = 77, K_KNOB_R = 30,  // left stick: mirrors the diamond, the ring as large as the whole diamond (key distance + key radius), the knob a little larger than a diamond key
    K_STICK_GRAB = 1.4,                             // how near the ring centre a touch-down grabs a stick (times the ring radius)
    K_FULL = 0.8,                                   // full tilt at this fraction of the ring radius (the knob still travels to the ring edge)
    K_DEAD = 0.1,                                   // stick dead zone (times the ring radius)
    // controls only the 3D layout has
    K_LOW_X = 231, K_LOW_Y = 64,                    // D-pad centre from the outer edge and the bottom (inward of and below the left stick, as on a Pro Controller)
    K_DPAD_R = 48, K_ARM_W = 17, K_ARM_IN = 11,     // D-pad: arm outer edge from the centre, half-width, tip from the centre
    K_DPAD_GRAB = 1.3,                              // D-pad grab radius (times the outer edge)
    K_RSTICK_R = 60,                                // right stick (not drawn): radius around its centre, the touch-down point
    K_RSWIPE = 1.0 / 3,                             // right stick area: this fraction of the screen width from the right edge (not in u)
    K_CLICK_X = 102, K_CLICK_R = 17;                // L3 / R3: centre from the outer edge (level with ZL / ZR), radius
static const int k_btns[] = {B_ZL, B_L, B_ZR, B_R, B_MINUS, B_PLUS, B_LS, B_RS};   // keys locked at touch-down (L3 / R3 only in the 3D layout)
// NSUserDefaults: 0 = 2D, 1 = 3D, 2 = Tap (DM_GAME_PAD_LAYOUT's numbers); each game's own in a package of several (main.m sets DM_SHELL_GAME)
static NSString *layout_key(void) { const char *g = getenv("DM_SHELL_GAME"); return g && *g ? [@"DmPadLayout." stringByAppendingString:@(g)] : @"DmPadLayout"; }
int dm_opmode(void);   // hle_oe.c: 0 = handheld
// Editable groups of controls (the editor moves / resizes / hides a group as a whole)
enum { G_STICK = 0, G_FACE, G_DPAD, G_LSH, G_RSH, G_PILLS, G_L3, G_R3, G_N };
typedef struct { CGFloat dx, dy, s; BOOL hide; } pad_adj;   // offset from the default place (in u), scale, hidden
static int groupOf(int b) {
    switch (b) { case B_A: case B_B: case B_X: case B_Y: return G_FACE; case B_LS: return G_L3; case B_RS: return G_R3;
    case B_L: case B_ZL: return G_LSH; case B_R: case B_ZR: return G_RSH; case B_PLUS: case B_MINUS: return G_PILLS; default: return G_DPAD; }
}
static const CGFloat K_CHROME_SECONDS = 3, K_EDGE = 24, K_EDGE_PULL = 40;   // Tap layout: the buttons fade after this long; a swipe from within K_EDGE of the top, K_EDGE_PULL down, shows them
static const CGFloat K_SCALE_MIN = 0.6, K_SCALE_MAX = 1.8;

@interface DmGamepad : UIView
@end
static __weak DmGamepad *g_view;
static float g_touch_opacity = 1, g_touch_scale = 1;   // dm_touch_style
static BOOL shell_zh_hant(void) { NSString *l = NSLocale.preferredLanguages.firstObject.lowercaseString ?: @""; return [l hasPrefix:@"zh-hant"] || [l hasPrefix:@"zh-tw"] || [l hasPrefix:@"zh-hk"] || [l hasPrefix:@"zh-mo"]; }

@implementation DmGamepad {
    NSMapTable<UITouch *, NSNumber *> *_owner;     // touch → control (with the key for C_BTN or the stick for C_STICK, << 8)
    UITouch *_stick[2]; CGPoint _stickNow[2];      // the touch holding each stick and where it is now (0 left, 1 right)
    CGPoint _rCentre;                              // the right stick's centre: where its touch landed, dragged along past K_RSTICK_R
    uint64_t _faceBits, _dpadBits, _btnBits;
    NSMapTable<UITouch *, NSNumber *> *_faceOf;    // which keys each touch on the diamond currently holds
    CAShapeLayer *_key[B_N]; CATextLayer *_label[B_N];   // one layer per key
    CAShapeLayer *_ring, *_knob;                   // the left stick (the right one is not drawn)
    CAShapeLayer *_swap; CATextLayer *_swapLabel; BOOL _swapHeld;
    CAShapeLayer *_qr; CATextLayer *_qrLabel; UIView *_qrOverlay;   // the phone gamepads' QR code button (below the layout button) and the card it opens
    UIImpactFeedbackGenerator *_touchFeedback;       // one short feedback per touch-control press edge
    unsigned _hapticSticks;
    BOOL _stickShown;                              // the left stick was held at the last refresh
    BOOL _full, _tap;                              // the 3D layout / the Tap layout is current
    CALayer *_controls;                            // holds every control layer: hidden while a controller or phone plays (the view itself stays, for game touches)
    BOOL _padOff;                                  // the controls are hidden: every touch goes to the game
    BOOL _external;                                // a physical controller or a phone plays: the controls show only for a while after a tap
    NSTimer *_peekTimer;
    UITouch *_game[16];                            // touches on the game's touch screen by finger slot
    // Tap layout: the layout / QR buttons fade out
    BOOL _chromeHidden; NSTimer *_chromeTimer;
    UITouch *_edgeTouch; CGPoint _edgeStart;       // a touch that began at the top edge: pulled down, it shows the buttons
    // the editor and what it edits
    pad_adj _adj[G_N];
    BOOL _floatStick; CGPoint _lCentre;            // floating left stick, and its centre while held
    float _alpha;                                  // the editor's opacity, times the launcher's
    BOOL _editing; int _sel;
    UIView *_editPanel; NSLayoutConstraint *_panelX, *_panelY; UILabel *_selName; UISlider *_sizeSlider, *_alphaSlider; UISwitch *_hideSwitch; UISegmentedControl *_stickSeg;
    CAShapeLayer *_selRing;
    NSMapTable<UITouch *, NSNumber *> *_editGroup; NSMapTable<UITouch *, NSValue *> *_editPrev;
    NSTimer *_swapTimer;                           // holding the layout button opens the editor
}

static UIColor *k_idle, *k_on, *k_line, *k_ringFill, *k_text, *k_textOn;
static CAShapeLayer *shape(CALayer *parent) {
    CAShapeLayer *l = [CAShapeLayer layer];
    l.fillColor = k_idle.CGColor; l.strokeColor = k_line.CGColor; l.lineWidth = 1.5;
    l.shadowColor = UIColor.blackColor.CGColor; l.shadowOpacity = 0.2; l.shadowRadius = 3; l.shadowOffset = CGSizeMake(0, 1);
    [parent addSublayer:l]; return l;
}
static CATextLayer *label(CALayer *parent, NSString *s) {
    CATextLayer *t = [CATextLayer layer];
    t.string = s; t.alignmentMode = kCAAlignmentCenter; t.foregroundColor = k_text.CGColor; t.contentsScale = UIScreen.mainScreen.scale;
    [parent addSublayer:t]; return t;
}

- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.multipleTouchEnabled = YES; self.opaque = NO; self.backgroundColor = UIColor.clearColor;
        const char *feedback = getenv("DM_TOUCH_HAPTICS");
        if (!feedback || atoi(feedback)) {
            _touchFeedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
            [_touchFeedback prepare];
        }
        _owner = [NSMapTable strongToStrongObjectsMapTable]; _faceOf = [NSMapTable strongToStrongObjectsMapTable];
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            // each colour carries its own low opacity instead of lowering the whole view's alpha (that would add an off-screen pass for the full-screen layer)
            k_idle = [UIColor colorWithWhite:1 alpha:0.14]; k_on = [UIColor colorWithWhite:1 alpha:0.45]; k_line = [UIColor colorWithWhite:1 alpha:0.38];
            k_ringFill = [UIColor colorWithWhite:1 alpha:0.06]; k_text = [UIColor colorWithWhite:1 alpha:0.6]; k_textOn = [UIColor colorWithWhite:0 alpha:0.7];
        });
        _controls = [CALayer layer]; [self.layer addSublayer:_controls];
        _ring = shape(_controls); _ring.fillColor = k_ringFill.CGColor;
        _knob = shape(_controls);
        CAShapeLayer *in = [CAShapeLayer layer]; in.fillColor = nil; in.strokeColor = k_line.CGColor; in.lineWidth = 1.5;   // inner ring of the knob
        [_knob addSublayer:in];
        static NSString *const names[B_N] = {@"A", @"B", @"X", @"Y", @"L3", @"R3", @"L", @"R", @"ZL", @"ZR", @"+", @"−"};
        for (int b = 0; b < B_N; b++) {
            _key[b] = shape(_controls);
            if (names[b]) _label[b] = label(_key[b], names[b]);   // the D-pad arms carry no label
        }
        _swap = shape(_controls); _swapLabel = label(_swap, @"");
        _qr = shape(_controls); _qrLabel = label(_qr, @"QR");
        _selRing = [CAShapeLayer layer]; _selRing.fillColor = nil; _selRing.strokeColor = [UIColor colorWithRed:0.35 green:0.75 blue:1 alpha:0.9].CGColor;
        _selRing.lineWidth = 2; _selRing.lineDashPattern = @[@6, @4]; _selRing.hidden = YES; [_controls addSublayer:_selRing];
        _editGroup = [NSMapTable strongToStrongObjectsMapTable]; _editPrev = [NSMapTable strongToStrongObjectsMapTable]; _sel = -1;
        NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
        _floatStick = [ud integerForKey:@"DmPadStickMode"] == 1;
        _alpha = [ud objectForKey:@"DmPadAlpha"] ? fminf(1, fmaxf(0.1f, [ud floatForKey:@"DmPadAlpha"])) : 1;
        _controls.opacity = g_touch_opacity * _alpha;
        // First-launch layout from the game profile (DM_PAD_LAYOUT, atoi; the profile writes simple / full / touch and the packer turns it
        // into 0 / 1 / 2, the order game.py uses). The game-free shell is compiled against the placeholder profile, which asks for full:
        // that is the shell's own default, and a profile that sets no key keeps it (upstream's Mac host would compile game.py's default,
        // simple, instead -- the one key where the two differ, left as it is on purpose, see HANDOFF 1b). A layout the player picks is
        // saved in NSUserDefaults and takes precedence from then on, which is why the environment only decides the first launch.
        NSNumber *saved = [NSUserDefaults.standardUserDefaults objectForKey:layout_key()];
        const char *pad_env = getenv("DM_PAD_LAYOUT");
        int l = saved ? (int)saved.integerValue : (pad_env ? atoi(pad_env) : DM_GAME_PAD_LAYOUT);
        if (l == 2 && dm_opmode() != 0) l = 0;   // Tap only in handheld mode (env.txt's DM_OPMODE may have changed it)
        _full = l == 1; _tap = l == 2;
        [self loadAdj];
        [self applyLayout];
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserver:self selector:@selector(padsChanged) name:@"DMPadsChanged" object:nil];   // shell_players.m, on the main thread
        [self padsChanged];
        motion_start();
    }
    return self;
}
- (BOOL)groupShown:(int)g { return !_tap && ((g != G_DPAD && g != G_L3 && g != G_R3) || _full); }   // the group belongs to the current layout
- (BOOL)groupLive:(int)g { return [self groupShown:g] && !_adj[g].hide; }   // ... and takes touches
- (void)applyLayout {   // show / hide the controls for the current layout
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (int b = 0; b < B_N; b++) { int g = groupOf(b);
        _key[b].hidden = ![self groupShown:g] || (_adj[g].hide && !_editing);
        _key[b].opacity = _adj[g].hide ? 0.3 : 1; }   // a hidden group shows faintly in the editor
    _ring.hidden = _knob.hidden = ![self groupShown:G_STICK] || (_adj[G_STICK].hide && !_editing);
    _ring.opacity = _knob.opacity = _adj[G_STICK].hide ? 0.3 : 1;
    _swapLabel.string = _tap ? @"Tap" : _full ? @"3D" : @"2D";
    _selRing.hidden = !_editing || _sel < 0;
    [CATransaction commit];
    if (_tap && !_editing) [self peekChrome]; else [self showChrome:YES];
    [self hintOnce];
}
- (void)nextLayout {   // 2D → 3D (→ Tap in handheld mode) → 2D: release every touch first (no key stays held), save, lay out again
    int l = _tap ? 0 : _full ? (dm_opmode() == 0 ? 2 : 0) : 1;
    [self reset];
    _full = l == 1; _tap = l == 2;
    [NSUserDefaults.standardUserDefaults setObject:@(l) forKey:layout_key()];
    [self loadAdj];
    [self applyLayout]; [self setNeedsLayout];
}

// ---- The editor's adjustments, kept per layout (2D / 3D) ----
- (NSString *)adjKey { return _full ? @"DmPadCustom.3D" : @"DmPadCustom.2D"; }
- (void)loadAdj {
    for (int g = 0; g < G_N; g++) _adj[g] = (pad_adj){0, 0, 1, NO};
    NSArray *a = [NSUserDefaults.standardUserDefaults arrayForKey:self.adjKey];
    for (int g = 0; g < G_N && g < (int)a.count; g++) {
        NSArray *e = [a[g] isKindOfClass:NSArray.class] ? a[g] : nil; if (e.count < 4) continue;
        _adj[g] = (pad_adj){[e[0] doubleValue], [e[1] doubleValue], fmin(K_SCALE_MAX, fmax(K_SCALE_MIN, [e[2] doubleValue])), [e[3] boolValue]};
    }
}
- (void)saveAdj {
    NSMutableArray *a = [NSMutableArray array];
    for (int g = 0; g < G_N; g++) [a addObject:@[@(_adj[g].dx), @(_adj[g].dy), @(_adj[g].s), @(_adj[g].hide)]];
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    [ud setObject:a forKey:self.adjKey]; [ud setInteger:_floatStick ? 1 : 0 forKey:@"DmPadStickMode"]; [ud setFloat:_alpha forKey:@"DmPadAlpha"];
    LOG("front end: touch controls edited (%s, left stick %s, opacity x%.2f)", _full ? "3D" : "2D", _floatStick ? "floating" : "fixed", _alpha);
}

// ---- Tap layout: the layout / QR buttons step out of the way ----
- (void)showChrome:(BOOL)on {
    if (on) { [_chromeTimer invalidate]; _chromeTimer = nil; }
    if (on == !_chromeHidden) return;
    _chromeHidden = !on;
    [CATransaction begin]; [CATransaction setAnimationDuration:on ? 0.15 : 0.5];
    _swap.opacity = _qr.opacity = on ? 1 : 0;
    [CATransaction commit];
}
- (void)peekChrome {   // show the buttons, then fade them K_CHROME_SECONDS later (or once the layout button is let go)
    [self showChrome:YES];
    __weak DmGamepad *weakSelf = self;
    _chromeTimer = [NSTimer scheduledTimerWithTimeInterval:K_CHROME_SECONDS repeats:NO block:^(NSTimer *t) { [weakSelf chromeEnd]; }];
}
- (void)chromeEnd {
    _chromeTimer = nil;
    if (!_tap || _editing || _qrOverlay) return;
    for (UITouch *t in _owner) if (([_owner objectForKey:t].unsignedLongLongValue & 0xff) == C_SWAP) { [self peekChrome]; return; }   // still held
    [self showChrome:NO];
}
- (void)toast:(NSString *)s {   // a short note over the game, gone by itself
    UILabel *l = [UILabel new]; l.text = s; l.numberOfLines = 0; l.textAlignment = NSTextAlignmentCenter;
    l.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold]; l.textColor = UIColor.whiteColor;
    l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.7]; l.layer.cornerRadius = 12; l.clipsToBounds = YES;
    CGSize sz = [l sizeThatFits:CGSizeMake(MIN(460, self.bounds.size.width - 40), CGFLOAT_MAX)];
    l.frame = CGRectMake(0, 0, sz.width + 32, sz.height + 20);
    l.center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMinY(self.safe) + 90);
    l.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    l.userInteractionEnabled = NO; l.alpha = 0; [self addSubview:l];
    [UIView animateWithDuration:0.25 animations:^{ l.alpha = 1; } completion:^(BOOL d1) { (void)d1;
        [UIView animateWithDuration:0.4 delay:4 options:0 animations:^{ l.alpha = 0; } completion:^(BOOL d2) { (void)d2; [l removeFromSuperview]; }]; }];
}
- (void)hintOnce {   // the first time each of these is reachable, say how
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults; BOOL zh = shell_zh_hant();
    NSString *key = _tap ? @"DmPadHintTap" : @"DmPadHintEdit";
    if (_editing || _padOff || [ud boolForKey:key]) return;
    [ud setBool:YES forKey:key];
    NSString *s = _tap ? (zh ? @"上方按鈕幾秒後會自動隱藏，點一下畫面外的黑邊或從頂端往下滑可叫出" : @"The buttons at the top hide after a few seconds: tap the black bars or swipe down from the top edge to bring them back")
                       : (zh ? @"長按上方的「2D / 3D」按鈕，可調整虛擬搖桿的位置、大小與模式" : @"Hold the 2D / 3D button at the top to move, resize or change the touch controls");
    __weak DmGamepad *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [weakSelf toast:s]; });
}

// ---- Layout (points; computed inside the safe area) ----
- (CGRect)safe { return UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets); }
- (CGRect)corner { UIEdgeInsets i = self.safeAreaInsets; i.left *= K_CORNER_IN; i.right *= K_CORNER_IN; return UIEdgeInsetsInsetRect(self.bounds, i); }   // the rectangle the bottom-corner controls use
- (CGFloat)u { return MIN(self.bounds.size.height / 430.0, 1.3) * g_touch_scale; }   // 1 = 430 points tall (iPhone Pro Max landscape)
static CGPoint side(CGRect s, int right, CGFloat dx, CGFloat y) { return CGPointMake(right ? CGRectGetMaxX(s) - dx : CGRectGetMinX(s) + dx, y); }
// Each group's place is its default place, moved by its offset; its members spread from the group's anchor by its scale (shell_adjust below)
- (CGPoint)off:(int)g { CGFloat u = self.u; return CGPointMake(_adj[g].dx * u, _adj[g].dy * u); }
static CGFloat dist(CGPoint a, CGPoint b) { return hypot(a.x - b.x, a.y - b.y); }
static CGPoint addp(CGPoint a, CGPoint b) { return CGPointMake(a.x + b.x, a.y + b.y); }
static CGPoint spread(CGPoint anchor, CGPoint p, CGFloat s, CGPoint off) { return CGPointMake(anchor.x + (p.x - anchor.x) * s + off.x, anchor.y + (p.y - anchor.y) * s + off.y); }
- (CGPoint)faceCenter { CGRect s = self.corner; CGFloat u = self.u; return addp(side(s, 1, K_FACE_X * u, CGRectGetMaxY(s) - K_PAD_Y * u), [self off:G_FACE]); }
- (CGFloat)faceGap { return K_FACE_GAP * self.u * _adj[G_FACE].s; }
- (CGFloat)faceR { return K_FACE_R * self.u * _adj[G_FACE].s; }
- (CGPoint)facePos:(int)b { CGPoint c = self.faceCenter; CGFloat g = self.faceGap;
    switch (b) { case B_A: return CGPointMake(c.x + g, c.y); case B_B: return CGPointMake(c.x, c.y + g); case B_X: return CGPointMake(c.x, c.y - g); default: return CGPointMake(c.x - g, c.y); } }
- (CGPoint)stickHome { CGRect s = self.corner; return addp(side(s, 0, K_STICK_X * self.u, CGRectGetMaxY(s) - K_PAD_Y * self.u), [self off:G_STICK]); }   // the left stick's ring centre at rest
- (CGPoint)stickCentre:(int)i { return i ? _rCentre : (_floatStick && _stick[0]) ? _lCentre : self.stickHome; }
- (CGFloat)stickR:(int)i { return i ? K_RSTICK_R * self.u : K_STICK_R * self.u * _adj[G_STICK].s; }
- (BOOL)inRightArea:(CGPoint)p { CGRect b = self.bounds; return p.x >= CGRectGetMaxX(b) - b.size.width * K_RSWIPE; }
- (BOOL)inLeftHalf:(CGPoint)p { return p.x < CGRectGetMidX(self.bounds); }   // where a floating left stick may land
- (CGPoint)dpadCenter { CGRect s = self.corner; CGFloat u = self.u; return addp(side(s, 0, K_LOW_X * u, CGRectGetMaxY(s) - K_LOW_Y * u), [self off:G_DPAD]); }
- (CGFloat)dpadR { return K_DPAD_R * self.u * _adj[G_DPAD].s; }
static BOOL isDrop(int b) { return b == B_ZL || b == B_L || b == B_ZR || b == B_R; }
static BOOL isClick(int b) { return b == B_LS || b == B_RS; }
- (CGPoint)dropBase:(int)b { CGRect s = self.safe; CGFloat u = self.u; BOOL z = b == B_ZL || b == B_ZR;
    return side(s, b == B_ZR || b == B_R, (z ? K_ZL_X : K_L_X) * u, CGRectGetMinY(s) + (z ? K_ZL_Y : K_L_Y) * u); }
- (CGPoint)shoulderAnchor:(BOOL)right { CGPoint a = [self dropBase:right ? B_ZR : B_ZL], b = [self dropBase:right ? B_R : B_L]; return CGPointMake((a.x + b.x) / 2, (a.y + b.y) / 2); }
- (CGPoint)dropCenter:(int)b { BOOL right = b == B_ZR || b == B_R; int g = right ? G_RSH : G_LSH;
    return spread([self shoulderAnchor:right], [self dropBase:b], _adj[g].s, [self off:g]); }
- (CGFloat)dropR:(int)b { return (b == B_ZL || b == B_ZR ? K_ZL_R : K_L_R) * self.u * _adj[b == B_ZR || b == B_R ? G_RSH : G_LSH].s; }
- (CGPoint)clickCenter:(int)b { CGRect s = self.safe; CGFloat u = self.u; int g = b == B_RS ? G_R3 : G_L3;
    return addp(side(s, b == B_RS, K_CLICK_X * u, CGRectGetMinY(s) + K_ZL_Y * u), [self off:g]); }
- (CGFloat)clickR:(int)b { return K_CLICK_R * self.u * _adj[b == B_RS ? G_R3 : G_L3].s; }
- (CGPoint)pillAnchor { CGRect s = self.safe; return CGPointMake(CGRectGetMidX(s), CGRectGetMinY(s) + K_PILL_Y * self.u); }
- (CGRect)pillRect:(int)b { CGFloat u = self.u, sc = _adj[G_PILLS].s, w = K_PILL_W * u * sc, h = K_PILL_H * u * sc; CGPoint a = self.pillAnchor;
    CGPoint c = spread(a, CGPointMake(a.x + (b == B_PLUS ? K_PILL_DX : -K_PILL_DX) * u, a.y), sc, [self off:G_PILLS]);   // − on the left, + on the right
    return CGRectMake(c.x - w / 2, c.y - h / 2, w, h); }
- (CGPoint)swapCenter { CGRect s = self.safe; return CGPointMake(CGRectGetMidX(s), CGRectGetMinY(s) + K_PILL_Y * self.u); }
// The editor: a group's anchor and the radius it is grabbed within
- (CGPoint)groupAnchor:(int)g {
    switch (g) {
    case G_STICK: return self.stickHome; case G_FACE: return self.faceCenter; case G_DPAD: return self.dpadCenter;
    case G_LSH: case G_RSH: return addp([self shoulderAnchor:g == G_RSH], [self off:g]);
    case G_PILLS: return addp(self.pillAnchor, [self off:G_PILLS]);
    default: return [self clickCenter:g == G_R3 ? B_RS : B_LS];
    }
}
- (CGFloat)groupExtent:(int)g {
    CGFloat u = self.u;
    switch (g) {
    case G_STICK: return [self stickR:0] * 1.05; case G_FACE: return self.faceGap + self.faceR; case G_DPAD: return self.dpadR * 1.1;
    case G_LSH: case G_RSH: { int z = g == G_RSH ? B_ZR : B_ZL; return dist([self dropCenter:z], [self groupAnchor:g]) + [self dropR:z] * 1.4; }
    case G_PILLS: return (K_PILL_DX + K_PILL_W / 2) * u * _adj[G_PILLS].s;
    default: return [self clickR:g == G_R3 ? B_RS : B_LS] * 1.8;
    }
}
- (int)btnAt:(CGPoint)p {   // locked keys (tested on touch-down only, then locked)
    CGFloat u = self.u;
    for (int i = 0; i < (int)(sizeof k_btns / sizeof *k_btns); i++) { int b = k_btns[i];
        if (![self groupLive:groupOf(b)]) continue;
        BOOL hit = isDrop(b) ? dist(p, [self dropCenter:b]) <= [self dropR:b] * 1.35
                 : isClick(b) ? dist(p, [self clickCenter:b]) <= [self clickR:b] * 1.35
                 : CGRectContainsPoint(CGRectInset([self pillRect:b], -8 * u, -8 * u), p);
        if (hit) return b; }
    return -1;
}
- (BOOL)inSwap:(CGPoint)p { return !_chromeHidden && dist(p, self.swapCenter) <= K_SWAP_R * self.u * 1.6; }
- (CGPoint)qrCenter { CGPoint c = self.swapCenter; return CGPointMake(c.x, c.y + 2.6 * K_SWAP_R * self.u); }
- (BOOL)inQR:(CGPoint)p { return !_qr.hidden && !_chromeHidden && dist(p, self.qrCenter) <= K_SWAP_R * self.u * 1.6; }
- (uint64_t)faceAt:(CGPoint)p {   // keys under the finger in the diamond (between two keys both count)
    uint64_t m = 0; CGFloat r = self.faceR * 1.25;
    for (int b = B_A; b <= B_Y; b++) if (dist(p, [self facePos:b]) <= r) m |= 1ull << b;
    return m;
}
- (uint64_t)dpadAt:(CGPoint)p {   // 8 directions: 45° each, diagonals press two keys; a small centre circle counts as none
    CGPoint c = self.dpadCenter; CGFloat dx = p.x - c.x, dy = p.y - c.y;
    if (hypot(dx, dy) < self.dpadR * 0.25) return 0;
    double a = atan2(-dy, dx) * 180 / M_PI; uint64_t m = 0;
    if (a > -67.5 && a < 67.5) m |= 1ull << B_RIGHT;
    if (a > 22.5 && a < 157.5) m |= 1ull << B_UP;
    if (a > 112.5 || a < -112.5) m |= 1ull << B_LEFT;
    if (a < -22.5 && a > -157.5) m |= 1ull << B_DOWN;
    return m;
}
- (CGPoint)knobOffset:(int)i {   // knob offset from the stick centre (clamped to the stick radius)
    if (!_stick[i]) return CGPointZero;
    CGPoint h = [self stickCentre:i]; CGFloat dx = _stickNow[i].x - h.x, dy = _stickNow[i].y - h.y, d = hypot(dx, dy), R = [self stickR:i];
    if (d > R) { dx *= R / d; dy *= R / d; }
    return CGPointMake(dx, dy);
}

// ---- Touch ----
- (void)recompute {
    uint64_t face = 0; for (UITouch *t in _faceOf) face |= [_faceOf objectForKey:t].unsignedLongLongValue;
    uint64_t btn = 0, dpad = 0; BOOL swap = NO;
    for (UITouch *t in _owner) { uint64_t v = [_owner objectForKey:t].unsignedLongLongValue; int c = (int)(v & 0xff);
        if (c == C_BTN) btn |= 1ull << (v >> 8);
        else if (c == C_DPAD) dpad |= [self dpadAt:[t locationInView:self]];
        else if (c == C_SWAP) swap = YES; }
    int32_t ax[4] = {0};
    for (int i = 0; i < 2; i++) {
        CGPoint o = [self knobOffset:i]; CGFloat R = [self stickR:i], d = hypot(o.x, o.y), dz = R * K_DEAD;
        if (d <= dz) continue;
        CGFloat m = fmin((d - dz) / (R * K_FULL - dz), 1) / d;   // outside the dead zone: 0 rising to full at the full-tilt radius
        ax[i * 2] = (int32_t)lrint(o.x * m * 32767); ax[i * 2 + 1] = (int32_t)lrint(-o.y * m * 32767);   // host: up is positive; rounded so full tilt is exactly 32767
    }
    BOOL changed = face != _faceBits || dpad != _dpadBits || btn != _btnBits || swap != _swapHeld;
    uint64_t pressed = (face | dpad | btn) & ~(_faceBits | _dpadBits | _btnBits);
    unsigned gripping = (_stick[0] ? 1u : 0) | (_stick[1] ? 2u : 0);
    if (pressed || (swap && !_swapHeld) || (gripping & ~_hapticSticks)) {
        [_touchFeedback impactOccurredWithIntensity:0.6]; [_touchFeedback prepare];
    }
    _hapticSticks = gripping;
    _faceBits = face; _dpadBits = dpad; _btnBits = btn; _swapHeld = swap;
    pthread_mutex_lock(&g_mu);
    g_touch_btn = face | dpad | btn; g_touch_lx = ax[0]; g_touch_ly = ax[1]; g_touch_rx = ax[2]; g_touch_ry = ax[3];
    pthread_mutex_unlock(&g_mu);
    publish();
    BOOL stick = _stick[0] != nil;   // only the left stick is drawn: the right one needs no refresh
    if (changed || stick || _stickShown) [self refresh];   // also refresh on the stick release so the knob returns to the centre
    _stickShown = stick;
}
// Touches no control takes (all of them while a physical controller is connected) go to the game's touch screen, normalized on the 16:9 picture that front_ios.m
// centres in the screen: Super Mario Galaxy's pointer in handheld mode (profile op_mode). The host reports them only in handheld mode, as on the Switch (hle_hid.c touch_read)
- (CGRect)picture {   // the 16:9 picture front_ios.m centres in the screen
    CGRect b = self.bounds; CGFloat w = b.size.width, h = b.size.height;
    if (w <= 0 || h <= 0) return CGRectZero;
    if (w / h > 16.0 / 9.0) w = h * 16.0 / 9.0; else h = w * 9.0 / 16.0;
    return CGRectMake((b.size.width - w) / 2, (b.size.height - h) / 2, w, h);
}
- (void)pushGame {
    CGRect pic = self.picture; CGFloat w = pic.size.width, h = pic.size.height, x0 = pic.origin.x, y0 = pic.origin.y;
    if (w <= 0 || h <= 0) return;
    dm_touch t[16]; int n = 0;
    for (int i = 0; i < 16; i++) if (_game[i]) {
        CGPoint p = [_game[i] locationInView:self];
        t[n++] = (dm_touch){(uint32_t)i, (float)fmin(fmax((p.x - x0) / w, 0), 0.999), (float)fmin(fmax((p.y - y0) / h, 0), 0.999)};
    }
    dm_touch_set(t, n);
}
- (BOOL)gameBegin:(UITouch *)t {
    for (int i = 0; i < 16; i++) if (!_game[i]) { _game[i] = t; [_owner setObject:@(C_GAME | (uint64_t)i << 8) forKey:t]; return YES; }
    return NO;
}
- (void)touchesBegan:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    BOOL game = NO;
    if (_external) [self peek];   // a tap brings the hidden controls back for a while; this touch already uses them
    if (_editing) { [self editBegan:ts]; return; }
    for (UITouch *t in ts) {
        if (_padOff) { game |= [self gameBegin:t]; continue; }
        CGPoint p = [t locationInView:self]; int hit = _tap ? -1 : [self btnAt:p];
        if (hit >= 0) { [_owner setObject:@(C_BTN | (uint64_t)hit << 8) forKey:t]; continue; }
        if ([self inSwap:p]) { [_owner setObject:@(C_SWAP) forKey:t]; [self swapHoldStart]; continue; }
        if ([self inQR:p]) { [self showQR]; continue; }
        if (_tap) {
            if (!CGRectContainsPoint(self.picture, p)) { if (_chromeHidden) [self peekChrome]; else [self showChrome:NO]; continue; }   // the black bars: show / hide the buttons
            if (_chromeHidden && p.y - CGRectGetMinY(self.bounds) <= K_EDGE) { _edgeTouch = t; _edgeStart = p; }   // may become a swipe down from the top edge
            game |= [self gameBegin:t]; continue;
        }
        // diamond, D-pad, left stick: take the one with the smallest distance / grab radius, if it is <= 1
        CGFloat best = 1; int kind = C_NONE, idx = 0;
        if ([self groupLive:G_FACE]) { CGFloat f = dist(p, self.faceCenter) / (self.faceGap + self.faceR * 1.6); if (f <= best) { best = f; kind = C_FACE; } }
        if ([self groupLive:G_DPAD]) { CGFloat d = dist(p, self.dpadCenter) / (self.dpadR * K_DPAD_GRAB); if (d < best) { best = d; kind = C_DPAD; } }
        if (!_stick[0] && [self groupLive:G_STICK]) { CGFloat s = dist(p, self.stickHome) / ([self stickR:0] * K_STICK_GRAB); if (s < best) { best = s; kind = C_STICK; } }
        if (kind == C_STICK) _lCentre = _floatStick ? p : self.stickHome;   // a floating stick centres where the finger lands
        if (kind == C_NONE && _floatStick && !_stick[0] && [self groupLive:G_STICK] && [self inLeftHalf:p]) { kind = C_STICK; _lCentre = p; }
        if (kind == C_NONE && _full && !_stick[1] && [self inRightArea:p]) { kind = C_STICK; idx = 1; _rCentre = p; }   // the right stick: centred where the touch lands
        if (kind == C_FACE) { [_owner setObject:@(C_FACE) forKey:t]; [_faceOf setObject:@([self faceAt:p]) forKey:t]; }
        else if (kind == C_DPAD) [_owner setObject:@(C_DPAD) forKey:t];
        else if (kind == C_STICK) { [_owner setObject:@(C_STICK | (uint64_t)idx << 8) forKey:t]; _stick[idx] = t; _stickNow[idx] = p; }
        else game |= [self gameBegin:t];
    }
    if (game) [self pushGame];
    [self recompute];
}
- (void)touchesMoved:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    BOOL game = NO;
    if (_editing) { [self editMoved]; return; }
    for (UITouch *t in ts) {
        uint64_t v = [_owner objectForKey:t].unsignedLongLongValue; int c = (int)(v & 0xff); CGPoint p = [t locationInView:self];
        if (t == _edgeTouch && p.y - _edgeStart.y >= K_EDGE_PULL) { _edgeTouch = nil; [self peekChrome]; }
        if (c == C_FACE) [_faceOf setObject:@([self faceAt:p]) forKey:t];
        else if (c == C_STICK) { _stickNow[v >> 8] = p;
            // the right stick's centre (and a floating left stick's) follows a finger past its radius, so turning back responds at once
            if ((v >> 8) == 1) { CGFloat d = dist(p, _rCentre), R = [self stickR:1];
                if (d > R) _rCentre = CGPointMake(p.x - (p.x - _rCentre.x) * R / d, p.y - (p.y - _rCentre.y) * R / d); }
            else if (_floatStick) { CGFloat d = dist(p, _lCentre), R = [self stickR:0];
                if (d > R) _lCentre = CGPointMake(p.x - (p.x - _lCentre.x) * R / d, p.y - (p.y - _lCentre.y) * R / d); } }
        else if (c == C_GAME) game = YES;
    }
    if (game) [self pushGame];
    [self recompute];
}
- (void)endTouches:(NSSet<UITouch *> *)ts tapped:(BOOL)ended {
    BOOL swap = NO, game = NO;
    if (_editing) { [self editEnded:ts]; return; }
    for (UITouch *t in ts) {
        if (t == _edgeTouch) _edgeTouch = nil;
        uint64_t v = [_owner objectForKey:t].unsignedLongLongValue;
        if ((v & 0xff) == C_SWAP) { [_swapTimer invalidate]; _swapTimer = nil; if (_tap) [self peekChrome]; }
        if (ended && (v & 0xff) == C_SWAP && [self inSwap:[t locationInView:self]]) swap = YES;   // layout button: counts only when released on the button
        if ((v & 0xff) == C_GAME && (v >> 8) < 16) { _game[v >> 8] = nil; game = YES; }
        [_owner removeObjectForKey:t]; [_faceOf removeObjectForKey:t]; for (int i = 0; i < 2; i++) if (t == _stick[i]) _stick[i] = nil;
    }
    if (game) [self pushGame];
    [self recompute];
    if (swap) [self nextLayout];
}
- (void)touchesEnded:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self endTouches:ts tapped:YES]; if (_external) [self peek]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self endTouches:ts tapped:NO]; }
- (void)reset { [_swapTimer invalidate]; _swapTimer = nil; _edgeTouch = nil; [_owner removeAllObjects]; [_faceOf removeAllObjects]; _stick[0] = _stick[1] = nil; for (int i = 0; i < 16; i++) _game[i] = nil; [self pushGame]; [self recompute]; }

// ---- Shapes ----
static CGPathRef circlePath(CGPoint c, CGFloat r) { return CGPathCreateWithEllipseInRect(CGRectMake(c.x - r, c.y - r, 2 * r, 2 * r), NULL); }
static CGPathRef dropPath(CGPoint c, CGFloat r, CGFloat tipAngle, CGFloat round) {   // teardrop: circle + two tangents meeting at the tip, tip slightly rounded
    CGFloat d = r * K_DROP_TIP, th = acos(r / d);
    CGPoint tip = CGPointMake(c.x + d * cos(tipAngle), c.y + d * sin(tipAngle));
    CGPoint p1 = CGPointMake(c.x + r * cos(tipAngle + th), c.y + r * sin(tipAngle + th)), p2 = CGPointMake(c.x + r * cos(tipAngle - th), c.y + r * sin(tipAngle - th));
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, p2.x, p2.y);
    CGPathAddArcToPoint(p, NULL, tip.x, tip.y, p1.x, p1.y, round);
    CGPathAddArc(p, NULL, c.x, c.y, r, tipAngle + th, tipAngle - th + 2 * M_PI, false);
    CGPathCloseSubpath(p); return p;
}
static CGPathRef armPath(CGPoint c, CGFloat R, CGFloat w, CGFloat in, CGFloat angle, CGFloat round) {   // one D-pad arm: an upward pentagon (tip toward the centre) rotated by angle around the centre
    CGPoint v[5] = {{-w, -R}, {w, -R}, {w, -(in + w)}, {0, -in}, {-w, -(in + w)}};
    CGFloat cs = cos(angle), sn = sin(angle);
    for (int i = 0; i < 5; i++) v[i] = CGPointMake(c.x + v[i].x * cs - v[i].y * sn, c.y + v[i].x * sn + v[i].y * cs);
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, (v[4].x + v[0].x) / 2, (v[4].y + v[0].y) / 2);
    for (int i = 0; i < 5; i++) CGPathAddArcToPoint(p, NULL, v[i].x, v[i].y, v[(i + 1) % 5].x, v[(i + 1) % 5].y, round);
    CGPathCloseSubpath(p); return p;
}
static void setPath(CAShapeLayer *l, CGPathRef p) { l.path = p; l.shadowPath = p; CGPathRelease(p); }
static void placeLabel(CATextLayer *t, CGPoint c, CGFloat fs) {
    CTFontRef f = CTFontCreateUIFontForLanguage(kCTFontUIFontEmphasizedSystem, fs, NULL);
    t.font = f; t.fontSize = fs;
    CGFloat h = CTFontGetAscent(f) + CTFontGetDescent(f) + CTFontGetLeading(f), w = fs * 3;
    t.frame = CGRectMake(c.x - w / 2, c.y - h / 2, w, h);
    CFRelease(f);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (self.window.windowScene) atomic_store(&g_screen_orientation, (int)self.window.windowScene.interfaceOrientation);   // the motion's axes (motion_start)
    CGFloat u = self.u;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    _controls.frame = self.layer.bounds;
    for (int b = B_A; b <= B_Y; b++) { CGPoint c = [self facePos:b]; setPath(_key[b], circlePath(c, self.faceR)); placeLabel(_label[b], c, 20 * u * _adj[G_FACE].s); }
    for (int i = 0; i < (int)(sizeof k_btns / sizeof *k_btns); i++) { int b = k_btns[i]; CGFloat gs = _adj[groupOf(b)].s;
        if (isDrop(b)) {
            BOOL right = b == B_ZR || b == B_R; CGPoint c = [self dropCenter:b];
            setPath(_key[b], dropPath(c, [self dropR:b], right ? -M_PI_4 : -3 * M_PI_4, 4 * u)); placeLabel(_label[b], c, 16 * u * gs);   // tip toward the near top corner
        } else if (isClick(b)) {
            CGPoint c = [self clickCenter:b]; setPath(_key[b], circlePath(c, [self clickR:b])); placeLabel(_label[b], c, 13 * u * gs);
        } else {
            CGRect rc = [self pillRect:b];
            setPath(_key[b], CGPathCreateWithRoundedRect(rc, rc.size.height / 2, rc.size.height / 2, NULL)); placeLabel(_label[b], CGPointMake(CGRectGetMidX(rc), CGRectGetMidY(rc)), 18 * u * gs);
        }
    }
    static const struct { int b; CGFloat angle; } arms[] = {{B_UP, 0}, {B_RIGHT, M_PI_2}, {B_DOWN, M_PI}, {B_LEFT, -M_PI_2}};   // the same arm in 90° steps
    for (int i = 0; i < 4; i++) setPath(_key[arms[i].b], armPath(self.dpadCenter, self.dpadR, K_ARM_W * u * _adj[G_DPAD].s, K_ARM_IN * u * _adj[G_DPAD].s, arms[i].angle, 6 * u));
    CGPoint sc = self.swapCenter; setPath(_swap, circlePath(sc, K_SWAP_R * u)); placeLabel(_swapLabel, sc, 12 * u);
    _qr.hidden = _qrLabel.hidden = !getenv("DM_PHONE_PADS_LIVE");   // only while the phone server runs
    CGPoint qc = self.qrCenter; setPath(_qr, circlePath(qc, K_SWAP_R * u)); placeLabel(_qrLabel, qc, 10 * u);
    CGFloat R = [self stickR:0]; _ring.bounds = CGRectMake(0, 0, 2 * R, 2 * R); setPath(_ring, circlePath(CGPointMake(R, R), R));   // placed by refresh (a floating stick moves)
    CGFloat k = K_KNOB_R * u * _adj[G_STICK].s; _knob.bounds = CGRectMake(0, 0, 2 * k, 2 * k);
    setPath(_knob, circlePath(CGPointMake(k, k), k));
    CAShapeLayer *in = (CAShapeLayer *)_knob.sublayers.firstObject; CGPathRef ip = circlePath(CGPointMake(k, k), k * 0.62);
    in.frame = _knob.bounds; in.path = ip; CGPathRelease(ip);
    if (_editing && _sel >= 0) setPath(_selRing, circlePath([self groupAnchor:_sel], [self groupExtent:_sel] + 6 * u));
    [CATransaction commit];
    if (_editPanel) [self clampPanel];
    [self refresh];
}
- (void)safeAreaInsetsDidChange { [super safeAreaInsetsDidChange]; [self setNeedsLayout]; }
- (void)refresh {   // pressed state → fill, sticks → knob position
    uint64_t all = _faceBits | _dpadBits | _btnBits;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (int b = 0; b < B_N; b++) { BOOL on = (all >> b) & 1;
        _key[b].fillColor = (on ? k_on : k_idle).CGColor; _label[b].foregroundColor = (on ? k_textOn : k_text).CGColor; }
    _swap.fillColor = (_swapHeld ? k_on : k_idle).CGColor; _swapLabel.foregroundColor = (_swapHeld ? k_textOn : k_text).CGColor;
    CGPoint h = [self stickCentre:0], o = [self knobOffset:0];
    _ring.position = h;
    _knob.position = CGPointMake(h.x + o.x, h.y + o.y); _knob.fillColor = (_stick[0] ? k_on : k_idle).CGColor;
    [CATransaction commit];
}

// ---- The editor: move, resize and hide groups of controls, pick the left stick's mode and an opacity ----
- (void)swapHoldStart {   // holding the layout button (2D / 3D) opens the editor; a short tap still goes to the next layout
    [_swapTimer invalidate]; _swapTimer = nil;
    if (_tap) return;
    __weak DmGamepad *weakSelf = self;
    _swapTimer = [NSTimer scheduledTimerWithTimeInterval:0.6 repeats:NO block:^(NSTimer *t) { [weakSelf enterEdit]; }];
}
static NSString *groupName(int g, BOOL zh) {
    static NSString *const zhn[G_N] = {@"左搖桿", @"ABXY 鍵", @"十字鍵", @"ZL / L", @"ZR / R", @"− / +", @"L3", @"R3"};
    static NSString *const en[G_N] = {@"Left stick", @"A B X Y", @"D-pad", @"ZL / L", @"ZR / R", @"− / +", @"L3", @"R3"};
    return g < 0 ? (zh ? @"點一組按鍵來選取" : @"Tap a group to select it") : (zh ? zhn : en)[g];
}
- (void)enterEdit {
    _swapTimer = nil;
    if (_editing || _tap || _padOff) return;
    [self reset];   // the held layout button lets go without switching the layout; no key stays held for the game
    [_touchFeedback impactOccurredWithIntensity:1]; [_touchFeedback prepare];
    _editing = YES; _sel = -1;
    [self applyLayout]; [self buildPanel]; [self setNeedsLayout];
    LOG("front end: touch controls editor opened (%s)", _full ? "3D" : "2D");
}
- (void)exitEdit {
    if (!_editing) return;
    _editing = NO; _sel = -1;
    [_editGroup removeAllObjects]; [_editPrev removeAllObjects];
    [_editPanel removeFromSuperview]; _editPanel = nil; _panelX = _panelY = nil;
    [self saveAdj]; [self applyLayout]; [self setNeedsLayout];
}
- (int)groupAt:(CGPoint)p {
    int best = -1; CGFloat bd = 1.15;
    for (int g = 0; g < G_N; g++) { if (![self groupShown:g]) continue;
        CGFloat d = dist(p, [self groupAnchor:g]) / [self groupExtent:g]; if (d < bd) { bd = d; best = g; } }
    return best;
}
- (void)editBegan:(NSSet<UITouch *> *)ts {
    for (UITouch *t in ts) {
        CGPoint p = [t locationInView:self]; int g = -1;
        for (UITouch *o in _editGroup) if (dist([o locationInView:self], p) < [self groupExtent:[_editGroup objectForKey:o].intValue] * 2.5) { g = [_editGroup objectForKey:o].intValue; break; }   // a second finger near a held group pinches it
        if (g < 0) g = [self groupAt:p];
        if (g < 0) continue;
        [_editGroup setObject:@(g) forKey:t]; [_editPrev setObject:[NSValue valueWithCGPoint:p] forKey:t];
        _sel = g;
    }
    _selRing.hidden = _sel < 0;
    [self updatePanel]; [self setNeedsLayout];
}
- (void)editMoved {
    CGFloat u = self.u; BOOL changed = NO;
    for (int g = 0; g < G_N; g++) {
        UITouch *t2[2] = {nil, nil}; int n = 0;
        for (UITouch *t in _editGroup) if ([_editGroup objectForKey:t].intValue == g && n < 2) t2[n++] = t;
        if (!n) continue;
        CGPoint a0 = [_editPrev objectForKey:t2[0]].CGPointValue, a1 = [t2[0] locationInView:self];
        if (n == 1) { _adj[g].dx += (a1.x - a0.x) / u; _adj[g].dy += (a1.y - a0.y) / u; }
        else {   // pinch: scale by the change of the fingers' distance, move by their midpoint
            CGPoint b0 = [_editPrev objectForKey:t2[1]].CGPointValue, b1 = [t2[1] locationInView:self];
            CGFloat d0 = dist(a0, b0), d1 = dist(a1, b1);
            if (d0 > 10) _adj[g].s = fmin(K_SCALE_MAX, fmax(K_SCALE_MIN, _adj[g].s * d1 / d0));
            _adj[g].dx += ((a1.x + b1.x) - (a0.x + b0.x)) / 2 / u; _adj[g].dy += ((a1.y + b1.y) - (a0.y + b0.y)) / 2 / u;
        }
        CGPoint c = [self groupAnchor:g]; CGRect in = CGRectInset(self.bounds, 12, 12);   // the anchor stays on screen
        _adj[g].dx += (fmin(fmax(c.x, CGRectGetMinX(in)), CGRectGetMaxX(in)) - c.x) / u;
        _adj[g].dy += (fmin(fmax(c.y, CGRectGetMinY(in)), CGRectGetMaxY(in)) - c.y) / u;
        changed = YES;
    }
    for (UITouch *t in _editGroup) [_editPrev setObject:[NSValue valueWithCGPoint:[t locationInView:self]] forKey:t];
    if (changed) { [self updatePanel]; [self setNeedsLayout]; }
}
- (void)editEnded:(NSSet<UITouch *> *)ts {
    for (UITouch *t in ts) { [_editGroup removeObjectForKey:t]; [_editPrev removeObjectForKey:t]; }
}
static UIStackView *row(NSArray<UIView *> *v) { UIStackView *s = [[UIStackView alloc] initWithArrangedSubviews:v]; s.axis = UILayoutConstraintAxisHorizontal; s.spacing = 10; s.alignment = UIStackViewAlignmentCenter; return s; }
static UILabel *text(NSString *s, CGFloat size, CGFloat alpha) { UILabel *l = [UILabel new]; l.text = s; l.font = [UIFont systemFontOfSize:size weight:UIFontWeightMedium]; l.textColor = [UIColor colorWithWhite:1 alpha:alpha]; l.numberOfLines = 0; return l; }
static UIButton *button(NSString *s, BOOL main, id target, SEL action) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem]; [b setTitle:s forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:16 weight:main ? UIFontWeightBold : UIFontWeightMedium];
    [b setTitleColor:main ? UIColor.blackColor : UIColor.whiteColor forState:UIControlStateNormal];
    b.backgroundColor = main ? [UIColor colorWithRed:0.35 green:0.75 blue:1 alpha:1] : [UIColor colorWithWhite:1 alpha:0.15];
    b.layer.cornerRadius = 10; [b.heightAnchor constraintEqualToConstant:38].active = YES;
    [b addTarget:target action:action forControlEvents:UIControlEventTouchUpInside]; return b;
}
- (void)buildPanel {   // a card in the middle of the screen (where the controls are not); it can be dragged away
    BOOL zh = shell_zh_hant();
    UIView *p = [UIView new]; p.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.92]; p.layer.cornerRadius = 18;
    UILabel *title = text(zh ? @"調整虛擬搖桿" : @"Edit touch controls", 18, 1); title.font = [UIFont boldSystemFontOfSize:18];
    UILabel *hint = text(zh ? @"拖曳按鍵移動，雙指捏合縮放；這張卡也能拖開" : @"Drag a group to move it, pinch to resize; this card can be dragged too", 13, 0.6);
    _stickSeg = [[UISegmentedControl alloc] initWithItems:zh ? @[@"固定搖桿", @"浮動搖桿"] : @[@"Fixed stick", @"Floating stick"]];
    _stickSeg.selectedSegmentIndex = _floatStick ? 1 : 0; [_stickSeg addTarget:self action:@selector(stickModeChanged) forControlEvents:UIControlEventValueChanged];
    UILabel *stickNote = text(zh ? @"浮動：左半邊畫面哪裡按下，搖桿就從哪裡開始" : @"Floating: the stick starts wherever a finger lands in the left half", 12, 0.5);
    _alphaSlider = [UISlider new]; _alphaSlider.minimumValue = 0.1; _alphaSlider.maximumValue = 1; _alphaSlider.value = _alpha;
    [_alphaSlider addTarget:self action:@selector(alphaChanged) forControlEvents:UIControlEventValueChanged];
    _selName = text(@"", 15, 0.9); _selName.font = [UIFont boldSystemFontOfSize:15];
    _sizeSlider = [UISlider new]; _sizeSlider.minimumValue = K_SCALE_MIN; _sizeSlider.maximumValue = K_SCALE_MAX;
    [_sizeSlider addTarget:self action:@selector(sizeChanged) forControlEvents:UIControlEventValueChanged];
    _hideSwitch = [UISwitch new]; [_hideSwitch addTarget:self action:@selector(hideChanged) forControlEvents:UIControlEventValueChanged];
    UILabel *alphaL = text(zh ? @"透明度" : @"Opacity", 14, 0.8), *sizeL = text(zh ? @"大小" : @"Size", 14, 0.8), *hideL = text(zh ? @"隱藏" : @"Hide", 14, 0.8);
    for (UILabel *l in @[alphaL, sizeL]) [l.widthAnchor constraintEqualToConstant:52].active = YES;
    UIStackView *buttons = row(@[button(zh ? @"重設這個版面" : @"Reset layout", NO, self, @selector(resetAdj)), button(zh ? @"完成" : @"Done", YES, self, @selector(exitEdit))]);
    buttons.distribution = UIStackViewDistributionFillEqually; buttons.alignment = UIStackViewAlignmentFill;
    UIStackView *st = [[UIStackView alloc] initWithArrangedSubviews:@[title, hint, _stickSeg, stickNote, row(@[alphaL, _alphaSlider]), _selName, row(@[sizeL, _sizeSlider, hideL, _hideSwitch]), buttons]];
    st.axis = UILayoutConstraintAxisVertical; st.spacing = 10; st.alignment = UIStackViewAlignmentFill; st.translatesAutoresizingMaskIntoConstraints = NO;
    [st setCustomSpacing:4 afterView:title]; [st setCustomSpacing:4 afterView:_stickSeg]; [st setCustomSpacing:16 afterView:stickNote];
    [p addSubview:st];
    const CGFloat W = MIN(340, self.bounds.size.width - 32), pad = 18;
    [NSLayoutConstraint activateConstraints:@[[st.topAnchor constraintEqualToAnchor:p.topAnchor constant:pad], [st.leadingAnchor constraintEqualToAnchor:p.leadingAnchor constant:pad],
        [st.trailingAnchor constraintEqualToAnchor:p.trailingAnchor constant:-pad], [st.bottomAnchor constraintEqualToAnchor:p.bottomAnchor constant:-pad]]];
    // Auto Layout sizes the card from its contents when it is laid out (a height measured beforehand came out short and cut the buttons off); dragging moves its centre
    [p addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragPanel:)]];
    p.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:p]; _editPanel = p;
    _panelX = [p.centerXAnchor constraintEqualToAnchor:self.centerXAnchor]; _panelY = [p.centerYAnchor constraintEqualToAnchor:self.centerYAnchor];
    [NSLayoutConstraint activateConstraints:@[[p.widthAnchor constraintEqualToConstant:W], _panelX, _panelY]];
    [self updatePanel];
}
- (void)dragPanel:(UIPanGestureRecognizer *)g {
    CGPoint d = [g translationInView:self]; _panelX.constant += d.x; _panelY.constant += d.y;
    [g setTranslation:CGPointZero inView:self]; [self clampPanel];
}
- (void)clampPanel {   // keep the card on screen: its centre moves at most half the free room either way
    CGSize c = [_editPanel systemLayoutSizeFittingSize:UILayoutFittingCompressedSize], b = self.bounds.size;
    CGFloat mx = fmax(0, (b.width - c.width) / 2), my = fmax(0, (b.height - c.height) / 2);
    _panelX.constant = fmin(fmax(_panelX.constant, -mx), mx); _panelY.constant = fmin(fmax(_panelY.constant, -my), my); }
- (void)updatePanel {
    if (!_editPanel) return;
    _selName.text = groupName(_sel, shell_zh_hant());
    _sizeSlider.enabled = _hideSwitch.enabled = _sel >= 0;
    if (_sel >= 0) { _sizeSlider.value = _adj[_sel].s; _hideSwitch.on = _adj[_sel].hide; }
}
- (void)stickModeChanged { _floatStick = _stickSeg.selectedSegmentIndex == 1; [self saveAdj]; }
- (void)alphaChanged { _alpha = _alphaSlider.value; [CATransaction begin]; [CATransaction setDisableActions:YES]; _controls.opacity = g_touch_opacity * _alpha; [CATransaction commit]; }
- (void)sizeChanged { if (_sel < 0) return; _adj[_sel].s = _sizeSlider.value; [self setNeedsLayout]; }
- (void)hideChanged { if (_sel < 0) return; _adj[_sel].hide = _hideSwitch.on; [self applyLayout]; }
- (void)resetAdj { for (int g = 0; g < G_N; g++) _adj[g] = (pad_adj){0, 0, 1, NO}; [self applyLayout]; [self updatePanel]; [self setNeedsLayout]; }

// ---- The launcher's touch-control style and the phone QR code card ----
- (void)applyStyle { if (!_padOff) _controls.opacity = g_touch_opacity * _alpha; [self setNeedsLayout]; }
int phone_pads_url(char *out, size_t cap);
- (void)showQR {   // a card over the game with the phone gamepads' QR code and address; a tap anywhere closes it
    if (_qrOverlay) return;
    char url[96]; if (!phone_pads_url(url, sizeof url)) return;
    NSString *u = [NSString stringWithUTF8String:url];
    CIFilter *f = [CIFilter filterWithName:@"CIQRCodeGenerator"]; [f setValue:[u dataUsingEncoding:NSUTF8StringEncoding] forKey:@"inputMessage"]; [f setValue:@"M" forKey:@"inputCorrectionLevel"];
    CIImage *ci = f.outputImage; CGImageRef cg = ci ? [[CIContext context] createCGImage:ci fromRect:ci.extent] : NULL;
    if (!cg) return;
    BOOL zh = shell_zh_hant();
    UIView *o = [[UIView alloc] initWithFrame:self.bounds]; o.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    o.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
    UIView *card = [UIView new]; card.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.96]; card.layer.cornerRadius = 20; card.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageView *img = [[UIImageView alloc] initWithImage:[UIImage imageWithCGImage:cg]]; CGImageRelease(cg);
    img.layer.magnificationFilter = kCAFilterNearest; img.backgroundColor = UIColor.whiteColor; img.contentMode = UIViewContentModeScaleAspectFit; img.translatesAutoresizingMaskIntoConstraints = NO;
    img.layer.cornerRadius = 8; img.layer.borderColor = UIColor.whiteColor.CGColor; img.layer.borderWidth = 8; img.clipsToBounds = YES;
    UILabel *title = [UILabel new]; title.text = zh ? @"用手機掃描加入遊戲" : @"Scan with a phone to join"; title.font = [UIFont boldSystemFontOfSize:20]; title.textColor = UIColor.whiteColor;
    UILabel *addr = [UILabel new]; addr.text = u; addr.font = [UIFont monospacedSystemFontOfSize:16 weight:UIFontWeightRegular]; addr.textColor = [UIColor colorWithWhite:1 alpha:0.85];
    UILabel *hint = [UILabel new]; hint.text = zh ? @"點一下任意處關閉" : @"Tap anywhere to close"; hint.font = [UIFont systemFontOfSize:13]; hint.textColor = [UIColor colorWithWhite:1 alpha:0.55];
    UIStackView *st = [[UIStackView alloc] initWithArrangedSubviews:@[title, img, addr, hint]]; st.axis = UILayoutConstraintAxisVertical; st.alignment = UIStackViewAlignmentCenter; st.spacing = 12;
    st.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:st]; [o addSubview:card];
    CGFloat side = MIN(220, self.bounds.size.height * 0.45);
    [NSLayoutConstraint activateConstraints:@[
        [img.widthAnchor constraintEqualToConstant:side], [img.heightAnchor constraintEqualToConstant:side],
        [st.topAnchor constraintEqualToAnchor:card.topAnchor constant:20], [st.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-16],
        [st.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:28], [st.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-28],
        [card.centerXAnchor constraintEqualToAnchor:o.centerXAnchor], [card.centerYAnchor constraintEqualToAnchor:o.centerYAnchor]]];
    [o addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(hideQR)]];
    o.alpha = 0; [self addSubview:o]; _qrOverlay = o;
    [UIView animateWithDuration:0.2 animations:^{ o.alpha = 1; }];
    LOG("front end: phone QR code shown (%s)", url);
}
- (void)hideQR {
    UIView *o = _qrOverlay; _qrOverlay = nil;
    [UIView animateWithDuration:0.2 animations:^{ o.alpha = 0; } completion:^(BOOL done) { (void)done; [o removeFromSuperview]; }];
}

// ---- Physical controllers and phones ----
// Each controller is a player of its own, from app launch: shell_players.m reads them and takes their players from the shared slot table (shell_slots.h), as phone_pads.c
// does for the phones. Here they only hide the touch gamepad while one plays: a tap on the screen shows it again for PEEK_SECONDS after the last touch (the iPad may
// still be played by touch), then it fades out.
enum { PEEK_SECONDS = 5 };
int shell_players_external(void);
void shell_players_release(void);
- (void)showControls:(BOOL)on {
    if (on == !_padOff) return;
    _padOff = !on;
    [CATransaction begin]; [CATransaction setAnimationDuration:on ? 0.15 : 0.4];
    _controls.opacity = on ? g_touch_opacity * _alpha : 0;
    [CATransaction commit];
    if (!on) [self reset];
}
- (void)peek {
    [self showControls:YES];
    [_peekTimer invalidate];
    __weak DmGamepad *weakSelf = self;
    _peekTimer = [NSTimer scheduledTimerWithTimeInterval:PEEK_SECONDS repeats:NO block:^(NSTimer *t) { [weakSelf peekEnd]; }];
}
- (void)peekEnd {
    if (!_external) return;
    if (_owner.count) { [self peek]; return; }   // still held: wait for its release
    [self showControls:NO];
}
- (void)padsChanged {
    BOOL any = shell_players_external() > 0;
    if (any == _external) return;
    _external = any;
    if (any) [self exitEdit];   // a controller took over: close the editor (its changes are kept)
    [_peekTimer invalidate]; _peekTimer = nil;
    [self showControls:!any];
}
@end

void dm_touch_style(float opacity, float scale) {   // the launcher's touch-control opacity and size (Launcher.swift, main thread)
    g_touch_opacity = fminf(1, fmaxf(0.2f, opacity)); g_touch_scale = fminf(1.3f, fmaxf(0.7f, scale));
    [g_view applyStyle];
}
UIView *dm_gamepad_view(CGRect frame) { DmGamepad *v = [[DmGamepad alloc] initWithFrame:frame]; g_view = v; return v; }
void dm_gamepad_reset(void) {   // On resign active: release everything (a key held while switching away and released in background gets no "release")
    dispatch_async(dispatch_get_main_queue(), ^{ [g_view reset]; });
    pthread_mutex_lock(&g_mu); g_pad_btn = 0; g_shake_btn = 0; g_pad_lx = g_pad_ly = g_pad_rx = g_pad_ry = 0; pthread_mutex_unlock(&g_mu); publish();
    dispatch_async(dispatch_get_main_queue(), ^{ shell_players_release(); });   // each controller's player too
}

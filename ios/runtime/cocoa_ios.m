// UIKit side of the window system, replacing cocoa.m on iOS (same cocoa.h interface).
//
// The guest runs on its own thread (boot_ios.m); UIKit owns the main thread. A guest top-level window becomes a
// UIView backed by a CAMetalLayer (the Vulkan surface) inside one full-screen root view controller, letterboxed to
// the window's aspect ratio. UIKit input becomes Win32 messages:
//   touch            -> left mouse button + pointer motion
//   hardware keyboard / mouse (GameController) -> keys, buttons, relative motion
// win_from_cocoa() and friends only take window.c's queue lock, so they may be called from UIKit's thread.
#import <UIKit/UIKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <GameController/GameController.h>
#import <CoreMotion/CoreMotion.h>
#include <stdatomic.h>
#include <pthread.h>
#include "cocoa.h"
void rt_log(const char *fmt, ...);

enum {
    WM_MOVE = 3, WM_SIZE = 5, WM_ACTIVATE = 6, WM_SETFOCUS = 7, WM_KILLFOCUS = 8, WM_CLOSE = 0x10, WM_ACTIVATEAPP = 0x1C,
    WM_MOUSEMOVE = 0x200, WM_LBUTTONDOWN, WM_LBUTTONUP, WM_LBUTTONDBLCLK, WM_RBUTTONDOWN, WM_RBUTTONUP, WM_RBUTTONDBLCLK,
    WM_MBUTTONDOWN, WM_MBUTTONUP, WM_MBUTTONDBLCLK, WM_MOUSEWHEEL,
};
enum { VK_LBUTTON = 1, VK_RBUTTON = 2, VK_MBUTTON = 4 };

static int g_active;
static _Atomic int g_dx, g_dy;                 // raw motion since the last cocoa_mouse_delta
static _Atomic int g_cx, g_cy;                 // virtual cursor, guest pixels
static _Atomic int g_buttons;                  // MK_* mask (1 left, 2 right, 0x10 middle)
static _Atomic uint64_t g_key_hwnd;            // window that receives keyboard and mouse input
static _Atomic int g_pointer_locked;
static int g_scr_w = 1920, g_scr_h = 1080, g_scr_hz = 60;   // landscape native pixels
static UIViewController *g_root;
static UIView *g_controls;
static int g_vw, g_vh;                          // emulated display mode (0 = native)
static double g_sens = 1.0;                     // look sensitivity multiplier (SENS button), touch and gyro
static _Atomic int g_iface_orient;               // UIInterfaceOrientation, kept current from the main thread
static _Atomic int g_gyro_on;                   // gyro aiming (GYRO button)
static const double kSensSteps[] = { 0.5, 0.75, 1.0, 1.5, 2.0, 3.0 };

static void on_main(dispatch_block_t b) { if ([NSThread isMainThread]) b(); else dispatch_sync(dispatch_get_main_queue(), b); }
int cocoa_is_main_thread(void) { return [NSThread isMainThread]; }
int cocoa_active(void) { return g_active; }

// Screen facts (main thread, before the guest starts) for display_ios.c.
void cocoa_ios_screen_init(void) {
    UIScreen *s = UIScreen.mainScreen;
    CGSize n = s.nativeBounds.size;
    g_scr_w = (int)fmax(n.width, n.height); g_scr_h = (int)fmin(n.width, n.height);
    g_scr_hz = (int)s.maximumFramesPerSecond;
    if (g_scr_hz < 30) g_scr_hz = 60;
}
void cocoa_ios_screen(int *w, int *h, int *hz) { *w = g_scr_w; *h = g_scr_h; *hz = g_scr_hz; }
double cocoa_refresh_hz(void) { return g_scr_hz; }

// ---------------- views ----------------
@class RTView;
static NSMutableArray<RTView *> *g_views;

@interface RTView : UIView
@property uint64_t hwnd;
@property double pxPerPt;                      // guest pixels per point
@property int gx, gy, gw, gh;                  // guest client rect
@property CGPoint last;
@property double downAt;
@property CGPoint start;
@property BOOL moved;
@property(weak) UITouch *tracking;
@end

static uint64_t mk_flags(void) { return (uint64_t)atomic_load(&g_buttons); }
static uint64_t pack_pos(int x, int y) { return (uint64_t)(uint16_t)x | (uint64_t)(uint16_t)y << 16; }
static int clampi(int v, int lo, int hi) { return v < lo ? lo : v > hi ? hi : v; }

static void mouse_button(uint64_t hwnd, int which, int down) {   // which: 1 left, 2 right, 4 middle
    int mk = which == 1 ? 1 : which == 2 ? 2 : 0x10;
    if (down) atomic_fetch_or(&g_buttons, mk); else atomic_fetch_and(&g_buttons, ~mk);
    uint32_t msg = which == 1 ? (down ? WM_LBUTTONDOWN : WM_LBUTTONUP) : which == 2 ? (down ? WM_RBUTTONDOWN : WM_RBUTTONUP) : (down ? WM_MBUTTONDOWN : WM_MBUTTONUP);
    extern void win_set_key(int vk, int down);
    win_set_key(which == 1 ? VK_LBUTTON : which == 2 ? VK_RBUTTON : VK_MBUTTON, down);
    di_mouse_button(which == 1 ? 0 : which == 2 ? 1 : 2, down);
    win_from_cocoa(hwnd, msg, mk_flags(), pack_pos(atomic_load(&g_cx), atomic_load(&g_cy)));
}
static void mouse_motion(uint64_t hwnd, int dx, int dy, int x, int y) {
    atomic_store(&g_cx, x); atomic_store(&g_cy, y);
    atomic_fetch_add(&g_dx, dx); atomic_fetch_add(&g_dy, dy);
    di_mouse_move(dx, dy);
    win_from_cocoa(hwnd, WM_MOUSEMOVE, mk_flags(), pack_pos(x, y));
}

@implementation RTView
+ (Class)layerClass { return [CAMetalLayer class]; }
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) { self.multipleTouchEnabled = NO; self.backgroundColor = UIColor.blackColor; self.opaque = YES; }
    return self;
}
- (void)point:(UITouch *)t x:(int *)x y:(int *)y {
    CGPoint p = [t locationInView:self];
    *x = clampi((int)lround(p.x * self.pxPerPt), 0, self.gw - 1); *y = clampi((int)lround(p.y * self.pxPerPt), 0, self.gh - 1);
}
// Trackpad style: dragging moves the cursor by relative motion, a short tap without movement is a left click at the cursor.
- (void)touchesBegan:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    if (self.tracking) return;
    UITouch *t = ts.anyObject; self.tracking = t; self.last = self.start = [t locationInView:self];
    self.downAt = CACurrentMediaTime(); self.moved = NO;
}
- (void)touchesMoved:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    UITouch *t = self.tracking; if (!t || ![ts containsObject:t]) return;
    CGPoint p = [t locationInView:self];
    if (hypot(p.x - self.start.x, p.y - self.start.y) > (atomic_load(&g_pointer_locked) ? 0 : 8)) self.moved = YES;
    if (!self.moved) return;
    double sens = atomic_load(&g_pointer_locked) ? 1.6 * g_sens : 1.0;   // look speed in gameplay
    int dx = (int)lround((p.x - self.last.x) * self.pxPerPt * sens), dy = (int)lround((p.y - self.last.y) * self.pxPerPt * sens);
    self.last = p;
    mouse_motion(self.hwnd, dx, dy, clampi(atomic_load(&g_cx) + dx, 0, self.gw - 1), clampi(atomic_load(&g_cy) + dy, 0, self.gh - 1));
}
- (void)touchesEnded:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    UITouch *t = self.tracking; if (!t || ![ts containsObject:t]) return;
    self.tracking = nil;
    if (atomic_load(&g_pointer_locked)) return;   // gameplay: touches only look around
    if (self.moved || CACurrentMediaTime() - self.downAt > 0.35) return;
    // A tap lands where the finger is: jump the cursor there, give the game a few frames to update the hovered
    // item (menus click the item under the cursor at that moment), then click.
    uint64_t hwnd = self.hwnd;
    int x, y; [self point:t x:&x y:&y];
    mouse_motion(hwnd, x - atomic_load(&g_cx), y - atomic_load(&g_cy), x, y);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        rt_log("[cocoa] tap click at %d,%d\n", atomic_load(&g_cx), atomic_load(&g_cy));
        // The menus' "[ENTER] SELECT" acts on the highlighted item; a mouse click on a checkbox toggled it twice
        // (net nothing), so a tap presses Enter on the item under the cursor instead.
        extern void win_key_from_cocoa(uint64_t hwnd, uint16_t mac_keycode, int down, int repeat, const uint16_t *chars, int nchars);
        uint16_t cr = '\r';
        win_key_from_cocoa(hwnd, 36, 1, 0, &cr, 1);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 90 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ win_key_from_cocoa(hwnd, 36, 0, 0, NULL, 0); });
    });
}
- (void)touchesCancelled:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self touchesEnded:ts withEvent:e]; }
@end

// ---------------- root view controller ----------------
static void relayout_all(void);
static void overlay_front(void);
@interface RTRootViewController : UIViewController @end
@implementation RTRootViewController
- (void)loadView { UIView *v = [UIView new]; v.backgroundColor = UIColor.blackColor; self.view = v; }
- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures { return UIRectEdgeAll; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
- (BOOL)prefersPointerLocked { return atomic_load(&g_pointer_locked); }
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews]; relayout_all(); atomic_store(&g_iface_orient, (int)self.view.window.windowScene.interfaceOrientation); }
@end

UIViewController *cocoa_ios_root(void) {   // main thread
    if (!g_root) g_root = [RTRootViewController new];
    return g_root;
}

// Guest client rect -> the view: fill the screen at the rect's own aspect ratio (letterboxed), drawable = cw x ch.
static void layout_view(RTView *v) {
    CGRect b = g_root.view.bounds;
    if (b.size.width < 1 || b.size.height < 1 || v.gw < 1 || v.gh < 1) return;
    double k = fmin(b.size.width / v.gw, b.size.height / v.gh);   // points per guest pixel
    CGRect f = CGRectMake(floor((b.size.width - v.gw * k) / 2), floor((b.size.height - v.gh * k) / 2), v.gw * k, v.gh * k);
    v.frame = f;
    v.pxPerPt = 1.0 / k;
    v.contentScaleFactor = 1.0 / k;
    ((CAMetalLayer *)v.layer).contentsScale = 1.0 / k;
}
static void relayout_all(void) { for (RTView *v in g_views) layout_view(v); }

// ---------------- windows ----------------
void *cocoa_window_new(uint64_t hwnd, int x, int y, int cw, int ch, int titled, int resizable, int minimizable, const char *title) {
    __block void *res = NULL;
    on_main(^{
        UIViewController *root = cocoa_ios_root();
        (void)root.view;
        RTView *v = [[RTView alloc] initWithFrame:root.view.bounds];
        v.hwnd = hwnd; v.gx = x; v.gy = y; v.gw = cw; v.gh = ch; v.hidden = YES;
        if (!g_views) g_views = [NSMutableArray array];
        [g_views addObject:v];
        [root.view addSubview:v];
        overlay_front();
        layout_view(v);
        g_active = 1;
        res = (__bridge_retained void *)v;
    });
    return res;
}
void cocoa_window_free(void *p) {
    on_main(^{
        RTView *v = (__bridge_transfer RTView *)p;
        [v removeFromSuperview]; [g_views removeObject:v];
        if (atomic_load(&g_key_hwnd) == v.hwnd) atomic_store(&g_key_hwnd, 0);
    });
}
void cocoa_window_show(void *p, int show, int activate) {
    on_main(^{
        RTView *v = (__bridge RTView *)p;
        v.hidden = !show;
        if (show) {
            [g_root.view bringSubviewToFront:v]; overlay_front();
            atomic_store(&g_key_hwnd, v.hwnd);
            win_from_cocoa(v.hwnd, WM_ACTIVATE, 1, 0);
            win_from_cocoa(v.hwnd, WM_SETFOCUS, 0, 0);
        }
    });
}
void cocoa_window_minimize(void *p, int m) { (void)p; (void)m; }
void cocoa_window_zoom(void *p, int z) { (void)p; (void)z; }
void cocoa_window_state(void *p, int *mn, int *zm, int *vis) {
    __block int v = 1;
    on_main(^{ v = !((__bridge RTView *)p).hidden; });
    *mn = 0; *zm = 0; *vis = v;
}
void cocoa_window_set_style(void *p, int titled, int resizable, int minimizable) { (void)p; (void)titled; (void)resizable; (void)minimizable; }
void cocoa_window_set_client(void *p, int x, int y, int cw, int ch) {
    on_main(^{
        RTView *v = (__bridge RTView *)p;
        v.gx = x; v.gy = y; v.gw = cw; v.gh = ch;
        layout_view(v);
        rt_log("[cocoa] layout hwnd %llx guest %d,%d %dx%d -> view %.0fx%.0f pt, scale %.3f\n", (unsigned long long)v.hwnd, x, y, cw, ch,
               v.frame.size.width, v.frame.size.height, v.contentScaleFactor);
        win_from_cocoa(v.hwnd, WM_SIZE, 0, pack_pos(cw, ch));
    });
}
void cocoa_window_get_client(void *p, int *x, int *y, int *cw, int *ch) {
    __block int a, b, c, d;
    on_main(^{ RTView *v = (__bridge RTView *)p; a = v.gx; b = v.gy; c = v.gw; d = v.gh; });
    *x = a; *y = b; *cw = c; *ch = d;
}
void cocoa_window_set_title(void *p, const char *title) { (void)p; (void)title; }
void cocoa_window_activate(void *p) { cocoa_window_show(p, 1, 1); }
void *cocoa_window_layer(void *p) {
    __block void *l = NULL;
    on_main(^{ l = (__bridge void *)((__bridge RTView *)p).layer; });
    return l;
}
void cocoa_frame_insets(int titled, int resizable, int *l, int *t, int *r, int *b) { (void)titled; (void)resizable; *l = *t = *r = *b = 0; }
void cocoa_set_virtual_screen(int w, int h) { g_vw = w; g_vh = h; }   // the view letterboxes any size onto the screen

void cocoa_pump(int wait_ms) {
    if (![NSThread isMainThread]) return;
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, wait_ms > 0 ? wait_ms / 1000.0 : 0, true);
}

// ---------------- cursor ----------------
void cocoa_cursor_pos(int *x, int *y) { *x = atomic_load(&g_cx); *y = atomic_load(&g_cy); }
void cocoa_set_cursor_pos(int x, int y) { atomic_store(&g_cx, x); atomic_store(&g_cy, y); }
void cocoa_cursor_visible(int v) {
    atomic_store(&g_pointer_locked, !v);
    rt_log("[cocoa] mouse capture %s\n", v ? "off" : "on");
    dispatch_async(dispatch_get_main_queue(), ^{ [g_root setNeedsUpdateOfPrefersPointerLocked]; g_controls.hidden = v; });
}
void cocoa_mouse_delta(int *dx, int *dy) { *dx = atomic_exchange(&g_dx, 0); *dy = atomic_exchange(&g_dy, 0); }

// ---------------- dialogs ----------------
char *cocoa_choose_folder(const char *message) { (void)message; return NULL; }   // the game folder is fixed (boot_ios.m)

static UIViewController *top_vc(void) {
    UIViewController *t = g_root;
    while (t.presentedViewController) t = t.presentedViewController;
    return t;
}
// Blocks the calling (guest) thread until dismissed; from the main thread it returns at once.
void cocoa_alert(const char *title, const char *text) {
    NSString *t = [NSString stringWithUTF8String:title ?: ""], *x = [NSString stringWithUTF8String:text ?: ""];
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    BOOL wait = ![NSThread isMainThread];
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *a = [UIAlertController alertControllerWithTitle:t message:x preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) { dispatch_semaphore_signal(sem); }]];
        [top_vc() presentViewController:a animated:YES completion:nil];
    });
    if (wait) dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
}
void cocoa_pick_friends(int n, const char *const *names, const char *const *details,
                        void (*done)(const int *picked, int npicked, void *ctx), void *ctx) {
    (void)n; (void)names; (void)details;
    dispatch_async(dispatch_get_main_queue(), ^{ done(NULL, 0, ctx); });   // no Steam overlay here
}
void cocoa_log_layer(void *p) {
    CAMetalLayer *l = (__bridge CAMetalLayer *)p;
    rt_log("[cocoa] layer bounds %.0fx%.0f pt, contentsScale %.3f, drawableSize %.0fx%.0f\n", l.bounds.size.width, l.bounds.size.height,
           l.contentsScale, l.drawableSize.width, l.drawableSize.height);
}

// ---------------- keyboard ----------------
// HID usage page 7 -> macOS virtual key code (window.c's key table is keyed by those).
static const uint8_t hid_to_mac[232] = {
    [0x04]=0,[0x05]=11,[0x06]=8,[0x07]=2,[0x08]=14,[0x09]=3,[0x0A]=5,[0x0B]=4,[0x0C]=34,[0x0D]=38,[0x0E]=40,[0x0F]=37,[0x10]=46,
    [0x11]=45,[0x12]=31,[0x13]=35,[0x14]=12,[0x15]=15,[0x16]=1,[0x17]=17,[0x18]=32,[0x19]=9,[0x1A]=13,[0x1B]=7,[0x1C]=16,[0x1D]=6,
    [0x1E]=18,[0x1F]=19,[0x20]=20,[0x21]=21,[0x22]=23,[0x23]=22,[0x24]=26,[0x25]=28,[0x26]=25,[0x27]=29,
    [0x28]=36,[0x29]=53,[0x2A]=51,[0x2B]=48,[0x2C]=49,[0x2D]=27,[0x2E]=24,[0x2F]=33,[0x30]=30,[0x31]=42,[0x33]=41,[0x34]=39,[0x35]=50,
    [0x36]=43,[0x37]=47,[0x38]=44,[0x39]=57,
    [0x3A]=122,[0x3B]=120,[0x3C]=99,[0x3D]=118,[0x3E]=96,[0x3F]=97,[0x40]=98,[0x41]=100,[0x42]=101,[0x43]=109,[0x44]=103,[0x45]=111,
    [0x49]=114,[0x4A]=115,[0x4B]=116,[0x4C]=117,[0x4D]=119,[0x4E]=121,[0x4F]=124,[0x50]=123,[0x51]=125,[0x52]=126,
    [0xE0]=59,[0xE1]=56,[0xE2]=58,[0xE3]=55,[0xE4]=62,[0xE5]=60,[0xE6]=61,[0xE7]=54,
};
static char hid_char(int u, int shift) {
    if (u >= 0x04 && u <= 0x1D) return (char)((shift ? 'A' : 'a') + u - 4);
    if (u >= 0x1E && u <= 0x27) return shift ? ")!@#$%^&*("[(u - 0x1E + 1) % 10] : "1234567890"[u - 0x1E];
    switch (u) {
    case 0x28: return '\r'; case 0x29: return 0x1B; case 0x2A: return 0x7F; case 0x2B: return '\t'; case 0x2C: return ' ';
    case 0x2D: return shift ? '_' : '-'; case 0x2E: return shift ? '+' : '='; case 0x2F: return shift ? '{' : '[';
    case 0x30: return shift ? '}' : ']'; case 0x31: return shift ? '|' : '\\'; case 0x33: return shift ? ':' : ';';
    case 0x34: return shift ? '"' : '\''; case 0x35: return shift ? '~' : '`'; case 0x36: return shift ? '<' : ',';
    case 0x37: return shift ? '>' : '.'; case 0x38: return shift ? '?' : '/';
    }
    return 0;
}
static _Atomic int g_shift;
static void key_event(int usage, int down) {
    if (usage < 0 || usage >= 232 || !(hid_to_mac[usage] || usage == 4)) return;
    uint64_t hwnd = atomic_load(&g_key_hwnd);
    if (!hwnd) return;
    if (usage == 0xE1 || usage == 0xE5) atomic_store(&g_shift, down);
    uint16_t ch[1]; int n = 0;
    char c = hid_char(usage, atomic_load(&g_shift));
    if (c && down) ch[n++] = (uint16_t)(unsigned char)c;
    win_key_from_cocoa(hwnd, hid_to_mac[usage], down, 0, ch, n);
}

static void attach_keyboard(GCKeyboard *kb) {
    kb.keyboardInput.keyChangedHandler = ^(GCKeyboardInput *input, GCControllerButtonInput *key, GCKeyCode code, BOOL pressed) { key_event((int)code, pressed); };
}
static void attach_mouse(GCMouse *m) {
    m.mouseInput.mouseMovedHandler = ^(GCMouseInput *mi, float dx, float dy) {
        uint64_t hwnd = atomic_load(&g_key_hwnd);
        int w = 1, h = 1; for (RTView *v in g_views) if (v.hwnd == hwnd) { w = v.gw; h = v.gh; }
        int ix = (int)lround(dx), iy = (int)lround(-dy);   // GameController's y is up
        mouse_motion(hwnd, ix, iy, clampi(atomic_load(&g_cx) + ix, 0, w - 1), clampi(atomic_load(&g_cy) + iy, 0, h - 1));
    };
    m.mouseInput.leftButton.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL p) { mouse_button(atomic_load(&g_key_hwnd), 1, p); };
    m.mouseInput.rightButton.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL p) { mouse_button(atomic_load(&g_key_hwnd), 2, p); };
    m.mouseInput.middleButton.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL p) { mouse_button(atomic_load(&g_key_hwnd), 4, p); };
    m.mouseInput.scroll.yAxis.valueChangedHandler = ^(GCControllerAxisInput *a, float v) {
        int d = (int)lround(v * 120);
        if (!d) return;
        di_mouse_wheel(d);
        win_from_cocoa(atomic_load(&g_key_hwnd), WM_MOUSEWHEEL, mk_flags() | (uint64_t)(uint16_t)(int16_t)d << 16, pack_pos(atomic_load(&g_cx), atomic_load(&g_cy)));
    };
}


// ---------------- on-screen keys ----------------
// A row of buttons over the game for the keys menus need without a keyboard (Space to continue, Esc, Enter, arrows).
static UIView *g_overlay;
static void overlay_front(void) { if (g_controls) [g_root.view bringSubviewToFront:g_controls]; if (g_overlay) [g_root.view bringSubviewToFront:g_overlay]; }
static void send_key(int mac, uint16_t ch, int down) {
    uint64_t hwnd = atomic_load(&g_key_hwnd);
    if (!hwnd) return;
    win_key_from_cocoa(hwnd, (uint16_t)mac, down, 0, down && ch ? &ch : NULL, down && ch ? 1 : 0);
}
@interface RTKeyButton : UIButton @property int mac; @property uint16_t ch; @end
@implementation RTKeyButton
- (void)pressed { send_key(self.mac, self.ch, 1); }
- (void)released { send_key(self.mac, self.ch, 0); }
@end
static void build_overlay(void) {
    static const struct { const char *label; int mac; uint16_t ch; } keys[] = {
        {"Esc", 53, 0x1B}, {"Enter", 36, '\r'}, {"Space", 49, ' '}, {"Tab", 48, '\t'},
        {"\u25C0", 123, 0}, {"\u25B2", 126, 0}, {"\u25BC", 125, 0}, {"\u25B6", 124, 0}, {"Y", 16, 'y'}, {"N", 45, 'n'},
    };
    UIView *row = [UIView new];
    g_overlay = row;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    UIStackView *st = [UIStackView new];
    st.axis = UILayoutConstraintAxisHorizontal; st.spacing = 6; st.translatesAutoresizingMaskIntoConstraints = NO;
    for (size_t i = 0; i < sizeof keys / sizeof *keys; i++) {
        RTKeyButton *b = [RTKeyButton buttonWithType:UIButtonTypeSystem];
        b.mac = keys[i].mac; b.ch = keys[i].ch;
        [b setTitle:[NSString stringWithUTF8String:keys[i].label] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont boldSystemFontOfSize:15];
        [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        b.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
        b.layer.cornerRadius = 8; b.layer.borderWidth = 1; b.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.35].CGColor;
        [b.widthAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
        [b.heightAnchor constraintEqualToConstant:36].active = YES;
        [b addTarget:b action:@selector(pressed) forControlEvents:UIControlEventTouchDown];
        [b addTarget:b action:@selector(released) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
        [st addArrangedSubview:b];
    }
    UIButton *hide = [UIButton buttonWithType:UIButtonTypeSystem];
    [hide setTitle:@"\u2328" forState:UIControlStateNormal];
    [hide setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    hide.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45]; hide.layer.cornerRadius = 8;
    hide.translatesAutoresizingMaskIntoConstraints = NO;
    [hide.widthAnchor constraintEqualToConstant:44].active = YES; [hide.heightAnchor constraintEqualToConstant:36].active = YES;
    [hide addAction:[UIAction actionWithHandler:^(UIAction *a) { st.hidden = !st.hidden; }] forControlEvents:UIControlEventTouchUpInside];
    [g_root.view addSubview:g_overlay];
    [row addSubview:st]; [row addSubview:hide];
    UILayoutGuide *g = g_root.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [row.topAnchor constraintEqualToAnchor:g.topAnchor constant:8], [row.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:8],
        [row.heightAnchor constraintEqualToConstant:36],
        [hide.leadingAnchor constraintEqualToAnchor:row.leadingAnchor], [hide.topAnchor constraintEqualToAnchor:row.topAnchor],
        [st.leadingAnchor constraintEqualToAnchor:hide.trailingAnchor constant:6], [st.topAnchor constraintEqualToAnchor:row.topAnchor],
        [row.trailingAnchor constraintEqualToAnchor:st.trailingAnchor],
    ]];
}


// ---------------- touch controls (gameplay) ----------------
// Left: a stick that holds W/A/S/D. Right: fire, zoom, jump, use, melee, grenade, quick-switch, weapon wheel.
// Shown while the game has captured the mouse (cocoa_cursor_visible(0)), i.e. in gameplay.
@interface RTStick : UIView
@property(strong) UIView *knob; @property(weak) UITouch *tracking; @property int dirs;   // bit0 W, 1 A, 2 S, 3 D
@end
@implementation RTStick
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12]; self.layer.cornerRadius = f.size.width / 2;
        self.layer.borderWidth = 2; self.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.35].CGColor;
        CGFloat k = f.size.width * 0.4;
        self.knob = [[UIView alloc] initWithFrame:CGRectMake((f.size.width - k) / 2, (f.size.height - k) / 2, k, k)];
        self.knob.backgroundColor = [UIColor colorWithWhite:1 alpha:0.5]; self.knob.layer.cornerRadius = k / 2; self.knob.userInteractionEnabled = NO;
        [self addSubview:self.knob];
    }
    return self;
}
- (void)setDirs:(int)d {
    static const int mac[4] = { 13, 0, 1, 2 };   // W A S D
    for (int i = 0; i < 4; i++) if (((d ^ _dirs) >> i) & 1) send_key(mac[i], 0, (d >> i) & 1);
    _dirs = d;
}
- (void)update:(UITouch *)t {
    CGPoint p = [t locationInView:self], c = CGPointMake(self.bounds.size.width / 2, self.bounds.size.height / 2);
    double R = self.bounds.size.width / 2, dx = p.x - c.x, dy = p.y - c.y, len = hypot(dx, dy);
    if (len > R) { dx *= R / len; dy *= R / len; len = R; }
    self.knob.center = CGPointMake(c.x + dx, c.y + dy);
    double nx = dx / R, ny = dy / R; int d = 0;
    if (len > R * 0.25) { if (ny < -0.38) d |= 1; if (nx < -0.38) d |= 2; if (ny > 0.38) d |= 4; if (nx > 0.38) d |= 8; }
    self.dirs = d;
}
- (void)touchesBegan:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { if (!self.tracking) { self.tracking = ts.anyObject; [self update:self.tracking]; } }
- (void)touchesMoved:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { if (self.tracking && [ts containsObject:self.tracking]) [self update:self.tracking]; }
- (void)end:(NSSet<UITouch *> *)ts {
    if (!self.tracking || ![ts containsObject:self.tracking]) return;
    self.tracking = nil; self.dirs = 0;
    self.knob.center = CGPointMake(self.bounds.size.width / 2, self.bounds.size.height / 2);
}
- (void)touchesEnded:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self end:ts]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self end:ts]; }
@end

typedef enum { ACT_KEY, ACT_MOUSE, ACT_WHEEL, ACT_CUSTOM } ActKind;
@interface RTActionButton : UIButton @property ActKind kind; @property int code, arg; @property(copy) void (^tap)(RTActionButton *); @end
@implementation RTActionButton
- (void)fire:(int)down {
    uint64_t hwnd = atomic_load(&g_key_hwnd);
    if (self.kind == ACT_KEY) send_key(self.code, 0, down);
    else if (self.kind == ACT_MOUSE) mouse_button(hwnd, self.code, down);
    else if (down) {
        di_mouse_wheel(self.arg);
        win_from_cocoa(hwnd, WM_MOUSEWHEEL, mk_flags() | (uint64_t)(uint16_t)(int16_t)self.arg << 16, pack_pos(atomic_load(&g_cx), atomic_load(&g_cy)));
    }
    self.alpha = down ? 1.0 : 0.75;
}
- (void)pressed { if (self.kind != ACT_CUSTOM) [self fire:1]; }
- (void)released { if (self.kind == ACT_CUSTOM) { if (self.tap) self.tap(self); } else [self fire:0]; }
// Hold FIRE and drag the same finger to keep aiming while firing.
- (void)touchesMoved:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    [super touchesMoved:ts withEvent:e];
    if (!(self.kind == ACT_MOUSE && self.code == 1)) return;
    UITouch *t = ts.anyObject;
    CGPoint p = [t locationInView:g_root.view], q = [t previousLocationInView:g_root.view];
    uint64_t hwnd = atomic_load(&g_key_hwnd);
    double k = 1.6 * g_sens;
    for (RTView *v in g_views) if (v.hwnd == hwnd) k *= v.pxPerPt;
    int dx = (int)lround((p.x - q.x) * k), dy = (int)lround((p.y - q.y) * k);
    if (dx || dy) mouse_motion(hwnd, dx, dy, clampi(atomic_load(&g_cx) + dx, 0, 4095), clampi(atomic_load(&g_cy) + dy, 0, 4095));
}
@end

static RTActionButton *action(NSString *title, ActKind kind, int code, int arg, CGFloat size) {
    RTActionButton *b = [RTActionButton buttonWithType:UIButtonTypeCustom];
    b.kind = kind; b.code = code; b.arg = arg;
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:size > 80 ? 20 : 14];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.22]; b.alpha = 0.75;
    b.layer.cornerRadius = size / 2; b.layer.borderWidth = 2; b.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.45].CGColor;
    b.bounds = CGRectMake(0, 0, size, size);
    [b addTarget:b action:@selector(pressed) forControlEvents:UIControlEventTouchDown];
    [b addTarget:b action:@selector(released) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    return b;
}
@interface RTControlsView : UIView @property(strong) RTStick *stick; @property(strong) NSArray<RTActionButton *> *buttons; @property(strong) NSArray<NSValue *> *offsets; @end
@implementation RTControlsView
// The left half of the screen is a floating stick: a touch there puts the stick under the finger. Buttons keep their own
// touches; the right half's empty space goes to the game view (look).
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    UIView *v = [super hitTest:p withEvent:e];
    if (v != self) return v;
    return p.x < self.bounds.size.width * 0.5 ? self : nil;
}
- (void)touchesBegan:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    if (self.stick.tracking) return;
    UITouch *t = ts.anyObject; CGPoint p = [t locationInView:self];
    CGFloat h = self.stick.bounds.size.width / 2;
    p.x = fmax(h, fmin(p.x, self.bounds.size.width - h)); p.y = fmax(h, fmin(p.y, self.bounds.size.height - h));
    self.stick.center = p; self.stick.alpha = 1;
    self.stick.tracking = t; [self.stick update:t];
}
- (void)touchesMoved:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { if (self.stick.tracking && [ts containsObject:self.stick.tracking]) [self.stick update:self.stick.tracking]; }
- (void)touchesEnded:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    if (!self.stick.tracking || ![ts containsObject:self.stick.tracking]) return;
    [self.stick end:ts];
    self.stick.alpha = 0.55; [self setNeedsLayout];   // back to the resting spot
}
- (void)touchesCancelled:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self touchesEnded:ts withEvent:e]; }
- (void)layoutSubviews {
    [super layoutSubviews];
    UIEdgeInsets in = self.safeAreaInsets; CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    CGFloat sz = 150;
    if (!self.stick.tracking) self.stick.frame = CGRectMake(in.left + 40, H - in.bottom - sz - 30, sz, sz);
    for (NSUInteger i = 0; i < self.buttons.count; i++) {       // offsets are from the bottom-right corner
        CGPoint o = self.offsets[i].CGPointValue;
        self.buttons[i].center = CGPointMake(W - in.right - o.x, H - in.bottom - o.y);
    }
}
@end
static void build_controls(void) {
    RTControlsView *v = [RTControlsView new];
    v.translatesAutoresizingMaskIntoConstraints = NO; v.hidden = YES;
    v.stick = [[RTStick alloc] initWithFrame:CGRectMake(0, 0, 150, 150)];
    v.stick.userInteractionEnabled = NO; v.stick.alpha = 0.55;   // resting hint; the controls view drives it
    [v addSubview:v.stick];
    struct { const char *t; ActKind k; int code, arg; CGFloat size, x, y; } defs[] = {
        {"FIRE", ACT_MOUSE, 1, 0, 104, 95, 95},
        {"ZOOM", ACT_MOUSE, 2, 0, 66, 60, 215},
        {"JUMP", ACT_KEY, 49, 0, 74, 205, 62},
        {"SPRINT", ACT_KEY, 56, 0, 66, 300, 62},
        {"USE", ACT_KEY, 14, 0, 58, 175, 150},
        {"MELEE", ACT_KEY, 3, 0, 58, 245, 150},
        {"GRENADE", ACT_KEY, 5, 0, 58, 315, 150},
        {"SWAP", ACT_KEY, 12, 0, 58, 385, 62},
        {"WPN \u25B2", ACT_WHEEL, 0, 120, 52, 45, 305},
        {"WPN \u25BC", ACT_WHEEL, 0, -120, 52, 45, 365},
        {"SENS\n1.0x", ACT_CUSTOM, 0, 0, 52, 45, 425},
        {"GYRO\noff", ACT_CUSTOM, 1, 0, 52, 45, 485},
    };
    NSMutableArray *bs = [NSMutableArray array], *os = [NSMutableArray array];
    for (size_t i = 0; i < sizeof defs / sizeof *defs; i++) {
        RTActionButton *b = action([NSString stringWithUTF8String:defs[i].t], defs[i].k, defs[i].code, defs[i].arg, defs[i].size);
        b.titleLabel.numberOfLines = 2; b.titleLabel.textAlignment = NSTextAlignmentCenter;
        b.titleLabel.font = [UIFont boldSystemFontOfSize:defs[i].size > 80 ? 20 : 11];
        if (defs[i].k == ACT_CUSTOM) {
            if (defs[i].code == 0) {   // SENS: next step
                NSInteger idx = 2; for (NSInteger j = 0; j < 6; j++) if (fabs(kSensSteps[j] - g_sens) < 0.01) idx = j;
                void (^show)(RTActionButton *) = ^(RTActionButton *bb) { [bb setTitle:[NSString stringWithFormat:@"SENS\n%.2gx", g_sens] forState:UIControlStateNormal]; };
                show(b);
                b.tap = ^(RTActionButton *bb) {
                    NSInteger k = 2; for (NSInteger j = 0; j < 6; j++) if (fabs(kSensSteps[j] - g_sens) < 0.01) k = j;
                    g_sens = kSensSteps[(k + 1) % 6]; show(bb);
                    [NSUserDefaults.standardUserDefaults setDouble:g_sens forKey:@"sens"];
                };
                (void)idx;
            } else {                    // GYRO: toggle
                void (^show)(RTActionButton *) = ^(RTActionButton *bb) {
                    [bb setTitle:atomic_load(&g_gyro_on) ? @"GYRO\non" : @"GYRO\noff" forState:UIControlStateNormal];
                    bb.backgroundColor = [UIColor colorWithWhite:1 alpha:atomic_load(&g_gyro_on) ? 0.5 : 0.22];
                };
                show(b);
                b.tap = ^(RTActionButton *bb) {
                    atomic_store(&g_gyro_on, !atomic_load(&g_gyro_on)); show(bb);
                    [NSUserDefaults.standardUserDefaults setBool:atomic_load(&g_gyro_on) forKey:@"gyro"];
                };
            }
        }
        [v addSubview:b]; [bs addObject:b]; [os addObject:[NSValue valueWithCGPoint:CGPointMake(defs[i].x, defs[i].y)]];
    }
    v.buttons = bs; v.offsets = os;
    g_controls = v;
    [g_root.view addSubview:v];
    [NSLayoutConstraint activateConstraints:@[
        [v.leadingAnchor constraintEqualToAnchor:g_root.view.leadingAnchor], [v.trailingAnchor constraintEqualToAnchor:g_root.view.trailingAnchor],
        [v.topAnchor constraintEqualToAnchor:g_root.view.topAnchor], [v.bottomAnchor constraintEqualToAnchor:g_root.view.bottomAnchor]]];
}


// ---------------- gyro aiming ----------------
// Turning the phone about the world's vertical axis turns the view; tilting it about the screen's horizontal axis
// looks up/down. Rotation rates come from CMDeviceMotion (gravity gives the vertical axis, so it works at any tilt).
static CMMotionManager *g_motion;
static void start_gyro(void) {
    g_motion = [CMMotionManager new];
    if (!g_motion.deviceMotionAvailable) { rt_log("[cocoa] no gyro\n"); return; }
    g_motion.deviceMotionUpdateInterval = 1.0 / 120;
    static double accx, accy, lastT;
    [g_motion startDeviceMotionUpdatesToQueue:[NSOperationQueue new] withHandler:^(CMDeviceMotion *m, NSError *err) {
        if (!m) return;
        double dt = lastT ? m.timestamp - lastT : 0; lastT = m.timestamp;
        if (dt <= 0 || dt > 0.1 || !atomic_load(&g_gyro_on) || g_controls.hidden) return;
        uint64_t hwnd = atomic_load(&g_key_hwnd); if (!hwnd) return;
        CMRotationRate r = m.rotationRate; CMAcceleration g = m.gravity;
        { static double px, py, pz; static int cnt; static double gx, gy, gz;   // diagnostics: peak rate per axis every 0.5 s
          if (fabs(r.x) > fabs(px)) px = r.x; if (fabs(r.y) > fabs(py)) py = r.y; if (fabs(r.z) > fabs(pz)) pz = r.z;
          gx += g.x; gy += g.y; gz += g.z;
          if (++cnt >= 60) { rt_log("[gyro] peak rate x %+.2f y %+.2f z %+.2f rad/s | gravity x %+.2f y %+.2f z %+.2f\n", px, py, pz, gx / cnt, gy / cnt, gz / cnt); px = py = pz = gx = gy = gz = 0; cnt = 0; } }
        // Two orthogonal axes from gravity, whatever way the sensors are mounted: yaw about the world's vertical (up = -gravity),
        // pitch about the screen's horizontal axis = up x screen-normal (z), normalized. (On this phone gravity lies along
        // the device's y axis in play, not x: assuming a fixed axis for pitch gave none.)
        double ux = -g.x, uy = -g.y, uz = -g.z;
        double yaw = r.x * ux + r.y * uy + r.z * uz;       // + = turning left
        double rx = uy, ry = -ux, rn = sqrt(rx * rx + ry * ry);   // screen-right in device coordinates
        double pitchUp = rn > 0.3 ? (r.x * rx + r.y * ry) / rn : 0;   // + = looking up
        double pitch = -pitchUp;                           // mouse y grows downward
        double k = 450.0 * g_sens * dt;                            // mouse counts per rad/s
        accx += -yaw * k; accy += pitch * k;
        int dx = (int)accx, dy = (int)accy; accx -= dx; accy -= dy;
        if (dx || dy) mouse_motion(hwnd, dx, dy, clampi(atomic_load(&g_cx) + dx, 0, 4095), clampi(atomic_load(&g_cy) + dy, 0, 4095));
    }];
}

// ProMotion: tell the system this app wants 60-120 Hz. Without a request iOS can settle the display at 30 Hz when
// frames arrive irregularly (a Metal layer alone does not ask for a rate). The link itself does nothing.
@interface RTRateHint : NSObject - (void)tick:(CADisplayLink *)l; @end
double cocoa_dl_interval_ms = 0; int cocoa_dl_count;   // measured display-link period (read by the perf log)
@implementation RTRateHint
- (void)tick:(CADisplayLink *)l {
    static CFTimeInterval last; CFTimeInterval t = l.timestamp;
    if (last) { cocoa_dl_interval_ms += (t - last) * 1000; cocoa_dl_count++; }
    last = t;
}
@end
static RTRateHint *g_hint; static CADisplayLink *g_link;
static void request_high_refresh(void) {
    g_hint = [RTRateHint new];
    g_link = [CADisplayLink displayLinkWithTarget:g_hint selector:@selector(tick:)];
    g_link.preferredFrameRateRange = CAFrameRateRangeMake(60, 120, 120);
    [g_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

// Main thread, at launch: input devices, app activation.
void gamepad_start(void);
void cocoa_ios_start(void) {
    cocoa_ios_screen_init();
    build_overlay();
    request_high_refresh();
    { NSUserDefaults *d = NSUserDefaults.standardUserDefaults; if ([d objectForKey:@"sens"]) g_sens = [d doubleForKey:@"sens"]; atomic_store(&g_gyro_on, [d boolForKey:@"gyro"]); }
    build_controls();
    start_gyro();
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    if (GCKeyboard.coalescedKeyboard) attach_keyboard(GCKeyboard.coalescedKeyboard);
    [nc addObserverForName:GCKeyboardDidConnectNotification object:nil queue:nil usingBlock:^(NSNotification *n) { attach_keyboard(n.object); }];
    for (GCMouse *m in GCMouse.mice) attach_mouse(m);
    [nc addObserverForName:GCMouseDidConnectNotification object:nil queue:nil usingBlock:^(NSNotification *n) { attach_mouse(n.object); }];
    [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil usingBlock:^(NSNotification *n) { win_from_cocoa(0, WM_ACTIVATEAPP, 1, 0); }];
    [nc addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:nil usingBlock:^(NSNotification *n) { win_from_cocoa(0, WM_ACTIVATEAPP, 0, 0); }];
    gamepad_start();
}

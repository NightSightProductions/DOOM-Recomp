// iOS entry point, replacing boot.c: UIApplicationMain on the main thread, the guest on its own thread.
//
// Game files: <app Documents>/DOOM/ (must contain DOOMx64vk.exe). Documents is visible in the Files app and to
// `devicectl device copy`; DOOM_GAME_DIR overrides it.
#import <UIKit/UIKit.h>
#import <AVFAudio/AVFAudio.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <pthread.h>
#include <sys/stat.h>
#include <unistd.h>
#include "rt.h"
#include "cocoa.h"
#include "game.h"

void win32_init(int argc, char **argv);
int rt_guest_strip_claimed(void);              // rt.c (ios/patches/framework/0001-ios-claim-guest-strip.patch)
UIViewController *cocoa_ios_root(void);
void cocoa_ios_start(void);

// The game restarts itself through CreateProcess to switch renderer or mode; an iOS app cannot start another
// copy of itself.
int rt_relaunch(int nargs, char **args) {
    (void)args;
    rt_log("[boot] relaunch requested (%d game args): not possible on iOS\n", nargs);
    return 0;
}

static char g_exe[PATH_MAX], g_dir[PATH_MAX];
static int g_argc; static char **g_argv;

static void *game_thread(void *arg) {
    (void)arg;
    pthread_setname_np("DOOM main");
    rt_init();
    char **gargv = g_argv; int gargc = g_argc;
    if (rt_game.extra_args) {
        int ne = 0; while (rt_game.extra_args[ne]) ne++;
        char **v = calloc((size_t)(gargc + ne + 1), sizeof *v);
        memcpy(v, gargv, (size_t)gargc * sizeof *v);
        for (int i = 0; i < ne; i++) v[gargc++] = (char *)rt_game.extra_args[i];
        gargv = v;
    }
    rt_log("[boot] game folder %s\n", g_dir);
    rt_load_image(g_exe);
    if (chdir(g_dir)) { perror(g_dir); return NULL; }
    win32_init(gargc, gargv);
    CPU *c = cpu_new(8u << 20);
    rt_set_cur(c);
    rt_log("[boot] image at 0x%llx, entry 0x%llx, %d functions\n", (unsigned long long)gimage_base, (unsigned long long)gentry, ngfuncs);
    uint64_t r = guest_call(c, gentry, 0, NULL);
    rt_log("[boot] entry returned %llu\n", (unsigned long long)r);
    exit(0);
}


// Performance log (every 5 s into the log, with RT_FPS): CPU use per thread, to see what limits the frame rate.
#include <mach/mach.h>
static void *perf_thread(void *arg) {
    pthread_setname_np("perf monitor");
    for (;;) {
        sleep(5);
        thread_act_array_t th; mach_msg_type_number_t n = 0;
        if (task_threads(mach_task_self(), &th, &n)) continue;
        char line[1024]; int o = snprintf(line, sizeof line, "[perf]");
        for (mach_msg_type_number_t i = 0; i < n; i++) {
            thread_basic_info_data_t bi; mach_msg_type_number_t c = THREAD_BASIC_INFO_COUNT;
            if (thread_info(th[i], THREAD_BASIC_INFO, (thread_info_t)&bi, &c)) continue;
            double cpu = bi.cpu_usage / 10.0;
            if (cpu < 3.0) continue;
            char name[64] = "?"; pthread_t pt = pthread_from_mach_thread_np(th[i]);
            if (pt) pthread_getname_np(pt, name, sizeof name);
            if (o < 900) o += snprintf(line + o, sizeof line - (size_t)o, " %s=%.0f%%", name[0] ? name : "?", cpu);
        }
        for (mach_msg_type_number_t i = 0; i < n; i++) mach_port_deallocate(mach_task_self(), th[i]);
        vm_deallocate(mach_task_self(), (vm_address_t)th, n * sizeof *th);
        NSProcessInfo *pi = NSProcessInfo.processInfo;
        o += snprintf(line + o, sizeof line - (size_t)o, " | lowPower=%d thermal=%ld", pi.lowPowerModeEnabled, (long)pi.thermalState);
        { extern double cocoa_dl_interval_ms; extern int cocoa_dl_count;
          if (cocoa_dl_count) { o += snprintf(line + o, sizeof line - (size_t)o, " displayLink=%.2fms", cocoa_dl_interval_ms / cocoa_dl_count); cocoa_dl_interval_ms = 0; cocoa_dl_count = 0; } }
        rt_log("%s\n", line);
    }
    return NULL;
}

static void start_game(void) {
    pthread_attr_t at;
    pthread_attr_init(&at);
    pthread_attr_setstacksize(&at, 64u << 20);
    pthread_t t;
    pthread_t pm; pthread_create(&pm, NULL, perf_thread, NULL); pthread_detach(pm);
    if (pthread_create(&t, &at, game_thread, NULL)) rt_log("[boot] cannot start the game thread\n");
    pthread_detach(t);
}

static void fatal(UIViewController *root, NSString *title, NSString *msg) {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Quit" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) { exit(0); }]];
    [root presentViewController:a animated:YES completion:nil];
}

static int is_game_dir(const char *d) {
    char p[PATH_MAX];
    snprintf(p, sizeof p, "%s/%s", d, rt_game.exe);
    return access(p, R_OK) == 0;
}

@interface RTSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(strong) UIWindow *window;
@end
@interface RTiOSDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation RTiOSDelegate
- (UISceneConfiguration *)application:(UIApplication *)app configurationForConnectingSceneSession:(UISceneSession *)s options:(UISceneConnectionOptions *)o {
    UISceneConfiguration *c = [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:s.role];
    c.delegateClass = [RTSceneDelegate class];
    return c;
}
- (UIInterfaceOrientationMask)application:(UIApplication *)a supportedInterfaceOrientationsForWindow:(UIWindow *)w { return UIInterfaceOrientationMaskLandscape; }
@end
@implementation RTSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)opts {
    UIApplication *app = UIApplication.sharedApplication;
    static int started; if (started++) return;
    setvbuf(stderr, NULL, _IONBF, 0);
    { NSString *d0 = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject; freopen([d0 stringByAppendingPathComponent:@"DOOM-recomp.log"].fileSystemRepresentation, "w", stderr); setvbuf(stderr, NULL, _IONBF, 0); fprintf(stderr, "[boot] launched, strip claimed: %d\n", rt_guest_strip_claimed()); }
    { char exe[PATH_MAX]; uint32_t n = sizeof exe; if (!_NSGetExecutablePath(exe, &n)) setenv("RT_VULKAN_LIB", exe, 0); }   // vk_ios.c
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (getenv("RT_LOG_FILE")) freopen([docs stringByAppendingPathComponent:@"DOOM-recomp.log"].fileSystemRepresentation, "w", stderr);
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    UIViewController *root = cocoa_ios_root();
    self.window.rootViewController = root;
    [self.window makeKeyAndVisible];
    cocoa_ios_start();
    app.idleTimerDisabled = YES;
    // Skip the online login (Bethesda/PlayFab): its failures cost ~30 s at startup. DOOM_ONLINE_LOGIN=1 turns it back on.
    setenv("RT_FPS", "1", 0);
    if (!getenv("DOOM_ONLINE_LOGIN")) setenv("RT_NO_HTTP", "1", 0);

    AVAudioSession *as = AVAudioSession.sharedInstance;
    [as setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault options:0 error:nil];
    [as setPreferredSampleRate:48000 error:nil];
    [as setActive:YES error:nil];

    if (!rt_guest_strip_claimed()) {
        rt_log("[boot] the guest address range 0x140000000 was not available in this launch\n");
        dispatch_async(dispatch_get_main_queue(), ^{
            fatal(root, @"Couldn't reserve memory",
                  @"iOS placed something in the address range the game needs. This happens on some launches. Quit and open the app again.");
        });
        return;
    }
    const char *env = rt_game_env("GAME_DIR");
    snprintf(g_dir, sizeof g_dir, "%s", env && *env ? env : [docs stringByAppendingPathComponent:@"DOOM"].fileSystemRepresentation);
    if (!is_game_dir(g_dir)) {
        NSString *msg = [NSString stringWithFormat:@"Copy the contents of your DOOM (2016) folder, the one containing %s, to the app's Documents/DOOM folder (Finder > this iPhone > Files, or devicectl device copy to), then reopen the app.", rt_game.exe];
        dispatch_async(dispatch_get_main_queue(), ^{ fatal(root, @"Game files not found", msg); });
        return;
    }
    snprintf(g_exe, sizeof g_exe, "%s/%s", g_dir, rt_game.exe);
    static char *argv0[] = { "DOOM", NULL };
    g_argc = 1; g_argv = argv0;
    start_game();
}
@end

int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass([RTiOSDelegate class])); }
}

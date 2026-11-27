// Steam Cloud saves shared with the Windows version (adapted from Wolfenstein-TOB-Recomp's cloud_wolf.c).
//
// DOOM (2016) syncs its saves with Steam Auto-Cloud, which the Steam client runs by itself on Windows' Saved Games
// folder (id Software/DOOM/base/savegame.user/<SteamID>). Steam for Mac resolves that Windows root for a game that runs
// through a compatibility tool, into the tool's Wine-style prefix:
//   <library>/steamapps/compatdata/379720/pfx/drive_c/users/steamuser/Saved Games
// and syncs it there before launch and after exit, in both directions. It only does so when the tool's internal name
// contains "proton"; NSR's tool ID, "nsr_proton", does (framework/tools/nsr.py). When DOOM is registered with NSR, the
// guest's C:\users\Player\Saved Games\id Software is a link into that prefix, so the game reads and writes the very
// files Steam syncs with Windows, and the framework's own Mac-only sync (doomrecomp/ in the cloud) is turned off.
// Without NSR nothing changes: saves stay in the app's folder and sync through doomrecomp/ as before.
//
// The first time, saves of an earlier build are merged in, one save slot at a time (GAME-AUTOSAVE0-2, PROFILE,
// SNAPMAP*): the slot saved more recently wins. Nothing is deleted: the app's earlier folder is kept as
// "id Software.local-<date>", and a Steam slot replaced by a newer Mac one is kept in "id Software.steam-<date>",
// both next to the link.
// DOOM_LOCAL_SAVES=1 keeps saves in the app's folder (no change from 1.1). The GOG release always does.
#include <copyfile.h>
#include <dirent.h>
#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <removefile.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include "game.h"
#include "rt.h"

#define SAVE_BASE "DOOM/base"

// The constructor runs before boot points stderr at the log, so its messages wait here and are written a moment later.
static char msgs[8192];
static void say(const char *fmt, ...) {
    size_t n = strlen(msgs);
    va_list ap; va_start(ap, fmt); vsnprintf(msgs + n, sizeof msgs - n, fmt, ap); va_end(ap);
}
static void *log_later(void *p) { (void)p; sleep(3); if (*msgs) rt_log("%s", msgs); return NULL; }

static void mkdir_p(const char *path) {
    char t[PATH_MAX]; snprintf(t, sizeof t, "%s", path);
    for (char *p = t + 1; *p; p++) if (*p == '/') { *p = 0; mkdir(t, 0755); *p = '/'; }
    mkdir(t, 0755);
}
static int is_dir(const char *p) { struct stat st; return stat(p, &st) == 0 && S_ISDIR(st.st_mode); }
static int exists(const char *p) { struct stat st; return lstat(p, &st) == 0; }
static void rm_rf(const char *p) { removefile(p, NULL, REMOVEFILE_RECURSIVE); }
// copies keep their modification times (COPYFILE_ALL), so a slot copied once compares equal afterwards
static int copy_tree(const char *from, const char *to) { return copyfile(from, to, NULL, COPYFILE_ALL | COPYFILE_RECURSIVE); }
static int move_tree(const char *from, const char *to) {   // the prefix can be on another volume (a second Steam library)
    if (!rename(from, to)) return 0;
    if (copy_tree(from, to)) return -1;
    rm_rf(from); return 0;
}

// newest modification time of the files in a save slot (Steam's own bookkeeping file left out)
static time_t newest(const char *dir) {
    time_t t = 0; DIR *d = opendir(dir); if (!d) return 0;
    struct dirent *e;
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.' || !strcmp(e->d_name, "steam_autocloud.vdf")) continue;
        char p[PATH_MAX]; snprintf(p, sizeof p, "%s/%s", dir, e->d_name);
        struct stat st; if (lstat(p, &st)) continue;
        time_t s = S_ISDIR(st.st_mode) ? newest(p) : st.st_mtime;
        if (s > t) t = s;
    }
    closedir(d); return t;
}
static int is_slot(const char *dir, const char *name) {   // as tools/import_saves.py: a slot with a save in it
    char p[PATH_MAX + 32];
    if (!strncmp(name, "SNAPMAP", 7)) return 1;
    snprintf(p, sizeof p, "%s/game.details", dir); if (exists(p)) return 1;
    snprintf(p, sizeof p, "%s/profile.bin", dir);  return exists(p);
}

// Merge one savegame.user/<id> folder of the app's into Steam's: per slot, the newer one wins.
static void merge_user(const char *id, const char *local, const char *steam, const char *backup) {
    DIR *d = opendir(local); if (!d) return;
    mkdir_p(steam);
    struct dirent *e;
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.') continue;
        char lp[PATH_MAX], sp[PATH_MAX]; struct stat st;
        snprintf(lp, sizeof lp, "%s/%s", local, e->d_name);
        snprintf(sp, sizeof sp, "%s/%s", steam, e->d_name);
        if (lstat(lp, &st)) continue;
        if (S_ISREG(st.st_mode)) { if (!exists(sp)) copyfile(lp, sp, NULL, COPYFILE_ALL); continue; }   // migrated.bin
        // slots only: not import_saves.py's PROFILE.windows / PROFILE.offline copies
        if (!S_ISDIR(st.st_mode) || strchr(e->d_name, '.') || !is_slot(lp, e->d_name)) continue;
        time_t lt = newest(lp), st_ = is_dir(sp) && is_slot(sp, e->d_name) ? newest(sp) : -1;
        if (st_ >= lt) { say("[cloud] %s/%s: Steam's save is as new or newer, kept\n", id, e->d_name); continue; }
        // copy beside the slot first, then swap, so an interrupted run never leaves a half-copied slot in its place
        char inc[PATH_MAX + 16]; snprintf(inc, sizeof inc, "%s/.%s.incoming", steam, e->d_name);
        rm_rf(inc);
        if (copy_tree(lp, inc)) { say("[cloud] %s/%s: could not copy the Mac save (%s)\n", id, e->d_name, strerror(errno)); rm_rf(inc); continue; }
        if (exists(sp)) {
            char bk[PATH_MAX]; snprintf(bk, sizeof bk, "%s/%s", backup, e->d_name);
            mkdir_p(backup);
            if (move_tree(sp, bk)) { say("[cloud] %s/%s: could not back up Steam's save, kept it\n", id, e->d_name); rm_rf(inc); continue; }
        }
        if (rename(inc, sp)) { say("[cloud] %s/%s: could not put the Mac save in place (%s)\n", id, e->d_name, strerror(errno)); rm_rf(inc); continue; }
        say("[cloud] %s/%s: the Mac save is newer, now in Steam Cloud%s\n", id, e->d_name, st_ >= 0 ? " (Steam's kept as a backup)" : "");
    }
    closedir(d);
}

// Bring an earlier build's save folder (a real folder at `link`) into Steam's (`target`).
static void merge_local(const char *link, const char *target, const char *saved, const char *stamp) {
    char lu[PATH_MAX], tu[PATH_MAX];
    snprintf(lu, sizeof lu, "%s/" SAVE_BASE "/savegame.user", link);
    snprintf(tu, sizeof tu, "%s/" SAVE_BASE "/savegame.user", target);
    DIR *d = opendir(lu);
    if (d) {
        struct dirent *e;
        while ((e = readdir(d))) {
            if (e->d_name[0] < '0' || e->d_name[0] > '9' || strchr(e->d_name, '.')) continue;   // <SteamID> folders only
            char l[PATH_MAX], t[PATH_MAX], b[PATH_MAX];
            snprintf(l, sizeof l, "%s/%s", lu, e->d_name);
            snprintf(t, sizeof t, "%s/%s", tu, e->d_name);
            snprintf(b, sizeof b, "%s/id Software.steam-%s/" SAVE_BASE "/savegame.user/%s", saved, stamp, e->d_name);
            if (is_dir(l)) merge_user(e->d_name, l, t, b);
        }
        closedir(d);
    }
    // settings (DOOMConfig.cfg, DOOMConfig.local): only where Steam's folder has none
    char lb[PATH_MAX], tb[PATH_MAX];
    snprintf(lb, sizeof lb, "%s/" SAVE_BASE, link); snprintf(tb, sizeof tb, "%s/" SAVE_BASE, target);
    if ((d = opendir(lb))) {
        struct dirent *e;
        while ((e = readdir(d))) {
            char l[PATH_MAX], t[PATH_MAX]; struct stat st;
            snprintf(l, sizeof l, "%s/%s", lb, e->d_name); snprintf(t, sizeof t, "%s/%s", tb, e->d_name);
            if (!strncmp(e->d_name, "DOOMConfig", 10) && !lstat(l, &st) && S_ISREG(st.st_mode) && !exists(t)) copyfile(l, t, NULL, COPYFILE_ALL);
        }
        closedir(d);
    }
}

// DOOM is registered with NSR (in its games.conf), or this launch came through a compatibility tool
static int nsr_in_use(const char *home) {
    if (getenv("STEAM_COMPAT_DATA_PATH")) return 1;
    char p[PATH_MAX], line[4096], id[16];
    snprintf(p, sizeof p, "%s/Library/Application Support/Steam/compatibilitytools.d/nsr_proton/games.conf", home);
    snprintf(id, sizeof id, "%u\t", rt_game.steam_app_id);
    FILE *f = fopen(p, "r"); if (!f) return 0;
    int found = 0;
    while (!found && fgets(line, sizeof line, f)) found = !strncmp(line, id, strlen(id));
    fclose(f); return found;
}

// The game's compatdata folder, in the Steam library that holds the game:
//   1. STEAM_COMPAT_DATA_PATH, which Steam sets for a compatibility tool (a launch from Steam);
//   2. next to the game folder boot uses (<data>/game-dir.txt: <library>/steamapps/common/<game>);
//   3. the default library.
static void compat_data(const char *home, const char *data, char *out, size_t n) {
    const char *env = getenv("STEAM_COMPAT_DATA_PATH");
    if (env && *env) { snprintf(out, n, "%s", env); return; }
    char p[PATH_MAX], line[PATH_MAX];
    snprintf(p, sizeof p, "%s/game-dir.txt", data);
    FILE *f = fopen(p, "r");
    if (f) {
        int ok = fgets(line, sizeof line, f) != NULL; fclose(f);
        line[strcspn(line, "\n")] = 0;
        char *common = ok ? strstr(line, "/steamapps/common/") : NULL;
        if (common) {
            *common = 0;
            snprintf(out, n, "%s/steamapps/compatdata/%u", line, rt_game.steam_app_id);
            if (is_dir(out)) return;
        }
    }
    snprintf(out, n, "%s/Library/Application Support/Steam/steamapps/compatdata/%u", home, rt_game.steam_app_id);
}

static void setup(void) {
#ifdef DOOM_EDITION_GOG
    return;   // no Steam account: saves stay in the app's folder
#endif
    const char *home = getenv("HOME");
    const char *local = rt_game_env("LOCAL_SAVES");
    if (!home) return;
    if (local && *local && strcmp(local, "0")) { say("[cloud] DOOM_LOCAL_SAVES: saves stay in the app's folder\n"); return; }
    if (!nsr_in_use(home)) return;   // as in 1.1: the framework syncs the app's save folder (doomrecomp/ in the cloud)

    // the guest's C:\users\Player\Saved Games, under the data folder exactly as runtime/files.c maps drive C:
    char data[PATH_MAX], saved[PATH_MAX], link[PATH_MAX], cdata[PATH_MAX], target[PATH_MAX];
    const char *dd = rt_game_env("DATA_DIR");
    if (dd && *dd) snprintf(data, sizeof data, "%s", dd);
    else snprintf(data, sizeof data, "%s/Library/Application Support/%s", home, rt_game.data_name);
    snprintf(saved, sizeof saved, "%s/c/users/Player/Saved Games", data);
    snprintf(link, sizeof link, "%s/id Software", saved);
    compat_data(home, data, cdata, sizeof cdata);
    snprintf(target, sizeof target, "%s/pfx/drive_c/users/steamuser/Saved Games/id Software", cdata);

    char base[PATH_MAX + 16]; snprintf(base, sizeof base, "%s/" SAVE_BASE, target);
    mkdir_p(base);
    mkdir_p(saved);
    char stamp[32]; time_t now = time(NULL); strftime(stamp, sizeof stamp, "%Y%m%d-%H%M%S", localtime(&now));

    struct stat st;
    if (lstat(link, &st) == 0) {
        if (S_ISLNK(st.st_mode)) {
            char cur[PATH_MAX]; ssize_t r = readlink(link, cur, sizeof cur - 1);
            if (r > 0) { cur[r] = 0; if (!strcmp(cur, target)) goto linked; }
            unlink(link);   // an older target (the game moved to another library): Steam's copy there is the same saves
        } else {
            // an earlier build's saves: merge them into Steam's folder, then keep the folder as it was
            merge_local(link, target, saved, stamp);
            char keep[PATH_MAX + 64]; snprintf(keep, sizeof keep, "%s.local-%s", link, stamp);
            if (rename(link, keep)) { say("[cloud] could not move %s aside (%s): saves stay local\n", link, strerror(errno)); return; }
            say("[cloud] earlier saves kept in %s\n", keep);
        }
    }
    if (symlink(target, link)) { say("[cloud] could not link %s (%s): saves stay local\n", link, strerror(errno)); return; }
linked:
    setenv("DOOM_CLOUD", "0", 1);   // Steam syncs this folder itself; the framework's doomrecomp/ sync would double it
    say("[cloud] saves: Steam Cloud, shared with Windows (%s)\n", target);
    // The runtime re-executes itself once at startup, so the merge usually happens in the first pass, whose messages
    // are never logged: list the kept folders every time instead.
    DIR *d = opendir(saved);
    if (d) {
        struct dirent *e;
        while ((e = readdir(d))) if (!strncmp(e->d_name, "id Software.local-", 18) || !strncmp(e->d_name, "id Software.steam-", 18))
            say("[cloud] %s saves kept in %s/%s\n", e->d_name[12] == 'l' ? "earlier Mac" : "replaced Steam", saved, e->d_name);
        closedir(d);
    }
}

__attribute__((constructor)) static void doom_cloud_init(void) {
    setup();
    if (*msgs) { pthread_t t; if (!pthread_create(&t, NULL, log_later, NULL)) pthread_detach(t); }
}

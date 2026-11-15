#!/usr/bin/env python3
"""Import DOOM (2016) saves from a Windows install (CrossOver/Whisky bottles) into DOOM Recomp.

The Windows release keeps saves in  <Saved Games>/id Software/DOOM/base/savegame.user/<SteamID>/  with
campaign slots GAME-AUTOSAVE0-2, PROFILE (settings and unlocks) and SNAPMAP* folders; DOOM Recomp uses the same
layout under ~/Library/Application Support/doom-recomp/c/users/Player/Saved Games. Nothing is overwritten:
  - a campaign slot goes to the same slot number if that is free, otherwise to a free slot;
  - SnapMap folders are copied when missing;
  - PROFILE is only copied when there is none (an existing one is kept; the Windows one is saved beside it
    as PROFILE.windows, to swap in by hand);
  - saves made before signing in to Steam (placeholder ID 76561197960265729) are handled the same way.
A backup of the whole DOOM Recomp save folder is made first (savegame.user.backup-<time>).

usage: import_saves.py [--steamid ID] [--from DIR ...] [--dry-run]
"""
import glob, os, shutil, sys, time

DEST_BASE = os.path.expanduser("~/Library/Application Support/doom-recomp/c/users/Player/Saved Games/id Software/DOOM/base")
PLACEHOLDER = "76561197960265729"
SLOTS = ["GAME-AUTOSAVE0", "GAME-AUTOSAVE1", "GAME-AUTOSAVE2"]

def windows_sources():
    pats = ["~/Library/Application Support/CrossOver/Bottles/*/drive_c/users/*/Saved Games/id Software/DOOM/base/savegame.user",
            "~/Library/Containers/com.isaacmarovitz.Whisky/Bottles/*/drive_c/users/*/Saved Games/id Software/DOOM/base/savegame.user"]
    return [p for pat in pats for p in glob.glob(os.path.expanduser(pat))]

def has_save(d):
    return os.path.isfile(os.path.join(d, "game.details")) or os.path.isfile(os.path.join(d, "profile.bin"))

def copy_tree(src, dst, dry):
    print("  %s -> %s" % (src, dst))
    if not dry: shutil.copytree(src, dst, ignore=shutil.ignore_patterns("steam_autocloud.vdf"))

def merge(src, dst, dry, alt="PROFILE.windows"):
    """merge one savegame.user/<id> folder into another"""
    os.makedirs(dst, exist_ok=True)
    used = {s for s in SLOTS if has_save(os.path.join(dst, s))}
    for name in sorted(os.listdir(src)):
        sp = os.path.join(src, name)
        if not os.path.isdir(sp) or not has_save(sp) and not name.startswith("SNAPMAP"): continue
        if name in SLOTS:
            target = name if name not in used else next((s for s in SLOTS if s not in used), None)
            if not target: print("  no free slot for %s (all three are used)" % sp); continue
            if os.path.exists(os.path.join(dst, target)) and not dry: shutil.rmtree(os.path.join(dst, target))   # an empty slot folder
            copy_tree(sp, os.path.join(dst, target), dry); used.add(target)
        elif name == "PROFILE":
            if has_save(os.path.join(dst, "PROFILE")):
                if alt and not os.path.exists(os.path.join(dst, alt)): copy_tree(sp, os.path.join(dst, alt), dry)
            else:
                if os.path.exists(os.path.join(dst, "PROFILE")) and not dry: shutil.rmtree(os.path.join(dst, "PROFILE"))
                copy_tree(sp, os.path.join(dst, "PROFILE"), dry)
        elif name.startswith("SNAPMAP") and not os.path.exists(os.path.join(dst, name)):
            copy_tree(sp, os.path.join(dst, name), dry)

def main():
    a = sys.argv[1:]
    dry = "--dry-run" in a
    users = os.path.join(DEST_BASE, "savegame.user")
    sources = [a[i + 1] for i, x in enumerate(a) if x == "--from"] or windows_sources()
    ids = [a[a.index("--steamid") + 1]] if "--steamid" in a else \
          sorted({d for s in sources for d in os.listdir(s) if d.isdigit() and d != PLACEHOLDER} |
                 {d for d in (os.listdir(users) if os.path.isdir(users) else []) if d.isdigit() and d != PLACEHOLDER})
    if not ids: print("no Steam account folder found"); return 1
    if os.path.isdir(users) and not dry:
        bak = users + ".backup-" + time.strftime("%Y%m%d-%H%M%S")
        shutil.copytree(users, bak); print("backup:", bak)
    for sid in ids:
        dst = os.path.join(users, sid)
        for s in sources:
            if os.path.isdir(os.path.join(s, sid)):
                print("importing Windows saves for %s from %s" % (sid, s)); merge(os.path.join(s, sid), dst, dry)
        ph = os.path.join(users, PLACEHOLDER)
        if os.path.isdir(ph):
            print("importing saves made before Steam sign-in"); merge(ph, dst, dry, alt="PROFILE.offline")
    return 0

if __name__ == "__main__":
    sys.exit(main())

# iOS port notes

Status: boots on device through vkCreateDevice and swapchain creation; needs the game data copied to Documents/DOOM.

## Layout
- `runtime/cocoa_ios.m`  UIKit replacement for cocoa.m: one full-screen root VC, each guest window a CAMetalLayer view letterboxed to
  the guest's aspect ratio; touch -> left button + motion; GameController keyboard/mouse -> keys/buttons; UIPointerLock for capture.
- `runtime/boot_ios.m`   replaces boot.c: UIApplicationMain on the main thread, the guest on a 64 MiB thread. Checks the strip claim
  (prompts to relaunch if lost), AVAudioSession, game folder = `Documents/DOOM` (or `DOOM_GAME_DIR`).
- `runtime/display_ios.c` generated from framework display.c by `scripts/gen_display_ios.py` (single UIScreen display).
- `runtime/vk_ios.c`     `vkGetInstanceProcAddr` forwarder to the bundled KosmicKrisp ICD (no Vulkan loader on iOS).
- `runtime/ios_compat.h` force-included shim: CGAssociateMouse no-op, `crypt` rename; audio uses
  `-DkAudioUnitSubType_DefaultOutput=kAudioUnitSubType_RemoteIO`.
- `Makefile`             builds libgame.a + both DLL libs for iOS and the patched `rt.c` into `build/`.
- `app/project.yml`      xcodegen project (`xcodegen generate`, then build/install with xcodebuild or devicectl).
All other framework runtime files are compiled unmodified.

## Address layout (measured on an iPhone 18-generation device, iOS 26+)
The translated game needs its image at 0x140000000 (exe, 0x14161000 bytes). On iOS:
- an app cannot re-exec itself (`posix_spawn(SETEXEC|DISABLE_ASLR)` returns EPERM), and arm64 executables are always PIE, so the
  macOS approach (linked `__GUEST` segment + re-exec without ASLR) does not work;
- 0x180000000-0x1f2000000 is the dyld shared cache, so the DLL base 0x180000000 is impossible;
- libmalloc's first arena lands in 0x140000000-0x160000000 in roughly a quarter to a third of launches.

Chosen approach: claim a 384 MiB strip at 0x140000000 with `mmap` from a very early constructor (`patches/framework/0001-*`),
rebase the DLLs into the strip, and when the claim fails (heap arena already there) tell the user to relaunch.
Rebasing the exe itself is not viable: tools/native.txt, tools/patches.txt and src/native_idtech.c hard-code guest addresses.

DLL bases for the iOS build (inside the strip, after the exe image ending at 0x154161000):
- superscriptx64.dll: `--rebase 155000000`
- bink2w64.dll:       `--rebase 156000000 --no-abi-trim`

## Verified so far
- Runtime: 20 of 26 files compile for iOS unchanged; cocoa.m, display.c, wasapi.c, xaudio2.c, dinput.c need porting (rt.c is patched).
- Translated game: all 482 generated files compile for iOS (arm64, -O2, -DRT_RELAX_FP).
- KosmicKrisp runs on device (see ios-kk-ci/).

## KosmicKrisp for iOS
`scripts/build-kosmickrisp-ios.sh` (edit the S/R paths at the top) fetches nothing: point it at a Mesa checkout of
`ios-kk-ci/out/MESA_COMMIT` (+ the framework's patches/mesa), it applies the iOS fixups and builds host tools + the iOS dylib.
`patches/mesa/0001-wsi-metal-extra-drawable.patch` is what takes the game from 30 to 60 fps: iOS cannot disable
CAMetalLayer display sync, so the layer needs one more drawable than the Vulkan swapchain has images (DOOM insists on 2).

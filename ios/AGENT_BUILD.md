# Build the iOS port with an AI coding agent

Hand this file to an agent (Claude Code, Codex, Cursor, ...) running in a terminal on the user's Mac, with the repo as the
working directory. Prompt: *"Follow ios/AGENT_BUILD.md to build and install DOOM Recomp on my iPhone."*

## Rules for the agent
- Run each step, check its output, and stop to ask the user only where marked **ASK**. Do not guess values.
- The user must own DOOM (2016) on Steam, **Windows** release. Never download game files or look for them online. Never commit them.
- Do not modify `framework/` (a pristine git submodule). Changes for iOS live in `ios/`.
- Long steps (translate, driver build) take 10-20 minutes each: run them in the background and wait for completion.
- If a step fails, read the error, fix the cause (usually a missing tool), and retry. Do not skip steps.

## 0. Preconditions (check, do not install blindly)
- Apple Silicon Mac, macOS with full **Xcode** installed (not only Command Line Tools): `xcodebuild -version`.
  If `xcode-select -p` is not under `/Applications/Xcode.app`, ask the user before running `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.
- Xcode signed in to the user's Apple ID (Settings > Accounts). iPhone on iOS 26+ with Developer Mode on, connected by cable, unlocked.
- About 30 GB free disk. Homebrew installed (`brew --version`); if missing, tell the user to install it from https://brew.sh.

## 1. Tools
```bash
brew install llvm libclc spirv-llvm-translator spirv-tools spirv-headers bison meson ninja pkg-config xcodegen python
git submodule update --init --recursive
python3 -m venv .venv
.venv/bin/pip install capstone==5.0.6 lief==0.16.6
```

## 2. Game files
**ASK** the user for the folder of their Steam copy of DOOM (it contains `DOOMx64vk.exe`, `superscriptx64.dll`, `bink2w64.dll`,
`base/`, `virtualtextures/`). Copy three files into the repo root with these names (they are git-ignored):
```bash
cp "$GAME/DOOMx64vk.exe"      orig.exe
cp "$GAME/superscriptx64.dll" orig_superscript.dll
cp "$GAME/bink2w64.dll"       orig_bink.dll
```
`scripts/build.sh` and the Mac installer check the exe against the supported Steam build; if translation reports a mismatch, tell the
user their game version is not supported and ask them to update it through Steam.

## 3. Translate the game (about 10-15 min)
```bash
make gen
.venv/bin/python framework/tools/recomp64.py orig_superscript.dll gen_superscript_ios --module superscriptx64 --rebase 155000000
.venv/bin/python framework/tools/recomp64.py orig_bink.dll gen_bink_ios --module bink2w64 --rebase 156000000 --no-abi-trim
```
The two DLLs are rebased into a 384 MiB address strip the iOS runtime claims at launch (see `ios/README.md`). Do not change the bases.

## 4. Vulkan driver for iOS (about 20 min)
```bash
ios/scripts/build-kosmickrisp-ios.sh
```
Produces `ios/build/libvulkan_kosmickrisp.dylib` (Mesa at the commit in `ios/MESA_COMMIT`, with the framework's and `ios/patches/mesa` patches).

## 5. Static libraries and patched runtime files
```bash
make -f ios/Makefile libs -j8
```
Creates `ios/build/libgame.a`, `libsuperscriptx64.a`, `libbink2w64.a`, and patched copies of `rt.c`, `steam.c`, `kernel32.c`.

## 6. Signing: the user's own team and bundle ID
In `ios/app/project.yml` the values `DEVELOPMENT_TEAM: R72X3BF4KE` and `PRODUCT_BUNDLE_IDENTIFIER: com.yoshisuga.doom` belong to the
original author. **ASK** the user for their Apple Developer Team ID (Xcode > Settings > Accounts > Team; or the 10-character ID in
`security find-identity -v -p codesigning`) and a unique bundle ID such as `com.<theirname>.doom`. Replace both in `project.yml`.
A free Apple ID works; the app then expires after 7 days. Do not commit these personal values back to the shared branch.

## 7. Build and install
```bash
cd ios/app
xcodegen generate
xcodebuild -project DOOM.xcodeproj -scheme DOOM -destination 'generic/platform=iOS' -allowProvisioningUpdates build
xcrun devicectl list devices            # find the iPhone's UDID
APP=$(ls -dt ~/Library/Developer/Xcode/DerivedData/DOOM-*/Build/Products/Debug-iphoneos/DOOM.app | head -1)
xcrun devicectl device install app --device <UDID> "$APP"
```
If install fails with a trust error, tell the user: Settings > General > VPN & Device Management > trust their developer profile.

## 8. Game data on the phone
The app reads `Documents/DOOM` (Files app: On My iPhone > DOOM). Tell the user to copy the `base` and `virtualtextures` folders
from their Steam copy there with Finder (iPhone > Files tab) or the Files app. Roughly 60+ GB; the agent can do this with
`xcrun devicectl device copy to --device <UDID> --domain-type appDataContainer --domain-identifier <bundle id> --source <dir> --destination Documents/DOOM/<name>`
but it is slow; Finder is usually easier.

## 9. Launch and diagnose
```bash
xcrun devicectl device process launch --device <UDID> <bundle id>      # phone must be unlocked
xcrun devicectl device copy from --device <UDID> --domain-type appDataContainer --domain-identifier <bundle id> \
  --source Documents/DOOM-recomp.log --destination ./doom.log
```
Known behavior, not bugs:
- About 1 in 3 launches shows "quit and reopen": the fixed guest address strip could not be claimed. Relaunch.
- `VK_ERROR_DEVICE_LOST` / GPU "DSF Pause Timeout" under heavy scenes: set the game's resolution scale to about 75%.
- Jetsam kill ("per-process-limit"): memory limit about 6 GB; `RT_VRAM_MB` (default 2048) caps the GPU heap in `ios/runtime/vk_ios.c`.
- Crash reports: `xcrun devicectl device copy from ... --domain-type systemCrashLogs --source .`

## Reference
`ios/README.md` (design notes), `ios/runtime/` (UIKit layer), `ios/patches/` (framework and Mesa patches), top-level `Makefile`
and `framework/README.md` (the recompilation pipeline).

# Building DOOM Recomp for iPhone (step by step, for Mac beginners)

You build the game yourself from your own copy of DOOM (2016). No game files are in this repository.

**Prefer to let an AI agent do it?** Open this repo in Claude Code, Codex, Cursor or similar, and tell it:
*"Follow ios/AGENT_BUILD.md to build and install DOOM Recomp on my iPhone."* The agent guide has the same steps in a form an
agent can follow, and it will stop to ask you for the things only you can supply (your game folder and your Apple Team ID).
See [AGENT_BUILD.md](AGENT_BUILD.md).

The steps below are the manual route.

## What you need
- An Apple Silicon Mac with **Xcode** installed (App Store, about 15 GB). Open it once so it installs its extra components.
- A free Apple ID, added in Xcode > Settings > Accounts.
- An iPhone on iOS 26 or later with **Developer Mode** on (Settings > Privacy & Security > Developer Mode).
- The **Windows** version of DOOM (2016) from Steam, fully downloaded and updated. On a Mac you can get it with Steam for Windows in
  CrossOver, or by copying the game folder from a PC. About 70 GB.
- About 30 GB of free disk space and about an hour (translating the game takes 10-15 minutes, the graphics driver about 20).

## 1. Install the tools
Open Terminal. Install Homebrew (the Mac package manager) if you don't have it:
```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```
Then the build tools, and point the system at the full Xcode:
```bash
brew install llvm libclc spirv-llvm-translator spirv-tools spirv-headers bison meson ninja pkg-config xcodegen python
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

## 2. Get the code
Keep `--recurse-submodules`: the recompilation framework is a git submodule.
```bash
git clone --recurse-submodules -b ios-port https://github.com/yoshisuga/DOOM-Recomp.git
cd DOOM-Recomp
python3 -m venv .venv
.venv/bin/pip install capstone==5.0.6 lief==0.16.6
```

## 3. Put your game files in the repo folder
Copy three files from your Steam copy of DOOM into the repo's top folder, renaming them:

| From the game folder | Save as |
|---|---|
| `DOOMx64vk.exe` | `orig.exe` |
| `superscriptx64.dll` | `orig_superscript.dll` |
| `bink2w64.dll` | `orig_bink.dll` |

## 4. Translate the game (10-15 minutes)
```bash
make gen
.venv/bin/python framework/tools/recomp64.py orig_superscript.dll gen_superscript_ios --module superscriptx64 --rebase 155000000
.venv/bin/python framework/tools/recomp64.py orig_bink.dll gen_bink_ios --module bink2w64 --rebase 156000000 --no-abi-trim
```
This turns the game's Windows code into C code. If it complains about the executable, your game version is probably not the supported
Steam build: update the game in Steam and copy the files again.

## 5. Build the graphics driver (about 20 minutes)
```bash
ios/scripts/build-kosmickrisp-ios.sh
```

## 6. Build the game libraries
```bash
make -f ios/Makefile libs -j8
```

## 7. Set up signing
Open `ios/app/project.yml` and change two lines to your own values:
- `DEVELOPMENT_TEAM`: your Apple Team ID (Xcode > Settings > Accounts > select your team).
- `PRODUCT_BUNDLE_IDENTIFIER`: something unique, such as `com.yourname.doom`.

Then generate the Xcode project and open it:
```bash
cd ios/app
xcodegen generate
open DOOM.xcodeproj
```
In Xcode, select the **DOOM** target > **Signing & Capabilities**, and check that your team is selected.

## 8. Run it on your phone
Plug in the iPhone and unlock it. Choose it as the run destination at the top of Xcode and press **Play**. The first time, trust your
developer profile on the phone: Settings > General > VPN & Device Management. With a free Apple ID the app stops working after 7 days
and has to be reinstalled from Xcode.

## 9. Copy the game data to the phone
In Finder, select the iPhone and open the **Files** tab. Drag the `base` and `virtualtextures` folders from your Steam copy of DOOM
into the **DOOM** app's entry. On the phone they appear in the Files app under On My iPhone > DOOM. This is about 60 GB, so it takes a while.

Launch DOOM from the home screen. The first load takes a minute or two.

## Good to know
- About one launch in three shows a "quit and reopen" message. That is a known memory-layout limit of iOS, so just open the app again.
- If it crashes in big fights, lower the game's resolution scale to about 75% (Options > Video). This keeps the GPU from timing out.
- The app is capped at about 6 GB of memory by iOS. A GPU heap cap of 2 GB (`RT_VRAM_MB` in `runtime/vk_ios.c`) keeps it under that.
- Controls: on-screen touch controls, or a Bluetooth keyboard and mouse or a game controller. Gyro aiming and the sensitivity button
  are on screen.
- Logs are in the app's Documents folder (`DOOM-recomp.log`), visible in the Files app. Attach it when reporting a problem.

More detail on how the port works: [README.md](README.md).

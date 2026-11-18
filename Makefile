# DOOM (2016) on Recomp-Framework (framework/, a git submodule): static recompilation to native arm64 macOS.
#   make gen gen-dll gen-bink   translate DOOMx64vk.exe, superscriptx64.dll and bink2w64.dll
#   make -j8 boot               build the runtime + translated game
#   make app                    build/DOOM.app
#   make kosmickrisp            build the Vulkan driver from Mesa (with the framework's patches)
#   make steam-play             register the app with NightSight Recomp (NSR), the Steam Play tool (needs NotProton)
FW        = framework
PYTHON    = .venv/bin/python
BUILD     = build
GAME_EXE ?= orig.exe
APP_NAME  = DOOM
BUNDLE_ID = com.nightsightproductions.doom-recomp
APP_CATEGORY = public.app-category.action-games
GAME_SRC  = src/game.c src/native_idtech.c

# The edition of the game: the Steam and GOG releases of DOOMx64vk.exe are different builds of the same code,
# so the native replacements and instruction patches sit at different addresses (the two DLLs are identical).
# Detected from the exe's SHA-256 (scripts/build.sh and setup/macos/Installer.swift check the same hashes);
# EDITION=steam or EDITION=gog overrides.
SHA_STEAM = 3d8b4393649f80bdae85c19ae2c985c45ec9ac54f74ab04a18816e30ead63c21
SHA_GOG   = a32df8ffa042090f14fe0a200f1c5d7dddf9c947fac223916c252f826f1ecf11
ifndef EDITION
EDITION := $(shell sha=$$(shasum -a 256 "$(GAME_EXE)" 2>/dev/null | cut -d' ' -f1); \
             if [ "$$sha" = $(SHA_STEAM) ]; then echo steam; elif [ "$$sha" = $(SHA_GOG) ]; then echo gog; else echo unknown; fi)
endif
ifeq ($(EDITION),gog)
NATIVE    = tools/native_gog.txt
PATCHES   = tools/patches_gog.txt
else
NATIVE    = tools/native.txt
PATCHES   = tools/patches.txt
endif
# the game's DLLs that contain code, translated as modules (rules below)
EXTRA_LIBS_FORCE = $(BUILD)/libsuperscriptx64.a $(BUILD)/libbink2w64.a

include $(FW)/recomp.mk
# The game synchronizes its threads through integer flags and locks, so float and vector accesses don't need
# x86 ordering (see the framework README, "Memory ordering")
GEN_CFLAGS += -DRT_RELAX_FP

# Translating with another edition's addresses would replace the wrong functions: refuse an unknown exe.
gen: check-edition
check-edition:
	@case "$(EDITION)" in steam|gog) echo "$(GAME_EXE): $(EDITION) release" ;; \
	  *) echo "error: $(GAME_EXE) is neither the supported Steam nor the GOG release of DOOMx64vk.exe" >&2; exit 1 ;; esac
.PHONY: check-edition
# src/game.c knows the edition (the GOG release has no Steam account to talk to); a stamp per edition
# rebuilds it when the edition changes.
ifeq ($(EDITION),gog)
CFLAGS += -DDOOM_EDITION_GOG
endif
$(BUILD)/edition.$(EDITION):
	@mkdir -p $(BUILD); rm -f $(BUILD)/edition.*; touch $@
$(BUILD)/game/src/game.o: $(BUILD)/edition.$(EDITION)

# Both DLLs prefer 0x180000000, where arm64 macOS maps its shared cache, so they are translated rebased into the
# framework's DLL range (0x160000000-0x164000000).
# superscriptx64.dll (the script VM); orig_superscript.dll links to the game's copy, like orig.exe
SUPERSCRIPT_DLL ?= orig_superscript.dll
$(eval $(call MODULE_RULES,superscriptx64,$(SUPERSCRIPT_DLL),gen_superscript,--rebase 160000000,))
# RAD Bink 2 (bink2w64.dll): rebased to 0x162000000, after superscriptx64.
# It only synchronizes through kernel objects, so it needs no TSO ordering.
BINK_DLL ?= orig_bink.dll
$(eval $(call MODULE_RULES,bink2w64,$(BINK_DLL),gen_bink,--rebase 162000000 --no-abi-trim,-DRT_TSO=0))

gen-dll: gen-superscriptx64
gen-bink: gen-bink2w64
.PHONY: gen-dll gen-bink

# Steam Play: Play on DOOM's own Steam entry starts the app (framework/tools/nsr.py, NightSight Recomp)
APP_PATH ?= $(CURDIR)/$(BUILD)/$(APP_NAME).app
steam-play:
	python3 $(FW)/tools/nsr.py install
	python3 $(FW)/tools/nsr.py add --appid 379720 --app "$(APP_PATH)" --pass-paths --exe 'doomx64*.exe' \
	    --force-exe DOOMx64vk.exe --name DOOM
.PHONY: steam-play

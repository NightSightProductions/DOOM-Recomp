#!/bin/bash
set -e
S=/private/tmp/claude-501/-Users-yoshi-Code-personal-DOOM-Recomp/b35ebc39-9e6f-423a-be36-9b72003e22d1/scratchpad; R=/Users/yoshi/Code/personal/DOOM-Recomp
python3 -m venv $S/venv && $S/venv/bin/pip install -q mako packaging pyyaml
export PATH="$S/host-tools/bin:/opt/homebrew/opt/llvm/bin:/opt/homebrew/opt/bison/bin:$S/venv/bin:$PATH"
cd $S/mesa
git checkout -q . 
for p in $R/framework/patches/mesa/*.patch; do git apply "$p" && echo "applied $p"; done
git apply --include=src/kosmickrisp/vulkan/kk_bo.c $R/ios-kk-ci/patches/0003-ios-support.patch && echo "applied kk_bo part of 0003"
perl -pi -e 's|^(\s*)(metal_layer\.displaySyncEnabled = .*;)\s*$|#if !__is_target_os(ios)\n$1$2\n#endif\n|' src/vulkan/wsi/wsi_common_metal_layer.m
# drawables: one more than the Vulkan swapchain images, so the game can render ahead of the compositor
perl -pi -e 's|metal_layer.maximumDrawableCount = image_count;|metal_layer.maximumDrawableCount = image_count < 3 ? image_count + 1 : image_count;|' src/vulkan/wsi/wsi_common_metal_layer.m
grep -n maximumDrawableCount src/vulkan/wsi/wsi_common_metal_layer.m
export SDKROOT=$(xcrun --sdk macosx --show-sdk-path)
if [ ! -d build-host ]; then
meson setup build-host . --prefix=$S/host-tools --buildtype=release -Db_ndebug=true -Dplatforms=macos -Dvulkan-drivers=kosmickrisp -Dgallium-drivers= -Dopengl=false -Dzstd=disabled -Dglx=disabled -Degl=disabled -Dgbm=disabled -Dinstall-mesa-clc=true -Dinstall-precomp-compiler=true
fi
ninja -C build-host install
unset SDKROOT
SDK=$(xcrun --sdk iphoneos --show-sdk-path); T=arm64-apple-ios26.0
cat > $S/ios-arm64.cross <<X
[binaries]
c = ['clang', '-target', '$T', '-isysroot', '$SDK']
cpp = ['clang++', '-target', '$T', '-isysroot', '$SDK']
objc = ['clang', '-target', '$T', '-isysroot', '$SDK']
objcpp = ['clang++', '-target', '$T', '-isysroot', '$SDK']
ar = 'ar'
strip = 'strip'
pkg-config = 'pkg-config'
[host_machine]
system = 'darwin'
subsystem = 'ios'
kernel = 'xnu'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
[properties]
needs_exe_wrapper = true
X
if [ ! -d build-ios ]; then
meson setup build-ios . --cross-file $S/ios-arm64.cross --prefix=$S/kk-ios --buildtype=release -Db_ndebug=true -Dplatforms=macos -Dvulkan-drivers=kosmickrisp -Dgallium-drivers= -Dopengl=false -Dzstd=disabled -Dglx=disabled -Degl=disabled -Dgbm=disabled -Dllvm=disabled -Dmesa-clc=system -Dprecomp-compiler=system -Dspirv-tools=disabled
fi
ninja -C build-ios install
find $S/kk-ios -name '*.dylib'
echo BUILD-DONE

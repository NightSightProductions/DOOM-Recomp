#!/bin/bash
# Builds KosmicKrisp (Mesa's Vulkan-on-Metal driver) for iOS: ios/build/libvulkan_kosmickrisp.dylib.
#   brew install llvm libclc spirv-llvm-translator spirv-tools spirv-headers bison meson ninja pkg-config
#   ios/scripts/build-kosmickrisp-ios.sh        (about 20 minutes; needs Xcode with the iOS SDK)
# Mesa is fetched at the commit in ios/MESA_COMMIT into ios/build/mesa, patched with the framework's patches and
# ios/patches/mesa/*.patch, built twice: native helper tools (mesa_clc, ...) for macOS, then the iOS dylib.
set -euo pipefail
R="$(cd "$(dirname "$0")/../.." && pwd)"
B="$R/ios/build"
MESA="$B/mesa"
COMMIT="$(awk '{print $1; exit}' "$R/ios/MESA_COMMIT")"
mkdir -p "$B"

if [ ! -d "$MESA/.git" ]; then
  git init -q "$MESA"
  git -C "$MESA" remote add origin https://gitlab.freedesktop.org/mesa/mesa.git
fi
if [ "$(git -C "$MESA" rev-parse HEAD 2>/dev/null || true)" != "$COMMIT" ]; then
  git -C "$MESA" fetch -q --depth 1 origin "$COMMIT"
  git -C "$MESA" checkout -q -f FETCH_HEAD
fi
git -C "$MESA" checkout -q -f .
for p in "$R"/framework/patches/mesa/*.patch "$R"/ios/patches/mesa/*.patch; do
  git -C "$MESA" apply "$p" && echo "applied $(basename "$p")"
done

[ -d "$B/venv" ] || { python3 -m venv "$B/venv"; "$B/venv/bin/pip" install -q mako packaging pyyaml; }
export PATH="$B/host-tools/bin:/opt/homebrew/opt/llvm/bin:/opt/homebrew/opt/bison/bin:$B/venv/bin:$PATH"

cd "$MESA"
# native helper tools, built with the macOS SDK
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
[ -d build-host ] || meson setup build-host . --prefix="$B/host-tools" --buildtype=release -Db_ndebug=true \
  -Dplatforms=macos -Dvulkan-drivers=kosmickrisp -Dgallium-drivers= -Dopengl=false -Dzstd=disabled -Dglx=disabled \
  -Degl=disabled -Dgbm=disabled -Dinstall-mesa-clc=true -Dinstall-precomp-compiler=true
ninja -C build-host install
unset SDKROOT

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"; T=arm64-apple-ios26.0
cat > "$B/ios-arm64.cross" <<EOF
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
EOF
[ -d build-ios ] || meson setup build-ios . --cross-file "$B/ios-arm64.cross" --prefix="$B/kk-ios" --buildtype=release \
  -Db_ndebug=true -Dplatforms=macos -Dvulkan-drivers=kosmickrisp -Dgallium-drivers= -Dopengl=false -Dzstd=disabled \
  -Dglx=disabled -Degl=disabled -Dgbm=disabled -Dllvm=disabled -Dmesa-clc=system -Dprecomp-compiler=system -Dspirv-tools=disabled
ninja -C build-ios install
cp "$B/kk-ios/lib/libvulkan_kosmickrisp.dylib" "$B/libvulkan_kosmickrisp.dylib"
echo "built $B/libvulkan_kosmickrisp.dylib"

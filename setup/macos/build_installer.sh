#!/bin/bash
#
# Builds the macOS distribution of DOOM Recomp:
#
#   DOOM-Recomp-macOS.dmg
#     Install DOOM Recomp.app   installer wizard (Installer.swift) carrying
#       source/                 this project's source, including the framework submodule (git ls-files --recurse-submodules) - no game files
#       source/prebuilt/kosmickrisp   the KosmicKrisp Vulkan driver built from Mesa (make kosmickrisp)
#     License.txt
#
# The installer builds the game on the user's Mac from their own copy of DOOM (2016),
# by running scripts/build.sh.
#
# Requirements: Xcode Command Line Tools (swiftc, git) and build/kosmickrisp (run `make kosmickrisp`).
# Usage: setup/macos/build_installer.sh [output dir]

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SETUP="${ROOT}/setup/macos"
OUT="${1:-${ROOT}/build-macos-dist}"
STAGE="${OUT}/stage"
MIN_MACOS="26.0"   # the runtime and KosmicKrisp need a current macOS

APP_NAME="DOOM Recomp"
INSTALLER="${STAGE}/dmg/Install ${APP_NAME}.app"
DMG="${OUT}/DOOM-Recomp-macOS.dmg"

die() { echo "error: $*" >&2; exit 1; }

git -C "${ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "run this from a git checkout"
[[ -f "${ROOT}/build/kosmickrisp/kosmickrisp_icd.json" ]] || die "build/kosmickrisp is missing: run 'make kosmickrisp' first"
VERSION="$(git -C "${ROOT}" describe --tags --always 2>/dev/null || echo 1.0)"
VERSION="${VERSION#v}"

rm -rf "${STAGE}"
mkdir -p "${INSTALLER}/Contents/MacOS" "${INSTALLER}/Contents/Resources/source"

# Only tracked files: the repository never contains game code or data.
# The framework's own submodules (third_party/dxvk, ffmpeg, ...) are for its win32 target and are listed as bare
# folders when not checked out: DOOM doesn't build them, so they are left out.
(cd "${ROOT}" && git ls-files --recurse-submodules | grep -v "^docs/" | while read -r f; do
    [[ -d "$f" ]] && continue
    mkdir -p "${INSTALLER}/Contents/Resources/source/$(dirname "$f")"
    cp -p "$f" "${INSTALLER}/Contents/Resources/source/$f"
done)
# The prebuilt Vulkan driver (open source: Mesa, MIT; the Khronos loader, Apache-2.0)
mkdir -p "${INSTALLER}/Contents/Resources/source/prebuilt"
cp -R "${ROOT}/build/kosmickrisp" "${INSTALLER}/Contents/Resources/source/prebuilt/kosmickrisp"

sed -e "s/@VERSION@/${VERSION}/g" -e "s/@MIN_MACOS@/${MIN_MACOS}/g" "${SETUP}/InstallerInfo.plist" > "${INSTALLER}/Contents/Info.plist"
xcrun swiftc -O -swift-version 5 -target "arm64-apple-macos${MIN_MACOS}" "${SETUP}/Installer.swift" -o "${INSTALLER}/Contents/MacOS/installer"
[[ -f "${SETUP}/WelcomeImage.png" ]] && cp "${SETUP}/WelcomeImage.png" "${INSTALLER}/Contents/Resources/"
# The installer's icon, made from the game's logo (docs/logo.png, 256 x 256)
ICONSET="${STAGE}/AppIcon.iconset"
rm -rf "${ICONSET}" && mkdir -p "${ICONSET}"
for size in 16 32 128 256; do
    sips -z "${size}" "${size}" "${ROOT}/docs/logo.png" --out "${ICONSET}/icon_${size}x${size}.png" >/dev/null
    [[ ${size} -le 128 ]] && sips -z $((size * 2)) $((size * 2)) "${ROOT}/docs/logo.png" --out "${ICONSET}/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "${ICONSET}" -o "${INSTALLER}/Contents/Resources/AppIcon.icns"

# Ad hoc signature: Apple Silicon only runs signed code. Distribution outside this Mac
# needs a Developer ID signature and notarization; set SIGN_ID to use one.
SIGN_ID="${SIGN_ID:--}"
SIGN_OPTS=()
[[ "${SIGN_ID}" != "-" ]] && SIGN_OPTS=(--options runtime --timestamp)
codesign --force --sign "${SIGN_ID}" "${SIGN_OPTS[@]+"${SIGN_OPTS[@]}"}" "${INSTALLER}"

cp "${ROOT}/LICENSE" "${STAGE}/dmg/License.txt"
rm -f "${DMG}"
hdiutil create -volname "${APP_NAME}" -srcfolder "${STAGE}/dmg" -ov -format UDZO "${DMG}" >/dev/null
echo "Created ${DMG}"

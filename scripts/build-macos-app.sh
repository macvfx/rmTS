#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
SOURCE="$PROJECT_DIR/Sources/main.swift"
AUTHORIZATION_SHIM="$PROJECT_DIR/Sources/AuthorizationShim.c"
PLIST_SOURCE="$PROJECT_DIR/Info.plist"
ASSET_CATALOG="$PROJECT_DIR/Resources/Assets.xcassets"
OUTPUT_APP="$PROJECT_DIR/build/Tailscale Cache Cleaner.app"
BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/tailscale-cleaner-build.XXXXXX")
trap 'rm -rf "$BUILD_DIR"' EXIT HUP INT TERM

[ "$(uname -s)" = "Darwin" ] || { printf 'The macOS app can only be built on macOS.\n' >&2; exit 1; }
[ -d "$ASSET_CATALOG/AppIcon.appiconset" ] || { printf 'Missing app icon asset catalog: %s\n' "$ASSET_CATALOG" >&2; exit 1; }
[ ! -e "$OUTPUT_APP" ] || { printf 'Refusing to replace existing app: %s\n' "$OUTPUT_APP" >&2; exit 1; }

SDK_PATH=$(xcrun --sdk macosx --show-sdk-path)
COMMON_FLAGS="-O -whole-module-optimization -module-cache-path $BUILD_DIR/ModuleCache -sdk $SDK_PATH -framework AppKit -framework Foundation -framework Security"

# Word splitting is intentional for the fixed compiler flags.
# shellcheck disable=SC2086
xcrun clang -target arm64-apple-macos12.0 -isysroot "$SDK_PATH" -c "$AUTHORIZATION_SHIM" -o "$BUILD_DIR/AuthorizationShim-arm64.o"
# shellcheck disable=SC2086
xcrun swiftc $COMMON_FLAGS -target arm64-apple-macos12.0 "$SOURCE" "$BUILD_DIR/AuthorizationShim-arm64.o" -o "$BUILD_DIR/TailscaleCacheCleaner-arm64"
# shellcheck disable=SC2086
xcrun clang -target x86_64-apple-macos12.0 -isysroot "$SDK_PATH" -c "$AUTHORIZATION_SHIM" -o "$BUILD_DIR/AuthorizationShim-x86_64.o"
# shellcheck disable=SC2086
xcrun swiftc $COMMON_FLAGS -target x86_64-apple-macos12.0 "$SOURCE" "$BUILD_DIR/AuthorizationShim-x86_64.o" -o "$BUILD_DIR/TailscaleCacheCleaner-x86_64"

mkdir -p "$OUTPUT_APP/Contents/MacOS" "$OUTPUT_APP/Contents/Resources"
lipo -create "$BUILD_DIR/TailscaleCacheCleaner-arm64" "$BUILD_DIR/TailscaleCacheCleaner-x86_64" -output "$OUTPUT_APP/Contents/MacOS/Tailscale Cache Cleaner"
install -m 0644 "$PLIST_SOURCE" "$OUTPUT_APP/Contents/Info.plist"
xcrun actool "$ASSET_CATALOG" \
    --compile "$OUTPUT_APP/Contents/Resources" \
    --platform macosx \
    --minimum-deployment-target 12.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$BUILD_DIR/asset-info.plist" \
    >/dev/null
if [ -f "$OUTPUT_APP/Contents/Resources/AppIcon.icns" ]; then
    /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string AppIcon' "$OUTPUT_APP/Contents/Info.plist" 2>/dev/null || \
        /usr/libexec/PlistBuddy -c 'Set :CFBundleIconFile AppIcon' "$OUTPUT_APP/Contents/Info.plist"
fi
codesign --force --deep --sign - "$OUTPUT_APP"

printf 'Built universal Swift app: %s\n' "$OUTPUT_APP"

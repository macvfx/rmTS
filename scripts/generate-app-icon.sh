#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
SOURCE="$PROJECT_DIR/Resources/AppIcon-1024.png"
ICONSET="$PROJECT_DIR/Resources/Assets.xcassets/AppIcon.appiconset"

[ "$(uname -s)" = "Darwin" ] || { printf 'App icons can only be generated on macOS.\n' >&2; exit 1; }
[ -f "$SOURCE" ] || { printf 'Missing source icon: %s\n' "$SOURCE" >&2; exit 1; }

mkdir -p "$ICONSET"

render() {
    pixels=$1
    filename=$2
    sips -z "$pixels" "$pixels" "$SOURCE" --out "$ICONSET/$filename" >/dev/null
}

render 16 icon_16x16.png
render 32 icon_16x16@2x.png
render 32 icon_32x32.png
render 64 icon_32x32@2x.png
render 128 icon_128x128.png
render 256 icon_128x128@2x.png
render 256 icon_256x256.png
render 512 icon_256x256@2x.png
render 512 icon_512x512.png
render 1024 icon_512x512@2x.png

printf 'Generated app icon renditions: %s\n' "$ICONSET"

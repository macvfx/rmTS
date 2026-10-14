#!/bin/sh

# Installs the tiny desktop wrapper for the current Linux user.

set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
APP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/tailscale-cache-cleaner"
DESKTOP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
DESKTOP_FILE="$DESKTOP_DIR/com.macvfx.tailscale-cache-cleaner.desktop"

[ "$(uname -s)" = "Linux" ] || {
    printf 'This desktop app targets Linux. The cleaner script can still be inspected here.\n' >&2
    exit 1
}

mkdir -p "$APP_DIR" "$DESKTOP_DIR"
install -m 0755 "$SCRIPT_DIR/tailscale-cache-cleaner.sh" "$APP_DIR/tailscale-cache-cleaner.sh"
install -m 0755 "$SCRIPT_DIR/tailscale-cache-cleaner-app.sh" "$APP_DIR/tailscale-cache-cleaner-app.sh"

escaped_app=$(printf '%s' "$APP_DIR/tailscale-cache-cleaner-app.sh" | sed 's/ /\\ /g')
sed "s|@APP_EXEC@|$escaped_app|g" "$PROJECT_DIR/Resources/com.macvfx.tailscale-cache-cleaner.desktop.in" > "$DESKTOP_FILE"
chmod 0644 "$DESKTOP_FILE"

if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$DESKTOP_DIR" >/dev/null 2>&1 || true
fi

printf 'Installed Tailscale Cache Cleaner.\n'
printf 'Desktop entry: %s\n' "$DESKTOP_FILE"
printf 'App files: %s\n' "$APP_DIR"

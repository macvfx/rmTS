#!/bin/sh

# Minimal Linux desktop wrapper for tailscale-cache-cleaner.sh.

set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
CLEANER="$SCRIPT_DIR/tailscale-cache-cleaner.sh"

if [ ! -x "$CLEANER" ]; then
    message="Cleaner script is missing or not executable:\n$CLEANER"
    if command -v zenity >/dev/null 2>&1; then
        zenity --error --title="Tailscale Cache Cleaner" --text="$message"
    else
        printf '%b\n' "$message" >&2
    fi
    exit 1
fi

if ! command -v zenity >/dev/null 2>&1; then
    printf 'Zenity is not installed; opening the terminal workflow instead.\n'
    exec "$CLEANER" --preview
fi

preview=$("$CLEANER" --preview 2>&1) || {
    zenity --error --title="Tailscale Cache Cleaner" --text="$(printf '%s' "$preview" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')"
    exit 1
}

warning="This removes only:\n\n• /var/cache/tailscale\n• /var/lib/tailscale/tailscaled.state\n\nIt stops tailscaled, signs this device out, and resets its node identity and Tailscale IP. Use it only on the duplicate or cloned device you intend to reset.\n\nCurrent preview:\n\n$preview\n\nContinue?"

zenity --question \
    --title="Tailscale Cache Cleaner" \
    --width=620 \
    --ok-label="Authenticate and Clean" \
    --cancel-label="Cancel" \
    --text="$warning" || exit 0

if ! command -v pkexec >/dev/null 2>&1; then
    zenity --error --title="Tailscale Cache Cleaner" \
        --text="PolicyKit (pkexec) is required for administrator authorization.\n\nYou can instead run:\nsudo '$CLEANER' --apply"
    exit 1
fi

output=$(pkexec "$CLEANER" --apply --yes 2>&1) || {
    status=$?
    [ -n "$output" ] || output="Cleanup was cancelled or administrator authorization failed."
    zenity --error --title="Tailscale Cache Cleaner" --width=620 --text="$output"
    exit "$status"
}

zenity --info --title="Tailscale Cache Cleaner" --width=620 \
    --text="$output\n\nReinstall/start Tailscale and authenticate this device again."

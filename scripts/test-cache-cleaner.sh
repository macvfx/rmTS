#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
CLEANER="$SCRIPT_DIR/tailscale-cache-cleaner.sh"
FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/tailscale-cleaner-test.XXXXXX")
trap 'rm -rf "$FIXTURE"' EXIT HUP INT TERM

mkdir -p "$FIXTURE/var/cache/tailscale" "$FIXTURE/var/lib/tailscale"
printf 'cache fixture\n' > "$FIXTURE/var/cache/tailscale/cache.db"
printf 'state fixture\n' > "$FIXTURE/var/lib/tailscale/tailscaled.state"

preview=$("$CLEANER" --preview --test-root "$FIXTURE" --test-platform linux)
printf '%s\n' "$preview" | grep -q 'FOUND  /var/cache/tailscale'
printf '%s\n' "$preview" | grep -q 'FOUND  /var/lib/tailscale/tailscaled.state'
[ -f "$FIXTURE/var/cache/tailscale/cache.db" ]
[ -f "$FIXTURE/var/lib/tailscale/tailscaled.state" ]

"$CLEANER" --apply --yes --test-root "$FIXTURE" --test-platform linux >/dev/null
[ ! -e "$FIXTURE/var/cache/tailscale" ]
[ ! -e "$FIXTURE/var/lib/tailscale/tailscaled.state" ]

mkdir -p "$FIXTURE/external-cache" "$FIXTURE/var/cache" "$FIXTURE/var/lib/tailscale"
printf 'must survive\n' > "$FIXTURE/external-cache/keep.txt"
printf 'must also survive\n' > "$FIXTURE/external-state"
ln -s "$FIXTURE/external-cache" "$FIXTURE/var/cache/tailscale"
ln -s "$FIXTURE/external-state" "$FIXTURE/var/lib/tailscale/tailscaled.state"

"$CLEANER" --apply --yes --test-root "$FIXTURE" --test-platform linux >/dev/null
[ ! -L "$FIXTURE/var/cache/tailscale" ]
[ ! -L "$FIXTURE/var/lib/tailscale/tailscaled.state" ]
[ -f "$FIXTURE/external-cache/keep.txt" ]
[ -f "$FIXTURE/external-state" ]

MAC_HOME="$FIXTURE/Users/tester"
mkdir -p \
    "$MAC_HOME/Library/Containers/io.tailscale.ipn.macos" \
    "$MAC_HOME/Library/Containers/io.tailscale.ipn.macsys" \
    "$MAC_HOME/Library/Group Containers/W5364U7YZB.group.io.tailscale.ipn.macos" \
    "$MAC_HOME/Library/Application Support/Tailscale" \
    "$FIXTURE/Library/Application Support/Tailscale" \
    "$FIXTURE/Library/Tailscale" \
    "$MAC_HOME/Library/Application Support/UnrelatedApp"
printf 'keep me\n' > "$MAC_HOME/Library/Application Support/UnrelatedApp/data"

mac_preview=$("$CLEANER" --preview --test-root "$FIXTURE" --test-platform macos)
printf '%s\n' "$mac_preview" | grep -q 'FOUND  ~/Library/Containers/io.tailscale.ipn.macos'
printf '%s\n' "$mac_preview" | grep -q 'FOUND  ~/Library/Application Support/Tailscale'
printf '%s\n' "$mac_preview" | grep -q 'FOUND  /Library/Application Support/Tailscale'

"$CLEANER" --apply --yes --test-root "$FIXTURE" --test-platform macos >/dev/null
[ ! -e "$MAC_HOME/Library/Containers/io.tailscale.ipn.macos" ]
[ ! -e "$MAC_HOME/Library/Containers/io.tailscale.ipn.macsys" ]
[ ! -e "$MAC_HOME/Library/Group Containers/W5364U7YZB.group.io.tailscale.ipn.macos" ]
[ ! -e "$MAC_HOME/Library/Application Support/Tailscale" ]
[ ! -e "$FIXTURE/Library/Application Support/Tailscale" ]
[ ! -e "$FIXTURE/Library/Tailscale" ]
[ -f "$MAC_HOME/Library/Application Support/UnrelatedApp/data" ]

printf 'PASS: Linux and macOS previews were non-destructive; cleanup removed only approved targets; symlink destinations and unrelated app data survived.\n'

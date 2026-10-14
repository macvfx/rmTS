#!/bin/sh

# Tailscale cache and node-state reset utility for macOS and Linux.
# Preview is the default. Destructive cleanup requires --apply and root.

set -eu

MODE="preview"
ASSUME_YES=0
TEST_ROOT=""
TEST_PLATFORM=""

usage() {
    cat <<'EOF'
Usage: tailscale-cache-cleaner.sh [--preview] [--apply] [--yes]

Safely inspects or removes fixed Tailscale state paths for the current platform.

Options:
  --preview       Show what exists and what would be removed (default).
  --apply         Remove the listed paths after stopping/closing Tailscale.
  --yes           Skip the interactive DELETE confirmation. Root is still required.
  --help          Show this help.

macOS covers Tailscale's documented App Store and standalone support-data paths,
plus exact Application Support/Tailscale directories. Linux covers:
  /var/cache/tailscale
  /var/lib/tailscale/tailscaled.state

This is a full local identity reset, not routine cache maintenance. Reinstalling or
starting Tailscale afterward requires authentication and creates a new node identity
and Tailscale IP address.
EOF
}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --preview) MODE="preview" ;;
        --apply) MODE="apply" ;;
        --yes) ASSUME_YES=1 ;;
        --help|-h) usage; exit 0 ;;
        # Private, non-root test hooks for disposable fixture trees.
        --test-root)
            [ "$#" -ge 2 ] || fail "--test-root requires a directory"
            [ "$(id -u)" -ne 0 ] || fail "--test-root is disabled for root"
            TEST_ROOT=$2
            shift
            ;;
        --test-platform)
            [ "$#" -ge 2 ] || fail "--test-platform requires linux or macos"
            [ "$(id -u)" -ne 0 ] || fail "--test-platform is disabled for root"
            TEST_PLATFORM=$2
            shift
            ;;
        *) fail "Unknown option: $1" ;;
    esac
    shift
done

if [ -n "$TEST_ROOT" ]; then
    case "$TEST_ROOT" in
        /*) ;;
        *) fail "--test-root must be an absolute path" ;;
    esac
    [ "$TEST_ROOT" != "/" ] || fail "--test-root cannot be /"
fi

if [ -n "$TEST_PLATFORM" ] && [ -z "$TEST_ROOT" ]; then
    fail "--test-platform requires --test-root"
fi

case "$TEST_PLATFORM" in
    "")
        case "$(uname -s)" in
            Darwin) PLATFORM="macos" ;;
            Linux) PLATFORM="linux" ;;
            *) fail "Unsupported platform: $(uname -s)" ;;
        esac
        ;;
    macos|linux) PLATFORM=$TEST_PLATFORM ;;
    *) fail "--test-platform must be linux or macos" ;;
esac

rooted_path() {
    printf '%s%s\n' "$TEST_ROOT" "$1"
}

mac_user_home() {
    if [ -n "$TEST_ROOT" ]; then
        printf '%s/Users/tester\n' "$TEST_ROOT"
        return
    fi

    if [ "$(id -u)" -ne 0 ]; then
        printf '%s\n' "$HOME"
        return
    fi

    user_name=${SUDO_USER:-}
    if [ -z "$user_name" ] || [ "$user_name" = "root" ]; then
        user_name=$(/usr/bin/stat -f '%Su' /dev/console 2>/dev/null || true)
    fi
    [ -n "$user_name" ] && [ "$user_name" != "root" ] && [ "$user_name" != "loginwindow" ] || \
        fail "Could not determine the logged-in macOS user"

    user_home=$(/usr/bin/dscl . -read "/Users/$user_name" NFSHomeDirectory 2>/dev/null | \
        awk '{$1=""; sub(/^ /, ""); print}' || true)
    case "$user_home" in
        /Users/*) printf '%s\n' "$user_home" ;;
        *) fail "Unsafe or missing home directory for $user_name" ;;
    esac
}

describe_path() {
    path=$1
    display=$2
    if [ -L "$path" ]; then
        printf 'FOUND  %s (symbolic link; only the link itself will be removed)\n' "$display"
    elif [ -d "$path" ]; then
        size=$(du -sh "$path" 2>/dev/null | awk '{print $1}' || true)
        printf 'FOUND  %s (directory%s)\n' "$display" "${size:+, $size}"
    elif [ -f "$path" ]; then
        size=$(wc -c < "$path" 2>/dev/null | tr -d ' ' || true)
        printf 'FOUND  %s (file%s)\n' "$display" "${size:+, $size bytes}"
    elif [ -e "$path" ]; then
        printf 'FOUND  %s (special filesystem object)\n' "$display"
    else
        printf 'ABSENT %s\n' "$display"
    fi
}

remove_path() {
    path=$1
    if [ -L "$path" ]; then
        rm -f -- "$path"
    elif [ -d "$path" ]; then
        rm -rf -- "$path"
    elif [ -f "$path" ]; then
        rm -f -- "$path"
    elif [ -e "$path" ]; then
        fail "$path is a special filesystem object; refusing to remove it"
    fi
}

handle_path() {
    path=$1
    display=$2
    case "$ACTION" in
        describe) describe_path "$path" "$display" ;;
        remove) remove_path "$path" ;;
        verify)
            if [ -e "$path" ] || [ -L "$path" ]; then
                fail "Verification failed: $display still exists"
            fi
            ;;
    esac
}

linux_targets() {
    handle_path "$(rooted_path /var/cache/tailscale)" "/var/cache/tailscale"
    handle_path "$(rooted_path /var/lib/tailscale/tailscaled.state)" "/var/lib/tailscale/tailscaled.state"
}

mac_variant_targets() {
    bundle=$1
    home=$2
    user_label='~'

    handle_path "$home/Library/Application Scripts/$bundle" "$user_label/Library/Application Scripts/$bundle"
    handle_path "$home/Library/Application Scripts/$bundle.login-item-helper" "$user_label/Library/Application Scripts/$bundle.login-item-helper"
    handle_path "$home/Library/Application Scripts/$bundle.share-extension" "$user_label/Library/Application Scripts/$bundle.share-extension"
    handle_path "$home/Library/Caches/$bundle" "$user_label/Library/Caches/$bundle"
    handle_path "$home/Library/Containers/$bundle" "$user_label/Library/Containers/$bundle"
    handle_path "$home/Library/Containers/$bundle.login-item-helper" "$user_label/Library/Containers/$bundle.login-item-helper"
    handle_path "$home/Library/Containers/$bundle.network-extension" "$user_label/Library/Containers/$bundle.network-extension"
    handle_path "$home/Library/Containers/$bundle.share-extension" "$user_label/Library/Containers/$bundle.share-extension"
    handle_path "$home/Library/HTTPStorages/$bundle" "$user_label/Library/HTTPStorages/$bundle"
    handle_path "$home/Library/Preferences/$bundle.plist" "$user_label/Library/Preferences/$bundle.plist"

    # Tailscale documents wildcard-prefixed Application Scripts and Group Containers.
    for path in "$home/Library/Application Scripts/"*".$bundle"; do
        [ -e "$path" ] || [ -L "$path" ] || continue
        handle_path "$path" "$user_label/Library/Application Scripts/$(basename "$path")"
    done
    for path in "$home/Library/Group Containers/"*".$bundle"; do
        [ -e "$path" ] || [ -L "$path" ] || continue
        handle_path "$path" "$user_label/Library/Group Containers/$(basename "$path")"
    done
}

mac_targets() {
    home=$1
    user_label='~'
    mac_variant_targets "io.tailscale.ipn.macos" "$home"
    mac_variant_targets "io.tailscale.ipn.macsys" "$home"
    handle_path "$home/Library/Containers/Tailscale" "$user_label/Library/Containers/Tailscale"
    handle_path "$home/Library/Tailscale" "$user_label/Library/Tailscale"

    # Exact supplemental paths requested for Application Support cleanup.
    handle_path "$home/Library/Application Support/Tailscale" "$user_label/Library/Application Support/Tailscale"
    handle_path "$(rooted_path '/Library/Application Support/Tailscale')" "/Library/Application Support/Tailscale"

    # Documented standalone system state.
    handle_path "$(rooted_path /Library/Tailscale)" "/Library/Tailscale"
}

run_targets() {
    if [ "$PLATFORM" = "linux" ]; then
        linux_targets
    else
        mac_targets "$MAC_HOME"
    fi
}

if [ "$PLATFORM" = "macos" ]; then
    MAC_HOME=$(mac_user_home)
fi

printf 'Tailscale cache and local identity reset\n'
printf 'Platform: %s\n' "$PLATFORM"
printf 'Mode: %s\n\n' "$MODE"
ACTION=describe
run_targets

if [ "$MODE" = "preview" ]; then
    printf '\nPreview only. No files were changed.\n'
    printf 'Run with sudo and --apply when you are ready.\n'
    exit 0
fi

if [ -z "$TEST_ROOT" ] && [ "$(id -u)" -ne 0 ]; then
    fail "Cleanup requires administrator access. Re-run with: sudo $0 --apply"
fi

if [ "$ASSUME_YES" -ne 1 ]; then
    printf '\nWARNING: This signs the device out and resets its Tailscale identity.\n'
    printf 'Type DELETE to continue: '
    IFS= read -r confirmation
    [ "$confirmation" = "DELETE" ] || fail "Confirmation did not match; nothing changed"
fi

if [ -z "$TEST_ROOT" ] && [ "$PLATFORM" = "linux" ]; then
    if command -v systemctl >/dev/null 2>&1; then
        printf '\nStopping tailscaled...\n'
        systemctl stop tailscaled 2>/dev/null || true
    elif command -v service >/dev/null 2>&1; then
        printf '\nStopping tailscaled...\n'
        service tailscaled stop 2>/dev/null || true
    fi
    if command -v pgrep >/dev/null 2>&1 && pgrep -x tailscaled >/dev/null 2>&1; then
        fail "tailscaled is still running. Stop or uninstall it before cleanup"
    fi
fi

if [ -z "$TEST_ROOT" ] && [ "$PLATFORM" = "macos" ]; then
    if pgrep -f '/Tailscale.app/' >/dev/null 2>&1; then
        fail "Tailscale is still running. Quit and uninstall it before cleanup"
    fi
fi

printf '\nRemoving only the approved Tailscale paths...\n'
ACTION=remove
run_targets
ACTION=verify
run_targets

printf 'Cleanup complete and verified.\n'
if [ -z "$TEST_ROOT" ]; then
    if [ "$PLATFORM" = "macos" ]; then
        printf 'Review/remove the Tailscale VPN configuration and Tailscale Keychain entries manually.\n'
    fi
    printf 'Reinstall/start Tailscale and authenticate this device again.\n'
fi

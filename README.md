# rmTS — Tailscale Cache Cleaner

rmTS is a small, public-source cleanup utility for resetting a duplicated local
Tailscale identity on macOS or Linux. It was created for the recovery procedure
described in Tailscale's guide for
[multiple devices with the same 100.x IP address](https://tailscale.com/docs/reference/troubleshooting/network-configuration/multiple-devices-same-100-x-ip-address).

> [!CAUTION]
> This is a destructive identity-reset tool, not routine cache maintenance.
> Cleaning signs the selected device out of Tailscale. After reinstalling and
> authenticating, it receives a new node identity and may receive a new
> Tailscale IP address.

## What is included

- A native universal macOS app written in Swift and AppKit.
- A command-line mode built into the same macOS executable for `sudo` use.
- A portable POSIX shell cleaner for macOS and Linux.
- A minimal Zenity/PolicyKit desktop wrapper for Linux.
- Disposable fixture tests that exercise removal boundaries without touching
  live Tailscale data.

The macOS app includes an application icon, About and Quit commands, built-in
Help, a non-destructive preview, explicit confirmation, administrator
authorization, and a readable result view. `FOUND` is shown in red and `ABSENT`
in green.

## Safety boundaries

The cleaners:

- preview by default;
- operate only on a fixed allowlist of Tailscale paths;
- refuse live cleanup without administrator access;
- refuse macOS cleanup while Tailscale is running;
- remove a symbolic link itself instead of following it;
- reject unsupported filesystem objects; and
- verify that each selected target is gone after cleanup.

The tools do not remove the macOS VPN configuration or Keychain entries. Those
manual steps remain visible in the app and the [User Guide](docs/USER-GUIDE.md).

## macOS app

Requirements: macOS 12 or later and Xcode command-line build tools.

```sh
./scripts/generate-app-icon.sh
./scripts/build-macos-app.sh
open "build/Tailscale Cache Cleaner.app"
```

The output is a universal `arm64` + `x86_64` application. The local build is
ad-hoc signed. Developer ID signing and notarization are release operations and
are intentionally not embedded in the public build script.

Command-line use of the compiled app:

```sh
"build/Tailscale Cache Cleaner.app/Contents/MacOS/Tailscale Cache Cleaner" --preview
sudo "build/Tailscale Cache Cleaner.app/Contents/MacOS/Tailscale Cache Cleaner" --apply --yes
```

## Shell cleaner

Preview first:

```sh
./scripts/tailscale-cache-cleaner.sh --preview
```

Apply only after reviewing the preview and uninstalling Tailscale:

```sh
sudo ./scripts/tailscale-cache-cleaner.sh --apply
```

The script requires typing `DELETE`. Add `--yes` only for an intentionally
non-interactive run.

## Linux desktop wrapper

Requirements: Zenity and PolicyKit `pkexec`.

```sh
./scripts/install-linux-app.sh
```

The Linux cleaner covers the two recovery paths from the original request:

- `/var/cache/tailscale`
- `/var/lib/tailscale/tailscaled.state`

## Tests

```sh
./scripts/test-cache-cleaner.sh
./build/Tailscale\ Cache\ Cleaner.app/Contents/MacOS/Tailscale\ Cache\ Cleaner --self-test
```

Both tests use disposable fixture trees and preserve unrelated data.

## Documentation

- [User Guide](docs/USER-GUIDE.md)
- [Project website](https://code.matx.ca)
- [Source repository](https://github.com/macvfx/rmTS)
- [Official Tailscale duplicate-IP troubleshooting](https://tailscale.com/docs/reference/troubleshooting/network-configuration/multiple-devices-same-100-x-ip-address)
- [Official Tailscale uninstall and complete-reset guidance](https://tailscale.com/docs/features/client/uninstall)

## Project status

Version 1.1.0 (build 4). The macOS authorization bridge uses Apple's deprecated
`AuthorizationExecuteWithPrivileges` ABI through a small compiled C shim. This
keeps the utility self-contained, but it is a maintenance boundary. A future
widely distributed version should migrate to a separately installed and signed
`SMAppService` privileged helper.

This independent utility is not affiliated with or endorsed by Tailscale Inc.
Tailscale is a registered trademark of Tailscale Inc.

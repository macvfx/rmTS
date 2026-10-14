# Tailscale Cache Cleaner User Guide

Version 1.1.0 (build 4)

## Purpose

Tailscale Cache Cleaner resets local Tailscale identity data on one device. It
is intended for the duplicate-node situation that can occur when a computer or
filesystem is cloned and two devices inherit the same Tailscale configuration.
Tailscale's official recovery guidance is to uninstall and completely delete
the client on one affected system, then reinstall and authenticate it so the
system receives a new identity.

This operation signs the selected device out. It is not a general performance,
network, or cache-cleaning tool.

## Choose the correct device

Before removing anything, identify the duplicate devices in the Tailscale admin
console. Tailscale documents a **Duplicate node key** badge on the Machines
page. Choose only the cloned or replacement system whose local identity you
intend to reset.

If you are uncertain which system should keep the existing identity, stop and
resolve that decision before continuing.

## macOS app requirements

- macOS 12 or later.
- An administrator account for the cleanup step.
- Tailscale quit and uninstalled before cleanup.

The app bundle is named `Tailscale Cache Cleaner.app`. Its bundle identifier is
`com.macvfx.tailscale-cache-cleaner`.

## macOS workflow

### 1. Quit and uninstall Tailscale

Quit the Tailscale application and uninstall the installed App Store or
standalone version. The cleaner deliberately refuses to proceed if it detects a
running Tailscale app process.

### 2. Review the preview

Open Tailscale Cache Cleaner. The main window immediately performs a read-only
preview.

- **FOUND** appears in bold red. That exact path currently exists and is a
  cleanup candidate.
- **ABSENT** appears in bold green. That path is already clear.
- **Mode: preview** confirms that no files are being changed.

Choose **Refresh Preview** after uninstalling Tailscale or changing anything
outside the app.

### 3. Authenticate and clean

Choose **Authenticate and Clean**, read the destructive-operation warning, and
confirm only if the displayed device is the one you intend to reset. Approve
the macOS administrator prompt.

The compiled Swift executable performs the cleanup itself. The app does not run
the repository's shell script. When invoked through the GUI, it launches its own
signed executable in privileged cleanup mode.

### 4. Complete the manual macOS steps

The app intentionally does not automate these system-level review steps:

1. Open **System Settings > Network > VPN**.
2. Remove the Tailscale VPN configuration if it remains.
3. Open **Keychain Access** and search for `tailscale`.
4. Review and remove remaining Tailscale entries, including machine-key,
   log-data, or preference entries documented by Tailscale.

### 5. Reinstall and verify

Reinstall Tailscale from the intended distribution, authenticate the device,
and verify it in the Machines page of the Tailscale admin console. Confirm that
the duplicate-node warning is resolved and that the device has the expected new
identity and address.

## Application menu

The **Tailscale Cache Cleaner** menu contains:

- **About Tailscale Cache Cleaner** — displays the app icon, version, build,
  [project website](https://code.matx.ca), and
  [public source repository](https://github.com/macvfx/rmTS).
- Standard macOS Services, Hide, and Show commands.
- **Quit Tailscale Cache Cleaner** (`Command-Q`).

The **Help** menu opens the built-in operating and safety guidance, with links
to the project website and public source repository.

## Command-line use of the macOS app

The same compiled executable supports a read-only preview:

```sh
"Tailscale Cache Cleaner.app/Contents/MacOS/Tailscale Cache Cleaner" --preview
```

It can also be invoked directly with `sudo`:

```sh
sudo "Tailscale Cache Cleaner.app/Contents/MacOS/Tailscale Cache Cleaner" --apply --yes
```

The `--yes` flag is required for compiled command-line cleanup. Without root
access, the executable exits without changing files.

## Shell-script workflow

The portable cleaner previews by default:

```sh
./scripts/tailscale-cache-cleaner.sh --preview
```

After reviewing the result:

```sh
sudo ./scripts/tailscale-cache-cleaner.sh --apply
```

Type `DELETE` when prompted. The shell script prints every fixed target before
confirmation and verifies deletion afterward.

## Linux behavior

On Linux, the cleaner targets only:

- `/var/cache/tailscale`
- `/var/lib/tailscale/tailscaled.state`

When applying a live cleanup, it attempts to stop `tailscaled` using `systemctl`
or `service`, then refuses to continue if the daemon is still running. The
optional Linux desktop wrapper uses Zenity for dialogs and PolicyKit `pkexec`
for administrator authorization.

## What the macOS cleaner targets

The macOS app and shell cleaner use fixed paths for the App Store bundle
identifier `io.tailscale.ipn.macos`, the standalone identifier
`io.tailscale.ipn.macsys`, documented suffix-matching Application Scripts and
Group Containers, and exact Tailscale support folders under the user's Library
and `/Library`.

The tools do not perform a broad filename search. An unrelated folder is not
removed merely because its contents mention Tailscale.

## Errors and holds

### Tailscale is still running

Quit and uninstall Tailscale, then choose **Refresh Preview**. Cleanup remains
blocked while the app process is detected.

### Administrator authorization was cancelled

Nothing is removed. Start again only when you are ready to authorize the exact
previewed operation.

### Unsupported filesystem object

The cleaner stops rather than removing a device, socket, or other special
filesystem object from an approved path. Inspect that path manually before
deciding what to do.

### Verification failed

The cleaner detected that an intended target still exists after the removal
attempt. Do not assume the identity reset is complete. Review permissions and
the reported path, then preview again.

## Privacy

The app does not collect, upload, or transmit cleanup results. Preview and
cleanup happen locally. Administrator authorization is requested through macOS.
The repository contains no authentication tokens or Tailscale account data.

Tailscale itself has its own product telemetry and privacy behavior; consult
Tailscale's documentation for those details.

## References

- [Project website](https://code.matx.ca)
- [Source repository](https://github.com/macvfx/rmTS)
- [Troubleshoot multiple devices with the same 100.x IP address](https://tailscale.com/docs/reference/troubleshooting/network-configuration/multiple-devices-same-100-x-ip-address)
- [Uninstall Tailscale](https://tailscale.com/docs/features/client/uninstall)
- [Install Tailscale](https://tailscale.com/docs/install)

This independent utility is not affiliated with or endorsed by Tailscale Inc.
Tailscale is a registered trademark of Tailscale Inc.

# Codex Credential Export for Headless Machines

This project provides portable, OS-specific scripts to export Codex CLI authentication data from a machine that can complete the browser login flow and restore it on a headless or remote host. The original one-off Linux script from [chuvadenovembro/script-to-use-codex-cli-on-remote-server-without-visual-environment](https://github.com/chuvadenovembro/script-to-use-codex-cli-on-remote-server-without-visual-environment) was generalized for macOS, Linux, and Windows with consistent behaviour and documentation.

> ⚠️ **Security warning:** The exported bundle contains your Codex credentials. Treat it like a password manager backup: move it only over secure channels (SSH, SFTP, USB that you control) and delete it immediately after import.

## Contents

- [`scripts/linux/codex-auth-transfer.sh`](scripts/linux/codex-auth-transfer.sh) – Bash entry point for Linux systems.
- [`scripts/macos/codex-auth-transfer.sh`](scripts/macos/codex-auth-transfer.sh) – Bash entry point tuned for macOS paths.
- [`scripts/windows/CodexAuthTransfer.ps1`](scripts/windows/CodexAuthTransfer.ps1) – PowerShell entry point for Windows hosts.
- [`scripts/shared/codex_auth_transfer.sh`](scripts/shared/codex_auth_transfer.sh) – Shared implementation used by the Unix scripts.

All scripts generate the same archive layout so you can export on one platform and import on another.

## What the scripts do

1. **Detect Codex credential directories** using default Codex locations and `codex config path` when available.
2. **Stage the data** in a temporary directory with restrictive permissions and write a manifest that records when the bundle was created.
3. **Archive the staged files** to `codex-auth-bundle.tar.gz` (or a custom path) and set the resulting file to user-only access.
4. **Restore bundles** on the target machine, optionally backing up any existing Codex data with a `.bak-YYYYmmdd-HHMMSS` suffix when `--force`/`-Force` is supplied.

If a credential path lives outside the exporting user’s home directory it is added to the bundle under `.codex-external/<hash>` so nothing leaks about the original absolute path.

## Prerequisites

| Platform | Requirements |
| --- | --- |
| Linux | Bash 4+, `tar`, and optionally `rsync` (for faster copies). |
| macOS | Bash (the system `/bin/bash` works), `tar`, and optionally `rsync`. |
| Windows | PowerShell 5.1 or later, `tar.exe` (ships with Windows 10 build 17063+), and `robocopy` (included with Windows). |

Ensure the Codex CLI is installed and signed in on the source machine. The target machine only needs the CLI installed; the scripts copy the credential files.

## Usage overview

1. **Export on a machine with browser access.**
2. **Transfer the generated `codex-auth-bundle.tar.gz`** to the target machine over a secure channel.
3. **Import on the headless/remote machine.**
4. **Remove the bundle from both machines** once the CLI works.

### Linux

```bash
# Source machine (already logged into Codex CLI)
chmod +x scripts/linux/codex-auth-transfer.sh
./scripts/linux/codex-auth-transfer.sh export

# Target machine
chmod +x scripts/linux/codex-auth-transfer.sh
./scripts/linux/codex-auth-transfer.sh import --force
```

Use `--force` when you want existing Codex directories to be backed up and replaced. Supply a custom archive name with `--output <path>` or `--file <path>` as needed.

### macOS

```bash
# Source machine
chmod +x scripts/macos/codex-auth-transfer.sh
./scripts/macos/codex-auth-transfer.sh export --output ~/Desktop/codex-auth-bundle.tar.gz

# Target machine
chmod +x scripts/macos/codex-auth-transfer.sh
./scripts/macos/codex-auth-transfer.sh import --file ~/codex-auth-bundle.tar.gz --force
```

The macOS script searches both standard Unix locations (`~/.config/codex`, `~/.codex`) and macOS-specific application support folders under `~/Library/Application Support`.

### Windows

```powershell
# Source machine (PowerShell)
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\scripts\windows\CodexAuthTransfer.ps1 export -Output C:\Users\me\Desktop\codex-auth-bundle.tar.gz

# Target machine (PowerShell, bundle copied in advance)
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\scripts\windows\CodexAuthTransfer.ps1 import -File C:\Users\me\Downloads\codex-auth-bundle.tar.gz -Force
```

The PowerShell script requires `tar.exe` in `PATH`. On modern Windows 10/11 installations it is preinstalled. If `tar.exe` is missing, install the “Windows Subsystem for Linux” feature or the free [bsdtar](https://github.com/libarchive/libarchive/releases) binary and add it to your `%PATH%`.

### Optional flags

- `CODEX_AUTH_TRANSFER_NO_METADATA=1` (Linux/macOS) or `-NoMetadata` (Windows) skips recording the `user=` and `host=` fields in the manifest.
- `--output`/`-Output` chooses a different bundle destination.
- `--file`/`-File` selects a different bundle when importing.
- `--force`/`-Force` backs up and overwrites existing credential folders on the target machine.

## Post-import checks

After importing:

1. Run `codex whoami` or another harmless CLI command to confirm the credentials work.
2. Delete the transferred bundle from all machines (`shred -u` on Linux, `srm` on macOS if available, or `Remove-Item` in PowerShell).
3. Remove any `.bak-*` backups if the new credentials work and you no longer need the old ones.

## Troubleshooting

- **`No Codex credential directories were found.`** Ensure you have signed in with `codex login` on the source machine and rerun the export.
- **Import fails because destinations exist.** Re-run the import with `--force`/`-Force`. The scripts safely move the old directories to `<path>.bak-YYYYmmdd-HHMMSS` before replacing them.
- **Codex refuses the restored credentials.** Some tokens are host-specific. Use a secure tunnel (e.g., SSH port forwarding) or the CLI’s device code login on the remote machine instead.
- **Windows complains about execution policy.** Use `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` in the session or sign the script with a trusted certificate.

## Development notes

- The Unix scripts share the implementation in [`scripts/shared/codex_auth_transfer.sh`](scripts/shared/codex_auth_transfer.sh) to keep behaviour identical between Linux and macOS.
- `rsync` is preferred when available because it preserves permissions efficiently. When `rsync` is absent the scripts fall back to `cp -a` (Unix) or `Copy-Item` (Windows).
- Archives are always gzip-compressed tarballs so you can export on one operating system and import on another without conversion.

## License

Apache License 2.0. See [LICENSE](LICENSE) for details.

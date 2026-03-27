# vault-backup

A simple, portable tool for creating encrypted backups. Compresses a directory and encrypts it with AES-256-CBC using OpenSSL. Recoverable on any machine.

## Quick Start

```bash
# 1. Clone the repo
git clone git@github.com:conquext/vault-backup.git && cd vault-backup

# 2. Copy and edit the config
cp vault-backup.conf.example vault-backup.conf
chmod 600 vault-backup.conf
# Edit vault-backup.conf — set SOURCE_DIR to the directory you want to back up

# 3. Run it
./vault-backup.sh
```

## Usage

```
vault-backup.sh [options] [config-file]
vault-backup.sh restore <file.enc> [--to <dir>]
vault-backup.sh collect <pattern> --from <dir> [--to <dir>]
vault-backup.sh verify <file.enc>
vault-backup.sh install-cron [schedule]
```

### Options

| Flag | Description |
|---|---|
| `--config <file>` | Path to config file |
| `--dry-run` | Show what would be backed up without creating a backup |
| `--all` | Run all profiles in PROFILES_DIR |
| `--help`, `-h` | Show help message |
| `--version`, `-v` | Show version |

### Examples

```bash
./vault-backup.sh                              # Use default config
./vault-backup.sh vault-backup.conf            # Specify config file
./vault-backup.sh --dry-run                    # Preview backup
./vault-backup.sh --all                        # Run all profiles
./vault-backup.sh restore backup.enc           # Restore to current dir
./vault-backup.sh restore backup.enc --to ~/restored
./vault-backup.sh collect '*.env' --from ~/projects
./vault-backup.sh collect '*.env' --from ~/projects --to ~/backups
./vault-backup.sh verify backup.enc            # Verify checksum
./vault-backup.sh install-cron                 # Default: 0 2 * * *
./vault-backup.sh install-cron "0 3 * * 0"    # Custom schedule
```

## Configuration

Edit `vault-backup.conf`:

| Variable | Required | Default | Description |
|---|---|---|---|
| `SOURCE_DIR` | Yes | — | Absolute path to the directory to back up |
| `OUTPUT_DIR` | No | `~/Downloads` | Where to save the encrypted file |
| `INCLUDE_PATTERNS` | No | `()` | Array of `find -name` patterns. Only matching files are backed up |
| `EXCLUDE_PATTERNS` | No | `()` | Array of tar `--exclude` patterns |
| `PASSPHRASE` | No | — | Leave empty to be prompted interactively |
| `UPLOAD_REMOTE` | No | `""` | rclone remote + path (e.g., `s3:bucket/backups`) |
| `RETENTION_COUNT` | No | `0` | Local backups to keep. 0 = keep all |
| `NOTIFY_URL` | No | `""` | Webhook URL for POST notifications |
| `NOTIFY_ON` | No | `"always"` | When to notify: `always`, `success`, `failure` |
| `PROFILES_DIR` | No | `""` | Directory of `.conf` files for `--all` |

### Exclude Patterns

```bash
EXCLUDE_PATTERNS=(
    ".DS_Store"
    "*.log"
    ".git"
    "node_modules"
    "__pycache__"
)
```

### Include Patterns

Selectively back up only files matching specific patterns:

```bash
INCLUDE_PATTERNS=(
    "*.env"
    ".env.local"
    "*.pem"
)
```

When `INCLUDE_PATTERNS` is set, only matching files within `SOURCE_DIR` are backed up. `EXCLUDE_PATTERNS` are applied on top to further filter. When empty (default), the entire directory is backed up.

## Collect

One-off selective backup by pattern — no config file needed:

```bash
# Collect all .env files from a project tree
./vault-backup.sh collect '*.env' --from ~/projects

# Specify output directory
./vault-backup.sh collect '*.env' --from ~/projects --to ~/backups

# Scripted (pipe passphrase)
echo "pass" | ./vault-backup.sh collect '*.env' --from ~/projects
```

Creates a `vault-collect-<timestamp>.tar.gz.enc` file with matched files preserving their path structure. A `.sha256` checksum is also created. Restore with the standard `restore` command.

## Restore

Restore an encrypted backup to a directory:

```bash
# Restore to current directory
./vault-backup.sh restore vault-backup-2026-03-23-143022.tar.gz.enc

# Restore to a specific directory
./vault-backup.sh restore vault-backup-2026-03-23-143022.tar.gz.enc --to ~/restored

# Scripted (pipe passphrase)
echo "mypassphrase" | ./vault-backup.sh restore backup.enc --to ~/restored
```

You can also decrypt manually without the tool:

```bash
openssl enc -d -aes-256-cbc -salt -pbkdf2 -iter 600000 -md sha256 \
  -in vault-backup-2026-03-23-143022.tar.gz.enc \
  -out vault-backup-2026-03-23-143022.tar.gz
tar xzf vault-backup-2026-03-23-143022.tar.gz
```

On Windows, use Git Bash or WSL.

## Verify

Each backup creates a `.sha256` checksum file. Verify integrity at any time:

```bash
./vault-backup.sh verify vault-backup-2026-03-23-143022.tar.gz.enc
```

This compares the stored hash against the file's current hash and reports any tampering or corruption.

## Upload

Upload backups to a remote destination using [rclone](https://rclone.org/):

```bash
# In vault-backup.conf
UPLOAD_REMOTE="s3:my-bucket/backups"
```

Both the `.enc` file and its `.sha256` checksum are uploaded. Requires rclone to be installed and configured. If rclone is not available, the backup still succeeds locally with a warning.

## Rotation

Automatically delete old local backups, keeping only the most recent N:

```bash
# In vault-backup.conf
RETENTION_COUNT=7    # Keep last 7 backups
```

Rotation runs after each backup. Companion `.sha256` files are also removed. Set to `0` to keep all backups (default).

## Notifications

Send a webhook notification after each backup:

```bash
# In vault-backup.conf
NOTIFY_URL="https://hooks.slack.com/services/T.../B.../xxx"
NOTIFY_ON="always"    # or "success" or "failure"
```

Sends a POST request with JSON:

```json
{
  "status": "success",
  "filename": "vault-backup-2026-03-23-143022.tar.gz.enc",
  "size": "1234567",
  "timestamp": "2026-03-23T14:30:22Z",
  "details": ""
}
```

Works with Slack, Discord, ntfy.sh, or any webhook endpoint.

## Profiles

Run multiple backup configurations with a single command:

```bash
# In vault-backup.conf
PROFILES_DIR="$HOME/.config/vault-backup/profiles"
```

Create one `.conf` file per backup target in the profiles directory. Each profile has its own `SOURCE_DIR`, `OUTPUT_DIR`, passphrase, upload, rotation, and notification settings.

```bash
# Run all profiles
./vault-backup.sh --all

# Each profile runs in isolation — failures in one don't stop others
```

## Cron

Schedule automated backups:

```bash
# Install with default schedule (daily at 2 AM)
./vault-backup.sh install-cron

# Custom schedule
./vault-backup.sh install-cron "0 3 * * 0"    # Weekly on Sunday at 3 AM
```

Requires `PASSPHRASE` to be set in the config file (no interactive prompt in cron). The tool checks for existing vault-backup cron entries to prevent duplicates.

## Dry Run

Preview what would be backed up without creating any files:

```bash
./vault-backup.sh --dry-run
```

Shows source directory, file count, estimated size, output filename, and configured upload destination. No passphrase is required.

## Encryption Details

- **Algorithm:** AES-256-CBC
- **Key Derivation:** PBKDF2 with 600,000 iterations
- **Salt:** Always enabled
- **Tool:** OpenSSL (pre-installed on macOS and most Linux distributions)

No special software, keys, or certificates needed for recovery — just OpenSSL and your passphrase.

## Requirements

- Bash 4+
- OpenSSL 1.1.1+ or LibreSSL 3.1.0+
- tar
- rclone (optional, for uploads)
- curl (optional, for notifications)

## Running Tests

```bash
tests/test-vault-backup.sh
```

## License

MIT

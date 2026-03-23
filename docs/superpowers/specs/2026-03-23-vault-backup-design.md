# vault-backup Design Spec

**Date:** 2026-03-23
**Status:** Draft

## Purpose

A single-file bash tool that compresses and encrypts a directory into a portable backup file. Designed for personal use on macOS/Linux, with recovery possible on any machine that has `openssl` and `tar`. Will be open-sourced.

## Non-Goals

- Upload to remote storage (future work)
- Incremental/differential backups
- Scheduling (users can wire this into cron themselves)
- GUI or interactive TUI

## Project Structure

```
vault-backup/
├── vault-backup.sh            # Main script (executable)
├── vault-backup.conf.example  # Example config (committed, no secrets)
├── .gitignore                 # Ignores vault-backup.conf, *.enc
├── LICENSE                    # MIT
└── README.md                  # Usage, decrypt instructions, config reference
```

## Config File

`vault-backup.conf` — a bash-sourceable file, gitignored:

```bash
# Directory to back up (required)
SOURCE_DIR="$HOME/.backup_directory"

# Output directory for encrypted backups (default: ~/Downloads)
OUTPUT_DIR="$HOME/Downloads"

# Exclude patterns (one per line, tar --exclude format)
EXCLUDE_PATTERNS=(
    ".DS_Store"
    "*.log"
)

# Passphrase for encryption (leave empty to be prompted interactively)
PASSPHRASE=""
```

An example file `vault-backup.conf.example` is committed to the repo with sensible defaults and documentation comments. Users copy it to `vault-backup.conf` and customize.

## Core Flow

1. **Load config** — source `vault-backup.conf` from the script's directory, or from a path passed as the first argument.
2. **Validate** — check that `SOURCE_DIR` exists, `OUTPUT_DIR` exists, `openssl` is available (must support `-pbkdf2`, i.e., OpenSSL 1.1.1+ or LibreSSL 3.1.0+), and `tar` is available. Also check config file permissions — warn to stderr if `vault-backup.conf` is group/world-readable.
3. **Passphrase** — if `PASSPHRASE` is empty in config:
   - Check that stdin is a terminal (`[[ -t 0 ]]`); if not, exit with an error explaining that a passphrase must be provided in config for non-interactive use.
   - Prompt with `read -s` twice (entry + confirmation). Reject if they don't match. Reject if empty.
   - The passphrase never appears in terminal history or process listings.
4. **Build exclude args** — map `EXCLUDE_PATTERNS` array to tar flags:
   ```bash
   EXCLUDE_ARGS=()
   for pattern in "${EXCLUDE_PATTERNS[@]}"; do
     EXCLUDE_ARGS+=(--exclude="$pattern")
   done
   ```
5. **Compress + Encrypt** — pipe `tar cz` (with excludes) directly into `openssl enc`, writing to the output file. No unencrypted intermediate files touch disk. The passphrase is passed via file descriptor 3 (`-pass fd:3 3<<<"$PASSPHRASE"`), keeping stdin free for the tar pipe and the passphrase invisible in `ps` output. Archive contains directory contents only (`tar cz -C "$SOURCE_DIR" .`), not the full path.
   ```bash
   tar cz "${EXCLUDE_ARGS[@]}" -C "$SOURCE_DIR" . \
     | openssl enc -aes-256-cbc -salt -pbkdf2 -iter 600000 \
         -pass fd:3 3<<<"$PASSPHRASE" \
         -out "$OUTPUT_FILE"
   ```
6. **Summary** — print file path, size, and the exact decrypt command.

## Encryption

- **Algorithm:** AES-256-CBC via `openssl enc`
- **Key derivation:** PBKDF2 with 600,000 iterations (`-pbkdf2 -iter 600000`)
- **Salt:** Always enabled (`-salt`), ensures unique ciphertext even with same passphrase and data
- **Command:** `openssl enc -aes-256-cbc -salt -pbkdf2 -iter 600000`

### Recovery

Decryption requires only `openssl` 1.1.1+ (pre-installed on macOS, available on every Linux distro, available on Windows via Git Bash or WSL):

```bash
openssl enc -d -aes-256-cbc -salt -pbkdf2 -iter 600000 \
  -in vault-backup-2026-03-23-143022.tar.gz.enc \
  -out vault-backup-2026-03-23-143022.tar.gz
tar xzf vault-backup-2026-03-23-143022.tar.gz
```

No special software, keys, or certificates needed — just the passphrase.

## Output

- **Filename:** `vault-backup-YYYY-MM-DD-HHMMSS.tar.gz.enc`
- **Location:** `OUTPUT_DIR` (defaults to `~/Downloads`)

## Script Interface

```bash
# Default: looks for vault-backup.conf in same directory as script
./vault-backup.sh

# Specify a config file
./vault-backup.sh /path/to/vault-backup.conf
```

No subcommands or flags beyond the optional config path.

### Terminal Output

```
vault-backup v1.0.0
─────────────────────
Source:    /Users/apple/.backup_directory
Output:    /Users/apple/Downloads
Excludes:  .DS_Store, *.log

Enter passphrase:
Confirm passphrase:

Backing up...
Done! vault-backup-2026-03-23-143022.tar.gz.enc (12.4 MB)
Saved to: /Users/apple/Downloads/vault-backup-2026-03-23-143022.tar.gz.enc

To decrypt:
  openssl enc -d -aes-256-cbc -salt -pbkdf2 -iter 600000 \
    -in vault-backup-2026-03-23-143022.tar.gz.enc \
    -out vault-backup-2026-03-23-143022.tar.gz
  tar xzf vault-backup-2026-03-23-143022.tar.gz
```

## Error Handling

- `set -euo pipefail` at the top of the script
- Validate all prerequisites before starting the backup
- `trap cleanup EXIT` to handle all exit paths; the cleanup function checks whether the backup completed successfully and deletes the partial output file if not
- Non-zero exit codes with descriptive error messages to stderr

## Security Considerations

- Passphrase never in terminal history (not a CLI argument)
- Passphrase passed to openssl via `-pass fd:3` using a here-string on file descriptor 3 — keeps stdin free for the tar pipe and is not visible in `ps` output
- No unencrypted temp files — tar pipes directly to openssl
- Script warns at startup if config file permissions are too open (group/world-readable)
- Empty passphrases are rejected
- `.gitignore` excludes `vault-backup.conf` and `*.enc` files
- **Minimum openssl version:** 1.1.1 (for `-pbkdf2` support); the validation step checks this

## Future Extensions (Not In Scope)

- Upload to S3, R2, Google Drive, VPS via scp/rsync
- Backup rotation / retention policy
- Integrity verification (checksum file alongside backup)
- Notification on success/failure

# vault-backup

A simple, portable tool for creating encrypted backups. Compresses a directory and encrypts it with AES-256-CBC using OpenSSL. Recoverable on any machine.

## Quick Start

```bash
# 1. Clone the repo
git clone <url> && cd vault-backup

# 2. Copy and edit the config
cp vault-backup.conf.example vault-backup.conf
chmod 600 vault-backup.conf
# Edit vault-backup.conf — set SOURCE_DIR to the directory you want to back up

# 3. Run it
./vault-backup.sh
```

## Configuration

Edit `vault-backup.conf`:

| Variable | Required | Description |
|---|---|---|
| `SOURCE_DIR` | Yes | Absolute path to the directory to back up |
| `OUTPUT_DIR` | No | Where to save the encrypted file (default: `~/Downloads`) |
| `EXCLUDE_PATTERNS` | No | Array of tar `--exclude` patterns |
| `PASSPHRASE` | No | Leave empty to be prompted interactively |

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

## Recovering Your Files

You need: `openssl` (1.1.1+) and `tar` — both pre-installed on macOS and Linux.

```bash
# Decrypt
openssl enc -d -aes-256-cbc -salt -pbkdf2 -iter 600000 -md sha256 \
  -in vault-backup-2026-03-23-143022.tar.gz.enc \
  -out vault-backup-2026-03-23-143022.tar.gz

# Extract
tar xzf vault-backup-2026-03-23-143022.tar.gz
```

On Windows, use Git Bash or WSL.

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

## Running Tests

```bash
tests/test-vault-backup.sh
```

## License

MIT

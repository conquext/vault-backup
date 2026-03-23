# vault-backup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a single-file bash tool that compresses and encrypts a directory into a portable, recoverable backup file.

**Architecture:** Single bash script (`vault-backup.sh`) with a bash-sourceable config file. Uses `tar` for compression and `openssl enc` for AES-256-CBC encryption with PBKDF2 key derivation. Passphrase passed via fd:3 to avoid stdin conflicts with tar pipe.

**Tech Stack:** Bash, tar, openssl, standard POSIX utilities

**Spec:** `docs/superpowers/specs/2026-03-23-vault-backup-design.md`

---

## File Structure

| File | Responsibility |
|---|---|
| `vault-backup.sh` | Main script: config loading, validation, passphrase handling, backup pipeline, summary output |
| `vault-backup.conf.example` | Documented example config (committed to repo) |
| `.gitignore` | Excludes `vault-backup.conf`, `*.enc`, test artifacts |
| `LICENSE` | MIT license |
| `README.md` | Usage, config reference, decrypt instructions, recovery guide |
| `tests/test-vault-backup.sh` | Integration test script: round-trip encrypt/decrypt, validation checks, error cases |

---

### Task 1: Project Scaffolding

**Files:**
- Create: `.gitignore`
- Create: `LICENSE`
- Create: `vault-backup.conf.example`

- [ ] **Step 1: Create .gitignore**

```gitignore
# User config (may contain passphrase)
vault-backup.conf

# Encrypted backup files
*.enc

# Test artifacts
tests/tmp/
```

- [ ] **Step 2: Create MIT LICENSE**

Standard MIT license with year 2026.

- [ ] **Step 3: Create vault-backup.conf.example**

```bash
#!/usr/bin/env bash
# vault-backup configuration
# Copy this file to vault-backup.conf and customize.
# IMPORTANT: vault-backup.conf is gitignored — do not commit it.

# Directory to back up (required, absolute path)
SOURCE_DIR="$HOME/.backup_directory"

# Output directory for encrypted backups (default: ~/Downloads)
OUTPUT_DIR="$HOME/Downloads"

# Exclude patterns (tar --exclude format)
# Add one pattern per line. Common examples:
#   ".DS_Store"    — macOS metadata files
#   "*.log"        — log files
#   ".git"         — git repositories
#   "node_modules" — npm dependencies
#   "__pycache__"  — Python cache
EXCLUDE_PATTERNS=(
    ".DS_Store"
)

# Passphrase for encryption.
# Leave empty to be prompted interactively (recommended).
# Set a value here only for automated/cron usage.
PASSPHRASE=""
```

- [ ] **Step 4: Commit**

```bash
git add .gitignore LICENSE vault-backup.conf.example
git commit -m "chore: add project scaffolding"
```

---

### Task 2: Test Framework and First Test

**Files:**
- Create: `tests/test-vault-backup.sh`

- [ ] **Step 1: Create test script with helpers and first test**

The test script is a plain bash integration test runner — no external dependencies. It creates temp directories, runs vault-backup.sh, and asserts outcomes.

```bash
#!/usr/bin/env bash
set -euo pipefail

# ── Test Framework ──────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VAULT_BACKUP="$PROJECT_DIR/vault-backup.sh"
TEST_TMP="$SCRIPT_DIR/tmp"
PASS_COUNT=0
FAIL_COUNT=0

setup() {
  rm -rf "$TEST_TMP"
  mkdir -p "$TEST_TMP/source" "$TEST_TMP/output" "$TEST_TMP/restore"
}

teardown() {
  rm -rf "$TEST_TMP"
}

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf "  PASS: %s\n" "$1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf "  FAIL: %s\n" "$1" >&2
  if [[ -n "${2:-}" ]]; then
    printf "        %s\n" "$2" >&2
  fi
}

write_config() {
  local passphrase="${1:-testpassword123}"
  cat > "$TEST_TMP/vault-backup.conf" <<CONF
SOURCE_DIR="$TEST_TMP/source"
OUTPUT_DIR="$TEST_TMP/output"
EXCLUDE_PATTERNS=()
PASSPHRASE="$passphrase"
CONF
  chmod 600 "$TEST_TMP/vault-backup.conf"
}

summary() {
  echo ""
  echo "──────────────────────────────"
  echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
  echo "──────────────────────────────"
  [[ $FAIL_COUNT -eq 0 ]]
}

# ── Tests ───────────────────────────────────────────────────────

test_script_exists() {
  echo "TEST: script exists and is executable"
  if [[ -x "$VAULT_BACKUP" ]]; then
    pass "vault-backup.sh exists and is executable"
  else
    fail "vault-backup.sh missing or not executable"
  fi
}

# ── Run ─────────────────────────────────────────────────────────
echo "vault-backup integration tests"
echo "══════════════════════════════"
setup
test_script_exists
teardown
summary
```

- [ ] **Step 2: Make test script executable and run it**

Run: `chmod +x tests/test-vault-backup.sh && tests/test-vault-backup.sh`
Expected: FAIL — vault-backup.sh does not exist yet.

- [ ] **Step 3: Commit**

```bash
git add tests/test-vault-backup.sh
git commit -m "test: add integration test framework with first failing test"
```

---

### Task 3: Script Skeleton — Config Loading

**Files:**
- Create: `vault-backup.sh`

- [ ] **Step 1: Create vault-backup.sh with shebang, flags, version, and config loading**

```bash
#!/usr/bin/env bash
set -euo pipefail

VERSION="1.0.0"

# ── Helpers ─────────────────────────────────────────────────────

die() {
  printf "ERROR: %s\n" "$1" >&2
  exit 1
}

warn() {
  printf "WARNING: %s\n" "$1" >&2
}

# ── Config Loading ──────────────────────────────────────────────

load_config() {
  local config_path="$1"

  [[ -f "$config_path" ]] || die "Config file not found: $config_path"

  # Warn if config is group/world-readable (may contain passphrase)
  if [[ "$(uname)" == "Darwin" ]]; then
    local perms
    perms=$(stat -f "%Lp" "$config_path")
    if [[ "$perms" != "600" && "$perms" != "400" ]]; then
      warn "Config file is readable by others (mode $perms). Consider: chmod 600 $config_path"
    fi
  else
    local perms
    perms=$(stat -c '%a' "$config_path")
    if [[ "$perms" != "600" && "$perms" != "400" ]]; then
      warn "Config file is readable by others (mode $perms). Consider: chmod 600 $config_path"
    fi
  fi

  # Source the config — intentionally executes bash for variable expansion
  # shellcheck source=/dev/null
  source "$config_path"

  # Defaults
  OUTPUT_DIR="${OUTPUT_DIR:-$HOME/Downloads}"
  if [[ -z "${EXCLUDE_PATTERNS+x}" ]]; then
    EXCLUDE_PATTERNS=()
  fi
  PASSPHRASE="${PASSPHRASE:-}"
}

# ── Resolve config path ────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -gt 0 ]]; then
  CONFIG_PATH="$1"
else
  CONFIG_PATH="$SCRIPT_DIR/vault-backup.conf"
fi

load_config "$CONFIG_PATH"
```

- [ ] **Step 2: Make executable**

Run: `chmod +x vault-backup.sh`

- [ ] **Step 3: Run tests**

Run: `tests/test-vault-backup.sh`
Expected: PASS — script exists and is executable.

- [ ] **Step 4: Commit**

```bash
git add vault-backup.sh
git commit -m "feat: add script skeleton with config loading"
```

---

### Task 4: Validation Functions

**Files:**
- Modify: `vault-backup.sh`
- Modify: `tests/test-vault-backup.sh`

- [ ] **Step 1: Add validation tests to test script**

Add these tests to `tests/test-vault-backup.sh` before the `# ── Run` section:

```bash
test_missing_config() {
  echo "TEST: exits with error on missing config"
  local output
  if output=$("$VAULT_BACKUP" /nonexistent/path 2>&1); then
    fail "should have exited non-zero"
  else
    if echo "$output" | grep -q "Config file not found"; then
      pass "exits with config not found error"
    else
      fail "wrong error message" "$output"
    fi
  fi
}

test_missing_source_dir() {
  echo "TEST: exits with error on missing source directory"
  cat > "$TEST_TMP/vault-backup.conf" <<CONF
SOURCE_DIR="/nonexistent/dir"
OUTPUT_DIR="$TEST_TMP/output"
EXCLUDE_PATTERNS=()
PASSPHRASE="test"
CONF
  chmod 600 "$TEST_TMP/vault-backup.conf"
  local output
  if output=$("$VAULT_BACKUP" "$TEST_TMP/vault-backup.conf" 2>&1); then
    fail "should have exited non-zero"
  else
    if echo "$output" | grep -q "Source directory"; then
      pass "exits with source directory error"
    else
      fail "wrong error message" "$output"
    fi
  fi
}

test_missing_output_dir() {
  echo "TEST: exits with error on missing output directory"
  cat > "$TEST_TMP/vault-backup.conf" <<CONF
SOURCE_DIR="$TEST_TMP/source"
OUTPUT_DIR="/nonexistent/output"
EXCLUDE_PATTERNS=()
PASSPHRASE="test"
CONF
  chmod 600 "$TEST_TMP/vault-backup.conf"
  local output
  if output=$("$VAULT_BACKUP" "$TEST_TMP/vault-backup.conf" 2>&1); then
    fail "should have exited non-zero"
  else
    if echo "$output" | grep -q "Output directory"; then
      pass "exits with output directory error"
    else
      fail "wrong error message" "$output"
    fi
  fi
}
```

Add to the Run section:

```bash
test_missing_config
test_missing_source_dir
test_missing_output_dir
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `tests/test-vault-backup.sh`
Expected: FAIL — validation functions not yet implemented.

- [ ] **Step 3: Add validate function to vault-backup.sh**

Add after `load_config` function:

```bash
# ── Validation ──────────────────────────────────────────────────

validate() {
  [[ -d "$SOURCE_DIR" ]] || die "Source directory does not exist: $SOURCE_DIR"
  [[ -d "$OUTPUT_DIR" ]] || die "Output directory does not exist: $OUTPUT_DIR"

  command -v openssl >/dev/null 2>&1 || die "openssl is not installed"
  command -v tar >/dev/null 2>&1 || die "tar is not installed"

  # Check openssl supports -pbkdf2
  if ! openssl enc -aes-256-cbc -pbkdf2 -iter 1 -pass pass:test -e -in /dev/null -out /dev/null 2>/dev/null; then
    die "openssl does not support -pbkdf2. Requires OpenSSL 1.1.1+ or LibreSSL 3.1.0+"
  fi
}
```

Add call to `validate` after `load_config "$CONFIG_PATH"`:

```bash
load_config "$CONFIG_PATH"
validate
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `tests/test-vault-backup.sh`
Expected: All PASS.

- [ ] **Step 5: Commit**

```bash
git add vault-backup.sh tests/test-vault-backup.sh
git commit -m "feat: add input validation with openssl version check"
```

---

### Task 5: Passphrase Handling

**Files:**
- Modify: `vault-backup.sh`
- Modify: `tests/test-vault-backup.sh`

- [ ] **Step 1: Add passphrase tests**

Add to test script before `# ── Run`:

```bash
test_empty_passphrase_non_interactive() {
  echo "TEST: exits with error on empty passphrase in non-interactive mode"
  cat > "$TEST_TMP/vault-backup.conf" <<CONF
SOURCE_DIR="$TEST_TMP/source"
OUTPUT_DIR="$TEST_TMP/output"
EXCLUDE_PATTERNS=()
PASSPHRASE=""
CONF
  chmod 600 "$TEST_TMP/vault-backup.conf"
  local output
  # Pipe from /dev/null to simulate non-interactive
  if output=$("$VAULT_BACKUP" "$TEST_TMP/vault-backup.conf" < /dev/null 2>&1); then
    fail "should have exited non-zero"
  else
    if echo "$output" | grep -qi "passphrase"; then
      pass "exits with passphrase error in non-interactive mode"
    else
      fail "wrong error message" "$output"
    fi
  fi
}

test_passphrase_from_config() {
  echo "TEST: accepts passphrase from config"
  echo "hello" > "$TEST_TMP/source/test.txt"
  write_config "mysecretpassword"
  local output
  if output=$("$VAULT_BACKUP" "$TEST_TMP/vault-backup.conf" 2>&1); then
    pass "backup succeeds with config passphrase"
  else
    fail "backup failed" "$output"
  fi
}
```

Add to Run section:

```bash
test_empty_passphrase_non_interactive
setup  # reset for next test
test_passphrase_from_config
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `tests/test-vault-backup.sh`
Expected: FAIL — passphrase handling not implemented.

- [ ] **Step 3: Add passphrase handling to vault-backup.sh**

Add after `validate` function:

```bash
# ── Passphrase ──────────────────────────────────────────────────

resolve_passphrase() {
  if [[ -n "$PASSPHRASE" ]]; then
    return
  fi

  # Non-interactive — no passphrase available
  if [[ ! -t 0 ]]; then
    die "No passphrase set in config and stdin is not a terminal. Set PASSPHRASE in your config file for non-interactive use."
  fi

  # Interactive prompt
  local pass1 pass2
  printf "Enter passphrase: " >&2
  read -rs pass1
  printf "\n" >&2

  [[ -n "$pass1" ]] || die "Passphrase cannot be empty."

  printf "Confirm passphrase: " >&2
  read -rs pass2
  printf "\n" >&2

  [[ "$pass1" == "$pass2" ]] || die "Passphrases do not match."

  PASSPHRASE="$pass1"
}
```

Add call after `validate`:

```bash
validate
resolve_passphrase
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `tests/test-vault-backup.sh`
Expected: `test_empty_passphrase_non_interactive` PASS, `test_passphrase_from_config` will still fail (backup pipeline not yet implemented). That is expected — move on.

- [ ] **Step 5: Commit**

```bash
git add vault-backup.sh tests/test-vault-backup.sh
git commit -m "feat: add passphrase handling with interactive prompt and non-interactive guard"
```

---

### Task 6: Core Backup Pipeline

**Files:**
- Modify: `vault-backup.sh`
- Modify: `tests/test-vault-backup.sh`

- [ ] **Step 1: Add round-trip integration test**

Add to test script before `# ── Run`:

```bash
test_round_trip() {
  echo "TEST: full round-trip encrypt and decrypt"
  # Create test files
  echo "hello world" > "$TEST_TMP/source/file1.txt"
  mkdir -p "$TEST_TMP/source/subdir"
  echo "nested content" > "$TEST_TMP/source/subdir/file2.txt"

  write_config "roundtrippassword"

  # Run backup
  local output
  output=$("$VAULT_BACKUP" "$TEST_TMP/vault-backup.conf" 2>&1) || {
    fail "backup failed" "$output"
    return
  }

  # Find the .enc file
  local enc_file
  enc_file=$(ls "$TEST_TMP/output/"*.enc 2>/dev/null | head -1) || true
  if [[ -z "$enc_file" ]]; then
    fail "no .enc file created"
    return
  fi

  # Decrypt
  local tar_file="$TEST_TMP/restore/backup.tar.gz"
  openssl enc -d -aes-256-cbc -salt -pbkdf2 -iter 600000 \
    -pass pass:roundtrippassword \
    -in "$enc_file" \
    -out "$tar_file" 2>/dev/null || {
    fail "decryption failed"
    return
  }

  # Extract
  tar xzf "$tar_file" -C "$TEST_TMP/restore" || {
    fail "tar extraction failed"
    return
  }

  # Verify contents
  if [[ "$(cat "$TEST_TMP/restore/file1.txt")" == "hello world" ]] &&
     [[ "$(cat "$TEST_TMP/restore/subdir/file2.txt")" == "nested content" ]]; then
    pass "round-trip: files match after decrypt"
  else
    fail "round-trip: file contents do not match"
  fi
}

test_excludes_work() {
  echo "TEST: exclude patterns are respected"
  echo "keep me" > "$TEST_TMP/source/keep.txt"
  echo "skip me" > "$TEST_TMP/source/skip.log"
  touch "$TEST_TMP/source/.DS_Store"

  cat > "$TEST_TMP/vault-backup.conf" <<CONF
SOURCE_DIR="$TEST_TMP/source"
OUTPUT_DIR="$TEST_TMP/output"
EXCLUDE_PATTERNS=(
    "*.log"
    ".DS_Store"
)
PASSPHRASE="excludetest"
CONF
  chmod 600 "$TEST_TMP/vault-backup.conf"

  "$VAULT_BACKUP" "$TEST_TMP/vault-backup.conf" >/dev/null 2>&1 || {
    fail "backup with excludes failed"
    return
  }

  local enc_file
  enc_file=$(ls "$TEST_TMP/output/"*.enc 2>/dev/null | head -1)

  openssl enc -d -aes-256-cbc -salt -pbkdf2 -iter 600000 \
    -pass pass:excludetest \
    -in "$enc_file" \
    -out "$TEST_TMP/restore/backup.tar.gz" 2>/dev/null

  tar xzf "$TEST_TMP/restore/backup.tar.gz" -C "$TEST_TMP/restore"

  local ok=true
  [[ -f "$TEST_TMP/restore/keep.txt" ]] || { fail "keep.txt missing"; ok=false; }
  [[ ! -f "$TEST_TMP/restore/skip.log" ]] || { fail "skip.log should be excluded"; ok=false; }
  [[ ! -f "$TEST_TMP/restore/.DS_Store" ]] || { fail ".DS_Store should be excluded"; ok=false; }

  if $ok; then
    pass "excludes: correct files included/excluded"
  fi
}
```

In the Run section, **remove** these two lines that were added in Task 5:

```bash
setup  # reset for next test
test_passphrase_from_config
```

Then add:

```bash
setup
test_round_trip
setup
test_excludes_work
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `tests/test-vault-backup.sh`
Expected: FAIL — backup pipeline not yet implemented.

- [ ] **Step 3: Add backup pipeline to vault-backup.sh**

Add after `resolve_passphrase` function:

```bash
# ── Backup ──────────────────────────────────────────────────────

BACKUP_COMPLETE=false
OUTPUT_FILE=""

cleanup() {
  if [[ "$BACKUP_COMPLETE" != "true" && -n "$OUTPUT_FILE" && -f "$OUTPUT_FILE" ]]; then
    rm -f "$OUTPUT_FILE"
    warn "Backup failed. Partial file removed: $OUTPUT_FILE"
  fi
}

trap cleanup EXIT

run_backup() {
  local timestamp
  timestamp=$(date +"%Y-%m-%d-%H%M%S")
  local filename="vault-backup-${timestamp}.tar.gz.enc"
  OUTPUT_FILE="$OUTPUT_DIR/$filename"

  # Build exclude args
  local exclude_args=()
  for pattern in "${EXCLUDE_PATTERNS[@]}"; do
    [[ -n "$pattern" ]] && exclude_args+=(--exclude="$pattern")
  done

  # Compress and encrypt in a single pipeline
  tar cz ${exclude_args[@]+"${exclude_args[@]}"} -C "$SOURCE_DIR" . \
    | openssl enc -aes-256-cbc -salt -pbkdf2 -iter 600000 \
        -pass fd:3 3<<<"$PASSPHRASE" \
        -out "$OUTPUT_FILE"

  BACKUP_COMPLETE=true

  # File size (portable)
  local size
  if [[ "$(uname)" == "Darwin" ]]; then
    size=$(stat -f "%z" "$OUTPUT_FILE")
  else
    size=$(stat -c "%s" "$OUTPUT_FILE")
  fi

  # Human-readable size
  local human_size
  if (( size >= 1073741824 )); then
    human_size=$(awk "BEGIN {printf \"%.1f GB\", $size/1073741824}")
  elif (( size >= 1048576 )); then
    human_size=$(awk "BEGIN {printf \"%.1f MB\", $size/1048576}")
  elif (( size >= 1024 )); then
    human_size=$(awk "BEGIN {printf \"%.1f KB\", $size/1024}")
  else
    human_size="${size} B"
  fi

  echo ""
  echo "Done! $filename ($human_size)"
  echo "Saved to: $OUTPUT_FILE"
  echo ""
  echo "To decrypt:"
  echo "  openssl enc -d -aes-256-cbc -salt -pbkdf2 -iter 600000 \\"
  echo "    -in $filename \\"
  echo "    -out ${filename%.enc}"
  echo "  tar xzf ${filename%.enc}"
}
```

Add call at the end of the script (after `resolve_passphrase`):

```bash
resolve_passphrase
run_backup
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `tests/test-vault-backup.sh`
Expected: All PASS.

- [ ] **Step 5: Commit**

```bash
git add vault-backup.sh tests/test-vault-backup.sh
git commit -m "feat: add core backup pipeline with encrypt, excludes, and cleanup trap"
```

---

### Task 7: Summary Banner and UX Polish

**Files:**
- Modify: `vault-backup.sh`

- [ ] **Step 1: Add banner and summary output**

Add between `validate` and `resolve_passphrase` calls at the end of the script (so the banner shows before the passphrase prompt, matching the spec):

```bash
# ── Banner ──────────────────────────────────────────────────────

echo "vault-backup v${VERSION}"
echo "─────────────────────────"
echo "Source:    $SOURCE_DIR"
echo "Output:    $OUTPUT_DIR"
if [[ ${#EXCLUDE_PATTERNS[@]} -gt 0 && -n "${EXCLUDE_PATTERNS[0]}" ]]; then
  echo "Excludes:  $(IFS=,; echo "${EXCLUDE_PATTERNS[*]}" | sed 's/,/, /g')"
fi
echo ""
echo "Backing up..."
```

Note: since this is at the top level of the script (not inside a function), replace `local IFS` with a subshell approach. Also note: `${array[*]}` uses only the **first character** of IFS as a separator, so use a comma then `sed` to add spaces:

```bash
if [[ ${#EXCLUDE_PATTERNS[@]} -gt 0 && -n "${EXCLUDE_PATTERNS[0]}" ]]; then
  echo "Excludes:  $(IFS=,; echo "${EXCLUDE_PATTERNS[*]}" | sed 's/,/, /g')"
fi
```

- [ ] **Step 2: Run tests to verify nothing broke**

Run: `tests/test-vault-backup.sh`
Expected: All PASS.

- [ ] **Step 3: Commit**

```bash
git add vault-backup.sh
git commit -m "feat: add startup banner and summary output"
```

---

### Task 8: Edge Case Tests

**Files:**
- Modify: `tests/test-vault-backup.sh`

- [ ] **Step 1: Add edge case tests**

Add before `# ── Run`:

```bash
test_empty_exclude_patterns() {
  echo "TEST: works with empty exclude patterns"
  echo "content" > "$TEST_TMP/source/file.txt"
  cat > "$TEST_TMP/vault-backup.conf" <<CONF
SOURCE_DIR="$TEST_TMP/source"
OUTPUT_DIR="$TEST_TMP/output"
EXCLUDE_PATTERNS=()
PASSPHRASE="emptyexclude"
CONF
  chmod 600 "$TEST_TMP/vault-backup.conf"

  if "$VAULT_BACKUP" "$TEST_TMP/vault-backup.conf" >/dev/null 2>&1; then
    pass "empty exclude patterns work"
  else
    fail "backup failed with empty exclude patterns"
  fi
}

test_wrong_passphrase_fails() {
  echo "TEST: decryption with wrong passphrase fails"
  echo "secret data" > "$TEST_TMP/source/secret.txt"
  write_config "correctpassword"

  "$VAULT_BACKUP" "$TEST_TMP/vault-backup.conf" >/dev/null 2>&1

  local enc_file
  enc_file=$(ls "$TEST_TMP/output/"*.enc 2>/dev/null | head -1)

  if openssl enc -d -aes-256-cbc -salt -pbkdf2 -iter 600000 \
    -pass pass:wrongpassword \
    -in "$enc_file" \
    -out "$TEST_TMP/restore/backup.tar.gz" 2>/dev/null; then
    fail "decryption should fail with wrong passphrase"
  else
    pass "wrong passphrase correctly rejected"
  fi
}

test_config_permission_warning() {
  echo "TEST: warns on world-readable config"
  echo "data" > "$TEST_TMP/source/file.txt"
  write_config "permtest"
  chmod 644 "$TEST_TMP/vault-backup.conf"
  local output
  output=$("$VAULT_BACKUP" "$TEST_TMP/vault-backup.conf" 2>&1) || true
  if echo "$output" | grep -q "readable by others"; then
    pass "warns on insecure config permissions"
  else
    fail "missing permission warning" "$output"
  fi
}

test_output_file_naming() {
  echo "TEST: output file follows naming convention"
  echo "data" > "$TEST_TMP/source/file.txt"
  write_config "nametest"

  "$VAULT_BACKUP" "$TEST_TMP/vault-backup.conf" >/dev/null 2>&1

  local enc_file
  enc_file=$(ls "$TEST_TMP/output/"*.enc 2>/dev/null | head -1)
  local basename
  basename=$(basename "$enc_file")

  if [[ "$basename" =~ ^vault-backup-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}\.tar\.gz\.enc$ ]]; then
    pass "filename matches naming convention"
  else
    fail "filename does not match convention: $basename"
  fi
}
```

Add to Run section:

```bash
setup
test_empty_exclude_patterns
setup
test_wrong_passphrase_fails
setup
test_config_permission_warning
setup
test_output_file_naming
```

- [ ] **Step 2: Run tests**

Run: `tests/test-vault-backup.sh`
Expected: All PASS.

- [ ] **Step 3: Commit**

```bash
git add tests/test-vault-backup.sh
git commit -m "test: add edge case tests for excludes, wrong passphrase, naming"
```

---

### Task 9: README

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write README.md**

```markdown
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
openssl enc -d -aes-256-cbc -salt -pbkdf2 -iter 600000 \
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
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add README with usage, config reference, and recovery guide"
```

---

### Task 10: Final Integration Run

- [ ] **Step 1: Run full test suite**

Run: `tests/test-vault-backup.sh`
Expected: All PASS, zero failures.

- [ ] **Step 2: Manual smoke test**

Create a real config and run it manually:

```bash
mkdir -p /tmp/vault-test-source
echo "important file" > /tmp/vault-test-source/important.txt
cp vault-backup.conf.example vault-backup.conf
# Edit SOURCE_DIR to /tmp/vault-test-source, PASSPHRASE to "smoketest"
chmod 600 vault-backup.conf
./vault-backup.sh
# Verify the .enc file appears in ~/Downloads
# Decrypt it and verify contents
```

- [ ] **Step 3: Clean up and final commit if needed**

```bash
rm -f vault-backup.conf
rm -rf /tmp/vault-test-source
```

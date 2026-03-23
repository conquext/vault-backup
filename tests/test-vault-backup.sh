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

# ── Run ─────────────────────────────────────────────────────────
echo "vault-backup integration tests"
echo "══════════════════════════════"
setup
test_script_exists
test_missing_config
test_missing_source_dir
test_missing_output_dir
test_empty_passphrase_non_interactive
setup
test_round_trip
setup
test_excludes_work
teardown
summary

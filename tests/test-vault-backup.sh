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

# ── Run ─────────────────────────────────────────────────────────
echo "vault-backup integration tests"
echo "══════════════════════════════"
setup
test_script_exists
test_missing_config
test_missing_source_dir
test_missing_output_dir
test_empty_passphrase_non_interactive
setup  # reset for next test
test_passphrase_from_config
teardown
summary

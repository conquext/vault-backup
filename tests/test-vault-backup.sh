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

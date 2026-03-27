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

# ── Original Tests ─────────────────────────────────────────────

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
  openssl enc -d -aes-256-cbc -salt -pbkdf2 -iter 600000 -md sha256 \
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

  openssl enc -d -aes-256-cbc -salt -pbkdf2 -iter 600000 -md sha256 \
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

# ── Task 0: Argument Parser Tests ──────────────────────────────

test_help_flag() {
  echo "TEST: --help shows usage"
  local output
  output=$("$VAULT_BACKUP" --help 2>&1)
  if echo "$output" | grep -q "Usage:" && echo "$output" | grep -q "restore"; then
    pass "--help shows usage with commands"
  else
    fail "--help output missing expected content" "$output"
  fi
}

test_version_flag() {
  echo "TEST: --version shows version"
  local output
  output=$("$VAULT_BACKUP" --version 2>&1)
  if echo "$output" | grep -q "v2.0.0"; then
    pass "--version shows v2.0.0"
  else
    fail "unexpected version output" "$output"
  fi
}

test_unknown_flag() {
  echo "TEST: unknown flag exits with error"
  local output
  if output=$("$VAULT_BACKUP" --bogus 2>&1); then
    fail "should have exited non-zero"
  else
    if echo "$output" | grep -q "Unknown option"; then
      pass "unknown flag reports error"
    else
      fail "wrong error message" "$output"
    fi
  fi
}

test_backward_compat_config_arg() {
  echo "TEST: bare config arg still works (backward compat)"
  echo "data" > "$TEST_TMP/source/file.txt"
  write_config "backcompat"

  local output
  output=$("$VAULT_BACKUP" "$TEST_TMP/vault-backup.conf" 2>&1) || {
    fail "backward compat config arg failed" "$output"
    return
  }

  local enc_file
  enc_file=$(ls "$TEST_TMP/output/"*.enc 2>/dev/null | head -1) || true
  if [[ -n "$enc_file" && -f "$enc_file" ]]; then
    pass "backward compat: config arg works"
  else
    fail "backward compat: no backup file created"
  fi
}

# ── Task 1: Dry Run Tests ──────────────────────────────────────

test_dry_run_shows_info() {
  echo "TEST: --dry-run shows info"
  echo "data" > "$TEST_TMP/source/file.txt"
  mkdir -p "$TEST_TMP/source/subdir"
  echo "more" > "$TEST_TMP/source/subdir/file2.txt"
  write_config "dryruntest"

  local output
  output=$("$VAULT_BACKUP" --dry-run --config "$TEST_TMP/vault-backup.conf" 2>&1) || {
    fail "dry run failed" "$output"
    return
  }

  local ok=true
  echo "$output" | grep -q "DRY RUN" || { fail "missing DRY RUN label"; ok=false; }
  echo "$output" | grep -q "Files:" || { fail "missing file count"; ok=false; }
  echo "$output" | grep -q "Size:" || { fail "missing size estimate"; ok=false; }
  echo "$output" | grep -q "Filename:" || { fail "missing filename"; ok=false; }

  if $ok; then
    pass "dry run shows expected info"
  fi
}

test_dry_run_no_file_created() {
  echo "TEST: --dry-run creates no .enc file"
  echo "data" > "$TEST_TMP/source/file.txt"
  write_config "dryruntest"

  "$VAULT_BACKUP" --dry-run --config "$TEST_TMP/vault-backup.conf" >/dev/null 2>&1 || true

  local enc_count
  enc_count=$(find "$TEST_TMP/output" -maxdepth 1 -name "*.enc" 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$enc_count" == "0" ]]; then
    pass "dry run: no .enc file created"
  else
    fail "dry run should not create files, found $enc_count"
  fi
}

# ── Task 2: Restore Tests ──────────────────────────────────────

test_restore_round_trip() {
  echo "TEST: restore command round-trip"
  echo "restore test data" > "$TEST_TMP/source/file.txt"
  mkdir -p "$TEST_TMP/source/nested"
  echo "nested restore" > "$TEST_TMP/source/nested/deep.txt"
  write_config "restorepass"

  # Create backup
  "$VAULT_BACKUP" "$TEST_TMP/vault-backup.conf" >/dev/null 2>&1

  local enc_file
  enc_file=$(ls "$TEST_TMP/output/"*.enc 2>/dev/null | head -1)

  # Restore via piped passphrase
  local output
  output=$(echo "restorepass" | "$VAULT_BACKUP" restore "$enc_file" --to "$TEST_TMP/restore" 2>&1) || {
    fail "restore failed" "$output"
    return
  }

  if [[ "$(cat "$TEST_TMP/restore/file.txt")" == "restore test data" ]] &&
     [[ "$(cat "$TEST_TMP/restore/nested/deep.txt")" == "nested restore" ]]; then
    pass "restore round-trip: files match"
  else
    fail "restore round-trip: file contents do not match"
  fi
}

test_restore_wrong_passphrase() {
  echo "TEST: restore fails with wrong passphrase"
  echo "secret" > "$TEST_TMP/source/file.txt"
  write_config "correctpass"

  "$VAULT_BACKUP" "$TEST_TMP/vault-backup.conf" >/dev/null 2>&1

  local enc_file
  enc_file=$(ls "$TEST_TMP/output/"*.enc 2>/dev/null | head -1)

  local output
  if output=$(echo "wrongpass" | "$VAULT_BACKUP" restore "$enc_file" --to "$TEST_TMP/restore" 2>&1); then
    fail "restore should fail with wrong passphrase"
  else
    pass "restore: wrong passphrase rejected"
  fi
}

test_restore_missing_file() {
  echo "TEST: restore fails on missing file"
  local output
  if output=$("$VAULT_BACKUP" restore /nonexistent/file.enc 2>&1); then
    fail "should have exited non-zero"
  else
    if echo "$output" | grep -q "File not found"; then
      pass "restore: missing file detected"
    else
      fail "wrong error message" "$output"
    fi
  fi
}

# ── Task 3: Checksum Tests ─────────────────────────────────────

test_checksum_created() {
  echo "TEST: checksum file created after backup"
  echo "data" > "$TEST_TMP/source/file.txt"
  write_config "checksumtest"

  "$VAULT_BACKUP" "$TEST_TMP/vault-backup.conf" >/dev/null 2>&1

  local enc_file
  enc_file=$(ls "$TEST_TMP/output/"*.enc 2>/dev/null | head -1)
  local sha_file="${enc_file}.sha256"

  if [[ -f "$sha_file" ]]; then
    pass "checksum: .sha256 file created"
  else
    fail "checksum: .sha256 file not found"
  fi
}

test_verify_succeeds() {
  echo "TEST: verify succeeds on valid backup"
  echo "data" > "$TEST_TMP/source/file.txt"
  write_config "verifytest"

  "$VAULT_BACKUP" "$TEST_TMP/vault-backup.conf" >/dev/null 2>&1

  local enc_file
  enc_file=$(ls "$TEST_TMP/output/"*.enc 2>/dev/null | head -1)

  local output
  output=$("$VAULT_BACKUP" verify "$enc_file" 2>&1) || {
    fail "verify failed" "$output"
    return
  }

  if echo "$output" | grep -q "Verified"; then
    pass "verify: valid backup passes"
  else
    fail "verify: unexpected output" "$output"
  fi
}

test_verify_detects_tampering() {
  echo "TEST: verify detects tampered file"
  echo "data" > "$TEST_TMP/source/file.txt"
  write_config "tampertest"

  "$VAULT_BACKUP" "$TEST_TMP/vault-backup.conf" >/dev/null 2>&1

  local enc_file
  enc_file=$(ls "$TEST_TMP/output/"*.enc 2>/dev/null | head -1)

  # Tamper with the file
  echo "tampered" >> "$enc_file"

  local output
  if output=$("$VAULT_BACKUP" verify "$enc_file" 2>&1); then
    fail "verify should fail on tampered file"
  else
    if echo "$output" | grep -q "FAILED"; then
      pass "verify: tampering detected"
    else
      fail "wrong error message" "$output"
    fi
  fi
}

# ── Task 4: Upload Tests ───────────────────────────────────────

test_upload_skipped_when_empty() {
  echo "TEST: upload skipped when UPLOAD_REMOTE is empty"
  echo "data" > "$TEST_TMP/source/file.txt"
  write_config "uploadtest"

  local output
  output=$("$VAULT_BACKUP" "$TEST_TMP/vault-backup.conf" 2>&1) || {
    fail "backup failed" "$output"
    return
  }

  if echo "$output" | grep -q "Uploading"; then
    fail "should not attempt upload when UPLOAD_REMOTE is empty"
  else
    pass "upload: skipped when UPLOAD_REMOTE is empty"
  fi
}

test_upload_fails_without_rclone() {
  echo "TEST: upload warns when rclone not installed"
  if command -v rclone >/dev/null 2>&1; then
    pass "skipped — rclone is installed"
    return
  fi

  echo "data" > "$TEST_TMP/source/file.txt"
  cat > "$TEST_TMP/vault-backup.conf" <<CONF
SOURCE_DIR="$TEST_TMP/source"
OUTPUT_DIR="$TEST_TMP/output"
EXCLUDE_PATTERNS=()
PASSPHRASE="uploadtest"
UPLOAD_REMOTE="s3:test-bucket/backups"
CONF
  chmod 600 "$TEST_TMP/vault-backup.conf"

  local output
  output=$("$VAULT_BACKUP" "$TEST_TMP/vault-backup.conf" 2>&1) || true

  if echo "$output" | grep -q "rclone is not installed"; then
    pass "upload: warns about missing rclone"
  else
    fail "missing rclone warning" "$output"
  fi
}

# ── Task 5: Rotation Tests ─────────────────────────────────────

test_rotation_keeps_n() {
  echo "TEST: rotation keeps exactly N backups"
  echo "data" > "$TEST_TMP/source/file.txt"

  # Create 5 fake backup files
  for i in 1 2 3 4 5; do
    touch "$TEST_TMP/output/vault-backup-2026-01-0${i}-120000.tar.gz.enc"
  done

  cat > "$TEST_TMP/vault-backup.conf" <<CONF
SOURCE_DIR="$TEST_TMP/source"
OUTPUT_DIR="$TEST_TMP/output"
EXCLUDE_PATTERNS=()
PASSPHRASE="rotatetest"
RETENTION_COUNT=3
CONF
  chmod 600 "$TEST_TMP/vault-backup.conf"

  "$VAULT_BACKUP" "$TEST_TMP/vault-backup.conf" >/dev/null 2>&1

  # Count remaining .enc files (5 pre-existing + 1 new = 6, keep 3 = 3 remaining)
  local count
  count=$(ls "$TEST_TMP/output/"*.enc 2>/dev/null | wc -l | tr -d ' ')

  if [[ "$count" == "3" ]]; then
    pass "rotation: keeps exactly 3"
  else
    fail "rotation: expected 3, found $count"
  fi
}

test_rotation_disabled_at_zero() {
  echo "TEST: rotation disabled when RETENTION_COUNT=0"
  echo "data" > "$TEST_TMP/source/file.txt"

  # Create 3 fake backup files
  for i in 1 2 3; do
    touch "$TEST_TMP/output/vault-backup-2026-01-0${i}-120000.tar.gz.enc"
  done

  cat > "$TEST_TMP/vault-backup.conf" <<CONF
SOURCE_DIR="$TEST_TMP/source"
OUTPUT_DIR="$TEST_TMP/output"
EXCLUDE_PATTERNS=()
PASSPHRASE="rotatetest"
RETENTION_COUNT=0
CONF
  chmod 600 "$TEST_TMP/vault-backup.conf"

  "$VAULT_BACKUP" "$TEST_TMP/vault-backup.conf" >/dev/null 2>&1

  # All files should remain: 3 pre-existing + 1 new = 4
  local count
  count=$(ls "$TEST_TMP/output/"*.enc 2>/dev/null | wc -l | tr -d ' ')

  if [[ "$count" == "4" ]]; then
    pass "rotation: disabled at 0, all files kept"
  else
    fail "rotation disabled: expected 4, found $count"
  fi
}

test_rotation_removes_sha256() {
  echo "TEST: rotation removes companion .sha256 files"
  echo "data" > "$TEST_TMP/source/file.txt"

  # Create fake backup files with companion checksums
  for i in 1 2 3 4 5; do
    touch "$TEST_TMP/output/vault-backup-2026-01-0${i}-120000.tar.gz.enc"
    echo "fakehash" > "$TEST_TMP/output/vault-backup-2026-01-0${i}-120000.tar.gz.enc.sha256"
  done

  cat > "$TEST_TMP/vault-backup.conf" <<CONF
SOURCE_DIR="$TEST_TMP/source"
OUTPUT_DIR="$TEST_TMP/output"
EXCLUDE_PATTERNS=()
PASSPHRASE="rotatetest"
RETENTION_COUNT=2
CONF
  chmod 600 "$TEST_TMP/vault-backup.conf"

  "$VAULT_BACKUP" "$TEST_TMP/vault-backup.conf" >/dev/null 2>&1

  # Check that .sha256 files for deleted backups are also gone
  local sha_count
  sha_count=$(ls "$TEST_TMP/output/"*.sha256 2>/dev/null | wc -l | tr -d ' ')
  local enc_count
  enc_count=$(ls "$TEST_TMP/output/"*.enc 2>/dev/null | wc -l | tr -d ' ')

  if [[ "$enc_count" == "2" && "$sha_count" == "2" ]]; then
    pass "rotation: .sha256 companions removed with old backups"
  else
    fail "rotation sha256: expected 2 enc + 2 sha256, found $enc_count enc + $sha_count sha256"
  fi
}

# ── Task 6: Notification Tests ─────────────────────────────────

test_notification_skipped_when_empty() {
  echo "TEST: notification skipped when NOTIFY_URL is empty"
  echo "data" > "$TEST_TMP/source/file.txt"
  write_config "notifytest"

  local output
  output=$("$VAULT_BACKUP" "$TEST_TMP/vault-backup.conf" 2>&1) || {
    fail "backup failed" "$output"
    return
  }

  if echo "$output" | grep -q "Notification failed"; then
    fail "notification should be skipped when NOTIFY_URL is empty"
  else
    pass "notification: skipped when NOTIFY_URL is empty"
  fi
}

test_notify_on_filter() {
  echo "TEST: NOTIFY_ON=failure skips notification on success"
  echo "data" > "$TEST_TMP/source/file.txt"

  cat > "$TEST_TMP/vault-backup.conf" <<CONF
SOURCE_DIR="$TEST_TMP/source"
OUTPUT_DIR="$TEST_TMP/output"
EXCLUDE_PATTERNS=()
PASSPHRASE="notifyfilter"
NOTIFY_URL="http://localhost:1"
NOTIFY_ON="failure"
CONF
  chmod 600 "$TEST_TMP/vault-backup.conf"

  local output
  output=$("$VAULT_BACKUP" "$TEST_TMP/vault-backup.conf" 2>&1) || true

  if echo "$output" | grep -q "Notification failed"; then
    fail "NOTIFY_ON=failure should skip notification on success"
  else
    pass "NOTIFY_ON: filters correctly"
  fi
}

# ── Task 7: Profile Tests ──────────────────────────────────────

test_profiles_succeed() {
  echo "TEST: all profiles run successfully"
  mkdir -p "$TEST_TMP/profiles" "$TEST_TMP/output1" "$TEST_TMP/output2"

  # Profile 1
  mkdir -p "$TEST_TMP/source1"
  echo "data1" > "$TEST_TMP/source1/file.txt"
  cat > "$TEST_TMP/profiles/alpha.conf" <<CONF
SOURCE_DIR="$TEST_TMP/source1"
OUTPUT_DIR="$TEST_TMP/output1"
PASSPHRASE="pass1"
CONF
  chmod 600 "$TEST_TMP/profiles/alpha.conf"

  # Profile 2
  mkdir -p "$TEST_TMP/source2"
  echo "data2" > "$TEST_TMP/source2/file.txt"
  cat > "$TEST_TMP/profiles/beta.conf" <<CONF
SOURCE_DIR="$TEST_TMP/source2"
OUTPUT_DIR="$TEST_TMP/output2"
PASSPHRASE="pass2"
CONF
  chmod 600 "$TEST_TMP/profiles/beta.conf"

  # Master config
  cat > "$TEST_TMP/vault-backup.conf" <<CONF
SOURCE_DIR="$TEST_TMP/source1"
OUTPUT_DIR="$TEST_TMP/output"
PROFILES_DIR="$TEST_TMP/profiles"
PASSPHRASE="unused"
CONF
  chmod 600 "$TEST_TMP/vault-backup.conf"

  local output
  output=$("$VAULT_BACKUP" --all --config "$TEST_TMP/vault-backup.conf" 2>&1) || {
    fail "profiles failed" "$output"
    return
  }

  if echo "$output" | grep -q "2 succeeded, 0 failed"; then
    pass "profiles: all succeeded"
  else
    fail "unexpected profile summary" "$output"
  fi
}

test_profiles_partial_failure() {
  echo "TEST: profiles continue after partial failure"
  mkdir -p "$TEST_TMP/profiles" "$TEST_TMP/output2"

  # Profile 1: bad source dir → will fail
  cat > "$TEST_TMP/profiles/bad.conf" <<CONF
SOURCE_DIR="/nonexistent/dir"
OUTPUT_DIR="$TEST_TMP/output"
PASSPHRASE="pass1"
CONF
  chmod 600 "$TEST_TMP/profiles/bad.conf"

  # Profile 2: good
  mkdir -p "$TEST_TMP/source2"
  echo "data2" > "$TEST_TMP/source2/file.txt"
  cat > "$TEST_TMP/profiles/good.conf" <<CONF
SOURCE_DIR="$TEST_TMP/source2"
OUTPUT_DIR="$TEST_TMP/output2"
PASSPHRASE="pass2"
CONF
  chmod 600 "$TEST_TMP/profiles/good.conf"

  # Master config
  cat > "$TEST_TMP/vault-backup.conf" <<CONF
SOURCE_DIR="$TEST_TMP/source"
OUTPUT_DIR="$TEST_TMP/output"
PROFILES_DIR="$TEST_TMP/profiles"
PASSPHRASE="unused"
CONF
  chmod 600 "$TEST_TMP/vault-backup.conf"

  local output
  # This exits non-zero because some profiles failed
  output=$("$VAULT_BACKUP" --all --config "$TEST_TMP/vault-backup.conf" 2>&1) || true

  if echo "$output" | grep -q "1 succeeded, 1 failed"; then
    pass "profiles: partial failure handled"
  else
    fail "unexpected profile summary" "$output"
  fi
}

# ── Task 8: Cron Tests ─────────────────────────────────────────

test_cron_requires_passphrase() {
  echo "TEST: install-cron requires passphrase in config"
  cat > "$TEST_TMP/vault-backup.conf" <<CONF
SOURCE_DIR="$TEST_TMP/source"
OUTPUT_DIR="$TEST_TMP/output"
PASSPHRASE=""
CONF
  chmod 600 "$TEST_TMP/vault-backup.conf"

  local output
  if output=$("$VAULT_BACKUP" install-cron --config "$TEST_TMP/vault-backup.conf" 2>&1); then
    fail "should have exited non-zero"
  else
    if echo "$output" | grep -q "PASSPHRASE must be set"; then
      pass "cron: requires passphrase"
    else
      fail "wrong error message" "$output"
    fi
  fi
}

test_cron_shows_schedule() {
  echo "TEST: install-cron shows default schedule"
  echo "data" > "$TEST_TMP/source/file.txt"
  cat > "$TEST_TMP/vault-backup.conf" <<CONF
SOURCE_DIR="$TEST_TMP/source"
OUTPUT_DIR="$TEST_TMP/output"
PASSPHRASE="crontest"
CONF
  chmod 600 "$TEST_TMP/vault-backup.conf"

  local output
  # Non-interactive: will fail at confirmation but schedule is shown first
  output=$("$VAULT_BACKUP" install-cron --config "$TEST_TMP/vault-backup.conf" < /dev/null 2>&1) || true

  if echo "$output" | grep -q "0 2"; then
    pass "cron: shows default schedule"
  else
    fail "missing schedule in output" "$output"
  fi
}

# ── Run ─────────────────────────────────────────────────────────
echo "vault-backup integration tests"
echo "══════════════════════════════"

# Original tests
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
setup
test_empty_exclude_patterns
setup
test_wrong_passphrase_fails
setup
test_config_permission_warning
setup
test_output_file_naming

# Task 0: Argument parser
echo ""
echo "── v2.0 Tests ──────────────────"
setup
test_help_flag
test_version_flag
test_unknown_flag
setup
test_backward_compat_config_arg

# Task 1: Dry run
setup
test_dry_run_shows_info
setup
test_dry_run_no_file_created

# Task 2: Restore
setup
test_restore_round_trip
setup
test_restore_wrong_passphrase
test_restore_missing_file

# Task 3: Checksum
setup
test_checksum_created
setup
test_verify_succeeds
setup
test_verify_detects_tampering

# Task 4: Upload
setup
test_upload_skipped_when_empty
setup
test_upload_fails_without_rclone

# Task 5: Rotation
setup
test_rotation_keeps_n
setup
test_rotation_disabled_at_zero
setup
test_rotation_removes_sha256

# Task 6: Notifications
setup
test_notification_skipped_when_empty
setup
test_notify_on_filter

# Task 7: Profiles
setup
test_profiles_succeed
setup
test_profiles_partial_failure

# Task 8: Cron
setup
test_cron_requires_passphrase
setup
test_cron_shows_schedule

# ── Task 9: Collect Tests ─────────────────────────────────────

test_collect_round_trip() {
  echo "TEST: collect round-trip"
  mkdir -p "$TEST_TMP/project/src" "$TEST_TMP/project/config"
  echo "app code" > "$TEST_TMP/project/src/app.js"
  echo "DB_HOST=localhost" > "$TEST_TMP/project/src/.env"
  echo "SECRET=abc" > "$TEST_TMP/project/config/.env"
  echo "readme" > "$TEST_TMP/project/README.md"

  # Collect all .env files
  local output
  output=$(echo "collectpass" | "$VAULT_BACKUP" collect '*.env' --from "$TEST_TMP/project" --to "$TEST_TMP/output" 2>&1) || {
    fail "collect failed" "$output"
    return
  }

  # Find the collect file
  local enc_file
  enc_file=$(ls "$TEST_TMP/output/"vault-collect-*.enc 2>/dev/null | head -1) || true
  if [[ -z "$enc_file" ]]; then
    fail "no vault-collect .enc file created"
    return
  fi

  # Restore it
  mkdir -p "$TEST_TMP/restore"
  output=$(echo "collectpass" | "$VAULT_BACKUP" restore "$enc_file" --to "$TEST_TMP/restore" 2>&1) || {
    fail "restore of collect failed" "$output"
    return
  }

  # Verify .env files present with path structure, and non-.env absent
  local ok=true
  # The find output includes absolute paths from --from dir
  if find "$TEST_TMP/restore" -name ".env" -type f | grep -q ".env"; then
    : # good
  else
    fail "collect round-trip: .env files not found in restore"
    ok=false
  fi

  if find "$TEST_TMP/restore" -name "app.js" -type f | grep -q "app.js"; then
    fail "collect round-trip: app.js should not be in archive"
    ok=false
  fi

  if find "$TEST_TMP/restore" -name "README.md" -type f | grep -q "README.md"; then
    fail "collect round-trip: README.md should not be in archive"
    ok=false
  fi

  if $ok; then
    pass "collect round-trip: correct files collected with path structure"
  fi
}

test_collect_no_matches() {
  echo "TEST: collect fails on no matches"
  mkdir -p "$TEST_TMP/project"
  echo "hello" > "$TEST_TMP/project/file.txt"

  local output
  if output=$(echo "pass" | "$VAULT_BACKUP" collect '*.xyz' --from "$TEST_TMP/project" --to "$TEST_TMP/output" 2>&1); then
    fail "should have exited non-zero"
  else
    if echo "$output" | grep -q "No files matching"; then
      pass "collect: no matches detected"
    else
      fail "wrong error message" "$output"
    fi
  fi
}

test_collect_missing_from() {
  echo "TEST: collect fails without --from"
  local output
  if output=$(echo "pass" | "$VAULT_BACKUP" collect '*.env' 2>&1); then
    fail "should have exited non-zero"
  else
    if echo "$output" | grep -q "Usage:"; then
      pass "collect: missing --from shows usage"
    else
      fail "wrong error message" "$output"
    fi
  fi
}

test_collect_checksum() {
  echo "TEST: collect creates .sha256 file"
  mkdir -p "$TEST_TMP/project"
  echo "data" > "$TEST_TMP/project/file.txt"

  echo "checksumpass" | "$VAULT_BACKUP" collect '*.txt' --from "$TEST_TMP/project" --to "$TEST_TMP/output" >/dev/null 2>&1

  local enc_file
  enc_file=$(ls "$TEST_TMP/output/"vault-collect-*.enc 2>/dev/null | head -1) || true
  local sha_file="${enc_file}.sha256"

  if [[ -f "$sha_file" ]]; then
    pass "collect: .sha256 file created"
  else
    fail "collect: .sha256 file not found"
  fi
}

# ── Task 10: Include Patterns Tests ──────────────────────────

test_include_patterns_backup() {
  echo "TEST: INCLUDE_PATTERNS backs up only matching files"
  echo "keep this" > "$TEST_TMP/source/notes.txt"
  echo "also keep" > "$TEST_TMP/source/todo.txt"
  echo "skip me" > "$TEST_TMP/source/image.png"
  mkdir -p "$TEST_TMP/source/sub"
  echo "nested txt" > "$TEST_TMP/source/sub/deep.txt"

  cat > "$TEST_TMP/vault-backup.conf" <<CONF
SOURCE_DIR="$TEST_TMP/source"
OUTPUT_DIR="$TEST_TMP/output"
INCLUDE_PATTERNS=("*.txt")
PASSPHRASE="includetest"
CONF
  chmod 600 "$TEST_TMP/vault-backup.conf"

  "$VAULT_BACKUP" "$TEST_TMP/vault-backup.conf" >/dev/null 2>&1 || {
    fail "backup with include patterns failed"
    return
  }

  local enc_file
  enc_file=$(ls "$TEST_TMP/output/"*.enc 2>/dev/null | head -1)

  openssl enc -d -aes-256-cbc -salt -pbkdf2 -iter 600000 -md sha256 \
    -pass pass:includetest \
    -in "$enc_file" \
    -out "$TEST_TMP/restore/backup.tar.gz" 2>/dev/null

  tar xzf "$TEST_TMP/restore/backup.tar.gz" -C "$TEST_TMP/restore"

  local ok=true
  [[ -f "$TEST_TMP/restore/notes.txt" ]] || { fail "include: notes.txt missing"; ok=false; }
  [[ -f "$TEST_TMP/restore/todo.txt" ]] || { fail "include: todo.txt missing"; ok=false; }
  [[ -f "$TEST_TMP/restore/sub/deep.txt" ]] || { fail "include: sub/deep.txt missing"; ok=false; }
  [[ ! -f "$TEST_TMP/restore/image.png" ]] || { fail "include: image.png should be excluded"; ok=false; }

  if $ok; then
    pass "include patterns: only .txt files in archive"
  fi
}

test_include_patterns_empty() {
  echo "TEST: empty INCLUDE_PATTERNS does normal full backup"
  echo "file1" > "$TEST_TMP/source/a.txt"
  echo "file2" > "$TEST_TMP/source/b.png"

  cat > "$TEST_TMP/vault-backup.conf" <<CONF
SOURCE_DIR="$TEST_TMP/source"
OUTPUT_DIR="$TEST_TMP/output"
INCLUDE_PATTERNS=()
PASSPHRASE="emptyinclude"
CONF
  chmod 600 "$TEST_TMP/vault-backup.conf"

  "$VAULT_BACKUP" "$TEST_TMP/vault-backup.conf" >/dev/null 2>&1 || {
    fail "backup with empty include failed"
    return
  }

  local enc_file
  enc_file=$(ls "$TEST_TMP/output/"*.enc 2>/dev/null | head -1)

  openssl enc -d -aes-256-cbc -salt -pbkdf2 -iter 600000 -md sha256 \
    -pass pass:emptyinclude \
    -in "$enc_file" \
    -out "$TEST_TMP/restore/backup.tar.gz" 2>/dev/null

  tar xzf "$TEST_TMP/restore/backup.tar.gz" -C "$TEST_TMP/restore"

  local ok=true
  [[ -f "$TEST_TMP/restore/a.txt" ]] || { fail "empty include: a.txt missing"; ok=false; }
  [[ -f "$TEST_TMP/restore/b.png" ]] || { fail "empty include: b.png missing"; ok=false; }

  if $ok; then
    pass "empty include patterns: full backup (backward compat)"
  fi
}

test_include_plus_exclude() {
  echo "TEST: INCLUDE + EXCLUDE interaction"
  echo "keep" > "$TEST_TMP/source/app.txt"
  echo "exclude me" > "$TEST_TMP/source/debug.txt"
  echo "skip" > "$TEST_TMP/source/photo.png"

  cat > "$TEST_TMP/vault-backup.conf" <<CONF
SOURCE_DIR="$TEST_TMP/source"
OUTPUT_DIR="$TEST_TMP/output"
INCLUDE_PATTERNS=("*.txt")
EXCLUDE_PATTERNS=("debug.txt")
PASSPHRASE="bothtest"
CONF
  chmod 600 "$TEST_TMP/vault-backup.conf"

  "$VAULT_BACKUP" "$TEST_TMP/vault-backup.conf" >/dev/null 2>&1 || {
    fail "backup with include+exclude failed"
    return
  }

  local enc_file
  enc_file=$(ls "$TEST_TMP/output/"*.enc 2>/dev/null | head -1)

  openssl enc -d -aes-256-cbc -salt -pbkdf2 -iter 600000 -md sha256 \
    -pass pass:bothtest \
    -in "$enc_file" \
    -out "$TEST_TMP/restore/backup.tar.gz" 2>/dev/null

  tar xzf "$TEST_TMP/restore/backup.tar.gz" -C "$TEST_TMP/restore"

  local ok=true
  [[ -f "$TEST_TMP/restore/app.txt" ]] || { fail "include+exclude: app.txt missing"; ok=false; }
  [[ ! -f "$TEST_TMP/restore/debug.txt" ]] || { fail "include+exclude: debug.txt should be excluded"; ok=false; }
  [[ ! -f "$TEST_TMP/restore/photo.png" ]] || { fail "include+exclude: photo.png should not be included"; ok=false; }

  if $ok; then
    pass "include+exclude: correct filtering"
  fi
}

test_dry_run_with_include() {
  echo "TEST: dry run with INCLUDE_PATTERNS shows include info"
  echo "data" > "$TEST_TMP/source/file.txt"
  echo "other" > "$TEST_TMP/source/file.log"

  cat > "$TEST_TMP/vault-backup.conf" <<CONF
SOURCE_DIR="$TEST_TMP/source"
OUTPUT_DIR="$TEST_TMP/output"
INCLUDE_PATTERNS=("*.txt")
PASSPHRASE="dryinclude"
CONF
  chmod 600 "$TEST_TMP/vault-backup.conf"

  local output
  output=$("$VAULT_BACKUP" --dry-run --config "$TEST_TMP/vault-backup.conf" 2>&1) || {
    fail "dry run with include failed" "$output"
    return
  }

  local ok=true
  echo "$output" | grep -q "Include:" || { fail "missing Include label"; ok=false; }
  echo "$output" | grep -q "Files:" || { fail "missing file count"; ok=false; }
  # Should show 1 file (only .txt matches)
  echo "$output" | grep -q "Files:.*1" || { fail "wrong file count (expected 1)"; ok=false; }

  if $ok; then
    pass "dry run with include: shows patterns and correct count"
  fi
}

# Task 9: Collect
setup
test_collect_round_trip
setup
test_collect_no_matches
setup
test_collect_missing_from
setup
test_collect_checksum

# Task 10: Include Patterns
setup
test_include_patterns_backup
setup
test_include_patterns_empty
setup
test_include_plus_exclude
setup
test_dry_run_with_include

teardown
summary

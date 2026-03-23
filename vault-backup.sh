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

# ── Resolve config path ────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -gt 0 ]]; then
  CONFIG_PATH="$1"
else
  CONFIG_PATH="$SCRIPT_DIR/vault-backup.conf"
fi

load_config "$CONFIG_PATH"
validate

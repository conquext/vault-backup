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

#!/usr/bin/env bash
set -euo pipefail

VERSION="2.0.0"

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

  # Required
  [[ -n "${SOURCE_DIR:-}" ]] || die "SOURCE_DIR is not set in config file: $config_path"

  # Defaults
  OUTPUT_DIR="${OUTPUT_DIR:-$HOME/Downloads}"
  if [[ -z "${EXCLUDE_PATTERNS+x}" ]]; then
    EXCLUDE_PATTERNS=()
  fi
  if [[ -z "${INCLUDE_PATTERNS+x}" ]]; then
    INCLUDE_PATTERNS=()
  fi
  PASSPHRASE="${PASSPHRASE:-}"

  # v2.0 defaults
  UPLOAD_REMOTE="${UPLOAD_REMOTE:-}"
  RETENTION_COUNT="${RETENTION_COUNT:-0}"
  NOTIFY_URL="${NOTIFY_URL:-}"
  NOTIFY_ON="${NOTIFY_ON:-always}"
  PROFILES_DIR="${PROFILES_DIR:-}"
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
  for pattern in "${EXCLUDE_PATTERNS[@]+"${EXCLUDE_PATTERNS[@]}"}"; do
    [[ -n "$pattern" ]] && exclude_args+=(--exclude="$pattern")
  done

  # Compress and encrypt in a single pipeline
  if [[ ${#INCLUDE_PATTERNS[@]} -gt 0 && -n "${INCLUDE_PATTERNS[0]:-}" ]]; then
    # Include mode: find matching files, then apply excludes
    local find_expr=()
    for pat in "${INCLUDE_PATTERNS[@]}"; do
      [[ ${#find_expr[@]} -gt 0 ]] && find_expr+=("-o")
      find_expr+=("-name" "$pat")
    done
    local find_excludes=()
    for pat in "${EXCLUDE_PATTERNS[@]+"${EXCLUDE_PATTERNS[@]}"}"; do
      [[ -n "$pat" ]] && find_excludes+=("!" "-name" "$pat")
    done
    (cd "$SOURCE_DIR" && find . -type f \( "${find_expr[@]}" \) ${find_excludes[@]+"${find_excludes[@]}"} -print0 \
      | tar cz --null -T -) \
      | openssl enc -aes-256-cbc -salt -pbkdf2 -iter 600000 -md sha256 \
          -pass fd:3 3<<<"$PASSPHRASE" \
          -out "$OUTPUT_FILE"
  else
    # Full directory backup (default)
    tar cz ${exclude_args[@]+"${exclude_args[@]}"} -C "$SOURCE_DIR" . \
      | openssl enc -aes-256-cbc -salt -pbkdf2 -iter 600000 -md sha256 \
          -pass fd:3 3<<<"$PASSPHRASE" \
          -out "$OUTPUT_FILE"
  fi

  [[ -s "$OUTPUT_FILE" ]] || die "Backup produced an empty file"

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
  echo "  openssl enc -d -aes-256-cbc -salt -pbkdf2 -iter 600000 -md sha256 \\"
  echo "    -in $filename \\"
  echo "    -out ${filename%.enc}"
  echo "  tar xzf ${filename%.enc}"
}

# ── Checksum ────────────────────────────────────────────────────

generate_checksum() {
  local file="$1"
  local checksum_file="${file}.sha256"

  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" > "$checksum_file"
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" > "$checksum_file"
  else
    warn "No sha256sum or shasum found — skipping checksum"
    return 1
  fi

  echo "Checksum:  $checksum_file"
}

run_verify() {
  local file="$1"

  [[ -f "$file" ]] || die "File not found: $file"

  local checksum_file="${file}.sha256"
  [[ -f "$checksum_file" ]] || die "Checksum file not found: $checksum_file"

  # Extract the stored hash
  local stored_hash
  stored_hash=$(awk '{print $1}' "$checksum_file")

  # Compute current hash
  local current_hash
  if command -v shasum >/dev/null 2>&1; then
    current_hash=$(shasum -a 256 "$file" | awk '{print $1}')
  elif command -v sha256sum >/dev/null 2>&1; then
    current_hash=$(sha256sum "$file" | awk '{print $1}')
  else
    die "No sha256sum or shasum found"
  fi

  if [[ "$stored_hash" == "$current_hash" ]]; then
    echo "Verified: $file"
    echo "SHA-256:  $current_hash"
  else
    die "Verification FAILED for $file — file may be corrupted or tampered with"
  fi
}

# ── Upload ──────────────────────────────────────────────────────

upload_backup() {
  local file="$1"

  [[ -n "$UPLOAD_REMOTE" ]] || return 0

  command -v rclone >/dev/null 2>&1 || {
    warn "rclone is not installed — skipping upload"
    return 1
  }

  echo "Uploading to $UPLOAD_REMOTE ..."

  rclone copyto "$file" "$UPLOAD_REMOTE/$(basename "$file")" || {
    warn "Upload failed for $(basename "$file")"
    return 1
  }

  # Upload .sha256 companion if it exists
  local checksum_file="${file}.sha256"
  if [[ -f "$checksum_file" ]]; then
    rclone copyto "$checksum_file" "$UPLOAD_REMOTE/$(basename "$checksum_file")" || {
      warn "Upload failed for $(basename "$checksum_file")"
      return 1
    }
  fi

  echo "Uploaded:  $UPLOAD_REMOTE/$(basename "$file")"
}

# ── Rotation ────────────────────────────────────────────────────

rotate_backups() {
  [[ "$RETENTION_COUNT" -gt 0 ]] || return 0

  local files=()
  while IFS= read -r f; do
    files+=("$f")
  done < <(ls -1 "$OUTPUT_DIR"/vault-backup-*.tar.gz.enc 2>/dev/null | sort)

  local count=${#files[@]}
  if (( count <= RETENTION_COUNT )); then
    return 0
  fi

  local to_delete=$(( count - RETENTION_COUNT ))
  local i=0
  for file in "${files[@]}"; do
    if (( i >= to_delete )); then
      break
    fi
    rm -f "$file"
    rm -f "${file}.sha256"
    i=$((i + 1))
  done

  echo "Rotation:  kept $RETENTION_COUNT, removed $to_delete old backup(s)"
}

# ── Notifications ───────────────────────────────────────────────

send_notification() {
  local status="$1"
  local filename="${2:-}"
  local size="${3:-}"
  local details="${4:-}"

  [[ -n "$NOTIFY_URL" ]] || return 0

  # Filter by NOTIFY_ON
  case "$NOTIFY_ON" in
    success) [[ "$status" == "success" ]] || return 0 ;;
    failure) [[ "$status" == "failure" ]] || return 0 ;;
    always) ;;
    *) return 0 ;;
  esac

  command -v curl >/dev/null 2>&1 || {
    warn "curl is not installed — skipping notification"
    return 1
  }

  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  local json
  json=$(printf '{"status":"%s","filename":"%s","size":"%s","timestamp":"%s","details":"%s"}' \
    "$status" "$filename" "$size" "$timestamp" "$details")

  curl -s -X POST -H "Content-Type: application/json" -d "$json" "$NOTIFY_URL" >/dev/null 2>&1 || {
    warn "Notification failed"
    return 1
  }
}

# ── Restore ─────────────────────────────────────────────────────

run_restore() {
  local file="$RESTORE_FILE"
  local target_dir="${RESTORE_DIR:-.}"

  [[ -n "$file" ]] || die "Usage: vault-backup.sh restore <file.enc> [--to <dir>]"
  [[ -f "$file" ]] || die "File not found: $file"
  [[ -d "$target_dir" ]] || die "Target directory does not exist: $target_dir"

  # Read passphrase (single prompt, no confirmation)
  local passphrase=""
  if [[ ! -t 0 ]]; then
    read -r passphrase
  else
    printf "Enter passphrase: " >&2
    read -rs passphrase
    printf "\n" >&2
  fi

  [[ -n "$passphrase" ]] || die "Passphrase cannot be empty."

  openssl enc -d -aes-256-cbc -salt -pbkdf2 -iter 600000 -md sha256 \
    -pass fd:3 3<<<"$passphrase" \
    -in "$file" \
  | tar xz -C "$target_dir" || die "Restore failed — wrong passphrase or corrupted file"

  echo "Restored: $file → $target_dir"
}

# ── Dry Run ─────────────────────────────────────────────────────

show_dry_run() {
  echo "[DRY RUN] No backup will be created."
  echo ""

  local file_count
  if [[ ${#INCLUDE_PATTERNS[@]} -gt 0 && -n "${INCLUDE_PATTERNS[0]:-}" ]]; then
    # Build find expression for include patterns
    local dry_find_expr=()
    for pat in "${INCLUDE_PATTERNS[@]}"; do
      [[ ${#dry_find_expr[@]} -gt 0 ]] && dry_find_expr+=("-o")
      dry_find_expr+=("-name" "$pat")
    done
    local dry_find_excludes=()
    for pat in "${EXCLUDE_PATTERNS[@]+"${EXCLUDE_PATTERNS[@]}"}"; do
      [[ -n "$pat" ]] && dry_find_excludes+=("!" "-name" "$pat")
    done
    file_count=$(find "$SOURCE_DIR" -type f \( "${dry_find_expr[@]}" \) ${dry_find_excludes[@]+"${dry_find_excludes[@]}"} 2>/dev/null | wc -l | tr -d ' ')
    echo "Include:   $(IFS=,; echo "${INCLUDE_PATTERNS[*]}" | sed 's/,/, /g')"
  else
    file_count=$(find "$SOURCE_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
  fi

  local estimated_size
  estimated_size=$(du -sh "$SOURCE_DIR" 2>/dev/null | awk '{print $1}')

  local timestamp
  timestamp=$(date +"%Y-%m-%d-%H%M%S")
  local filename="vault-backup-${timestamp}.tar.gz.enc"

  echo "Files:     $file_count"
  echo "Size:      $estimated_size (before compression)"
  echo "Filename:  $filename"

  if [[ -n "${UPLOAD_REMOTE:-}" ]]; then
    echo "Upload:    $UPLOAD_REMOTE"
  fi

  if [[ "${RETENTION_COUNT:-0}" -gt 0 ]]; then
    echo "Retention: keep $RETENTION_COUNT"
  fi

  echo ""
}

# ── Collect ─────────────────────────────────────────────────

run_collect() {
  local pattern="$COLLECT_PATTERN"
  local from_dir="$COLLECT_FROM"
  local to_dir="${COLLECT_TO:-.}"

  [[ -n "$pattern" ]] || die "Usage: vault-backup.sh collect <pattern> --from <dir> [--to <dir>]"
  [[ -n "$from_dir" ]] || die "Usage: vault-backup.sh collect <pattern> --from <dir> [--to <dir>]"
  [[ -d "$from_dir" ]] || die "Source directory does not exist: $from_dir"
  [[ -d "$to_dir" ]] || die "Output directory does not exist: $to_dir"

  # Count matching files
  local match_count
  match_count=$(find "$from_dir" -type f -name "$pattern" 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$match_count" -eq 0 ]]; then
    die "No files matching '$pattern' in $from_dir"
  fi

  # Read passphrase
  local passphrase=""
  if [[ ! -t 0 ]]; then
    read -r passphrase
  else
    local pass1 pass2
    printf "Enter passphrase: " >&2
    read -rs pass1
    printf "\n" >&2
    [[ -n "$pass1" ]] || die "Passphrase cannot be empty."
    printf "Confirm passphrase: " >&2
    read -rs pass2
    printf "\n" >&2
    [[ "$pass1" == "$pass2" ]] || die "Passphrases do not match."
    passphrase="$pass1"
  fi
  [[ -n "$passphrase" ]] || die "Passphrase cannot be empty."

  local timestamp
  timestamp=$(date +"%Y-%m-%d-%H%M%S")
  local filename="vault-collect-${timestamp}.tar.gz.enc"
  local output_file="$to_dir/$filename"

  echo "Collecting $match_count file(s) matching '$pattern' from $from_dir"

  find "$from_dir" -type f -name "$pattern" -print0 \
    | tar cz --null -T - \
    | openssl enc -aes-256-cbc -salt -pbkdf2 -iter 600000 -md sha256 \
        -pass fd:3 3<<<"$passphrase" \
        -out "$output_file"

  [[ -s "$output_file" ]] || die "Collect produced an empty file"

  BACKUP_COMPLETE=true
  OUTPUT_FILE="$output_file"

  echo "Done! $filename"
  echo "Saved to: $output_file"

  generate_checksum "$output_file" || true
}

# ── Profiles ────────────────────────────────────────────────────

run_all_profiles() {
  local config_path="${CONFIG_PATH:-}"
  if [[ -z "$config_path" ]]; then
    config_path="$SCRIPT_DIR/vault-backup.conf"
  fi

  load_config "$config_path"

  [[ -n "$PROFILES_DIR" ]] || die "PROFILES_DIR is not set in config"
  [[ -d "$PROFILES_DIR" ]] || die "Profiles directory does not exist: $PROFILES_DIR"

  local conf_files=("$PROFILES_DIR"/*.conf)
  [[ -e "${conf_files[0]}" ]] || die "No .conf files found in $PROFILES_DIR"

  echo "vault-backup v${VERSION} — running all profiles"
  echo "─────────────────────────"
  echo "Profiles:  $PROFILES_DIR"
  echo ""

  local succeeded=0
  local failed=0

  for conf in "${conf_files[@]}"; do
    local profile_name
    profile_name=$(basename "$conf" .conf)
    echo "── Profile: $profile_name ──"

    if (
      # Subshell: isolate config state
      BACKUP_COMPLETE=false
      OUTPUT_FILE=""
      load_config "$conf"
      validate
      show_banner
      resolve_passphrase
      echo "Backing up..."
      run_backup
      generate_checksum "$OUTPUT_FILE" || true
      upload_backup "$OUTPUT_FILE" || true
      rotate_backups || true
      send_notification "success" "$(basename "$OUTPUT_FILE")" "" "" || true
    ); then
      succeeded=$((succeeded + 1))
    else
      failed=$((failed + 1))
      echo "  Profile $profile_name FAILED"
    fi
    echo ""
  done

  echo "─────────────────────────"
  echo "Profiles: $succeeded succeeded, $failed failed"

  [[ $failed -eq 0 ]]
}

# ── Cron ────────────────────────────────────────────────────────

run_install_cron() {
  local config_path="${CONFIG_PATH:-}"
  if [[ -z "$config_path" ]]; then
    config_path="$SCRIPT_DIR/vault-backup.conf"
  fi

  load_config "$config_path"

  [[ -n "$PASSPHRASE" ]] || die "PASSPHRASE must be set in config for cron usage"

  local schedule="$CRON_SCHEDULE"
  local script_path
  script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  local abs_config
  abs_config="$(cd "$(dirname "$config_path")" && pwd)/$(basename "$config_path")"
  local cron_entry="$schedule $script_path $abs_config"

  echo "Cron entry to install:"
  echo "  $cron_entry"
  echo ""

  # Check for existing entry
  if crontab -l 2>/dev/null | grep -qF "vault-backup"; then
    warn "Existing vault-backup cron entry found. Remove it first if you want to replace it."
    crontab -l 2>/dev/null | grep "vault-backup"
    return 1
  fi

  # Confirm interactively
  if [[ -t 0 ]]; then
    printf "Install this cron entry? [y/N] " >&2
    local confirm
    read -r confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Cancelled."; return 0; }
  else
    die "Cron installation requires interactive terminal"
  fi

  # Append to crontab
  (crontab -l 2>/dev/null; echo "$cron_entry") | crontab -

  echo "Cron entry installed."
}

# ── Banner / Usage ──────────────────────────────────────────────

show_banner() {
  echo "vault-backup v${VERSION}"
  echo "─────────────────────────"
  echo "Source:    $SOURCE_DIR"
  echo "Output:    $OUTPUT_DIR"
  if [[ ${#INCLUDE_PATTERNS[@]} -gt 0 && -n "${INCLUDE_PATTERNS[0]:-}" ]]; then
    echo "Includes:  $(IFS=,; echo "${INCLUDE_PATTERNS[*]}" | sed 's/,/, /g')"
  fi
  if [[ ${#EXCLUDE_PATTERNS[@]} -gt 0 && -n "${EXCLUDE_PATTERNS[0]:-}" ]]; then
    echo "Excludes:  $(IFS=,; echo "${EXCLUDE_PATTERNS[*]}" | sed 's/,/, /g')"
  fi
  echo ""
}

show_usage() {
  cat <<USAGE
vault-backup v${VERSION} — encrypted backup tool

Usage:
  vault-backup.sh [options] [config-file]
  vault-backup.sh restore <file.enc> [--to <dir>]
  vault-backup.sh collect <pattern> --from <dir> [--to <dir>]
  vault-backup.sh verify <file.enc>
  vault-backup.sh install-cron [schedule]

Commands:
  restore       Decrypt and extract an encrypted backup
  collect       Selectively back up files matching a pattern
  verify        Verify integrity of an encrypted backup
  install-cron  Install a cron job for automated backups

Options:
  --config <file>   Path to config file
  --dry-run         Show what would be backed up without creating a backup
  --all             Run all profiles in PROFILES_DIR
  --help, -h        Show this help message
  --version, -v     Show version

Examples:
  vault-backup.sh                          # Use default config
  vault-backup.sh vault-backup.conf        # Specify config file
  vault-backup.sh --dry-run                # Preview backup
  vault-backup.sh --all                    # Run all profiles
  vault-backup.sh restore backup.enc       # Restore to current dir
  vault-backup.sh restore backup.enc --to ~/restored
  vault-backup.sh collect '*.env' --from ~/projects
  vault-backup.sh collect '*.env' --from ~/projects --to ~/backups
  vault-backup.sh verify backup.enc        # Verify checksum
  vault-backup.sh install-cron             # Default: 0 2 * * *
  vault-backup.sh install-cron "0 3 * * 0" # Custom schedule
USAGE
}

# ── Single Backup Flow ──────────────────────────────────────────

run_single_backup() {
  local config_path="${CONFIG_PATH:-}"
  if [[ -z "$config_path" ]]; then
    config_path="$SCRIPT_DIR/vault-backup.conf"
  fi

  load_config "$config_path"
  validate

  if $DRY_RUN; then
    show_banner
    show_dry_run
    return 0
  fi

  show_banner
  resolve_passphrase

  echo "Backing up..."
  run_backup

  # Post-backup pipeline (non-fatal)
  local backup_status="success"
  local backup_details=""

  generate_checksum "$OUTPUT_FILE" || {
    backup_details="${backup_details}checksum failed; "
  }

  upload_backup "$OUTPUT_FILE" || {
    backup_details="${backup_details}upload failed; "
    if [[ -n "$UPLOAD_REMOTE" ]]; then
      backup_status="failure"
    fi
  }

  rotate_backups || {
    backup_details="${backup_details}rotation failed; "
  }

  # Get file size for notification
  local file_size=""
  if [[ -f "$OUTPUT_FILE" ]]; then
    if [[ "$(uname)" == "Darwin" ]]; then
      file_size=$(stat -f "%z" "$OUTPUT_FILE")
    else
      file_size=$(stat -c "%s" "$OUTPUT_FILE")
    fi
  fi

  send_notification "$backup_status" "$(basename "$OUTPUT_FILE")" "$file_size" "$backup_details" || true
}

# ── Argument Parser ─────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_PATH=""
DRY_RUN=false
RUN_ALL=false
RESTORE_FILE=""
RESTORE_DIR=""
VERIFY_FILE=""
CRON_SCHEDULE="0 2 * * *"
COLLECT_PATTERN=""
COLLECT_FROM=""
COLLECT_TO=""

parse_args() {
  local cmd=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h)
        show_usage
        exit 0
        ;;
      --version|-v)
        echo "vault-backup v${VERSION}"
        exit 0
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --all)
        RUN_ALL=true
        shift
        ;;
      --config)
        [[ $# -ge 2 ]] || die "--config requires an argument"
        CONFIG_PATH="$2"
        shift 2
        ;;
      restore)
        cmd="restore"
        shift
        if [[ $# -gt 0 && "$1" != --* ]]; then
          RESTORE_FILE="$1"
          shift
        fi
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --to)
              [[ $# -ge 2 ]] || die "--to requires an argument"
              RESTORE_DIR="$2"
              shift 2
              ;;
            *) die "Unknown option for restore: $1" ;;
          esac
        done
        ;;
      collect)
        cmd="collect"
        shift
        if [[ $# -gt 0 && "$1" != --* ]]; then
          COLLECT_PATTERN="$1"
          shift
        fi
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --from)
              [[ $# -ge 2 ]] || die "--from requires an argument"
              COLLECT_FROM="$2"
              shift 2
              ;;
            --to)
              [[ $# -ge 2 ]] || die "--to requires an argument"
              COLLECT_TO="$2"
              shift 2
              ;;
            *) die "Unknown option for collect: $1" ;;
          esac
        done
        ;;
      verify)
        cmd="verify"
        shift
        if [[ $# -gt 0 && "$1" != --* ]]; then
          VERIFY_FILE="$1"
          shift
        fi
        ;;
      install-cron)
        cmd="install-cron"
        shift
        if [[ $# -gt 0 && "$1" != --* ]]; then
          CRON_SCHEDULE="$1"
          shift
        fi
        ;;
      --*)
        die "Unknown option: $1"
        ;;
      *)
        # Backward compat: bare arg = config path
        if [[ -z "$CONFIG_PATH" ]]; then
          CONFIG_PATH="$1"
        else
          die "Unknown argument: $1"
        fi
        shift
        ;;
    esac
  done

  # Dispatch
  case "$cmd" in
    restore)
      run_restore
      ;;
    collect)
      run_collect
      ;;
    verify)
      [[ -n "$VERIFY_FILE" ]] || die "Usage: vault-backup.sh verify <file.enc>"
      run_verify "$VERIFY_FILE"
      ;;
    install-cron)
      run_install_cron
      ;;
    "")
      if $RUN_ALL; then
        run_all_profiles
      else
        run_single_backup
      fi
      ;;
  esac
}

# ── Main ────────────────────────────────────────────────────────

parse_args "$@"

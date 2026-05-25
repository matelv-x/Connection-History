#!/usr/bin/env bash
set -euo pipefail

TARGET="${1:-/home/pi/sg1_v4}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_FILE="$SCRIPT_DIR/connection-history.patch"
BACKUP_ROOT="${BACKUP_ROOT:-/home/pi}"
STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR="$BACKUP_ROOT/sg1_v4_backup_connection_history_$STAMP"

log() { echo; echo "=== $1 ==="; }
fail() { echo "ERROR: $1" >&2; exit 1; }

require_target() {
  [ -d "$TARGET" ] || fail "Target folder not found: $TARGET"
  [ -f "$TARGET/main.py" ] || fail "This does not look like a StargateProject folder: $TARGET"
  [ -f "$PATCH_FILE" ] || fail "Patch file not found: $PATCH_FILE"
  command -v patch >/dev/null 2>&1 || fail "patch command not found. Install it first."
}

backup_target() {
  log "Creating backup"
  mkdir -p "$BACKUP_ROOT"
  cp -a "$TARGET" "$BACKUP_DIR"
  echo "$BACKUP_DIR" > "$SCRIPT_DIR/.last_backup_path"
  echo "Backup created: $BACKUP_DIR"
}

service_action() {
  local action="$1"
  [ "${RESTART_STARGATE_SERVICE:-1}" = "1" ] || return 0
  command -v systemctl >/dev/null 2>&1 || return 0
  systemctl "$action" stargate.service >/dev/null 2>&1 || true
}

apply_patch_file() {
  log "Applying patch: $(basename "$PATCH_FILE")"
  if patch -d "$TARGET" -p1 --forward --dry-run < "$PATCH_FILE" >/dev/null; then
    patch -d "$TARGET" -p1 --forward < "$PATCH_FILE"
  elif patch -d "$TARGET" -p1 --reverse --dry-run < "$PATCH_FILE" >/dev/null 2>&1; then
    echo "Patch already appears to be applied. Skipping text patch."
  else
    fail "Patch cannot be applied cleanly. Restore from backup if needed: $BACKUP_DIR"
  fi
}

copy_binary_assets() {
  [ -d "$SCRIPT_DIR/files" ] || return 0
  log "Copying binary assets only"
  local copied=0
  while IFS= read -r -d '' src; do
    if grep -Iq . "$src"; then
      continue
    fi
    local rel="${src#"$SCRIPT_DIR/files/"}"
    local dst="$TARGET/$rel"
    mkdir -p "$(dirname "$dst")"
    cp -f "$src" "$dst"
    copied=$((copied + 1))
    echo "Copied binary asset: $rel"
  done < <(find "$SCRIPT_DIR/files" -type f -print0)
  if [ "$copied" -eq 0 ]; then
    echo "No binary assets to copy."
  fi
}

require_target
backup_target
service_action stop
apply_patch_file
copy_binary_assets
service_action start

log "Done"
echo "Installed connection-history patch into: $TARGET"

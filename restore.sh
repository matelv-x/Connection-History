#!/usr/bin/env bash
set -euo pipefail

TARGET="/home/pi/sg1_v4"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --target)
      TARGET="$2"
      shift 2
      ;;
    *)
      TARGET="$1"
      shift
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_FILE="$SCRIPT_DIR/.last_backup_path"
BACKUP_ROOT="${BACKUP_ROOT:-/home/pi}"
BACKUP_DIR=""

if [ -f "$BACKUP_FILE" ]; then
  BACKUP_DIR="$(cat "$BACKUP_FILE")"
fi

if [ -z "$BACKUP_DIR" ] || [ ! -d "$BACKUP_DIR" ]; then
  BACKUP_DIR="$(find "$BACKUP_ROOT" -maxdepth 1 -type d -name 'sg1_v4_backup_connection_history_*' 2>/dev/null | sort | tail -n 1)"
fi

if [ -z "$BACKUP_DIR" ] || [ ! -d "$BACKUP_DIR" ]; then
  echo "ERROR: no backup found. Expected .last_backup_path or $BACKUP_ROOT/sg1_v4_backup_connection_history_*" >&2
  exit 1
fi

echo "Restoring from: $BACKUP_DIR"
sudo systemctl stop stargate.service 2>/dev/null || true
sudo rm -rf "$TARGET"
sudo cp -a "$BACKUP_DIR" "$TARGET"
sudo find "$TARGET" -type d -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true
sudo chown -R pi:pi "$TARGET" 2>/dev/null || true
sudo systemctl start stargate.service 2>/dev/null || true
echo "Restore complete: $TARGET"

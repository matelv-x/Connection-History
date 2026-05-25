#!/usr/bin/env bash
set -euo pipefail

SG1_DIR="${1:-/home/pi/sg1_v4}"

fail() { echo "ERROR: $1" >&2; exit 1; }

[ -d "$SG1_DIR" ] || fail "Target folder not found: $SG1_DIR"

if ! sudo -n true 2>/dev/null; then
  echo "This restore needs sudo because stargate files may be owned by root."
  sudo true
fi

restore_backup_file() {
  local rel="$1"
  local target="$SG1_DIR/$rel"
  local backup=""

  backup="$(ls -t "$target".backup_connection_history_* 2>/dev/null | head -n 1 || true)"
  if [ -z "$backup" ]; then
    backup="$(ls -dt /home/pi/sg1_v4_backup_dynamic_wormhole_only_* 2>/dev/null | head -n 1 || true)"
    if [ -n "$backup" ] && [ -e "$backup/$rel" ]; then
      backup="$backup/$rel"
    else
      backup=""
    fi
  fi

  if [ -n "$backup" ] && [ -e "$backup" ]; then
    sudo mkdir -p "$(dirname "$target")"
    sudo rm -rf "$target"
    sudo cp -a "$backup" "$target"
    echo "Restored: $rel"
  else
    echo "Skipped, no original backup found: $rel"
  fi
}

echo "Removing Connection History add-on from:"
echo "  $SG1_DIR"

sudo systemctl stop stargate.service || true

restore_backup_file "classes/dialing_log.py"
restore_backup_file "config/defaults-milkyway/dialing_log.json.dist"

sudo rm -f "$SG1_DIR/web/connection_history.htm"
sudo rm -f "$SG1_DIR/web/js/connection_history.js"
sudo rm -f "$SG1_DIR/config/milkyway-dialing_history.json"

sudo python3 - "$SG1_DIR" <<'PY'
import re
import sys
from pathlib import Path

base = Path(sys.argv[1])

web_server = base / "classes/web_server.py"
if web_server.exists():
    text = web_server.read_text(encoding="utf-8")
    text = re.sub(
        r'\n\s*elif request_path == "/get/dialing_history":\n'
        r'\s*data = \{\n'
        r'\s*"history": self\.stargate\.dialing_log\.get_history\(\),\n'
        r'\s*"summary": \{\n'
        r'\s*key: value\.get\("value"\)\n'
        r'\s*for key, value in self\.stargate\.dialing_log\.get_summary\(\)\.items\(\)\n'
        r'\s*\}\n'
        r'\s*\}\n',
        "\n",
        text,
        count=1,
    )
    web_server.write_text(text, encoding="utf-8")
    print("Cleaned: classes/web_server.py")

for page in (base / "web").glob("*.htm"):
    if page.name == "connection_history.htm":
        continue
    html = page.read_text(encoding="utf-8", errors="ignore")
    html = re.sub(r'\n\s*<a class="dropdown-item" href="connection_history\.htm">Connection History</a>', "", html)
    page.write_text(html, encoding="utf-8")

retro_nav = base / "web/retro/js/navigation.js"
if retro_nav.exists():
    js = retro_nav.read_text(encoding="utf-8", errors="ignore")
    js = re.sub(r'\n\s*<a \$\{isActive\(\'/connection_history\.htm\'\)\}>Connection History</a>', "", js)
    retro_nav.write_text(js, encoding="utf-8")
    print("Cleaned: web/retro/js/navigation.js")
PY

sudo python3 -m py_compile "$SG1_DIR/classes/web_server.py" "$SG1_DIR/classes/dialing_log.py"
sudo find "$SG1_DIR/classes" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
sudo chown -R pi:pi "$SG1_DIR"
sudo systemctl start stargate.service

echo "=== CONNECTION HISTORY RESTORE COMPLETE ==="

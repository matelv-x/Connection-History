#!/usr/bin/env bash
set -euo pipefail

SG1_DIR="${1:-/home/pi/sg1_v4}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP="$(date +%Y%m%d_%H%M%S)"
HISTORY_STYLE="${HISTORY_STYLE:-}"

echo "Installing Connection History in the 192.168.1.200 style"
echo "Target: $SG1_DIR"
echo

choose_history_style() {
  if [ -n "$HISTORY_STYLE" ]; then
    return 0
  fi

  if [ ! -t 0 ]; then
    HISTORY_STYLE="current"
    echo "No interactive terminal detected. Using style: current"
    return 0
  fi

  echo "Choose Connection History page style:"
  echo "  1) current  - current Pi5 package style, white text on transparent table"
  echo "  2) kristian - original Kristian style, like 192.168.1.111"
  printf "Style [1/current]: "
  read -r style_answer

  case "${style_answer:-1}" in
    1|current|CURRENT)
      HISTORY_STYLE="current"
      ;;
    2|kristian|Kristian|KRISTIAN|original|ORIGINAL)
      HISTORY_STYLE="kristian"
      ;;
    *)
      echo "Unknown style '$style_answer'. Using style: current"
      HISTORY_STYLE="current"
      ;;
  esac
}

choose_history_style

case "$HISTORY_STYLE" in
  current|kristian)
    echo "Selected page style: $HISTORY_STYLE"
    ;;
  *)
    echo "ERROR: HISTORY_STYLE must be 'current' or 'kristian', got: $HISTORY_STYLE"
    exit 1
    ;;
esac

echo

backup_file() {
  local target="$1"
  if [ -f "$target" ]; then
    sudo cp "$target" "$target.backup_connection_history_$STAMP"
  fi
}

copy_project_file() {
  local rel="$1"
  local src="$SCRIPT_DIR/$rel"
  local dst="$SG1_DIR/$rel"

  if [ ! -f "$src" ]; then
    echo "INFO: source file not found next to this installer, using target or embedded fallback: $rel"
    return 0
  fi

  sudo mkdir -p "$(dirname "$dst")"
  backup_file "$dst"
  sudo cp "$src" "$dst"
  echo "Installed: $rel"
}

require_target_file() {
  local rel="$1"
  if [ ! -f "$SG1_DIR/$rel" ]; then
    echo "ERROR: target file missing: $SG1_DIR/$rel"
    exit 1
  fi
}

require_target_file "classes/web_server.py"
require_target_file "classes/StargateMilkyWay/stargate.py"

copy_project_file "classes/dialing_log.py"
copy_project_file "config/defaults-milkyway/dialing_log.json.dist"
copy_project_file "web/connection_history.htm"
copy_project_file "web/js/connection_history.js"

echo
echo "Patching and verifying server integration..."

sudo python3 - "$SG1_DIR" "$HISTORY_STYLE" <<'PY'
from pathlib import Path
import ast
import json
import re
import shutil
import sys

base = Path(sys.argv[1])
history_style = sys.argv[2]

web_server = base / "classes" / "web_server.py"
stargate_py = base / "classes" / "StargateMilkyWay" / "stargate.py"
connection_page = base / "web" / "connection_history.htm"
connection_js = base / "web" / "js" / "connection_history.js"
config_dir = base / "config"
defaults_dir = config_dir / "defaults-milkyway"

dialing_log_py = base / "classes" / "dialing_log.py"
dialing_log_template = 'from datetime import datetime, timezone\nimport json\nimport os\nfrom stargate_config import StargateConfig\nimport rollbar\n\nclass DialingLog():\n\n    def __init__(self, stargate):\n        self.log = stargate.log\n        self.cfg = stargate.cfg\n        self.stargate = stargate\n\n        self.addr_manager = stargate.addr_manager\n\n        self.current_activity = {}\n        self.summary = {}\n\n        # Initialize the Config\n        self.base_path = stargate.base_path\n        self.galaxy_path = stargate.galaxy_path\n        self.datastore = StargateConfig(self.base_path, "dialing_log", self.galaxy_path)\n        self.datastore.set_log(self.log)\n        self.datastore.load()\n        self.history_path = os.path.join(self.base_path, "config", f"{self.galaxy_path}-dialing_history.json")\n\n        self.__reset_state()\n\n    def __reset_summary_storage(self): # pylint: disable=unused-private-member\n\n        self.datastore.set("established_standard_count", 0)    # Lifetime Count of Established Outbound Wormholes to Movie Gates\n        self.datastore.set("established_standard_mins", 0)    # Lifetime Minutes Outbound Established to Movie Gates\n\n        self.datastore.set("established_fan_count", 0)         # Lifetime Count of Established Outbound Wormholes to Fan Gates\n        self.datastore.set("established_fan_mins", 0)          # Lifetime Minutes Outbound Established to Fan Gates\n\n        self.datastore.set("inbound_count", 0)                 # Lifetime Count of Established Inbound Wormholes\n        self.datastore.set("inbound_mins", 0)                  # Lifetime Minutes Inbound Established\n\n        self.datastore.set("dialing_failures", 0)              # Lifetime Failed Dialing Attempts\n\n    def get_summary(self):\n        return self.datastore.get_all_configs()\n\n    def get_history(self, limit=None):\n        history = self.__load_history()\n        return history[::-1]\n\n    def dialing_fail(self, address_buffer):\n        self.current_activity[\'start_time\'] = self.__get_time_now()\n        self.current_activity[\'end_time\'] = self.current_activity[\'start_time\']\n        self.current_activity[\'dialer_address\'] = self.addr_manager.get_book().get_local_address()\n        self.current_activity[\'receiver_address\'] = address_buffer\n        remote = self.__get_gate_details_by_address(address_buffer)\n\n        # Persist this activity\n        self.log.log("Dialing Log: Failed Outbound Dialing")\n        # self.log.log(f"   Start Time: {self.activity_start_time}")\n        # self.log.log(f"   End Time: {self.activity_end_time}")\n        self.log.log(f"   Dialer Address: {self.current_activity[\'dialer_address\']}")\n        self.log.log(f"   Address Buffer: {self.current_activity[\'receiver_address\']}")\n\n        # Update the Summary\n        self.datastore.set(\'dialing_failures\', self.datastore.get(\'dialing_failures\') + 1)\n        self.__append_history({\n            "activity": "Failed",\n            "status": "Failed",\n            "gate_name": remote["gate_name"],\n            "gate_type": remote["gate_type"],\n            "gate_address": remote["gate_address"],\n            "source_ip": remote["source_ip"],\n            "start_time": self.__format_time(self.current_activity[\'start_time\']),\n            "end_time": self.__format_time(self.current_activity[\'end_time\']),\n            "mins": 0,\n            "dialer_address": self.current_activity[\'dialer_address\'],\n            "receiver_address": address_buffer\n        })\n\n        # Update Rollbar\n        rollbar.report_message(\'Failed Outbound Dialing\', \'info\')\n\n    def established_inbound(self, dialing_gate_address=None, gate_name=None, source_ip=None):\n        if dialing_gate_address is None:\n            dialing_gate_address = getattr(self.stargate, "fan_gate_incoming_address", None)\n        if gate_name is None:\n            gate_name = getattr(self.stargate, "connected_planet_name", None)\n        if source_ip is None:\n            source_ip = getattr(self.stargate, "fan_gate_incoming_ip", None)\n\n        remote = self.__get_gate_details_by_address(dialing_gate_address)\n        self.current_activity[\'activity\'] = "Inbound"\n        self.current_activity[\'start_time\'] = self.__get_time_now()\n        self.current_activity[\'dialer_address\'] = dialing_gate_address\n        self.current_activity[\'receiver_address\'] = self.addr_manager.get_book().get_local_address()\n        self.current_activity[\'remote_gate_type\'] = remote["gate_type"]\n        self.current_activity[\'remote_gate_name\'] = gate_name or remote["gate_name"]\n        self.current_activity[\'remote_source_ip\'] = source_ip or remote["source_ip"]\n        self.log.log("Dialing Log: Established Inbound")\n\n        # Update the Summary\n        self.datastore.set(\'inbound_count\', self.datastore.get(\'inbound_count\') + 1)\n\n        # Update Rollbar\n        rollbar.report_message(\'Established Inbound\', \'info\')\n\n    def established_outbound(self, receiver_address):\n        remote = self.__get_gate_details_by_address(receiver_address)\n        self.current_activity[\'activity\'] = "Outbound"\n        self.current_activity[\'start_time\'] = self.__get_time_now()\n        self.current_activity[\'dialer_address\']= self.addr_manager.get_book().get_local_address()\n        self.current_activity[\'receiver_address\'] = receiver_address\n        self.current_activity[\'remote_gate_type\'] = remote["gate_type"]\n        self.current_activity[\'remote_gate_name\'] = remote["gate_name"]\n        self.current_activity[\'remote_source_ip\'] = remote["source_ip"]\n\n        if self.current_activity[\'remote_gate_type\'] == "FAN":\n            self.datastore.set(\'established_fan_count\', self.datastore.get(\'established_fan_count\') + 1)\n        else:\n            self.datastore.set(\'established_standard_count\', self.datastore.get(\'established_standard_count\') + 1)\n\n        self.log.log("Dialing Log: Established Outbound")\n\n        # Update Rollbar\n        rollbar.report_message(\'Established Outbound\', \'info\')\n\n    def shutdown(self):\n\n        # Just return if we don\'t have an established activity (on boot)\n        if self.current_activity[\'activity\'] is None:\n            self.log.log("Gate is idle.")\n            return\n\n        # Log the shutdown time and calculate time established\n        self.current_activity[\'end_time\'] = self.__get_time_now()\n        elapsed = self.__get_minutes_elapsed()\n\n        self.log.log("Dialing Log: Shutdown")\n\n        # Persist this activity\n        self.log.log(f"   Activity: {self.current_activity[\'activity\']}")\n        self.log.log(f"   Gate Type: {self.current_activity[\'remote_gate_type\']}")\n        self.log.log(f"   Start Time: {self.current_activity[\'start_time\']}")\n        self.log.log(f"   End Time: {self.current_activity[\'end_time\']}")\n        self.log.log(f"   Elapsed: {elapsed} minutes")\n        self.log.log(f"   Dialer Address: {self.current_activity[\'dialer_address\']}")\n        self.log.log(f"   Receiver Address: {self.current_activity[\'receiver_address\']}")\n\n        if self.current_activity[\'activity\'] == "Outbound":\n            if self.current_activity[\'remote_gate_type\'] == "FAN":\n                self.datastore.set(\'established_fan_mins\', self.datastore.get(\'established_fan_mins\') + elapsed)\n            else: # standard/movie\n                self.datastore.set(\'established_standard_mins\', self.datastore.get(\'established_standard_mins\') + elapsed)\n        else: # Inbound\n            self.datastore.set(\'inbound_mins\', self.datastore.get(\'inbound_mins\') + elapsed)\n\n        self.__append_history({\n            "activity": self.current_activity[\'activity\'],\n            "status": "Established",\n            "gate_name": self.current_activity.get(\'remote_gate_name\') or self.__get_name_for_history(),\n            "gate_type": self.current_activity.get(\'remote_gate_type\') or "",\n            "gate_address": self.__get_remote_address_for_history(),\n            "source_ip": self.current_activity.get(\'remote_source_ip\') or "",\n            "start_time": self.__format_time(self.current_activity[\'start_time\']),\n            "end_time": self.__format_time(self.current_activity[\'end_time\']),\n            "mins": elapsed,\n            "dialer_address": self.current_activity[\'dialer_address\'],\n            "receiver_address": self.current_activity[\'receiver_address\']\n        })\n\n        # Update Rollbar\n        rollbar.report_message(\'Disengaged\', \'info\')\n\n        # Reset the state vars to get ready for the next activity\n        self.__reset_state()\n\n    def __reset_state(self):\n        self.current_activity[\'activity\'] = None\n        self.current_activity[\'remove_address_type\'] = None\n        self.current_activity[\'start_time\'] = None\n        self.current_activity[\'dialer_address\'] = None\n        self.current_activity[\'receiver_address\'] = None\n        self.current_activity[\'remote_gate_type\'] = None\n        self.current_activity[\'remote_gate_name\'] = None\n        self.current_activity[\'remote_source_ip\'] = None\n        self.log.log("Dialing Log: Idle")\n\n        # Update Rollbar\n        rollbar.report_message(\'Gate Idle\', \'info\')\n\n    @staticmethod\n    def __get_time_now():\n        return datetime.now(timezone.utc)\n\n    def __get_minutes_elapsed(self):\n        diff = self.current_activity[\'end_time\'] - self.current_activity[\'start_time\']\n        minutes = diff.total_seconds() / 60\n        return minutes\n\n\n    @staticmethod\n    def __format_time(value):\n        if hasattr(value, "isoformat"):\n            return value.isoformat()\n        return value\n\n    def __get_gate_details_by_address(self, address):\n        gate_address = self.__address_without_origin(address)\n        entry = self.addr_manager.get_book().get_entry_by_address(gate_address) if gate_address else None\n        if entry:\n            return {\n                "gate_name": entry.get("name", "Unknown"),\n                "gate_type": str(entry.get("type", "")).upper(),\n                "gate_address": entry.get("gate_address", gate_address),\n                "source_ip": entry.get("ip_address", "")\n            }\n\n        return {\n            "gate_name": "Unknown Address",\n            "gate_type": "UNKNOWN",\n            "gate_address": gate_address or address,\n            "source_ip": ""\n        }\n\n    @staticmethod\n    def __address_without_origin(address):\n        if not isinstance(address, list):\n            return address\n        if len(address) >= 7:\n            return address[:-1]\n        return address\n\n    def __get_name_for_history(self):\n        if self.current_activity[\'activity\'] == "Outbound":\n            return self.__get_gate_details_by_address(self.current_activity[\'receiver_address\'])["gate_name"]\n        return getattr(self.stargate, "connected_planet_name", None) or "Unknown"\n\n    def __get_remote_address_for_history(self):\n        if self.current_activity[\'activity\'] == "Outbound":\n            return self.__address_without_origin(self.current_activity[\'receiver_address\'])\n        return self.current_activity[\'dialer_address\']\n\n    def __load_history(self):\n        try:\n            with open(self.history_path, "r", encoding="utf8") as history_file:\n                data = json.load(history_file)\n        except (OSError, json.JSONDecodeError):\n            return []\n\n        if isinstance(data, dict):\n            history = data.get("history", {}).get("value", [])\n            return history if isinstance(history, list) else []\n        if isinstance(data, list):\n            return data\n        return []\n\n    def __append_history(self, event):\n        history = self.__load_history()\n        history.append(event)\n\n        data = {\n            "history": {\n                "value": history,\n                "desc": "Recent Stargate connection history",\n                "type": "list"\n            }\n        }\n\n        with open(self.history_path, "w+", encoding="utf8") as history_file:\n            json.dump(data, history_file, indent=2)\n'
if dialing_log_py.exists():
    dialing_log_text = dialing_log_py.read_text(encoding="utf-8")
    if "def get_history" not in dialing_log_text or "def __append_history" not in dialing_log_text:
        dialing_log_py.write_text(dialing_log_template, encoding="utf-8")
        print("Updated: classes/dialing_log.py with detailed history support")
    else:
        updated_dialing_log_text = dialing_log_text
        updated_dialing_log_text = re.sub(
            r"(?ms)^    def get_history\(self, limit=100\):\n"
            r"        history = self\.__load_history\(\)\n"
            r"        return history\[-limit:\]\[::-1\]",
            "    def get_history(self, limit=None):\n"
            "        history = self.__load_history()\n"
            "        return history[::-1]",
            updated_dialing_log_text,
            count=1,
        )
        updated_dialing_log_text = updated_dialing_log_text.replace(
            "\n        history = history[-250:]\n\n        data = {",
            "\n\n        data = {",
            1,
        )
        old_inbound_block = """        self.current_activity['activity'] = "Inbound"
        self.current_activity['start_time'] = self.__get_time_now()
        self.current_activity['dialer_address'] = dialing_gate_address
        self.current_activity['receiver_address'] = self.addr_manager.get_book().get_local_address()
        self.current_activity['remote_gate_type'] = "INBOUND"
        self.current_activity['remote_gate_name'] = gate_name or "Unknown"
        self.current_activity['remote_source_ip'] = source_ip
"""
        new_inbound_block = """        remote = self.__get_gate_details_by_address(dialing_gate_address)
        self.current_activity['activity'] = "Inbound"
        self.current_activity['start_time'] = self.__get_time_now()
        self.current_activity['dialer_address'] = dialing_gate_address
        self.current_activity['receiver_address'] = self.addr_manager.get_book().get_local_address()
        self.current_activity['remote_gate_type'] = remote["gate_type"]
        self.current_activity['remote_gate_name'] = gate_name or remote["gate_name"]
        self.current_activity['remote_source_ip'] = source_ip or remote["source_ip"]
"""
        updated_dialing_log_text = updated_dialing_log_text.replace(
            old_inbound_block,
            new_inbound_block,
            1,
        )
        if updated_dialing_log_text != dialing_log_text:
            dialing_log_py.write_text(updated_dialing_log_text, encoding="utf-8")
            print("Updated: classes/dialing_log.py with current history support")

dialing_log_text = dialing_log_py.read_text(encoding="utf-8")
updated_dialing_log_text = dialing_log_text
updated_dialing_log_text = updated_dialing_log_text.replace(
    """        remote = self.__get_gate_details_by_address(dialing_gate_address)
        self.current_activity['activity'] = "Inbound"
        self.current_activity['start_time'] = self.__get_time_now()
        self.current_activity['dialer_address'] = dialing_gate_address
""",
    """        remote = self.__get_gate_details_by_address(dialing_gate_address)
        if remote["gate_type"] == "UNKNOWN" and source_ip:
            remote = self.__get_gate_details_by_source_ip(source_ip)
        self.current_activity['activity'] = "Inbound"
        self.current_activity['start_time'] = self.__get_time_now()
        self.current_activity['dialer_address'] = dialing_gate_address or remote["gate_address"]
""",
    1,
)

if "def __get_gate_details_by_source_ip" not in updated_dialing_log_text:
    source_ip_helper = '''    def __get_gate_details_by_source_ip(self, source_ip):
        if not source_ip:
            return {
                "gate_name": "Unknown Address",
                "gate_type": "UNKNOWN",
                "gate_address": "",
                "source_ip": ""
            }

        book = self.addr_manager.get_book()
        gate_sets = []
        for method_name, fallback_type in (
            ("get_lan_gates", "LAN"),
            ("get_fan_gates", "FAN"),
            ("get_standard_gates", "STANDARD"),
        ):
            if hasattr(book, method_name):
                gates = getattr(book, method_name)()
                if isinstance(gates, dict):
                    gate_sets.append((gates, fallback_type))

        datastore = getattr(book, "datastore", None)
        if datastore and hasattr(datastore, "get_all_configs"):
            configs = datastore.get_all_configs()
            for key, fallback_type in (
                ("lan_gates", "LAN"),
                ("fan_gates", "FAN"),
                ("standard_gates", "STANDARD"),
            ):
                gates = configs.get(key, {})
                if isinstance(gates, dict) and "value" in gates:
                    gates = gates.get("value", {})
                if isinstance(gates, dict):
                    gate_sets.append((gates, fallback_type))

        for gates, fallback_type in gate_sets:
            for gate in gates.values():
                if not isinstance(gate, dict):
                    continue
                if str(gate.get("ip_address", "")) == str(source_ip):
                    gate_address = gate.get("gate_address") or source_ip
                    return {
                        "gate_name": gate.get("name", "Unknown"),
                        "gate_type": str(gate.get("type", fallback_type)).upper(),
                        "gate_address": gate_address,
                        "source_ip": source_ip
                    }

        return {
            "gate_name": "Unknown Address",
            "gate_type": "UNKNOWN",
            "gate_address": source_ip,
            "source_ip": source_ip
        }

'''
    marker = "    @staticmethod\n    def __address_without_origin(address):\n"
    if marker in updated_dialing_log_text:
        updated_dialing_log_text = updated_dialing_log_text.replace(marker, source_ip_helper + marker, 1)

if updated_dialing_log_text != dialing_log_text:
    dialing_log_py.write_text(updated_dialing_log_text, encoding="utf-8")
    print("Updated: classes/dialing_log.py with inbound source-IP lookup")

config_dir.mkdir(parents=True, exist_ok=True)
defaults_dir.mkdir(parents=True, exist_ok=True)

history_path = config_dir / "milkyway-dialing_history.json"
if not history_path.exists():
    history_path.write_text(json.dumps({
        "history": {
            "value": [],
            "desc": "Recent Stargate connection history",
            "type": "list"
        }
    }, indent=2) + "\n", encoding="utf-8")
    print("Created: config/milkyway-dialing_history.json")

summary_path = config_dir / "milkyway-dialing_log.json"
summary_default = defaults_dir / "dialing_log.json.dist"
if not summary_path.exists():
    if summary_default.exists():
        shutil.copyfile(summary_default, summary_path)
        print("Created: config/milkyway-dialing_log.json")
    else:
        summary_path.write_text(json.dumps({
            "established_standard_count": {"value": 0, "desc": "Lifetime Count of Established Outbound Wormholes to Movie Gates", "type": "int"},
            "established_standard_mins": {"value": 0, "desc": "Lifetime Minutes Outbound Established to Movie Gates", "type": "float"},
            "established_fan_count": {"value": 0, "desc": "Lifetime Count of Established Outbound Wormholes to Fan Gates", "type": "int"},
            "established_fan_mins": {"value": 0, "desc": "Lifetime Minutes Outbound Established to Fan Gates", "type": "float"},
            "inbound_count": {"value": 0, "desc": "Lifetime Count of Established Inbound Wormholes", "type": "int"},
            "inbound_mins": {"value": 0, "desc": "Lifetime Minutes Inbound Established", "type": "float"},
            "dialing_failures": {"value": 0, "desc": "Lifetime Failed Dialing Attempts", "type": "int"}
        }, indent=2) + "\n", encoding="utf-8")
        print("Created fallback: config/milkyway-dialing_log.json")


def config_value(config, key, default):
    field = config.get(key)
    if isinstance(field, dict) and "value" in field:
        return field["value"]
    return default


def set_config_value(config, key, value, desc, value_type):
    field = config.get(key)
    if isinstance(field, dict):
        field["value"] = value
    else:
        config[key] = {"value": value, "desc": desc, "type": value_type}


def load_json_file(path, default):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return default


def parse_address(value):
    value = value.strip()
    try:
        parsed = ast.literal_eval(value)
    except (ValueError, SyntaxError):
        return value
    return parsed if isinstance(parsed, list) else value


def format_legacy_time(value):
    value = str(value or "").strip()
    if not value:
        return ""
    if " " in value and "T" not in value:
        return value.replace(" ", "T", 1)
    return value


def log_payload(line):
    line = line.rstrip("\n")
    if "]" in line:
        return line.split("]", 1)[1].strip()
    return line.strip()


def log_timestamp(line):
    if line.startswith("[") and "]" in line:
        return format_legacy_time(line[1:].split("]", 1)[0])
    return ""


def get_gate_details(address, addresses_config):
    if not isinstance(address, list):
        return {"gate_name": "Unknown Address", "gate_type": "UNKNOWN", "gate_address": address, "source_ip": ""}
    lookup_address = address[:-1] if len(address) >= 7 else address
    for section, gate_type in (("lan_gates", "LAN"), ("fan_gates", "FAN"), ("standard_gates", "STANDARD")):
        gates = config_value(addresses_config, section, {})
        if not isinstance(gates, dict):
            continue
        for gate in gates.values():
            if gate.get("gate_address") == lookup_address:
                return {
                    "gate_name": gate.get("name", "Unknown"),
                    "gate_type": str(gate.get("type", gate_type)).upper(),
                    "gate_address": gate.get("gate_address", lookup_address),
                    "source_ip": gate.get("ip_address", ""),
            }
    return {"gate_name": "Unknown Address", "gate_type": "UNKNOWN", "gate_address": lookup_address, "source_ip": ""}


def get_gate_details_by_source_ip(source_ip, addresses_config):
    if not source_ip:
        return {"gate_name": "Unknown Address", "gate_type": "UNKNOWN", "gate_address": "", "source_ip": ""}
    for section, gate_type in (("lan_gates", "LAN"), ("fan_gates", "FAN"), ("standard_gates", "STANDARD")):
        gates = config_value(addresses_config, section, {})
        if not isinstance(gates, dict):
            continue
        for gate in gates.values():
            if not isinstance(gate, dict):
                continue
            if str(gate.get("ip_address", "")) == str(source_ip):
                return {
                    "gate_name": gate.get("name", "Unknown"),
                    "gate_type": str(gate.get("type", gate_type)).upper(),
                    "gate_address": gate.get("gate_address") or source_ip,
                    "source_ip": source_ip,
                }
    return {"gate_name": "Unknown Address", "gate_type": "UNKNOWN", "gate_address": source_ip, "source_ip": source_ip}


def parse_legacy_milkyway_log(log_path, addresses_config):
    if not log_path.exists():
        return []

    events = []
    active = None

    def flush_active():
        nonlocal active
        if not active:
            return
        if active.get("kind") == "failed" and active.get("receiver_address") is not None:
            remote = get_gate_details(active.get("receiver_address"), addresses_config)
            events.append({
                "activity": "Failed",
                "status": "Failed",
                "gate_name": remote["gate_name"],
                "gate_type": remote["gate_type"],
                "gate_address": remote["gate_address"],
                "source_ip": remote["source_ip"],
                "start_time": active.get("start_time", ""),
                "end_time": active.get("end_time", active.get("start_time", "")),
                "mins": 0,
                "dialer_address": active.get("dialer_address"),
                "receiver_address": active.get("receiver_address"),
            })
        elif active.get("kind") == "shutdown" and active.get("activity") and active.get("receiver_address") is not None:
            remote_address = active.get("receiver_address") if active.get("activity") == "Outbound" else active.get("dialer_address")
            remote = get_gate_details(remote_address, addresses_config)
            gate_type = active.get("gate_type") or remote["gate_type"]
            events.append({
                "activity": active.get("activity"),
                "status": "Established",
                "gate_name": remote["gate_name"],
                "gate_type": str(gate_type).upper(),
                "gate_address": remote["gate_address"],
                "source_ip": remote["source_ip"],
                "start_time": format_legacy_time(active.get("start_time", "")),
                "end_time": format_legacy_time(active.get("end_time", "")),
                "mins": active.get("mins", 0),
                "dialer_address": active.get("dialer_address"),
                "receiver_address": active.get("receiver_address"),
            })
        active = None

    for raw_line in log_path.read_text(encoding="utf-8", errors="ignore").splitlines():
        payload = log_payload(raw_line)
        timestamp = log_timestamp(raw_line)

        if payload.startswith("Dialing Log:"):
            flush_active()
            if payload == "Dialing Log: Failed Outbound Dialing":
                active = {"kind": "failed", "start_time": timestamp, "end_time": timestamp}
            elif payload == "Dialing Log: Shutdown":
                active = {"kind": "shutdown"}
            else:
                active = None
            continue

        if not active or ":" not in payload:
            continue

        key, value = payload.split(":", 1)
        key = key.strip()
        value = value.strip()

        if key == "Activity":
            active["activity"] = value
        elif key == "Gate Type":
            active["gate_type"] = value
        elif key == "Start Time":
            active["start_time"] = value
        elif key == "End Time":
            active["end_time"] = value
        elif key == "Elapsed":
            try:
                active["mins"] = float(value.split()[0])
            except (ValueError, IndexError):
                active["mins"] = 0
        elif key == "Dialer Address":
            active["dialer_address"] = parse_address(value)
        elif key in ("Receiver Address", "Address Buffer"):
            active["receiver_address"] = parse_address(value)

    flush_active()
    return events[-250:]


def import_legacy_history_if_empty():
    history_data = load_json_file(history_path, {})
    existing = history_data if isinstance(history_data, list) else config_value(history_data, "history", [])
    if existing:
        print("Skipped legacy milkyway.log import: history already contains events")
        return

    addresses_config = load_json_file(config_dir / "milkyway-addresses.json", {})
    events = parse_legacy_milkyway_log(base / "logs" / "milkyway.log", addresses_config)
    if not events:
        print("Skipped legacy milkyway.log import: no previous connection events found")
        return

    history_path.write_text(json.dumps({
        "history": {
            "value": events,
            "desc": "Recent Stargate connection history",
            "type": "list"
        }
    }, indent=2) + "\n", encoding="utf-8")

    summary = load_json_file(summary_path, {})
    if all(float(config_value(summary, key, 0) or 0) == 0 for key in (
        "established_standard_count",
        "established_standard_mins",
        "established_fan_count",
        "established_fan_mins",
        "inbound_count",
        "inbound_mins",
        "dialing_failures",
    )):
        established_standard_count = 0
        established_standard_mins = 0.0
        established_fan_count = 0
        established_fan_mins = 0.0
        inbound_count = 0
        inbound_mins = 0.0
        dialing_failures = 0

        for event in events:
            mins = float(event.get("mins") or 0)
            if event.get("status") == "Failed":
                dialing_failures += 1
            elif event.get("activity") == "Inbound":
                inbound_count += 1
                inbound_mins += mins
            elif event.get("gate_type") == "FAN":
                established_fan_count += 1
                established_fan_mins += mins
            else:
                established_standard_count += 1
                established_standard_mins += mins

        set_config_value(summary, "established_standard_count", established_standard_count, "Lifetime Count of Established Outbound Wormholes to Movie Gates", "int")
        set_config_value(summary, "established_standard_mins", established_standard_mins, "Lifetime Minutes Outbound Established to Movie Gates", "float")
        set_config_value(summary, "established_fan_count", established_fan_count, "Lifetime Count of Established Outbound Wormholes to Fan Gates", "int")
        set_config_value(summary, "established_fan_mins", established_fan_mins, "Lifetime Minutes Outbound Established to Fan Gates", "float")
        set_config_value(summary, "inbound_count", inbound_count, "Lifetime Count of Established Inbound Wormholes", "int")
        set_config_value(summary, "inbound_mins", inbound_mins, "Lifetime Minutes Inbound Established", "float")
        set_config_value(summary, "dialing_failures", dialing_failures, "Lifetime Failed Dialing Attempts", "int")
        summary_path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")

    print(f"Imported {len(events)} previous connection event(s) from logs/milkyway.log")


def normalize_existing_inbound_history_types():
    history_data = load_json_file(history_path, {})
    if isinstance(history_data, list):
        events = history_data
        wrapped = False
    else:
        events = config_value(history_data, "history", [])
        wrapped = True

    if not isinstance(events, list):
        return

    addresses_config = load_json_file(config_dir / "milkyway-addresses.json", {})
    changed = 0

    for event in events:
        if not isinstance(event, dict):
            continue
        if event.get("activity") != "Inbound" or str(event.get("gate_type", "")).upper() not in ("INBOUND", "UNKNOWN", ""):
            continue

        remote = get_gate_details(event.get("dialer_address"), addresses_config)
        if remote["gate_type"] == "UNKNOWN" and event.get("source_ip"):
            remote = get_gate_details_by_source_ip(event.get("source_ip"), addresses_config)
        if remote["gate_type"] == "UNKNOWN":
            continue
        event["gate_type"] = remote["gate_type"]
        event["gate_address"] = remote["gate_address"]
        if not event.get("gate_name") or event.get("gate_name") == "Unknown":
            event["gate_name"] = remote["gate_name"]
        if not event.get("source_ip"):
            event["source_ip"] = remote["source_ip"]
        changed += 1

    if not changed:
        return

    if wrapped:
        set_config_value(history_data, "history", events, "Recent Stargate connection history", "list")
        output = history_data
    else:
        output = events

    history_path.write_text(json.dumps(output, indent=2) + "\n", encoding="utf-8")
    print(f"Updated {changed} inbound history event(s) with gate type")


import_legacy_history_if_empty()
normalize_existing_inbound_history_types()

text = web_server.read_text(encoding="utf-8")

if "if path.startswith('/stargate/'):" not in text:
    marker = "        return path, query_string\n"
    patch = (
        "        if path.startswith('/stargate/'):\n"
        "            path = path[len('/stargate'):]\n"
        "        return path, query_string\n"
    )
    if marker not in text:
        raise SystemExit("ERROR: could not patch /stargate prefix support in web_server.py")
    text = text.replace(marker, patch, 1)
    print("Patched: /stargate URL prefix support")

if 'request_path == "/get/dialing_history"' not in text:
    endpoint = '''            elif request_path == "/get/dialing_history":
                data = {
                    "history": self.stargate.dialing_log.get_history(),
                    "summary": {
                        key: value.get("value")
                        for key, value in self.stargate.dialing_log.get_summary().items()
                    }
                }

'''
    marker = '            elif request_path == "/get/config":\n'
    if marker not in text:
        raise SystemExit("ERROR: could not find /get/config marker in web_server.py")
    text = text.replace(marker, endpoint + marker, 1)
    print("Patched: /get/dialing_history endpoint")

web_server.write_text(text, encoding="utf-8")

current_style = '''<style>
      :root {
        --connection-history-accent: #00ff00;
      }

      .starter-template,
      .starter-template p,
      #connection_history_summary,
      #connection_history_summary p,
      .connection-history-lifetime {
        color: #fff !important;
      }

      .starter-template h3,
      #connection_history_summary strong,
      .table thead th {
        color: var(--connection-history-accent) !important;
      }

      .table {
        color: #fff !important;
        --bs-table-bg: transparent !important;
        --bs-table-striped-bg: transparent !important;
        --bs-table-hover-bg: transparent !important;
        --bs-table-active-bg: transparent !important;
      }

      #connection_history_rows tr,
      #connection_history_rows td,
      #connection_history_rows th,
      .table thead th {
        background: transparent !important;
      }

      .table-striped > tbody > tr:nth-of-type(odd),
      .table-striped > tbody > tr:nth-of-type(even) {
        background: transparent !important;
      }

      .table td,
      .table th {
        color: #fff !important;
      }

      .table thead th {
        color: var(--connection-history-accent) !important;
      }
    </style>'''

kristian_style = '''<style>
      :root {
        --connection-history-accent: #00ff00;
      }

      .starter-template,
      .starter-template p,
      #connection_history_summary,
      #connection_history_summary p,
      .connection-history-lifetime,
      .table,
      .table td {
        color: #000 !important;
      }

      .starter-template h3,
      #connection_history_summary strong,
      .table thead th {
        color: var(--connection-history-accent) !important;
      }

      .table {
        --bs-table-bg: transparent !important;
        --bs-table-striped-bg: rgba(255, 255, 255, 0.18) !important;
        --bs-table-hover-bg: rgba(255, 255, 255, 0.28) !important;
        --bs-table-active-bg: rgba(255, 255, 255, 0.28) !important;
      }

      #connection_history_rows td {
        background: transparent !important;
      }
    </style>'''

connection_html_template = '''<!--
*******************************************************************
***   Kristian's Stargate Project - TheStargateProject.com      ***
*******************************************************************
-->

<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, shrink-to-fit=no">
    <meta name="author" content="Jonathan Moyes">
    <link rel="shortcut icon" type="image/x-icon" href="img/favicon.ico"/>

    <title>Connection History | Stargate Command</title>

    <link rel="stylesheet" href="lib/jquery-ui-1.13.0.custom/jquery-ui.min.css">
    <link href="lib/bootstrap-5/css/bootstrap.min.css" rel="stylesheet">

    <script type="text/javascript" src="lib/jquery-3.3.1.min.js"></script>
    <script type="text/javascript" src="lib/jquery-ui-1.13.0.custom/jquery-ui.min.js"></script>

    <link rel="stylesheet" href="main.css" />

    __CONNECTION_HISTORY_STYLE__
  </head>

  <body>
    <script type="text/javascript">
      $(function() {
        doPoll();
        updateConnectionHistory();
      });
    </script>

    <nav class="navbar navbar-expand-md navbar-dark bg-dark fixed-top">
      <a class="navbar-brand" href="/">Stargate Command</a>
      <button class="navbar-toggler" type="button" data-bs-toggle="collapse" data-bs-target="#navbarsExampleDefault">
        <span class="navbar-toggler-icon"></span>
      </button>

      <div class="collapse navbar-collapse" id="navbarsExampleDefault">
        <ul class="navbar-nav mr-auto">
          <li class="nav-item"><a class="nav-link" href="index.htm">Home</a></li>
          <li class="nav-item"><a class="nav-link" href="address_book.htm">Address Book</a></li>
          <li class="nav-item"><a class="nav-link" href="symbol_overview.htm">Symbols</a></li>
          <li class="nav-item dropdown">
            <a class="nav-link dropdown-toggle active" href="#" data-bs-toggle="dropdown">Admin</a>
            <div class="dropdown-menu">
              <a class="dropdown-item" href="debug.htm">Testing / Debug</a>
              <a class="dropdown-item" href="sound_board.htm">Sound Board</a>
              <a class="dropdown-item active" href="#">Connection History</a>
              <a><hr></a>
              <a class="dropdown-item" href="config.htm">Configuration</a>
              <a class="dropdown-item" href="info.htm">System Information</a>
              <a><hr></a>
              <a class="dropdown-item" href="#" onClick="software_restart()">Restart Software</a>
              <a class="dropdown-item" href="#" onClick="host_reboot()">Reboot Raspberry Pi</a>
              <a class="dropdown-item" href="#" onClick="host_shutdown()">Shutdown Raspberry Pi</a>
            </div>
          </li>
          <li class="nav-item"><a class="nav-link" href="help.htm">Help</a></li>
        </ul>
      </div>
    </nav>

    <div class='header_image_container'>
      <img class='header_image' src="img/header.jpg" alt="">
    </div>

    <main role="main" class="container">
      <div class="starter-template">
        <h3>Connection History</h3>
        <p>Established inbound/outbound wormholes and failed dialing attempts.</p>
        <div id="connection_history_summary"></div>
        <div class="table-responsive">
          <table class="table table-striped table-sm">
            <thead>
              <tr>
                <th>Time</th>
                <th>Direction</th>
                <th>Status</th>
                <th>Gate</th>
                <th>Type</th>
                <th>Address</th>
                <th>Source IP</th>
                <th>Duration</th>
              </tr>
            </thead>
            <tbody id="connection_history_rows"></tbody>
          </table>
        </div>
      </div>
    </main>

    <script src="/lib/bootstrap-5/js/bootstrap.bundle.min.js"></script>
    <script src="/js/top_menu.js"></script>
    <script src="/js/gate_offline_polling.js"></script>
    <script src="/js/connection_history.js"></script>
  </body>
</html>
'''

connection_js_template = '''function poll_success(singleShot, data){
  hideOfflineModal();
  is_online = true;
  poll_delay = poll_delay_default;

  if (!singleShot){
    setTimeout(function(){doPoll(false);}, poll_delay);
  }
}

function updateConnectionHistory(){
  $.get('/stargate/get/dialing_history')
    .done(function(data) {
      const events = data.history || [];
      const summary = data.summary || {};
      $('#connection_history_summary').html(buildSummaryHtml(events, summary));
      $('#connection_history_rows').html('');

      if (events.length === 0) {
        $('#connection_history_rows').append(
          '<tr><td colspan="8">Detailed connection history has not been recorded yet. Lifetime totals are shown above.</td></tr>'
        );
        return;
      }

      $.each(events, function(index, event) {
        $('#connection_history_rows').append(
          '<tr>' +
            '<td>' + escapeHtml(formatTime(event.start_time)) + '</td>' +
            '<td>' + escapeHtml(event.activity || '') + '</td>' +
            '<td>' + escapeHtml(event.status || '') + '</td>' +
            '<td>' + escapeHtml(event.gate_name || '') + '</td>' +
            '<td>' + escapeHtml(event.gate_type || '') + '</td>' +
            '<td>' + escapeHtml(formatAddress(event.gate_address)) + '</td>' +
            '<td>' + escapeHtml(event.source_ip || '') + '</td>' +
            '<td>' + escapeHtml(formatDuration(event.mins)) + '</td>' +
          '</tr>'
        );
      });
    })
    .fail(function() {
      $('#connection_history_summary').html('<p>Unable to load connection history.</p>');
      $('#connection_history_rows').html(
        '<tr><td colspan="8">Unable to load connection history.</td></tr>'
      );
    });
}

function buildSummaryHtml(events, summary) {
  const totalConnections = numberValue(summary.established_fan_count) +
    numberValue(summary.established_standard_count) +
    numberValue(summary.inbound_count);
  const totalMinutes = numberValue(summary.established_fan_mins) +
    numberValue(summary.established_standard_mins) +
    numberValue(summary.inbound_mins);

  return '' +
    '<p>Showing ' + events.length + ' detailed connection event(s).</p>' +
    '<div class="connection-history-lifetime">' +
      '<strong>Lifetime totals:</strong> ' +
      'Connections: ' + totalConnections + ' | ' +
      'Inbound: ' + numberValue(summary.inbound_count) + ' | ' +
      'Outbound fan: ' + numberValue(summary.established_fan_count) + ' | ' +
      'Outbound standard: ' + numberValue(summary.established_standard_count) + ' | ' +
      'Failures: ' + numberValue(summary.dialing_failures) + ' | ' +
      'Open time: ' + formatDuration(totalMinutes) +
    '</div>';
}

function numberValue(value) {
  const number = parseFloat(value);
  return isFinite(number) ? number : 0;
}

function formatAddress(value) {
  if ($.isArray(value)) {
    return value.join('-');
  }
  if (value === null || typeof value === 'undefined') {
    return '';
  }
  return String(value);
}

function formatDuration(value) {
  const mins = parseFloat(value);
  if (!isFinite(mins) || mins <= 0) {
    return '';
  }
  if (mins < 1) {
    return Math.round(mins * 60) + 's';
  }
  return mins.toFixed(1) + ' min';
}

function formatTime(value) {
  if (!value) return '';
  const date = new Date(value);
  if (isNaN(date.getTime())) return value;
  return date.toLocaleString();
}

function escapeHtml(value) {
  return String(value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#039;');
}
'''

selected_style = current_style if history_style == "current" else kristian_style

if not connection_page.exists():
    connection_page.parent.mkdir(parents=True, exist_ok=True)
    connection_page.write_text(
        connection_html_template.replace("__CONNECTION_HISTORY_STYLE__", selected_style),
        encoding="utf-8"
    )
    print("Created: web/connection_history.htm")

if not connection_js.exists():
    connection_js.parent.mkdir(parents=True, exist_ok=True)
    connection_js.write_text(connection_js_template, encoding="utf-8")
    print("Created: web/js/connection_history.js")

if connection_page.exists():
    html = connection_page.read_text(encoding="utf-8")
    html, count = re.subn(r"<style>.*?</style>", selected_style, html, count=1, flags=re.S)
    if count == 0:
        html = html.replace("</head>", selected_style + "\n  </head>", 1)
    connection_page.write_text(html, encoding="utf-8")
    print(f"Applied Connection History style: {history_style}")
else:
    print("WARN: web/connection_history.htm is missing, style was not applied")

stargate_text = stargate_py.read_text(encoding="utf-8")
active_inbound_hook = re.search(
    r"(?m)^\s*self\.dialing_log\.established_inbound\s*\(",
    stargate_text,
)
if not active_inbound_hook:
    legacy_inbound_marker = """                # Log the connection!
                # TODO: hook this up!
                #self.dialing_log.established_inbound( self.inbound_dialer)
"""
    inbound_hook = """                # Log the connection!
                self.dialing_log.established_inbound(
                    getattr(self, "fan_gate_incoming_address", None),
                    getattr(self, "connected_planet_name", None),
                    getattr(self, "fan_gate_incoming_ip", None)
                )
"""
    if legacy_inbound_marker in stargate_text:
        stargate_text = stargate_text.replace(legacy_inbound_marker, inbound_hook, 1)
        stargate_py.write_text(stargate_text, encoding="utf-8")
        print("Patched: active inbound history hook in classes/StargateMilkyWay/stargate.py")
    else:
        incoming_log = "                self.log.log(f'INCOMING Wormhole from {self.connected_planet_name} established')\n"
        if incoming_log in stargate_text:
            stargate_text = stargate_text.replace(incoming_log, incoming_log + "\n" + inbound_hook, 1)
            stargate_py.write_text(stargate_text, encoding="utf-8")
            print("Patched: active inbound history hook in classes/StargateMilkyWay/stargate.py")
        else:
            print("WARN: could not find incoming wormhole marker for inbound history hook")

missing = []
stargate_text = stargate_py.read_text(encoding="utf-8")
checks = {
    "from dialing_log import DialingLog": "DialingLog import",
    "self.dialing_log = DialingLog(self)": "DialingLog initialization",
    "self.dialing_log.established_outbound": "outbound established history hook",
    "self.dialing_log.dialing_fail": "failed dialing history hook",
    "self.dialing_log.shutdown": "wormhole shutdown history hook",
}

for needle, label in checks.items():
    if needle not in stargate_text:
        missing.append(label)

if not re.search(r"(?m)^\s*self\.dialing_log\.established_inbound\s*\(", stargate_text):
    missing.append("inbound established history hook")

if missing:
    print()
    print("WARN: history page and endpoint are installed, but Stargate hooks are missing:")
    for item in missing:
        print(f"  - {item}")
    print("WARN: install the current sg1_v4 Pi5 package or patch stargate.py before expecting new events.")
else:
    print("Verified: Stargate history hooks are present")

for page in (base / "web").glob("*.htm"):
    if page.name == "connection_history.htm":
        continue
    html = page.read_text(encoding="utf-8", errors="ignore")
    if "connection_history.htm" in html:
        continue
    anchors = [
        '<a class="dropdown-item" href="sound_board.htm">Sound Board</a>',
        '<a class="dropdown-item" href="#">Sound Board</a>',
        '<a class="dropdown-item" href="debug.htm">Testing / Debug</a>',
    ]
    for anchor in anchors:
        if anchor in html:
            link = anchor + '\n              <a class="dropdown-item" href="connection_history.htm">Connection History</a>'
            page.write_text(html.replace(anchor, link, 1), encoding="utf-8")
            print(f"Patched nav link: web/{page.name}")
            break
    else:
        print(f"WARN: could not find admin menu marker in web/{page.name}")

retro_nav = base / "web" / "retro" / "js" / "navigation.js"
if retro_nav.exists():
    js = retro_nav.read_text(encoding="utf-8", errors="ignore")
    if "connection_history.htm" not in js:
        anchors = [
            "            <a ${isActive('/sound_board.htm')}>Sound Board</a>",
            "            <a ${isActive('/debug.htm')}>Testing / Debug</a>",
        ]
        for anchor in anchors:
            if anchor in js:
                link = anchor + "\n            <a ${isActive('/connection_history.htm')}>Connection History</a>"
                retro_nav.write_text(js.replace(anchor, link, 1), encoding="utf-8")
                print("Patched nav link: web/retro/js/navigation.js")
                break
        else:
            print("WARN: could not find retro admin nav marker")

PY

echo
echo "Checking Python syntax..."
sudo python3 -m py_compile \
  "$SG1_DIR/classes/web_server.py" \
  "$SG1_DIR/classes/dialing_log.py" \
  "$SG1_DIR/classes/StargateMilkyWay/stargate.py"

echo
echo "Restarting Stargate service..."
sudo systemctl restart stargate.service

echo
echo "Checking endpoint..."
if curl -fsS "http://127.0.0.1:8080/get/dialing_history" >/tmp/stargate_dialing_history_check.json; then
  echo "OK: /get/dialing_history responds on port 8080"
else
  echo "WARN: endpoint check failed on port 8080. Check: sudo systemctl status stargate.service"
fi

echo
echo "DONE."
echo "Open:"
echo "http://stargate.local/connection_history.htm"
echo "or:"
echo "http://<raspberry-pi-ip>/connection_history.htm"

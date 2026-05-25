from datetime import datetime, timezone
import json
import os
from stargate_config import StargateConfig
import rollbar

class DialingLog():

    def __init__(self, stargate):
        self.log = stargate.log
        self.cfg = stargate.cfg
        self.stargate = stargate

        self.addr_manager = stargate.addr_manager

        self.current_activity = {}
        self.summary = {}

        # Initialize the Config
        self.base_path = stargate.base_path
        self.galaxy_path = stargate.galaxy_path
        self.datastore = StargateConfig(self.base_path, "dialing_log", self.galaxy_path)
        self.datastore.set_log(self.log)
        self.datastore.load()
        self.history_path = os.path.join(self.base_path, "config", f"{self.galaxy_path}-dialing_history.json")

        self.__reset_state()

    def __reset_summary_storage(self): # pylint: disable=unused-private-member

        self.datastore.set("established_standard_count", 0)    # Lifetime Count of Established Outbound Wormholes to Movie Gates
        self.datastore.set("established_standard_mins", 0)    # Lifetime Minutes Outbound Established to Movie Gates

        self.datastore.set("established_fan_count", 0)         # Lifetime Count of Established Outbound Wormholes to Fan Gates
        self.datastore.set("established_fan_mins", 0)          # Lifetime Minutes Outbound Established to Fan Gates

        self.datastore.set("inbound_count", 0)                 # Lifetime Count of Established Inbound Wormholes
        self.datastore.set("inbound_mins", 0)                  # Lifetime Minutes Inbound Established

        self.datastore.set("dialing_failures", 0)              # Lifetime Failed Dialing Attempts

    def get_summary(self):
        return self.datastore.get_all_configs()

    def get_history(self, limit=100):
        history = self.__load_history()
        return history[-limit:][::-1]

    def dialing_fail(self, address_buffer):
        self.current_activity['start_time'] = self.__get_time_now()
        self.current_activity['end_time'] = self.current_activity['start_time']
        self.current_activity['dialer_address'] = self.addr_manager.get_book().get_local_address()
        self.current_activity['receiver_address'] = address_buffer
        remote = self.__get_gate_details_by_address(address_buffer)

        # Persist this activity
        self.log.log("Dialing Log: Failed Outbound Dialing")
        # self.log.log(f"   Start Time: {self.activity_start_time}")
        # self.log.log(f"   End Time: {self.activity_end_time}")
        self.log.log(f"   Dialer Address: {self.current_activity['dialer_address']}")
        self.log.log(f"   Address Buffer: {self.current_activity['receiver_address']}")

        # Update the Summary
        self.datastore.set('dialing_failures', self.datastore.get('dialing_failures') + 1)
        self.__append_history({
            "activity": "Failed",
            "status": "Failed",
            "gate_name": remote["gate_name"],
            "gate_type": remote["gate_type"],
            "gate_address": remote["gate_address"],
            "source_ip": remote["source_ip"],
            "start_time": self.__format_time(self.current_activity['start_time']),
            "end_time": self.__format_time(self.current_activity['end_time']),
            "mins": 0,
            "dialer_address": self.current_activity['dialer_address'],
            "receiver_address": address_buffer
        })

        # Update Rollbar
        #rollbar.report_message('Failed Outbound Dialing', 'info')

    def established_inbound(self, dialing_gate_address=None, gate_name=None, source_ip=None):
        if dialing_gate_address is None:
            dialing_gate_address = getattr(self.stargate, "fan_gate_incoming_address", None)
        if gate_name is None:
            gate_name = getattr(self.stargate, "connected_planet_name", None)
        if source_ip is None:
            source_ip = getattr(self.stargate, "fan_gate_incoming_ip", None)

        self.current_activity['activity'] = "Inbound"
        self.current_activity['start_time'] = self.__get_time_now()
        self.current_activity['dialer_address'] = dialing_gate_address
        self.current_activity['receiver_address'] = self.addr_manager.get_book().get_local_address()
        self.current_activity['remote_gate_type'] = "INBOUND"
        self.current_activity['remote_gate_name'] = gate_name or "Unknown"
        self.current_activity['remote_source_ip'] = source_ip
        self.log.log("Dialing Log: Established Inbound")

        # Update the Summary
        self.datastore.set('inbound_count', self.datastore.get('inbound_count') + 1)

        # Update Rollbar
        #rollbar.report_message('Established Inbound', 'info')

    def established_outbound(self, receiver_address):
        remote = self.__get_gate_details_by_address(receiver_address)
        self.current_activity['activity'] = "Outbound"
        self.current_activity['start_time'] = self.__get_time_now()
        self.current_activity['dialer_address']= self.addr_manager.get_book().get_local_address()
        self.current_activity['receiver_address'] = receiver_address
        self.current_activity['remote_gate_type'] = remote["gate_type"]
        self.current_activity['remote_gate_name'] = remote["gate_name"]
        self.current_activity['remote_source_ip'] = remote["source_ip"]

        if self.current_activity['remote_gate_type'] == "FAN":
            self.datastore.set('established_fan_count', self.datastore.get('established_fan_count') + 1)
        else:
            self.datastore.set('established_standard_count', self.datastore.get('established_standard_count') + 1)

        self.log.log("Dialing Log: Established Outbound")

        # Update Rollbar
        #rollbar.report_message('Established Outbound', 'info')

    def shutdown(self):

        # Just return if we don't have an established activity (on boot)
        if self.current_activity['activity'] is None:
            self.log.log("Gate is idle.")
            return

        # Log the shutdown time and calculate time established
        self.current_activity['end_time'] = self.__get_time_now()
        elapsed = self.__get_minutes_elapsed()

        self.log.log("Dialing Log: Shutdown")

        # Persist this activity
        self.log.log(f"   Activity: {self.current_activity['activity']}")
        self.log.log(f"   Gate Type: {self.current_activity['remote_gate_type']}")
        self.log.log(f"   Start Time: {self.current_activity['start_time']}")
        self.log.log(f"   End Time: {self.current_activity['end_time']}")
        self.log.log(f"   Elapsed: {elapsed} minutes")
        self.log.log(f"   Dialer Address: {self.current_activity['dialer_address']}")
        self.log.log(f"   Receiver Address: {self.current_activity['receiver_address']}")

        if self.current_activity['activity'] == "Outbound":
            if self.current_activity['remote_gate_type'] == "FAN":
                self.datastore.set('established_fan_mins', self.datastore.get('established_fan_mins') + elapsed)
            else: # standard/movie
                self.datastore.set('established_standard_mins', self.datastore.get('established_standard_mins') + elapsed)
        else: # Inbound
            self.datastore.set('inbound_mins', self.datastore.get('inbound_mins') + elapsed)

        self.__append_history({
            "activity": self.current_activity['activity'],
            "status": "Established",
            "gate_name": self.current_activity.get('remote_gate_name') or self.__get_name_for_history(),
            "gate_type": self.current_activity.get('remote_gate_type') or "",
            "gate_address": self.__get_remote_address_for_history(),
            "source_ip": self.current_activity.get('remote_source_ip') or "",
            "start_time": self.__format_time(self.current_activity['start_time']),
            "end_time": self.__format_time(self.current_activity['end_time']),
            "mins": elapsed,
            "dialer_address": self.current_activity['dialer_address'],
            "receiver_address": self.current_activity['receiver_address']
        })

        # Update Rollbar
        #rollbar.report_message('Disengaged', 'info')

        # Reset the state vars to get ready for the next activity
        self.__reset_state()

    def __reset_state(self):
        self.current_activity['activity'] = None
        self.current_activity['remove_address_type'] = None
        self.current_activity['start_time'] = None
        self.current_activity['dialer_address'] = None
        self.current_activity['receiver_address'] = None
        self.current_activity['remote_gate_type'] = None
        self.current_activity['remote_gate_name'] = None
        self.current_activity['remote_source_ip'] = None
        self.log.log("Dialing Log: Idle")

        # Update Rollbar
        #rollbar.report_message('Gate Idle', 'info')

    @staticmethod
    def __get_time_now():
        return datetime.now(timezone.utc)

    def __get_minutes_elapsed(self):
        diff = self.current_activity['end_time'] - self.current_activity['start_time']
        minutes = diff.total_seconds() / 60
        return minutes


    @staticmethod
    def __format_time(value):
        if hasattr(value, "isoformat"):
            return value.isoformat()
        return value

    def __get_gate_details_by_address(self, address):
        gate_address = self.__address_without_origin(address)
        entry = self.addr_manager.get_book().get_entry_by_address(gate_address) if gate_address else None
        if entry:
            return {
                "gate_name": entry.get("name", "Unknown"),
                "gate_type": str(entry.get("type", "")).upper(),
                "gate_address": entry.get("gate_address", gate_address),
                "source_ip": entry.get("ip_address", "")
            }

        return {
            "gate_name": "Unknown Address",
            "gate_type": "UNKNOWN",
            "gate_address": gate_address or address,
            "source_ip": ""
        }

    @staticmethod
    def __address_without_origin(address):
        if not isinstance(address, list):
            return address
        if len(address) >= 7:
            return address[:-1]
        return address

    def __get_name_for_history(self):
        if self.current_activity['activity'] == "Outbound":
            return self.__get_gate_details_by_address(self.current_activity['receiver_address'])["gate_name"]
        return getattr(self.stargate, "connected_planet_name", None) or "Unknown"

    def __get_remote_address_for_history(self):
        if self.current_activity['activity'] == "Outbound":
            return self.__address_without_origin(self.current_activity['receiver_address'])
        return self.current_activity['dialer_address']

    def __load_history(self):
        try:
            with open(self.history_path, "r", encoding="utf8") as history_file:
                data = json.load(history_file)
        except (OSError, json.JSONDecodeError):
            return []

        if isinstance(data, dict):
            history = data.get("history", {}).get("value", [])
            return history if isinstance(history, list) else []
        if isinstance(data, list):
            return data
        return []

    def __append_history(self, event):
        history = self.__load_history()
        history.append(event)
        history = history[-250:]

        data = {
            "history": {
                "value": history,
                "desc": "Recent Stargate connection history",
                "type": "list"
            }
        }

        with open(self.history_path, "w+", encoding="utf8") as history_file:
            json.dump(data, history_file, indent=2)

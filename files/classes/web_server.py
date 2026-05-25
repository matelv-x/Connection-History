import os
import json
import re
from time import sleep
import urllib.parse
import collections
import platform
import random
import time
from http.server import SimpleHTTPRequestHandler


class StargateWebServer(SimpleHTTPRequestHandler):

    # Overload SimpleHTTPRequestHandler.log_message() to suppress logs from printing to console
    def log_message(self, format, *args):  # pylint: disable=redefined-builtin
        if self.stargate.cfg.get("control_api_debug_enable"):
            self.stargate.log.log(f'{self.client_address[0]} {str(args[0])}')

    def parse_get_vars(self):
        query_string = {}
        path = self.path
        if '?' in path:
            path, tmp = path.split('?', 1)
            query_string = urllib.parse.parse_qs(tmp)
        if path.startswith('/stargate/'):
            path = path[len('/stargate'):]
        return path, query_string

    def do_GET(self):  # pylint: disable=invalid-name
        try:
            request_path, get_vars = self.parse_get_vars()

            if request_path == "/dial":
                target = self.get_home_dial_path()
                query = urllib.parse.urlparse(self.path).query
                self.send_response(302)
                self.send_header("Location", target + ("?" + query if query else ""))
                self.end_headers()
                return

            if request_path == "/get/is_alive":
                data = {'is_alive': True}

            elif request_path == "/get/address_book":
                data = {}
                record_type = get_vars.get('type', ['all'])[0]
                if record_type == "standard":
                    data['address_book'] = self.stargate.addr_manager.get_book().get_standard_gates()
                elif record_type == "fan":
                    data['address_book'] = self.stargate.addr_manager.get_book().get_fan_and_lan_addresses()
                else:
                    all_addr = self.stargate.addr_manager.get_book().get_all_nonlocal_addresses()
                    data['address_book'] = collections.OrderedDict(sorted(all_addr.items()))

                data['summary'] = self.stargate.addr_manager.get_summary_from_book(data['address_book'], True)
                data['galaxy_path'] = self.stargate.galaxy_path

            elif request_path == "/get/local_address":
                data = self.stargate.addr_manager.get_book().get_local_address()

            elif request_path == "/get/dialing_status":
                incoming_visual_symbols = getattr(self.stargate, "incoming_visual_symbols", [])
                extended_sequence_stage = getattr(self.stargate, "extended_sequence_stage", 0)
                incoming_visual_locked_chevrons = self.stargate.locked_chevrons_incoming

                if len(incoming_visual_symbols) > len(self.stargate.address_buffer_incoming):
                    if extended_sequence_stage >= 2:
                        incoming_visual_locked_chevrons += 1
                    if extended_sequence_stage >= 3:
                        incoming_visual_locked_chevrons += 1

                    incoming_visual_locked_chevrons = min(
                        incoming_visual_locked_chevrons,
                        len(incoming_visual_symbols)
                    )

                data = {
                    "gate_name": self.stargate.addr_manager.get_book().get_local_gate_name(),
                    "local_address": self.stargate.addr_manager.get_book().get_local_address(),
                    "address_buffer_outgoing": self.stargate.address_buffer_outgoing,
                    "locked_chevrons_outgoing": self.stargate.locked_chevrons_outgoing,
                    "address_buffer_incoming": self.stargate.address_buffer_incoming,
                    "locked_chevrons_incoming": self.stargate.locked_chevrons_incoming,
                    "incoming_visual_symbols": incoming_visual_symbols,
                    "incoming_visual_locked_chevrons": incoming_visual_locked_chevrons,
                    "extended_sequence_stage": extended_sequence_stage,
                    "wormhole_active": self.stargate.wormhole_active,
                    "black_hole_connected": self.stargate.black_hole,
                    "connected_planet": self.stargate.connected_planet_name,
                    "wormhole_open_time": self.stargate.wh_manager.open_time,
                    "wormhole_max_time": self.stargate.wh_manager.wormhole_max_time,
                    "wormhole_time_till_close": self.stargate.wh_manager.get_time_remaining(),
                    "ring_position": self.stargate.ring.get_position(),
                    "speed_dial_full_address": self.stargate.cfg.get('dialing_address_book_dials_full_address')
                }

            elif request_path == "/get/system_info":
                data = {
                    "gate_name": self.stargate.addr_manager.get_book().get_local_gate_name(),
                    "local_stargate_address": self.stargate.addr_manager.get_book().get_local_address(),
                    "local_stargate_address_string": self.stargate.addr_manager.get_book().get_local_address_string(),
                    "subspace_public_key": self.stargate.subspace_client.get_public_key(),
                    "subspace_ip_address_config": self.stargate.subspace_client.get_configured_ip(),
                    "subspace_ip_address_active": self.stargate.net_tools.get_subspace_ip(True),
                    "lan_ip_address": self.stargate.net_tools.get_ip_by_interface_list(['wlan0', 'eth0', 'en0', 'en1']),
                    "software_version": str(self.stargate.sw_updater.get_current_version()),
                    "software_update_last_check": self.stargate.cfg.get('software_update_last_check'),
                    "software_update_status": self.stargate.cfg.get('software_update_status'),
                    "python_version": platform.python_version(),
                    "internet_available": self.stargate.net_tools.has_internet_access(),
                    "subspace_available": self.stargate.subspace_client.is_online(),
                    "standard_gate_count": len(self.stargate.addr_manager.get_book().get_standard_gates()),
                    "fan_gate_count": len(self.stargate.addr_manager.get_book().get_fan_gates()),
                    "lan_gate_count": len(self.stargate.addr_manager.get_book().get_lan_gates()),
                    "fan_gate_last_update": self.stargate.cfg.get('fan_gate_last_update'),
                    "dialer_mode": self.stargate.dialer.type,
                    "hardware_mode": self.stargate.electronics.name,
                    "audio_volume": self.stargate.audio.volume,
                    "galaxy": self.stargate.galaxy
                }

                for key, value in self.stargate.dialing_log.get_summary().items():
                    data['stats_' + key] = value.get('value')

            elif request_path == "/get/hardware_status":
                data = {
                    "chevrons": self.stargate.chevrons.get_status(),
                    "glyph_ring": self.stargate.ring.get_status()
                }

            elif request_path == "/get/dhd_symbols":
                data = self.stargate.symbol_manager.get_dhd_symbols()

            elif request_path == "/get/symbols":
                data = {
                    "symbols": self.stargate.symbol_manager.get_all_ddslick()
                }

            elif request_path == "/get/symbols_all":
                data = self.stargate.symbol_manager.get_all()

            elif request_path == "/get/alarm_clock":
                data = self.stargate.alarm_clock.get_alarm_data()

            elif request_path == "/get/alarm_audio_files":
                data = {
                    "files": self.stargate.alarm_clock.list_audio_files()
                }

            elif request_path == "/get/dialing_history":
                data = {
                    "history": self.stargate.dialing_log.get_history(),
                    "summary": {
                        key: value.get("value")
                        for key, value in self.stargate.dialing_log.get_summary().items()
                    }
                }

            elif request_path == "/get/config":
                data = collections.OrderedDict(sorted(self.stargate.cfg.get_all_configs().items()))

            elif request_path == '/get/audio_clips':
                data = self.stargate.audio.list_clips()

            else:
                self.send_response(404, 'Not Found')
                self.end_headers()
                return

            content = json.dumps(data)
            self.send_response(200, 'OK')
            self.send_header("Content-type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Headers", 'Authorization, Content-Type')
            self.send_header("Access-Control-Allow-Methods", 'GET')
            self.end_headers()
            self.wfile.write(content.encode())

        except:  # pylint: disable=bare-except
            if self.stargate.cfg.get("control_api_debug_enable"):
                raise

            self.send_response(500, "Exception")
            self.end_headers()

    def do_POST(self):  # pylint: disable=invalid-name
        try:
            if self.path.startswith('/stargate/'):
                self.path = self.path[len('/stargate'):]
            content_len = int(self.headers.get('content-length', 0))
            body = self.rfile.read(content_len)
            try:
                data = json.loads(body)
            except:  # pylint: disable=bare-except
                data = {}

            if self.path == '/do/shutdown':
                self.stargate.wormhole_active = False
                sleep(5)
                self.send_response(200, 'OK')
                self.end_headers()
                os.system('systemctl poweroff')
                return

            if self.path == '/do/reboot':
                self.stargate.wormhole_active = False
                sleep(5)
                self.send_response(200, 'OK')
                self.end_headers()
                os.system('systemctl reboot')
                return

            if self.path == '/do/restart':
                if not self.stargate.app.is_daemon:
                    self.stargate.log.log("Software Reboot Requested, but not running as Daemon. Unable.")
                    self.send_response(200, 'Unable, software not running as daemon.')
                    self.end_headers()
                    return

                self.stargate.wormhole_active = False
                sleep(5)
                self.send_response(200, 'OK')
                self.end_headers()
                os.system('systemctl restart stargate.service')
                return

            if self.path == "/do/chevron_cycle":
                self.stargate.chevrons.get(int(data['chevron_number'])).cycle_outgoing()
                data = {"success": True}

            elif self.path == "/do/all_chevron_leds_off":
                self.stargate.chevrons.all_off()
                self.stargate.wormhole_active = False
                data = {"success": True}

            elif self.path == "/do/all_chevron_leds_on":
                self.stargate.chevrons.all_lights_on()
                data = {"success": True}

            elif self.path == "/do/white_on":
                try:
                    cal_led = self.stargate.electronics.get_calibration_led()
                    if cal_led:
                        cal_led.on()
                        data = {"success": True}
                    else:
                        self.stargate.log.log("WHITE_ON ERROR: calibration_led is None")
                        data = {"success": False}
                except Exception as exc:
                    self.stargate.log.log(f"WHITE_ON ERROR: {exc}")
                    data = {"success": False}

            elif self.path == "/do/white_off":
                try:
                    cal_led = self.stargate.electronics.get_calibration_led()
                    if cal_led:
                        cal_led.off()
                        data = {"success": True}
                    else:
                        self.stargate.log.log("WHITE_OFF ERROR: calibration_led is None")
                        data = {"success": False}
                except Exception as exc:
                    self.stargate.log.log(f"WHITE_OFF ERROR: {exc}")
                    data = {"success": False}

            elif self.path == "/do/wormhole_on":
                if not self.stargate.wormhole_active:
                    self.stargate.black_hole = False
                    self.stargate.manual_dynamic_override = False
                    self.stargate.wormhole_active = True
                    data = {"success": True}
                else:
                    data = {"success": False, "message": "A wormhole is already established."}

            elif self.path == "/do/dynamic_wormhole_on":
                if not self.stargate.wormhole_active:
                    self.stargate.black_hole = False
                    self.stargate.manual_dynamic_override = True
                    self.stargate.wormhole_active = True
                    data = {"success": True}
                else:
                    data = {"success": False, "message": "A wormhole is already established."}

            elif self.path == "/do/blackhole_on":
                if not self.stargate.wormhole_active:
                    self.stargate.black_hole = True
                    self.stargate.manual_dynamic_override = None
                    self.stargate.wormhole_active = True
                    data = {"success": True}
                else:
                    data = {"success": False, "message": "A wormhole is already established."}

            elif self.path == "/do/wormhole_off":
                self.stargate.black_hole = False
                self.stargate.wormhole_active = False
                data = {"success": True}

            elif self.path == "/do/dhd_on":
                try:
                    dhd = getattr(self.stargate.dialer, "hardware", None)
                    dhd_type = getattr(self.stargate.dialer, "type", "Unknown")

                    if dhd is None or dhd_type != "DHDv2":
                        self.stargate.log.log(f"DHD ON: DHD not active (type={dhd_type})")
                        data = {
                            "success": False,
                            "message": "DHDv2 not connected"
                        }
                    else:
                        target_brightness = int(255 * 0.60)
                        dhd.set_brightness_center(target_brightness)
                        dhd.set_brightness_symbols(target_brightness)

                        center_color = (255, 0, 0)
                        ring_color = (255, 50, 0)

                        dhd.clear_all_pixels()
                        dhd.set_color_center(center_color)
                        dhd.set_color_symbols(ring_color)
                        dhd.set_all_pixels_to_color(*ring_color)
                        dhd.set_center_on()
                        dhd.latch()

                        self.stargate.log.log(
                            f"DHD ON: center={center_color}, ring={ring_color}, brightness={target_brightness}"
                        )
                        data = {"success": True}

                except Exception as exc:
                    self.stargate.log.log(f"DHD ON ERROR: {exc}")
                    data = {"success": False, "message": str(exc)}

            elif self.path == "/do/dhd_off":
                try:
                    dhd = getattr(self.stargate.dialer, "hardware", None)
                    dhd_type = getattr(self.stargate.dialer, "type", "Unknown")

                    if dhd is None or dhd_type != "DHDv2":
                        self.stargate.log.log(f"DHD OFF: DHD not active (type={dhd_type})")
                        data = {
                            "success": False,
                            "message": "DHDv2 not connected"
                        }
                    else:
                        dhd.clear_all_pixels()
                        dhd.latch()
                        self.stargate.log.log("DHD OFF: LEDs cleared")
                        data = {"success": True}

                except Exception as exc:
                    self.stargate.log.log(f"DHD OFF ERROR: {exc}")
                    data = {"success": False, "message": str(exc)}

            elif self.path == "/do/symbol_forward":
                self.stargate.ring.move(33, self.stargate.ring.forward_direction)
                self.stargate.ring.release()
                data = {"success": True}

            elif self.path == "/do/symbol_backward":
                self.stargate.ring.move(33, self.stargate.ring.backward_direction)
                self.stargate.ring.release()
                data = {"success": True}

            elif self.path == "/do/volume_down":
                self.stargate.audio.volume_down()
                data = {"success": True}

            elif self.path == "/do/volume_up":
                self.stargate.audio.volume_up()
                data = {"success": True}

            elif self.path == "/do/simulate_incoming":
                if getattr(self.stargate, "wormhole_active", False):
                    data = {"success": False, "message": "A wormhole is already established."}
                else:
                    payload = data if isinstance(data, dict) else {}
                    extended = bool(payload.get("extended", False))

                    self.stargate.extended_mode = extended

                    self.stargate.incoming_visual_symbols = []
                    self.stargate.random_dhd_symbols = []
                    self.stargate.random_dhd_index = 0
                    self.stargate.random_dhd_active = False
                    self.stargate.random_dhd_last_time = 0
                    self.stargate.random_dhd_center_pending = False
                    self.stargate.extended_sequence_stage = 0
                    self.stargate.extended_sequence_last_time = 0

                    self.stargate.address_buffer_incoming = []
                    self.stargate.locked_chevrons_incoming = 0

                    for symbol_number in self.stargate.addr_manager.get_book().get_local_loopback_address():
                        self.stargate.address_buffer_incoming.append(symbol_number)

                    self.stargate.address_buffer_incoming.append(7)
                    self.stargate.centre_button_incoming = True

                    data = {
                        "success": True,
                        "mode": "extended" if extended else "original"
                    }

            elif self.path == "/do/subspace_up":
                print("Subspace UP")
                data = {"success": False, "message": "API NOT IMPLEMENTED"}

            elif self.path == "/do/subspace_down":
                print("Subspace DOWN")
                data = {"success": False, "message": "API NOT IMPLEMENTED"}

            elif self.path == "/do/dhd_press":
                symbol_number = int(data['symbol'])

                if symbol_number > 0:
                    self.stargate.keyboard.queue_symbol(symbol_number)
                elif symbol_number == 0:
                    self.stargate.keyboard.queue_center_button()
                elif symbol_number == -1 and self.stargate.wormhole_active is False and len(self.stargate.address_buffer_outgoing) > 0:
                    self.stargate.dialing_log.dialing_fail(self.stargate.address_buffer_outgoing)
                    self.stargate.shutdown(cancel_sound=False, wormhole_fail_sound=False)

                data = {"success": True}

            elif self.path == "/do/clear_outgoing_buffer":
                self.stargate.shutdown(cancel_sound=False, wormhole_fail_sound=False)
                data = {"success": True}

            elif self.path == "/do/set_glyph_ring_zero":
                self.stargate.ring.zero_position()
                data = {"success": True}

            elif self.path == "/do/dhd_led_test":
                try:
                    dhd = getattr(self.stargate.dialer, "hardware", None)
                    dhd_type = getattr(self.stargate.dialer, "type", "Unknown")

                    if dhd is None or dhd_type != "DHDv2":
                        self.stargate.log.log(f"DHD LED TEST: DHD not active (type={dhd_type})")
                        data = {
                            "success": False,
                            "message": "DHDv2 not connected"
                        }
                    else:
                        try:
                            mode = data.get("mode", "full")
                        except Exception:
                            mode = "full"

                        from test.dhd_test_from_config import dhd_led_test_backend
                        import threading

                        threading.Thread(
                            target=dhd_led_test_backend.run_dhd_test,
                            args=(dhd, self.stargate.log, mode),
                            daemon=True
                        ).start()

                        data = {"success": True, "mode": mode}

                except Exception as exc:
                    self.stargate.log.log(f"DHD LED TEST ERROR: {exc}")
                    data = {"success": False, "message": str(exc)}

            elif self.path == "/do/dhd_test_enable":
                self.stargate.keyboard.enable_dhd_test(True)
                data = {"success": True}

            elif self.path == "/do/dhd_test_disable":
                self.stargate.keyboard.enable_dhd_test(False)
                data = {"success": True}

            elif self.path == '/do/audio_play':
                try:
                    clip = data['clip']
                except KeyError:
                    data = {"success": False, "error": "Required fields missing or invalid request"}
                    return

                try:
                    clip_name = clip.replace('/', '_').split('.')[0]
                    if clip_name[0] == '_':
                        clip_name = clip_name[1:]

                    if clip_name not in self.stargate.audio.sounds:
                        self.stargate.audio.sounds[clip_name] = {
                            'file': self.stargate.audio.init_wav_file('/' + clip)
                        }

                    self.stargate.audio.sound_start(clip_name)
                except ValueError as exc:
                    data = {"success": False, "error": str(exc)}
                    return

                data = {"success": True}

            elif self.path == '/do/test_alarm_clock':
                data = self.stargate.alarm_clock.test_alarm(data.get('audio_file'))

            elif self.path == '/do/stop_alarm_clock':
                data = self.stargate.alarm_clock.stop_alarm()

            elif self.path == '/update/alarm_clock':
                try:
                    alarm_data = self.stargate.alarm_clock.update_alarm(data)
                    data = {
                        "success": True,
                        "message": "Alarm clock settings saved.",
                        "alarm": alarm_data
                    }
                except Exception as exc:
                    data = {"success": False, "message": str(exc)}

            elif self.path == '/update/local_stargate_address':
                continue_to_save = True
                try:
                    address = [data['S1'], data['S2'], data['S3'], data['S4'], data['S5'], data['S6']]
                except KeyError:
                    data = {"success": False, "error": "Required fields missing or invalid request"}
                    continue_to_save = False

                if continue_to_save:
                    verify_avail, error, entry = self.stargate.addr_manager.verify_address_available(address)  # pylint: disable=unused-variable
                    if verify_avail == "VERIFY_OWNED":
                        try:
                            if data['owner_confirmed']:
                                pass
                            else:
                                data = {"success": False, "error": error}
                                continue_to_save = False
                        except KeyError:
                            data = {
                                "success": False,
                                "extend": "owner_unconfirmed",
                                "error": f'This address is in use by a Fan Gate - "{entry["name"]}"'
                            }
                            continue_to_save = False
                    elif verify_avail is False:
                        data = {"success": False, "error": error}
                        continue_to_save = False

                if continue_to_save:
                    self.stargate.addr_manager.get_book().set_local_address(address)
                    data = {
                        "success": True,
                        "message": "There are no conflicts with your chosen address.<br><br>Local Address Saved."
                    }

            elif self.path == '/update/subspace_ip':
                try:
                    self.stargate.subspace_client.set_ip_address(data['ip'])
                    data = {"success": True, "message": "Subspace IP Address Saved."}
                except ValueError as exc:
                    data = {"success": False, "message": str(exc)}

            elif self.path == '/update/config':
                try:
                    message = self.stargate.cfg.set_bulk(data)
                    data = {"success": True, "message": "Configuration Saved", "results": message}
                except (NameError, ValueError) as exc:
                    data = {"success": False, "message": str(exc)}

            else:
                self.send_response(404, 'Not Found')
                self.end_headers()
                return

            if data:
                self.send_json_response(data)
            else:
                self.send_response(200, 'OK')
                self.end_headers()

            return

        except:  # pylint: disable=bare-except
            if self.stargate.cfg.get("control_api_debug_enable"):  # pylint: disable=no-member
                raise

            self.send_response(500, "Exception")
            self.end_headers()

    def send_json_response(self, data):
        content = json.dumps(data)
        self.send_response(200, 'OK')
        self.send_header("Content-type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", 'Authorization, Content-Type')
        self.send_header("Access-Control-Allow-Methods", 'POST, GET')
        self.end_headers()
        self.wfile.write(content.encode())

    def get_home_dial_path(self):
        try:
            page = self.stargate.cfg.get("web_home_redirect_page")
        except Exception:
            page = "retro/dial.html"

        if page not in ("retro/dial.html", "retro/dial9.html"):
            page = "retro/dial.html"

        return "/" + page


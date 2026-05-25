from threading import Thread
from time import time, sleep
from random import randrange, sample

from symbol_manager import StargateSymbolManager
from chevrons import ChevronManager
from dialers import Dialer
from keyboard_manager import KeyboardManager
from symbol_ring import SymbolRing
from stargate_address_manager import StargateAddressManager
import subspace_messages
from subspace_client import SubspaceClient
from wormhole_manager import WormholeManager
from subspace_server import SubspaceServer
from dialing_log import DialingLog
from alarm_clock_manager import AlarmClockManager


class Stargate:
    """
    This is the class to create the stargate object itself.
    """
    def __init__(self, app):

        self.app = app
        self.log = app.log
        self.cfg = app.cfg
        self.audio = app.audio
        self.electronics = app.electronics
        self.base_path = app.base_path
        self.net_tools = app.net_tools
        self.sw_updater = self.app.sw_updater
        self.schedule = app.schedule
        self.galaxy = app.galaxy
        self.galaxy_path = app.galaxy_path

        self.log.log('Initializing Milky Way Stargate Software')

        # Retrieve the configurations
        self.inactivity_timeout = self.cfg.get("dialing_timeout")

        # Initialize the state variables
        self.running = True
        self.address_buffer_outgoing = [] #Storage buffer for dialed outgoing address
        self.address_buffer_incoming = [] #Storage buffer for dialed incoming address
        self.last_activity_time = None # A variable to store the last user input time
        self.centre_button_outgoing = False #A variable for the state of the centre button, outgoing.
        self.centre_button_incoming = False #A variable for the state of the centre button, incoming.
        self.locked_chevrons_outgoing = 0 # The current number of locked outgoing chevrons
        self.locked_chevrons_incoming = 0 # The current number of locked incoming chevrons
        self.wormhole_active = False # The state of the wormhole.
        self.black_hole = False # Did we dial the black hole?
        self.fan_gate_online_status = True # To keep track of the dialed fan_gate status. Assume it's online until proven otherwise
        self.fan_gate_incoming_ip = None # To keep track of the IP address for the remote gate that establishes a wormhole
        self.fan_gate_incoming_name = None
        self.fan_gate_incoming_address = None
        self.connected_planet_name = None
        self.dhd_test = False
        self.extended_mode = False

        # DHD incoming animation state
        self.random_dhd_symbols = []
        self.random_dhd_index = 0
        self.random_dhd_active = False
        self.random_dhd_last_time = 0
        self.random_dhd_center_pending = False

        # Visual symbols shown on DHD / HOME
        self.incoming_visual_symbols = []

        # Extended incoming sequence state
        self.extended_sequence_stage = 0
        self.extended_sequence_last_time = 0

        ### Set up the needed classes and make them ready to use ###
        self.symbol_manager = StargateSymbolManager(self.galaxy_path)
        self.subspace_client = SubspaceClient(self)
        self.addr_manager = StargateAddressManager(self)
        self.chevrons = ChevronManager(self)
        self.ring = SymbolRing(self)
        self.dialer = Dialer(self) # A "Dialer" is either a Keyboard or DHDv2
        self.keyboard = KeyboardManager(self, app.is_daemon)
        self.wh_manager = WormholeManager(self)
        self.wh_manager.initialize_animation_manager()
        self.dialing_log = DialingLog(self)
        self.alarm_clock = AlarmClockManager(self)

        ### Run the stargate server for incoming wormholes.
        # LAN gates must work even when Internet/Subspace is unavailable.
        try:
            self.subspace_client_server_thread = Thread(target=SubspaceServer(self).start, daemon=True, args=())
            self.subspace_client_server_thread.start()
        except:
            self.log.log("Failed to start SubspaceServer thread")
            raise

        ### Notify that the Stargate is ready
        self.audio.play_random_clip("startup")
        self.log.log('The Stargate is started and ready!')

    def initialize_gate_state_vars(self):
        """
        This method resets the state variables to "gate idle"
        :return:
        """
        # Reset/initialize the state variables and address buffers
        self.address_buffer_outgoing = [] #Storage buffer for dialed outgoing address
        self.address_buffer_incoming = [] #Storage buffer for dialed incoming address
        self.last_activity_time = None # A variable to store the last user input time
        self.centre_button_outgoing = False #A variable for the state of the centre button, outgoing.
        self.centre_button_incoming = False #A variable for the state of the centre button, incoming.
        self.locked_chevrons_outgoing = 0 # The current number of locked outgoing chevrons
        self.locked_chevrons_incoming = 0 # The current number of locked incoming chevrons
        self.wormhole_active = False # The state of the wormhole.
        self.black_hole = False # Did we dial the black hole?
        self.fan_gate_online_status = True # To keep track of the dialed fan_gate status. Assume it's online until proven otherwise
        self.fan_gate_incoming_ip = None # To keep track of the IP address for the remote gate that establishes a wormhole
        self.fan_gate_incoming_name = None
        self.fan_gate_incoming_address = None
        self.connected_planet_name = None
        self.extended_mode = False

        self.random_dhd_symbols = []
        self.random_dhd_index = 0
        self.random_dhd_active = False
        self.random_dhd_last_time = 0
        self.random_dhd_center_pending = False

        self.incoming_visual_symbols = []

        self.extended_sequence_stage = 0
        self.extended_sequence_last_time = 0

    def _get_dhd_hw(self):
        try:
            dialer = getattr(self, "dialer", None)
            hw = getattr(dialer, "hardware", None) if dialer else None
            dhd_type = getattr(dialer, "type", None) if dialer else None
            if hw is not None and dhd_type == "DHDv2":
                return hw
        except Exception:
            pass
        return None

    def _dhd_symbol_on(self, symbol_number):
        hw = self._get_dhd_hw()
        if hw is None:
            return False

        try:
            fn = getattr(hw, "set_symbol_on", None)
            if callable(fn):
                fn(symbol_number)
                return True
        except Exception:
            pass

        fallback_calls = [
            ("set_symbol", (symbol_number, True)),
            ("symbol_on", (symbol_number,)),
            ("turn_on_symbol", (symbol_number,)),
            ("set_single_symbol", (symbol_number, True)),
        ]

        for method_name, args in fallback_calls:
            try:
                fn = getattr(hw, method_name, None)
                if callable(fn):
                    fn(*args)
                    return True
            except Exception:
                pass

        return False

    def _dhd_center_on(self):
        hw = self._get_dhd_hw()
        if hw is None:
            return False
        try:
            fn = getattr(hw, "set_center_on", None)
            if callable(fn):
                fn()
                return True
        except Exception:
            pass
        return False

    def _dhd_latch(self):
        hw = self._get_dhd_hw()
        if hw is None:
            return
        try:
            fn = getattr(hw, "latch", None)
            if callable(fn):
                fn()
        except Exception:
            pass

    def _dhd_clear(self):
        hw = self._get_dhd_hw()
        if hw is None:
            return
        try:
            fn = getattr(hw, "clear_all_pixels", None)
            if callable(fn):
                fn()
                self._dhd_latch()
                return
        except Exception:
            pass

        try:
            fn = getattr(hw, "clear_lights", None)
            if callable(fn):
                fn()
        except Exception:
            pass

    def _prepare_random_dhd_sequence(self, random_symbol_count):
        """
        Start random DHD sequence:
        - normal incoming: 6 random + Earth(last) + center(after Earth)
        - extended incoming: 8 random + Earth(last) + center(after Earth)
        """
        hw = self._get_dhd_hw()
        if hw is None:
            return

        try:
            earth_symbol = 1

            # Random symbols without Earth
            pool = list(range(2, 40))
            random_symbols = sample(pool, random_symbol_count)

            # Earth must always be last
            self.random_dhd_symbols = random_symbols + [earth_symbol]
            self.incoming_visual_symbols = self.random_dhd_symbols.copy()

            self.random_dhd_index = 0
            self.random_dhd_active = True
            self.random_dhd_last_time = 0
            self.random_dhd_center_pending = True

            try:
                target_brightness = int(255 * 0.60)
                hw.set_brightness_center(target_brightness)
                hw.set_brightness_symbols(target_brightness)
            except Exception:
                pass

            self._dhd_clear()
            # Center comes only after Earth
            self._dhd_latch()

        except Exception as ex:
            self.log.log(f'Random DHD prepare failed: {ex}')

    def _update_random_dhd_sequence(self):
        if not self.random_dhd_active:
            return

        now = time()
        if self.random_dhd_last_time and (now - self.random_dhd_last_time) < 0.12:
            return

        if self.random_dhd_index < len(self.random_dhd_symbols):
            symbol_number = self.random_dhd_symbols[self.random_dhd_index]
            if self._dhd_symbol_on(symbol_number):
                self._dhd_latch()

            self.random_dhd_index += 1
            self.random_dhd_last_time = now
            return

        if self.random_dhd_center_pending:
            self._dhd_center_on()
            self._dhd_latch()
            self.random_dhd_center_pending = False
            self.random_dhd_last_time = now
            return

        self.random_dhd_active = False

    def _extended_white_on(self):
        try:
            cal_led = self.electronics.get_calibration_led()
            if cal_led:
                cal_led.on()
        except Exception as ex:
            self.log.log(f'Extended incoming: unable to turn WHITE LED on: {ex}')

    def _extended_white_off(self):
        try:
            cal_led = self.electronics.get_calibration_led()
            if cal_led:
                cal_led.off()
        except Exception as ex:
            self.log.log(f'Extended incoming: unable to turn WHITE LED off: {ex}')

    def _light_incoming_chevron(self, chevron_number):
        try:
            self.chevrons.get(chevron_number).incoming_on()
            return True
        except KeyError:
            return False
        except Exception as ex:
            self.log.log(f'Extended incoming: unable to enable chevron {chevron_number}: {ex}')
            return False

    def _advance_extended_incoming_sequence(self):
        """
        Extended sequence after original 7-symbol incoming:
        - 7th lock already happened in normal incoming engine
        - then chevron 8
        - then chevron 9
        - then wormhole
        """
        if not self.extended_mode:
            return True

        now = time()

        if self.extended_sequence_stage == 0:
            self.extended_sequence_stage = 1
            self.extended_sequence_last_time = now
            return False

        if (now - self.extended_sequence_last_time) < 0.55:
            return False

        if self.extended_sequence_stage == 1:
            self._light_incoming_chevron(8)
            self.extended_sequence_stage = 2
            self.extended_sequence_last_time = now
            return False

        if self.extended_sequence_stage == 2:
            self._light_incoming_chevron(9)
            self.extended_sequence_stage = 3
            self.extended_sequence_last_time = now
            return False

        if self.extended_sequence_stage == 3:
            # Short natural pause before wormhole opens
            if (now - self.extended_sequence_last_time) < 0.25:
                return False
            self.extended_sequence_stage = 4
            return True

        return True

    def update(self):
        """
        This is the main method to keep the stargate running and make decisions based on the manipulated objects variables.
        There are basically two main phases, the dialing phase and the wormhole phase.
        :return: Nothing is returned.
        """
        while self.running: # If we have not aborted

            # Keep DHD animation running during dialing
            self._update_random_dhd_sequence()

            ### The Dialing phase###
            if not self.wormhole_active and self.running: # If we are in the dialing phase

                ## Outgoing dialing ##
                self.outgoing_dialing()

                ## Incoming dialing ##
                self.incoming_dialing()

                ## Establishing wormhole ##
                self.establishing_wormhole()

                ### Check for inactivity ###
                # If there are something in the buffers and no activity for 1 minute while dialing.
                # TODO: Use Schedule
                if self.inactivity( self.inactivity_timeout ):
                    self.log.log('Inactivity detected, aborting.')
                    self.shutdown()

            ### The wormhole phase ###
            elif self.wormhole_active: # If wormhole
                self.ring.release() # Release the stepper motor.
                self.wh_manager.establish_wormhole() # This will establish the wormhole and keep it running until self.wormhole_active is False
                #When the wormhole is no longer running
                self.shutdown(cancel_sound=False)

            self.schedule.run_pending() # Run any scheduled items

            sleep(0.1) # Give the CPU a break (and yield to other threads)

        # When the stargate is no longer running.
        self.shutdown(cancel_sound=False)


    def outgoing_dialing(self):
        """
        This method handles the outgoing dialing of the stargate. It's kept in it's own method so not to clutter up the update method too much.
        :return: Nothing is returned
        """
        if len(self.address_buffer_outgoing) > self.locked_chevrons_outgoing:
            self.ring.move_symbol_to_chevron(self.address_buffer_outgoing[self.locked_chevrons_outgoing], self.locked_chevrons_outgoing + 1)  # Dial the symbol
            self.locked_chevrons_outgoing += 1  # Increment the locked chevrons variable.

            # If the gate shutdown requested, play the stop-dialing sound, and stop doing things.
            if not self.running:
                self.shutdown(cancel_sound=False, wormhole_fail_sound=True)
                sleep(0.5) # Time to allow the wormhole_fail_sound to finish
                return

            try:
                self.chevrons.get(self.locked_chevrons_outgoing).cycle_outgoing()  # Do the chevron locking thing.
            except KeyError:  # If we dialed more chevrons than the stargate can handle.
                pass  # Just pass without activating a chevron.

            try:
                self.log.log(f'Chevron {self.locked_chevrons_outgoing} locked with symbol: {self.address_buffer_outgoing[self.locked_chevrons_outgoing - 1]}')
            except IndexError:
                pass
            self.last_activity_time = time()  # update the last_activity_time

            ## If we are dialing a fan_gate, send the symbols to the remote gate.
            if self.addr_manager.is_fan_made_stargate(self.address_buffer_outgoing):
                # If the gate is presumed to be online, send it.
                if self.fan_gate_online_status:
                    # send the locked symbols to the remote gate.

                    this_gate_ip = self.addr_manager.get_ip_from_stargate_address(self.address_buffer_outgoing )
                    this_message = str( self.address_buffer_outgoing[0:self.locked_chevrons_outgoing] )
                    has_connection = self.subspace_client.send_to_remote_stargate( this_gate_ip, this_message)[0] # Attempt to send

                    # Check for success
                    if has_connection:
                        self.log.log(f'Subspace Sent: {self.address_buffer_outgoing[0:self.locked_chevrons_outgoing]}')

                        # Check if the recipient is busy. If so, stop sending subspace messages to it.
                        is_busy = self.subspace_client.get_status_of_remote_gate(this_gate_ip)
                        if is_busy:
                            self.log.log("The dialed Stargate is busy, can't establish a wormhole.")
                        self.fan_gate_online_status = not is_busy

                    else:
                        self.log.log('This Gate is offline. Skipping Subspace sends for remainder of this dialing attempt.')
                        self.fan_gate_online_status = False # Gate is offline, don't keep sending messages during this dialing attempt

    def incoming_dialing(self):
        """
        This method handles the incoming dialing of the stargate. It's kept in it's own method so not to clutter up the update method too much.
        :return: Nothing is returned
        """

        # If there are dialed incoming symbols that are not yet locked and we are currently not dialing out.
        if len(self.address_buffer_incoming) > self.locked_chevrons_incoming and len(self.address_buffer_outgoing) == 0:

            # If we are still receiving the correct address to match the local stargate:
            buffer_first_6 = self.address_buffer_incoming[0:min(len(self.address_buffer_incoming), 6)] # get up to 6 symbols off incoming buffer
            local_first_6 = self.addr_manager.get_book().get_local_address()[0:min(len(self.address_buffer_incoming), 6)] # get up to 6 symbols off the local address_buffer_incoming
            loopback_first_6 = self.addr_manager.get_book().get_local_loopback_address()[0:min(len(self.address_buffer_incoming), 6)] # get up to 6 symbols off the loopback local address

            # If the incoming address buffer matches our routable or unroutable local address, lock it.
            if buffer_first_6 in (local_first_6, loopback_first_6):
                self.log.log("Address matching. Incoming Buffer: " + str(self.address_buffer_incoming))

                # Start DHD first, before the first chevron
                if self.locked_chevrons_incoming == 0 and not self.random_dhd_active and self.random_dhd_index == 0:
                    self.audio.play_random_clip("IncomingWormhole")
                    self._prepare_random_dhd_sequence(8 if self.extended_mode else 6)
                    self.last_activity_time = time()
                    return

                # DHD must stay ahead of chevrons
                # Before locking chevron N, at least N DHD symbols must already be lit.
                if self.random_dhd_index <= self.locked_chevrons_incoming:
                    return

                # If there are more than one unlocked symbol, add a short delay to avoid locking both symbols at once.
                if len(self.address_buffer_incoming) > self.locked_chevrons_incoming + 1:
                    delay = randrange(1, 800) / 100  # Add a delay with some randomness
                else:
                    delay = 0

                self.locked_chevrons_incoming += 1  # Increment the locked chevrons variable.
                try:
                    self.chevrons.get(self.locked_chevrons_incoming).incoming_on()  # Do the chevron locking thing.
                except KeyError:  # If we dialed more chevrons than the stargate can handle.
                    pass  # Just pass without activating a chevron.

                # Extended mode after original 7th symbol:
                # white first, then 8, then 9, then wormhole
                if self.extended_mode and self.locked_chevrons_incoming == 7:
                    self._extended_white_on()

                self.last_activity_time = time()  # update the last_activity_time

                # Do the logging
                self.log.log(f'Incoming: Chevron {self.locked_chevrons_incoming} locked with symbol {self.address_buffer_incoming[self.locked_chevrons_incoming - 1]}')

                sleep(delay)  # if there's a delay, use it.
            else:
                self.log.log("Address is not a match for this gate")

    # TODO: Some of this belongs in Subspace.
    def try_sending_centre_button(self):
        """
        This functions simply checks if it is possible to send the centre_button to the remote gate and sends it.
        This method is used in the establishing_wormhole method.
        :return: Nothing is returned.
        """
        if  self.addr_manager.is_fan_made_stargate(self.address_buffer_outgoing) and \
            self.fan_gate_online_status and \
            self.centre_button_outgoing and \
            len(self.address_buffer_outgoing) == self.locked_chevrons_outgoing:

            _ip_address = self.addr_manager.get_ip_from_stargate_address(self.address_buffer_outgoing )
            result = self.subspace_client.send_to_remote_stargate( _ip_address, subspace_messages.DIAL_CENTER_INCOMING )[0]
            if result:
                self.log.log('Sent: Center Button')

    def get_connected_planet_name(self):

        if self.wormhole_active == 'outgoing':
            return self.addr_manager.get_planet_name_by_address(self.address_buffer_outgoing)
        if self.wormhole_active == 'incoming':
            if self.fan_gate_incoming_name:
                return self.fan_gate_incoming_name
            return self.addr_manager.get_planet_name_from_ip(self.fan_gate_incoming_ip)
        # Not connected
        return False

    def establishing_wormhole(self):
        """
        This is the method that decides if we are to establish a wormhole or not
        :return: Nothing is returned, But the self.wormhole_active variable is changed if we can establish a wormhole.
        """
        ### Establishing wormhole ###
        ## Outgoing wormhole##
        # If the centre_button_outgoing is active and all dialed symbols are locked.
        if self.centre_button_outgoing and (0 < len(self.address_buffer_outgoing) == self.locked_chevrons_outgoing):

            # Try to send the centre button to the fan_gate:
            self.try_sending_centre_button()
            # Try to establish a wormhole
            if self.possible_to_establish_wormhole():

                self.ring.release() # Release the stepper to prevent overheating

                # Update the state variables
                self.wormhole_active = 'outgoing'
                self.connected_planet_name = self.get_connected_planet_name()

                # Log some stuff
                self.log.log('Valid address is locked')
                self.log.log(f'OUTGOING Wormhole to {self.connected_planet_name} established')

                # Log the connection!
                self.dialing_log.established_outbound(self.address_buffer_outgoing)

                # Check if we dialed a black hole planet
                if self.addr_manager.get_book().get_entry_by_address(self.address_buffer_outgoing[0:-1])['is_black_hole']:
                    self.log.log("Oh no! It's the black hole planet!")
                    self.black_hole = True
            else:
                # Log the dialing failure
                self.dialing_log.dialing_fail(self.address_buffer_outgoing)
                self.shutdown(cancel_sound=False, wormhole_fail_sound=True)

        ## Incoming wormhole ##
        # If the centre_button_incoming is active and all dialed symbols are locked.
        elif self.centre_button_incoming and 0 < len(self.address_buffer_incoming) == self.locked_chevrons_incoming:
            # If the incoming wormhole matches the local address
            if self.address_buffer_incoming[0:-1] == self.addr_manager.get_book().get_local_address() or \
                self.address_buffer_incoming[0:-1] == self.addr_manager.get_book().get_local_loopback_address():

                # Extended incoming:
                # after original 7-symbol incoming,
                # add 8, then 9, then wormhole
                if self.extended_mode:
                    if not self._advance_extended_incoming_sequence():
                        return

                # Update some state variables
                self.wormhole_active = 'incoming'  # Set the wormhole state to activate the wormhole.
                self.connected_planet_name = self.get_connected_planet_name()

                try:
                    self.dialer.hardware.set_center_on() # Activate the centre_button light
                except Exception:
                    pass

                self.log.log('Incoming address is a match!')
                self.log.log(f'INCOMING Wormhole from {self.connected_planet_name} established')

                # Log the connection!
                self.dialing_log.established_inbound(
                    getattr(self, "fan_gate_incoming_address", None),
                    self.connected_planet_name,
                    getattr(self, "fan_gate_incoming_ip", None)
                )

            else:
                self.log.log('Incoming address is NOT a match to Local Gate Address!')
                self.shutdown(cancel_sound=False, wormhole_fail_sound=True)


    def shutdown(self, cancel_sound=True, wormhole_fail_sound=False):
        """
        This method shuts down and resets the Stargate.
        :return:
        """

        self.log.log('Shutting down the gate...')

        # Play the cancel sound
        if cancel_sound:
            self.audio.sound_start('dialing_cancel')

        # Play the wormhole fail sound
        if wormhole_fail_sound:
            self.audio.sound_start('dialing_fail')

        self._extended_white_off()

        # Turn off the chevrons
        self.chevrons.all_off()

        # Turn off the DHD lights
        try:
            self.dialer.hardware.clear_lights()
        except Exception:
            self._dhd_clear()

        # Release the stepper motor.
        self.ring.release()

        # Put the gate back in to an idle state
        self.initialize_gate_state_vars()

        self.dialing_log.shutdown()

    def inactivity(self, seconds):
        """
        This functions checks if there has been more than the variable seconds of inactivity:
        :param seconds: The number of seconds of allowed inactivity
        :return: True if inactivity is detected, False if not
        """

        # TODO: Use schedule

        if not self.wormhole_active: #If we are in the dialing phase
            if self.last_activity_time: #If the variable is not None
                if (len(self.address_buffer_incoming) > 0) or (len(self.address_buffer_outgoing) > 0): # If there are something in the buffers
                    if (time() - self.last_activity_time) > seconds:
                        return True
        return False

    def possible_to_establish_wormhole(self):
        """
        This is a method to help check if we are able to establish a wormhole or not.
        :return: Returns True if we can establish a wormhole, and False if not
        """

        # TODO: Some of this belongs in Subspace.

        # If the dialed address is valid
        if self.fan_gate_online_status and ( len(self.address_buffer_outgoing) > 0 and self.addr_manager.valid_planet(self.address_buffer_outgoing) or \
            len(self.address_buffer_incoming) > 0 and self.addr_manager.valid_planet(self.address_buffer_incoming) ):
            # If we dialed a fan_gate
            if self.addr_manager.valid_planet(self.address_buffer_outgoing) == 'fan_gate':
                # If the dialed fan_gate is not online
                if not self.fan_gate_online_status:
                    self.log.log('The dialed fan_gate is NOT online!')
                    return False
                # If the dialed fan_gate is already busy, with an active wormhole or outgoing dialing is in progress.
                if self.subspace_client.get_status_of_remote_gate(self.addr_manager.get_ip_from_stargate_address(self.address_buffer_outgoing )):
                    self.log.log('The dialed fan_gate is already busy!')
                    return False
            return True  # returns true if we can establish a wormhole
        return False  # returns false if we cannot establish a wormhole.

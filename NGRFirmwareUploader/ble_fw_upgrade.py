import argparse
import asyncio
import logging
import sys
import re
import os
import json
import signal
import struct
from bumble.core import AdvertisingData, BT_LE_TRANSPORT, ProtocolError
from bumble.device import Device, Peer
from bumble.hci import Address
from bumble.transport import open_transport_or_link
from bumble.pairing import PairingDelegate, PairingConfig
from bumble.controller import Connection
from bumble.gatt import GATT_REQUEST_TIMEOUT
from bumble.gatt_client import CharacteristicProxy
from time import perf_counter
from datetime import timedelta
from humanize.filesize import naturalsize

###################################################################################################
## CONFIG

# Default BLE Target where to connect
BLE_TARGET='DKN_SDG_BLE_HCI_HOST'
# Default BLE characteristic on BLE Target where to write
BLE_FWU_WRITE_CHARACTERISTIC='3CE06519-BC5C-432C-AD3A-8801B224EE2C'
# Default BLE characteristic on BLE Target where to read info for fwu
BLE_CAPABILITY_READ_CHARACTERISTIC='3CE06519-BC5C-432C-AD3A-8801B224EE2D'
BLE_SMP_CHARACTERISTIC='DA2E7828-FBCE-4E01-AE9E-261174997C48'
SMP_PAYLOAD_SIZE=384
SMP_MIN_PAYLOAD_SIZE=32
SMP_GROUP_IMAGE=1
SMP_ID_IMAGE_UPLOAD=1
SMP_OP_WRITE=2
SMP_OP_WRITE_RSP=3
SMP_RETRY_COUNT=3
SMP_WINDOW_SIZE=10
# Connection Timeout
BLE_CONNECTION_TIMEOUT=60
# Timeout in seconds before we consider we cannot resolve BLE address when target is a BLE name
BLE_RESOLV_ADDR_TIMEOUT=30
# Number of Retry of Pairing
BLE_RETRY_PAIRING=5
# Maximum Transmission Unit (MTU) to be used
BLE_MTU_SIZE=498
# State value signifying that the device is in fwu mode and read for info
FWU_READY_FOR_INFO="readyForInfo"
# State value signifying that the upload is done
FWU_UPLOAD_SUCCESS="uploadSuccess"
# Output progress to console after every number of Bytes sent
BLE_OUTPUT_PROGRESS_STEP=100000

###################################################################################################
## GLOBALS

logger = logging.getLogger(__name__)

class SmpPendingRequest:
    def __init__(self, sequence: int, offset: int, chunk_size: int, request: bytes):
        self.sequence = sequence
        self.offset = offset
        self.chunk_size = chunk_size
        self.request = request

# Change logger class to avoid color characters introduced by Bumble library
class NoColorLogger(logging.Logger):

    def __init__(self,name,level=logging.NOTSET):
        super(NoColorLogger,self).__init__(name,level)

    def debug(self,msg,*args,**kwargs):
        # Search for special color characters and remove them
        msg = re.sub(r'\x1b\[[0-9]{1,2}m', '', msg)
        super(NoColorLogger,self).debug(msg,*args,**kwargs)

# Delegate class to handle pairing
# Based on the Delegate class in the pair.py example of Bumble library
class Delegate(PairingDelegate):
    def __init__(self, mode, connection, capability_string, do_prompt):
        super().__init__(
            {
                'keyboard': PairingDelegate.KEYBOARD_INPUT_ONLY,
                'display': PairingDelegate.DISPLAY_OUTPUT_ONLY,
                'display+keyboard': PairingDelegate.DISPLAY_OUTPUT_AND_KEYBOARD_INPUT,
                'display+yes/no': PairingDelegate.DISPLAY_OUTPUT_AND_YES_NO_INPUT,
                'none': PairingDelegate.NO_OUTPUT_NO_INPUT,
            }[capability_string.lower()]
        )

        self.mode = mode
        self.peer = Peer(connection)
        self.peer_name = None
        self.do_prompt = do_prompt

    async def prompt(self, message):
        # Wait a bit to allow some of the log lines to print before we prompt
        await asyncio.sleep(1)

        return input(message).lower().strip()


    """Called when number must be displayed and comfirmed during pairing"""
    async def compare_numbers(self, number, digits):
        # Prompt for a numeric comparison
        logger.info('###-----------------------------------')
        logger.info(f'### Pairing with {args.target}:')
        logger.info('###-----------------------------------')
        while True:
            response = await self.prompt(
                f'>>> Does the other device display {number:0{digits}}? '
            )

            if response == 'yes' or response == 'y':
                return True

            if response == 'no' or response == 'n':
                return False

###################################################################################################
## FUNCTIONS

"""
Parse command line arguments
"""
def parse_args() -> argparse.Namespace:

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "TRANSPORT",
        type=str,
        help="Transport spec (e.g. 'serial:/dev/ttyACM0' or 'usb:0')"
    )
    parser.add_argument(
        "MAIN_FIRMWARE_FILE",
        type=str,
        help="Firmware binary file for main image (e.g. 'zephyr_signed.bin')"
    )
    parser.add_argument(
        "RADIO_FIRMWARE_FILE",
        type=str,
        help="Firmware binary file for radio image (e.g. 'zephyr_signed.bin')"
    )
    parser.add_argument(
        "-t",
        "--target",
        type=str,
        help=f"Name or BLE Address of the BLE Target where to send Firmware binary (default: '{BLE_TARGET}')",
        default=BLE_TARGET
    )
    parser.add_argument(
        "-l",
        "--log-level",
        type=str,
        help=f"Log level (default: '{logging.getLevelName(logging.INFO)}')",
        default=logging.getLevelName(logging.INFO)
    )
    parser.add_argument(
        "--write-characteristic-id",
        type=str,
        help=f"Characteristic Id to be used for sending Firmware binary chunks (default: "
        "'{BLE_FWU_WRITE_CHARACTERISTIC}')",
        default=BLE_FWU_WRITE_CHARACTERISTIC
    )
    parser.add_argument(
        "--read-characteristic-id",
        type=str,
        help=f"Characteristic Id to be used for reading Firmware Update info (default: "
        "'{BLE_CAPABILITY_READ_CHARACTERISTIC}')",
        default=BLE_CAPABILITY_READ_CHARACTERISTIC
    )
    parser.add_argument(
        "--smp-characteristic-id",
        type=str,
        help=f"SMP Characteristic Id used for image upload (default: '{BLE_SMP_CHARACTERISTIC}')",
        default=BLE_SMP_CHARACTERISTIC
    )
    parser.add_argument(
        "--progress-step",
        type=int,
        help=f"Output progress to console after every number of Bytes sent (default: '{BLE_OUTPUT_PROGRESS_STEP}')",
        default=BLE_OUTPUT_PROGRESS_STEP
    )
    parser.add_argument(
        "--smp-retries",
        type=int,
        help=f"Number of retries for one SMP request on BLE write failure or response timeout (default: '{SMP_RETRY_COUNT}')",
        default=SMP_RETRY_COUNT
    )
    parser.add_argument(
        "--smp-window-size",
        type=int,
        help=f"Number of SMP requests to send before waiting for responses (default: '{SMP_WINDOW_SIZE}')",
        default=SMP_WINDOW_SIZE
    )
    parser.add_argument(
        "--smp-payload-size",
        type=int,
        help=f"Firmware bytes per SMP upload request (default: '{SMP_PAYLOAD_SIZE}')",
        default=SMP_PAYLOAD_SIZE
    )
    parser.add_argument(
        "--smp-write-without-response",
        action="store_true",
        help="Use BLE write without response for SMP upload requests; SMP notify responses are still checked"
    )
    return parser.parse_args()

"""
Initialize input arguments
"""
def init_args() -> None:
    if os.path.exists(args.MAIN_FIRMWARE_FILE) == False:
        logger.error(f"File [{args.MAIN_FIRMWARE_FILE}] does not exist")
        exit(1)
    if os.path.exists(args.RADIO_FIRMWARE_FILE) == False:
        logger.error(f"File [{args.RADIO_FIRMWARE_FILE}] does not exist")
        exit(1)
    if args.smp_retries < 0:
        logger.error("--smp-retries must be 0 or greater")
        exit(1)
    if args.smp_window_size <= 0 or args.smp_window_size > 255:
        logger.error("--smp-window-size must be between 1 and 255")
        exit(1)
    max_payload_size = max_smp_payload_size_for_mtu(BLE_MTU_SIZE)
    if args.smp_payload_size < SMP_MIN_PAYLOAD_SIZE or args.smp_payload_size > max_payload_size:
        logger.error(
            f"--smp-payload-size must be between {SMP_MIN_PAYLOAD_SIZE} and "
            f"{max_payload_size} for MTU {BLE_MTU_SIZE}"
        )
        exit(1)
    init_logger(args.log_level)

"""
Initialize the logger
"""
def init_logger(log_level: str) -> None:
    logging.setLoggerClass(NoColorLogger)
    logging.getLogger().setLevel(args.log_level)

    ch = logging.StreamHandler(sys.stdout)
    ch.setLevel(logging.INFO)
    ch.setFormatter(logging.Formatter("%(levelname)-8s | %(message)s"))
    logging.getLogger().addHandler(ch)

    fh = logging.FileHandler(f"{__file__[:-3]}.log")
    fh.setFormatter(logging.Formatter("%(asctime)s | %(levelname)-8s | %(name)-8s | %(message)s"))
    logging.getLogger().addHandler(fh)

"""
Initialize the BLE device
"""
def init_device(hci_source, hci_sink) -> Device:
    logger.info("Initializing Device ...")
    device = Device.with_hci("dkn-ble-fwu", "F1:F2:F3:F4:F5:F6", hci_source, hci_sink)
    device.pairing_config_factory = lambda connection: PairingConfig(
        True, True, True, Delegate('le', connection, 'display+keyboard', True)
    )
    return device

"""
Resolve the BLE address of the given name
"""
async def resolve_addr(device: Device, name: str) -> str:
    # Create a future to store the address when it's found
    peer_address = asyncio.get_running_loop().create_future()

    def on_peer_found(address, ad_data):
        local_name = ad_data.get(AdvertisingData.COMPLETE_LOCAL_NAME, raw=True)
        if local_name is None:
            local_name = ad_data.get(AdvertisingData.SHORTENED_LOCAL_NAME, raw=True)
        if local_name is not None:
            logger.debug(f"Local Name=[{local_name.decode('utf-8')}]")
            if local_name.decode('utf-8') == args.target:
                logger.info(f" - Address is [{address}]")
                peer_address.set_result(address)

    device.on('advertisement', lambda a: on_peer_found(a.address, a.data))
    await device.start_scanning(legacy=False, filter_duplicates=True)
    try:
        await asyncio.wait_for(peer_address, BLE_RESOLV_ADDR_TIMEOUT)
    except:
        logger.error(f"Unable to resolve address for target [{name}] after {BLE_RESOLV_ADDR_TIMEOUT}s")
        exit(1)
    return peer_address.result().to_string()

"""
Get a BLE address from the given Target, reslove it if it is a name instead of an address
"""
async def get_target_address(device : Device, target : str) -> str:
    try:
        # Check if ble target address needs to be resolved
        addr = Address.from_string_for_transport(args.target, BT_LE_TRANSPORT)
    except ValueError:
        # If the address is not parsable, assume it is a name instead
        logger.info(f'Resolving Address for BLE Target [{args.target}]')
        await device.power_on()
        addr = await resolve_addr(device, args.target)
        await device.power_off()
    return addr

"""
Logging when the connection parameters are updated
"""
def on_connection_update(connection, new_parameters):
    logger.info(f"Connection Updated, new parameters were set:")
    logger.info(f" - Connection Interval = {new_parameters.connection_interval}")
    logger.info(f" - Supervision Timeout = {new_parameters.supervision_timeout}")
    logger.info(f" - Maximum Latency = {new_parameters.peripheral_latency}")

"""
Create Connection with given Remote BLE Address and complete pairing with Remote
"""
async def get_paired_connection(device: Device, addr:str, nb_retry: int = 0) -> Connection:
    logger.info("Getting paired connection ...")

    # Connect to the device
    logger.info(f"Connecting to BLE Target [{args.target}] at Address [{addr}] ...")
    await device.power_on()
    connection = await device.connect(addr, timeout=BLE_CONNECTION_TIMEOUT)

    connection.on('disconnection', lambda *_: logger.info(' - Disconnected'))
    connection.on(
        'connection_encryption_change',
        lambda *_: logger.info(' - Connection encrypted')
    )
    connection.on('pairing_start', lambda *_: logger.info(' - Pairing started'))
    connection.on('pairing', lambda *_: logger.info(' - Paired!'))
    connection.on('pairing_failure', lambda *_: logger.warning(' - Pairing failed!'))
    connection.on(
        'connection_parameters_update',
        lambda *_: on_connection_update(connection, connection.parameters)
    )

    # Pair with the device
    try:
        # This step differs slightly from Madoka app:
        # App tries reading a characteristic to trigger pairing, as specified by iOS and Android
        # As this is part of these OS's, we skip this step and go straight to pairing
        await connection.pair()
        return connection
    except asyncio.CancelledError:
        # If we are cancelled, just raise the exception
        raise
    except Exception as e:
        logger.warning(f"Error when pairing to remote, error: {e}")

        if nb_retry > BLE_RETRY_PAIRING:
            raise Exception(f"Cannot pair with remote after {BLE_RETRY_PAIRING} retries", e)
        else:
            nb_retry += 1
            logger.info(f"Retry Pairing Attempt #{nb_retry} ---")
            await device.power_off()
            return await get_paired_connection(device, addr, nb_retry)

"""
Perform steps to connect to the BLE Target and return the Peer and Connection
"""
async def connect_to_target(hci_source, hci_sink) -> Peer:
    device = init_device(hci_source, hci_sink)
    addr = await get_target_address(device, args.target)
    connection = await get_paired_connection(device, addr)

    return Peer(connection)

"""
Verify the Maximum Transmission Unit (MTU) of the connection
"""
async def verify_mtu(peer: Peer) -> None:
    logger.debug("Checking MTU ...")
    mtu = await peer.request_mtu(BLE_MTU_SIZE)
    if mtu != BLE_MTU_SIZE:
        raise Exception(f"MTU is not {BLE_MTU_SIZE} but {mtu} instead")
    logger.debug(f" - MTU verified: {mtu}")

"""
Find the GATT characteristics needed for the Firmware Update
"""
async def find_characteristics(peer:Peer) -> [CharacteristicProxy, CharacteristicProxy, CharacteristicProxy]:
    await peer.discover_services()
    await peer.discover_characteristics()

    fwu_write = peer.get_characteristics_by_uuid(args.write_characteristic_id)
    if not fwu_write:
        raise Exception(f"FWU write Characteristic {args.write_characteristic_id} not found")
    capability_read = peer.get_characteristics_by_uuid(args.read_characteristic_id)
    if not capability_read:
        raise Exception(f"Capability Read Characteristic {args.read_characteristic_id} not found")
    smp = peer.get_characteristics_by_uuid(args.smp_characteristic_id)
    if not smp:
        raise Exception(f"SMP Characteristic {args.smp_characteristic_id} not found")

    if len(fwu_write) > 1:
        raise Exception(f"More than one FWU write Characteristic found")
    if len(capability_read) > 1:
        raise Exception(f"More than one Capability Read Characteristic found")
    if len(smp) > 1:
        raise Exception(f"More than one SMP Characteristic found")
    return [fwu_write[0], capability_read[0], smp[0]]

"""
Send the mode json to the BLE Target, putting the device in Firmware Update mode
"""
async def send_mode(fwu_write: CharacteristicProxy) -> None:
    fw_upgrade_mode_json = json.dumps({
        "fwuMode": True
    })
    await write_value(fwu_write, fw_upgrade_mode_json)

"""
Write a json value to a BLE characteristic
"""
async def write_value(characteristic: CharacteristicProxy, json: str) -> None:
    logger.info(f"Writing JSON [{json}] to Characteristic [{characteristic.uuid}] ...")
    ascii_message = json.encode('utf-8').hex()
    await characteristic.write_value(bytes.fromhex(ascii_message), True)

def cbor_uint(value: int) -> bytes:
    if value < 24:
        return bytes([value])
    if value <= 0xFF:
        return bytes([0x18, value])
    if value <= 0xFFFF:
        return bytes([0x19]) + value.to_bytes(2, "big")
    return bytes([0x1A]) + value.to_bytes(4, "big")

def cbor_text(value: str) -> bytes:
    raw = value.encode("utf-8")
    return bytes([0x60 + len(raw)]) + raw

def cbor_bytes(value: bytes) -> bytes:
    length = len(value)
    if length < 24:
        return bytes([0x40 + length]) + value
    if length <= 0xFF:
        return bytes([0x58, length]) + value
    return bytes([0x59]) + length.to_bytes(2, "big") + value

def cbor_map(items: list[tuple[str, bytes]]) -> bytes:
    return bytes([0xA0 + len(items)]) + b"".join(cbor_text(key) + value for key, value in items)

def smp_image_upload_request(sequence: int, slot: int, offset: int, data: bytes, total_size: int) -> bytes:
    items = [("off", cbor_uint(offset)), ("data", cbor_bytes(data))]
    if offset == 0:
        # Zephyr direct upload expects the absolute slot number plus one in the image field.
        items.insert(0, ("image", cbor_uint(slot + 1)))
        items.insert(1, ("len", cbor_uint(total_size)))

    payload = cbor_map(items)
    header = struct.pack(
        ">BBHHBB",
        SMP_OP_WRITE,
        0,
        len(payload),
        SMP_GROUP_IMAGE,
        sequence,
        SMP_ID_IMAGE_UPLOAD,
    )
    return header + payload

def max_smp_payload_size_for_mtu(mtu: int) -> int:
    # ATT Write Value can carry MTU-3 bytes. The first SMP upload packet has the most CBOR overhead
    # because it includes image and total length fields, so use that shape for the limit.
    max_write_value_size = mtu - 3
    payload_size = 0
    while len(smp_image_upload_request(0, 255, 0, bytes(payload_size + 1), 0xFFFFFFFF)) <= max_write_value_size:
        payload_size += 1
    return payload_size

def cbor_read_int(data: bytes, index: int) -> tuple[int, int]:
    head = data[index]
    index += 1
    major = head >> 5
    value = head & 0x1F
    if major not in (0, 1):
        raise ValueError("Expected CBOR integer")
    if value < 24:
        parsed = value
    elif value == 24:
        parsed = data[index]
        index += 1
    elif value == 25:
        parsed = int.from_bytes(data[index:index + 2], "big")
        index += 2
    elif value == 26:
        parsed = int.from_bytes(data[index:index + 4], "big")
        index += 4
    else:
        raise ValueError("Unsupported CBOR integer width")

    if major == 1:
        parsed = -1 - parsed
    return parsed, index

def cbor_read_uint(data: bytes, index: int) -> tuple[int, int]:
    value, index = cbor_read_int(data, index)
    if value < 0:
        raise ValueError("Expected CBOR unsigned integer")
    return value, index

def cbor_read_length(data: bytes, index: int, value: int) -> tuple[int | None, int]:
    if value < 24:
        return value, index
    if value == 24:
        return data[index], index + 1
    if value == 25:
        return int.from_bytes(data[index:index + 2], "big"), index + 2
    if value == 26:
        return int.from_bytes(data[index:index + 4], "big"), index + 4
    if value == 31:
        return None, index
    raise ValueError("Unsupported CBOR integer width")

def cbor_read_text(data: bytes, index: int) -> tuple[str, int]:
    head = data[index]
    index += 1
    if (head >> 5) != 3:
        raise ValueError("Expected CBOR text")
    length, index = cbor_read_length(data, index, head & 0x1F)
    if length is None:
        raise ValueError("Indefinite CBOR text is not supported")
    return data[index:index + length].decode("utf-8"), index + length

def cbor_decode_value(data: bytes, index: int):
    head = data[index]
    index += 1
    major = head >> 5
    value = head & 0x1F

    if major in (0, 1):
        return cbor_read_int(data, index - 1)

    length, index = cbor_read_length(data, index, value)

    if major == 2:
        if length is None:
            raise ValueError("Indefinite CBOR bytes are not supported")
        return data[index:index + length], index + length

    if major == 3:
        if length is None:
            raise ValueError("Indefinite CBOR text is not supported")
        return data[index:index + length].decode("utf-8"), index + length

    if major == 4:
        values = []
        if length is None:
            while data[index] != 0xFF:
                item, index = cbor_decode_value(data, index)
                values.append(item)
            return values, index + 1
        for _ in range(length):
            item, index = cbor_decode_value(data, index)
            values.append(item)
        return values, index

    if major == 5:
        values = {}
        if length is None:
            while data[index] != 0xFF:
                key, index = cbor_decode_value(data, index)
                item, index = cbor_decode_value(data, index)
                values[key] = item
            return values, index + 1
        for _ in range(length):
            key, index = cbor_decode_value(data, index)
            item, index = cbor_decode_value(data, index)
            values[key] = item
        return values, index

    if major == 7:
        if value == 20:
            return False, index
        if value == 21:
            return True, index
        if value == 22:
            return None, index
        if value == 23:
            return None, index

    raise ValueError(f"Unsupported CBOR type: major={major}, value={value}")

def smp_response_sequence_and_offset(packet: bytes) -> tuple[int, int]:
    op, _flags, length, group, seq, command = struct.unpack(">BBHHBB", packet[:8])
    if op != SMP_OP_WRITE_RSP or group != SMP_GROUP_IMAGE or command != SMP_ID_IMAGE_UPLOAD:
        raise ValueError("Unexpected SMP response header")

    payload = packet[8:8 + length]
    if not payload:
        return seq, -1

    values, _ = cbor_decode_value(payload, 0)
    if not isinstance(values, dict):
        raise ValueError(f"Expected CBOR map in SMP response, got {type(values).__name__}")

    logger.debug(f" - SMP response payload: {values}")

    if isinstance(values.get("err"), dict):
        err = values["err"]
        raise ValueError(f"SMP upload failed with group={err.get('group')} rc={err.get('rc')}")
    if values.get("rc", 0) != 0:
        raise ValueError(f"SMP upload failed with rc={values['rc']}")
    return seq, values.get("off", -1)

def drain_smp_responses(response_queue: asyncio.Queue) -> None:
    drained = 0
    while True:
        try:
            response_queue.get_nowait()
            drained += 1
        except asyncio.QueueEmpty:
            break

    if drained > 0:
        logger.debug(f" - Discarded {drained} stale SMP response(s)")

async def collect_smp_window_responses(response_queue: asyncio.Queue, pending: list[SmpPendingRequest]) -> dict[int, int]:
    pending_by_sequence = {request.sequence: request for request in pending}
    responses = {}
    deadline = perf_counter() + GATT_REQUEST_TIMEOUT

    while len(responses) < len(pending):
        timeout = deadline - perf_counter()
        if timeout <= 0:
            missing = sorted(set(pending_by_sequence) - set(responses))
            raise asyncio.TimeoutError(f"Missing SMP response(s) for seq={missing}")

        response = await asyncio.wait_for(response_queue.get(), timeout)
        logger.debug(f" - SMP response raw: {response.hex()}")
        sequence, next_offset = smp_response_sequence_and_offset(response)

        request = pending_by_sequence.get(sequence)
        if request is None:
            logger.warning(f"Discarding stale SMP response: Unexpected SMP sequence {sequence}")
            continue

        responses[sequence] = next_offset

    return responses

async def send_smp_window_with_retry(
    smp_write: CharacteristicProxy,
    response_queue: asyncio.Queue,
    pending: list[SmpPendingRequest]
) -> int:
    write_with_response = not args.smp_write_without_response

    for attempt in range(args.smp_retries + 1):
        retry_left = attempt < args.smp_retries
        drain_smp_responses(response_queue)

        try:
            for request in pending:
                await smp_write.write_value(request.request, write_with_response)

            responses = await collect_smp_window_responses(response_queue, pending)
        except ProtocolError as pe:
            if not retry_left:
                logger.error(pe)
                logger.error(f"Protocol Exception when writing SMP window, error code: 0x{pe.error_code:02x}")
                raise
            logger.warning(
                f"SMP window write failed, retry {attempt + 1}/{args.smp_retries}: "
                f"0x{pe.error_code:02x}"
            )
            continue
        except asyncio.TimeoutError as e:
            if not retry_left:
                logger.error(f"SMP window response timeout, no retries left: {e}")
                raise
            logger.warning(f"SMP window response timeout, retry {attempt + 1}/{args.smp_retries}: {e}")
            continue

        next_offset = pending[-1].offset + pending[-1].chunk_size
        for request in pending:
            response_offset = responses[request.sequence]
            if response_offset < 0:
                response_offset = request.offset + request.chunk_size

            expected_offset = request.offset + request.chunk_size
            if response_offset != expected_offset:
                logger.warning(
                    f"SMP window resync: seq={request.sequence} request_off={request.offset} "
                    f"expected_next={expected_offset} ngr_next={response_offset}"
                )
                return response_offset

        return next_offset

    raise RuntimeError("Unreachable SMP window retry state")

"""
Wait for the BLE Target to have a specified state in the capability characteristic
Checks the capability_read characteristic status after 15 seconds
and then every 5 seconds until the state is reached
"""
async def wait_for_state(
    capability_read: CharacteristicProxy,
    state: str,
    initial_delay_seconds: int = 15
) -> None:
    logger.info(f"Waiting for BLE Target to reach state [{state}] ...")
    if initial_delay_seconds > 0:
        await asyncio.sleep(initial_delay_seconds)
    state_reached = False
    while not state_reached:
        try:
            capability_value = await capability_read.read_value()
        except Exception as e:
            logger.error(f"Error when reading capability characteristic:")
            logger.error(e)
            await asyncio.sleep(5)
            logger.error("Retrying ...")
            continue

        logger.debug(f" - Capability Value: [{capability_value}]")
        data = json.loads(capability_value.decode('utf-8'))
        if data["main"]["state"] == state or data["radio"]["state"] == state:
             state_reached = True
             logger.info(f"State [{state}] reached")
             return
        logger.debug(" - State not reached yet ...")
        await asyncio.sleep(5)

"""
Upload the Firmware binary file to the BLE Target
"""
async def upload_image(smp_write: CharacteristicProxy, image: str, slot: int) -> None:
    logger.info(f"Uploading Firmware binary file [{image}] ...")
    write_mode = "without BLE response" if args.smp_write_without_response else "with BLE response"
    logger.info(
        f" - SMP window size set to {args.smp_window_size}, retries set to {args.smp_retries}, "
        f"payload size set to {args.smp_payload_size}, write mode: {write_mode}"
    )
    size = os.path.getsize(image)
    total_sent = 0
    sequence = 0
    next_progress_step = args.progress_step
    start_counter = perf_counter()
    step_counter = perf_counter()
    response_queue = asyncio.Queue()

    def on_smp_response(value: bytes) -> None:
        response_queue.put_nowait(bytes(value))

    await smp_write.subscribe(on_smp_response)
    try:
        with open(image, "rb") as f:
            while total_sent < size:
                pending = []
                window_offset = total_sent
                window_size = 1 if total_sent == 0 else args.smp_window_size

                for _ in range(window_size):
                    if window_offset >= size:
                        break

                    f.seek(window_offset)
                    chunk = f.read(args.smp_payload_size)
                    request = smp_image_upload_request(sequence, slot, window_offset, chunk, size)
                    pending.append(SmpPendingRequest(
                        sequence,
                        window_offset,
                        len(chunk),
                        request,
                    ))
                    window_offset += len(chunk)
                    sequence = (sequence + 1) & 0xFF

                next_offset = await send_smp_window_with_retry(smp_write, response_queue, pending)

                total_sent = next_offset
                logger.debug(f" - Sent up to offset {total_sent} - {size - total_sent} Bytes remaining")

                # Output progress to console if needed
                if total_sent > next_progress_step:
                    # Calculate stats
                    total_duration = perf_counter() - start_counter
                    step_sent = total_sent - next_progress_step + args.progress_step
                    step_duration = perf_counter() - step_counter
                    step_counter = perf_counter()
                    # Output progress to console
                    logger.info(f" - {naturalsize(total_sent)} sent in {timedelta(seconds=total_duration)}"
                                 f" [Step: {naturalsize(step_sent)} sent in {timedelta(seconds=step_duration)}]")
                    # Define next progress
                    next_progress_step += args.progress_step
    finally:
        await smp_write.unsubscribe(on_smp_response)
    total_duration = perf_counter() - start_counter
    logger.info(f"TOTAL [{naturalsize(total_sent)} - {total_sent} Bytes] sent in {timedelta(seconds=(total_duration))}")


"""
Open the transport. If it fails, wait 5 seconds and retry once
"""
async def open_transport(transport: str):
    try:
        transport_instance = await open_transport_or_link(transport)
    except Exception as e:
        logger.warning(f"Error when opening transport [{transport}]: {e}")
        logger.warning("Retrying in 5 seconds ...")
        await asyncio.sleep(5)
        try:
            transport_instance = await open_transport_or_link(transport)
        except Exception as e:
            logger.error(f"Error when opening transport [{transport}] on second attempt: {e}")
            raise e

    return transport_instance


"""
Read FW upgrade capability characteristic to determine slots
"""
async def get_slots(capability_read: CharacteristicProxy) -> [int, int]:
    capability_value = await capability_read.read_value()
    logger.debug(f" - Capability Value: [{capability_value}]")

    data = json.loads(capability_value.decode('utf-8'))
    main_slot = data["mainFreeSlot"]
    radio_slot = data["radioFreeSlot"]

    logger.debug(f" - Main FW will be uploaded to slot [{main_slot}]")
    logger.debug(f" - Radio FW will be uploaded to slot [{radio_slot}]")

    if main_slot == None or radio_slot == None:
        raise Exception("Unable to determine slots from capability characteristic")
    return [main_slot, radio_slot]


"""
Run the main firmware upgrade process
"""
async def run_fwu(hci_source, hci_sink):
    peer = await connect_to_target(hci_source, hci_sink)

    await verify_mtu(peer)
    fwu_write, capability_read, smp_write = await find_characteristics(peer)

    # Determine slots to use:
    [main_slot, radio_slot] = await get_slots(capability_read)

    # Start of firmware update
    await send_mode(fwu_write)

    # First upload - ST firmware
    await wait_for_state(capability_read, FWU_READY_FOR_INFO)
    await upload_image(smp_write, args.MAIN_FIRMWARE_FILE, main_slot)
    await wait_for_state(capability_read, FWU_READY_FOR_INFO, initial_delay_seconds=0)

    # Second upload - nRF firmware
    await upload_image(smp_write, args.RADIO_FIRMWARE_FILE, radio_slot + 2)
    await wait_for_state(capability_read, FWU_UPLOAD_SUCCESS, initial_delay_seconds=0)


###################################################################################################
## MAIN
async def main(args: argparse.Namespace) -> None:

    stop_event = asyncio.Event()
    loop = asyncio.get_running_loop()

    loop.add_signal_handler(signal.SIGINT, stop_event.set)
    loop.add_signal_handler(signal.SIGTERM, stop_event.set)


    logger.info(f"Opening transport [{args.TRANSPORT}] ...")
    transport = await open_transport(args.TRANSPORT)
    async with transport as (hci_source, hci_sink):

        fwu_task = asyncio.create_task(
            run_fwu(hci_source, hci_sink)
        )

        done, pending = await asyncio.wait(
            [fwu_task, asyncio.create_task(stop_event.wait())],
            return_when=asyncio.FIRST_COMPLETED,
        )

        if stop_event.is_set():
            logger.info("FWU cancelled")
            fwu_task.cancel()
            await asyncio.gather(fwu_task, return_exceptions=True)
        else:
            await fwu_task


if __name__ == '__main__':
    args = parse_args()
    init_args()

    try:
        asyncio.run(main(args))
    except Exception as e:
        logger.error(e)
        sys.exit(1)

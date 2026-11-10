"""Read-only Windows bench probe for the FT601 register transport."""

import argparse
import struct
import sys

from .ft601_client import FRAME_MAGIC, Frame, Opcode, encode_opcode

FT601_ID = 0x0403601F
PIPE_OUT = 0x02
PIPE_IN = 0x82
TIMEOUT_MS = 2000
STATUS_ADDRESS = 0x10


def read_status(device):
    request = Frame(Opcode.READ, 0, STATUS_ADDRESS, []).to_bytes()
    if device.writePipe(PIPE_OUT, request, len(request)) != len(request):
        raise OSError("Short FT601 request")

    response = bytearray()
    while len(response) < 16:
        chunk = device.readPipeEx(PIPE_IN, 16 - len(response))["bytes"]
        if not chunk:
            raise OSError("Incomplete FT601 response")
        response.extend(chunk)

    magic, header, address, status = struct.unpack("<4I", response)
    expected_header = (encode_opcode(Opcode.READ) << 24) | 1
    if (magic, header, address) != (FRAME_MAGIC, expected_header, STATUS_ADDRESS):
        raise ValueError("Response magic, opcode, length, flags, or address mismatch")
    if status & ~0x7:
        raise ValueError(f"Unexpected status register value 0x{status:08X}")
    return status


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", required=True, help="Serial of the bench FT601")
    args = parser.parse_args()
    if sys.platform != "win32":
        parser.error("The probe uses the Windows D3XX pipe API")

    try:
        import ftd3xx
    except ImportError:
        parser.error("Install the Windows ftd3xx Python package first")

    try:
        ftd3xx.raiseExceptionOnError(True)
        serial = args.serial.encode("ascii")
        devices = [
            ftd3xx.getDeviceInfoDetail(index)
            for index in range(ftd3xx.createDeviceInfoList())
        ]
        matches = [
            info for info in devices
            if info["ID"] == FT601_ID and info["SerialNumber"] == serial
        ]
        if len(matches) != 1:
            raise OSError(f"Expected one matching FT601, found {len(matches)}")

        device = ftd3xx.create(serial, ftd3xx.defines.FT_OPEN_BY_SERIAL_NUMBER)
        if device is None:
            raise OSError("Could not open the bench FT601")
        try:
            for pipe in (PIPE_OUT, PIPE_IN):
                device.setPipeTimeout(pipe, TIMEOUT_MS)
            status = read_status(device)
        finally:
            device.close(noreset=True)
    except (ftd3xx.DeviceError, OSError, ValueError) as error:
        print(f"FAIL: FT601 register transport: {error}", file=sys.stderr)
        return 1

    print(f"PASS: FT601 register transport, STATUS=0x{status:08X}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

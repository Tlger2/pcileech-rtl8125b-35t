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
    written = device.writePipe(PIPE_OUT, request, len(request))
    if written != len(request):
        raise OSError(f"Short FT601 request: wrote {written}/{len(request)} bytes")

    response = bytearray()
    while len(response) < 16:
        chunk = device.readPipeEx(PIPE_IN, 16 - len(response))["bytes"]
        if not chunk:
            raise OSError(
                f"Incomplete FT601 response: got {len(response)}/16 bytes "
                "(is the FPGA running the audited firmware?)"
            )
        response.extend(chunk)

    magic, header, address, status = struct.unpack("<4I", response)
    expected_header = (encode_opcode(Opcode.READ) << 24) | 1
    if (magic, header, address) != (FRAME_MAGIC, expected_header, STATUS_ADDRESS):
        raise ValueError(
            f"Response mismatch: magic=0x{magic:08X} header=0x{header:08X} "
            f"addr=0x{address:08X} (expected magic=0x{FRAME_MAGIC:08X} "
            f"header=0x{expected_header:08X} addr=0x{STATUS_ADDRESS:08X})"
        )
    if status & ~0x7:
        raise ValueError(f"Unexpected status register value 0x{status:08X}")
    return status


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", required=True, help="Serial of the bench FT601")
    parser.add_argument(
        "--list", action="store_true",
        help="List matching FT601 devices and exit",
    )
    args = parser.parse_args()
    if sys.platform != "win32":
        parser.error("The probe uses the Windows D3XX pipe API")

    try:
        import ftd3xx
    except ImportError:
        parser.error(
            "Install the Windows ftd3xx Python package first "
            "(and the FTDI D3XX driver for J3 / 0403:601F)"
        )

    try:
        ftd3xx.raiseExceptionOnError(True)
        devices = [
            ftd3xx.getDeviceInfoDetail(index)
            for index in range(ftd3xx.createDeviceInfoList())
        ]
        ft601s = [info for info in devices if info.get("ID") == FT601_ID]

        if args.list or not ft601s:
            if not ft601s:
                print("No FT601 devices (ID 0403:601F) found.", file=sys.stderr)
                print("Confirm J3 is connected and the D3XX driver is bound.", file=sys.stderr)
                return 1
            print("FT601 devices:")
            for info in ft601s:
                print(f"  serial={info.get('SerialNumber')!r}  description={info.get('Description')!r}")
            if args.list:
                return 0

        serial = args.serial.encode("ascii")
        matches = [
            info for info in ft601s
            if info.get("SerialNumber") == serial
        ]
        if len(matches) != 1:
            found = [info.get("SerialNumber") for info in ft601s]
            raise OSError(
                f"Expected one FT601 with serial {args.serial!r}, "
                f"found {len(matches)}. Available: {found}"
            )

        device = ftd3xx.create(serial, ftd3xx.defines.FT_OPEN_BY_SERIAL_NUMBER)
        if device is None:
            raise OSError(f"Could not open FT601 serial {args.serial!r}")
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

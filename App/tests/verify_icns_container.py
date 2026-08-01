#!/usr/bin/env python3

from pathlib import Path
import struct
import sys


ROOT = Path(__file__).resolve().parent.parent
ICONSET = ROOT / "Resources" / "AppIcon.iconset"
ICNS = ROOT / "Resources" / "AppIcon.icns"
CHUNKS = {
    b"icp4": "icon_16x16.png",
    b"icp5": "icon_32x32.png",
    b"icp6": "icon_32x32@2x.png",
    b"ic07": "icon_128x128.png",
    b"ic08": "icon_256x256.png",
    b"ic09": "icon_512x512.png",
    b"ic10": "icon_512x512@2x.png",
}


def main() -> int:
    data = ICNS.read_bytes()
    assert data[:4] == b"icns", "ICNS header is missing"
    assert struct.unpack(">I", data[4:8])[0] == len(data), "ICNS length is incorrect"

    offset = 8
    payloads: dict[bytes, bytes] = {}
    while offset < len(data):
        chunk_type = data[offset : offset + 4]
        chunk_length = struct.unpack(">I", data[offset + 4 : offset + 8])[0]
        assert chunk_length >= 8, f"invalid {chunk_type!r} chunk length"
        payloads[chunk_type] = data[offset + 8 : offset + chunk_length]
        offset += chunk_length
    assert offset == len(data), "ICNS chunks do not consume the container"

    for chunk_type, filename in CHUNKS.items():
        assert payloads.get(chunk_type) == (ICONSET / filename).read_bytes(), (
            f"{chunk_type.decode()} does not contain {filename}"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())

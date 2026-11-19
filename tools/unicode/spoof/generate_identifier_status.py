#!/usr/bin/env python3
"""Generate the UTS #39 Identifier_Status range table.

Usage:
    generate_identifier_status.py IdentifierStatus.txt out_dir

The input lists the code point ranges whose Identifier_Status is Allowed;
all other code points are Restricted. The output blob is CJXI version 1:
a sorted range table.
"""

from __future__ import annotations

import hashlib
import struct
import sys
from pathlib import Path

INPUT_SHA256 = "617228a16da13850bf8af28b6cd08f5e9b6595d2eb60404fe6eee2c85b4e4a35"


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    source_path = Path(sys.argv[1])
    out_dir = Path(sys.argv[2])
    out_dir.mkdir(parents=True, exist_ok=True)

    data = source_path.read_bytes()
    actual = hashlib.sha256(data).hexdigest()
    if actual != INPUT_SHA256:
        raise SystemExit(
            f"{source_path}: expected SHA-256 {INPUT_SHA256}, found {actual}"
        )

    ranges: list[tuple[int, int]] = []
    for line in data.decode("utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        parts = [part.strip() for part in line.split(";")]
        if len(parts) < 2 or parts[1] != "Allowed":
            continue
        span = parts[0].split("..")
        start = int(span[0], 16)
        end = int(span[-1], 16)
        ranges.append((start, end))
    ranges.sort()

    blob = bytearray(b"CJXI")
    blob += struct.pack("<B3BI", 1, 17, 0, 0, len(ranges))
    for start, end in ranges:
        blob += struct.pack("<II", start, end)

    (out_dir / "identifier_status.bin").write_bytes(bytes(blob))
    print(
        f"wrote {len(blob)} bytes, {len(ranges)} allowed ranges",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

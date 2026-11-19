#!/usr/bin/env python3
"""Generate the UTS #39 confusables mapping blob.

Usage:
    generate_confusables.py confusables.txt out_dir

The input is Unicode's security data file; each record maps one source
code point to a prototype sequence. The output blob is CJCF version 1:
a sorted record table plus a shared code-point pool.
"""

from __future__ import annotations

import hashlib
import struct
import sys
from pathlib import Path

INPUT_SHA256 = "091c7f82fc39ef208faf8f94d29c244de99254675e09de163160c810d13ef22a"


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

    records: list[tuple[int, list[int]]] = []
    for line in data.decode("utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        parts = [part.strip() for part in line.split(";")]
        if len(parts) < 2:
            continue
        source = int(parts[0], 16)
        target = [int(value, 16) for value in parts[1].split()]
        if not target:
            continue
        records.append((source, target))
    records.sort()

    pool: list[int] = []
    table: list[tuple[int, int, int]] = []
    for source, target in records:
        table.append((source, len(pool), len(target)))
        pool.extend(target)

    blob = bytearray(b"CJXC")
    blob += struct.pack("<B3BII", 1, 17, 0, 0, len(table), len(pool))
    for source, offset, length in table:
        blob += struct.pack("<IIB3x", source, offset, length)
    for codepoint in pool:
        blob += struct.pack("<I", codepoint)

    (out_dir / "confusables_data.bin").write_bytes(bytes(blob))
    print(
        f"wrote {len(blob)} bytes, {len(table)} mappings, "
        f"{len(pool)} pool code points",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

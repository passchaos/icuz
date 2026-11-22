#!/usr/bin/env python3
"""Expand the packed Bidi_Class page table into a flat byte table.

Usage:
    generate_flat_classes.py src/unicode/bidi/data.bin out_dir

Emits a `CJZ0` v1 blob consumed by src/unicode/bidi/data.zig. A flat table is
one load per scalar instead of the packed table's dependent index-then-page
loads, which matters for random scalars because the index load is on the
critical path.

The only input is the committed `data.bin`, so this generator is reproducible
without a UCD checkout.
"""

from __future__ import annotations

import struct
import sys
from pathlib import Path

UNICODE_VERSION = (17, 0, 0)
PAGE_SIZE = 256
PAGE_COUNT = 0x1100


def read_u16(data: bytes, offset: int) -> int:
    return struct.unpack_from("<H", data, offset)[0]


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    source = Path(sys.argv[1])
    out_dir = Path(sys.argv[2])
    out_dir.mkdir(parents=True, exist_ok=True)

    data = source.read_bytes()
    if (
        data[:4] != b"CJB1"
        or data[4] != 1
        or tuple(data[5:8]) != UNICODE_VERSION
    ):
        raise SystemExit(f"{source}: unexpected Bidi_Class table header")
    index_count = read_u16(data, 8)
    page_count = read_u16(data, 10)
    if index_count != PAGE_COUNT:
        raise SystemExit(f"{source}: unexpected page index length")
    index_offset = 16
    pages_offset = index_offset + index_count * 2
    if pages_offset + page_count * PAGE_SIZE > len(data):
        raise SystemExit(f"{source}: unexpected page payload length")

    index = [
        read_u16(data, index_offset + page * 2) for page in range(index_count)
    ]
    # One trailing sentinel entry serves scalars above U+10FFFF; the
    # surrogate range is patched to `on`, matching `class`'s validity rule,
    # so the runtime lookup needs no branches.
    flat = bytearray(PAGE_COUNT * PAGE_SIZE + 1)
    for page in range(index_count):
        base = pages_offset + index[page] * PAGE_SIZE
        flat[page * PAGE_SIZE : (page + 1) * PAGE_SIZE] = data[
            base : base + PAGE_SIZE
        ]
    on = 13
    flat[0xD800:0xE000] = bytes([on]) * 0x800
    flat[PAGE_COUNT * PAGE_SIZE] = on

    payload = bytearray(
        struct.pack(
            "<4sBBBBII",
            b"CJZ0",
            1,
            *UNICODE_VERSION,
            len(flat),
            0,
        )
    )
    payload += flat
    (out_dir / "flat_classes.bin").write_bytes(bytes(payload))


if __name__ == "__main__":
    main()

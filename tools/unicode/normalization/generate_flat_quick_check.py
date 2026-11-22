#!/usr/bin/env python3
"""Expand the packed quick-check page table into a flat table.

Usage:
    generate_flat_quick_check.py src/unicode/normalization/quick_check.bin \
        out_dir

Emits a `CJZ9` v1 blob consumed by src/unicode/normalization/data.zig. A flat
table is one load per scalar instead of the packed table's dependent
index-then-page loads, which dominate random lookups.

The only input is the committed blob, so this generator is reproducible
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
        data[:4] != b"CJQ1"
        or data[4] != 1
        or tuple(data[5:8]) != UNICODE_VERSION
    ):
        raise SystemExit(f"{source}: unexpected quick-check table header")
    index_count = read_u16(data, 8)
    page_count = read_u16(data, 10)
    if index_count != PAGE_COUNT:
        raise SystemExit(f"{source}: unexpected page index length")
    index_offset = 12
    pages_offset = index_offset + index_count * 2
    if pages_offset + page_count * PAGE_SIZE > len(data):
        raise SystemExit(f"{source}: unexpected page payload length")

    index = [
        read_u16(data, index_offset + page * 2) for page in range(index_count)
    ]
    # The packed table stores all-yes (0) for ASCII and surrogates, and
    # `quickCheckValue` returns 0 outside the Unicode range, so a zero
    # sentinel makes a clamped load match without branches.
    flat = bytearray(PAGE_COUNT * PAGE_SIZE + 1)
    for page in range(index_count):
        base = pages_offset + index[page] * PAGE_SIZE
        flat[page * PAGE_SIZE : (page + 1) * PAGE_SIZE] = data[
            base : base + PAGE_SIZE
        ]

    payload = bytearray(
        struct.pack(
            "<4sBBBBII",
            b"CJZ9",
            1,
            *UNICODE_VERSION,
            len(flat),
            0,
        )
    )
    payload += flat
    (out_dir / "flat_quick_check.bin").write_bytes(bytes(payload))


if __name__ == "__main__":
    main()

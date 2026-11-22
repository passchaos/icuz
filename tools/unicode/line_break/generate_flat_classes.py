#!/usr/bin/env python3
"""Expand the packed Line_Break page table into a flat class table.

Usage:
    generate_flat_classes.py src/unicode/line_break/data.bin \
        src/unicode/line_break/properties.zig out_dir

Emits a `CJZ6` v1 blob consumed by src/unicode/line_break/iterator.zig. The
segmenter keeps the two-byte property table; the public class query gets a
single-load table instead of the dependent index-then-page loads.

The inputs are committed files, so this generator is reproducible without a
UCD checkout.
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


def enum_ordinal(path: Path, enum_name: str, member: str) -> int:
    text = path.read_text(encoding="utf-8")
    body = text.split(f"pub const {enum_name} = enum(u6) {{", 1)[1].split(
        "};", 1
    )[0]
    names = [
        line.strip().rstrip(",")
        for line in body.splitlines()
        if line.strip() and not line.strip().startswith("//")
    ]
    return names.index(member)


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    source = Path(sys.argv[1])
    types_path = Path(sys.argv[2])
    out_dir = Path(sys.argv[3])
    out_dir.mkdir(parents=True, exist_ok=True)

    data = source.read_bytes()
    if (
        data[:4] != b"CJL2"
        or data[4] != 2
        or tuple(data[5:8]) != UNICODE_VERSION
    ):
        raise SystemExit(f"{source}: unexpected Line_Break table header")
    index_count = read_u16(data, 8)
    page_count = read_u16(data, 10)
    if index_count != PAGE_COUNT:
        raise SystemExit(f"{source}: unexpected page index length")
    index_offset = 12
    pages_offset = index_offset + index_count * 2
    if pages_offset + page_count * PAGE_SIZE * 2 > len(data):
        raise SystemExit(f"{source}: unexpected page payload length")

    unknown = enum_ordinal(types_path, "BreakClass", "unknown")
    index = [
        read_u16(data, index_offset + page * 2) for page in range(index_count)
    ]
    # One trailing sentinel entry serves scalars above U+10FFFF; the
    # surrogate range is patched to Unknown, matching `lookup`'s validity
    # rule, so the runtime lookup needs no branches.
    flat = bytearray(PAGE_COUNT * PAGE_SIZE + 1)
    for page in range(index_count):
        base = pages_offset + index[page] * PAGE_SIZE * 2
        for low in range(PAGE_SIZE):
            flat[page * PAGE_SIZE + low] = (
                read_u16(data, base + low * 2) & 0x3F
            )
    flat[0xD800:0xE000] = bytes([unknown]) * 0x800
    flat[PAGE_COUNT * PAGE_SIZE] = unknown

    payload = bytearray(
        struct.pack(
            "<4sBBBBII",
            b"CJZ6",
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

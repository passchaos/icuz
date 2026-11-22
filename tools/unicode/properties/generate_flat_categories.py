#!/usr/bin/env python3
"""Expand the packed property page table into a flat General_Category table.

Usage:
    generate_flat_categories.py src/unicode/properties/data.bin \
        src/unicode/properties/trie.zig out_dir

Emits a `CJZ7` v1 blob consumed by src/unicode/properties/trie.zig. The packed
word table keeps every binary property; the category query gets a single-load
byte table instead of the dependent index-then-page loads, which dominate
random lookups.

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
CATEGORY_BITS = 0x1F


def read_u16(data: bytes, offset: int) -> int:
    return struct.unpack_from("<H", data, offset)[0]


def enum_ordinal(path: Path, enum_name: str, member: str) -> int:
    text = path.read_text(encoding="utf-8")
    body = text.split(f"pub const {enum_name} = enum(u5) {{", 1)[1].split(
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
        data[:4] != b"CJP2"
        or data[4] != 2
        or tuple(data[5:8]) != UNICODE_VERSION
    ):
        raise SystemExit(f"{source}: unexpected property table header")
    index_count = read_u16(data, 8)
    page_count = read_u16(data, 10)
    if index_count != PAGE_COUNT:
        raise SystemExit(f"{source}: unexpected page index length")
    index_offset = 16
    pages_offset = index_offset + index_count * 2
    if pages_offset + page_count * PAGE_SIZE * 8 > len(data):
        raise SystemExit(f"{source}: unexpected page payload length")

    unassigned = enum_ordinal(types_path, "Category", "Cn")
    index = [
        read_u16(data, index_offset + page * 2) for page in range(index_count)
    ]
    # One trailing sentinel entry serves scalars above U+10FFFF, matching
    # `value`'s default. Surrogates keep their packed category (`Cs`), as
    # `category` has no validity rule of its own.
    flat = bytearray(PAGE_COUNT * PAGE_SIZE + 1)
    for page in range(index_count):
        base = pages_offset + index[page] * PAGE_SIZE * 8
        for low in range(PAGE_SIZE):
            flat[page * PAGE_SIZE + low] = (
                struct.unpack_from("<Q", data, base + low * 8)[0]
                & CATEGORY_BITS
            )
    flat[PAGE_COUNT * PAGE_SIZE] = unassigned

    payload = bytearray(
        struct.pack(
            "<4sBBBBII",
            b"CJZ7",
            1,
            *UNICODE_VERSION,
            len(flat),
            0,
        )
    )
    payload += flat
    (out_dir / "flat_categories.bin").write_bytes(bytes(payload))


if __name__ == "__main__":
    main()

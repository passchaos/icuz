#!/usr/bin/env python3
"""Generate trimmed membership bitmaps for hot binary properties.

Usage:
    generate_property_bits.py src/unicode/properties/data.bin out_dir

Emits a `CJBP` v1 blob consumed by src/unicode/properties/bits.zig. Each entry
is a trimmed little-endian bitmap with one trailing zero sentinel word, so a
single clamped load answers membership without touching the 2 MiB packed page
table.

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

# Bit positions come from the generated BinaryProperty enum; bits.zig compares
# every bitmap against the packed table over the whole scalar space, so a
# reordered enum fails tests instead of silently changing a property.
PROPERTIES = [
    ("white_space", 5),
    ("alphabetic", 6),
    ("uppercase", 7),
    ("lowercase", 8),
    ("math", 9),
    ("cased", 16),
]


def read_u16(data: bytes, offset: int) -> int:
    return struct.unpack_from("<H", data, offset)[0]


def load_page_table(path: Path) -> tuple[list[int], list[tuple[int, ...]]]:
    data = path.read_bytes()
    if (
        data[:4] != b"CJP2"
        or data[4] != 2
        or tuple(data[5:8]) != UNICODE_VERSION
    ):
        raise SystemExit(f"{path}: unexpected property table header")
    index_count = read_u16(data, 8)
    page_count = read_u16(data, 10)
    if index_count != PAGE_COUNT:
        raise SystemExit(f"{path}: unexpected page index length")
    index_offset = 16
    pages_offset = index_offset + index_count * 2
    if pages_offset + page_count * PAGE_SIZE * 8 != len(data):
        raise SystemExit(f"{path}: unexpected page payload length")
    index = [read_u16(data, index_offset + page * 2) for page in range(index_count)]
    pages = []
    for slot in range(page_count):
        base = pages_offset + slot * PAGE_SIZE * 8
        pages.append(struct.unpack_from(f"<{PAGE_SIZE}Q", data, base))
    return index, pages


def page_masks(pages: list[tuple[int, ...]], bit: int) -> list[int]:
    masks = []
    for page in pages:
        mask = 0
        flag = 1 << bit
        for slot, value in enumerate(page):
            if value & flag:
                mask |= 1 << slot
        masks.append(mask)
    return masks


def build_bitmap(index: list[int], masks: list[int]) -> list[int]:
    max_codepoint = -1
    for page, page_slot in enumerate(index):
        mask = masks[page_slot]
        if mask:
            max_codepoint = page * PAGE_SIZE + mask.bit_length() - 1
    if max_codepoint < 0:
        return [0]
    words = [0] * ((max_codepoint >> 6) + 2)
    for page, page_slot in enumerate(index):
        mask = masks[page_slot]
        base = page * PAGE_SIZE
        while mask:
            low = mask & -mask
            start = low.bit_length() - 1
            rest = mask >> start
            length = (rest ^ (rest + 1)).bit_length() - 1
            first = base + start
            for codepoint in range(first, first + length):
                words[codepoint >> 6] |= 1 << (codepoint & 63)
            mask &= ~(((1 << length) - 1) << start)
    return words


def render(bitmaps: list[tuple[int, list[int]]]) -> bytes:
    total_words = sum(len(words) for _, words in bitmaps)
    payload = bytearray(
        struct.pack(
            "<4sBBBBHHI",
            b"CJQZ",
            1,
            *UNICODE_VERSION,
            len(bitmaps),
            0,
            total_words,
        )
    )
    offset = 0
    for bit, words in bitmaps:
        payload += struct.pack("<III", bit, offset, len(words))
        offset += len(words)
    for _, words in bitmaps:
        for word in words:
            payload += struct.pack("<Q", word)
    return bytes(payload)


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    source = Path(sys.argv[1])
    out_dir = Path(sys.argv[2])
    out_dir.mkdir(parents=True, exist_ok=True)

    index, pages = load_page_table(source)
    bitmaps = []
    for _, bit in PROPERTIES:
        bitmaps.append((bit, build_bitmap(index, page_masks(pages, bit))))
    (out_dir / "property_bits.bin").write_bytes(render(bitmaps))


if __name__ == "__main__":
    main()

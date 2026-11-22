#!/usr/bin/env python3
"""Generate precomputed UnicodeSet ranges from the scalar property table.

Usage:
    generate_set_ranges.py src/unicode/properties/data.bin out_dir

Emits a `CJSR` v1 blob consumed by src/unicode/properties/trie.zig. It stores
the coalesced scalar ranges for every binary-property bit, every
General_Category value, and every General_Category alias mask, so dense set
construction copies ranges instead of rescanning the deduplicated page table.

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
CATEGORY_COUNT = 30
PROPERTY_BITS = 64

CATEGORIES = [
    "Lu", "Ll", "Lt", "Lm", "Lo",
    "Mn", "Mc", "Me",
    "Nd", "Nl", "No",
    "Pc", "Pd", "Ps", "Pe", "Pi", "Pf", "Po",
    "Sm", "Sc", "Sk", "So",
    "Zs", "Zl", "Zp",
    "Cc", "Cf", "Cs", "Co", "Cn",
]
AGGREGATES = {
    "L": ["Lu", "Ll", "Lt", "Lm", "Lo"],
    "LC": ["Lu", "Ll", "Lt"],
    "M": ["Mn", "Mc", "Me"],
    "N": ["Nd", "Nl", "No"],
    "P": ["Pc", "Pd", "Ps", "Pe", "Pi", "Pf", "Po"],
    "S": ["Sm", "Sc", "Sk", "So"],
    "Z": ["Zs", "Zl", "Zp"],
    "C": ["Cc", "Cf", "Cs", "Co", "Cn"],
}


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


def build_page_masks(
    pages: list[tuple[int, ...]],
) -> tuple[list[list[int]], list[list[int]]]:
    """Per distinct page, one 256-bit membership mask per entry."""
    property_masks: list[list[int]] = []
    category_masks: list[list[int]] = []
    for page in pages:
        property_page = [0] * PROPERTY_BITS
        category_page = [0] * CATEGORY_COUNT
        for slot, value in enumerate(page):
            bit = 1 << slot
            category_page[value & 0x1F] |= bit
            flags = value >> 5
            while flags:
                low = flags & -flags
                property_page[5 + low.bit_length() - 1] |= bit
                flags ^= low
        property_masks.append(property_page)
        category_masks.append(category_page)
    return property_masks, category_masks


def page_runs(
    index: list[int],
    masks: list[list[int]],
    entry: int,
) -> list[tuple[int, int]]:
    runs: list[tuple[int, int]] = []
    for page, page_slot in enumerate(index):
        mask = masks[page_slot][entry]
        base = page * PAGE_SIZE
        while mask:
            low = mask & -mask
            start = low.bit_length() - 1
            rest = mask >> start
            length = (rest ^ (rest + 1)).bit_length() - 1
            first = base + start
            last = first + length - 1
            if runs and first == runs[-1][1] + 1:
                runs[-1] = (runs[-1][0], last)
            else:
                runs.append((first, last))
            mask &= ~(((1 << length) - 1) << start)
    return runs


def merge_runs(runs: list[tuple[int, int]]) -> list[tuple[int, int]]:
    merged: list[tuple[int, int]] = []
    for first, last in sorted(runs):
        if merged and first <= merged[-1][1] + 1:
            merged[-1] = (merged[-1][0], max(merged[-1][1], last))
        else:
            merged.append((first, last))
    return merged


def render(
    property_ranges: list[list[tuple[int, int]]],
    mask_ranges: list[tuple[int, list[tuple[int, int]]]],
) -> bytes:
    range_count = sum(len(ranges) for ranges in property_ranges)
    range_count += sum(len(ranges) for _, ranges in mask_ranges)
    payload = bytearray(
        struct.pack(
            "<4sBBBBHHI",
            b"CJSR",
            1,
            *UNICODE_VERSION,
            PROPERTY_BITS,
            len(mask_ranges),
            range_count,
        )
    )
    offset = 0
    for ranges in property_ranges:
        payload += struct.pack("<II", offset, len(ranges))
        offset += len(ranges)
    for mask, ranges in mask_ranges:
        payload += struct.pack("<III", mask, offset, len(ranges))
        offset += len(ranges)
    for ranges in property_ranges:
        for first, last in ranges:
            payload += struct.pack("<II", first, last)
    for _, ranges in mask_ranges:
        for first, last in ranges:
            payload += struct.pack("<II", first, last)
    return bytes(payload)


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    source = Path(sys.argv[1])
    out_dir = Path(sys.argv[2])
    out_dir.mkdir(parents=True, exist_ok=True)

    index, pages = load_page_table(source)
    property_masks, category_masks = build_page_masks(pages)

    property_ranges = [
        page_runs(index, property_masks, bit) for bit in range(PROPERTY_BITS)
    ]

    aliases: list[tuple[int, list[int]]] = []
    for category in range(CATEGORY_COUNT):
        aliases.append((1 << category, [category]))
    for members in AGGREGATES.values():
        mask = 0
        for name in members:
            mask |= 1 << CATEGORIES.index(name)
        aliases.append((mask, [CATEGORIES.index(name) for name in members]))
    mask_ranges = []
    for mask, categories in aliases:
        runs: list[tuple[int, int]] = []
        for category in categories:
            runs.extend(page_runs(index, category_masks, category))
        mask_ranges.append((mask, merge_runs(runs)))
    mask_ranges.sort(key=lambda entry: entry[0])

    (out_dir / "set_ranges.bin").write_bytes(render(property_ranges, mask_ranges))


if __name__ == "__main__":
    main()
